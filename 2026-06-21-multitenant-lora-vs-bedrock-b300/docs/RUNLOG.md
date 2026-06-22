# RUNLOG — multitenant-serving-b300

実際に実行したコマンドと結果を時系列で1ファイルに残す (登壇・再現用)。GPU 不要で進められる
ものだけ (ローカルデータ生成 + Bedrock 実測)。GPU を使う vLLM/inference-perf 計測は別実験の
GPU 占有が空き次第 (DESIGN.md §10 Phase 0-)。

設計・根拠は `DESIGN.md`、調査の生データは `design-research-raw.json` / `research-raw.json`。

**実行日**: 2026-06-21
**環境**: ローカル mac (darwin)、AWS 認証 = Admin role `<ACCOUNT_ID>` (Isengard AssumeRole)、region us-west-2
**凡例**: [OK] 成功 / [NG] 失敗 / [INFO] 確認 / [確定] 設計の未確定事項を実機で解決

---

## 0. サマリ (この RUNLOG で確定した重要事実)

| # | 確定事項 | 根拠 (本 RUNLOG の section) |
|---|---|---|
| R1 | **Gemma 4 31B / E2B は bedrock-mantle で実際に動く (HTTP 200)**。OpenAI 互換レスポンス | §3 |
| R2 | **認証は SigV4 (service="bedrock")。Bearer token 不要** ← DESIGN.md の最大 open question を解決 | §3 |
| R3 | **prompt caching は効かない (`cached_tokens`=0 が全8条件で)** ← F1 を API 実データで実証 | §4 |
| R4 | **TTFT は system prompt が短〜中 (≤512tok) ではほぼ一定**、long(1711tok) で上昇。Bedrock マネージドが prefill を吸収 | §4 |
| R5 | **`aws bedrock list-foundation-models` には Gemma 3 のみ。Gemma 4 は出ない** (bedrock-mantle は別カタログ) | §2 |
| R6 | usage で prompt/completion トークンが正確に取れる → コスト実測の土台 | §3-4 |
| R7 | ローカルのデータ生成スクリプト (Zipf split / Bedrock dataset) は実データで動作 | §5 |
| R8 | **long-context で TTFT が prompt token にほぼ線形〜超線形に爆発** (3K=1.3s → 48K=13s → 96K=45s → 150K=103s)。caching 無しでフル課金。LoRA(短prompt)の構造的優位を実証 | §4b |
| R9 | **Bedrock 31B は同時実行で TTFT が崖崩壊**: conc 1-10 は ~350ms → conc 20 で 37秒 → 40 で 42秒。SLO達成率 97.5%→2.5%。503 は出ず**キューで TTFT を伸ばす**。out_tok/s ~30 頭打ち。自前専有の質的優位の実証 (論点1) | §4c |
| 注 | §4c に計測バグ教訓: `asyncio.to_thread` は default 14 スレ頭打ちで concurrency が出ない → aiohttp 真async に修正済み | §4c |
| R10 | **自前 vLLM 0.21 (sm_103 image) で Gemma 4 31B fp8 + multi-LoRA が動く (Phase 0 smoke 成功)**。base 生成 OK、ダミー LoRA ロード&生成 OK | §6 |
| R11 | **「vLLM omni」は不要**。Gemma 4 は mainline vLLM に登録済み。vision_tower の PunicaWrapper 警告は「vision に LoRA を当てないだけ」で無害。text-only では vision tower forward は呼ばれず追加コストゼロ (HBM ~1GiB のみ) | §6 |
| R12 | **Gemma 4 は層ごとに attention 次元が異なる (heterogeneous)**: sliding 層=head_dim256/kv16 (kv_out4096) / full 層=global_head_dim512/kv4 (kv_out2048)。`layer_types` で決まる (31B=full10+sliding50)。LoRA adapter は per-layer shape で合成必須 | §6 |
| R13 | **F2 (最大の実装リスク) は実機で安全側**: max_loras=4 に 5 distinct adapter 同時バーストでも RuntimeError でクラッシュせず全 HTTP 200。vLLM v1 スケジューラが defer する。ただし 1000 テナント高負荷では未確認、max_loras 大きめ方針は維持 | §6 |
| R14 | peft 0.19.1 は **Gemma4ClippableLinear 非対応**で get_peft_model 失敗 → ダミー adapter は `scripts/synth_dummy_lora.py` で **peft を介さず safetensors 直接合成** (rank16=123.6M params=247MB)。B300 実測 GPU mem 275040 MiB/枚 (=268GiB, F4 裏付け) | §6 |
| R15 | **本計測完了 (8x B300, 128 tenant, 全 adapter ロード済み)**。自前飽和: B(LoRA)=97 req/s / B(affinity)=122 / **B0(sys prompt)=311 req/s**。Bedrock SLO 達成上限=0.41 req/s。**自前は Bedrock の ~240-760倍 の goodput** | §7 |
| R16 | **反直感: 自前では LoRA より 512tok system prompt の方が ~3倍速い** (B0 311 vs B 97 req/s, out_tok/s 19905 vs 6335, TPOT 18 vs 53ms)。multi-LoRA の SGMV+swap オーバーヘッドが 512 prefill コストを上回る。コスト損益分岐 (S=512,CB=263 req/s) を **B0 のみ超える=自前が純コストでも安い** | §7 |
| R17 | **routing affinity の効果は飽和近傍でのみ顕著**: conc≤128 は round-robin ≈ affinity、conc512 で affinity +24% (97.6→121.6 req/s)。128 tenant/max_loras=32 で hot-set ヒット率改善が効くのは高負荷時のみ (論点2の答え) | §7 |
| 注2 | 計測の罠2件: ①proxy が `await r.read()` で stream を壊し TTFT/TPOT 崩壊 → 廃止し sweep に複数 base-url 直接ルーティング実装。②1000 adapter 登録は engine ではなく「全 replica に curl 殺到」が原因で遅延 → replica 順次・低並列なら 244ms/load。テナントは 128 で確定 | §7 |
| R18 | **GPU 性能限界 (補足, base 31B fp8, 8x B300)**: decode 天井 ≈ **29,200 out tok/s / goodput 228 req/s** (conc 1024-2048 飽和, SLO 100%, 崩壊せず)。long-ctx: 30K tok 入力でも TTFT 2.6s/SLO 内、TPOT は入力長にほぼ不感 (11→16ms)、goodput は prefill で反比例 (1K=41→30K=17 req/s)。KV cache=907K tok/replica @32768 (fp8) | §9 |
| 注3 | 計測の罠3件目: vLLM 停止は `pkill -f "vllm serve"` では **EngineCore worker が GPU mem を握ったまま残る** (free 10.89GiB に枯渇し再起動失敗)。`nvidia-smi --query-compute-apps=pid` の全 PID を kill する必要 | §9 |
| R19 | **PD-disaggregation は Gemma 4 で実機 NOT VIABLE (確定)**: 4P+4D を NIXL で起動 → 全 8 worker が `nixl/worker.py:895 AssertionError: All kv cache tensors must have the same size` で起動失敗。Gemma 4 の heterogeneous attention (sliding kv16/hd256 vs full kv4/hd512) が NIXL の同一サイズ KV 要求に反する ("Different kv cache shape is not supported by HeteroTP")。config では回避不可。設計の PD スキップ判断が実機で裏付けられた | §10 |

