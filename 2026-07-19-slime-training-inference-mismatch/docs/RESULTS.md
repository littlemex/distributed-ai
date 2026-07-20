# 検証結果: training-inference mismatch は最適化問題か

主軸論文「Beyond Precision: Training-Inference Mismatch is an Optimization Problem
and Simple LR Scheduling Fixes It」(arXiv:2602.01826) を SLIME GRPO (Qwen3-4B dense,
colocated, TP1/PP1/CP1, 単一ノード H200 x8) で検証した記録。

rollout エンジン (SGLang) と trainer (Megatron-LM) の logprob mismatch が学習崩壊を
引き起こすという主張を、mismatch を人工的に増幅する装置 (KV cache fp8 量子化) を作って
再現し、崩壊の機序と補正による救済まで対照実験で示した。

## 一行結論

論文の主張は正しい。ただし崩壊が顕在化するかは mismatch の絶対量 (mis_kl) 次第で、それは
rollout/trainer の数値経路差 (エンジン・精度) の大きさで決まる。素の bf16 SGLang vs Megatron
では mis_kl ~6e-4 と極小で崩壊せず (良性)、KV cache を fp8 に量子化して mismatch を 54 倍に
増幅すると、bf16 では安定だった学習率でも崩壊した。適切な補正 (cap 付き importance sampling)
で救済できる。実務者はまず自分のスタックで mis_kl を測り、大きい場合のみ cap 付き IS を使うべき。

## 因果構造 (全て LR 1e-5 固定、dropout=0、seed 固定、response 8192、temp 1.0)

差分を 1 つずつ変えた対照実験:

| run | rollout / 補正 | mis_kl の挙動 | reward | entropy | 結末 |
| --- | --- | --- | --- | --- | --- |
| baseline | bf16 / なし | 0.0006 一定 | 安定 | 安定 | 崩壊せず (mismatch 極小) |
| amplified | KV fp8 / なし | 0.03 -> 2.49 指数発散 | 0.69 -> 0.38 | 0.48 -> 0.18 低下 | 崩壊 (bias 駆動) |
| rollout-logprobs | KV fp8 / logprob 生置換 | 0.008 に抑制 | step4 で 0 | 0.4 -> 1.2 上昇 | 崩壊 (variance 駆動) |
| TIS | KV fp8 / cap 2.0 | 0.024-0.039 安定 | 0.44 -> 0.73 上昇 | 0.27-0.39 保持 | 救済 |
| TIS-nocap | KV fp8 / cap 100 (無効) | 上昇 | 低下 | 0.07 (step6) | 崩壊 |

## 決定的に言えること

1. **mismatch が崩壊の原因**: baseline と amplified の差分は mismatch のみ (mis_kl 0.0006 vs 0.03)。
   同じ LR 1e-5 で bf16 は安定・KV fp8 は崩壊した。
2. **mismatch 発散が崩壊に先行する** (amplified): mis_kl は step8 頃までは静かで、step10-12
   で倍増し、step14 以降に急発散する (miles の同条件 collapse arm の per-step 値が精密な参照:
   <=8 静穏 / ~10-12 倍増 / >=14 暴走)。遅れて reward/entropy が崩れる、論文の因果順序そのもの。
3. **適切な補正で救済できる** (TIS): cap 付き importance sampling で崩壊領域を乗り越え、
   reward が上昇に転じた。
4. **cap こそが救済の因果因子** (TIS vs TIS-nocap): この 2 者の差分は cap の値のみ。
   cap を実質無効化 (upper=100) すると崩壊した。

## bias-variance の二分法 (2 種類の崩壊機序)

entropy の動く向きが崩壊の種類で逆になる。これは弱点ではなく崩壊機序が 2 種類あることの証拠:

- **amplified = bias 駆動の崩壊**: 未補正の mismatch が系統的に歪んだ勾配を生み、方策が誤った
  モードに固着する -> entropy 低下 (collapse)。
- **rollout-logprobs = variance 駆動の崩壊**: fp8 の粗い logprob を生で importance ratio の分母に
  使うと重み分布が heavy-tail 化し、勾配ノイズで方策が拡散する -> entropy 上昇 (diffusion)。
- **TIS = cap で bias-variance トレードオフを調整**: 少量の bias を受け入れて variance を抑える。
  truncated importance sampling の教科書的性質そのもの。

## 補足: ppo_kl は mismatch ではなく dropout の産物

検証中に観測された ppo_kl ~0.30 は、rollout-vs-trainer の off-policy ずれではなく train モードの
dropout が原因だった。詳細は [PPOKL_ROOTCAUSE.md](./PPOKL_ROOTCAUSE.md)。本検証の全 run は
dropout=0 で回し、ppo_kl を実測値化している。mis_kl は dropout 非依存で独立。

## rollout エンジン選択と mismatch の一般化 (今後の検証課題)

mismatch の大きさは rollout エンジンと trainer のカーネル・数値経路差で決まる。本検証の
SGLang vs Megatron は数値経路が比較的揃っており mis_kl は極小だった。一般に mismatch 増幅が
報告されるのは vLLM vs FSDP/HF のようにカーネル差が大きい構成、MoE (routing 非決定性)、
fp8 推論 vs bf16 学習の混合精度、長い応答、大規模モデルである。「vLLM だと崩壊しやすい」は
魅力的な仮説だが本検証では未実証 (SLIME は SGLang 専用実装のため差し替えが容易でない)。
今後の検証課題として記録する。

## 検証の限界 (正直な開示)

- n=1 seed。RL の分散に対して見出し主張は本来複数 seed で確認すべき。
- KV cache fp8 は mismatch を人工的に増幅する装置であり、実運用で自然に生じる mismatch とは源が違う
  (現象は同型だが「機構の独立実証」と表現するのが正確)。
- TIS run は step19 まで。後期の崩壊がないことは未確認。
- 単一構成 (dense 4B / SGLang / Megatron) の測定結果であり、全構成への一般化ではない。
- baseline は truncation 支配 (truncated_ratio ~0.53)。eval-reward gap は別問題。
