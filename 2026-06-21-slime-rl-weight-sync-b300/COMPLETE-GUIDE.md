# SLIME GRPO を NVIDIA B300 (sm_103) で動かす完全ガイド

**最終更新**: 2026-06-20
**到達状態**: SLIME GRPO smoke が B300 で **完全動作**(rollout 生成 → train → weight sync → eval まで一巡)。
**検証環境**: EKS `ml-clusters-shared-us-west-2` / p6-b300.48xlarge x2 (NVIDIA B300, 8 GPU/node, sm_103) / kai-scheduler / FSx Lustre。

このドキュメントは、awsome-distributed-ai の SLIME test case (H100/p5 想定) を B300 で動かすために**実測で特定した 6 つの壁とその真因・対処**を、再現可能な手順とコード情報込みで残すもの。**6 つの壁はすべてリファレンス awsome-distributed-ai 自体の抜け**で、参照した 2 リファレンス (awsome-distributed-ai / mlkeita-pavel-blog-nccl-nixl) のどちらにも答えはなかった。H100 でも顕在化するはずで、リファレンスが完全 smoke を通せていない強い傍証。

---

## 0. TL;DR — 動かすために必要な全て

### image (L1: 本丸)
awsome-distributed-ai の `slime.Dockerfile` (`nvcr.io/nvidia/pytorch:26.02-py3` + TE 2.12 + SGLang 0.5.12.post1) を**ほぼ無改変**で B300 ビルド → `slime:v0.2.4-ngc-b300`。**追加した唯一の修正は末尾の `numpy<2` pin 1 行**(壁6)。

### run_grpo / env (recipe はリファレンス形を保ち、B300 delta は env に隔離)
```sh
# env_vars.myuser (FSx パス + B300 delta)
export SGLANG_LOG_LEVEL="info"                                    # 壁2: uvicorn 有効値 (WARN→info)
export SGLANG_EXTRA_ARGS="--sglang-cuda-graph-max-bs 8"           # 壁3: B300 大HBM の capture 範囲抑制
export TRAIN_EXTRA_ARGS="--no-offload-train --no-offload-rollout" # 壁5: cu12 .so LD_PRELOAD 回避
```
```yaml
# raycluster-ngc.yaml (worker と head の env)
- { name: GLOO_SOCKET_IFNAME, value: "eth0" }                     # 壁4: TP>1 の gloo broadcast NIC 明示
```
recipe `run_grpo_qwen3_4b.reference.sh` はリファレンスとの差分が **MODEL_ARGS の literal 展開 1 点のみ**(壁1)+ env フック (`${SGLANG_LOG_LEVEL}`/`${SGLANG_EXTRA_ARGS}`/`${TRAIN_EXTRA_ARGS}`)。

---

## 1. 6 つの壁と真因 (到達順)

### 壁0: L3 patch 8個 (`--no-rope-fusion` 等)
- **誤解していたこと**: 前任セッションは TE 不在の SGLang nightly image を使い、`--no-rope-fusion --transformer-impl local --qkv-format bshd --no-bias-dropout-fusion --no-persist-layer-norm --no-masked-softmax-fusion --no-gradient-accumulation-fusion --attention-backend local --spec local --micro-batch-size 1` を必須としていた。
- **真因**: nightly image に Transformer Engine が無い (`Transformer Engine and Apex are not installed`)。
- **対処**: リファレンスの NGC base image (`nvcr.io/nvidia/pytorch:26.02-py3`, TE 2.12.0 同梱) を**無改変ビルド**。これで L3 patch は**全部不要**(素フラグで Megatron model build 通過を実証)。SGLang を 0.5.13 nightly に上げると NGC の torch 2.11/CUDA 13 ABI が壊れて TE/flash-attn が死ぬので **0.5.12.post1 を堅持**。
- **副産物**: 前任が必須としていた L2 (MemPool keepalive patch) も NGC SGLang 0.5.12 では**不要**(CUDA graph capture abort 0 件)。

