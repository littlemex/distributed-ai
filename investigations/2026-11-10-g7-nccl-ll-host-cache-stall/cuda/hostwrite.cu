// GPU store bandwidth into pinned host memory, with or without the CPU having just read it.
// usage: hostwrite <bytes> <iters> <cpu_read:0|1> <flush:0|1> <cpu_core>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <sched.h>
#include <immintrin.h>
#include <cuda_runtime.h>
__global__ void wr(uint4* p, size_t n, uint32_t v) {
  for (size_t i = blockIdx.x*blockDim.x+threadIdx.x; i < n; i += gridDim.x*blockDim.x)
    p[i] = make_uint4(v, v, v, v);
}
int main(int argc, char** argv) {
  size_t bytes = atol(argv[1]); int iters = atoi(argv[2]); int rd = atoi(argv[3]); int fl = atoi(argv[4]);
  cpu_set_t s; CPU_ZERO(&s); CPU_SET(atoi(argv[5]), &s); sched_setaffinity(0, sizeof(s), &s);
  uint4* h; cudaHostAlloc(&h, bytes, cudaHostAllocMapped); uint4* d; cudaHostGetDevicePointer(&d, h, 0);
  size_t n = bytes/16; cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
  volatile uint32_t sink = 0; float tot = 0; float mn = 1e9;
  for (int it = 0; it < iters + 3; it++) {
    if (rd) { volatile uint32_t* q = (volatile uint32_t*)h; for (size_t i = 0; i < bytes/4; i += 16) sink += q[i]; }
    if (fl) { for (size_t i = 0; i < bytes; i += 64) _mm_clflushopt((char*)h + i); _mm_sfence(); }
    cudaEventRecord(a); wr<<<64, 512>>>(d, n, it); cudaEventRecord(b); cudaEventSynchronize(b);
    float ms; cudaEventElapsedTime(&ms, a, b); if (it >= 3) { tot += ms; if (ms < mn) mn = ms; }
  }
  printf("bytes=%zu cpu_read=%d flush=%d avg=%.1f us min=%.1f us -> %.1f GB/s (avg)\n", bytes, rd, fl, tot/iters*1e3, mn*1e3, bytes/(tot/iters*1e-3)/1e9);
  return 0;
}
