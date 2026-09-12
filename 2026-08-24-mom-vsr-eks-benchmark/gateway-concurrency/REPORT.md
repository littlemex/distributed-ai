# stratoclave 課金ゲートウェイの同時実行性能 実測記録

最終更新: 2026-08-24 (JST)

## 結論 (先に要点)

- **この stratoclave デプロイ (ECS Fargate, タスク 2 個、各 0.25 vCPU / 512MB、uvicorn ワーカー 1 個) を経由した MoM ベンチマークで、ゲートウェイを律速要因にせずにモデル性能を測れる同時実行数は、おおよそ 4〜8 が上限。** 8 を超えると achieved throughput は改善せず (計測値は 1.4〜4.6 req/s の間で上下するだけで concurrency=8 以降は伸びない)、レイテンシだけが線形以上に悪化する。
- concurrency=64 では、ゲートウェイ経由の非ストリーミング応答は p50 9.9 秒、ストリーミングの TTFT (最初のトークンまでの時間) は p50 8.3 秒に達した。同じモデル (gemma-4, 実体は google.gemma-4-31b on bedrock-mantle) にゲートウェイを経由せず直接アクセスすると、同じ concurrency=64 で p50 386 ミリ秒、TTFT p50 157 ミリ秒。**つまり concurrency=64 で観測される遅さの 96〜98% はゲートウェイ由来であり、モデル側の限界ではない。**
- 飽和点の根拠は CPU である。DynamoDB のスロットリングは全計測を通じて 0 件、消費キャパシティも無視できる量だった (後述)。ECS サービスの CPU 使用率はスイープ実行中に平均 25〜29%・最大 66〜84.5% まで跳ね上がった (1 分粒度の平均値であることに注意。各ステージは数秒〜20 秒しかないため、実際の秒単位のピークはこれより高い可能性がある — この点は「測れなかったこと」として明記する)。タスクは 2 個から増えず (Application Auto Scaling の対象ではあるが、今回の短時間バーストでは発火しなかった)。
- ゲートウェイの 402 (予算切れ) や upstream の 429 は、今回の全計測 (約 690 リクエスト) を通じて **1 件も発生しなかった。** テナントのドルプール予算 (`stratoclave-tenant-budgets`) とモデル別クォータ (`stratoclave-model-quotas`) はいずれもアイテム数 0 で無効だったため、今回観測した劣化はすべて同時実行容量の問題であり、予算/クォータの誤読の余地はない。

## 対象と実測手順

- ゲートウェイ: ECS Fargate サービス `stratoclave-backend` (cluster `stratoclave-cluster`, us-east-1)。CloudFront URL `https://d8b03j8erit4k.cloudfront.net`。
- 負荷生成元: us-east-1 の EC2 `i-0390229058244a214` に SSM (`AWS-RunShellScript`) で入り、そこから計測した。ローカル (日本) からの計測も予備的に行い、ネットワーク距離がノイズになることを確認した (後述)。
- 計測スクリプト: `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/scripts/sweep.py`。既存の `~/works/data-science/investigations/multitenant-serving-b300/scripts/concurrency_sweep.py` の aiohttp + Semaphore による並行化設計を再利用し、(a) 非ストリーミングも測れるようにした、(b) ゲートウェイのエラー応答 (402 の reason 等) を分類する、(c) ゲートウェイを経由しない直接呼び出し (bedrock-mantle 直叩き / boto3 Converse 直叩き) を同一ツールに統合した点が差分。
- 生の計測結果 (JSON): `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/` 配下の 6 ファイル。
- API キーはローカルのキーファイル (パスは `SCLV_KEY_FILE` で渡す) を使用。値は本記録・スクリプト・結果 JSON のいずれにも書いていない。計測用に EC2 と受け渡し用 S3 バケット (`$BENCH_BUCKET`) に一時配置したが、計測後に両方から削除済み。

## 1. 同時実行スイープ (gemma-4, 非ストリーミング)

concurrency ごとに `max(8, concurrency*3)` 件 (上限 48 件) を投げた。プロンプトは短文、`max_tokens=32`。

| concurrency | n | 所要秒 | ok | err | achieved req/s | p50 (ms) | p95 (ms) | max (ms) |
|---|---|---|---|---|---|---|---|---|
| 1  | 8  | 5.68  | 8  | 0 | 1.41 | 547  | 1463 | 1463 |
| 2  | 8  | 3.72  | 8  | 0 | 2.15 | 745  | 1389 | 1389 |
| 4  | 12 | 5.71  | 12 | 0 | 2.10 | 767  | 3510 | 3510 |
| 8  | 24 | 5.73  | 24 | 0 | 4.19 | 1663 | 2553 | 2746 |
| 16 | 48 | 20.89 | 48 | 0 | 2.30 | 3229 | 4485 | 20883 |
| 32 | 48 | 10.52 | 48 | 0 | 4.56 | 6223 | 7824 | 7833 |
| 64 | 48 | 13.53 | 48 | 0 | 3.55 | 9903 | 10497| 13523|

生データ: `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/gateway-nonstream.json`

**飽和点**: concurrency=8 で achieved throughput が 4.19 req/s に達した後、concurrency=16 では 2.30 req/s に**低下**し、32/64 でも 3.55〜4.56 req/s の範囲を出ない。つまり concurrency を上げても throughput は一切改善せず、レイテンシだけが線形以上に悪化する — これが典型的な飽和 (queueing) の兆候。エラー (402/429/5xx) は全ステージで 0 件だったので、劣化は「拒否」ではなく「順番待ち」による。

