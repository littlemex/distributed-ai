import sys
# variant r: like q (GPU publishes size after writing, proxy still reads lines afterwards) but the proxy
# reads only one LL line out of every NCCL_LLSCAN_STRIDE_CL cache lines (4 LL lines per 64 B cache line).
# Tests whether the slowdown scales with the number of CPU-cached lines the GPU later overwrites.
p = sys.argv[1]; s = open(p).read()
old = """            for (int i=0; i<nFifoLines; i++) {
              volatile uint32_t *f1 = &lines[i].flag1;"""
new = """            static const int strideLines = 4 * (getenv("NCCL_LLSCAN_STRIDE_CL") ? atoi(getenv("NCCL_LLSCAN_STRIDE_CL")) : 1);
            for (int i=0; i<nFifoLines; i+= (llReady ? strideLines : 1)) {
              volatile uint32_t *f1 = &lines[i].flag1;"""
assert s.count(old) == 1; s = s.replace(old, new)
open(p, "w").write(s); print("patched")
