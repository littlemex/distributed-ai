// cliff5: an N-GPU LL ring without NCCL. GPU i writes 64 KiB LL steps (16 B lines: data, flag, data, flag) into
// an 8-slot send ring in pinned host memory; its CPU proxy waits for the step, optionally reads C cache lines
// of the slot (leaving CPU-cached copies), and RDMA-writes the slot with efa-direct into GPU (i+1)'s recv ring
// (pinned, GPU-mapped). At step s GPU i polls the LL flags of recv step s-1 (written by the EFA) and uses that
// data as the input of send step s. Up to 8 EFA writes in flight per GPU; a send slot is freed when its write
// completes. All endpoints live in one EFA domain.
// usage: cliff5 <ngpu> <C cached lines per step 0..1024> <steps> [domain]
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>
#include <sched.h>
#include <cuda_runtime.h>
#include <rdma/fabric.h>
#include <rdma/fi_domain.h>
#include <rdma/fi_endpoint.h>
#include <rdma/fi_cm.h>
#include <rdma/fi_rma.h>
#include <rdma/fi_errno.h>
#define SLOTS 8
#define STEPB 65536
#define LINES (STEPB/16)
#define CK(x) do { int _r = (x); if (_r) { fprintf(stderr, "%s failed: %d %s\n", #x, _r, fi_strerror(-_r)); exit(1); } } while (0)
struct Ctl { volatile uint64_t tail[8]; volatile uint64_t head[8]; };
__global__ void k(uint4* send, const uint4* recv, Ctl* c, int steps) {
  for (int s = 0; s < steps; s++) {
    if (threadIdx.x == 0) while (c->head[0] + SLOTS <= (uint64_t)s) {}
    __syncthreads();
    uint4* slot = send + (size_t)(s % SLOTS)*LINES;
    int rs = s - 1; const uint4* rslot = recv + (size_t)((rs < 0 ? 0 : rs) % SLOTS)*LINES;
    for (int l = threadIdx.x; l < LINES; l += blockDim.x) {
      uint32_t acc = 0;
      if (rs >= 0) { uint4 v; do { asm volatile("ld.volatile.global.v4.u32 {%0,%1,%2,%3}, [%4];" : "=r"(v.x), "=r"(v.y), "=r"(v.z), "=r"(v.w) : "l"(rslot + l) : "memory"); } while (v.y != (uint32_t)(rs+1) || v.w != (uint32_t)(rs+1)); acc = v.x; }
      slot[l] = make_uint4(acc + 1, s+1, acc + 1, s+1);
    }
    __syncthreads();
    if (threadIdx.x == 0) { __threadfence_system(); c->tail[0] = s + 1; }
  }
}
struct Gpu { uint4 *send, *recv, *dsend, *drecv; Ctl* c; Ctl* dc; fid_ep* ep; fid_cq* cq; fid_mr *mrs, *mrr; fi_addr_t peer; uint64_t rkey; cudaStream_t st; };
int main(int argc, char** argv) {
  int n = atoi(argv[1]), C = atoi(argv[2]), steps = atoi(argv[3]); const char* dom = argc > 4 ? argv[4] : "rdmap83s0-rdm";
  fi_info* h = fi_allocinfo(); h->caps = FI_RMA | FI_LOCAL_COMM | FI_REMOTE_COMM; h->mode = FI_CONTEXT | FI_CONTEXT2 | FI_RX_CQ_DATA; h->ep_attr->type = FI_EP_RDM;
  h->fabric_attr->prov_name = strdup("efa"); h->fabric_attr->name = strdup("efa-direct"); h->domain_attr->name = strdup(dom);
  h->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY | FI_MR_HMEM;
  fi_info* fi; CK(fi_getinfo(FI_VERSION(2, 0), NULL, NULL, 0, h, &fi));
  fid_fabric* fab; fid_domain* domn; fid_av* av; CK(fi_fabric(fi->fabric_attr, &fab, NULL)); CK(fi_domain(fab, fi, &domn, NULL));
  fi_av_attr ava = {}; ava.type = FI_AV_TABLE; CK(fi_av_open(domn, &ava, &av, NULL));
  std::vector<Gpu> g(n); std::vector<fi_addr_t> addrs(n);
  for (int i = 0; i < n; i++) {
    cudaSetDevice(i); cudaStreamCreate(&g[i].st);
    cudaHostAlloc(&g[i].send, SLOTS*STEPB, cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&g[i].dsend, g[i].send, 0);
    cudaHostAlloc(&g[i].recv, SLOTS*STEPB, cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&g[i].drecv, g[i].recv, 0); memset(g[i].recv, 0, SLOTS*STEPB);
    cudaHostAlloc(&g[i].c, sizeof(Ctl), cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&g[i].dc, g[i].c, 0); memset((void*)g[i].c, 0, sizeof(Ctl));
    fi_cq_attr cqa = {}; cqa.format = FI_CQ_FORMAT_CONTEXT; CK(fi_cq_open(domn, &cqa, &g[i].cq, NULL));
    CK(fi_endpoint(domn, fi, &g[i].ep, NULL)); CK(fi_ep_bind(g[i].ep, &g[i].cq->fid, FI_TRANSMIT | FI_RECV)); CK(fi_ep_bind(g[i].ep, &av->fid, 0)); CK(fi_enable(g[i].ep));
    char a[64]; size_t al = sizeof(a); CK(fi_getname(&g[i].ep->fid, a, &al)); if (fi_av_insert(av, a, 1, &addrs[i], 0, NULL) != 1) { fprintf(stderr, "av_insert\n"); return 1; }
    CK(fi_mr_reg(domn, g[i].send, SLOTS*STEPB, FI_WRITE | FI_READ | FI_REMOTE_READ, 0, 0, 0, &g[i].mrs, NULL));
    CK(fi_mr_reg(domn, g[i].recv, SLOTS*STEPB, FI_REMOTE_WRITE, 0, 0, 0, &g[i].mrr, NULL));
  }
  for (int i = 0; i < n; i++) { int nx = (i + 1) % n; g[i].peer = addrs[nx]; g[i].rkey = fi_mr_key(g[nx].mrr); }
  struct Req { fi_context2 ctx; int s; };
  std::vector<std::thread> px;
  for (int i = 0; i < n; i++) px.emplace_back([&, i] {
    Gpu& G = g[i]; int nx = (i + 1) % n; int core = (i < 4 ? 8 + i : 104 + i);
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(core, &cs); sched_setaffinity(0, sizeof(cs), &cs);
    std::vector<Req> rq(SLOTS); std::vector<char> fin(SLOTS, 0); int posted = 0, done = 0; volatile uint64_t sink = 0;
    while (done < steps) {
      int s = posted;
      if (s < steps && s < done + SLOTS && G.c->tail[0] >= (uint64_t)s + 1) {
        size_t off = (size_t)(s % SLOTS)*STEPB; volatile uint32_t* sl = (volatile uint32_t*)((char*)G.send + off);
        if (C > 0) { int stride = 1024 / C; for (int j = 0; j < C; j++) sink += sl[(size_t)j*stride*16]; }
        rq[s % SLOTS].s = s; ssize_t r;
        while ((r = fi_write(G.ep, (char*)G.send + off, STEPB, fi_mr_desc(G.mrs), G.peer, (uint64_t)((char*)g[nx].recv + off), G.rkey, &rq[s % SLOTS].ctx)) == -FI_EAGAIN) fi_cq_read(G.cq, NULL, 0);
        if (r) { fprintf(stderr, "fi_write %zd\n", r); exit(1); }
        posted++;
      }
      fi_cq_entry e[16]; ssize_t m = fi_cq_read(G.cq, e, 16);
      if (m > 0) for (int j = 0; j < m; j++) fin[((Req*)e[j].op_context)->s % SLOTS] = 1;
      else if (m < 0 && m != -FI_EAGAIN) { fi_cq_err_entry ee = {}; fi_cq_readerr(G.cq, &ee, 0); fprintf(stderr, "cq err %d\n", ee.err); exit(1); }
      while (done < posted && fin[done % SLOTS]) { fin[done % SLOTS] = 0; done++; G.c->head[0] = done; }
    }
  });
  std::vector<cudaEvent_t> ea(n), eb(n);
  for (int i = 0; i < n; i++) { cudaSetDevice(i); cudaEventCreate(&ea[i]); cudaEventCreate(&eb[i]); cudaEventRecord(ea[i], g[i].st); k<<<1, 512, 0, g[i].st>>>(g[i].dsend, g[i].drecv, g[i].dc, steps); cudaEventRecord(eb[i], g[i].st); }
  float mx = 0; for (int i = 0; i < n; i++) { cudaSetDevice(i); cudaEventSynchronize(eb[i]); float ms; cudaEventElapsedTime(&ms, ea[i], eb[i]); if (ms > mx) mx = ms; }
  for (auto& t : px) t.join();
  printf("[cliff5] ngpu=%d C=%d steps=%d -> %.2f us/step\n", n, C, steps, mx*1000/steps);
  return 0;
}
