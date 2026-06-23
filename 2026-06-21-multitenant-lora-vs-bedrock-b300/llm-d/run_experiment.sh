#!/usr/bin/env bash
# llm-d / GIE EndpointPicker による LoRA-aware routing 実験のオーケストレータ。
#
# 同じ 8 Pod (1 Pod = 1 GPU = 1 vLLM, Gemma 4 31B fp8, adapter 128 個登録済み) に対し、
# 以下 4 条件を「同一の concurrency_sweep.py・同一 SLO・同一ワークロード」で計測する。
# 計測は必ずクラスタ内・同一ノードの bench Pod (mt-lora-bench) から実行する
# (前回 1Pod localhost 計測とネットワーク条件を揃え、TTFT を不当に膨らませない)。
#
#   [整合性検証 — 前回値を新構成で再現できるか]
#   (0) direct-rr      : EPP 非経由。8 Pod IP を client-side roundrobin (req 循環)。
#                        前回 B-roundrobin.json (1Pod8proc) と一致すべき。
#   (0') direct-affinity: EPP 非経由。client-side で adapter を Pod に静的シャーディング
#                        (urls[adapter_idx % 8])。前回 B-affinity.json と一致すべき。
#
#   [新規 llm-d データ — GIE EndpointPicker の実ルーティング]
#   (1) epp-rr      : EPP profile=rr (random-picker)。EPP 経路自体の中立性検証用。
#   (2) epp-affinity: EPP profile=affinity (lora-affinity-scorer)。LoRA-aware routing 単独効果。
#                     client 静的シャーディングと違い、vllm:lora_requests_info の running set を
#                     読んで動的に affinity を効かせる (これが llm-d 本来の挙動)。
#   (3) epp-full    : EPP profile=full (queue+kv+prefix+lora-affinity)。llm-d 代表構成。
#
# ワークロード (前回 B-roundrobin/B-affinity と完全一致):
#   adapters=128, zipf=1.1, concurrency=[8,32,64,128,256,512],
#   requests_per_stage=512, max_tokens=64, ignore_eos, SLO ttft<=2000ms tpot<=80ms
#
# 使い方 (Mac から; kubectl が ml-shared-uw2 に通っていること):
#   ./run_experiment.sh            # 全 4 条件
#   ./run_experiment.sh epp-affinity   # 単一条件のみ
set -euo pipefail

NS=mt-serving
BENCH=mt-lora-bench
HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/../scripts/concurrency_sweep.py"
EPP_URL="http://mt-lora-epp.${NS}.svc.cluster.local:80/v1"   # Envoy(8081) 入口

# 前回と一致させる sweep 共通引数
COMMON_ARGS=(--model google/gemma-4-31B-it --auth none --adapters 128 --zipf 1.1 \
  --concurrency 8 32 64 128 256 512 --requests-per-stage 512 --max-tokens 64 \
  --slo-ttft-ms 2000 --slo-tpot-ms 80 --timeout 120 --ignore-eos)

ONLY="${1:-all}"

# bench Pod に sweep スクリプトを配置 (冪等)
echo "[INFO] copying concurrency_sweep.py into $BENCH"
kubectl cp "$SWEEP" "$NS/$BENCH:/tmp/concurrency_sweep.py"
kubectl exec "$BENCH" -n "$NS" -- bash -lc 'mkdir -p /tmp/llmd-results'

# 8 Pod の IP を取得 (direct routing 用)
pod_ips() {
  kubectl get pods -n "$NS" -l app=mt-lora-pool \
    -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort
}

run_sweep() {
  local name="$1"; shift
  local base_url="$1"; shift
  local routing="$1"; shift
  echo ""
  echo "========================================================"
  echo "[RUN] condition=$name routing=$routing"
  echo "      base_url=$base_url"
  echo "========================================================"
  kubectl exec "$BENCH" -n "$NS" -- bash -lc \
    "cd /tmp && python3 concurrency_sweep.py --base-url '$base_url' --routing $routing \
       ${COMMON_ARGS[*]} --out /tmp/llmd-results/${name}.json"
  # 結果を手元へ回収
  kubectl cp "$NS/$BENCH:/tmp/llmd-results/${name}.json" "$HERE/results/${name}.json"
  echo "[OK] saved $HERE/results/${name}.json"
}

mkdir -p "$HERE/results"

# --- (0) direct-rr / (0') direct-affinity: EPP を通さず 8 Pod IP を client routing ---
if [ "$ONLY" = all ] || [ "$ONLY" = direct-rr ]; then
  IPS=$(pod_ips)
  BASE=$(echo "$IPS" | sed 's#^#http://#; s#$#:8000/v1#' | paste -sd, -)
  run_sweep "llmd-direct-rr" "$BASE" roundrobin
fi
if [ "$ONLY" = all ] || [ "$ONLY" = direct-affinity ]; then
  IPS=$(pod_ips)
  BASE=$(echo "$IPS" | sed 's#^#http://#; s#$#:8000/v1#' | paste -sd, -)
  run_sweep "llmd-direct-affinity" "$BASE" affinity
fi

# --- (1)(2)(3) EPP 経由: profile を切り替えて単一 Envoy エンドポイントに送る ---
for cond in epp-rr epp-affinity epp-full; do
  [ "$ONLY" = all ] || [ "$ONLY" = "$cond" ] || continue
  profile="${cond#epp-}"   # rr / affinity / full
  echo "[INFO] switching EPP profile -> $profile"
  "$HERE/switch_profile.sh" "$profile"
  # EPP 再起動直後は datalayer がメトリクスを集め始めるまで数秒。lora_requests_info を
  # 温めるためウォームアップを 1 周流す (計測対象外)。
  sleep 10
  run_sweep "llmd-${cond}" "$EPP_URL" roundrobin
done

echo ""
echo "[DONE] all requested conditions complete. results in $HERE/results/"
