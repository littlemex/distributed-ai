# scripts / configs — multitenant-serving-b300

`docs/DESIGN.md` の実装成果物をファイル化したもの。**まだ GPU/クラスタでは未実行**(別実験が GPU 使用中)。
設計の根拠・数値・出典は `docs/DESIGN.md` を、生の調査データは `docs/design-research-raw.json` を参照。

## 構成

```
scripts/
  mint_dummy_lora_adapters.py  ダミー rank-16 LoRA を訓練なしで N 枚生成 (ハードリンクでディスク節約)
  gen_zipf_lora_split.py       inference-perf 用 Zipf traffic split (lora_split_{n}.yaml) 生成
  gen_bedrock_dataset.py       Bedrock 用 per-tenant distinct system prompt の shareGPT JSONL 生成
  bedrock_load_driver.py       Bedrock (bedrock-mantle, openai SDK) 負荷ドライバ + 503 計測
  bench_lora_swap_cost.py      swap-in 1回の絶対コスト (hot/CPU->GPU/disk->GPU) マイクロベンチ
  tenant_affinity_proxy.py     llm-d 抜きの consistent-hash affinity proxy (round-robin と比較)
  monitor_lora_swap.py         vllm:lora_requests_info から swap-in/s を観測
  register_adapters.sh         起動済み vLLM に runtime API で adapter を並列登録
  serve_vllm_27b.sh            Gemma 3 27B fp8 + multi-LoRA 起動 (1 GPU TP=1, 8 個並べる)
  serve_vllm_4b.sh             Gemma 3 4B fp8 + multi-LoRA 起動
configs/
  vllm-gemma3-27b-1000tenants.yaml   inference-perf Approach B (大)
  vllm-gemma3-4b-1000tenants.yaml    inference-perf Approach B (小)
  bedrock-gemma4-31b-1000tenants.yaml inference-perf Approach A (大)
  bedrock-gemma4-e2b-1000tenants.yaml inference-perf Approach A (小)
```

## 実行順序 (GPU が空いたら)

1. **データ生成 (GPU 不要、ローカル可)**
   ```bash
   python scripts/gen_zipf_lora_split.py                       # lora_split_{100,500,1000}.yaml
   python scripts/gen_bedrock_dataset.py                       # bedrock_dataset_{size}_{n}tenants.jsonl
   # lora_split_1000.yaml の中身を configs/vllm-*.yaml の load.lora_traffic_split に展開
   ```

2. **ダミー adapter 生成 (transformers/peft が要る。GPU 不要)**
   ```bash
   python scripts/mint_dummy_lora_adapters.py --model google/gemma-3-27b-it --n 1000 --out-dir /adapters/gemma3-27b
   python scripts/mint_dummy_lora_adapters.py --model google/gemma-3-4b-it  --n 1000 --out-dir /adapters/gemma3-4b
   ```

3. **Phase 0 smoke (GPU 1 枚)** — DESIGN.md §10。特に **F2 挙動確認**(max_loras 超過で
   RuntimeError か defer か)と **swap-in マイクロベンチ**を最初にやる。
   ```bash
   CUDA_VISIBLE_DEVICES=0 PORT=8000 MAX_LORAS=16 MAX_CPU_LORAS=1000 ./scripts/serve_vllm_27b.sh &
   ./scripts/register_adapters.sh /adapters/gemma3-27b 64 8000
   python scripts/bench_lora_swap_cost.py --port 8000 --max-loras 16 --n-adapters 64
   ```

4. **Phase 1 計測** — 8 replica 起動 → 1000 adapter 登録 → inference-perf で A/B sweep。
5. **Phase 1.5 軽量 affinity** — `ROUTING=roundrobin` と `ROUTING=affinity` で
   `tenant_affinity_proxy.py` を前段に置いて TTFT/swap 差を測る。差が小さければ llm-d 不要。
6. **Phase 2 llm-d** — Phase 1.5 で効果が大きいときのみ。

## 注意 (DESIGN.md より)

- **F2**: 1スケジューラバッチ内の distinct adapter 数 > `--max-loras` で即 RuntimeError。
  高同時実行ほど危険。max_loras はバッチ内同時 distinct ピーク以上に。
- **F1**: Bedrock prompt caching は Gemma 非対応 → Approach A は毎回フル input price。
- **未確認**: bedrock-mantle が Bearer token か SigV4 か(`bedrock_load_driver.py` で代替可)、
  inference-perf の shareGPT system field マッピング、X-Tenant-ID ヘッダ送信可否。
- パス (`/adapters`, `/data`) は実行環境に合わせて調整する。
