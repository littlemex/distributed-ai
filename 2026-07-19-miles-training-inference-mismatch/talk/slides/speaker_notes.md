## Slide 1 -- Title

[EN]
Self-intro: "I'm <name> from <team>. I cover <specialist area>." Thank you for the opportunity to present today.

The network side has been covered many times at this monthly sync, so today I focused on the parts of RL post-training other than the network, and I will present what I organized.

Three topics: the CPU/GIL bottleneck, the rollout/training scaling asymmetry, and the training-inference numerical mismatch.

[JA]
自己紹介:「<チーム>の<名前>です。<領域>を担当しています」発表の機会をいただき、ありがとうございます。

ネットワークについてはこのmonthly syncで何度も取り上げられているので、今日はRL post-trainingのネットワーク以外の部分にフォーカスして、整理した内容を発表します。

扱うのは次の3つです。CPU/GILのボトルネック、rolloutとtrainingのスケーリング非対称性、trainingとinferenceの数値的なミスマッチです。

## Slide 2 -- RL post-training basics: GRPO

[EN]
Before we get to the infrastructure problems, here is the basic loop, using GRPO as the example. The policy is the model we are training, and it runs on the GPU. Given a prompt, it generates actions, like choosing moves in a game. Those actions are then evaluated in an environment on the CPU, for example by playing out the game or running a tool, and each finished episode returns one reward, here a simple win or loss.

GRPO's key idea is that there is no separate value or critic model. Instead, we run multiple episodes from the same prompt, in this figure five, and compare each reward to the group average shown by the dashed line. Episodes that scored above average get reinforced, meaning their actions become more likely, while below-average ones get suppressed. Those adjustments become a policy weight update, and the loop repeats.

GRPO is one of the RL algorithms used in post-training. The workload it trains on can be anything: tool use, coding, math, and so on. In every case the structure is the same. The GPU generates a response, and the CPU evaluates it by scoring with a reward model or by actually executing tool calls and checking whether they succeed.

[JA]
インフラの話に入る前に、GRPOを例に基本のループを説明します。ポリシーとは学習対象のモデルのことで、GPU上で動き、プロンプトを受けて行動を生成します。たとえばゲームで手を選ぶようなイメージです。その行動はCPU上の環境で評価されます。ゲームを最後までプレイしたり、ツールを実行したりして、1エピソードごとに1つの報酬、ここでは勝ち負けが返ってきます。

GRPOのポイントは、価値関数やクリティックのような別モデルを使わないことです。代わりに同じプロンプトから複数のエピソード、図では5本を実行し、各報酬をグループ平均、点線の位置と比較します。平均より良ければ強化、悪ければ抑制し、その結果でポリシーの重みを更新します。

GRPOはpost-trainingで使われるRLアルゴリズムの1つです。学習対象のワークロードはツール利用、コーディング、数学など何でも構いません。どの場合でも構造は同じです。GPUがレスポンスを生成し、CPUがそれを評価します。評価とは、reward modelでスコアリングするか、実際にtool callを実行して成功したか確認することです。

## Slide 3 -- GRPO RL loop: example slime disaggregated rollout and training

[EN]
Let's now map the conceptual diagram from the previous slide onto a real framework called slime. slime is an RL post-training framework that combines SGLang for the generation side and Megatron for the training side, with Ray orchestrating the two. The generation phase is called the rollout: this is where the model produces responses, and it corresponds exactly to the generate step in the game example from the last slide.
The figure shows a disaggregated topology, meaning rollout and training run on separate GPU pools connected over the network. When both share the same GPUs, that is called colocated. Following the five numbered steps: rollout generates sequences, the sequences and log-probs are collected across the network, rewards and advantage normalization are computed, training runs its internal tensor, pipeline, and data parallelism, and finally the updated weights are synced back to the rollout side. The orange boxes are inter-node EFA traffic, while the gray boxes stay on intra-node NVLink.
Two points from this diagram carry through the rest of the talk. First, the KV cache never leaves the rollout side; it stays entirely intra-node. Second, weight sync is the only boundary where training sends state back to rollout. That single boundary is exactly where the hidden constraints and mismatch from this talk's title show up between the training engine and the inference engine, and that is where we go next.