未実行/今後: B0 と Bedrock を同一 512tok 入力で厳密比較 (現状 Bedrock §4c は ~128tok short)。E2B アーム。テナント数スケール (32/64/128 で振る)。

---

## 1. 環境確認 (read-only)

```bash
aws sts get-caller-identity   # Admin role (詳細は社内情報のため非掲載)
aws configure list-profiles
```
```
Account / UserId / Arn : <redacted: 社内アカウント情報>
AWS_REGION=us-west-2 / BEDROCK_API_KEY=<unset> / BEDROCK_BASE_URL=<unset>
```
[INFO] Admin role, us-west-2。Bedrock 用の API key/bearer は未設定 (が R2 で SigV4 のため不要と判明)。

ローカル依存:
```bash
python3 -c "import transformers, peft, torch"   # -> ModuleNotFoundError: peft
python3 -c "import yaml"                          # -> ok
python3 -c "import openai"                        # -> ModuleNotFoundError: openai
python3 -c "import boto3; print(boto3.__version__)"  # -> 1.35.74
```
[INFO] `yaml` と `boto3` はある。`peft`/`openai` は無い → それらに依存するスクリプトは未実行。
Bedrock 実測は boto3 SigV4 + urllib のみで実施できた (openai SDK 不要)。

---

## 2. Bedrock foundation models カタログ (read-only)

```bash
aws bedrock list-foundation-models --region us-west-2 \
  --query "modelSummaries[?contains(modelId,'gemma') || contains(providerName,'Google')].[modelId,providerName,inferenceTypesSupported]" --output json
```
```json
[ ["google.gemma-3-12b-it","Google",["ON_DEMAND"]],
  ["google.gemma-3-4b-it","Google",["ON_DEMAND"]],
  ["google.gemma-3-27b-it","Google",["ON_DEMAND"]] ]
```
[確定 R5] **Gemma 3 (4b/12b/27b) の ON_DEMAND のみ。Gemma 4 (31b/e2b) はこのカタログに出ない**。
→ Gemma 4 は従来の bedrock-runtime カタログではなく bedrock-mantle 系にある、という設計の裏付け。

---

## 3. Gemma 3 27B (bedrock-runtime Converse) と Gemma 4 (bedrock-mantle) の疎通

### 3-1. Gemma 3 27B — bedrock-runtime Converse (boto3)

```python
br = boto3.client("bedrock-runtime", region_name="us-west-2")
resp = br.converse(modelId="google.gemma-3-27b-it",
    messages=[{"role":"user","content":[{"text":"Reply with exactly: OK"}]}],
    inferenceConfig={"maxTokens":10,"temperature":0})
```
```
[OK] latency=867ms text='OK\n' usage={'inputTokens': 14, 'outputTokens': 3, 'totalTokens': 17}
```
[OK] Gemma 3 27B は従来 API (Converse) で動く。Approach A の代替/参考に使える。

### 3-2. Gemma 4 31B — bedrock-mantle (SigV4, urllib)

