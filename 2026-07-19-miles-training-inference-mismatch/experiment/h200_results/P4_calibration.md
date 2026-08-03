# P4: H100 -> H200 キャリブレーション (完了)

> **データ裏付け: TB_ONLY (単一ソース)** — 本ファイルの数値は run `h200_p4_calib` の TensorBoard event file に
> 由来する。判定と引用可否の定義は同ディレクトリの `DATA_STATUS.md`、照合コマンドは
> `python3 verify_results.py` (Ray head pod)。数値を他の文書へ転記する前に必ず照合する。


条件: Qwen3-4B dense, colocated, 1ノード8GPU, TP1/PP1/CP1, LR 1e-6, bf16,
dropout 0, seed 1234/rollout-seed 42, NUM_ROLLOUT=1 (step 0 のみ)。
H100 baseline と同一設定。job raysubmit_EiwSEz1HSypFbtrF、SUCCEEDED。

| メトリクス | H100 (p5.48xlarge) | H200 (p5en.48xlarge) | 差 |
|---|---|---|---|
| train/mis_kl | 0.000632 | **0.000627** | 0.8% |
| train/ppo_kl | 0.0 | 0.0 | 一致 |
| train/train_rollout_logprob_abs_diff | 0.0130 | 0.0127 | 2.3% |

## 読み取り

mis_kl の差は 0.8% で、slime 自身の run-to-run spread (0.00053-0.00074、約±17%) より
桁で小さい。H100 と H200 は同じ GH100 ダイで SM 数も 132 で同一、違いは HBM 容量
(76 -> 143GB) と帯域なので、この一致自体は強い主張ではない (Fable の指摘)。

意味があるのはコントロールとしての側面。HBM が倍増して SGLang の KV プールサイズも
CUDA graph のキャプチャバッチも変わったのに mis_kl は動かない。つまり
**ランタイムのリソース依存の構成変化は mismatch に影響しない**ことが確認できた。
本当に意味のあるハード軸は Hopper vs Blackwell (B300) だが今回はスコープ外。

同時に、インフラ変更後もハードコードが残っていないことの実証にもなった:
node-role (gpu-p5 -> gpu-p5en)、EFA 枚数 (32 -> 16)、HBM 容量が変わっても
env の設定変更だけで完走している。

## 副産物: weight sync の予備値

構造化ログに `fn=update_weights phase=end ok=true elapsed_s=0.5` が全 rank で出ていた。
H200 colocated (CUDA IPC) = **0.5s**。B300 colocated の 1.5s に対し 3 倍速い。
P3 の事前予測は「colocated が遅いのは ipc_collect() GC と Ray IPC handle 往復という
ソフトウェア要因なのでハード不変で 1.5s が再現する」だったので、これは予測と食い違う。
P3 を正式に測る価値が上がった (B300 固有要因だった可能性)。
なお HBM は 139.8GB のうち update_weights 後 18.83GB 使用で余裕あり。