## 2. ゲートウェイ経由 vs Bedrock/bedrock-mantle 直叩き (同じモデル)

同じ `google.gemma-4-31b` (client alias `gemma-4`) を、ゲートウェイの `_mantle_transport.py` が使うのと同じ経路 (`aws_bedrock_token_generator.provide_token` でトークンを自前で発行し `bedrock-mantle.us-east-2.api.aws/openai/v1/chat/completions` に直接 POST) で叩いた。

| concurrency | ゲートウェイ p50 (ms) | 直叩き p50 (ms) | ゲートウェイ throughput (req/s) | 直叩き throughput (req/s) |
|---|---|---|---|---|
| 1  | 547  | 231 | 1.41 | 4.22 |
| 2  | 745  | 277 | 2.15 | 2.72 |
| 4  | 767  | 266 | 2.10 | 13.79 |
| 8  | 1663 | 287 | 4.19 | 6.01 |
| 16 | 3229 | 274 | 2.30 | 26.11 |
| 32 | 6223 | 316 | 4.56 | 28.39 |
| 64 | 9903 | 386 | 3.55 | 75.63 |

生データ: `results/gateway-nonstream.json` と `results/direct-mantle-nonstream.json`

concurrency=64 で、直叩きは throughput 75.63 req/s・p50 386ms を出せている。つまりモデル (mantle 側) は 64 並列を問題なくこなせる。ゲートウェイを挟むと同じ 64 並列で throughput は 3.55 req/s (約 1/21)、p50 は 9.9 秒 (約 26 倍) まで悪化する。**この差はゲートウェイが加えているオーバーヘッドそのもの。**

## 3. ストリーミング (`stream: true`) での同じ比較

| concurrency | ゲートウェイ TTFT p50 (ms) | 直叩き TTFT p50 (ms) | ゲートウェイ throughput (req/s) | 直叩き throughput (req/s) |
|---|---|---|---|---|
| 1  | 374  | 59  | 1.75 | 3.24 |
| 4  | 481  | 56  | 4.60 | 13.90 |
| 16 | 2302 | 61  | 4.55 | 42.10 |
| 64 | 8305 | 157 | 4.10 | 66.14 |

生データ: `results/gateway-stream.json` と `results/direct-mantle-stream.json`

ストリーミングでも同じ構図。concurrency=64 でゲートウェイの TTFT p50 は 8.3 秒 (直叩きの約 53 倍)。ストリーミングは接続を長く保持する分、同時接続数の天井は非ストリーミングと質的に違うのではと想定していたが、実測ではゲートウェイ側のボトルネックが支配的で、ストリーミングか否かに関わらず同じ concurrency で同程度に劣化した (TTFT がまさに「モデルが答え始める前の待ち行列」を表しているため、モデルの生成速度ではなくゲートウェイの受付処理が支配していることがここでも確認できる)。

## 4. Converse 経路 (wire_protocol="messages") でも同じ構図か

gemma-4 は bedrock-mantle パススルー (`wire_protocol: "responses"`) だが、Claude 系や `qwen3-next-80b` (`qwen.qwen3-next-80b-a3b`, us-east-1) は Bedrock Converse 経路 (`wire_protocol: "messages"`)。異なるコードパスでも同じ天井が出るかを、安価枠で少量だけ確認した。

| concurrency | ゲートウェイ p50 (ms) | 直接 Converse (boto3) p50 (ms) | ゲートウェイ throughput (req/s) | 直接 throughput (req/s) |
|---|---|---|---|---|
| 1  | 572  | 319 | 1.68 | 3.18  |
| 4  | 1024 | 397 | 3.76 | 10.32 |
| 16 | 3004 | 767 | 4.68 | 13.92 |

生データ: `results/gateway-converse-qwen.json` と `results/direct-converse-qwen.json`

同じ質的パターン (concurrency に対してほぼ線形の劣化、ゲートウェイの throughput が頭打ち)。よって天井は mantle パススルー特有ではなく、**ゲートウェイの共通処理 (受付・予約・ECS タスクの CPU) に起因する**、両 wire_protocol で共通のボトルネックだと言える。

## 5. ボトルネックの同定 (根拠付き)

以下を切り分けた。

### 5.1 ECS タスク数と CPU/メモリ (根拠: CloudWatch)

- `aws ecs describe-services --cluster stratoclave-cluster --services stratoclave-backend` → `desiredCount=2, runningCount=2` (計測前後で変化なし)。
- タスク定義 (`stratoclave-backend:42`) の CPU/メモリ: **256 CPU units (0.25 vCPU) / 512MB**。タスクは 2 個なので合計でも 0.5 vCPU しかない。
- `entrypoint.sh` (`/Users/akazawt/tmp/mom-bench/stratoclave/backend/entrypoint.sh:9`) は `uvicorn main:app --host 0.0.0.0 --port 8000` を `--workers` 指定なしで起動している。つまり**タスクあたり ASGI ワーカー 1 プロセス・イベントループ 1 個**。
- CloudWatch `AWS/ECS CPUUtilization` (サービス平均、対象 `ClusterName=stratoclave-cluster, ServiceName=stratoclave-backend`):

  | 時刻 (JST) | Average | Maximum |
  |---|---|---|
  | 19:44 | 1.3% | 2.9% |
  | 19:45 | 1.4% | 2.8% |
  | 19:46 | 2.4% | 9.6% |
  | 19:47 (gateway-nonstream 実行中) | 25.3% | 66.1% |
  | 19:48 (gateway-nonstream 実行中) | 29.3% | 79.8% |
  | 19:52 (converse 比較実行中) | 26.8% | **84.5%** |

  `AWS/ECS MemoryUtilization` は同じ時間帯で 20〜26% 台のまま動かず、メモリ不足 (OOM) は起きていない。**CPU は明確にアイドル (1〜2%) からスイープ実行中だけ跳ね上がっており、メモリではなく CPU が制約要因であることを示している。**
  - **測れなかったこと**: CloudWatch のこの指標は 1 分粒度の平均/最大で、各ステージは数秒〜20 秒しかない。したがって concurrency=16/32/64 の実行中に単一タスクの CPU が実際に 100% に張り付いていたかどうかは、この粒度では確定できない。Container Insights によるタスク単位・秒単位の CPU を追加取得すれば確定できるが、今回は実行していない。

