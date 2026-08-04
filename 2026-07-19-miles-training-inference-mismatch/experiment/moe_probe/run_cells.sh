#!/bin/bash
# 残りのセルを順に実行する。
#
# 並列実行は避ける。並列で回すと 2 つのエンジンが同じノードの CPU/メモリを
# 取り合ってロードが極端に遅くなり、さらに片方が落ちたときの切り分けが
# 難しくなる。1 セルあたり生成は 1 分程度で、支配的なのはロード (約 4 分) なので
# 直列でも全部で 30 分以内に終わる。
#
# cwd を絶対パスで固定する。setsid 経由だと cwd が引き継がれず
# /root/miles で probe.py を探して失敗した (C_backend の初回)。
set -u
cd /fsx/moe-probe/scripts || exit 1
R=/fsx/moe-probe/results

for spec in "$@"; do
  cell="${spec%%:*}"
  gpus="${spec##*:}"
  echo "=== [$(date -u +%H:%M:%S)] cell=$cell gpus=$gpus ==="
  CUDA_VISIBLE_DEVICES="$gpus" python3 /fsx/moe-probe/scripts/probe.py \
      --cell "$cell" --n-prompts 32 --max-new 8192 \
      > "$R/$cell.log" 2>&1
  rc=$?
  echo "=== [$(date -u +%H:%M:%S)] cell=$cell exit=$rc ==="
  if [ -f "$R/$cell.summary.json" ]; then
    python3 -c "
import json
s = json.load(open('$R/$cell.summary.json'))
print('  repetition_frac=%.3f  n_rep=%d/%d  longest_repeat=%d  finish=%s' % (
    s['repetition_frac'], s['n_repetition'], s['n_samples'],
    s['longest_repeat_repeats_max'], s['finish_reasons']))
"
  else
    echo "  NO SUMMARY -- see $R/$cell.log"
  fi
done
echo "=== ALL DONE [$(date -u +%H:%M:%S)] ==="
