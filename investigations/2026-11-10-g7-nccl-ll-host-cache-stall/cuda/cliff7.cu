// cliff7: cliff6, but connections b >= NNET are SHM-like: the next GPU polls this GPU's send ring directly in
// host memory (no proxy, no EFA, no CPU read) and returns the slot by writing this GPU's head. Only the NNET
// net connections go through the proxy (CPU reads C lines, then fi_write). usage: cliff7 <ngpu> <C> <steps> <nconn> <nnet>
// cliff6: cliff5 with NC connections (blocks) per GPU like NCCL channels; one proxy thread per GPU serves all NC
// connections round-robin. usage: cliff6 <ngpu> <C> <steps> <nconn> [domain]
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
#define MAXC 8
struct Ctl { volatile uint64_t tail[MAXC*8]; volatile uint64_t head[MAXC*8]; };
__global__ void k(uint4* sendAll, const uint4* recvNet, const uint4* recvShm, Ctl* c, Ctl* prevc, int steps, int nnet, int shmNoRead) {
  int b = blockIdx.x; bool shm = b >= nnet;
  bool sink = shm && shmNoRead;   // SHM-like stream that nobody reads: the writer frees its own slots
  uint4* send = sendAll + (size_t)b*SLOTS*LINES;
  const uint4* recv = (shm ? recvShm : recvNet) + (size_t)b*SLOTS*LINES;
  for (int s = 0; s < steps; s++) {
    if (threadIdx.x == 0) while (c->head[b*8] + SLOTS <= (uint64_t)s) {}
    __syncthreads();
    uint4* slot = send + (size_t)(s % SLOTS)*LINES;
    int rs = s - 1; const uint4* rslot = recv + (size_t)((rs < 0 ? 0 : rs) % SLOTS)*LINES;
    for (int l = threadIdx.x; l < LINES; l += blockDim.x) {
      uint32_t acc = 0;
      if (rs >= 0 && !sink) { uint4 v; do { asm volatile("ld.volatile.global.v4.u32 {%0,%1,%2,%3}, [%4];" : "=r"(v.x), "=r"(v.y), "=r"(v.z), "=r"(v.w) : "l"(rslot + l) : "memory"); } while (v.y != (uint32_t)(rs+1) || v.w != (uint32_t)(rs+1)); acc = v.x; }
      slot[l] = make_uint4(acc + 1, s+1, acc + 1, s+1);
    }
    __syncthreads();
    if (threadIdx.x == 0) {
      __threadfence_system(); c->tail[b*8] = s + 1;
      if (sink) c->head[b*8] = s + 1;
      else if (shm && rs >= 0) prevc->head[b*8] = rs + 1;   // consumed the previous GPU's SHM slot rs
    }
  }
  if (shm && !sink && threadIdx.x == 0) prevc->head[b*8] = steps;
}
struct Gpu { uint4 *send, *recv, *dsend, *drecv; Ctl* c; Ctl* dc; fid_ep* ep; fid_cq* cq; fid_mr *mrs, *mrr; fi_addr_t peer; uint64_t rkey; cudaStream_t st; };
int main(int argc, char** argv) {
  int n = atoi(argv[1]), C = atoi(argv[2]), steps = atoi(argv[3]); int NC = atoi(argv[4]); int NNET = atoi(argv[5]); int shmNoRead = getenv("CLIFF_SHM_NOREAD") ? atoi(getenv("CLIFF_SHM_NOREAD")) : 0; int cachedConns = getenv("CLIFF_CACHED_CONNS") ? atoi(getenv("CLIFF_CACHED_CONNS")) : 1 << 30; int flush = getenv("CLIFF_FLUSH") ? atoi(getenv("CLIFF_FLUSH")) : 0; const char* dom = argc > 6 ? argv[6] : "rdmap83s0-rdm";
  fi_info* h = fi_allocinfo(); h->caps = FI_RMA | FI_LOCAL_COMM | FI_REMOTE_COMM; h->mode = FI_CONTEXT | FI_CONTEXT2 | FI_RX_CQ_DATA; h->ep_attr->type = FI_EP_RDM;
  h->fabric_attr->prov_name = strdup("efa"); h->fabric_attr->name = strdup("efa-direct"); h->domain_attr->name = strdup(dom);
  h->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY | FI_MR_HMEM;
  fi_info* fi; CK(fi_getinfo(FI_VERSION(2, 0), NULL, NULL, 0, h, &fi));
  fid_fabric* fab; fid_domain* domn; fid_av* av; CK(fi_fabric(fi->fabric_attr, &fab, NULL)); CK(fi_domain(fab, fi, &domn, NULL));
  fi_av_attr ava = {}; ava.type = FI_AV_TABLE; CK(fi_av_open(domn, &ava, &av, NULL));
  std::vector<Gpu> g(n); std::vector<fi_addr_t> addrs(n);
  for (int i = 0; i < n; i++) {
    cudaSetDevice(i); cudaStreamCreate(&g[i].st);
    cudaHostAlloc(&g[i].send, (size_t)NC*SLOTS*STEPB, cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&g[i].dsend, g[i].send, 0);
    cudaHostAlloc(&g[i].recv, (size_t)NC*SLOTS*STEPB, cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&g[i].drecv, g[i].recv, 0); memset(g[i].recv, 0, (size_t)NC*SLOTS*STEPB);
    cudaHostAlloc(&g[i].c, sizeof(Ctl), cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&g[i].dc, g[i].c, 0); memset((void*)g[i].c, 0, sizeof(Ctl));
    fi_cq_attr cqa = {}; cqa.format = FI_CQ_FORMAT_CONTEXT; CK(fi_cq_open(domn, &cqa, &g[i].cq, NULL));
    CK(fi_endpoint(domn, fi, &g[i].ep, NULL)); CK(fi_ep_bind(g[i].ep, &g[i].cq->fid, FI_TRANSMIT | FI_RECV)); CK(fi_ep_bind(g[i].ep, &av->fid, 0)); CK(fi_enable(g[i].ep));
    char a[64]; size_t al = sizeof(a); CK(fi_getname(&g[i].ep->fid, a, &al)); if (fi_av_insert(av, a, 1, &addrs[i], 0, NULL) != 1) { fprintf(stderr, "av_insert\n"); return 1; }
    CK(fi_mr_reg(domn, g[i].send, (size_t)NC*SLOTS*STEPB, FI_WRITE | FI_READ | FI_REMOTE_READ, 0, 0, 0, &g[i].mrs, NULL));
    CK(fi_mr_reg(domn, g[i].recv, (size_t)NC*SLOTS*STEPB, FI_REMOTE_WRITE, 0, 0, 0, &g[i].mrr, NULL));
  }
  for (int i = 0; i < n; i++) { int nx = (i + 1) % n; g[i].peer = addrs[nx]; g[i].rkey = fi_mr_key(g[nx].mrr); }
  struct Req { fi_context2 ctx; int b; int s; };
  std::vector<std::thread> px;
  for (int i = 0; i < n; i++) px.emplace_back([&, i] {
    Gpu& G = g[i]; int nx = (i + 1) % n; int core = (i < 4 ? 8 + i : 104 + i);
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(core, &cs); sched_setaffinity(0, sizeof(cs), &cs);
    std::vector<Req> rq(NC*SLOTS); std::vector<char> fin(NC*SLOTS, 0); std::vector<int> posted(NC, 0), done(NC, 0); int total = 0; volatile uint64_t sink = 0;
    while (total < NNET*steps) {
      for (int b = 0; b < NNET; b++) {
        int s = posted[b];
        if (s < steps && s < done[b] + SLOTS && G.c->tail[b*8] >= (uint64_t)s + 1) {
          size_t off = ((size_t)b*SLOTS + s % SLOTS)*STEPB; volatile uint32_t* sl = (volatile uint32_t*)((char*)G.send + off);
          if (C > 0 && b < cachedConns) { int stride = 1024 / C; for (int j = 0; j < C; j++) sink += sl[(size_t)j*stride*16];
            if (flush) { for (int j = 0; j < C; j++) asm volatile("clflushopt (%0)" :: "r"(sl + (size_t)j*stride*16) : "memory"); asm volatile("sfence" ::: "memory"); } }
          Req* r0 = &rq[b*SLOTS + s % SLOTS]; r0->b = b; r0->s = s; ssize_t r;
          while ((r = fi_write(G.ep, (char*)G.send + off, STEPB, fi_mr_desc(G.mrs), G.peer, (uint64_t)((char*)g[nx].recv + off), G.rkey, &r0->ctx)) == -FI_EAGAIN) fi_cq_read(G.cq, NULL, 0);
          if (r) { fprintf(stderr, "fi_write %zd\n", r); exit(1); }
          posted[b]++;
        }
      }
      fi_cq_entry e[16]; ssize_t m = fi_cq_read(G.cq, e, 16);
      if (m > 0) for (int j = 0; j < m; j++) { Req* q = (Req*)e[j].op_context; fin[q->b*SLOTS + q->s % SLOTS] = 1; }
      else if (m < 0 && m != -FI_EAGAIN) { fi_cq_err_entry ee = {}; fi_cq_readerr(G.cq, &ee, 0); fprintf(stderr, "cq err %d\n", ee.err); exit(1); }
      for (int b = 0; b < NNET; b++) while (done[b] < posted[b] && fin[b*SLOTS + done[b] % SLOTS]) { fin[b*SLOTS + done[b] % SLOTS] = 0; done[b]++; total++; G.c->head[b*8] = done[b]; }
    }
  });
  std::vector<cudaEvent_t> ea(n), eb(n);
  for (int i = 0; i < n; i++) { cudaSetDevice(i); cudaEventCreate(&ea[i]); cudaEventCreate(&eb[i]); cudaEventRecord(ea[i], g[i].st); int pv = (i + n - 1) % n; k<<<NC, 512, 0, g[i].st>>>(g[i].dsend, g[i].drecv, g[pv].dsend, g[i].dc, g[pv].dc, steps, NNET, shmNoRead); cudaEventRecord(eb[i], g[i].st); }
  float mx = 0; for (int i = 0; i < n; i++) { cudaSetDevice(i); cudaEventSynchronize(eb[i]); float ms; cudaEventElapsedTime(&ms, ea[i], eb[i]); if (ms > mx) mx = ms; }
  for (auto& t : px) t.join();
  printf("[cliff7] shmNoRead=%d nnet=%d cachedConns=%d flush=%d ngpu=%d nconn=%d C=%d steps=%d -> %.2f us/step\n", shmNoRead, NNET, cachedConns > NC ? NC : cachedConns, flush, n, NC, C, steps, mx*1000/steps);
  return 0;
}
