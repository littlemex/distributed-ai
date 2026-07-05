# Benchmark Methodology (throughput / cost / accuracy)

This document defines the measurement conditions, procedure, and reporting format
so that a third party can **extrapolate these numbers to their own workload**
("if we reserve Graviton / g6e, how much can we process, and what will it cost?").

---

## 0. Design principles

1. **Throughput is not a single number.** It is a function of batch size, input
   length, concurrency, quantization, and thread count. So we report a **table
   with conditions made explicit**, not one headline value.
2. **Make it extrapolatable.** Alongside raw throughput (sent/s, tok/s) we always
   report hardware conditions (instance type, vCPU/GPU count, $/hr), workload
   conditions (input length, output length, batch), and derived metrics
   ($/1M sentences, $/1M tokens) so readers can plug in their own
   (count x mean length) to get a daily cost.
3. **Strict measurement window.** Model load, warmup, and tokenization are
   excluded from the timed region; only the pure inference wall-clock is measured.
4. **Reproducible.** Model repo, revision, runtime version, quantization, and all
   flags are recorded.

---

## A. Embedding (Graviton CPU)

### Metrics
- Primary: **sentences/sec** (encode a fixed corpus, divide by wall-clock).
- Derived: **USD / 1M sentences** = hourly_usd / (sent_per_sec * 3600) * 1e6.
  For token-basis comparison with APIs: **tokens/sec = sent/sec x input_len**,
  and **USD / 1M input tokens** = hourly_usd / (tok_per_s * 3600) * 1e6.
- Auxiliary: p50 / p99 batch latency, embedding dimension.
- Accuracy: nDCG@10 / Recall@10 on a small JA retrieval set (see section C).

### Definition of "sentence"
1 "sentence" = 1 request = 1 input text. Its length is controlled by the
**input token length** parameter (32 / 128 / 512 tokens). Embedding has no output
tokens (one forward pass -> one vector), so the billable/throughput unit is
**input tokens**.

### Swept axes
| Axis | Patterns | Why |
|---|---|---|
| input length (tokens) | 32 / 128 / 512 | short QA to long chunks; longer = fewer sent/s |
| batch size | 1 / 8 / 32 / 64 | bigger batch = higher throughput, higher latency |
| threads | all physical vCPUs (e.g. c7g.8xl=32) | ARM parallel efficiency |
| quantization | fp32 / int8 (dynamic) | int8 ~1.5-3x on CPU |
| runtime | ONNX Runtime (CPUExecutionProvider) | stable + easy int8 on Graviton |

### Procedure
1. Model download + ONNX session build -> **excluded**
2. Warmup: first batch x2 -> **excluded**
3. Timed: encode all N texts in batches; sent_per_sec = N/dt
4. Each (model x quant x input_len x batch) measured 3x, **median** reported.
5. Prefixes applied per model (ruri="検索文書: ", e5="passage: ", etc.).

---

## B. Summarization LLM (GPU: g6e / p4d)

### Metrics
- Primary: **total tokens/sec (input+output, continuous batching)** via
  `vllm bench throughput` (offline = saturated throughput).
- Derived: **USD / 1M tokens** = gpu_hourly_usd / (tok_per_s * 3600) * 1e6.
  g6e.12xlarge is L40S x4; we run 1 model per GPU so we use the **per-GPU price
  (g6e.xlarge = $1.861/hr)** for the conversion.
- Auxiliary: req/s; daily throughput (req/day) via the formula below.

### Token control (important)
We use `--dataset-name random --random-range-ratio 0` so input/output token
counts are **exact** (not character-based). Earlier char-based generation was a
methodology bug and is fixed here.

### Swept axes
| Axis | Patterns |
|---|---|
| input length | 256 / 1024 / 4096 tokens |
| output length | 128 / 512 tokens |
| quantization | BF16 / FP8 (L40S) / AWQ,INT8 (A100) |
| batching | continuous batching, --num-prompts 500, saturated |
| GPU allocation | 1 model = 1 GPU (TP=1); large models also TP=N |

### Daily throughput extrapolation
```
daily_tokens = tok_per_s * 86400
tokens_per_request = mean_input_len + output_len
daily_requests = (tok_per_s * 86400) / (mean_input_len + output_len)
```

---

## C. Accuracy (reference-grade sanity, NOT full benchmarks)

- **Embedding**: a small hand-written JA query->gold-doc set with distractors;
  nDCG@10 and Recall@10. Purpose: confirm JA embedding is not broken and that the
  relative ordering matches published JMTEB. This is intentionally small; a full
  JMTEB run is out of scope.
- **Translation**: a small fixed JA<->EN parallel set; chrF via sacrebleu.
  Purpose: confirm the LLM's JA is coherent (not garbled) and get a ballpark
  quality number. NOT a full WMT eval.

---

## D. Reporting format (results/*.jsonl)

Each run appends one JSON Lines record. Throughput records carry hardware,
workload, throughput, and derived-cost fields; accuracy records carry the task,
query count, and scores. Tables in the README always print the hardware condition
and unit price in the header, with a note that readers should extrapolate via the
formulas above for their own workload.
