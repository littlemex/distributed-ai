import sys
# variant n: base NCCL, but LL receivers sleep NS ns after each poll that sees a stale flag
# (fewer polling loads of host memory). Tests whether GPU-side polling amplifies the stall.
p = sys.argv[1]; ns = sys.argv[2]; s = open(p).read()
old1 = """      if (checkAbort(abort, 1, spins)) break;
    } while ((flag1 != flag) || (flag2 != flag));"""
new1 = """      if (checkAbort(abort, 1, spins)) break;
      if ((flag1 != flag) || (flag2 != flag)) __nanosleep(%s);
    } while ((flag1 != flag) || (flag2 != flag));""" % ns
old2 = """    while (line[i].flag1 != flag || line[i].flag2 != flag) {
      asm volatile("ld.volatile.global.v4.u32 {%0,%1,%2,%3}, [%4];" : "=r"(line[i].data1), "=r"(line[i].flag1), "=r"(line[i].data2), "=r"(line[i].flag2) : "l"(&src->i4) : "memory");"""
new2 = old2.replace("{\n      asm", "{\n      __nanosleep(" + ns + ");\n      asm", 1)
assert s.count(old1) == 1 and s.count(old2) == 1
s = s.replace(old1, new1).replace(old2, new2)
open(p, "w").write(s)
print("patched", ns)
