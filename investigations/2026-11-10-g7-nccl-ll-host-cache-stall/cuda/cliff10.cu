// cliff10: cliff9 with one process per GPU (as NCCL runs one rank per GPU). mpirun -np 4 -N 2: ranks 0,1 = A0,A1
// on node 0 and ranks 2,3 = B0,B1 on node 1. Each process puts its send ring and control block in POSIX shared memory
// (shm_open + mmap + cudaHostRegister) so the local neighbour process can poll it and return slots; the recv ring
// for EFA writes stays private. Each process owns its own EFA fabric/domain/endpoint.
// usage: cliff10 <C> <steps> [domain]
// (derived from) cliff9: NCCL-free LL repro across two real nodes (EFA leaves the host).
// Two MPI ranks (one per node), each driving local GPUs 0 and 1: A0,A1 on rank 0 and B0,B1 on rank 1.
// Four channels per GPU. Channels 0,2 run the ring A0 -> B0 -> B1 -> A1 -> A0, channels 1,3 run it backwards
// (A0 -> A1 -> B1 -> B0 -> A0), so every GPU has two inter-node (net) and two intra-node (shm) send channels.
//   net hop: the sender's proxy thread waits for the step, reads C cache lines of the slot (leaving CPU-cached
//            copies), then RDMA-writes the 64 KiB slot with efa-direct into the remote GPU's recv ring.
//   shm hop: the next GPU polls the sender's send ring in host memory directly and returns the slot via head.
// Each block writes 16 B LL lines (data, flag, data, flag); line l of step s is "value read from the incoming
// line l of step s-1, plus 1", as an LL receiver/sender does.
// env: CLIFF_FLUSH=1 clflushopt the lines the proxy read; CLIFF_SHM_NOREAD=1 shm hops are not read by anyone.
// usage (mpirun -np 2 -N 1): cliff9 <C cached lines per step 0..1024> <steps> [domain]
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>
#include <algorithm>
#include <unistd.h>
#include <sched.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <mpi.h>
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
#define NCH 4
#define NLG 1
#define CK(x) do { int _r = (x); if (_r) { fprintf(stderr, "%s failed: %d %s\n", #x, _r, fi_strerror(-_r)); exit(1); } } while (0)
struct Ctl { volatile uint64_t tail[NCH*8]; volatile uint64_t head[NCH*8]; };
// Global GPU ids: 0=A0 1=A1 (rank 0), 2=B0 3=B1 (rank 1).
static const int ringFwd[4] = {0, 2, 3, 1};   // A0 B0 B1 A1
static const int ringBwd[4] = {0, 1, 3, 2};   // A0 A1 B1 B0
static int nextOf(int ch, int gid) { const int* r = (ch % 2 == 0) ? ringFwd : ringBwd; for (int i = 0; i < 4; i++) if (r[i] == gid) return r[(i + 1) % 4]; return -1; }
static int prevOf(int ch, int gid) { const int* r = (ch % 2 == 0) ? ringFwd : ringBwd; for (int i = 0; i < 4; i++) if (r[i] == gid) return r[(i + 3) % 4]; return -1; }
static int nodeOf(int gid) { return gid / 2; }

struct BlockArgs { const uint4* in[NCH]; Ctl* prevCtl[NCH]; int inShm[NCH]; int sink[NCH]; };
__device__ __forceinline__ uint64_t gtime() { uint64_t t; asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(t)); return t; }
__global__ void k(uint4* sendAll, Ctl* c, BlockArgs a, int steps, uint64_t* ts) {
  int b = blockIdx.x;
  uint4* send = sendAll + (size_t)b*SLOTS*LINES; const uint4* in = a.in[b];
  for (int s = 0; s < steps; s++) {
    if (threadIdx.x == 0) while (c->head[b*8] + SLOTS <= (uint64_t)s) {}
    __syncthreads();
    uint4* slot = send + (size_t)(s % SLOTS)*LINES;
    int rs = s - 1; const uint4* rslot = in + (size_t)((rs < 0 ? 0 : rs) % SLOTS)*LINES;
    if (a.sink[b]) { if (threadIdx.x == 0 && rs >= 0) while (a.prevCtl[b]->tail[b*8] < (uint64_t)rs + 1) {} __syncthreads(); }
    for (int l = threadIdx.x; l < LINES; l += blockDim.x) {
      uint32_t acc = 0;
      if (rs >= 0 && !a.sink[b]) { uint4 v; do { asm volatile("ld.volatile.global.v4.u32 {%0,%1,%2,%3}, [%4];" : "=r"(v.x), "=r"(v.y), "=r"(v.z), "=r"(v.w) : "l"(rslot + l) : "memory"); } while (v.y != (uint32_t)(rs+1) || v.w != (uint32_t)(rs+1)); acc = v.x; }
      slot[l] = make_uint4(acc + 1, s+1, acc + 1, s+1);
    }
    __threadfence_system();
    __syncthreads();
    if (threadIdx.x == 0) {
      c->tail[b*8] = s + 1; ts[(size_t)b*steps + s] = gtime();
      if (a.inShm[b] && rs >= 0) a.prevCtl[b]->head[b*8] = rs + 1;
    }
  }
  if (a.inShm[b] && threadIdx.x == 0) a.prevCtl[b]->head[b*8] = steps;
}

