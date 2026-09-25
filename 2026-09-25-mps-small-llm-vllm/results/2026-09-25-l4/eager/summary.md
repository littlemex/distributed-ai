| model | concurrency | mode | output tok/s (mean ± sd) | vs single | median TTFT ms | median TPOT ms | GPU util % |
|---|---|---|---|---|---|---|---|
| Qwen2.5-0.5B-Instruct | 16 | single | 1048.9 ± 2.8 | 1.0 | 83.3 | 14.7 | 43.6 |
| Qwen2.5-0.5B-Instruct | 16 | timeslice | 1005.6 ± 2.7 | 0.96 | 114.2 | 14.99 | 99.1 |
| Qwen2.5-0.5B-Instruct | 16 | mps | 1024.0 ± 3.5 | 0.98 | 76.2 | 15.03 | 75.6 |
| Qwen2.5-0.5B-Instruct | 128 | single | 4516.0 ± 29.7 | 1.0 | 181.0 | 26.78 | 88.4 |
| Qwen2.5-0.5B-Instruct | 128 | timeslice | 3993.9 ± 11.9 | 0.88 | 328.7 | 29.54 | 98.8 |
| Qwen2.5-0.5B-Instruct | 128 | mps | 4569.3 ± 20.4 | 1.01 | 279.5 | 26.08 | 97.1 |
