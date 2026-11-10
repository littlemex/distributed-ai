import sys
p = sys.argv[1]; s = open(p).read()
old = """                if (lines[i*NCCL_LL128_LINEELEMS+NCCL_LL128_DATAELEMS] != flag) { ready = 0; break; }
              }
"""
new = old + """              if (ready) { // variant g: drop the CPU's copies of the LL128 flag cache lines it read
                for (int i=0; i<nFifoLines; i++) asm volatile("clflushopt (%0)" :: "r"(lines+i*NCCL_LL128_LINEELEMS+NCCL_LL128_DATAELEMS) : "memory");
                asm volatile("sfence" ::: "memory");
              }
"""
assert s.count(old) == 1; open(p, "w").write(s.replace(old, new)); print("patched")