```python
url="https://bedrock-mantle.us-west-2.api.aws/openai/v1/chat/completions"
body=json.dumps({"model":"google.gemma-4-31b","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10})
req=AWSRequest(method="POST", url=url, data=body, headers={"Content-Type":"application/json"})
SigV4Auth(creds, "bedrock", "us-west-2").add_auth(req)   # service名 "bedrock" / "bedrock-mantle" 両方試行
urllib.request.urlopen(...)
```
```
[OK svc=bedrock]        200 {"choices":[{"finish_reason":"stop",...,"message":{"content":"OK",...}}],"model":"google.gemma-4-31b",...}
[OK svc=bedrock-mantle] 200 {"choices":[{"finish_reason":"stop",...,"message":{"content":"OK",...}}],"model":"google.gemma-4-31b",...}
```
[確定 R1/R2] **Gemma 4 31B が bedrock-mantle で動作 (HTTP 200, OpenAI 互換レスポンス)**。
**認証は SigV4 で OK、Bearer token 不要**。SigV4 の service 名は "bedrock" でも "bedrock-mantle" でも 200。
→ DESIGN.md §7/§11 の「Bearer か SigV4 か未確認」を解決。`bedrock_load_driver.py` の SigV4 経路でいける。

---

## 4. Gemma 4 system-prompt サイズ sweep (TTFT/TPOT/usage 実測)

再現スクリプト: `scripts/probe_bedrock_gemma4.py` (streaming で TTFT、usage で課金トークン取得)。

```bash
python3 scripts/probe_bedrock_gemma4.py
```
```
model            | sys_size     | TTFT ms | total ms | TPOT ms | prompt_tok | cached_tok | out_tok
google.gemma-4-31b | none         |     758 |      764 |     0.6 |         21 |          0 | 11
google.gemma-4-31b | short(~128)  |     820 |      892 |     4.0 |        139 |          0 | 20
google.gemma-4-31b | medium(~512) |     754 |      856 |     5.7 |        451 |          0 | 20
google.gemma-4-31b | long(~2048)  |    1076 |     1080 |     0.2 |       1711 |          0 | 20
google.gemma-4-e2b | none         |     797 |     1131 |     5.3 |         21 |          0 | 64
google.gemma-4-e2b | short(~128)  |     806 |     1145 |     5.4 |        139 |          0 | 64
google.gemma-4-e2b | medium(~512) |     817 |     1158 |     5.4 |        451 |          0 | 64
google.gemma-4-e2b | long(~2048)  |     980 |     1313 |     5.3 |       1711 |          0 | 64
```

[確定 R3] **`cached_tokens` が全 8 条件で 0**。system prompt 451/1711 tok を送っても cache されない
→ **F1 (Gemma に prompt caching なし) を API レスポンスの実データで実証**。Approach A は毎回フル input 課金。

[確定 R4] **TTFT は system prompt 短〜中 (≤512 tok) ではほぼ一定** (31B: 758→820→754ms)。
**long(1711 tok) で上昇** (31B: 1076ms, E2B: 980ms)。マネージド Bedrock が中程度の prefill を
吸収しており、「長い system prompt = 即 TTFT 悪化」とは単純にならない。登壇の観察ポイント。

[INFO] E2B は TPOT が安定 (~5.3ms) だが **TTFT は 31B と同等** (マネージドなので "小モデル=速い" が
単純に成立しない)。31B の TTFT 揺れ (TPOT 0.2-5.7ms) は out_tok が少なく分母が小さいため。

> 注意: 上記は単発・低負荷の値。高同時実行 (100/500/1000) では 503 throttle が出うる (§7 DESIGN.md)。
> goodput-vs-concurrency の本計測は inference-perf / bedrock_load_driver.py で別途 (ramp-up 必須)。

### コスト実測の土台 (usage から)

prompt_tokens / completion_tokens が取れるので、DESIGN.md §8 の per-token 価格と掛け合わせれば
1 リクエストの実コストが出せる。例: 31B medium = (451 in × $0.14 + 20 out × $0.40)/1e6 = $0.000071/req。

---

## 4b. long-context sweep (Gemma 4 31B, 最大 context 256K 付近まで)

§4 は最大 1711 tok 止まりで Gemma 4 の 256K context から見ると桁違いに短い。テナント設定の
richness 上限 = long system prompt の prefill コストを見るため、~3K〜150K tok まで上げて単発計測。
(max_tokens=32, single request, streaming TTFT)

```
model            | target_words | payload_MB | TTFT ms | total ms | prompt_tok | cached
google.gemma-4-31b |         3000 |       0.03 | 1308    | 1442     | 3029       | 0
google.gemma-4-31b |        12000 |        0.1 | 2360    | 2699     | 12029      | 0
google.gemma-4-31b |        48000 |       0.41 | 13350   | 13883    | 48029      | 0
google.gemma-4-31b |        96000 |       0.82 | 45183   | 46075    | 96029      | 0
google.gemma-4-31b |       150000 |       1.28 | 103142  | 105086   | 150029     | 0
```

[確定 R8] **TTFT が prompt token にほぼ線形〜超線形に爆発**:
- 3K→12K (4倍tok): TTFT 1.3s→2.4s
- 12K→48K (4倍): 2.4s→**13.3s**
- 48K→96K (2倍): 13.3s→**45.2s** (~3.4倍 = 超線形。prefill が完全支配)
- 96K→150K: 45s→**103s**