### 壁1: MODEL_ARGS が train.py に渡らない (`hf_validate_args failed: hidden_size None`)
- **症状**: 素フラグで model build に入ると `hidden_size in hf config 2560 is not equal to hidden_size None` で即停止。norm_epsilon/rotary_base が Megatron デフォルト値になっている。
- **真因**: リファレンス recipe は `TRAIN_CMD="... source scripts/models/${MODEL_SCRIPT} && python3 train.py \${MODEL_ARGS[@]}"` と bash 配列 `${MODEL_ARGS[@]}` を**エスケープして遅延展開**する。worker が単一 `bash -c` で受ける HyperPod 前提。RayCluster 経由は `ray job submit -- bash -c "..."` で shell が一段深くネストし、配列が中間 sh 層で**空展開**される (実証: ネスト時 0 要素、単一 shell 25 要素)。
- **対処**: head 側で `MODEL_ARGS_LITERAL="${MODEL_ARGS[*]}"` と literal 文字列に展開してから渡す。`source /opt/slime/scripts/models/${MODEL_SCRIPT}` (image 内コード) を使い、FSx pyenv は**注入しない** (前任の plain-image 方式の名残で TE を shadow する)。

### 壁2: SGLang HTTP server が立たない (★最重要・最も時間を溶かした)
- **症状**: capture 完了後も rollout engine の HTTP server (uvicorn, port 15000) が listen せず、engine init の `_wait_server_healthy` が `/health_generate` を永久に取れず hang。RolloutManager が `start_rollout_servers` の `ray.get` で PENDING_CREATION 固着。py-spy で HTTP server プロセスは `_exit_function` (atexit, multiprocessing/util.py:360) で子 scheduler を join 待ち。scheduler (EngineCore) 自体は `recv_requests`/`on_idle` で **ready**。
- **真因**: リファレンス recipe の `--sglang-log-level WARN` (大文字) が SGLang 経由で uvicorn にそのまま渡る (`sglang/srt/entrypoints/http_server.py:2230` の `log_level=server_args.log_level_http or server_args.log_level`)。uvicorn の有効 log_level は**小文字のみ** `{critical,error,warning,info,debug,trace}` で、`'WARN'`/`'warn'` は `KeyError` を投げ **uvicorn が起動前に die** する。
- **切り分けの決め手**: 単一 engine を `python -m sglang.launch_server --log-level info` (小文字) で手動起動 → 90秒で `fired up and ready` (B300 自体は正常)。SLIME 経由 (WARN) は HTTP server 不起動。`log_level=info` にした瞬間 `Uvicorn running` + `fired up: 2` で両 engine 起動。
- **対処**: `--sglang-log-level info` (env: `SGLANG_LOG_LEVEL=info`)。**リファレンス awsome-distributed-ai 自体のバグ**。

### 壁3: CUDA graph capture が異常に遅い / colocated で CPU 競合
- **症状**: `Capturing batches (52/52)` と `Capturing num tokens (74/74)` が 16 engine 同時だと数十分かかる。`sglang::scheduler` が CPU 95% で奪い合い。
- **真因**: B300 の 192GB HBM。`--sglang-mem-fraction-static 0.8` だと SGLang が `cuda_graph_max_bs` を最上位階層 (160) に自動設定し、capture する batch×token 範囲が膨大になる。H100 80GB では起きにくい、**大 HBM が裏目に出る B300 固有現象**。
- **対処**: `--sglang-cuda-graph-max-bs 8` (env: `SGLANG_EXTRA_ARGS`)。capture batch が 52→4 に短縮。
- **注意**: triton backend (`--sglang-attention-backend triton`) は B300 で `Pointer argument cannot be accessed from Triton (cpu tensor?)` の CPU tensor エラーを誘発するため**使わない** (前任 adhoc 版の crash 原因だった)。

### 壁4: TP>1 で gloo broadcast hang (`Capturing num tokens` 68/74 付近で停止)
- **症状**: TP=8 構成で capture が 68/74 付近で停止。py-spy で scheduler が `broadcast` (torch/distributed/distributed_c10d.py) → `broadcast_pyobj` (sglang utils/common.py) → `recv_requests` (scheduler.py) で待機。
- **真因**: SGLang の TP rank 間制御 broadcast (`broadcast_pyobj`) は `force_cpu_device=True` で **gloo CPU group** を使う (`self.tp_cpu_group`)。gloo は `NCCL_SOCKET_IFNAME` を見ず独自に NIC を選ぶため、複数 NIC (eth0 + EFA) 環境で**誤った interface を掴み broadcast hang**。NCCL/EFA の問題ではない。
- **対処**: pod env に `GLOO_SOCKET_IFNAME=eth0` (pod 主 NIC)。これで capture 74/74 完走。TP=1 では不要。