### 5.2 sync ルート + anyio スレッドプールの構造的上限

- `/v1/chat/completions` は `def chat_completions(...)` という**同期関数** (`/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/chat_completions.py:267`)。FastAPI は同期 `def` ルートを anyio のワーカースレッドプール上で実行する (イベントループ上ではない)。このことはコード内コメントでも明言されている: 「`/v1/messages` と `/v1/chat/completions` のハンドラは sync `def` なので、FastAPI はこれら (と reserve) をスレッドプールで実行する。イベントループではない」(`/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/_pipeline.py:1578-1581`)。
- anyio の `to_thread` の既定のスレッド上限は 40 (プロセスあたり)。タスクあたりワーカー 1 プロセスなので、**タスクあたり最大 40 リクエストしか同時に "実行中" になれない** (残りはスレッド獲得待ちで queueing する)。concurrency=64 を投げると、単純にこの構造的な上限だけで少なくとも 24 リクエストがスレッド獲得すら出来ずに待つ。
- 非ストリーミングの mantle パススルー (`_mantle_chat_completion`, `chat_completions.py:627-654`) は `_mantle_transport.sync_client()` (`/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/_mantle_transport.py:90-97`) という**同期 httpx クライアント**を使う。これはリクエストごとに新規construct され、`mint_bearer_token()` (同ファイル 47-73 行、`aws_bedrock_token_generator.provide_token` を毎回呼ぶ) も毎回実行される。この間ずっとスレッドプールの1スロットを専有する。ストリーミングのmantle パススルーだけは非同期クライアントに切り替えている理由がコード内コメントに明記されている: 「sync generator はストリーム全体 (最大 timeout の 600 秒) の間 anyio ワーカーを保持してしまい、他の全ての sync ルートを飢餓状態にする」(`chat_completions.py:656-661`)。**つまり非ストリーミング経路は設計上、まさにこの「他のリクエストを飢餓させる」構造になっている。**

### 5.3 DynamoDB (予約/決済) — 明確に「否定」できた

- `stratoclave-user-tenants` (per-user トークン残高)・`stratoclave-tenant-budgets` (テナントのドルプール)・`stratoclave-model-quotas` はいずれも **`BillingMode: PAY_PER_REQUEST`**。
- `stratoclave-tenant-budgets` と `stratoclave-model-quotas` は **ItemCount=0**。つまり今回のテナント (`default-org`) にはドルプール予算もモデル別クォータも設定されておらず、`reserve_credit_for_model` は最も単純な経路 (`/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/_pipeline.py:1171-1179` の "No routing config at all → passthrough") を通る。TransactWriteItems によるホットパーティション競合 (タスク側で当初想定していた「同一テナント/同一ユーザーへの予約集中」) は、**この経路では発生していない** — それはドルプール型テナント向けの `_reserve_over_candidates` / プール2テーブル TransactWriteItems 経路 (`_pipeline.py:1553〜`) の話であり、今回のテナントには適用されない。
- 実際に効いているのは `UserTenantsRepository.reserve()` (`/Users/akazawt/tmp/mom-bench/stratoclave/backend/dynamo/user_tenants.py:236-330`) の**単一アイテムの楽観ロック** (`user_id`+`tenant_id` 固定のキー1行に対する `ConditionExpression` 付き `update_item`)。すべてのベンチマークリクエストが同じ API キー = 同じ `user_id`/`tenant_id` を使うため、これが唯一のホットパーティションである。リトライは `_RESERVE_MAX_RETRIES = 5` 回、**`ConditionalCheckFailedException` の場合はバックオフ無しで即時再試行**する (309-315行、`continue` のみ)。
- `AWS/DynamoDB ThrottledRequests` は `stratoclave-user-tenants` / `stratoclave-usage-logs` のいずれも計測window全体で **0 件**。`ConsumedWriteCapacityUnits` も計測中のピーク2分間で 168+224=392 (Sum) — on-demand テーブルの実効上限 (数千 WCU/秒のオーダー) に対して無視できる量。
- 結論: **DynamoDB のスロットリングやホットパーティション競合が飽和点の主因である証拠は無い。** 402 (`personal_budget_exhausted`) も含め、エラーは全計測を通じて 0 件だった。単一アイテムへの楽観ロック競合は理論上レイテンシに寄与しうる (再試行のたびに GetItem+UpdateItem のラウンドトリップが増える) が、us-east-1 タスクから us-east-1 DynamoDB への単発呼び出しは通常 5〜15ms 程度であり、観測された秒単位のレイテンシ膨張を主として説明できるものではない。**このためDynamoDBは律速要因から除外し、CPU (5.1, 5.2) を主因と判定した。**

