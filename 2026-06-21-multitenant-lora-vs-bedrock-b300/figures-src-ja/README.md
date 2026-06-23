# figures-src-ja — 登壇スライド構成図 (日本語版) の draw.io ソース

LLMOps 登壇用スライド (日本語) で使う構成図の draw.io XML ソースです。
これらが図の一次ソース (single source of truth) で、draw.io (diagrams.net) でそのまま開いて編集・エクスポートできます。

| XML | スライドでの役割 |
| --- | --- |
| `title.xml` | 表紙 (マルチテナント LLM アプリケーションの最適化) |
| `problem.xml` | 課題: テナントの多様性 vs コスト統制 |
| `lifecycle.xml` | LLMOps flywheel (本日の focus = serve 側) |
| `confidentiality.xml` | テナント境界をまたぐもの (学習時 LoRA / 推論時 prompt・RAG) |
| `tier_arch.xml` | Tier-aware サービングアーキテクチャ |
| `silo_vs_pool.xml` | GPU を埋められるかがコスパを決める |
| `approach.xml` | LoRA で 1 つの base を多テナントに使い回す |
| `llmd_routing.xml` | LoRA-aware Router で swap を避ける (概念図) |
| `setup.xml` | 実験アーキテクチャ (arm A/B/B0) |
| `latency_basics_ja.xml` / `latency_basics_en.xml` | TTFT・TPOT・Goodput の定義 (日本語/英語) |
| `measured.xml` | 測定条件のまとめ |
| `perf_summary.xml` | 性能の統制論 (Pros/Cons) |
| `decision_map.xml` | 自前が勝つ条件 (break-even は quota と独立) |
| `conclusion.xml` | まとめ (好循環 + flywheel) |

### Phase 2: 本物の llm-d / GIE EndpointPicker 実験 (`gen_llmd_figs.py` で生成)

| XML | スライドでの役割 |
| --- | --- |
| `llmd_epp_arch.xml` | EPP standalone 構成 (client→Envoy→ext_proc→EPP→InferencePool→8 Pod) |
| `llmd_profiles.xml` | 3 profile (rr / affinity / full) の scorer 構成。profile 差し替えだけで条件切替 |
| `llmd_pitfalls.xml` | 実装のはまりポイント 4 件 (privileged / 並列登録 / metric 未populate / 計測経路) |
| `llmd_result.xml` | 計測結果の要点 (affinity 単独崩壊 vs full 最良 + 整合性 OK) |

`gen_llmd_figs.py` で上記 4 枚を再生成できます (`OUT=/path python3 gen_llmd_figs.py`)。

実測グラフ (fig1..fig9) は構成図ではなく `../scripts/make_figures.py` が `../results/*.json` から生成します。
Phase 2 の実測グラフは同スクリプトの `fig10_llmd_routing` (EPP 5 条件 goodput) と
`fig11_integrity` (1Pod8proc→8Pod の整合性) で、`../llm-d/results/*.json` から生成します。
pptx 本体は容量が大きいためこのリポジトリには含めていません (XML から再構成可能)。