→ 短い prompt は Bedrock マネージドが吸収する (§4 R4) が、**long-context では prefill コストが
TTFT に直撃**する。テナント設定を richに (長く) するほど Bedrock は TTFT もコストも悪化。
**`cached`=0 のまま** = 150K tok を毎回フル課金 ($0.14/1M × 150K = $0.021/req の input だけで)。
→ **自前 LoRA (設定を重みに焼き込み = prompt 短い) の構造的優位**を裏付ける実データ。

[INFO] payload 上限: 31B は request body 3.5MB 上限 (model card)。150K tok=1.28MB なので 256K
(~2.2MB) も入る見込み。ただし TTFT が 100秒超では実用外。**登壇では「長context は技術的には
通るが TTFT が線形爆発し、long-tenant-config を毎リクエスト送る方式の限界」を示す材料**。

> 注: TTFT 100秒級はクライアント/サーバ両側のタイムアウト設計に直結。concurrency sweep
> (§4c) ではこの outlier が全体を引きずるため timeout 設定が重要。

---

## 4c. concurrency sweep + goodput (TTFT/TPOT/Goodput)

共通ツール `scripts/concurrency_sweep.py` で計測。OpenAI 互換なので **同じツールを後で vLLM に
向けて GPU 側も同一メトリクス・同一 SLO で計測**する (ユーザ確定方針)。

goodput 定義: good = (TTFT ≤ slo_ttft AND TPOT ≤ slo_tpot AND error なし)、goodput_req/s = good/wall。
SLO: TTFT ≤ 2000ms, TPOT ≤ 80ms。

### [教訓・要注意] 計測バグ: asyncio.to_thread は 14 スレッド頭打ち

最初の実装は `asyncio.to_thread` + blocking urllib だった。**default ThreadPoolExecutor の
max_workers = min(32, cpu+4) = 14** で、`--concurrency 200/300` を指定しても**実効同時実行が 14 で
頭打ち**になっていた。その結果「conc 10〜300 で TTFT/goodput がほぼ不変」という**誤った結論**を出した
(誤データ: conc300 で TTFT p50=740ms, good 100% に見えた → 実際は 14 並列の値)。
→ **aiohttp で真の非同期に書き換え**て解決 (`one_request` が `session.post` を直接 await、
TCPConnector limit = concurrency+10)。教訓: 負荷ツールで to_thread/ブロッキング IO は使わない。

### [確定] 真の同時実行での結果 (Gemma 4 31B, short prompt ~128tok, 40 req/stage)

`results/bedrock-31b-short-trueasync.json`
```
conc | dur_s | ok | 503 | TTFT p50/p90/p99       | TPOT p50/p90/p99 | out_tok/s | goodput_req/s | good%
   1 | 95.02 | 40 |  0  | 348/407/64879          | 5.7/7.0/7.5      |    27     |    0.41       | 97.5%
   2 | 92.93 | 40 |  0  | 341/414/76455          | 5.9/7.6/8.6      |    27     |    0.41       | 95.0%
   5 | 87.84 | 40 |  0  | 340/73919/79724        | 5.7/7.5/8.4      |    29     |    0.40       | 87.5%
  10 | 82.34 | 40 |  0  | 360/72093/77595        | 5.6/7.4/8.1      |    31     |    0.36       | 75.0%
  20 | 77.61 | 40 |  0  | 37436/67900/73815      | 7.5/11.7/13.0    |    33     |    0.26       | 50.0%
  40 | 80.39 | 40 |  0  | 42041/71847/77448      | 9.4/11.9/14.8    |    32     |    0.01       |  2.5%
```

[確定 R9] **Bedrock Gemma 4 31B は同時実行で TTFT が崩壊する (登壇 論点1 の本体データ)**:
- **TTFT p50 の崖**: conc 1-10 は ~350ms と健全 → **conc 20 で 37,436ms (37秒) に崩壊** → conc 40 で 42秒。崖は conc 10→20 の間。
- **SLO 達成率 (good%) が単調減少**: 97.5 → 95 → 87.5 → 75 → 50 → **2.5%**。きれいな劣化曲線。
- **503 は一度も出ない**。Bedrock は throttle で弾かず**キューに入れて TTFT を伸ばす** → 「金を払っても遅延が読めない」。
- **TPOT は安定** (5.6〜9.4ms) → ボトルネックは prefill/キューイング、decode は健全。
- **out_tok/s が ~30 で頭打ち** = Bedrock が 1 リクエストに割り当てるスループット上限。低 conc でも p99 に 64-79秒の散発 outlier (conc1 でも p99=64秒)。

→ **自前 p6-b300 (専有) なら飽和まで自分のリソース**。Bedrock は単発は速いが多人数同時で TTFT が
100倍に崩壊し SLO を割る。これがコスト交差点 (DESIGN.md §8) とは独立した「自前の質的優位」。

> 次: GPU が空いたら **同じ `concurrency_sweep.py` を vLLM (`--base-url http://.../v1 --auth none
> --adapters 1000 --zipf 1.1`) に向けて同一メトリクスで計測**し、この表に並べる。out_tok/s と
> TTFT 崩壊点が自前でどこに来るかが直接比較になる。