### 5.4 CloudFront / ALB

- 全計測を通じて CloudFront が返したエラー (503 等) は 0 件だった (全リクエストが 200 で応答し、劣化はステータスコードではなく latency として現れた)。CloudFront と ALB を分離した個別計測は行っていない — 理由は、エラーが一件も出ていないため CloudFront/ALB 層でリクエストが拒否・分離されている証拠がなく、5.1/5.2 の CPU/スレッドプール要因で説明が完結するため。**これは「測らなかったこと」として明記する**: ALB 直のURLを使えばCloudFrontのオーバーヘッド分だけを分離測定できるが、今回は実施していない。

### 5.5 upstream (Bedrock / bedrock-mantle) の 429

- 直叩き (ゲートウェイ無し) の計測でも、concurrency=64 まで 429 やエラーは 0 件だった (2/3/4節の表を参照)。**upstream 側のスロットリングは、今回の規模の負荷では発生していない。** ゲートウェイ経由の劣化を upstream の 429 と誤読する余地はない。

## 6. ローカル (日本) 計測 vs us-east-1 EC2 計測の差 (参考)

本計測を始める前、ローカル (日本) から同じスイープの小規模版を実行したところ、concurrency=4 で p50=1338ms・max=6424ms という、us-east-1 から測った同条件 (p50=767ms, max=887ms 前後) より大きく劣る値が出た。**この差はネットワーク距離 (日本 ⇔ us-east-1) のノイズであり、ゲートウェイの実力を過小評価する。** このため本計測の「公式値」は全て us-east-1 の EC2 (`i-0390229058244a214`) から取得したものを採用した。VSR のベンチマーク自体も、可能であれば同じ理由で us-east-1 (あるいはゲートウェイと同一リージョン) から実行するべきである。

## 7. コスト

- 総リクエスト数: 約 690 件 (ゲートウェイ経由 + 直叩きの合計。gemma-4/google.gemma-4-31b 系が約 634 件、qwen3-next-80b 系が約 56 件)。
- すべて `max_tokens` 16〜32、短いプロンプト (1 文)。Claude Opus/Sonnet/Fable は本計測では一切使用していない (初回の動作確認 1 件のみ gemma-4 で実施)。
- ゲートウェイ側の内部クレジット (トークン、実際のドルではない社内会計) の消費は、計測前後の `/api/mvp/me` 比較で 2,549,530 → 2,532,097 (Δ 17,433 トークン)。残高 253 万トークンに対して無視できる消費で、予算枯渇には全く近づいていない。
- 実際の AWS 課金は gemma-4 (bedrock-mantle 経由) と qwen3-next-80b (Bedrock Converse) の少量トークンの推論コストのみで、いずれも安価なモデル。Opus 等の高額モデルは不使用のため、実費は数十円〜百円オーダーと推定する (正確な単価は非公開のため概算)。

## 8. VSR ベンチマーク設計への結論

- **「ゲートウェイが律速せずにモデル性能を測れる同時実行数」は、このデプロイでは概ね 4〜8 (ゲートウェイ全体で、複数モデルへの同時発行を合算した数)。** 8 まではレイテンシの伸びが比較的緩やか (p50 547→1663ms) で throughput もこの区間で最大 (4.19 req/s) に達する。concurrency=16 以降は throughput が頭打ち (2.3〜4.6 req/s の範囲を出ない) のに対しレイテンシだけ増え続け (p50 3.2秒→9.9秒、tailはさらに悪化)、かつ直叩きとの差が数十倍に開く — これはモデルではなくゲートウェイを測っている状態である。
- VSR は複数モデルに同時にリクエストを振り分ける構成のため、**「1 モデルあたりの concurrency」ではなく「ゲートウェイに同時に飛んでいる全リクエスト数の合計」を 8 以下に抑える**必要がある。例えば 5 モデルを比較するなら、各モデルの同時実行は 1〜2 に抑える、あるいはモデルごとに逐次化して合計の同時実行を管理するのが安全。
- ストリーミングでも同じ結論が成り立つ (TTFT が同程度に悪化する)。VSR がストリーミングで応答を取るなら、TTFT の増分をモデルの実力と誤読しないよう、同時実行 8 以下を維持すること。
- 402/429 などのエラーは、今回のテナント設定 (ドルプール・モデルクォータ未設定) では出なかったが、**VSR ベンチマーク本番でテナント設定が変わっている場合 (ドルプールやクォータが有効化された場合) は、5.3 で述べた 2 テーブル TransactWriteItems 経路に切り替わり、挙動が変わる可能性がある。** ベンチマーク実行前に `stratoclave-tenant-budgets` / `stratoclave-model-quotas` のアイテム数を確認し、今回と同じ「無効」状態であることを確認しておくとよい。

## 9. 天井を上げたい場合の選択肢 (提案のみ、実行していない)

いずれも書き込み系操作 (ECS サービス更新・タスク定義更新等) のため、今回は実行せず提案のみとする。

