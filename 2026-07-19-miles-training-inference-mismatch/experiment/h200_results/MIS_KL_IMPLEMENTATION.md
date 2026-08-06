# mis_kl の計算ロジック (ソースコード確定版)

> Source: `radixark/miles` (commit at HEAD of main, 2026-08-05 時点)
> Files: `examples/infra_features/train_infer_mismatch_helper/mis.py` (line 398-466)
>        `miles/backends/training_utils/loss_hub/losses.py` (line 313-344)
>        `miles/backends/training_utils/loss_hub/math_utils.py` (line 139-185)

## 計測の仕組み

```
SGLang (rollout engine)          Megatron-LM (trainer)
        │                                │
        │  rollout_log_probs             │  train_log_probs (= trainer の再 forward 値。
        │  (per-token logprob            │  (per-token logprob from trainer's
        │   from SGLang forward)         │   forward on the SAME tokens)
        │                                │
        └───────────┬────────────────────┘
                    │
                    ▼
          compute_mis_weights() / add_ppl_metrics()
                    │
                    ▼
         TensorBoard scalars (train/mis_*)

Note: train/train_rollout_logprob_abs_diff と train/train_rollout_kl は
losses.py (loss 計算パス) で別途計算される。mis.py を経由しない。
```

両エンジンは**同じ重み・同じトークン列**に対して forward pass を実行する。
その logprob の差を 4 つの視点で集約したのが以下の指標群。

## TB スカラー名と計算式の完全対応

### 1. `train/mis_kl` — KL divergence (k3 estimator)

```python
# mis.py:428-429 (add_ppl_metrics 内)
log_ratio = train_log_prob - rollout_log_prob          # per-token
k3_kl_matrix = torch.exp(log_ratio) - log_ratio - 1   # Schulman k3
# → masked_mean over tokens → TensorBoard
```

**数学的に**: KL(π_rollout || π_train) の **k3 推定量** (Schulman blog 準拠)

$$\hat{KL}_{k3} = \mathbb{E}\left[ e^{r} - r - 1 \right], \quad r = \log\frac{\pi_{\text{train}}}{\pi_{\text{rollout}}}$$

性質:
- 非負 (k1 と違い負にならない。k2 も非負だが、k3 は加えて unbiased)
- 2 分布が近いとき k1 より低分散 (Schulman blog の経験的主張)。ただし乖離が大きい (r >> 0) とき exp(r) 項で分散は爆発する
- r が小さいとき $\approx r^2/2$ (= k2 estimator に一致)

Reference: http://joschu.net/blog/kl-approx.html

### 2. `train/mis_ppl_ratio` — Perplexity ratio

```python
# mis.py:433-445
mean_log_prob_training = masked_mean(train_log_prob, loss_mask)
mean_log_prob_rollout  = masked_mean(rollout_log_prob, loss_mask)
log_ppl_diff = mean_log_prob_rollout - mean_log_prob_training
ppl_ratio = torch.exp(log_ppl_diff)
```

**数学的に**:

$$\text{ppl\_ratio} = \frac{\text{PPL}_{\text{train}}}{\text{PPL}_{\text{rollout}}} = \exp\left(\bar{\ell}_{\text{rollout}} - \bar{\ell}_{\text{train}}\right)$$

ここで $\bar{\ell} = \frac{1}{T}\sum_t \log\pi(a_t|s_t)$ (sequence-level の平均 log-prob)。

1.0 なら sequence-level の平均 logprob が一致 (per-token が相殺している可能性あり)。1.001 は差 0.1% 相当。

### 3. `train/mis_chi2_token` — Chi-squared divergence

```python
# mis.py:450-456
log_ratio = train_log_prob - rollout_log_prob
log_ratio_safe = torch.clamp(log_ratio, min=-20.0, max=20.0)
rho_token = torch.exp(log_ratio_safe)                  # ρ = π_train / π_rollout
rho_squared_token = rho_token.square()
chi2_token = masked_mean(rho_squared_token, loss_mask) - 1.0
```

**数学的に**:

$$\chi^2(\pi_{\text{train}} \| \pi_{\text{rollout}}) = \mathbb{E}\left[\rho^2\right] - 1, \quad \rho = \frac{\pi_{\text{train}}}{\pi_{\text{rollout}}}$$

IS weights の二次モーメント。mis_kl より裾 (外れ値トークン) に敏感。

### 4. `train/train_rollout_logprob_abs_diff` — 生の絶対差

```python
# losses.py:319-323
rollout_log_probs = torch.cat(batch["rollout_log_probs"], dim=0)
abs_diff = (train_scored_log_probs - rollout_log_probs).abs()
train_rollout_logprob_abs_diff = sum_of_sample_mean(abs_diff)
```

**数学的に**:

$$\frac{1}{N}\sum_{n=1}^{N}\frac{1}{T_n}\sum_{t=1}^{T_n}\left|\log\pi_{\text{train}}(a_t) - \log\pi_{\text{rollout}}(a_t)\right|$$

KL の形を仮定しない最も素朴な指標。方向 (どちらが大きいか) の情報を捨てている。

### 5. `train/train_rollout_kl` — もう一つの KL (losses.py 独自)

```python
# losses.py:326
rollout_train_kl = compute_approx_kl(
    rollout_log_probs, train_scored_log_probs, kl_loss_type="low_var_kl"
)
```

k3 推定量 + 安全 clamp ([-10, 10])。
`compute_approx_kl(rollout_log_probs, train_scored_log_probs, "low_var_kl")` は内部で
`log_ratio = rollout - train` → k3 branch で `-log_ratio` = `train - rollout` → mis.py と**同じ式・同じ方向**。
clamp 範囲だけが異なる (losses.py は [-10, 10]、mis.py の k3_kl は clamp なし)。
崩壊時 (r >> 10) に値が分かれる。変数名 `rollout_train_kl` は引数順に由来し KL の方向とは逆を示唆するが、実際は KL(rollout || train) である。

## 計算される場所のまとめ

| TB scalar | 計算場所 | 入力 | 集約 |
|---|---|---|---|
| `train/mis_kl` | `mis.py:add_ppl_metrics` (L428-429) | rollout_log_prob, train_log_prob | sum_of_sample_mean: 各系列内 mean → 系列間 mean (losses.py 経由) |
| `train/mis_ppl_ratio` | `mis.py:add_ppl_metrics` (L444) | 同上 | exp(sequence-mean log-prob diff) |
| `train/mis_chi2_token` | `mis.py:add_ppl_metrics` (L455) | 同上 | E[ρ²] - 1 |
| `train/train_rollout_logprob_abs_diff` | `losses.py` (L323) | train_scored_log_probs, rollout_log_probs | sample-mean of |diff| per token |
| `train/train_rollout_kl` | `losses.py` (L326) | 同上 | k3 with clamp[-10,10] |

## 重要な注意

1. **`mis_kl` は KL(π_rollout || π_train) であり、KL(π_train || π_rollout) ではない。**
   理由: トークンは**rollout policy (SGLang) からサンプルされている**ので、
   `masked_mean` は E_{π_rollout}[·] の MC 推定。k3 推定量に `r = log(π_train/π_rollout)` を
   入れると `E_{π_rollout}[exp(r) - r - 1]` = KL(rollout || train) になる。
   注意: `mis_chi2_token` は χ²(**train** || rollout) で**方向が逆**。

2. **k3 推定量は非負。** したがって `mis_kl >= 0` は常に成り立つ。0 なら完全一致。

3. **per-token ダンプとの関係**: 集約前の per-token 値 (`k3_kl_matrix`) は
   per-token dump 計装で書き出され、位置プロファイル実験 (`PP_POSITION_PROFILE.md`) で使用。

4. **TIS を有効にしても mis_kl の計算自体は変わらない。** `add_ppl_metrics` は
   `compute_mis_weights` の中で TIS の on/off に関わらず常に呼ばれる (L206)。
   TIS は IS weights を修正するだけで、mismatch の測定自体には影響しない。