---

## 5. ローカルデータ生成 (GPU 不要、実行済み)

### 5-1. Zipf traffic split

```bash
python3 scripts/gen_zipf_lora_split.py
```
```
N=100:  top 10%=0.626  top-16=0.708
N=500:  top 10%=0.734  top-16=0.581
N=1000: top 10%=0.768  top-16=0.544
-> data/lora_split_{100,500,1000}.yaml (sum=1.0 検証済み)
```
[OK] Zipf(s=1.1)。1000 テナントでも top-16 が全 traffic の **54.4%** をカバー
→ affinity routing で hot-16 を当てれば半分以上のリクエストが GPU hit になる試算と整合 (DESIGN.md §3)。

### 5-2. Bedrock dataset (per-tenant distinct system prompt)

```bash
python3 scripts/gen_bedrock_dataset.py
```
```
[OK] bedrock_dataset_{short,medium,long,xlarge}_{100,500,1000}tenants.jsonl  (計12ファイル)
wc -l: 各 1000tenants ファイルは 1000 行。total data 119MB (data/ に隔離、gitignore)
```
[OK] short(128)/medium(512)/long(2048)/xlarge(8192) tok × 100/500/1000 テナント。
各テナントはシード固定の distinct な system prompt を持つ (caching 無効化の設計意図, R3 で実証済み)。

> 生成物 (`data/*.jsonl`, `data/lora_split_*.yaml`, 計119MB) は再生成可能なので `.gitignore` で除外。

---

## 6. 自前 vLLM Phase 0 smoke (B300 実機, namespace mt-serving)

GPU 解放 (48 枚空き) を受けて 1 GPU で smoke 実施。クラスタ: 8 node × 8 GPU=64、`other-experiment`
(別実験) が 2 node=16 占有、残り 48 空き。**p6-b300 は 1 node=8 GPU** (16 ではない、認識訂正)。

### 環境・前提
- namespace `mt-serving` 作成。ECR pull secret (`ecr-pull-secret`) と HF token を用意。
- image: `<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/vllm-uccl-ep:vllm0.21.0-uccl-0dc87eb-cu13-b300-fix1`
  (vLLM 0.21.0, transformers 5.12.1, peft 無し→ pod 内 pip)。manifest: `manifests/00-smoke-vllm-lora-4b.yaml`。
- **実測 GPU mem = 275040 MiB/枚 (=268 GiB)** ← F4 (2144GB/8=268) を実機裏付け [R10/R14]。
- **HF gated**: 旧 token は Gemma metadata は読めるが resolve 403 (利用規約未承認)。ack 済み token に更新。
  Gemma 3 は `gated: manual`、**Gemma 4 (大文字 repo `google/gemma-4-31B-it` 等) は gated=False**。

### Gemma 4 の存在と vLLM 対応 [R11]
- `google/gemma-4-31B-it` 実在 (arch `Gemma4ForConditionalGeneration`, 62.5GB bf16, image-text-to-text)。
  `gemma-4-E2B-it` / `gemma-4-26B-A4B-it` / `gemma-4-12B-it` も実在。
- vLLM 0.21 は `Gemma4ForCausalLM`(text) と `Gemma4ForConditionalGeneration`(mm) を登録済み、**両方 supports_lora=True**。
- 「vLLM omni」は別パッケージ (Qwen3-Omni/拡散系向け)、**不要**。
- vision_tower の PunicaWrapper 警告 = LoRA を vision に当てないだけ (無害)。text-only では vision forward
  は呼ばれず追加コスト 0 (HBM ~1GiB のみ)。→ `Gemma4ForConditionalGeneration` のまま画像を送らない運用でOK。

### base 起動・生成 [R10]
```bash
vllm serve google/gemma-4-31B-it --tensor-parallel-size 1 --quantization fp8 \
  --enable-lora --max-loras 4 --max-lora-rank 16 --lora-dtype bfloat16 --max-cpu-loras 8 \
  --gpu-memory-utilization 0.90 --max-model-len 4096 --port 8000
```
- model load = **32.62 GiB / 33.6s** (fp8)。起動ログ: heterogeneous head_dim で **TRITON_ATTN 強制**、
  KV cache 202.6 GiB / 240,559 tok 確保。health 200。
- base 生成: `{"model":"google/gemma-4-31B-it"}` → "OK" (usage 取得可)。

### ダミー LoRA 合成と heterogeneous 次元 [R12/R14]
- peft 0.19.1 は **Gemma4ClippableLinear 非対応** ("Target module ... is not supported") → get_peft_model 失敗。
- → `scripts/synth_dummy_lora.py` で **peft を介さず safetensors 直接合成**。
- **最初の合成は全層一律 kv_out=4096 で作り、ロード時 `size of tensor a (2048) must match b (4096)` で 500**。
  原因 = Gemma 4 の attention は層で次元が違う:
  - sliding(local) 50 層: head_dim 256, kv_heads 16 → q_out 8192, kv_out 4096
  - full(global) 10 層: global_head_dim **512**, num_global_key_value_heads **4** → q_out 16384, kv_out **2048**
  - `text_config.layer_types` で判定。synth を per-layer 対応に修正 → 123.6M params/枚 (247MB bf16)。