1. **ECS タスクの CPU/メモリを上げる** (例: 256→1024 CPU units)。5.1/5.2 で示した通り CPU が主因なので、最も直接的に効く。副作用: Fargate の時間単価が上がる (256→1024 で単純計算 4 倍)。
2. **uvicorn の `--workers` を増やす、または `desiredCount`/`maxCapacity` を増やす**。現在は 1 タスクにワーカー 1 プロセスで、anyio スレッドプール (40) が実質の上限になっている。`--workers` を増やすか、タスク数を増やして CloudFront/ALB で負荷分散すれば、この構造的上限を並列に多重化できる。副作用: `--workers` はタスク内メモリを消費するため、CPU と合わせて増強が必要。`maxCapacity` (現在 2〜4) を増やすのはコスト増と、DynamoDB の同時書き込み増加 (今回は問題にならなかったが、規模が変われば再検証が必要)。
3. **Application Auto Scaling のスケールアウト判定をより速くする** (現在 min=2/max=4 は設定されているが、今回の数分間のバーストでは発火しなかった)。ベンチマークの負荷パターンが「短時間バースト」である場合、target tracking よりスケジュールベースのスケールアウト (ベンチマーク実行前に desiredCount を一時的に上げておく) が確実。
4. **mantle パススルーの非ストリーミング経路も非同期化する**。現状、非ストリーミングの mantle 呼び出しは同期 httpx クライアントでスレッドプールを専有する (5.2 参照)。ストリーミング経路と同様に非同期化すれば、1 タスクあたりの実効同時実行数を増やせる可能性がある。副作用: アプリケーションコードの変更が必要で、今回の計測スコープ外。
5. **リクエストごとのbearer トークン再発行を止め、TTL 内で再利用する**。現状 `mint_bearer_token` はリクエストごとに呼ばれている (5.2 参照)。CPU 消費の小さな積み上げだが、concurrency が高いほど無視できなくなる。

## 付録: 生成物一覧

- 計測スクリプト: `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/scripts/sweep.py`
- 生の計測結果 (JSON、6 本):
  - `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/gateway-nonstream.json`
  - `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/direct-mantle-nonstream.json`
  - `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/gateway-stream.json`
  - `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/direct-mantle-stream.json`
  - `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/gateway-converse-qwen.json`
  - `/Users/akazawt/eks/distributed-ai/2026-08-24-mom-vsr-eks-benchmark/gateway-concurrency/results/direct-converse-qwen.json`
- 参照した stratoclave ソース (読み取りのみ、変更なし):
  - `/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/chat_completions.py`
  - `/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/_pipeline.py`
  - `/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/_mantle_transport.py`
  - `/Users/akazawt/tmp/mom-bench/stratoclave/backend/dynamo/user_tenants.py`
  - `/Users/akazawt/tmp/mom-bench/stratoclave/backend/entrypoint.sh`
  - `/Users/akazawt/tmp/mom-bench/stratoclave/backend/mvp/defaults/models.json`

---

# 追記: 修正後の再計測 (2026-08-24 22:15 JST)

上の計測を受けて実装を直し (接続プーリング、bearer 再利用、スレッド上限の明示化、
タスク 0.25 vCPU → 1 vCPU、リクエスト数ベースの autoscaling)、
タスク定義 43 / 8 タスクの構成で同じスイープを回した。

## 結果

| 同時実行 | 修正前 GW | 修正後 GW | 直叩き (同時刻) |
|---|---|---|---|
| 1 | 1.41 req/s, p50 547 ms | 1.61 req/s, p50 597 ms | 3.41 req/s, p50 306 ms |
| 8 | 2.15 req/s, p50 745 ms | 1.70 req/s, p50 615 ms | 10.57 req/s, p50 360 ms |
| 64 | 4.19 req/s (c=8), p50 1663 ms | **61.69 req/s, p50 628 ms** | 49.17 req/s, p50 442 ms |
| 256 | 4.56 req/s (c=32), p50 6223 ms | 64.35 req/s, p50 1479 ms | 27.52 req/s, p50 525 ms |
| 512 | 3.55 req/s (c=64), p50 9903 ms | 48.39 req/s, p50 2741 ms | 8.49 req/s, p50 954 ms |
| 1024 | 未計測 | 計測不能 (WAF が遮断) | 21.53 req/s, p50 1836 ms |

アプリ側の天井は **4.5 req/s から 60 req/s 超へ、約 14 倍**。同時実行 64 では
ゲートウェイ経由 (61.7 req/s) が直叩き (49.2 req/s) を上回っており、
この水準ではゲートウェイはもう律速していない。

同時実行 1 と 8 でレイテンシがほぼ変わらないのは想定内である。8 タスクに
least-outstanding-requests で分散するため、少数リクエストではほぼ全てが
別タスクの冷えたプールに当たり、各タスクの最初の 1 本がハンドシェイクを払う。
プーリングの効果は本数が増えてから出る (同時実行 64 の数字がそれ)。

## 天井は容量ではなく 2 つのポリシーだった

同時実行 1024 のステージは **1018 件が HTTP 403** で全滅した。原因は容量ではなく
**WAF のレート制限 (`WAF_RATE_LIMIT_PER_5MIN`、既定 300)** である。送信元 IP あたり
5 分で 300 リクエストなので、持続レートに直すと **1 req/s**。それ以前のステージで
5 分窓を使い切った結果、1024 のステージが丸ごと遮断された。

同時実行 256 と 512 では **402 `personal_budget_exhausted`** が出た (それぞれ 54 件、
250 件)。テストユーザーのトークン予算を使い切ったもので、会計は設計どおり動いている。

つまり単一 IP・単一ユーザーのクライアント (まさに VSR ベンチのハーネス) にとっての
実効的な天井は、いまはアプリの容量ではなく次の 2 つである。