### 壁5: train worker が即死 (`ActorUnschedulableError` + `libcudart.so.12`)
- **症状**: rollout 突破後、MegatronTrainRayActor の Ray worker 起動が `Failed to startup worker after retrying 5 times`。raylet ログに `bash: error while loading shared libraries: libcudart.so.12: cannot open shared object file`。
- **真因**: `slime/ray/actor_group.py:62-72` で `offload_train` 有効時 (リファレンス既定) に SLIME が `torch_memory_saver_hook_mode_preload.abi3.so` を train actor に **`LD_PRELOAD`** する。この**無印 .so は cu12 リンク** (`ldd` で `libcudart.so.12 => not found`)。NGC image は CUDA 13 なので LD_PRELOAD した worker の bash が起動時に即死。image には cu13 版 `..._preload_cu13.abi3.so` (libcudart.so.13 リンク) が存在するが、SLIME は無印 (cu12) を決め打ち。
- **対処**: `--no-offload-train --no-offload-rollout` (env: `TRAIN_EXTRA_ARGS`) で offload_train を切る → LD_PRELOAD 分岐自体がスキップ。B300 192GB なら offload 不要なので設計判断としても妥当。

### 壁6: Megatron init が numpy 2.x で abort
- **症状**: train actor 起動 → Megatron init で `AssertionError: Megatron does not support numpy 2.x` (`slime/backends/megatron_utils/initialize.py:66`)。
- **真因**: Megatron-LM は numpy 1.x を hard-assert (`assert np.__version__.startswith("1.")`, NVIDIA/Megatron-LM#1563)。だが `sglang[all]` が numpy 2.1.0 を transitively 引く。リファレンス Dockerfile は numpy を pin していない。
- **対処 (美しい解決 = アドホックでなく image で)**: Dockerfile の**最終 dep step** (SLIME install 後、全依存解決後) に `pip install "numpy<2"` を追加。numpy 1.26.4 が入り、SGLang は `numpy` (unversioned) 要求なので両立 (numpy>=2 を厳格要求するのは extra / py>=3.13 のみで py3.12 では非該当)。

---

## 2. 実測データ (登壇ネタ: weight sync)

`slime/backends/megatron_utils/actor.py:135` が weight sync の方式を分岐:
```python
update_weight_cls = UpdateWeightFromTensor if self.args.colocate else UpdateWeightFromDistributed
```

### colocated (CUDA IPC, `UpdateWeightFromTensor`) — 実測済み
- **Qwen3-4B, TP=8, 2 node, colocate**: 初回 2.4s (CUDA IPC handle 確立込み)、**2回目以降は定常 ~1.2s** (GRPO 6+周回で安定、weight_sync 7回)。
- ログ上 `POST /update_weights_from_tensor` が呼ばれ、CUDA IPC 方式であることを実証。
- GRPO 1周の内訳: update_weights 1.2s / ref_log_probs 1.2-1.7s / actor_train 20-30s / train end 21-33s。
- 一次データ: `RESULTS/smoke_STABLE_memfrac04_<jobid>.log` (6+周回安定), `RESULTS/WEIGHT_SYNC_RESULTS.md` (サマリ)。
- **安定動作の必須設定**: mem-fraction 0.4 + `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` (mem-fraction 0.5 は1周完走するが2周目の NCCL communicator buffer の CUDA calloc ~13MB が OOM。`unhandled cuda error` の正体は OOM)。

### disaggregated (NCCL/EFA, `UpdateWeightFromDistributed`) — 未測定 (次のステップ)
- Qwen3-30B-A3B MoE, `--colocate` を外す。`slime-pp_{pp_rank}` group で NCCL broadcast (EFA 経由)。
- 比較軸: colocated CUDA IPC vs disaggregated NCCL/EFA の update_weights 時間。記事の「推定」を実測で置換。

---

## 3. 再現手順 (クリーンな状態から)

```sh
# --- 前提: investigations/slime-on-eks-b300/ に居る。kubectl が myuser-slime ns に通る ---

# [1] image ビルド (numpy<2 pin 入り Dockerfile)
cd reference-build
kubectl -n myuser-slime delete configmap slime-ngc-build-context 2>/dev/null
kubectl -n myuser-slime create configmap slime-ngc-build-context \
  --from-file=Dockerfile=./Dockerfile --from-file=requirements.txt=./requirements.txt
kubectl -n myuser-slime delete job slime-ngc-build 2>/dev/null
kubectl -n myuser-slime apply -f ./buildkit-job.yaml
# ECR secret は 12h で失効。失効していたら再発行:
#   aws ecr get-login-password --region us-west-2 | ... で ecr-myuser-own secret 再作成
# ビルド ~11分 (layer cache 効けば)。push 完了を build pod ログで確認。

# [2] RayCluster 起動 (新 image を確実に pull するため初回は Always)
cd ../reference-test
kubectl -n myuser-slime delete raycluster slime-ray 2>/dev/null
sed 's/imagePullPolicy: IfNotPresent/imagePullPolicy: Always/g' raycluster-ngc.yaml | kubectl apply -f -
# 全 3 pod Ready を待つ (head は B300 同居、GPU 無しノードに置かない=このクラスタの CPU node が貧弱なため)

# [3] recipe + env を FSx に配置して投入
HEAD=$(kubectl -n myuser-slime get pod -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}')
kubectl -n myuser-slime exec $HEAD -- mkdir -p /fsx/myuser/slime/reference-test/recipe
kubectl -n myuser-slime cp run_grpo_qwen3_4b.reference.sh $HEAD:/fsx/myuser/slime/reference-test/recipe/run_grpo_qwen3_4b.sh
kubectl -n myuser-slime cp env_vars.myuser $HEAD:/fsx/myuser/slime/reference-test/env_vars.myuser
kubectl -n myuser-slime exec $HEAD -- bash -lc '
  cd /fsx/myuser/slime/reference-test
  export ENV_FILE=/fsx/myuser/slime/reference-test/env_vars.myuser
  nohup bash recipe/run_grpo_qwen3_4b.sh > /fsx/myuser/slime/logs/smoke_$(date +%H%M%S).log 2>&1 &'

# [4] 監視: fired up: 2 → RolloutManager ALIVE → MegatronTrainRayActor 起動 → Timer update_weights → Eval aime
```

### はまりどころ早見表
| 症状 | 確認コマンド | 対処 |
|---|---|---|
| pod が Pending (gang scheduling) | `kubectl describe pod` の Events | head を B300 同居に (nodeAffinity 削除 + taint toleration)。capacity-reservation taint は `operator: Exists` |
| `hf_validate_args failed ... None` | recipe の MODEL_ARGS 展開 | literal 展開 (`${MODEL_ARGS[*]}`) を使う |
| HTTP server 立たず `_wait_server_healthy` hang | `ss -tln | grep 15000` が空 + py-spy で `_exit_function` | `SGLANG_LOG_LEVEL=info` (WARN は uvicorn KeyError) |
| capture が数十分 / CPU 95% | `Capturing num tokens` が進まない | `--sglang-cuda-graph-max-bs 8` |
| TP>1 で capture 68/74 で停止 | py-spy で `broadcast_pyobj`→gloo | `GLOO_SOCKET_IFNAME=eth0` |
| `ActorUnschedulableError` + `libcudart.so.12` | raylet ログの bash error | `--no-offload-train --no-offload-rollout` |
| `Megatron does not support numpy 2.x` | `python3 -c 'import numpy;print(numpy.__version__)'` が 2.x | Dockerfile に `numpy<2` pin |
| ECR push 403 | docker secret token (12h 失効) | `aws ecr get-login-password` で secret 再発行 |
| 古い image が使われる | 同一 tag で再 push 時 | RayCluster を `imagePullPolicy: Always` で再作成 |

---

## 4. 関連ファイル (このディレクトリ)
- `PATCH-DESIGN.md` — 層別 patch 設計と切り分け全履歴 (壁ごとの検証ログ)
- `run_grpo_qwen3_4b.reference.sh` — recipe (リファレンス + literal 展開 + env フック)
- `env_vars.myuser` — FSx パス + B300 delta (log_level / cuda-graph-max-bs / no-offload)
- `raycluster-ngc.yaml` — RayCluster (NGC image, GLOO_SOCKET_IFNAME, B300 taint, head 同居)
- `../reference-build/Dockerfile` — NGC リファレンス + numpy<2 pin
- `../reference-build/buildkit-job.yaml` — BuildKit Job
- `RESULTS/smoke_complete_*.log` — 完全動作時の driver ログ一次データ
- `RESULTS/weight_sync_measurements.txt` — weight sync timer 抽出

関連 memory: `slime-b300-smoke-true-rootcauses`, `slime-weight-sync-impl-structure`, `slime-b300-mempool-and-memory-saver` (旧・訂正済), `eks-ml-shared-uw2-cluster-layout`。