[JA]
先ほどのスライドの概念図から、slimeという実際のフレームワークに当てはめてみます。slimeはRLポストトレーニング向けのフレームワークで、生成側にSGLang、学習側にMegatronを組み合わせ、Rayが全体を統括します。生成のフェーズはロールアウトと呼ばれます。つまりモデルが応答を生成する段階のことで、前のスライドのゲームの例でいうと生成のステップに当たります。
この図はディスアグリゲーテッド構成、つまりロールアウトと学習を別々のGPUプールで動かし、ネットワークで接続する形を示しています。両者が同じGPUを共有する場合はコロケートと呼称します。番号の順に見ると、ロールアウトが系列を生成し、系列とログ確率がネットワーク越しに収集され、報酬計算とアドバンテージの正規化が行われ、学習側が内部でテンソル並列やパイプライン並列やデータ並列を実行し、最後に更新された重みがロールアウト側へ同期されます。オレンジのボックスはノード間のEFA通信を表し、グレーのボックスはノード内のNVLinkに収まる通信を表します。
この図から、この後の話のために覚えておいてほしいポイントは二つです。第一に、KVキャッシュはロールアウト側から一切出ず、ノード内に留まります。第二に、重み同期は学習側がロールアウト側へ状態を送り返す唯一の境界です。この境界こそが学習エンジンと推論エンジンの間で、登壇タイトルにある隠れた制約とミスマッチが現れる場所であり、次のスライドからそこに踏み込みます。

## Slide 4 -- Reference: slime GRPO and miles GRPO on awsome-distributed-training

[EN]
As a reference implementation for what I just showed, the awsome-distributed-training repository already has a slime GRPO test case that runs end-to-end on HyperPod EKS. I contributed several enhancements to that test case and the Frameworks team reviewed those PRs. Thank you for that.
I am currently building a miles GRPO test case in the same repository. miles is a fork of slime.

[JA]
今お見せしたものの動くリファレンスとして、awsome-distributed-trainingリポジトリにslime GRPOのテストケースがすでにあります。HyperPod EKS上でエンドツーエンドに動くものです。このテストケースに対していくつかのエンハンスメントを出し、Frameworksチームにレビューいただきました。ありがとうございます。
現在、同じリポジトリにmiles GRPOのテストケースを作成中です。milesはslimeのフォークです。

## Slide 5 -- Beyond the network in GRPO

[EN]
This slide summarizes the three things to be aware of beyond the network when running GRPO at scale. The bottom bar shows one example of a cycle time breakdown. Rollout generation dominates at tens of seconds. actor_train, the backward pass and optimizer step, takes 20 to 30 seconds. Weight sync over the network is about 0.5 seconds, under 1 percent of the total cycle. The network matters, but it may not be the dominant cost.
Now look at the two pools. Training on the left is a fixed topology. You set TP, PP, and DP at launch and it does not change while the job runs. Rollout on the right is an elastic pool. It uses both GPU for generation and CPU for environment evaluation, and you can scale them independently. These two sides scale differently, and that asymmetry is something to keep in mind when sizing a cluster.
The red boundary at the top is the point that requires attention. The weight sync arrow and the trajectory arrow are the only information exchange between training and rollout. If the two engines compute slightly different numbers for the same tokens, that difference accumulates silently until the policy collapses. That mismatch-induced collapse is the main subject of this talk, and we go into it next.

[JA]
このスライドはGRPOをスケールで動かすときにネットワーク以外で意識すべき3つのことをまとめています。下のバーはサイクルタイムの内訳の一例です。ロールアウトの生成が数十秒で支配的です。actor_train、つまりbackwardとoptimizer更新が20から30秒です。ネットワーク経由のweight syncは約0.5秒、サイクル全体の1%未満です。ネットワークは重要ですが、支配的なコストではない可能性があります。
次に2つのプールを見てください。左のtrainingは固定トポロジーです。TP、PP、DPを起動時に設定したら、ジョブの実行中は変わりません。右のrolloutは弾性プールです。生成用のGPUと環境評価用のCPUを使い、それぞれ独立にスケールできます。この2つのスケールの仕方が違うことは、クラスタのサイジングで意識しておくべき点です。
上部の赤い境界が注意が必要なポイントです。weightsの矢印とtrajectoriesの矢印が、trainingとrolloutの間の唯一の情報交換です。もし2つのエンジンが同じトークンに対して微妙に異なる数値を計算していたら、その差がサイレントに蓄積し、最終的にポリシーが崩壊します。このmismatch起因の崩壊が今日の本題であり、次から詳しく見ていきます。

