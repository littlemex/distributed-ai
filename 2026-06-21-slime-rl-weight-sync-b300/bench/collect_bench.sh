#!/usr/bin/env bash
# ============================================================================
# Weight Sync ベンチ集計スクリプト
# ============================================================================
# run_bench.sh で投入した各セルのログから weight sync (Timer update_weights) を
# 集計し、apple-to-apple 比較表を出力する。
#
# 使い方: ./collect_bench.sh           (/tmp/bench_logs.txt の全セル)
#         ./collect_bench.sh <logpath> (単一ログ)
# ============================================================================
set -uo pipefail
NS=myuser-slime
HEAD=$(kubectl -n $NS get pod -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}')

collect_one() {
  local cell="$1" log="$2"
  echo "----- セル $cell ($log) -----"
  # weight sync の elapsed (初回 + 定常)
  local vals
  vals=$(kubectl -n $NS exec "$HEAD" -- bash -lc "tr '\r' '\n' < $log 2>/dev/null | grep -E 'Timer update_weights end' | grep -oE '[0-9.]+s'" 2>&1 | grep -ivE "Future|pynvml" | tr '\n' ' ')
  echo "  update_weights: ${vals:-(まだ無し)}"
  # 400 error / engine 数 / mem-fraction の確認 (apple-to-apple の前提検証)
  local e400  engines memf
  e400=$(kubectl -n $NS exec "$HEAD" -- bash -lc "grep -ciE 'must match the size|400 Client' $log 2>/dev/null" 2>&1 | grep -ivE "Future|pynvml" | head -1)
  engines=$(kubectl -n $NS exec "$HEAD" -- bash -lc "tr '\r' '\n' < $log 2>/dev/null | grep -oE 'Ports for engine [0-9]+' | sort -u | wc -l" 2>&1 | grep -ivE "Future|pynvml" | head -1)
  memf=$(kubectl -n $NS exec "$HEAD" -- bash -lc "grep -oE 'mem_fraction_static [^0-9]*[0-9.]+' $log 2>/dev/null | head -1" 2>&1 | grep -ivE "Future|pynvml" | grep -oE '[0-9.]+$')
  echo "  検証: engine数=$engines  mem-fraction=$memf  400error=$e400"
}

echo "=== Weight Sync apple-to-apple ベンチ集計 ==="
if [ $# -ge 1 ] && [ -f "/tmp/bench_logs.txt" ] && [ "$1" != "${1%.log}" ]; then
  collect_one "single" "$1"
elif [ -f /tmp/bench_logs.txt ]; then
  while read cell log; do collect_one "$cell" "$log"; done < /tmp/bench_logs.txt
else
  echo "ログ記録 (/tmp/bench_logs.txt) が無い。run_bench.sh を先に実行するか、ログパスを引数で渡す。"
fi

echo
echo "=== apple-to-apple 確認チェックリスト (集計後に手で確認) ==="
echo "  [ ] A1/A2/B1 とも engine数 が同じ (4 期待)"
echo "  [ ] A1/A2/B1 とも mem-fraction が同じ (BENCH_MEM_FRACTION)"
echo "  [ ] A1 vs A2: モデル・engine・mem-fraction 一致、方式のみ差 → 方式比較OK"
echo "  [ ] A2 vs B1: 方式・engine 一致、モデルのみ差 → 規模比較OK"
echo "  [ ] 全セル 400error=0 (weight sync 成功)"
