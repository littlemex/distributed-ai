# miles 実機検証結果

親ディレクトリ (slime 版) の training-inference mismatch 検証を miles で再現した実機記録。
単一ノード (H200 x8, colocated GRPO, Qwen3-4B dense) で miles 版イメージ (radixark/miles + EFA) を
ビルドし、RayCluster で GRPO を回した。

## 到達点

miles で **GRPO 1 step が完走**し、mismatch metrics が slime と同一の計測系で取得できた。
weight sync (colocated)・rollout・ref/log_probs・Megatron backward まで実機で動作を確認。

## miles baseline の mismatch metrics (step 0, LR 1e-6, dropout=0, seed 固定)

slime baseline と直接比較可能な計測値:

| 指標 | miles (実測) | slime (実測) | 一致 |
| --- | --- | --- | --- |
| train/mis_kl | 0.000632 | 0.00065 | ほぼ一致 |
| train/mis_ppl_ratio | 1.00063 | 1.0006 | 一致 |
| train/mis_chi2_token | 0.00131 | 0.0012 | 一致 |
| train/train_rollout_logprob_abs_diff | 0.0130 | 0.0128 | 一致 |
| train/ppo_kl | 0.0 | 0.0 (dropout=0) | 一致 |
| rollout/raw_reward | 0.531 | (同レンジ) | - |
| perf/rollout_time | 56.7s | (同オーダー) | - |

結論: **miles でも bf16 SGLang vs Megatron の mis_kl は ~6e-4 と極小**で、slime とビット近似一致した。
これは「mismatch の絶対量は RL フレームワーク (slime/miles) でなく rollout/trainer の数値経路差で
決まる」という親ディレクトリの結論を miles で追認する。ppo_kl も dropout=0 で 0.0 となり、
「ppo_kl は dropout artefact」の結論も miles で再現した。

## 実機で確認できた miles の動作

- 8 SGLang engine の起動と `mark_alive` (weight_version 1.0 で weight sync 動作)
- rollout 生成 (response_len mean 6552, truncated_ratio 0.469)
- ref_log_probs / log_probs の再計算 (mismatch metrics の分母)
- Megatron actor_train (backward, grad_norm 0.125, actor_train_tflops 168)
- `--get-mismatch-metrics` + `--custom-tis-function-path` (ドット記法) + `mis_metrics_only.yaml`
  の計測経路が slime と同一フラグで通ること

## 既知の未解決 (smoke の合否には影響しない)

- `save_model()` が `_pickle.UnpicklingError: pickle data was truncated` で失敗。Megatron の分散
  checkpoint 保存 (`gather_object`) の問題で、GRPO 学習ループ自体とは独立。num-rollout 1 の
  最終 step 後の自動 save で発現。checkpoint 保存を要する長時間 run では別途対処が必要
  (SAVE_INTERVAL を大きくして save を回避、または分散 save の shard 設定を調整)。

## KV fp8 amplified (実機、LR 1e-5, dropout=0)

`--sglang-kv-cache-dtype fp8_e5m2` を足して同じ Qwen3-4B bf16 を回すと、miles でも mismatch が
増幅した:

| 指標 | miles baseline (bf16) | miles KV fp8 | 倍率 |
| --- | --- | --- | --- |
| train/mis_kl | 0.000632 | 0.0310 (step0) | 約49倍 |

slime の同一増幅 (0.0006 -> 0.0327, 54倍) とほぼ一致。miles でも「KV cache fp8 が rollout と
trainer の数値経路差を作り mismatch を 1-2 桁増幅する」ことを実機で再現した。KV fp8 の初期 step は
mis_kl 0.031 -> 0.028 -> 0.027 と横ばい (slime も序盤は 0.026-0.034 で安定してから後半に発散した
のと同じ初期挙動)。SGLang engine は fp8 KV cache で正常に生成 (reward 正解を確認)。

到達点まとめ: **baseline の mismatch 良性 (mis_kl ~6e-4) と KV fp8 による増幅 (~3e-2) の両方が
slime と一致して miles で再現**。「mismatch の絶対量は framework でなく rollout/trainer の数値経路差で
決まる」という結論が、slime と miles の 2 フレームワークで裏付けられた。

TIS 救済 (env/env_vars.tis.example, `--use-tis` + mis.yaml cap 2.0) を回す準備も整っている
(フラグは miles CLI に存在確認済み)。