## Slide 6 -- What breaks RL post-training?

[EN]
What silently breaks RL post-training from a place you are not looking at?

[JA]
何がRL post-trainingを、見えないところから壊すのでしょうか。

## Slide 7 -- Terminology: KL divergence, ppo_kl, mis_kl

[EN]
Let me define three terms that appear throughout the rest of this talk. First, KL divergence. This is a measure of how far one probability distribution diverges from another. It is not a symmetric distance, but it tells you how different two distributions are over the same set of outcomes.
Now, log_probs. When a model processes a token sequence like "The cat sat on," it assigns one log-probability to each token, meaning how likely the model thought that token was. So log_probs is just a column of numbers, one per token position. KL divergence compares two such columns position by position.
ppo_kl lives entirely inside the training engine. You take the same token sequence, forward it through the weights before the update to get old_log_probs, then forward it through the weights after the update to get new_log_probs. The KL divergence between these two columns is ppo_kl. It measures how much one gradient step moved the policy. Same engine, same tokens, different moments in time.
mis_kl lives at the boundary between two engines. You take the same token sequence, forward it through the rollout engine to get rollout_log_probs, and forward it through the training engine to get trainer_log_probs. The KL divergence between those two is mis_kl. After weight sync, both engines hold the same weights, so in theory these numbers should be identical. In practice, the computation paths differ slightly, and a gap appears. Same weights, same tokens, same moment, different engines.
The rest of this talk is about what happens when that gap is not zero.

[JA]
この後ずっと出てくる3つの用語を定義します。まずKL divergenceです。ある確率分布がもう1つからどれだけ乖離しているかを測る尺度です。対称的な距離ではありませんが、同じ事象集合上で2つの分布がどれだけ違うかを教えてくれます。
次にlog_probsです。モデルが「The cat sat on」のようなトークン列を処理するとき、各トークンに対して1つの対数確率を付けます。そのトークンがどれくらいありそうだとモデルが判断したか、という数値です。つまりlog_probsはトークン位置ごとに1つの数値が並んだ列です。KL divergenceはこのような2つの数値列をポジションごとに比較します。
ppo_klはtraining engineの内部で完結します。同じトークン列を更新前の重みでforwardしてold_log_probsを得て、更新後の重みでforwardしてnew_log_probsを得ます。この2列のKL divergenceがppo_klです。1回のgradient stepでpolicyがどれだけ動いたかを示します。同じエンジン、同じトークン、時間が違うだけです。
mis_klは2つのエンジンの境界に存在します。同じトークン列をrollout engineでforwardしてrollout_log_probsを得て、training engineでforwardしてtrainer_log_probsを得ます。この2列のKL divergenceがmis_klです。weight sync後は両エンジンが同じ重みを持っているので、理論上はこの数値は完全に一致するはずです。しかし実際は計算経路が微妙に異なるためギャップが生じます。同じ重み、同じトークン、同じ時点、エンジンだけが違います。
この後の話は、このギャップがゼロでないときに何が起きるか、です。

## Slide 8 -- Prior work: what was known before us

[EN]
These are the key prior works I picked up for context, not an exhaustive survey.
slime, THUDM, 2025. When the slime team first ran disaggregated GRPO training, they observed silent policy collapse and traced it to the numerical mismatch between SGLang and Megatron. As a result, slime explicitly logs mis_kl and implements truncated importance sampling as a defense, capping the importance ratio so the mismatch cannot drive unstable gradient updates. To my knowledge it was the first framework to log this metric explicitly.
Beyond Precision, arXiv 2602.01826, February 2026. This paper formalized the mismatch as an optimization theory problem. Theorem 3.1 derives an upper bound of order T squared, meaning per-token numerical differences can accumulate across token positions, and in the worst case the cumulative effect grows quadratically with sequence length T. The paper also proposed learning rate scheduling as an additional defense.
KIVI, arXiv 2402.02750, February 2024. Background only. It analyzed how aggressive KV cache quantization changes the output probability distribution. It did not connect this to RL post-training or mis_kl, but it provides the background for why KV cache fp8 amplifies the mismatch.