1. WAF のレート制限: 300 リクエスト / 5 分 / 送信元 IP
2. ユーザーのトークン予算

**1024 同時実行を実測で示すには、この 2 つを先に上げる必要がある。** 容量側の
準備 (8 タスク × 128 = 1024 admit) は完了しており、起動ログの
`concurrency_capacity_configured` で `sync_route_threads=128` / `offload_threads=128` /
`mantle_connections=256` / `bedrock_connections=128` を確認済み。

## `BACKEND_REQUESTS_PER_TARGET` の導出

計測から導くと決めていた値をここで確定できる。

- 同時実行 64: 61.69 req/s / 8 タスク = **7.7 req/s/タスク**、p50 628 ms
  (無負荷の 597 ms とほぼ同じ = まだ余裕がある)
- 同時実行 256: 64.35 req/s / 8 タスク = 8.0 req/s/タスク、p50 1479 ms (劣化開始)
- 同時実行 512: 48.39 req/s / 8 タスク = 6.0 req/s/タスク、p50 2741 ms (飽和)

飽和は 8 req/s/タスク 付近で、そこではレイテンシが 2.4 倍に伸びている。レイテンシが
平坦なうちにタスクを足すという方針から、**300 requests/min/task (= 5 req/s/task)** を
採る。これは飽和点の約 62 % で、無負荷レイテンシを保てる水準である。

## 未計測のまま残したこと

- 同時実行 1024 の実測 (WAF と予算が先に当たるため)
- ストリーミングの再計測 (今回は非ストリーミングのみ)
- 8 タスクを超えるスケールアウトの挙動 (今回は floor=ceiling=8 の固定構成で計測したため、
  autoscaling そのものは発火していない)


---

# 追記 2: 同時実行 1024 の実測 (2026-08-25 03:50 JST)

WAF のレート制限を認証済み 614,400 / 5 分に上げ、テストユーザーの残高を 20M トークンまで
追加し、per-phase の duration ログを入れたイメージ (`timing-645ea8e`) を 8 タスクで
デプロイして計測した。

## 結果 — 1024 は捌けている

| 同時実行 | 1 タスクあたり | GW req/s | GW p50 | 直叩き req/s | 直叩き p50 | GW 成功/エラー |
|---|---|---|---|---|---|---|
| 1 | 0 | 2.0 | 493 ms | 3.1 | 276 ms | 8 / 0 |
| 8 | 1 | 10.2 | 361 ms | 18.6 | 312 ms | 16 / 0 |
| 64 | 8 | 42.3 | 549 ms | 11.7 | 332 ms | 128 / 0 |
| 256 | 32 | 81.1 | 1331 ms | 147.9 | 511 ms | 512 / 0 |
| 512 | 64 | **91.9** | 2791 ms | 107.8 | 958 ms | 1024 / 0 |
| 1024 | 128 | 31.7 | 7706 ms | 38.8 | 1873 ms | **1017 / 7** |

同時実行 1024 で **1024 本中 1017 本が 200**。403 (WAF) と 402 (予算) は 1 件も出ていない。
残る 7 件は 504 が 1 件と、負荷生成側の `ClientConnectorError` が 6 件で、後者は
**直叩き側でも同数の 6 件**出ているので負荷生成 EC2 のソケット枯渇であり、
ゲートウェイの問題ではない。

スループットのピークは同時実行 512 での **91.9 req/s** で、修正前の 4.5 req/s から
**約 20 倍**である。

## 1024 での待ちは upstream ではなく自前の会計処理

duration ログ 3,006 本の内訳 (この計測期間全体)。

| phase | p50 | p95 | max |
|---|---|---|---|
| total | 2014 ms | 5068 ms | 15306 ms |
| **reserve** | **1201 ms** | **3623 ms** | 5157 ms |
| upstream | 317 ms | 897 ms | 15262 ms |
| settle | 285 ms | 1127 ms | 1915 ms |
| unaccounted | 4.9 ms | 23 ms | 254 ms |

5 秒より遅い 164 本に絞ると、reserve p50 3844 ms、settle p50 1095 ms に対し
upstream は p50 487 ms。**遅いリクエストの時間は予約と決済に入っている。**

DynamoDB 自体は速い。UpdateItem の平均 3〜4 ms、最大 263 ms、条件付き書き込み失敗 0、
throttle 0、消費 WCU はピークでも 82 WCU/s。つまり待ちは DynamoDB のサービス時間ではなく
**呼び出しに至るまでの待ち**である。ECS の CPU は同時刻で平均 32 %、最大 69 %。

## 真因: 1 プロセスに 128 リクエストを入れると GIL で直列化する

1 タスクあたりの同時実行とレイテンシの対応が決定的である。

| 1 タスクあたり | p50 |
|---|---|
| 4 | 約 390 ms (upstream とほぼ同じ) |
| 8 | 549 ms |
| 32 | 1331 ms |
| 64 | 2791 ms |
| 128 | 7706 ms |

CPU は 70 % に届かないのにレイテンシが 1 タスクあたり同時実行に比例して伸びる。
これは CPU 飽和ではなく、**単一 Python プロセス内で 128 スレッドが GIL を取り合う**
挙動と一致する。1 リクエストは reserve / upstream / settle で複数回の botocore 呼び出しを
行い、その CPU 部分が直列化されるので、スレッド数を増やすほど 1 本あたりの待ちが伸びる。

## 導かれる推奨

- **admit できることと低レイテンシで捌けることは別**である。8 タスク × 128 で 1024 は
  admit でき実際に 1017 本が成功したが、p50 は 7.7 秒になる。
