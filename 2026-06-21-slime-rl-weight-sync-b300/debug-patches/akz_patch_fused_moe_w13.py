import sys
f = "/usr/local/lib/python3.12/dist-packages/sglang/srt/layers/moe/fused_moe_triton/layer.py"
s = open(f).read()
if "AKZ_W13" in s:
    print("already patched"); sys.exit(0)
lines = open(f).readlines()
out = []
done = False
for ln in lines:
    # _load_w13 の "shard_size = expert_data.shape[shard_dim] // 2" の直後にログ
    out.append(ln)
    if (not done) and ln.strip() == "shard_size = expert_data.shape[shard_dim] // 2":
        ind = ln[:len(ln) - len(ln.lstrip())]
        out.append(ind + 'import sys as _w13s; _w13s.stderr.write("AKZ_W13 expert_data=" + str(tuple(expert_data.shape)) + " loaded=" + str(tuple(loaded_weight.shape)) + " shard_dim=" + str(shard_dim) + " shard_size=" + str(shard_size) + " tp_rank=" + str(tp_rank) + "\\n"); _w13s.stderr.flush()\n')
        done = True
open(f, "w").writelines(out)
print("[OK] patched _load_w13" if done else "[NG] anchor not found")
