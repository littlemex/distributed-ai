# figures-src — 構成図の draw.io ソース

登壇スライド / ブログで使う構成図の **draw.io XML ソース** です。これらが図の一次ソース (single source of truth) です。各 `.xml` は draw.io (diagrams.net) でそのまま開いて編集・エクスポートできます。`.drawio` にリネームしても中身は同一です。

## スライド構成図 (talk の物語順)

| XML | スライドでの役割 |
| --- | --- |
| `title.xml` | 表紙 (Unlocking Multi-Tenant LLM Inference — An LLMOps Approach for SaaS) |
| `problem.xml` | 課題: per-tenant behavior/data vs cost の緊張、tier ごとのコスト統制 |
| `lifecycle.xml` | LLMOps の per-tenant data flywheel (今日の focus = serve 側) |
| `confidentiality.xml` | per-tenant データの注入2方式 (LoRA / system prompt) とテナント境界の守り方 |
| `tier_arch.xml` | Tier-aware serving architecture (router → Bedrock / 自前 GPU プール) |
| `silo_vs_pool.xml` | GPU を分割するほど TTFT/TPOT/Goodput/cost が悪化 → pool 一択 |
| `approach.xml` | How LoRA serves many tenants (frozen base + per-tenant adapter + cache 階層) |
| `llmd_routing.xml` | LoRA-aware Router (hot-set 常駐を保ち swap を避ける) |
| `setup.xml` | 実験アーキテクチャ (Bedrock arm A / EKS 上の自前 arm B,B0 / 8x vLLM TP=1) |
| `measured.xml` | 測定条件まとめ (3 arms × 2 routings, sweep, Goodput SLO, Oregon 料金) |
| `perf_summary.xml` | 性能の統制論 (Bedrock pooled/siloed vs self-host のトレードオフ) |
| `decision_map.xml` | 自前が勝つ条件 (concurrency × context length, break-even は quota と独立) |
| `conclusion.xml` | Takeaways + LLMOps flywheel (collect→eval→tune→deploy→観測ループ) |

## 実測グラフについて

goodput / コスト損益分岐 / routing / long-context などの**実測グラフ**は構成図ではなく、
`../scripts/make_figures.py` が `../results/*.json` から再生成します:

```bash
cd ..
python scripts/make_figures.py   # -> figures/ に fig1..fig9 を生成
```

`fig9_cost_tier.png` は cost-vs-token-volume を Tier 別に示すグラフ (旧 cost_tier 表のグラフ版)。

## 補足

`gen_arch_figs.py` は初期の 3 図を生成した際のスクリプトで参考として残しています。現在の図は上記 XML が一次ソースです。
pptx 本体は容量が大きいためこのリポジトリには含めていません (XML から再構成可能)。
