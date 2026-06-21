# figures-src — 構成図の draw.io ソース

登壇スライド / ブログで使う構成図の **draw.io XML ソース** です。これらが図の一次ソース (single source of truth) です。各 `.xml` は draw.io (diagrams.net) でそのまま開いて編集・エクスポートできます。

## ファイル一覧

| XML | 図の内容 |
| --- | --- |
| `problem.xml` | マルチテナントの緊張関係 (per-tenant behavior vs low cost) |
| `lifecycle.xml` | per-tenant LLMOps ライフサイクル (collect → mask → LoRA → deploy → serve) |
| `confidentiality.xml` | LoRA vs system prompt のデータ境界 (どこで生データが越えるか) |
| `cost_tier.xml` | コストモデル × SaaS Tier (表形式。グラフ版は scripts の fig9) |
| `tier_arch.xml` | Tier-aware サービングアーキテクチャ (router が Bedrock / 自前 GPU へ振り分け) |
| `silo_vs_pool.xml` | サイロ (~8% util) vs プール (~90% util) |
| `approach.xml` | テナント識別子の運び方 A (system prompt) / B (LoRA) |
| `lora_explained.xml` | Multi-LoRA の仕組み (frozen base + unmerged 加算) と数式 |
| `setup.xml` | 3 アーム実験 (A Bedrock / B self-host LoRA / B0 self-host prompt) |
| `topology.xml` | 自前 GPU プール (31B fp8 × TP=1 × 8 replica) |
| `llmd_routing.xml` | llm-d affinity routing + vLLM キャッシュ階層 (hot-set / CPU pool / disk) |
| `decision_map.xml` | 自前ホスティングが勝る条件 (2 軸マップ) |
| `conclusion.xml` | 結論 (Bedrock vs self-host の使い分け + LLMOps 成長フレーム) |
| `title.xml` | 表紙 |

## 実測グラフについて

goodput / コスト損益分岐 / routing / long-context などの**実測グラフ**は構成図ではなく、
`../scripts/make_figures.py` が `../results/*.json` から再生成します:

```bash
cd ..
python scripts/make_figures.py   # -> figures/ に fig1..fig9 を生成
```

`fig9_cost_tier.png` は cost_tier.xml (表) のグラフ版 (コスト対トークン量・Tier 別) です。

## 補足

`gen_arch_figs.py` は初期の 3 図 (approach / opsloop / topology) を生成した際のスクリプトで、
参考として残しています。現在の図は上記 XML が一次ソースであり、このスクリプトの出力ではありません。
