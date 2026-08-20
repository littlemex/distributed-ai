---
title: "自前 EKS で Qwen3.8-27B を vLLM serving し、opencode / OpenClaw / Hermes Agent を自前バックエンドで動かした記録"
emoji: "🦉"
type: "tech"
topics: ["EKS", "vLLM", "Qwen", "Kubernetes", "LLM"]
published: false
---

自前 EKS クラスタ(`distai-eks`, ap-northeast-1)に `Qwen/Qwen3.8-27B` を vLLM で serving し、opencode / OpenClaw / Hermes Agent という 3 つの自律エージェントを自前 Qwen バックエンドで動かし、Amazon Bedrock の Web Search をツール化し、最後に YaRN で context を native の 4 倍(1M)まで拡張するところまでやった記録です。品質より網羅性を優先し、実装と実測に忠実に書きます。数値は本文中で明記した実測のみで、未計測のものは「未計測」と書きます。

## リポジトリと作業場所

- 本体: `littlemex/distributed-ai` の git worktree `/Users/akazawt/tmp/qwen/dai-serving-wt`、branch `feat/serving-vllm-qwen`。
- 成果物一式(date ディレクトリ): `/Users/akazawt/tmp/qwen/dai-serving-wt/2026-08-19-qwen3-8-27b-vllm-eks/`
  - `pool/` Karpenter NodePool マニフェスト
  - `charts/vllm-serving/` Helm chart
  - `overlays/qwen3.8-27b.yaml` モデル別チューニング
  - `models/qwen3.8-27b.yaml` モデルの事実(config.json 由来)
  - `scripts/` `up.sh` `port-forward.sh` `run_smoke.py`
  - `opencode/` `hermes/` `openclaw/` 各エージェントの pod マニフェスト
  - `tools/bedrock-websearch/` Bedrock Web Search ラッパー
  - `client/agents.sh` + `agents.env.example` 一撃ランチャ
  - `ACCESS.md` アクセス手順
- クラスタ: EKS `distai-eks`(ap-northeast-1)、kubeconfig context は `distai-tokyo`、namespace `distai`。
- クラスタに許可されている IAM principal は `arn:aws:iam::776010787911:role/Admin` のみ。ローカルの AWS プロファイルは `claude-code`(この profile で `assumed-role/Admin/...` になる)を使う必要があった。`a7760` という別プロファイルは SSO トークン失効で使えなかった。

`infra/eks`(Terraform 管理のクラスタ基盤本体)は今回**一切変更していない**。GPU プールは既存の `gpu-ddp` EC2NodeClass を再利用した Karpenter NodePool を `kubectl apply` で追加しただけで、Terraform state には触れていない。

## 全体アーキテクチャ

```
[CPU pod] OpenClaw (常時稼働 Gateway, port 18789, ブラウザ UI)
[CPU pod] opencode (対話 TUI, kubectl exec で利用)
[CPU pod] Hermes Agent (対話 TUI, kubectl exec で利用)
     │  いずれも in-cluster Service 経由で Qwen を呼ぶ
     │  Web 検索は bedrock-websearch (Bedrock Web Search を SigV4 で叩く自作ツール)
     ▼
[GPU pod] vLLM v0.27.1 — Qwen/Qwen3.8-27B (TP4, g6e.12xlarge, YaRN で 1M context)
```

## Qwen/Qwen3.8-27B の実体

`models/qwen3.8-27b.yaml` に事実だけを切り出してある。HuggingFace の `config.json` から確認した内容:

| 項目 | 値 |
|---|---|
| model_id | `Qwen/Qwen3.8-27B` |
| architecture (transformers) | `Qwen3_5ForConditionalGeneration`(`model_type: qwen3_5`) |
| modality | `image-text-to-text`(VLM。`image_token_id` あり) |
| license | apache-2.0 |
| dtype | bfloat16 |
| 重みサイズ(概算) | 約 54 GiB |
| パラメータ数 | 27B |
| 注意機構 | ハイブリッド。全 64 層中 16 層が full_attention(4 層ごとに 1 回)、残り 48 層が linear_attention(Gated DeltaNet) |
| num_attention_heads | 24 |
| num_key_value_heads | 4(テンソル並列度はこれを割り切れる値 = 1, 2, 4 のいずれか) |
| head_dim | 256 |
| max_position_embeddings(native) | 262144 |
| rope_parameters | `mrope_interleaved: true`, `mrope_section: [11, 11, 10]`, `partial_rotary_factor: 0.25`, `rope_theta: 10000000`, `rope_type: default` |

製品名(`Qwen3.8-27B`)と transformers 上のアーキ識別子(`qwen3_5`)は別物である点に注意。`models/qwen3.8-27b.yaml` ではモデル名をファイル名に、`architecture: qwen3_5` は事実フィールドとして分離して持たせている。

ハイブリッド注意の実務上の含意:
- linear_attention 層は固定サイズの recurrent state を持ち、paged KV ではない。そのため **prefix caching が非対応**。
- 同時実行数を制約するのは KV プールではなく recurrent state。
- 重み約 54 GiB は 48 GB の L40S 1 枚に収まらないため、TP(テンソル並列)が必須。`num_key_value_heads=4` なので TP は 1, 2, 4 のいずれかを選べる。

## vLLM serving

### イメージとカスタムビルドの要否

