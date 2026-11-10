// Emulates the LL send side without NCCL to locate the "cached lines" cliff.
// GPU: one 512-thread block per connection writes a 64 KiB step (4096 x 16 B lines, 8 per thread) into an
//      8-slot ring in pinned host memory, then fences and publishes the step (tail).  With rd=1 each thread
//      first reads one 16 B line from a separate host "recv" region before each store, like an LL receiver.
// CPU: one proxy thread per process waits for each step, reads C cache lines of the slot (spread evenly),
//      then frees the slot (head).
// usage: cliff <nconn> <C cached lines per step (0..1024)> <rd 0|1> <steps> <proxy_core>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <thread>
#include <atomic>
#include <sched.h>
#include <cuda_runtime.h>
#define SLOTS 8
#define STEPB 65536
#define LINES (STEPB/16)
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
  int nconn = atoi(argv[1]), C = atoi(argv[2]), rd = atoi(argv[3]), steps = atoi(argv[4]), core = atoi(argv[5]);
  uint4* ring; cudaHostAlloc(&ring, (size_t)nconn*SLOTS*STEPB, cudaHostAllocMapped);
  uint4* recv; cudaHostAlloc(&recv, (size_t)nconn*STEPB, cudaHostAllocMapped);
  Ctl* c; cudaHostAlloc(&c, sizeof(Ctl), cudaHostAllocMapped); for (int i = 0; i < 64; i++) { c->tail[i] = 0; c->head[i] = 0; }
  uint4 *dring, *drecv; Ctl* dc; cudaHostGetDevicePointer(&dring, ring, 0); cudaHostGetDevicePointer(&drecv, recv, 0); cudaHostGetDevicePointer(&dc, c, 0);
  std::atomic<int> stop{0}; volatile uint64_t sink = 0;
  std::thread proxy([&] {
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(core, &cs); sched_setaffinity(0, sizeof(cs), &cs);
    for (int s = 0; s < steps; s++) for (int cn = 0; cn < nconn; cn++) {
      while (c->tail[cn*8] < (uint64_t)s + 1) {}
      volatile uint32_t* sl = (volatile uint32_t*)(ring + ((size_t)cn*SLOTS + s % SLOTS)*LINES);
      if (C > 0) { int stride = 1024 / C; for (int i = 0; i < C; i++) sink += sl[(size_t)i*stride*16]; }
      c->head[cn*8] = s + 1;
    }
  });
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
  cudaEventRecord(a); k<<<nconn, 512>>>(dring, drecv, dc, steps, rd); cudaEventRecord(b); cudaEventSynchronize(b);
  proxy.join(); float ms; cudaEventElapsedTime(&ms, a, b);
  printf("nconn=%d C=%d rd=%d steps=%d -> %.2f us/step\n", nconn, C, rd, steps, ms*1000/steps);
  return 0;
}
