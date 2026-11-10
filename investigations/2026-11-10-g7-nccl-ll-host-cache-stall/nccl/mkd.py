import sys
# variant d: base NCCL + scan counters + env NCCL_LLSCAN_BACKOFF_NS: after a failed LL scan of a slot,
# do not rescan that slot until the backoff has elapsed. Tests whether proxy re-polling amplifies the stall.
p = sys.argv[1]; s = open(p).read()
old = """            for (int i=0; i<nFifoLines; i++) {
              volatile uint32_t *f1 = &lines[i].flag1;
              volatile uint32_t *f2 = &lines[i].flag2;
              if (f1[0] != flag || f2[0] != flag) { ready = 0; break; }
            }
"""
new = """            static thread_local uint64_t cScans = 0, cLines = 0, cSteps = 0, cSkips = 0;
            static thread_local std::unordered_map<const void*, uint64_t> nextScan;
            static const uint64_t backoffNs = getenv("NCCL_LLSCAN_BACKOFF_NS") ? strtoull(getenv("NCCL_LLSCAN_BACKOFF_NS"), NULL, 0) : 0;
            uint64_t nowNs = backoffNs ? clockNano() : 0;
            if (backoffNs && nowNs < nextScan[buff]) { ready = 0; cSkips++; }
            else {
              int iRead = 0;
              for (int i=0; i<nFifoLines; i++) {
                volatile uint32_t *f1 = &lines[i].flag1;
                volatile uint32_t *f2 = &lines[i].flag2;
                iRead = i + 1;
                if (f1[0] != flag || f2[0] != flag) { ready = 0; break; }
              }
              if (nFifoLines >= 2048) { cScans++; cLines += iRead; }
              if (!ready && backoffNs) nextScan[buff] = nowNs + backoffNs;
              if (ready && nFifoLines >= 2048) { cSteps++;
                if (cSteps % 5000 == 0) fprintf(stderr, "LLSCAN tid=%ld bigsteps=%lu scans/step=%.2f lines/step=%.0f backoff=%lu\\n", (long)gettid(), cSteps, (double)cScans/cSteps, (double)cLines/cSteps, backoffNs); }
            }
"""
assert s.count(old) == 1; s = s.replace(old, new)
s = "#include <unistd.h>\n#include <unordered_map>\n" + s
open(p, "w").write(s); print("patched")