[JA]
以下は網羅的なサーベイではなく、文脈理解のために拾った主要な先行研究です。
slimeはTHUDMによる2025年のフレームワークです。開発チームは分離型のGRPO学習を初めて実行した際に、ポリシーが静かに崩壊する現象を観測し、その原因をロールアウトエンジンSGLangと学習エンジンMegatronの間の数値的な不一致に突き止めたと報告されています。この経緯からslimeはmis_klという指標を明示的にログしており、対策としてtruncated importance samplingを実装しています。重要度比に上限を設けることで不一致が不安定な勾配更新を引き起こすのを防ぐ仕組みです。私の知る限り、この指標を明示的に記録した最初のフレームワークです。
Beyond Precisionは2026年2月のarXiv 2602.01826で、この不一致を最適化理論の問題として定式化しました。定理3.1はTの二乗のオーダーの上界を導出しています。トークンごとの数値差が系列に沿って蓄積し、最悪の場合その累積効果が系列長Tに対して二次的に増大するという主張です。追加の対策として学習率スケジューリングも提案されています。
KIVIは2024年2月のarXiv 2402.02750で、背景知識として挙げます。強いKVキャッシュ量子化が出力確率分布をどう変えるかを分析した研究です。RLポストトレーニングやmis_klとの接続はしていませんが、KVキャッシュのfp8がなぜ不一致を増幅するのかを理解するための土台になります。

## Slide 9 -- This work: per-kernel attribution of the amplification

[EN]
This is where this work sits relative to the prior research. slime discovered the phenomenon and built TIS as a defense. Beyond Precision formalized the theory and derived the O(T^2, T squared) bound. What I add is the causal attribution: KV cache quantization alone drives the amplification. CUDA graph and the triton attention backend are irrelevant. The effect is monotone in mantissa bits, with e4m3 giving roughly 12x amplification and e5m2 roughly 45x.
Beyond the per-kernel attribution itself, identifying what does NOT matter is also a contribution of this work. Specifically: at least on H100 and H200, there is no hardware dependence, with the two differing by only 5.4 percent in baseline mis_kl, which is within run-to-run noise. At least across miles and slime, there is no framework dependence, with both producing the same results. And it is not a single-seed accident, with all 3 seeds showing the same direction. These negative results mean the finding is structural, not an artifact of a particular setup. Data is shown primarily from miles, and the rest of the talk uses H200 data. Details are in the following slides.

[JA]
先行研究に対する本研究の位置づけです。slimeが現象を発見しTISで防御策を構築しました。Beyond Precisionが理論を定式化しO(T^2)の上界を導出しました。私が追加するのは因果帰属です。増幅を引き起こすのはKVキャッシュ量子化のみであり、CUDAグラフやtritonアテンションバックエンドは無関係です。効果は仮数部ビット数に対して単調で、e4m3で約12倍、e5m2で約45倍です。
カーネル帰属そのものに加えて、何が影響しないかを特定したことも本研究の貢献です。具体的には、少なくともH100とH200ではハードウェア依存がありません。両者のベースラインmis_klの差は5.4パーセントでrun間ばらつきの範囲内です。少なくともmilesとslimeではフレームワーク依存がありません。両方で同じ結果が得られています。そしてシングルシードの偶然でもありません。3シードすべてで同じ方向性を確認しています。これらの否定的な結果は、この現象が特定のセットアップのアーティファクトではなく構造的であることを意味します。データは主にmilesによるもので、以降はH200のデータで進めます。詳細は後続のスライドで示します。

## Slide 10 -- How mis_kl is measured in miles

[EN]
The training-inference mismatch problem is already well known among RL framework developers. All major frameworks including verl, slime, and NeMo-RL have built-in measurement and mitigation mechanisms. miles also has this support, and measuring mis_kl is straightforward. Here is how it works step by step. Step 1: the rollout engine SGLang generates tokens and records per-token log-probabilities during sampling. Step 2: the token sequence and those rollout_log_probs are sent to the training process via Ray. Step 3: the training engine Megatron re-forwards the exact same tokens through its own computation path and produces train_log_probs. Step 4: still inside the Megatron process, at losses.py L206 before backward, the framework computes r = train_log_prob minus rollout_log_prob for each token, then mis_kl = mean of exp r minus r minus 1, the k3 estimator. This scalar goes to TensorBoard every step. The config is minimal: set get_mismatch_metrics to true in the training yaml. On the SGLang side, the --sglang-kv-cache-dtype flag sets the KV cache precision. In this study, setting it to fp8 amplified mis_kl enough to observe it clearly.

