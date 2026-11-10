import sys
# variant s (built on q: the GPU publishes the step size after writing, so the proxy's read is not needed
# for correctness). For deferred LL steps the proxy reads lines according to NCCL_LLX_MODE / NCCL_LLX_ARG,
# so the CPU leaves cached copies in a controlled pattern before the EFA send:
#   all      every LL line (same as q)              none     no line
#   suffix   the last ARG cache lines, contiguous
#   stride   1 line per ARG cache lines              prefix   the first ARG cache lines, contiguous
#   slotmod  every line, only on steps with step % ARG == 0
#   chan     every line, only on channels with channelId < ARG
#   demote   every line, then cldemote each cache line (copy pushed from the core to the LLC)
p = sys.argv[1]
s = open(p).read()
old = """          } else if (p == NCCL_PROTO_LL) {
            uint32_t flag = NCCL_LL_FLAG(sub->base+sub->transmitted+1);
            int nFifoLines = DIVUP(size, sizeof(union ncclLLFifoLine));
            union ncclLLFifoLine* lines = (union ncclLLFifoLine*)buff;
            for (int i=0; i<nFifoLines; i++) {"""
new = """          } else if (p == NCCL_PROTO_LL && llReady) {
            static const char* llxMode = getenv("NCCL_LLX_MODE") ? getenv("NCCL_LLX_MODE") : "all";
            static const int llxArg = getenv("NCCL_LLX_ARG") ? atoi(getenv("NCCL_LLX_ARG")) : 1;
            int nFifoLines = DIVUP(size, sizeof(union ncclLLFifoLine));
            volatile union ncclLLFifoLine* lines = (volatile union ncclLLFifoLine*)buff;
            uint32_t sink = 0;
            int first = 0, last = nFifoLines, step = 1;
            if (!strcmp(llxMode, "none")) last = 0;
            else if (!strcmp(llxMode, "stride")) step = 4 * llxArg;
            else if (!strcmp(llxMode, "prefix")) last = std::min(nFifoLines, 4 * llxArg);
            else if (!strcmp(llxMode, "suffix")) first = std::max(0, nFifoLines - 4 * llxArg);
            else if (!strcmp(llxMode, "slotmod")) { if ((sub->transmitted / args->sliceSteps) % llxArg) last = 0; }
            else if (!strcmp(llxMode, "chan")) { if (sub->channelId >= llxArg) last = 0; }
            for (int i = first; i < last; i += step) sink += lines[i].flag1;
            if (!strcmp(llxMode, "demote")) {
              for (int i = 0; i < nFifoLines; i += 4) asm volatile("cldemote (%0)" :: "r"(lines + i) : "memory");
            }
            (void)sink;
          } else if (p == NCCL_PROTO_LL) {
            uint32_t flag = NCCL_LL_FLAG(sub->base+sub->transmitted+1);
            int nFifoLines = DIVUP(size, sizeof(union ncclLLFifoLine));
            union ncclLLFifoLine* lines = (union ncclLLFifoLine*)buff;
            for (int i=0; i<nFifoLines; i++) {"""
q_marker = "          } else if (p == NCCL_PROTO_LL) {\n            uint32_t flag"
assert s.count(q_marker) == 1, "expected the q variant (proxy scans LL even when ready)"
assert s.count(old) == 1
s = s.replace(old, new)
if "#include <cstring>" not in s:
    s = "#include <cstring>\n#include <algorithm>\n" + s
open(p, "w").write(s)
print("patched")