- 修正版 adapter ロード: `POST /v1/load_lora_adapter` → **"Success: LoRA adapter 'adapter-0' added"** HTTP 200。
- adapter-0 で生成: `{"model":"adapter-0"}` → "OK" (B=0 初期化なので base と同出力 = 期待通り)。**multi-LoRA 経路が sm_103/Gemma4 で動作確認**。

### F2 検証 (最大の実装リスク) [R13]
- 5 枚ロード (max_cpu_loras=8 の CPU プールに常駐, max_loras=4) → 全 HTTP 200。
- **max_loras=4 に 5 distinct adapter を同時バースト** → 全 adapter HTTP 200、**RuntimeError 出ず**。
  vLLM v1 スケジューラが max_loras 個ずつに分けて defer する (クラッシュしない) = 実機で安全側。
  ただし 1000 テナント高負荷では未確認。max_loras 大きめ方針は維持。

---

## 7. 本計測結果 (8x B300 1 node, 128 tenant, Gemma 4 31B fp8)

構成: 8x TP=1 独立レプリカ (port 8000-8007, DESIGN-v2 §5 フラグ, kv-cache fp8_e4m3, max_loras=32,
max_cpu_loras=1000)。128 adapter (rank-16, per-layer 合成) を全 replica に登録。計測 = `concurrency_sweep.py`
(aiohttp 真async, 複数 base-url 直接ルーティング, ignore_eos で出力長固定)。SLO: TTFT≤2000ms, TPOT≤80ms。
全データ JSON は `results/`。

### 7.1 アーム別 concurrency sweep (goodput req/s, 全 SLO 100% 達成・特記なき限り)

| conc | B LoRA RR | B LoRA affinity | B0 sys512 | B0 sys2048 | (Bedrock 31B 実測 §4c) |
|---|---|---|---|---|---|
| 8   | 6.2  | 6.0  | 12.1 | 10.8 | 0.41 |
| 32  | 21.7 | 22.3 | 44.4 | 42.0 | (崩壊域) |
| 64  | 38.2 | 41.0 | 82.6 | 73.6 | - |
| 128 | 64.4 | 68.7 | 140.4| 108.4| - |
| 256 | 96.5 | 100.3| 206.3| 147.0| - |
| 512 | 97.6 | **121.6** | **311.0** | **215.7** | - |
| out_tok/s @512 | 6,335 | 7,826 | 19,905 | 13,804 | ~30/req |

- **r_sat (SLO 内飽和 goodput)**: B(LoRA)≈97-122 / B0(512tok)≈311 / B0(2048tok)≈216 req/s。
- **Bedrock 31B の SLO 達成上限 = 0.41 req/s** (§4c, conc 20 で TTFT 37秒に崩壊)。
  → 自前は Bedrock の **約 240倍 (B) 〜 760倍 (B0)** の goodput。**スループット優位は条件なし確定**。

### 7.2 [R16] 反直感: LoRA より system prompt の方が自前では速い

- B0(512tok sys prompt) = **311 req/s / out 19,905 tok/s / TPOT 18ms**
- B(LoRA, ~10tok) = **97 req/s / out 6,335 tok/s / TPOT 53ms**
- LoRA は入力が短い(prefill 軽)のに **3倍遅い**。原因 = multi-LoRA の **SGMV per-token 計算 + swap** が
  512 prefill コストを上回る。TPOT 18 vs 53ms に明確。
- **コスト含意 (DESIGN-v2 §7 損益分岐, CB $93.60/hr)**:
  - S=512: 損益分岐 263 req/s → **B0=311 が超え自前が純コストでも安い** / B=97 は Bedrock 有利
  - S=2048: 損益分岐 86 req/s → **B0=216, B も近い → 自前圧勝域**
  - S=8192: 損益分岐 22 req/s → 自前完勝 (long context で Bedrock は TTFT も崩壊, R8)

### 7.3 [R17] routing (round-robin vs affinity) の効果

- conc 512 飽和近傍: affinity が RR比 **+24%** (goodput 97.6→121.6, out_tok/s 6335→7826)。
- conc ≤256: ほぼ同等 (goodput 差 <5%)。ただし **TTFT p50 は affinity が一貫して低い**
  (nt128 conc256: RR 487ms → aff 386ms) = cold swap が critical path から減る。
- テナント数スケール (conc 256 固定, nt=32/64/128): goodput は 94-107 req/s でほぼ横ばい
  (conc 256 では飽和未達のため swap が支配的でない)。routing が効くのは「飽和 × 多テナント」局面。

### 7.4 [R: swap cost] swap-in マイクロベンチ — 「ロード時間は安い」を実証

```
bench_lora_swap_cost.py --port 8001 --max-loras 32 --n-adapters 64
hot=26.7ms  cpu_swap=27.9ms  swap_cost(CPU->GPU)~=1.2ms
```
- **CPU→GPU swap-in = わずか 1.2ms** (max_cpu_loras=1000 で全 adapter CPU 常駐 → disk read 回避、
  247MB の H2D pinned copy のみ)。ユーザの直感「ロード時間大したことない」を実測で裏付け。
