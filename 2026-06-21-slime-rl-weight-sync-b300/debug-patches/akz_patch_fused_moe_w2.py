import sys
f = "/usr/local/lib/python3.12/dist-packages/sglang/srt/layers/moe/fused_moe_triton/layer.py"
s = open(f).read()
if "AKZ_W2 " in s:
    print("already patched"); sys.exit(0)
lines = open(f).readlines()
out = []
done = False
for ln in lines:
    out.append(ln)
    # _load_w2 内の "shard_size = expert_data.shape[shard_dim]" (weight matrix 側) の直後
    if (not done) and ln.strip() == "shard_size = expert_data.shape[shard_dim]":
        ind = ln[:len(ln) - len(ln.lstrip())]
        out.append(ind + 'import sys as _w2s; _w2s.stderr.write("AKZ_W2 expert_data=" + str(tuple(expert_data.shape)) + " loaded=" + str(tuple(loaded_weight.shape)) + " shard_dim=" + str(shard_dim) + " shard_size=" + str(shard_size) + "\\n"); _w2s.stderr.flush()\n')
        done = True
open(f, "w").writelines(out)
print("[OK] patched _load_w2" if done else "[NG] anchor not found")
