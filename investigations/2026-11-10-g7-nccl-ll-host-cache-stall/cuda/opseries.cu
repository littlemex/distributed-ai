// Time every single all-reduce (one process per node, 8 GPUs per process) to see whether the
// slow state is entered and left within a run.  usage: opseries <bytes> <iters> <outfile>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <mpi.h>
#include <nccl.h>
#include <cuda_runtime.h>
#define NG 8
int main(int argc, char** argv) {
  MPI_Init(&argc, &argv); int rank, nproc; MPI_Comm_rank(MPI_COMM_WORLD, &rank); MPI_Comm_size(MPI_COMM_WORLD, &nproc);
  size_t bytes = atol(argv[1]); int iters = atoi(argv[2]);
  ncclUniqueId id; if (rank == 0) ncclGetUniqueId(&id); MPI_Bcast(&id, sizeof(id), MPI_BYTE, 0, MPI_COMM_WORLD);
  ncclComm_t comm[NG]; cudaStream_t st[NG]; float* buf[NG]; cudaEvent_t e0, e1;
  ncclGroupStart();
  for (int g = 0; g < NG; g++) { cudaSetDevice(g); cudaStreamCreate(&st[g]); cudaMalloc(&buf[g], bytes); cudaMemset(buf[g], 0, bytes);
    ncclCommInitRank(&comm[g], nproc*NG, id, rank*NG + g); }
  ncclGroupEnd();
  cudaSetDevice(0); cudaEventCreate(&e0); cudaEventCreate(&e1);
  std::vector<float> t(iters);
  for (int i = 0; i < iters + 20; i++) {
    cudaSetDevice(0); cudaEventRecord(e0, st[0]);
    ncclGroupStart(); for (int g = 0; g < NG; g++) ncclAllReduce(buf[g], buf[g], bytes/4, ncclFloat, ncclSum, comm[g], st[g]); ncclGroupEnd();
    cudaSetDevice(0); cudaEventRecord(e1, st[0]);
    for (int g = 0; g < NG; g++) { cudaSetDevice(g); cudaStreamSynchronize(st[g]); }
    float ms; cudaEventElapsedTime(&ms, e0, e1); if (i >= 20) t[i-20] = ms*1000;
  }
  if (rank == 0) { FILE* f = fopen(argv[3], "w"); for (float x : t) fprintf(f, "%.1f\n", x); fclose(f); }
  for (int g = 0; g < NG; g++) ncclCommDestroy(comm[g]);
  MPI_Finalize(); return 0;
}