- 機構的結論: swap 単発は安い(1.2ms) → 低中負荷では routing 差なし。飽和時のみ swap が積み重なり
  forward を阻害 → affinity +24%。B が B0 より遅い真因は swap でなく **SGMV per-token 計算** (TPOT 差)。

### 7.4b [apple-to-apple] 同一 512tok system prompt での Bedrock vs 自前 B0

同一入力 (512tok sys prompt + ~10tok user, output 64)、同一 SLO、同一ツール、同一 concurrency 思想での厳密比較。

| conc | Bedrock 31B goodput (good%) | 自前 B0 goodput (good%) |
|---|---|---|
| 4   | 0.75 (91.7%) | - |
| 8   | 0.53 (83.3%) | 12.1 (100%) |
| 16  | 0.54 (66.7%) | - |
| 32  | 0.27 (33.3%, TTFT 27秒) | 44.4 (100%) |
| 512 | (崩壊済) | 254.9 (100%) |
| 768 | - | **392.7 (100%)** |
| 1024| - | **397.5 (100%) ← 飽和** |

- **Bedrock 31B は 512tok 入力では conc 4 で既に 91.7% (TTFT p99 47秒)、conc 8 以降 SLO 崩壊**。
  最大 achievable goodput ≈ **0.75 req/s**。short(128tok, §4c) の 0.41 と同オーダー = 入力長でなく
  Bedrock 側容量律速。
- **自前 B0 の真の飽和点 = ~398 req/s / out 25,442 tok/s (conc 768-1024, SLO 100%)**。
  single-request baseline (conc 1) = 1.53 req/s / TTFT 24ms。
- **同一 512tok 入力での倍率 ≈ 530倍** (398 / 0.75)。**B0 飽和 398 > 損益分岐 263 (S=512,CB)
  → 同一入力で自前が純コストでも安い**ことが apple-to-apple で確定。

### 7.5 結論 (登壇の骨子)

1. **スループット/goodput**: 自前 8x B300 は Bedrock 31B の 240-760倍 (Bedrock は同時 20 で崩壊、自前は
   512 で 100% SLO)。「金を払っても Bedrock は高同時実行で捌けない」= 自前専有の質的優位 (論点1)。
2. **コスト**: system prompt が長い (S≥2048) ほど自前が純コストでも安い (Bedrock は無 caching でフル課金,
   R3)。S=512 でも B0 なら損益分岐超え。LoRA(B) は SGMV overhead で純コストは Bedrock 有利寄り。
3. **反直感 (R16)**: 自前ではテナント設定を LoRA より system prompt で配る方が 3倍速い・安い。
4. **routing (論点2)**: affinity の旨みは飽和近傍で +24%、TTFT は常に改善。swap 単発は 1.2ms と安い。

## 9. 補足: GPU 性能限界の導出 (apple-to-apple ではなく構成の天井)

8x B300 / Gemma 4 31B fp8 / **base model (LoRA なし)** / max_model_len=32768 / kv-cache fp8_e4m3 で、
この構成の物理限界を多角的に計測。SLO は緩め (TTFT≤5000ms, TPOT≤100ms) にして「どこまで出るか」を見る。

### 9.1 KV cache 容量 (起動時 vLLM 自己申告)
- max_model_len=32768 で **GPU KV cache = 907,444 tokens/replica** (fp8)。8 replica = ~7.26M tokens node-wide。
- **Maximum concurrency for 32,768 tok/req = 27.69x/replica** → フル 32K 文脈なら ~221 並列 node-wide。

### 9.2 long-context 限界 (入力長 sweep, conc 64 固定, out 128)
`results/lc-in{1024,4096,8192,16384,30000}.json`

| input tok | TTFT p50 | TPOT p50 | out_tok/s | goodput req/s | good% |
|---|---|---|---|---|---|
| 1,024  | 219ms  | 11.0ms | 5,287 | 41.3 | 100% |
| 4,096  | 371ms  | 11.8ms | 4,633 | 36.2 | 100% |
| 8,192  | 506ms  | 12.2ms | 4,227 | 33.0 | 100% |
| 16,384 | 1,207ms| 13.8ms | 3,174 | 24.8 | 100% |
| 30,000 | 2,641ms| 16.5ms | 2,141 | 16.7 | 100% |

- **TTFT は入力長に sub-linear** (1K→30K で ~12倍, トークンは 30倍 = chunked prefill が効く)。
- **TPOT は入力長にほぼ不感** (11→16.5ms) = decode は context 長に鈍感。
- **goodput は prefill コストで反比例** (41→17 req/s)。30K tok 入力でも TTFT 2.6秒・SLO 内・100%。
- → Bedrock の long-ctx (R8: 96K=45s, 150K=103s) と対照的に、自前は 30K を 2.6秒で捌く。

### 9.3 goodput / decode throughput 限界 (input 1024, out 128, conc sweep)
`results/lc-goodput-limit.json`

| conc | TTFT p50 | TPOT p50 | out_tok/s | goodput req/s | good% |
|---|---|---|---|---|---|
| 128  | 49ms  | 13.1ms | 9,328  | 72.9  | 100% |
| 256  | 63ms  | 16.4ms | 14,566 | 113.8 | 100% |
| 512  | 232ms | 20.4ms | 22,617 | 176.7 | 100% |
| 1024 | 535ms | 30.5ms | 28,939 | 226.1 | 100% |
| 2048 | 468ms | 30.5ms | **29,227** | **228.3** | 100% |