[JA]
training-inference mismatch の問題はRLフレームワーク開発者の間ではすでに常識です。verl、slime、NeMo-RL を含む主要フレームワークにはすべて測定と軽減の仕組みが組み込まれています。milesにもこのサポートがあり、mis_klの計測は簡単です。手順は次のとおりです。ステップ1: rolloutエンジンのSGLangがトークンを生成し、サンプリング中にトークンごとのlog-probabilityを記録します。ステップ2: そのトークン列とrollout_log_probsがRay経由でtrainingプロセスに送られます。ステップ3: trainingエンジンのMegatronがまったく同じトークンを自身の計算経路でre-forwardし、train_log_probsを得ます。ステップ4: 同じMegatronプロセス内で、losses.py L206のbackward前の時点で、各トークンの r = train_log_prob 引く rollout_log_prob を計算し、mis_kl = mean of exp r minus r minus 1、k3推定量を出します。このスカラーが毎ステップTensorBoardに記録されます。設定は最小限で、training側のyamlでget_mismatch_metricsをtrueにするだけです。SGLang側の--sglang-kv-cache-dtypeフラグはKVキャッシュの精度を設定します。今回の計測では、これをfp8にすることでmis_klが増幅され、明確に観測できるようになりました。

## Slide 11 -- 2x2 cross-experiment: what amplifies, what destabilizes

[EN]
This slide shows a 2x2 factorial experiment crossing KV cache precision with learning rate. The key finding: fp8 clearly raises mis_kl regardless of LR, but training instability depends on additional factors like LR. With bf16 KV at either LR, mis_kl stays around 0.0006-0.0007 and grad_norm stays at 0.12, completely stable. With fp8 KV at LR 1e-6, mis_kl rises to 0.028 but grad_norm only reaches 0.17 and reward is still climbing at step 14, no sign of instability. With fp8 KV at LR 1e-5, mis_kl reaches 0.399 at step 14 with grad_norm already at 2.78, twenty times higher than normal, and the run eventually reaches reward 0.023 and grad_norm 66.7. The mismatch amplification is structural and LR-independent. Whether it destabilizes training depends on how fast the optimizer moves the weights in response.

[JA]
このスライドはKVキャッシュの精度と学習率を交差させた2x2の実験です。重要な発見は、fp8はLRに関係なくmis_klを明確に上昇させますが、学習の不安定化はLRなどのパラメーターに影響を受けるということです。bf16 KVではどちらのLRでもmis_klは0.0006-0.0007、grad_normは0.12で完全に安定しています。fp8 KVでもLR 1e-6ならmis_klは0.028に上がりますがgrad_normは0.17にとどまり、ステップ14時点でrewardも上昇中で不安定化の兆候はありません。fp8 KVかつLR 1e-5ではステップ14でmis_klが0.399、grad_normが2.78と通常の20倍に達し、最終的にreward 0.023、grad_norm 66.7に至ります。ミスマッチの増幅は構造的でLRに無関係ですが、それが学習を不安定化させるかどうかはoptimizerが重みをどれだけ速く動かすかに依存します。

## Slide 12 -- Mitigating the mismatch: TIS (arXiv:2602.01826)

[EN]
So how do we mitigate this mis_kl? Several methods have been proposed, and today I will explain one of them, TIS, Truncated Importance Sampling, from arXiv:2602.01826, "Beyond Precision."
First, why the error grows. The paper's Theorem 3.1 bounds the gradient error: the gap between the actual gradient and the ideal gradient is at most C times T squared, where T is the response length in tokens and C is the per-token numerical mismatch. The key point for reading the left figure: T squared is an upper bound, a ceiling. A longer response raises the ceiling; it does not force the actual error to grow like T squared. The real error can sit well underneath.
Now what TIS does. Each sample gets a weight that reflects how much the training engine and the rollout engine disagree. Most samples are fine, but a few extreme ones get a huge weight and dominate the update, and that is what drives the collapse. TIS is simple: it just caps that weight. Anything above the cap is clipped off and discarded, so no single sample can run away with the update.
And be honest about what TIS is not. It does not remove the mismatch; it only bounds how much any one sample can push the gradient. The paper notes it reduces variance at the cost of some bias, so it prolongs the stable window rather than eliminating collapse, and it pairs TIS with learning-rate scheduling as the fuller fix.