struct Peer { char epname[64]; size_t eplen; uint64_t recvVa; uint64_t recvKey; };
int main(int argc, char** argv) {
  MPI_Init(&argc, &argv); int rank, np; MPI_Comm_rank(MPI_COMM_WORLD, &rank); MPI_Comm_size(MPI_COMM_WORLD, &np);
  if (np != 4) { fprintf(stderr, "needs exactly 4 ranks (2 per node)\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
  int gid = rank, node = nodeOf(gid), localGpu = gid % 2;
  int C = atoi(argv[1]), steps = atoi(argv[2]); const char* dom = argc > 3 ? argv[3] : "rdmap83s0-rdm";
  int flush = getenv("CLIFF_FLUSH") ? atoi(getenv("CLIFF_FLUSH")) : 0;
  int shmNoRead = getenv("CLIFF_SHM_NOREAD") ? atoi(getenv("CLIFF_SHM_NOREAD")) : 0;
  size_t ringB = (size_t)NCH*SLOTS*STEPB, ctlB = 4096 * ((sizeof(Ctl) + 4095) / 4096);
  cudaSetDevice(localGpu); cudaFree(0);
  // shared send ring + control block of this process
  char nm[64]; snprintf(nm, sizeof(nm), "/cliff10_%d_%d", getpid(), gid);
  int fd = shm_open(nm, O_CREAT | O_RDWR, 0600); if (fd < 0 || ftruncate(fd, ringB + ctlB)) { perror("shm"); MPI_Abort(MPI_COMM_WORLD, 1); }
  char* base = (char*)mmap(NULL, ringB + ctlB, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (base == MAP_FAILED) { perror("mmap"); MPI_Abort(MPI_COMM_WORLD, 1); }
  memset(base, 0, ringB + ctlB);
  for (size_t o = 0; o < ringB + ctlB; o += 64) asm volatile("clflushopt (%0)" :: "r"(base + o));
  asm volatile("sfence" ::: "memory");
  if (cudaHostRegister(base, ringB + ctlB, cudaHostRegisterMapped | cudaHostRegisterPortable) != cudaSuccess) { fprintf(stderr, "cudaHostRegister own\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
  uint4* send0 = (uint4*)base; Ctl* ctl0 = (Ctl*)(base + ringB);
  uint4* dsend0; Ctl* dctl0; cudaHostGetDevicePointer(&dsend0, send0, 0); cudaHostGetDevicePointer(&dctl0, ctl0, 0);
  uint4* recv0; cudaHostAlloc(&recv0, ringB, cudaHostAllocMapped); memset(recv0, 0, ringB);
  for (size_t o = 0; o < ringB; o += 64) asm volatile("clflushopt (%0)" :: "r"((char*)recv0 + o));
  asm volatile("sfence" ::: "memory");
  uint4* drecv0; cudaHostGetDevicePointer(&drecv0, recv0, 0);
  // EFA, per process
  fi_info* h = fi_allocinfo(); h->caps = FI_RMA | FI_LOCAL_COMM | FI_REMOTE_COMM; h->mode = FI_CONTEXT | FI_CONTEXT2 | FI_RX_CQ_DATA; h->ep_attr->type = FI_EP_RDM;
  h->fabric_attr->prov_name = strdup("efa"); h->fabric_attr->name = strdup("efa-direct"); h->domain_attr->name = strdup(dom);
  h->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY | FI_MR_HMEM;
  fi_info* fi; CK(fi_getinfo(FI_VERSION(2, 0), NULL, NULL, 0, h, &fi));
  fid_fabric* fab; fid_domain* domn; fid_av* av; CK(fi_fabric(fi->fabric_attr, &fab, NULL)); CK(fi_domain(fab, fi, &domn, NULL));
  fi_av_attr ava = {}; ava.type = FI_AV_TABLE; CK(fi_av_open(domn, &ava, &av, NULL));
  fid_ep* ep0; fid_cq* cq0; fid_mr *mrs0, *mrr0;
  fi_cq_attr cqa = {}; cqa.format = FI_CQ_FORMAT_CONTEXT; CK(fi_cq_open(domn, &cqa, &cq0, NULL));
  CK(fi_endpoint(domn, fi, &ep0, NULL)); CK(fi_ep_bind(ep0, &cq0->fid, FI_TRANSMIT | FI_RECV)); CK(fi_ep_bind(ep0, &av->fid, 0)); CK(fi_enable(ep0));
  CK(fi_mr_reg(domn, send0, ringB, FI_WRITE | FI_READ | FI_REMOTE_READ, 0, 0, 0, &mrs0, NULL));
  CK(fi_mr_reg(domn, recv0, ringB, FI_REMOTE_WRITE, 0, 0, 0, &mrr0, NULL));
  struct Info { Peer p; char shm[64]; } my = {}, info[4];
  my.p.eplen = sizeof(my.p.epname); CK(fi_getname(&ep0->fid, my.p.epname, &my.p.eplen)); my.p.recvVa = (uint64_t)recv0; my.p.recvKey = fi_mr_key(mrr0);
  strncpy(my.shm, nm, sizeof(my.shm) - 1);
  MPI_Allgather(&my, sizeof(my), MPI_BYTE, info, sizeof(my), MPI_BYTE, MPI_COMM_WORLD);
  Peer all[4]; for (int g = 0; g < 4; g++) all[g] = info[g].p;
  fi_addr_t addr[4];
  for (int g = 0; g < 4; g++) if (fi_av_insert(av, all[g].epname, 1, &addr[g], 0, NULL) != 1) { fprintf(stderr, "av_insert %d\n", g); MPI_Abort(MPI_COMM_WORLD, 1); }
  // attach the local neighbour's shared send ring + control block
  int nb = node*2 + (1 - localGpu);
  int fd2 = shm_open(info[nb].shm, O_RDWR, 0600); if (fd2 < 0) { perror("shm_open neighbour"); MPI_Abort(MPI_COMM_WORLD, 1); }
  char* nbase = (char*)mmap(NULL, ringB + ctlB, PROT_READ | PROT_WRITE, MAP_SHARED, fd2, 0); if (nbase == MAP_FAILED) { perror("mmap neighbour"); MPI_Abort(MPI_COMM_WORLD, 1); }
  if (cudaHostRegister(nbase, ringB + ctlB, cudaHostRegisterMapped | cudaHostRegisterPortable) != cudaSuccess) { fprintf(stderr, "cudaHostRegister neighbour\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
  uint4* dnsend; Ctl* dnctl; cudaHostGetDevicePointer(&dnsend, (uint4*)nbase, 0); cudaHostGetDevicePointer(&dnctl, (Ctl*)(nbase + ringB), 0);
  MPI_Barrier(MPI_COMM_WORLD); shm_unlink(nm);
  // arrays expected by the rest of the (cliff9) code, with one local GPU
  uint4 *send[NLG] = {send0}, *dsend[NLG] = {dsend0}; Ctl *ctl[NLG] = {ctl0}, *dctl[NLG] = {dctl0};
  fid_ep* ep[NLG] = {ep0}; fid_cq* cq[NLG] = {cq0}; fid_mr* mrs[NLG] = {mrs0}; cudaStream_t st[NLG]; cudaStreamCreate(&st[0]);
  BlockArgs args[NLG]; int netOut[NLG][NCH]; int nextG[NLG][NCH];
  for (int ch = 0; ch < NCH; ch++) {
    int nx = nextOf(ch, gid), pv = prevOf(ch, gid);
    nextG[0][ch] = nx; netOut[0][ch] = nodeOf(nx) != node;
    int inShm = nodeOf(pv) == node;
    args[0].inShm[ch] = inShm; args[0].sink[ch] = inShm && shmNoRead;
    if (inShm) { args[0].in[ch] = dnsend + (size_t)ch*SLOTS*LINES; args[0].prevCtl[ch] = dnctl; }
    else { args[0].in[ch] = drecv0 + (size_t)ch*SLOTS*LINES; args[0].prevCtl[ch] = nullptr; }
  }
  (void)np;
  struct Req { fi_context2 ctx; int ch; int s; };
  std::vector<std::thread> px;
  for (int lg = 0; lg < NLG; lg++) px.emplace_back([&, lg] {
    int core = 8 + gid % 2; cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(core, &cs);
    if (sched_setaffinity(0, sizeof(cs), &cs)) { perror("sched_setaffinity"); exit(1); }
    std::vector<Req> rq(NCH*SLOTS); std::vector<char> fin(NCH*SLOTS, 0); std::vector<int> posted(NCH, 0), done(NCH, 0);
    int work = 0; for (int ch = 0; ch < NCH; ch++) if (netOut[lg][ch]) work += steps;
    int total = 0; volatile uint64_t sink = 0;
    while (total < work) {
      for (int ch = 0; ch < NCH; ch++) {
        int s = posted[ch];
        if (!netOut[lg][ch]) continue;
        if (s < steps && s < done[ch] + SLOTS && ctl[lg]->tail[ch*8] >= (uint64_t)s + 1) {
          size_t off = ((size_t)ch*SLOTS + s % SLOTS)*STEPB; volatile uint32_t* sl = (volatile uint32_t*)((char*)send[lg] + off);
          if (C > 0) { int stride = 1024 / C; for (int j = 0; j < C; j++) sink += sl[(size_t)j*stride*16];
            if (flush) { for (int j = 0; j < C; j++) asm volatile("clflushopt (%0)" :: "r"(sl + (size_t)j*stride*16) : "memory"); asm volatile("sfence" ::: "memory"); } }
          int nx = nextG[lg][ch]; Req* r0 = &rq[ch*SLOTS + s % SLOTS]; r0->ch = ch; r0->s = s; ssize_t r;
          while ((r = fi_write(ep[lg], (char*)send[lg] + off, STEPB, fi_mr_desc(mrs[lg]), addr[nx], all[nx].recvVa + off, all[nx].recvKey, &r0->ctx)) == -FI_EAGAIN) fi_cq_read(cq[lg], NULL, 0);
          if (r) { fprintf(stderr, "fi_write %zd\n", r); exit(1); }
          posted[ch]++;
        }
      }
      fi_cq_entry e[16]; ssize_t m = fi_cq_read(cq[lg], e, 16);
      if (m > 0) for (int j = 0; j < m; j++) { Req* q = (Req*)e[j].op_context; fin[q->ch*SLOTS + q->s % SLOTS] = 1; }
      else if (m < 0 && m != -FI_EAGAIN) { fi_cq_err_entry ee = {}; fi_cq_readerr(cq[lg], &ee, 0); fprintf(stderr, "cq err %d\n", ee.err); exit(1); }
      for (int ch = 0; ch < NCH; ch++) if (netOut[lg][ch]) while (done[ch] < posted[ch] && fin[ch*SLOTS + done[ch] % SLOTS]) { fin[ch*SLOTS + done[ch] % SLOTS] = 0; done[ch]++; total++; ctl[lg]->head[ch*8] = done[ch]; }
    }
  });

  uint64_t* ts[NLG]; uint64_t* dts[NLG];
  for (int lg = 0; lg < NLG; lg++) { cudaHostAlloc(&ts[lg], (size_t)NCH*steps*8, cudaHostAllocMapped | cudaHostAllocPortable); cudaHostGetDevicePointer(&dts[lg], ts[lg], 0); }
  MPI_Barrier(MPI_COMM_WORLD);
  cudaEvent_t ea[NLG], eb[NLG];
  for (int lg = 0; lg < NLG; lg++) { cudaSetDevice(localGpu); cudaEventCreate(&ea[lg]); cudaEventCreate(&eb[lg]); cudaEventRecord(ea[lg], st[lg]); k<<<NCH, 512, 0, st[lg]>>>(dsend[lg], dctl[lg], args[lg], steps, dts[lg]); cudaEventRecord(eb[lg], st[lg]); }
  float mx = 0; for (int lg = 0; lg < NLG; lg++) { cudaSetDevice(localGpu); cudaEventSynchronize(eb[lg]); float ms; cudaEventElapsedTime(&ms, ea[lg], eb[lg]); if (ms > mx) mx = ms; }
  for (auto& t : px) t.join();
  std::vector<float> d;
  for (int lg = 0; lg < NLG; lg++) for (int b = 0; b < NCH; b++) for (int s2 = 21; s2 < steps; s2++) d.push_back((ts[lg][(size_t)b*steps + s2] - ts[lg][(size_t)b*steps + s2 - 1]) / 1000.0f);
  int nd = d.size(); std::vector<float> gath(nd*4);
  MPI_Gather(d.data(), nd, MPI_FLOAT, gath.data(), nd, MPI_FLOAT, 0, MPI_COMM_WORLD);
  float gmx; MPI_Reduce(&mx, &gmx, 1, MPI_FLOAT, MPI_MAX, 0, MPI_COMM_WORLD);
  if (rank == 0) {
    std::sort(gath.begin(), gath.end()); size_t N = gath.size(); size_t slow = 0; for (float x : gath) if (x > 100) slow++;
    printf("[cliff10] 2node 1proc/GPU C=%d flush=%d shmNoRead=%d steps=%d -> %.2f us/step | per-step p50=%.1f p90=%.1f p99=%.1f max=%.1f us, steps>100us=%.1f%%\n",
           C, flush, shmNoRead, steps, gmx*1000/steps, gath[N/2], gath[N*9/10], gath[N*99/100], gath[N-1], 100.0*slow/N);
  }
  fflush(stdout); MPI_Barrier(MPI_COMM_WORLD);
  _exit(0);   // skip MPI_Finalize: it hangs with live efa-direct endpoints
}
