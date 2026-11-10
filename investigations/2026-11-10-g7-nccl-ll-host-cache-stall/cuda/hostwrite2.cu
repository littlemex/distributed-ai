// GPU store into pinned host memory after N CPU cores each read a slice of it.
// usage: hostwrite2 <bytes> <iters> <nreaders> <first_core>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <thread>
#include <vector>
#include <sched.h>
#include <cuda_runtime.h>
__global__ void wr(uint4* p, size_t n, uint32_t v) {
  for (size_t i = blockIdx.x*blockDim.x+threadIdx.x; i < n; i += gridDim.x*blockDim.x) p[i] = make_uint4(v, v, v, v);
}
static void rd(volatile uint32_t* q, size_t words, int core, uint32_t* out) {
  cpu_set_t s; CPU_ZERO(&s); CPU_SET(core, &s); sched_setaffinity(0, sizeof(s), &s);
  uint32_t x = 0; for (size_t i = 0; i < words; i += 16) x += q[i]; *out = x;
}
int main(int argc, char** argv) {
  size_t bytes = atol(argv[1]); int iters = atoi(argv[2]); int nr = atoi(argv[3]); int c0 = atoi(argv[4]);
  uint4* h; cudaHostAlloc(&h, bytes, cudaHostAllocMapped); uint4* d; cudaHostGetDevicePointer(&d, h, 0);
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b); std::vector<uint32_t> sink(nr + 1);
  float tot = 0;
  for (int it = 0; it < iters + 3; it++) {
    if (nr > 0) {
      std::vector<std::thread> th; size_t per = bytes / 4 / nr;
      for (int r = 0; r < nr; r++) th.emplace_back(rd, (volatile uint32_t*)h + r*per, per, c0 + r, &sink[r]);
      for (auto& t : th) t.join();
    }
    cudaEventRecord(a); wr<<<64, 512>>>(d, bytes/16, it); cudaEventRecord(b); cudaEventSynchronize(b);
    float ms; cudaEventElapsedTime(&ms, a, b); if (it >= 3) tot += ms;
  }
  printf("bytes=%zu readers=%d avg=%.1f us (%.1f GB/s)\n", bytes, nr, tot/iters*1e3, bytes/(tot/iters*1e-3)/1e9);
  return 0;
}
