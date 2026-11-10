// Does a GPU's host-memory read wait behind its own stalled writes?
// Writer blocks store W bytes into host region H (optionally CPU-read just before -> cached copies).
// One reader block (thread 0) does dependent volatile loads from a separate host region R and
// records each load's latency with %globaltimer. Reported: median/p90/max load latency (ns).
// usage: rdlat <write_bytes> <cpu_read_H:0|1> <writers_on:0|1> <iters>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#define NL 4096
__device__ __forceinline__ uint64_t gt() { uint64_t t; asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(t)); return t; }
__global__ void k(uint4* H, size_t n, volatile uint32_t* R, uint32_t* lat, int writers, volatile int* go, uint32_t* cnt, unsigned int* doneBlocks) {
  int nb = gridDim.x - 1;
  if (blockIdx.x == 0) {
    if (threadIdx.x == 0) {
      while (*go == 0) {}
      uint32_t idx = 0; int i = 0;
      do { uint64_t t0 = gt();
           #pragma unroll 1
           for (int j = 0; j < 8; j++) { uint32_t v; asm volatile("ld.volatile.global.u32 %0, [%1];" : "=r"(v) : "l"(R + ((idx + j*16 + i*128) & 0xFFFF)) : "memory"); idx += v; }
           lat[i] = (uint32_t)((gt() - t0) / 8); i++; }
      while (i < NL && (writers ? atomicAdd(doneBlocks, 0) < (unsigned)nb : i < 64));
      *cnt = i;
    }
    return;
  }
  if (threadIdx.x == 0 && blockIdx.x == 1) *go = 1;
  if (writers) for (size_t i = (blockIdx.x-1)*blockDim.x+threadIdx.x; i < n; i += (size_t)nb*blockDim.x) H[i] = make_uint4(7, 7, 7, 7);
  __syncthreads(); __threadfence();
  if (threadIdx.x == 0) atomicAdd(doneBlocks, 1);
}
int main(int argc, char** argv) {
  size_t W = atol(argv[1]); int cr = atoi(argv[2]); int wr = atoi(argv[3]); int it = atoi(argv[4]);
  uint4* H; cudaHostAlloc(&H, W, cudaHostAllocMapped); uint4* dH; cudaHostGetDevicePointer(&dH, H, 0);
  uint32_t* R; cudaHostAlloc(&R, 65536*4, cudaHostAllocMapped); for (int i = 0; i < 65536; i++) R[i] = 0; uint32_t* dR; cudaHostGetDevicePointer(&dR, R, 0);
  int* go; cudaHostAlloc(&go, 64, cudaHostAllocMapped); int* dgo; cudaHostGetDevicePointer(&dgo, go, 0);
  uint32_t* lat; cudaMalloc(&lat, NL*4); uint32_t* cnt; cudaMalloc(&cnt, 4); unsigned int* db; cudaMalloc(&db, 4); uint32_t hc; std::vector<uint32_t> all; std::vector<uint32_t> h(NL); volatile uint32_t s = 0;
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b); float tw = 0;
  for (int r = 0; r < it + 2; r++) {
    if (cr) { volatile uint32_t* q = (volatile uint32_t*)H; for (size_t i = 0; i < W/4; i += 16) s += q[i]; }
    *go = 0; cudaMemset(db, 0, 4);
    cudaEventRecord(a); k<<<1 + 16, 512>>>(dH, W/16, dR, lat, wr, dgo, cnt, db); cudaEventRecord(b); cudaEventSynchronize(b);
    float ms; cudaEventElapsedTime(&ms, a, b); cudaMemcpy(h.data(), lat, NL*4, cudaMemcpyDeviceToHost); cudaMemcpy(&hc, cnt, 4, cudaMemcpyDeviceToHost);
    if (r >= 2) { all.insert(all.end(), h.begin(), h.begin()+hc); tw += ms; }
  }
  std::sort(all.begin(), all.end()); size_t N = all.size();
  printf("samples=%zu W=%zu cpu_read=%d writers=%d kernel=%.1f us | read latency ns: p50=%u p90=%u p99=%u max=%u\n", N, W, cr, wr, tw/it*1e3, all[N/2], all[N*9/10], all[N*99/100], all[N-1]);
  return 0;
}
