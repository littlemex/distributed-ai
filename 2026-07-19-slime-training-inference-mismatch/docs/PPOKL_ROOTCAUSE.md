# ppo_kl ~0.30 の真因: train モードの dropout

## 結論

GRPO の学習中に観測される ppo_kl ~0.30 の正体は **train モードの dropout** であり、真の
off-policy ずれでもマイクロバッチ境界のズレでも複数回 optimizer 更新でもない。SLIME/Megatron が
RL fine-tuning でも Megatron default の dropout 0.1 を有効のままにしていることが原因。

- old_log_probs は `forward_only()` = eval モードで計算される -> dropout OFF
- loss の log_probs は `train()` = train モードで計算される -> dropout 0.1 ON
- ppo_kl = old_log_probs (dropout なし) - log_probs (dropout あり) が per-token で ~0.30 を生む
- config: attention_dropout=0.1, hidden_dropout=0.1 (Megatron default, 未上書き)

## 決定的実測 (3 run 比較、全て step0、LR 1e-6、seed 固定)

| run | dropout | dynamic batch | ppo_kl | pg_clipfrac | mis_kl | abs_diff |
| --- | --- | --- | --- | --- | --- | --- |
| baseline step0 | 0.1 | ON | 0.312 | 0.043 | 0.00065 | 0.0128 |
| diag (batch off) | 0.1 | OFF | 0.304 | 0.064 | 0.00074 | 0.0129 |
| diag (dropout 0) | **0** | ON | **0.000** | **0.000** | 0.00053 | 0.0129 |

- dynamic batch を OFF にしても ppo_kl は不変 -> マイクロバッチ境界ズレ説を棄却。
- dropout=0 にすると ppo_kl -> 0, clipfrac -> 0 -> dropout 起因を決定的に確定。
- mis_kl と abs_diff は 3 run で不変 -> training-inference mismatch (mis_kl) は dropout/ppo_kl とは
  独立に計算される (更新前 logprob と rollout logprob から算出)。mismatch 検証は dropout 設定の
  影響を受けない。

## 含意

- RL fine-tuning では dropout を切る (attention/hidden とも 0) こと。切らないと ppo_kl や
  clipfrac が dropout 由来のノイズで水増しされ、真の off-policy drift の観測を妨げる。
- 崩壊モニタリングは mis_kl と entropy を軸にする。ppo_kl は dropout artefact を含みうる。
