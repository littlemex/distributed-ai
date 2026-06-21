import sys
f = "/usr/local/lib/python3.12/dist-packages/sglang/srt/model_executor/model_runner.py"
s = open(f).read()
if "AKZ_RECV_SHAPE" in s:
    print("already patched"); sys.exit(0)
lines = open(f).readlines()
out = []
done = False
for ln in lines:
    if (not done) and ln.strip() == "self.model.load_weights(weights)":
        ind = ln[:len(ln) - len(ln.lstrip())]
        out.append(ind + "import sys as _akzs\n")
        out.append(ind + "for _akzn, _akzw in weights:\n")
        out.append(ind + "    if 'expert' in _akzn:\n")
        out.append(ind + "        _akzs.stderr.write('AKZ_RECV_SHAPE ' + _akzn + ' ' + str(tuple(_akzw.shape)) + '\\n')\n")
        out.append(ind + "        _akzs.stderr.flush()\n")
        out.append(ind + "        break\n")
        done = True
    out.append(ln)
open(f, "w").writelines(out)
print("[OK] patched" if done else "[NG] anchor not found")