[JA]
では、この mis_kl はどうすれば緩和できるのでしょうか。さまざまな手法が提案されていますが、今回はそのうちの一つ、arXiv:2602.01826「Beyond Precision」で提案されている TIS、Truncated Importance Sampling について説明します。
まず、なぜ誤差が増えるのか。論文の定理3.1は勾配誤差の上界を与えます。実際の勾配と理想的な勾配の差は、高々 C かける T の2乗です。T は応答のトークン長、C は1トークンあたりの数値ミスマッチです。左の図を読むうえで大事な点は、T の2乗はあくまで上界、つまり天井だということです。応答が長くなると天井は上がりますが、実際の誤差が T の2乗で増えるわけではありません。実際の誤差は天井のはるか下に留まりえます。
次に、TIS が何をするか。各サンプルには、学習エンジンとロールアウトエンジンがどれだけ食い違っているかを表す重みが付きます。ほとんどのサンプルは問題ありませんが、一部の極端なサンプルが巨大な重みを持って更新を支配し、それが崩壊を引き起こします。TIS はシンプルで、その重みにキャップをかけるだけです。キャップを超えた分は切り取って捨てるので、どの単一サンプルも更新を暴走させることができなくなります。
最後に、TIS が何ではないかを正直に。TIS はミスマッチそのものを消すわけではなく、どの1サンプルも勾配をどれだけ押せるかを抑えるだけです。論文は、TIS が多少のバイアスと引き換えに分散を下げると述べており、崩壊を根絶するのではなく安定な窓を延ばすもので、より完全な対策として学習率スケジューリングと組み合わせています。

## Slide 13 -- How we set up TIS in miles (mis.yaml)

[EN]
miles already ships the TIS machinery, so enabling it is just a config file. Here is exactly what we set. The one line that does the work is line 6, tis_upper_bound 2.0: this is the cap. Any importance ratio above 2.0 gets clipped back to 2.0, which is the main valve on variance blow-up. Line 8, tis_batch_normalize true, then rescales the surviving weights back to a batch mean of 1.0 so the clipping does not shift the overall scale. The other flags, including the rejection-sampling veto on line 7, are left at their defaults; I am not going to walk through them today, since the cap on line 6 is the piece that matters for the next slide.

[JA]
miles はもともと TIS の仕組みを持っているので、有効にするのは設定ファイルを書くだけです。今回まさに設定したのがこれです。効いているのは6行目の tis_upper_bound 2.0、これがキャップです。重要度比が 2.0 を超えたら 2.0 に切り詰めます。分散爆発の元栓です。そのあと8行目の tis_batch_normalize true が、生き残った重みを batch の平均 1.0 に戻し、切り詰めで全体のスケールがずれないようにします。7行目の rejection sampling の veto を含む他のフラグはデフォルトのままで、今日は説明しません。次のスライドで効いてくるのは6行目のキャップだからです。

## Slide 14 -- Our measurement: T² collapse vs TIS-flattened

[EN]
Now the same T² picture, but with our actual numbers, all 30 steps straight from TensorBoard. The red curve is TIS off: mis_kl starts at 0.032, is still quiet through the first several steps, and then climbs stage by stage -- past 0.4 around step 14, past 1 around step 17, and up to 31.8 by step 29. It runs away. The red dashed line is an illustrative epsilon-times-T-squared curve with epsilon 0.035, drawn to show the shape of the ceiling; the measured red curve rises underneath it. The blue curve is TIS on: it never leaves the floor, peaking around 0.15 and ending near 0.07 over the full 30 steps, and it tracks the illustrative O(T) line. The faint bands are the min-max over three seeds -- the collapse arms all blow up, the TIS arms all stay flat. The number I want you to take away is at the start versus the end: the epsilon that anchors the T-squared curve, 0.035, is essentially the step-0 mis_kl, 0.032. So one step's worth of mismatch is what got amplified about a thousand-fold by step 29. Turning on the cap flattens that into the O(T) line. Two honest caveats: the epsilon-T-squared and epsilon-T lines are illustrative fits, not the paper's constants, and I only ran 30 steps, so "flat here" is not "flat forever."

