import sys
p = sys.argv[1]; s = open(p).read()
old = """              if (f1[0] != flag || f2[0] != flag) { ready = 0; break; }
            }
"""
new = old + """            if (ready) { // variant f: drop the CPU's copies of the lines it just read
              for (int i=0; i<nFifoLines; i+=4) asm volatile("clflushopt (%0)" :: "r"(lines+i) : "memory");
              asm volatile("sfence" ::: "memory");
            }
"""
assert s.count(old) == 1; open(p, "w").write(s.replace(old, new)); print("patched")