- レイテンシを upstream 相当に保てるのは **1 プロセスあたり 8 前後まで**、実用上の妥協点は
  32 前後 (p50 1.3 秒)。
- したがって 1024 を低レイテンシで捌くなら、スレッドを増やす方向ではなく
  **プロセスを増やす方向** (`uvicorn --workers`、またはタスク数) に振るべきである。
  1 プロセス 32 で 1024 なら 32 プロセス相当が必要になる。
- `GATEWAY_SYNC_ROUTE_THREADS` の既定 128 は「admit の上限」としては正しいが、
  「低レイテンシで捌ける上限」ではない。この 2 つを doc で分けて書いた。


---

# 追記 3: 真因は GIL ではなく DynamoDB クライアントの接続プール (2026-08-25 04:50 JST)

追記 2 で「1 プロセス内の GIL 競合」と結論したが、**これは誤りだった**。Fable と Codex に
相談した結果、両者が独立に別の容疑者を挙げ、ログで確定した。

## 決定的な証拠

タスクログに次が **1,010 件**。

```
Connection pool is full, discarding connection: dynamodb.us-east-1.amazonaws.com. Connection pool size: 10
```

`dynamo/client.py` の `get_dynamodb_resource()` は `Config` を渡していなかったので、
botocore 既定の `max_pool_connections=10` のままだった。urllib3 は非ブロッキングなので、
プールが埋まっていると**接続を新規作成して使用後に破棄する**。つまり 11 本目以降の
同時呼び出しは毎回 TCP + TLS ハンドシェイクを払っていた。全リクエストが reserve と
settle で 2 回以上ここを通るので、プロセス内で最も忙しいクライアントである。

Bedrock と mantle のプールは追記 1 の時点で直していたのに、**最もトラフィックが多い
DynamoDB を見落としていた**。同じ欠陥の見落としである。

Fable の指摘で重要だったのは、スループットが 512 → 1024 で 91.9 → 31.7 req/s と
**崩壊**していた点である。純粋な CPU 飽和ならプラトーになる。崩壊は
「同時実行が増えると 1 リクエストあたりの実コストが増える」ことを意味し、
プール枯渇によるハンドシェイク churn がまさにそれである。

また 1 vCPU のホストでは GIL 直列化と CPU 飽和は区別できないという指摘も正しく、
私の「GIL」という名指しは不正確だった。

## 修正後の実測 (8 タスク × 4 vCPU × 4 worker × 32 スレッド)

| 同時実行 | 修正前 GW | 修正後 GW | 同時刻の直叩き |
|---|---|---|---|
| 64 | 42.3 req/s, p50 549 ms | 80.6 req/s, p50 435 ms | 114.4 req/s, p50 344 ms |
| 256 | 81.1 req/s, p50 1331 ms | 183.9 req/s, p50 811 ms | 36.1 req/s, p50 605 ms |
| 512 | 91.9 req/s, p50 2791 ms | 98.3 req/s, p50 1356 ms | 5.7 req/s, p50 934 ms |
| 1024 | 31.7 req/s, p50 7706 ms | **226.6 req/s, p50 3326 ms** | 151.1 req/s, p50 1853 ms |

同時実行 1024 で 1024 本中 1018 本が 200 (残り 6 件は負荷生成側の
`ClientConnectorError` で、直叩き側でも 8 件出ている)。

**当初の 4.5 req/s から 226.6 req/s、約 50 倍。**

## phase 別の内訳も改善

| phase | 修正前 p50 | 修正後 p50 | 修正前 p95 | 修正後 p95 |
|---|---|---|---|---|
| total | 2014 ms | 705 ms | 5068 ms | 1338 ms |
| reserve | 1201 ms | 341 ms | 3623 ms | 869 ms |
| upstream | 317 ms | 266 ms | 897 ms | 530 ms |
| settle | 285 ms | 38 ms | 1127 ms | 241 ms |
| unaccounted | 4.9 ms | 0.6 ms | 23 ms | 9.7 ms |

`Connection pool is full` の警告は **0 件**になった。

reserve が依然 341 ms あるのは DynamoDB のサービス時間 (3〜4 ms) より大きいので、
まだ待ちが残っている。次に見るならここである。

## 併せて入れた変更

- **1 プロセスあたりの同時実行上限を 128 → 32** に下げた。追記 2 のデータどおり
  レイテンシは 1 プロセスあたり同時実行に比例するので、128 は admit できても
  捌けていない。フリートはプロセス数で増やす。
- **uvicorn の worker 化** (`GATEWAY_UVICORN_WORKERS`、既定は vCPU 数)。1 vCPU の
  タスクは 1 プロセスのまま (従来と同一)、4 vCPU なら 4 プロセス。
  Codex と Fable が揃って指摘したとおり、**1 vCPU で worker を増やしても意味がない**
  ので worker 数は vCPU に従わせ、同時実行目標には従わせない。
- **awslogs を non-blocking に。** blocking だと CloudWatch の詰まりで stdout 書き込みが
  止まり、Python の logging はハンドラロックを持つのでプロセス内の全スレッドが待つ。

## 未解決 / 次

- reserve に残る 341 ms の内訳 (DynamoDB 呼び出し回数、条件付き更新の競合)。
- 目標値の補正: 同時実行 1024 で p50 500 ms は**達成不可能**である。直叩き自体が
  同条件で p50 1853 ms なので、現実的な目標は「直叩き + 数百 ms」である。
  現状 3326 ms なのでまだ 1.8 倍の差がある。
