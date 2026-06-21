#!/usr/bin/env bash
# ============================================================================
# Weight Sync apple-to-apple ベンチ実行スクリプト
# ============================================================================
# GPU (RayCluster) が空いたら即実行できるように用意した薄いラッパー。
# 3 セル (A1/A2/B1) を順に GRPO 投入し、weight sync の Timer 値を集計する。
#
# 前提:
#   - RayCluster slime-ray が Ready (myuser-slime namespace)
#   - FSx に Qwen3-4B / Qwen3-4B_torch_dist / Qwen3-30B-A3B / _torch_dist 配置済み
#   - image slime:v0.2.4-ngc-b300 (TE2.12 + numpy<2 + mbridge)
#   - このディレクトリ (bench/) と recipe/run_grpo_qwen3_4b.reference.sh が FSx に配置済み
#
# 使い方 (ローカルから):
#   ./run_bench.sh                # 3 セル全部 (mem-fraction 0.5)
#   ./run_bench.sh A1             # 単一セル
#   BENCH_MEM_FRACTION=0.6 ./run_bench.sh A1   # mem-fraction を変えて
#
# apple-to-apple 原則: 3 セルとも engine 数=4, BENCH_MEM_FRACTION 共通, 訓練ハイパラ固定。
#   A1↔A2 = 方式比較 (colocated CUDA IPC vs disaggregated NCCL/EFA)
#   A2↔B1 = 規模比較 (4B dense vs 30B MoE)
# ============================================================================
set -uo pipefail

NS=myuser-slime
FSX_BENCH=/fsx/myuser/slime/reference-test/bench
FSX_RECIPE=/fsx/myuser/slime/reference-test/recipe/run_grpo_qwen3_4b.sh
export BENCH_MEM_FRACTION="${BENCH_MEM_FRACTION:-0.5}"

CELLS=("${@:-A1 A2 B1}")
[ $# -eq 0 ] && CELLS=(A1 A2 B1)

declare -A ENVFILE=(
  [A1]="env.A1-4b-colocated"
  [A2]="env.A2-4b-disaggregated"
  [B1]="env.B1-30b-moe-disaggregated"
)

HEAD=$(kubectl -n $NS get pod -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}')
echo "[INFO] head pod: $HEAD / BENCH_MEM_FRACTION=$BENCH_MEM_FRACTION"

# bench env 群と recipe を FSx に同期 (冪等)
echo "[INFO] bench env を FSx に配置"
kubectl -n $NS exec "$HEAD" -- mkdir -p "$FSX_BENCH" >/dev/null 2>&1
for cell in A1 A2 B1; do
  kubectl -n $NS cp "$(dirname "$0")/${ENVFILE[$cell]}" "$HEAD:$FSX_BENCH/${ENVFILE[$cell]}" >/dev/null 2>&1
done

for cell in ${CELLS[@]}; do
  EF="$FSX_BENCH/${ENVFILE[$cell]}"
  TS=$(kubectl -n $NS exec "$HEAD" -- date +%H%M%S 2>/dev/null | tr -d '\r')
  LOG="/fsx/myuser/slime/logs/bench_${cell}_${TS}.log"
  echo "==================================================================="
  echo "[INFO] セル $cell 投入: env=${ENVFILE[$cell]} mem-fraction=$BENCH_MEM_FRACTION log=$LOG"
  echo "==================================================================="
  # 前 job の残プロセス掃除
  for W in $(kubectl -n $NS get pod -l ray.io/node-type=worker -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n $NS exec "$W" -c ray-worker -- bash -lc "pkill -9 -f sglang 2>/dev/null; sleep 2; true" >/dev/null 2>&1
  done
  # 投入 (run_grpo は COLOCATE/MODEL_SCRIPT/MOE_ARGS 等を env から読む)
  kubectl -n $NS exec "$HEAD" -- bash -lc "
    cd /fsx/myuser/slime/reference-test
    export BENCH_MEM_FRACTION=$BENCH_MEM_FRACTION
    export ENV_FILE=$EF
    nohup bash $FSX_RECIPE > $LOG 2>&1 &
    echo submit_PID=\$!
  " 2>&1 | grep -ivE "Future|pynvml"
  echo "[INFO] $cell 投入完了。監視は: kubectl -n $NS exec $HEAD -- ray job logs <id>"
  echo "[INFO] weight sync 値: grep 'Timer update_weights end' $LOG"
  echo "$cell $LOG" >> /tmp/bench_logs.txt
done

echo
echo "[DONE] 投入完了。各セルの weight sync 集計は collect_bench.sh で。"
