import sys
# variant c: base NCCL + counters of how often the send proxy re-scans LL lines per step.
p = sys.argv[1]; s = open(p).read()
old = """            for (int i=0; i<nFifoLines; i++) {
              volatile uint32_t *f1 = &lines[i].flag1;
              volatile uint32_t *f2 = &lines[i].flag2;
              if (f1[0] != flag || f2[0] != flag) { ready = 0; break; }
            }
"""
new = """            static thread_local uint64_t cScans = 0, cLines = 0, cSteps = 0, cBig = 0, cBigScans = 0;
            int iRead = 0;
            for (int i=0; i<nFifoLines; i++) {
              volatile uint32_t *f1 = &lines[i].flag1;
              volatile uint32_t *f2 = &lines[i].flag2;
              iRead = i + 1;
              if (f1[0] != flag || f2[0] != flag) { ready = 0; break; }
            }
            cScans++; cLines += iRead; if (nFifoLines >= 2048) cBigScans++;
            if (ready) { cSteps++; if (nFifoLines >= 2048) cBig++;
              if (cSteps % 20000 == 0) fprintf(stderr, "LLSCAN tid=%ld steps=%lu scans/step=%.2f lines/step=%.0f bigsteps=%lu bigscans/bigstep=%.2f\\n", (long)gettid(), cSteps, (double)cScans/cSteps, (double)cLines/cSteps, cBig, cBig ? (double)cBigScans/cBig : 0.0); }
"""
assert s.count(old) == 1; s = s.replace(old, new)
if "#include <unistd.h>" not in s: s = "#include <unistd.h>\n" + s
open(p, "w").write(s); print("patched")