- 非ストリーミング経路の async 化は両者とも「第 2 フェーズ」評価。まず設定と
  トポロジで直し切ってから。


---

# 追記 4: 「ゲートウェイが律速していない」ことの計測 (2026-08-25 05:30 JST)

要件が「同時実行 1024」ではなく「**ゲートウェイが Bedrock の同時実行を律速しない**」で
あることが明確になったので、計測方法をクローズドループ (同時実行固定) から
**オープンループ (提供レート固定)** に変えた。

クローズドループは「一気に投げて全部さばけるまでの時間」を測るので、ドレイン時間が
支配してどちらが律速か見えない。律速の有無は「**同じ提供レートに対してレイテンシと
失敗率が upstream 直叩きと同等か**」でしか確かめられない。

## 結果 — 律速していない

20 秒ずつ、同じレートを両者に流した (gemma-4、max_tokens 16、us-east-1 の EC2 から)。

| 提供レート | GW p50 | 直叩き p50 | 差 | GW p95 | 直叩き p95 | GW 失敗 |
|---|---|---|---|---|---|---|
| 25 req/s | 314 ms | 230 ms | **+84 ms** | 847 ms | 1062 ms | 0 / 501 |
| 50 req/s | 297 ms | 222 ms | **+75 ms** | 900 ms | 988 ms | 2 / 1001 |
| 100 req/s | 304 ms | 225 ms | **+79 ms** | 822 ms | 681 ms | 13 / 2001 |
| 200 req/s | 391 ms | 227 ms | **+164 ms** | 1071 ms | 575 ms | 6 / 4001 |

**レートを 8 倍にしても p50 が 300〜390 ms でほぼ平坦**である。律速している側は
レートを上げるとレイテンシが伸びるので、この範囲でゲートウェイは律速していない。
上乗せは 100 req/s まで +75〜85 ms、200 req/s で +164 ms で、これは会計処理
(reserve + settle、DynamoDB 5 往復) のコストである。

## 残っていた失敗の正体と修正

GW 側の失敗はすべて **504** で、直叩き側では 0 件だった (直叩きは 500 が 3 件)。
原因は CloudFront のオリジン応答タイムアウトが既定 **30 秒**で、ゲートウェイ自身の
upstream 読み取り上限が 600 秒だったこと。つまり upstream が 30 秒を超えると、
呼び出し側には **CloudFront の HTML 504** が返る。呼び出し側のせいでもゲートウェイの
せいでもない問題が、パースできない形で見えていた。

2 点直した。

- CloudFront のオリジン応答タイムアウトを 60 秒 (クォータ引き上げなしの上限) に。
  keepalive も 5 秒 → 60 秒 (バースト間でオリジン接続を捨てていた)。
- **非ストリーミングの読み取り上限を CDN より短い 50 秒に**。自分が先に諦めることで、
  呼び出し側には他の経路と同じ JSON の 502 が返る。ストリーミングは長い窓を維持する
  (バイトが流れるので CDN のタイムアウトは各 read に効き、全体には効かない)。

## 未計測

- 200 req/s より上。この計測では負荷生成側 (単一 EC2) が先に飽和しており、直叩きの
  実効スループットも 99 req/s 前後で頭打ちになっている。より上を見るなら負荷生成を
  複数ホストに分ける必要がある。
- reserve の 341 ms の内訳。DynamoDB は 1 リクエストあたり 5 往復
  (user-tenants に GetItem 2 + UpdateItem 2、usage-logs に PutItem 1) で、
  サービス時間の合計は約 18 ms。残りは呼び出しに至るまでの待ちである。


---

# 追記 5: CDN タイムアウト修正のデプロイ後検証 (2026-08-25 05:55 JST)

CloudFront の OriginReadTimeout 60 秒 + 非ストリーミング読み取り 50 秒の構成を
デプロイし (`cdn-eb32d74`、CloudFront は Deployed 状態を確認)、同じオープンループで
確認した。フリートは定常構成の 2 タスク × 4 vCPU × 4 worker。

| 提供レート | 成功 | 失敗 | p50 | 504 |
|---|---|---|---|---|
| 100 req/s | 2001 / 2001 | 0 | 575 ms | **0 件 (修正前 13 件)** |
| 200 req/s | 2862 / 4001 | 1139 | 7320 ms | 0 件 |

**100 req/s で 504 が消えた。**

200 req/s の段は**計測として無効**である。失敗 1139 件の内訳は
`ClientConnectorDNSError` 899 件と `ClientConnectorError` 240 件で、いずれも
負荷生成側 (単一 EC2) の DNS / ソケット枯渇である。ゲートウェイに届いた 2862 本は
すべて 200 だった。この帯域を測るには負荷生成を複数ホストに分け、DNS を
キャッシュする必要がある。

p50 が追記 4 の 304 ms より高い 575 ms なのは、この検証が定常構成の 2 タスクで
走っているためである (追記 4 は 8 タスク)。scale-out すれば追記 4 の水準に戻る。

## ここで打ち止めとする理由

本来の目的は VSR の MoM 計測であり、ゲートウェイはその測定器である。測定器が
被測定対象を律速しないことは追記 4 で示せた (同一レートで p50 の上乗せが
+75〜164 ms、レートを 8 倍にしても平坦)。これ以上の最適化 (reserve の 5 往復削減、
非ストリーミング経路の async 化) は目的から外れるので行わない。
