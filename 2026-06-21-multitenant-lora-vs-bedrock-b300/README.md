# Multi-tenant LLM Serving: Bedrock 従量課金 vs 自前 GPU プールの損益分岐

NVIDIA B300 (Blackwell, sm_103) を使った Amazon EKS 上で、マルチテナント LLM サービスの
2方式 — **Amazon Bedrock (Gemma 4 31B, system prompt, 従量課金)** と
**自前 vLLM (Gemma 4 31B fp8, Multi-LoRA / system prompt, インスタンス課金)** —
を同一メトリクス (TTFT / TPOT / Goodput) で実測し、**コストとパフォーマンスの損益分岐点**を求めた記録。

## ディレクトリ

```
2026-06-21-multitenant-lora-vs-bedrock-b300/
├── results/      # 全 sweep の生 JSON (Bedrock / 自前 B / B0 / routing / long-ctx)
├── scripts/      # 負荷ツール・ダミー LoRA 合成・図生成・vLLM 起動スクリプト
├── configs/      # inference-perf 設定 (参考)
├── manifests/    # p6-b300 上の vLLM k8s manifest (smoke / 8 replica)
├── figures-src/  # 構成図の draw.io 元 XML (silo/approach/opsloop/topology)
├── llm-d/        # 本物の llm-d/GIE EndpointPicker による LoRA-aware routing 実験 (Phase 2)
└── docs/         # RUNLOG (実行コマンド+結果) / 設計 / PD 検証
```

図について:
- `figures-src/*.xml` は draw.io で開ける構成図のソース。`gen_arch_figs.py` で再生成可能。
- 実測グラフ (goodput / コスト損益分岐 / routing / long-ctx 等) は `scripts/make_figures.py` が
  `results/*.json` から再生成します (`python scripts/make_figures.py` → `figures/`)。

## 計測サマリ (p6-b300 1ノード = B300 × 8, 128 tenant, Gemma 4 31B fp8)

SLO: TTFT ≤ 2000ms かつ TPOT ≤ 80ms。Goodput = SLO 内 req/s。

| アーム | 飽和 goodput | 出力スループット | TPOT p50 |
| --- | --- | --- | --- |
| Bedrock 31B (system prompt) | **~0.75 req/s** (concurrency 20+ で崩壊) | ~30 tok/s/req | ~7ms |
| 自前 B (Multi-LoRA, 短入力) | ~110 req/s | ~7,600 tok/s | 53ms |
| 自前 B0 (512tok system prompt) | **~398 req/s** | ~25,000 tok/s | 18ms |

主要な結論:

- **高稼働マルチテナントプールでは自前が圧勝** — 同一 512tok 入力で goodput **約 530倍** (Bedrock は同時 20 で崩壊、自前は 512 で SLO 100%)
- **コスト損益分岐 ≈ 263 req/s** (S=512, Capacity Block $93.60/hr)。自前 B0 飽和 398 req/s で**純コストでも安い**。system prompt が長い (S≥2048) ほど自前有利
- **反直感**: 自前では LoRA より system prompt が ~3.6倍速い (Multi-LoRA の SGMV per-token オーバーヘッド、TPOT 53 vs 18ms)。LoRA を選ぶ理由は性能でなくデータ分離・ガバナンス
- **賢いルーティング (llm-d affinity)** は飽和近傍で +24% (低負荷では差なし)。アダプタ swap 自体は安い (~1.2ms)
- **本物の llm-d/GIE EndpointPicker でも実証 (Phase 2, `llm-d/`)**: 8 Pod + EPP で scheduling profile だけ
  差し替えて 5 条件を公平比較。**lora-affinity 単独は高負荷 (concurrency 512) で goodput 72 req/s に崩壊** (人気テナントの
  過集中で負荷分散が効かない) が、**queue+kv-cache+prefix と合成した full profile は 124 req/s で全条件中最良・SLO 100%**。
  「LoRA-aware routing は負荷分散と組み合わせて初めて効く」を実データで裏付け。構成を 1Pod8proc→8Pod に変えても
  前回の TTFT/TPOT/Goodput と一致 (整合性検証 `llm-d/compare_integrity.py`) するため、上記サマリの数値はそのまま有効。
- **long-context**: 30K トークン入力を TTFT 2.6秒・SLO 100% で捌く。decode 天井 ~29,200 tok/s
- **PD-disaggregation は Gemma 4 では不可** — heterogeneous attention が NIXL の同一サイズ KV 要求に非互換

## 再現の要点

- モデル: Bedrock `google.gemma-4-31b` (bedrock-mantle, SigV4, OpenAI 互換 Chat Completions)。
  従来の InvokeModel/Converse は非対応、`aws bedrock list-foundation-models` にも出ない (別カタログ)。
- 自前: vLLM 0.21 (sm_103/cu13 image)、8x TP=1 データ並列、fp8 + kv-cache fp8_e4m3、max_loras=32 / max_cpu_loras=1000。
- ダミー LoRA: `scripts/synth_dummy_lora.py` (Gemma 4 の per-layer heterogeneous 次元に対応、peft を介さず safetensors 直接合成)。
- 計測: `scripts/concurrency_sweep.py` (aiohttp 真async、Bedrock と自前を同一コードで)。図は `scripts/make_figures.py`。

> 注: 本実験では **精度は評価していません** (ダミー LoRA でサービング性能のみ計測)。テナント設定の届け方による性能・コストの違いにフォーカスしています。