- **decode throughput 天井 ≈ 29,200 out tok/s, goodput ≈ 228 req/s** (conc 1024→2048 で頭打ち)。
- 飽和点でも TTFT 468ms / TPOT 30.5ms と SLO 内 = **崩壊せず、純粋に throughput が飽和**
  (Bedrock のような TTFT 爆発・SLO 違反は起きない。KV cache に余裕)。
- この ~29K tok/s が「8x B300 1 node で 31B fp8 を decode-heavy で回したときの上限」。

### 9.4 注意 (計測の罠3件目)
vLLM 停止は `pkill -f "vllm serve"` だけでは **EngineCore worker subprocess が GPU メモリを握ったまま残る**
(GPU free が 10.89GiB に枯渇 → 再起動が ValueError で失敗)。
**`nvidia-smi --query-compute-apps=pid` の全 PID を kill** してから再起動すること。

---

## 8. 次アクション / 未取得・完了状況

完了:
- [済] 自前 8x B300 本計測 (B/B0/routing/テナントスケール/飽和) — §7
- [済] apple-to-apple (同一 512tok system prompt で Bedrock vs B0) — §7.4b
- [済] Bedrock 512tok/2048tok/E2B sweep (`results/bedrock-{31b-512tok,31b-2048tok,e2b-512tok}.json`、いずれも conc 8 以降崩壊)
- [済] GPU 性能限界 (long-ctx / goodput / decode 天井) — §9

未取得 (任意):
- 自前 Gemma 4 E2B アーム (小モデル対比) — ユーザ判断でスキップ
- Bedrock E2B/2048tok の結果数値を §4 系に追記 (JSON は取得済み)
- **GPU 解放前の後片付け (§CLUSTER-GUIDE 7)**: pod 削除で GPU 解放、namespace/image/NVMe adapters は残す。

---

## 10. PD-disaggregation 検証 (結果: Gemma 4 では NOT VIABLE)

ユーザ要望で PD (prefill/decode 分離 + NIXL KV 転送) を long-context で測ろうとした。設計 (DESIGN-v2 §2)
では「単一ノード decode-heavy には PD 不要」とスキップしていたが、long-ctx (prefill-heavy) なら効く
可能性があるため実機検証。

### 構成 (PD-PLAN.md, 既存 llm-d-disagg-b300 の NIXL レシピを Gemma4 に適用)
- 4 prefill (GPU 0-3) + 4 decode (GPU 4-7), 各 TP=1 = 8 GPU 全使用 (DP baseline と公平)
- `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both","kv_connector_extra_config":{"backends":["LIBFABRIC"]}}'`
- 同 image (NIXL v1.1.0 入り), max_model_len=32768, fp8 kv, EFA env (NCCL_SOCKET_IFNAME=^lo,docker,veth 等)
- 起動スクリプト: pod 内 `/tmp/launch_pd.sh`

### [確定 R19] 結果: 全 8 worker が起動失敗

```
vllm/distributed/kv_transfer/kv_connector/v1/nixl/worker.py:895
AssertionError: All kv cache tensors must have the same size
```
ソース該当箇所 (worker.py:893-896):
```python
if not self.use_mla:
    # Different kv cache shape is not supported by HeteroTP.
    # This must also hold true for Mamba-like models.
    assert tensor_size_bytes == curr_tensor_size_bytes, (
        "All kv cache tensors must have the same size")
```

- **根本原因**: Gemma 4 の heterogeneous attention — sliding-window 層 (kv_heads=16, head_dim=256) と
  full-attention 層 (kv_heads=4, head_dim=512) で **層ごとに KV cache テンソルのサイズが異なる**。
  NixlConnector は全層同一サイズの KV を要求 (HeteroTP 非対応) → アサーション失敗。
- **config では回避不可** (heterogeneity は言語モデル本体の仕様。`Gemma4ForCausalLM` text-only 上書きでも
  層構成は変わらない)。MLA モデル (DeepSeek 系) は `use_mla` 分岐で回避されるが Gemma4 は非 MLA。
- 全 8 worker (prefill 0-3, decode 0-3) が同一 assertion で死亡 (各 2 hits)。health 全て 000。

### 結論
- **vLLM 0.21 + NIXL では Gemma 4 (heterogeneous/sliding-window attention) の PD-disaggregation は不可能**。
  これは tuning でなく architectural な制約。
- 設計 (DESIGN-v2 §2) の「PD スキップ」判断が実機で裏付けられた (理由は当初の「decode-heavy で無益」
  に加え、そもそも Gemma4 では NIXL が動かない、が判明)。
- PD が動く前例 (llm-d-disagg-b300) は Qwen3-8B (uniform attention) / DeepSeek-V3 (MLA) で、いずれも
  この assertion を踏まない構成だった。**モデルのアーキテクチャが PD の可否を決める**という知見。
- 登壇では「PD は試したが Gemma 4 のような heterogeneous attention モデルでは NIXL KV 転送が
  成立せず、データ並列 (8x TP=1) が唯一の選択肢だった」と報告できる (負の結果も価値)。