`vllm/vllm-openai:v0.27.1`(upstream 公式イメージ、カスタムビルド不要)を使用した。事前に GitHub 上の vLLM `main` ブランチと `v0.27.1` タグの `vllm/model_executor/models/registry.py` を確認し、`Qwen3_5ForConditionalGeneration` が両方に登録されていることを確認済み。PyPI の vLLM 最新版は `0.27.1`(確認時点)。

### GPU ノードプール

`pool/nodepool-gpu-l40s.yaml` で Karpenter NodePool `gpu-l40s` を追加した。既存の `gpu-ddp` という EC2NodeClass を再利用しており、新規の EC2NodeClass は作っていない。

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-l40s
spec:
  disruption:
    budgets:
    - nodes: 10%
    consolidateAfter: 5m
    consolidationPolicy: WhenEmpty
  limits:
    cpu: "200"
    memory: 2000Gi
  template:
    metadata:
      labels:
        distributed-ai/device: nvidia
        node-role: gpu-l40s
    spec:
      expireAfter: Never
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-ddp
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["g6e.12xlarge"]
      - key: topology.kubernetes.io/zone
        operator: In
        values: ["ap-northeast-1a"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: kubernetes.io/os
        operator: In
        values: ["linux"]
      taints:
      - effect: NoSchedule
        key: nvidia.com/gpu
      terminationGracePeriod: 1h
```

適用:

```bash
kubectl --context distai-tokyo apply -f /Users/akazawt/tmp/qwen/dai-serving-wt/2026-08-19-qwen3-8-27b-vllm-eks/pool/nodepool-gpu-l40s.yaml
```

`g6e.12xlarge` は L40S x4(合計 VRAM 192GB)。`consolidationPolicy: WhenEmpty` + `consolidateAfter: 5m` により、Pod が無くなって 5 分経てば Karpenter がノードを自動回収する。GPU quota は「Running On-Demand G and VT instances」がこのインスタンス(48 vCPU 分)をカバーしている必要がある。

### Helm chart とデプロイ

`charts/vllm-serving/`(Helm chart)を `helm template | kubectl apply` で投入する運用(Helm release は作らない)。デプロイコマンド:

```bash
helm template x /Users/akazawt/tmp/qwen/dai-serving-wt/2026-08-19-qwen3-8-27b-vllm-eks/charts/vllm-serving \
  -f /Users/akazawt/tmp/qwen/dai-serving-wt/2026-08-19-qwen3-8-27b-vllm-eks/overlays/qwen3.8-27b.yaml \
  -n distai | kubectl --context distai-tokyo apply -n distai -f -
```

chart のテンプレート(`charts/vllm-serving/templates/deployment.yaml`)は values に応じて以下の vLLM 起動引数を生成する:

- `--model` `--served-model-name` `--tensor-parallel-size` `--pipeline-parallel-size`
- `--max-model-len`(Helm が `1e6` 以上の整数を科学表記でレンダリングしてしまう問題があったため、テンプレート側で `{{ int64 .Values.maxModelLen }}` として明示的に整数化している。後述の YaRN 検証で実際にこれで一度クラッシュした)
- `--gpu-memory-utilization` `--max-num-seqs` `--dtype`
- `--no-enable-prefix-caching`(`enablePrefixCaching: false` の時)
- `--enforce-eager`(任意)
- `--enable-auto-tool-choice --tool-call-parser=<toolCallParser>`(`enableAutoToolChoice: true` の時)
- `--default-chat-template-kwargs=<chatTemplateKwargs>`(JSON 文字列)
- `--hf-overrides=<hfOverrides>`(JSON 文字列。YaRN 拡張で使用)
- `extraArgs` によるエスケープハッチ

Deployment の `strategy.type` は `Recreate`。GPU 1 台あたりのデバイス数が固定なので、RollingUpdate だと新旧 Pod が GPU を取り合ってしまうため。`startupProbe` は `/health` への httpGet で、`periodSeconds` と `failureThreshold` を values で調整できる(コールドスタートが長いモデルのため)。`/dev/shm` は `emptyDir(medium: Memory)`、HF キャッシュも `emptyDir`(この検証では永続化していない)。

### 現在の overlay(最終状態)

`overlays/qwen3.8-27b.yaml` の最終版(この記事執筆時点):

```yaml
image: vllm/vllm-openai:v0.27.1
model: Qwen/Qwen3.8-27B
nodeRole: gpu-l40s
gpuCount: 4
tensorParallelSize: 4
maxModelLen: 1048576
gpuMemoryUtilization: 0.92
maxNumSeqs: 2
hfOverrides: '{"rope_scaling":{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":262144}}'
extraEnv:
  VLLM_ALLOW_LONG_MAX_MODEL_LEN: "1"
enablePrefixCaching: false
enableAutoToolChoice: true
toolCallParser: qwen3_coder
chatTemplateKwargs: '{"enable_thinking": false}'
```

TP4 は g6e.12xlarge(L40S x4)全部を使う構成で、`num_key_value_heads=4` が TP4 を割り切れるため成立する。

### max_model_len の変遷

一度に 1048576 にしたわけではなく、次の順で上げていった。

| 段階 | max_model_len | 理由 |
|---|---|---|
| 1 | 32768 | 最初のブリングアップ。native(262144)の一部で安全に立てるための初期値 |
| 2 | 65536 | Hermes Agent が「context window は最低 64K 必要」という制約を持っており、`ollama/Qwen/Qwen3.8-27B` で接続しようとした際に vLLM 側が 32768 を返したため拒否された。65536 に上げて解消 |
| 3 | 131072 | Hermes に Bedrock Web Search MCP を登録した際の research turn で `Context length exceeded: max compression attempts (3) reached.` というエラーが発生。system prompt + tools + skills の分だけ余裕を持たせるため 128K に拡張(この段階は YaRN 未使用、native 262144 の範囲内) |
| 4 | 1048576(YaRN) | native の 4 倍まで context を伸ばす検証として YaRN を適用(後述) |

### コールドスタートの実測

`node launch(2-4分) + イメージ pull + 重みダウンロード(約54GiB) + コンパイル/ウォームアップ` で、実測で **約 9.5 分**で Ready になった(このクラスタでの観測値)。

### 動作確認スクリプト

```bash
cd /Users/akazawt/tmp/qwen/dai-serving-wt/2026-08-19-qwen3-8-27b-vllm-eks/scripts
export KCTX=distai-tokyo NAMESPACE=distai
./up.sh qwen3.8-27b
./port-forward.sh qwen3.8-27b 8000 &
python3 run_smoke.py --base-url http://localhost:8000 --model Qwen/Qwen3.8-27B
```

`run_smoke.py` は `/v1/models` の一覧確認 → chat completion → tool call のアサートまでを行う。

## thinking(overthinking)問題と対策

### 発生した問題

デフォルト設定(thinking 有効、`reasoning_effort` は既定値 `xhigh`)で、曖昧・難しいタスクを投げると、モデルが延々と `reasoning_content` に思考を書き続け、`max_tokens` に達して `finish_reason: "length"` で終わり、`content`(最終回答)が空のまま返ってくる現象が発生した。エージェントのツールループがこれで止まる/タイムアウトする実害も観測した。

これは Qwen 系の thinking モデル特有の、greedy/低温デコード時に停止トークンを出さず無限に反復し続けるという既知の問題傾向と一致する。

### 発見: chat_template に reasoning_effort パラメータがある

`Qwen/Qwen3.8-27B` の `tokenizer_config.json` の `chat_template` を確認したところ、次のロジックが埋め込まれていた(該当部分の抜粋、Jinja テンプレート):

```jinja
{%- if enable_thinking is undefined or enable_thinking is true %}
    {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
    {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
        {{- raise_exception('Unexpected reasoning effort ' ~ reasoning_effort ~ '. Supported types are xhigh (default), medium, and low.') }}
    {%- endif %}
    {%- if resolved_reasoning_effort == 'xhigh' %}
        {%- set reasoning_instructions = 'Reasoning effort is set to xhigh. Please think carefully through the task, ...' %}
    {%- elif resolved_reasoning_effort == 'low' %}
        {%- set reasoning_instructions = 'Reas...' %}
```

つまり `enable_thinking` と `reasoning_effort`(`xhigh` | `medium` | `low`、既定 `xhigh`)は vLLM の `chat_template_kwargs` としてリクエストごとに(または `--default-chat-template-kwargs` でサーバ既定として)渡せる。これは [zenn の別記事](https://zenn.dev/shogo0x2e/articles/qwen38-27b-stop-overthinking) が llama.cpp の `reasoning_budget_tokens`(思考トークン予算 + 予算超過時に `</think>` 直前へ打ち切りメッセージを注入)で実現していた「考えすぎ対策」に相当する仕組みが、vLLM でも `reasoning_effort` パラメータとしてモデル側(chat_template 側)にネイティブに存在していた、ということ。llama.cpp 固有の機構を持ち込まずに vLLM で同等の効果を狙える。

### before/after 実測

条件: vLLM `Qwen/Qwen3.8-27B`、TP4 on g6e.12xlarge、`chat_template_kwargs` をリクエストごとに変更、同一の曖昧な難問プロンプト、`temperature=0`、`max_tokens=8192`。

| 設定(chat_template_kwargs) | finish_reason | completion_tokens | 応答時間 | 最終回答に到達 |
|---|---|---|---|---|
| `reasoning_effort=xhigh`(既定、thinking ON) | `length` | 8192 | 188s | ✗(max_tokens まで思考して回答に至らず = overthinking を再現) |
| `reasoning_effort=medium` | `stop` | 955 | 21s | ✓ |
| `reasoning_effort=low` | `stop` | 635 | 14s | ✓ |
| `enable_thinking=false`(thinking OFF) | `stop` | 999 | 34s | ✓ |

既定の `xhigh` は、この曖昧な難問プロンプトに対して 8192 トークンの予算を使い切っても最終回答に到達しなかった(overthinking の再現)。`reasoning_effort` を `medium` または `low` に下げる、あるいは `enable_thinking` を `false` にすることで、いずれも `finish_reason: stop` で正常終了した。

なお、簡単なタスク(例: 単語 1 つを返すだけの指示)では `xhigh` のままでも `stop` で正常終了することを別途確認している(この記事の早い段階の検証)。overthinking が顕在化するのは、曖昧・オープンエンドな難問に対してであり、あらゆるリクエストで暴走するわけではない。

### 採用した既定値

エージェントのバックエンドとして安定動作させる目的から、サーバ既定は `chat_template_kwargs: '{"enable_thinking": false}'`(thinking を完全に OFF)を採用した(`--default-chat-template-kwargs` で設定、overlay に記載)。個別リクエストで `chat_template_kwargs` を上書きすれば thinking を有効化した上で `reasoning_effort` を絞ることもできる。

## Tool calling

`chat/completions` エンドポイントでの tool calling を有効にするには、`--enable-auto-tool-choice` と、モデルの chat_template が出力する tool call フォーマットに合った `--tool-call-parser` が必要。

`Qwen/Qwen3.8-27B` の chat_template を確認したところ、tool call は次の Qwen3 XML 形式で出力されることが分かった(抜粋):

```
<tool_call>
<function=example_function_name>
<parameter=example_parameter_1>
value_1
</parameter>
</function>
</tool_call>
```

これは JSON 形式を期待する `hermes` パーサーでは解釈できず、**`qwen3_coder` パーサーを使う必要がある**。vLLM の起動引数は次の通り:

```
--enable-auto-tool-choice --tool-call-parser=qwen3_coder
```

これを使わずに `tools` 付きリクエストを送ると `HTTP 400: The model's maximum context length...` のような形ではなく `tool_calls` が構造化されずに返ってくる(生テキストのまま)、または 400 エラーになる。OpenAI 互換であることと tool-calling 互換であることは別問題なので、`run_smoke.py` では tool call のアサートも入れている。

## Amazon Bedrock Web Search をツール化する

### なぜ直接使えないか

Amazon Bedrock の `web_search` ツールは、以下の条件を満たす場合のみ使える:

- **Responses API** 経由(`chat/completions` ではエラーになる。`web_search` を `tools` に渡すと `unrecognized`/バリデーションエラーになる)
- **Bedrock 自身の OpenAI モデル**(`openai.gpt-5.6-sol` などの bare モデル ID)を使う
- エンドポイントは `https://bedrock-mantle.<region>.api.aws/openai/v1/responses`(region は `us-east-1` / `us-east-2` / `us-west-2` のいずれか)
- SigV4 署名(service 名は `bedrock`)
- self-host 不可(マネージドのみ)

つまり、自前 Qwen の tool-calling にそのまま `web_search` を組み込むことはできない。Qwen が使うモデルは Qwen のまま、web 検索だけを別のツールとして呼び出す形にする必要がある。

### 実装: `bedrock_websearch.py`

`tools/bedrock-websearch/bedrock_websearch.py` という 1 ファイルの薄いラッパーを実装した。標準ライブラリのみに依存(SigV4 署名も自前実装。`botocore` は無くても動く)で、2 つの入口を持つ:

- CLI: `python3 bedrock_websearch.py "<query>"` → 回答本文 + 出典 URL を標準出力に出す
- MCP: `python3 bedrock_websearch.py --mcp` → 依存なしの stdio JSON-RPC MCP サーバ(`initialize` / `notifications/initialized` / `tools/list` / `tools/call` を実装し、ツール名 `web_search` を公開)

認証情報の解決順序(コードの実装通り):

1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`(+ `AWS_SESSION_TOKEN`)が環境変数にあればそれを使う
2. `AWS_CONTAINER_CREDENTIALS_FULL_URI`(または `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` から `http://169.254.170.2<rel>` を組み立て)があればそれを使う
3. 上記が環境変数として渡ってこない場合の**固定フォールバック**: `/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token` が存在すれば、EKS Pod Identity の固定エンドポイント `http://169.254.170.23/v1/credentials` にこのトークンファイルの内容を `Authorization` ヘッダとして渡してクレデンシャルを取得する
4. それでも取れない場合、最後の手段として `botocore` が入っていればそれを使う(ローカル開発の profile/SSO 用)

この 3 番目のフォールバックを実装した理由は実際にハマったから: opencode の MCP サブプロセスは、opencode.json の `environment` に書いた環境変数しか MCP サブプロセスに渡さず、Pod 自体に注入されている EKS Pod Identity のコンテナクレデンシャル環境変数(`AWS_CONTAINER_CREDENTIALS_FULL_URI` など)を継承しなかった。そのため MCP 経由の呼び出しだけが認証エラーになり、`kubectl exec` で直接 CLI を呼ぶと(コンテナの全 env を継承するので)成功する、という非対称な現象が発生した。固定パスへのフォールバックを実装したことで、環境変数の伝播経路に関係なく Pod Identity から認証できるようになった。

Bedrock 側の呼び出しは Responses API に `tools: [{"type": "web_search", "external_web_access": true}]` を渡し、レスポンス中の `web_search_call`(実際に投げた検索クエリ)と `output_text` の `annotations`(`url_citation`)を抜き出して整形する。

### EKS Pod Identity のセットアップ

Bedrock 呼び出し用の IAM ロールを 1 つ作り、各エージェントの Pod にひも付けた。

```bash
# ロール(信頼ポリシーは pods.eks.amazonaws.com)
aws iam create-role --role-name distai-openclaw-bedrock \
  --assume-role-policy-document file:///tmp/pi-trust.json
aws iam attach-role-policy --role-name distai-openclaw-bedrock \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess

# ServiceAccount ごとに Pod Identity association を作成(opencode / hermes / openclaw の3つ)
kubectl --context distai-tokyo -n distai create sa opencode
aws eks create-pod-identity-association --cluster-name distai-eks --region ap-northeast-1 \
  --namespace distai --service-account opencode \
  --role-arn arn:aws:iam::776010787911:role/distai-openclaw-bedrock
```

同様に `hermes`、`openclaw` の ServiceAccount にも同じロールへの association を作成した。`AmazonBedrockFullAccess` は検証用のため広すぎる権限であり、本番運用するなら Bedrock 呼び出しに絞った最小権限ポリシーに絞るべき(未実施)。

### 各エージェントへの組み込み方

エージェントによって MCP の対応状況が違ったため、組み込み方が 3 パターンに分かれた。

- **opencode**: `opencode.json` の `mcp` セクションに `bedrock-websearch` を `local` stdio サーバとして登録。`opencode run --pure --auto` で動作確認、Qwen エージェントが `bedrock-websearch_web_search` を実際に呼び出し、出典付きの回答を返すことを確認した(例: vLLM の最新バージョンを聞いて `v0.27.1` と出典 URL を回答)。
- **OpenClaw**: 検証時点で固定していたイメージ `ghcr.io/openclaw/openclaw:2026.3.1` には `openclaw mcp` サブコマンドが存在しなかった。そのため MCP 経由ではなく、エージェントの shell 実行ツール + `AGENTS.md`(ツールの使い方を教える指示ファイル)をワークスペースに配置する方式で組み込んだ。`AGENTS.md` を ConfigMap でマウントし、起動コマンドで `~/.openclaw/workspace/AGENTS.md` にコピーしている。「Go の最新版を調べて」のようなコマンド指定なしの依頼でも、この指示ファイルにより自動的に `python3 /opt/tools/bedrock_websearch.py` を実行して回答することを確認した。
- **Hermes Agent**: `hermes mcp add bedrock-websearch --command python3 --env BEDROCK_WS_REGION=us-east-1 --args /opt/tools/bedrock_websearch.py --mcp` で登録できるが、実行すると「Enable all tools? [Y/n/select]」という**対話プロンプト**が出て、非対話実行(Pod 起動スクリプト内)では `Cancelled` になってしまう。`echo y | hermes mcp add ...` とパイプで `y` を渡すことで解消した。登録後は `hermes mcp list` で `bedrock-websearch` が `enabled` として確認できる。

### Bedrock Web Search のコスト・制約に関する留意点

- 検索を伴う 1 回の Responses API 呼び出しで、入力トークンが大きくなる(実測で約 30k input tokens/回、web コンテキストが注入されるため)。課金は `billing.payer=developer` としてアカウントに乗る。
- `chat/completions` では `web_search` を拒否するため、必ず Responses API 経由にする必要がある。

## エージェントの接続とハマりどころ / 特徴比較

opencode / qwen-code / OpenClaw / Hermes Agent の 4 つを自前 Qwen バックエンドで動かした。それぞれの素性とハマりどころ、そして使ってみて見えた特徴を記録する。

### opencode

`@ai-sdk/openai-compatible` プロバイダとして自前 vLLM を登録する。opencode 独自の落とし穴:

- 非対話実行(`opencode run`)で、外部プラグインのロードが原因で間欠的にハングする現象があった。`--pure`(外部プラグインなしで実行)を付けることで回避した。
- 同様に、opencode のローカル状態(`~/.local/share/opencode/project`, `~/.local/share/opencode/storage`)が古いまま残っていると `init` 直後でハングし、vLLM に一切リクエストが届かない現象があった。該当ディレクトリを削除して state をクリアすると解消した。
- 非対話でツール(ファイル読み取り等)を使わせるには `--auto`(権限自動承認)が必要。無いと承認待ちでブロックする。
- モデルの `limit.context` / `limit.output` を opencode.json 側で明示しないと、opencode が既定で大きな `max_tokens`(実測で約 32000)を要求し、vLLM 側の `max_model_len` を超えて `400` エラーになった。`{"limit": {"context": 32768, "output": ...}}` のように明示して解消した。

### qwen-code

Qwen 公式の gemini-cli フォーク(npm `@qwen-code/qwen-code`、バイナリ `qwen`、実測 0.21.14)。設定は単一の `~/.qwen/settings.json` で、`modelProviders.openai` の `baseUrl` を自前 vLLM に向け、`security.auth.selectedType: "openai"` を入れておくと起動時の対話 `/auth` をスキップできる。MCP は同じ settings.json の `mcpServers` で登録する。qwen-code 独自の落とし穴:

- MCP の状態表示 `qwen mcp list` は stdio サーバを `Disconnected` と出すが、これは静的表示で、実セッションでは遅延接続される(実際に web_search ツールが呼べて URL 付きで返る)。表示に惑わされないこと。
- 非対話は `-p "..."`、セッション再開は `-r <id>` / `-c`。ツールを自動実行させるには `--approval-mode yolo` が要る(承認プロンプトで止まる)。
- **マルチモーダルのモダリティ判定がモデル名ベース**。qwen-code は `qwen*-vl-*` のような名前でだけ画像/動画対応と判定するため、自前の `Qwen/Qwen3.8-27B` という名前だと vision 非対応と見なされ、`@画像パス` を渡しても添付が `Operation cancelled` でキャンセルされる(`--approval-mode yolo` でも変わらない=承認ではなくモダリティ判定が原因)。**`modelProviders.openai[].generationConfig.modalities` に `{"image": true, "video": true}` を明示**すると解消し、画像を読めるようになった(E2E 実測: push した画像内テキストを正しく読解)。
- `@path` はプロセスの cwd 基準で解決される。Pod 内で動くため参照できるのは Pod 上のパスだけ(Mac ローカルのファイルは直接読めない)。

### OpenClaw

自前 vLLM を `custom-api-key`(OpenAI 互換)として非対話 onboard する:

```bash
openclaw onboard --non-interactive --accept-risk --flow quickstart \
  --auth-choice custom-api-key \
  --custom-base-url "http://vllm-qwen-qwen3-8-27b:8000/v1" \
  --custom-model-id "Qwen/Qwen3.8-27B" --custom-compatibility openai \
  --custom-api-key "vllm-local" --custom-provider-id "qwen-eks" \
  --gateway-bind lan --gateway-port 18789 --gateway-auth token --gateway-token "<token>"
openclaw config set agents.defaults.model.primary "qwen-eks/Qwen/Qwen3.8-27B"
```

Gateway(Control UI + agent runtime + cron スケジューラ)をメインプロセスとして起動し続けることで「常時稼働の自律エージェント」になる。`openclaw agent --agent main -m "..."` でワンショット実行もできる。落とし穴として `--auth-choice vllm`(バンドルされた vLLM 専用プロバイダ)は 127.0.0.1 決め打ちの自動検出を試みるため対話モード限定であり、非対話の headless Pod では使えなかった。`custom-api-key` + `--custom-base-url` で明示指定することで回避した。

### Hermes Agent(Nous Research)

公開イメージ `nousresearch/hermes-agent:v2026.8.18`(Docker Hub、ビルド不要)を使用。自前 Qwen への接続は、Hermes が持つ `ollama` プロバイダの base URL を上書きすることで実現した(Qwen 専用プロバイダは OAuth 前提だったため):

```bash
export OLLAMA_API_KEY=vllm-local
export OLLAMA_BASE_URL=http://vllm-qwen-qwen3-8-27b:8000/v1
```

ハマった点が 2 つ:

1. **モデル参照のスラッシュ問題**: `model.default` を `ollama/Qwen/Qwen3.8-27B` のように provider 接頭辞付きで設定すると、モデル ID 自体に含まれるスラッシュのせいで内部的に壊れ、`HTTP 404: The model \`ollama<path>-27B\` does not exist.` のようなエラーになる。**provider 接頭辞を付けない bare な `Qwen/Qwen3.8-27B` を `model.default` に設定する**(provider は `OLLAMA_*` の環境変数から解決される)ことで解消した。
2. **`/root` へのアクセス権限**: Hermes のエージェント/ターミナル実行はサンドボックス化されており非 root で動くため、`/root`(パーミッション `0700`)配下の作業ディレクトリ(`/root/work` や `/root/.git` 相当)にアクセスできず `[Errno 13] Permission denied` になった。**`/opt/data/work` のように `/root` の外の、誰でもアクセス可能(`chmod 777`)な git 初期化済みディレクトリ**を `terminal.cwd` に設定することで解消した。
3. Hermes の実際の設定ファイルは `~/.hermes/config.yaml` ではなく **`/opt/data/config.yaml`**である。ConfigMap で `~/.hermes/config.yaml` をマウントしても Hermes は読んでいなかった(`hermes config get` で未設定として返ってくる)。`hermes config set model.default ...` / `hermes config set terminal.cwd ...` のように CLI 経由で設定する必要がある。
4. Hermes は最低 64K の context window を要求する。vLLM の `max_model_len` を 65536 未満(32768)にしていた段階では `Model ... has a context window of 32,768 tokens, which is below the minimum 64,000 required by Hermes Agent.` というエラーで拒否された。

最終的な Pod 起動コマンド(要旨):

```bash
ln -sf /opt/hermes/bin/hermes /usr/local/bin/hermes
mkdir -p /opt/data/work && chmod 777 /opt/data/work
cd /opt/data/work
git rev-parse --git-dir >/dev/null 2>&1 || git init -q
git config user.email agent@local && git config user.name hermes
hermes config set model.default "Qwen/Qwen3.8-27B"
hermes config set terminal.cwd "/opt/data/work"
echo y | hermes mcp add bedrock-websearch --command python3 \
  --env BEDROCK_WS_REGION=us-east-1 --args /opt/tools/bedrock_websearch.py --mcp
```

### 使ってみて見えた特徴の比較

| 観点 | opencode | qwen-code | Hermes Agent |
|---|---|---|---|
| 位置づけ | コーディング特化 | コーディング特化(gemini-cli フォーク) | 汎用パーソナルアシスタント(コーディング専用ではない) |
| バックエンド接続 | `@ai-sdk/openai-compatible` プロバイダ | `modelProviders.openai`(openai auth type) | `ollama` プロバイダの base URL 上書き |
| 設定の置き場 | `opencode.json` | `~/.qwen/settings.json`(単一ファイル) | `/opt/data/config.yaml`(CLI `hermes config set` 経由) |
| MCP 登録 | local stdio(コンテナ env が subprocess に渡らず、Pod Identity は固定エンドポイント fallback が必要) | settings.json `mcpServers`(遅延接続) | `hermes mcp add` |
| 非対話実行 | `opencode run --pure --auto` | `qwen -p`(ツールは `--approval-mode yolo`) | ワンショット CLI あり |
| 画像入力 | 可(base64 data URL、モデル名 gate なし) | 可(ただし `modalities` 明示が必要) | 可(`supports_vision: true` が必要) |
| 動画入力 | 経路なし(openai/anthropic protocol が動画 MIME を拒否) | 条件付き(モデル名 gate + 明示設定) | 独自 `video_url` 拡張(vLLM との相互運用は未検証) |
| ローカルファイル | 自プロセスの FS を読んで base64 | `@path`(cwd 基準) | 統一 resolver(data/http/file/local/container) |
| 主なハマり | 古い state / 外部プラグインでハング、`max_tokens` 明示 | モデル名モダリティ gate、`mcp list` の Disconnected 表示 | slash 入りモデル名、`/root` 権限、config 置き場、64K 下限 |

要約すると、コーディング用途では opencode と qwen-code が本命で、qwen-code は gemini-cli 譲りの `@path` とマルチモーダル、opencode は `run --pure` の非対話が使いやすい。Hermes はコーディング特化ではなく汎用アシスタント寄りという位置づけが実際に触ってみて分かった。OpenClaw はブラウザ Control UI と cron を持つ「常駐エージェント」型で毛色が違う。

### マルチモーダル(画像/動画)の学び

- **本番 vLLM(MTP + YaRN 1M 有効)がそのまま画像を理解**した。テキスト入り画像を送ると正しく OCR し(実測)、spec decode(MTP)や YaRN 1M と同居しても画像理解は壊れなかった。serving 側の設定変更なしで動く。
- 3 エージェントに共通するのは「**Pod のファイルシステムからファイルを読んで base64 でリクエストに埋め込む**」方式で、アップロード API 経路は持たない。したがって Mac ローカルのファイルはまず Pod に入れる必要がある。`agents.sh push <file>`(内部は `kubectl cp`)で Pod の `/root/media/` に置き、TUI で `@/root/media/foo.png` のように参照する運用にした。動画は vLLM 側でどうせ数フレームに間引かれるため、push 内で ffmpeg で事前ダウンサンプル(fps 1 / 512px / 60s)している。
- 動画対応は総じて弱い。opencode は動画経路そのものがなく、qwen-code / Hermes はコードはあるが送信形式(特に Hermes の独自 `video_url`)と vLLM の解釈が一致するかは未検証。画像が確実な道。

## アクセス方法: ssh は不要だった

最初は各エージェント Pod に openssh-server を仕込み、ssh 鍵を生成して port-forward + `ProxyCommand` で `ssh opencode` のように一撃で入れる仕組みを作った。しかし後から考え直し、**対話的にエージェントを使うだけなら `kubectl exec -it` で十分**であり、既存の kubeconfig / AWS 認証をそのまま使えるため、ssh 鍵・sshd・`~/.ssh/config` の管理はすべて不要と判断して撤去した。scp/sftp/rsync や VS Code Remote-SSH のような ssh ネイティブなツールを使う必要が出たら sshd + 鍵を戻す、という判断。

現在の一撃ランチャ(`client/agents.sh`)はキーレスで、次のコマンドだけで動く:

```bash
cd /Users/akazawt/tmp/qwen/dai-serving-wt/2026-08-19-qwen3-8-27b-vllm-eks/client
cp agents.env.example agents.env   # AWS_PROFILE=claude-code などを編集
./agents.sh setup                  # kubeconfig context 作成のみ
./agents.sh opencode                # kubectl exec -it で opencode TUI
./agents.sh hermes                  # kubectl exec -it で hermes TUI
./agents.sh openclaw                # 裏で port-forward + ブラウザで Control UI を開く
./agents.sh down                    # 裏の port-forward を停止
```

素の kubectl でも同じことができる:

```bash
kubectl --context distai-tokyo -n distai exec -it deploy/opencode -- bash -lc opencode
kubectl --context distai-tokyo -n distai exec -it deploy/hermes   -- bash -lc hermes
kubectl --context distai-tokyo -n distai port-forward svc/openclaw 18789:18789
```

`agents.env` の `AWS_PROFILE` を空文字にすると `aws` CLI が空プロファイルと解釈してエラーになったため、`agents.sh` 内で空文字なら `unset AWS_PROFILE` する処理を入れている。

## YaRN による 1M context への拡張

### モチベーションとハードウェア上の見積もり

Qwen3.8-27B の native context は 262144(256K)。モデルカードには「YaRN を適用することで最大 1M トークンまで拡張可能」との記載がある。まず g6e.12xlarge(L40S x4, 合計 VRAM 192GB, TP4)というハードウェア構成でどこまで context を伸ばせそうかを見積もった。

- KV キャッシュが必要なのは full_attention の 16 層のみ(linear_attention 48 層は固定サイズの recurrent state で context 長に比例しない)。
- KV サイズ ≒ `num_kv_heads(4) × head_dim(256) × 2(K/V) × 2byte(bf16) × 16層 = 64KB/token`。
- 192GB × 0.90(利用率) − 重み 54GB ≒ 100GB 程度が KV に使える(概算、この見積もり自体は実測ではない)。
- 64KB/token で割ると、合算で ~1.5M トークン相当の KV が載る計算になり、native の 262144 は 1 本あたり KV 約 16GiB(合算)で十分収まる計算だった。

この見積もりに基づき、まず native の 4 倍(1048576 = 262144 × 4)を YaRN の `factor: 4.0` として試すことにした。

### vLLM での設定方法とハマった点

vLLM `v0.27.1` には `--rope-scaling` という起動フラグは**存在しない**。試したところ `unrecognized arguments: --rope-scaling=...` で即クラッシュした。正しい方法は `--hf-overrides` に `rope_scaling` を JSON で注入すること:

```
--hf-overrides={"rope_scaling":{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":262144}}
```

これでも一度失敗した。エラーは:

```
pydantic_core._pydantic_core.ValidationError: 1 validation error for ModelConfig
  Value error, User-specified max_model_len (1048576) is greater than the derived
  max_model_len (max_position_embeddings=262144.0 ...). To allow overriding this
  maximum, set the env var VLLM_ALLOW_LONG_MAX_MODEL_LEN=1. ...
```

`--hf-overrides` の `rope_scaling` だけでは vLLM 内部の「導出された max_model_len」のガードが解除されず、`VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` を環境変数として明示的に渡す必要がある。このガードは vLLM 自身が「RoPE を使うモデルで導出値を超える position は nan を生む可能性がある」と警告している安全弁であり、`extreme caution` を要すると明記されている。

さらにもう一つ、これらの前にHelm chart 側の罠を踏んだ:`maxModelLen: 1048576` を Helm がテンプレートでレンダリングすると `1.048576e+06` という科学表記の文字列になり、vLLM の `--max-model-len` パーサーが `invalid human_readable_int_or_auto value: '1.048576e+06'` として拒否した。`charts/vllm-serving/templates/deployment.yaml` の該当行を `--max-model-len={{ int64 .Values.maxModelLen }}` として明示的に整数化することで解消した。

最終的な overlay の該当部分:

```yaml
maxModelLen: 1048576
gpuMemoryUtilization: 0.92
maxNumSeqs: 2
hfOverrides: '{"rope_scaling":{"rope_type":"yarn","factor":4.0,"original_max_position_embeddings":262144}}'
extraEnv:
  VLLM_ALLOW_LONG_MAX_MODEL_LEN: "1"
```

`maxNumSeqs` は 1M トークンの KV を確保する余裕を持たせるため 2 まで下げた(後述の同時実行数の検証はこの記事では未実施、「未計測」)。

### 動作確認: needle-in-haystack

`/v1/models` の `max_model_len` が `1048576` になっていることをまず確認。次に、native(262144)を明確に超えるプロンプト長で「干し草の中の針(needle-in-haystack)」テストを行った。パディング文字列の中に秘密のパスフレーズを 1 箇所埋め込み、それを最後に問い合わせる形式。

実測(1 回目の試行、prompt_tokens が native 未満だったケース):

- `prompt_tokens: 153049`(native 262144 未満)
- 回答: `EMERALD-DELTA-7742`(埋め込んだ秘密の passphrase と完全一致)

native を明確に超えることを確認するため、パディングを増やして再実行:

- `prompt_tokens: 324049`(native 262144 を明確に超える)
- 回答: `EMERALD-DELTA-7742`(完全一致)
- 応答時間: 174.4 秒

native の 262144 を超える 324049 トークンの context の中に埋めた needle を正しく取り出せたことから、YaRN による context 拡張が実際に機能していることを確認した。

### 精度への影響と今回の検証の限界

YaRN は一般に、長さを拡張する代わりに精度(特に中間~長距離の検索精度)が低下し得る手法として知られている。今回検証したのは 324049 トークンでの単一 needle の完全一致取得のみであり、以下は**未計測**:

- 1M トークン(1048576)に近い長さでの needle 検索精度
- 複数 needle や needle の位置(先頭/中間/末尾)による精度差
- YaRN 無し(native 262144 以下)との定量的な精度比較
- 長 context 時のスループット/レイテンシの系統的な計測

これらは今後の検証課題として残っている。

## まとめ

- `Qwen/Qwen3.8-27B`(ハイブリッド注意の VLM)は upstream の `vllm/vllm-openai:v0.27.1` でカスタムビルド無しに serving できた。
- 既定の thinking(`reasoning_effort=xhigh`)は曖昧な難問で overthinking(`finish_reason: length`、回答未達)を起こす。`chat_template_kwargs` の `reasoning_effort`(`medium`/`low`)または `enable_thinking=false` で回避できることを実測で確認した。
- tool calling には `qwen3_coder` パーサーが必要(chat_template が Qwen3 XML 形式を出力するため)。
- Bedrock の Web Search は Qwen の tool-calling に直結できないため、SigV4 の薄いラッパーツール(`bedrock_websearch.py`)を自作し、opencode(MCP)/OpenClaw(shell + AGENTS.md)/Hermes(MCP)の 3 パターンで組み込んだ。EKS Pod Identity でキーレス認証。
- ssh は結局不要で、`kubectl exec` に一本化した。
- YaRN で native の 4 倍(1048576)まで context を拡張し、324049 トークンでの needle-in-haystack を実証したが、精度の系統的な評価は未計測のまま残っている。