[JA]
同じ T の2乗の絵を、今度は実測値で見せます。全30ステップ、TensorBoard からそのまま出しています。赤い曲線が TIS オフです。mis_kl は 0.032 から始まり、最初の数ステップは静かで、そこから段階的に登ります。ステップ14前後で 0.4 を超え、ステップ17前後で 1 を超え、ステップ29で 31.8 まで達します。暴走です。赤い破線は illustrative な イプシロン かける T の2乗の曲線で、イプシロンは 0.035、天井の形を示すために描いています。実測の赤い曲線はその下を登ります。青い曲線が TIS オンです。30ステップを通じて床から離れず、最大でも 0.15 程度、最後は 0.07 付近で終わり、illustrative な O(T) の線をなぞります。薄い帯は3シードの min-max で、崩壊アームは全部暴走し、TIS アームは全部平坦です。持ち帰ってほしい数字は最初と最後の対比です。T の2乗の曲線を固定するイプシロン 0.035 は、ステップ0の mis_kl 0.032 とほぼ同じです。つまり1ステップ分のミスマッチが、ステップ29までにおよそ千倍に化けたということです。キャップを入れると、それが O(T) の線まで平坦化します。正直な注記が二つ。イプシロン かける T の2乗、およびイプシロン かける T の線は illustrative なフィットで、論文の定数ではありません。そして私は30ステップしか回していないので、「ここで平坦」は「永遠に平坦」ではありません。

## Slide 15 -- Key takeaways

[Takeaways (shown on slide)]
- The network isn't the bottleneck — weight sync is under 1% of the GRPO cycle; the silent constraints are elsewhere.
- Training–inference mismatch (mis_kl) is the real hidden killer: rollout and training score the same tokens slightly differently, and the gap compounds.
- This work — per-kernel attribution: KV-cache quantization alone drives the amplification (e4m3 ≈ 12×, e5m2 ≈ 45×); CUDA graph and the triton backend don't matter.
- The negative results matter too: no hardware dependence (H100 ≈ H200), no framework dependence (miles ≈ slime), reproduces across 3 seeds — so it's structural, not an artifact.
- Amplification is structural and LR-independent; collapse is not — fp8 raises mis_kl at any LR, but it only destabilizes training when LR is also high.
- TIS (arXiv:2602.01826) caps the runaway: a cap of 2.0 flattens the T²-shaped blow-up to O(T); it bounds each sample's push rather than removing the mismatch.

[EN]
To wrap up. Today I focused on the mismatch, to introduce a hidden failure mode of RL post-training to you all on the computing side. The training-inference mismatch is where the rollout engine and the training engine put slightly different numbers on the same tokens, and that gap compounds until it silently breaks the run. What I add on top of prior work is the causal attribution: KV-cache quantization alone amplifies the mismatch, monotonically in mantissa bits, while CUDA graph and the attention backend do not. The negative results — no hardware dependence, no framework dependence, and reproduction across three seeds — say this is structural rather than a quirk of one setup. And TIS is the simple mitigation: capping the importance ratio at 2.0 flattens the T²-shaped blow-up back to O(T). The broader lesson: when we lean on hardware capabilities like quantization, we have to weigh their side effects from several angles — this case, I hope, made that point concrete again.

[JA]
まとめます。今回は mismatch に焦点を当てて、RL post-training の隠れた failure を、Computing をやられている皆さんに紹介しました。training-inference mismatch は、ロールアウトエンジンと学習エンジンが同じトークンにわずかに異なる数値を付け、その差が積み上がって、最終的に学習を静かに壊すというものです。先行研究に私が加えたのは因果帰属で、ミスマッチを増幅するのは KV キャッシュ量子化だけ、仮数部ビット数に対して単調であり、CUDA グラフやアテンションバックエンドは効きません。否定的な結果、つまりハードウェア依存なし、フレームワーク依存なし、3シードでの再現は、この現象が特定構成のクセではなく構造的であることを示します。そして TIS が簡潔な対策で、重要度比を 2.0 でキャップすると、T の2乗型の暴走が O(T) まで平坦化します。より大きな教訓として、量子化のようなハードウェアケイパビリティを有効に活用する際には、その影響をさまざまな視点から考慮しなければならないことを、今回のケースで改めて理解いただけたのではないでしょうか。
