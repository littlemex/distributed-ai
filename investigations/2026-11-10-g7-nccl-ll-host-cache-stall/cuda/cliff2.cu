// cliff.cu + the NIC reads every step: after the CPU proxy reads C cache lines of a slot, it RDMA-writes the
// 64 KiB slot with efa-direct to a buffer in the same process (so the EFA device reads the slot from host
// memory, as in NCCL's net send), waits for completion, then frees the slot.
// usage: cliff2 <nconn> <C> <rd 0|1> <steps> <proxy_core> <efa 0|1> [domain]
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <thread>
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
struct Ctl { volatile uint64_t tail[64]; volatile uint64_t head[64]; };
__global__ void k(uint4* ring, const uint4* recv, Ctl* c, int steps, int rd) {
  int conn = blockIdx.x; uint4* base = ring + (size_t)conn*SLOTS*LINES; uint32_t acc = 0;
  for (int s = 0; s < steps; s++) {
    if (threadIdx.x == 0) while (c->head[conn*8] + SLOTS <= (uint64_t)s) {}
    __syncthreads();
    uint4* slot = base + (size_t)(s % SLOTS)*LINES;
    for (int l = threadIdx.x; l < LINES; l += blockDim.x) {
      if (rd) { uint4 v; asm volatile("ld.volatile.global.v4.u32 {%0,%1,%2,%3}, [%4];" : "=r"(v.x), "=r"(v.y), "=r"(v.z), "=r"(v.w) : "l"(recv + conn*LINES + l) : "memory"); acc += v.x; }
      slot[l] = make_uint4(acc, s+1, acc, s+1);
    }
    __syncthreads();
    if (threadIdx.x == 0) { __threadfence_system(); c->tail[conn*8] = s + 1; }
  }
}
int main(int argc, char** argv) {
  int nconn = atoi(argv[1]), C = atoi(argv[2]), rd = atoi(argv[3]), steps = atoi(argv[4]), core = atoi(argv[5]), efa = atoi(argv[6]);
  const char* dom = argc > 7 ? argv[7] : "rdmap83s0-rdm";
  size_t ringB = (size_t)nconn*SLOTS*STEPB;
  uint4* ring; cudaHostAlloc(&ring, ringB, cudaHostAllocMapped);
  uint4* recv; cudaHostAlloc(&recv, (size_t)nconn*STEPB, cudaHostAllocMapped);
  char* dst = (char*)aligned_alloc(4096, ringB);
  Ctl* c; cudaHostAlloc(&c, sizeof(Ctl), cudaHostAllocMapped); for (int i = 0; i < 64; i++) { c->tail[i] = 0; c->head[i] = 0; }
  uint4 *dring, *drecv; Ctl* dc; cudaHostGetDevicePointer(&dring, ring, 0); cudaHostGetDevicePointer(&drecv, recv, 0); cudaHostGetDevicePointer(&dc, c, 0);
  fid_fabric* fab; fid_domain* domn; fid_ep* ep; fid_av* av; fid_cq* cq; fid_mr *mrs, *mrd; fi_addr_t self = 0; uint64_t rkey = 0;
  if (efa) {
    fi_info* h = fi_allocinfo(); h->caps = FI_RMA | FI_LOCAL_COMM | FI_REMOTE_COMM; h->mode = FI_CONTEXT | FI_CONTEXT2 | FI_RX_CQ_DATA; h->ep_attr->type = FI_EP_RDM;
    h->fabric_attr->prov_name = strdup("efa"); h->fabric_attr->name = strdup("efa-direct"); h->domain_attr->name = strdup(dom);
    h->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY | FI_MR_HMEM;
    fi_info* fi; CK(fi_getinfo(FI_VERSION(2, 0), NULL, NULL, 0, h, &fi));
    CK(fi_fabric(fi->fabric_attr, &fab, NULL)); CK(fi_domain(fab, fi, &domn, NULL));
    fi_cq_attr cqa = {}; cqa.format = FI_CQ_FORMAT_CONTEXT; CK(fi_cq_open(domn, &cqa, &cq, NULL));
    fi_av_attr ava = {}; ava.type = FI_AV_TABLE; CK(fi_av_open(domn, &ava, &av, NULL));
    CK(fi_endpoint(domn, fi, &ep, NULL)); CK(fi_ep_bind(ep, &cq->fid, FI_TRANSMIT | FI_RECV)); CK(fi_ep_bind(ep, &av->fid, 0)); CK(fi_enable(ep));
    char addr[64]; size_t al = sizeof(addr); CK(fi_getname(&ep->fid, addr, &al)); if (fi_av_insert(av, addr, 1, &self, 0, NULL) != 1) { fprintf(stderr, "av_insert\n"); return 1; }
    CK(fi_mr_reg(domn, ring, ringB, FI_WRITE | FI_READ | FI_REMOTE_READ, 0, 0, 0, &mrs, NULL));
    CK(fi_mr_reg(domn, dst, ringB, FI_REMOTE_WRITE, 0, 0, 0, &mrd, NULL)); rkey = fi_mr_key(mrd);
  }
  volatile uint64_t sink = 0; fi_context2 ctx;
  std::thread proxy([&] {
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(core, &cs); sched_setaffinity(0, sizeof(cs), &cs);
    for (int s = 0; s < steps; s++) for (int cn = 0; cn < nconn; cn++) {
      while (c->tail[cn*8] < (uint64_t)s + 1) {}
      size_t off = ((size_t)cn*SLOTS + s % SLOTS)*STEPB; volatile uint32_t* sl = (volatile uint32_t*)((char*)ring + off);
      if (C > 0) { int stride = 1024 / C; for (int i = 0; i < C; i++) sink += sl[(size_t)i*stride*16]; }
      if (efa) {
        ssize_t r; while ((r = fi_write(ep, (char*)ring + off, STEPB, fi_mr_desc(mrs), self, (uint64_t)(dst + off), rkey, &ctx)) == -FI_EAGAIN) fi_cq_read(cq, NULL, 0);
        if (r) { fprintf(stderr, "fi_write %zd\n", r); exit(1); }
        fi_cq_entry e; ssize_t n; while ((n = fi_cq_read(cq, &e, 1)) == -FI_EAGAIN) {}
        if (n < 0) { fi_cq_err_entry ee = {}; fi_cq_readerr(cq, &ee, 0); fprintf(stderr, "cq err %d\n", ee.err); exit(1); }
      }
      c->head[cn*8] = s + 1;
    }
  });
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
  cudaEventRecord(a); k<<<nconn, 512>>>(dring, drecv, dc, steps, rd); cudaEventRecord(b); cudaEventSynchronize(b);
  proxy.join(); float ms; cudaEventElapsedTime(&ms, a, b);
  printf("nconn=%d C=%d rd=%d efa=%d steps=%d -> %.2f us/step\n", nconn, C, rd, efa, steps, ms*1000/steps);
  return 0;
}
