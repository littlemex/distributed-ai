| model | concurrency | mode | output tok/s (mean ± sd) | vs single | median TTFT ms | median TPOT ms | GPU util % |
|---|---|---|---|---|---|---|---|
| Qwen2.5-0.5B-Instruct | 16 | single | 2351.7 ± 3.5 | 1.0 | 86.4 | 6.17 | 99.1 |
| Qwen2.5-0.5B-Instruct | 16 | timeslice | 1249.4 ± 2.8 | 0.53 | 159.3 | 11.85 | 100.0 |
| Qwen2.5-0.5B-Instruct | 16 | mps | 1405.6 ± 0.9 | 0.6 | 148.4 | 10.48 | 99.9 |
| Qwen2.5-0.5B-Instruct | 128 | single | 5294.5 ± 38.0 | 1.0 | 172.6 | 22.91 | 98.4 |
| Qwen2.5-0.5B-Instruct | 128 | timeslice | 4094.7 ± 29.6 | 0.77 | 324.0 | 28.8 | 98.8 |
| Qwen2.5-0.5B-Instruct | 128 | mps | 4680.9 ± 19.7 | 0.88 | 295.0 | 25.11 | 98.6 |
| Qwen2.5-1.5B-Instruct | 16 | single | 849.9 ± 2.6 | 1.0 | 299.6 | 16.55 | 99.3 |
| Qwen2.5-1.5B-Instruct | 16 | timeslice | 456.3 ± 1.4 | 0.54 | 529.7 | 32.03 | 99.9 |
| Qwen2.5-1.5B-Instruct | 16 | mps | 525.9 ± 0.8 | 0.62 | 498.6 | 27.52 | 99.9 |
| Qwen2.5-1.5B-Instruct | 128 | single | 2045.0 ± 17.9 | 1.0 | 469.3 | 59.08 | 99.4 |
| Qwen2.5-1.5B-Instruct | 128 | timeslice | 1583.1 ± 6.0 | 0.77 | 907.7 | 73.59 | 99.5 |
| Qwen2.5-1.5B-Instruct | 128 | mps | 1770.7 ± 2.9 | 0.87 | 859.2 | 65.51 | 99.5 |
| Qwen2.5-3B-Instruct | 16 | single | 448.9 ± 1.0 | 1.0 | 604.0 | 31.23 | 99.6 |
| Qwen2.5-3B-Instruct | 16 | timeslice | 237.8 ± 0.5 | 0.53 | 1033.7 | 61.7 | 100.0 |
| Qwen2.5-3B-Instruct | 16 | mps | 269.4 ± 0.4 | 0.6 | 980.2 | 54.1 | 99.9 |
| Qwen2.5-3B-Instruct | 128 | single | 1131.8 ± 0.5 | 1.0 | 872.2 | 106.75 | 99.7 |
| Qwen2.5-3B-Instruct | 128 | timeslice | 884.1 ± 2.6 | 0.78 | 1669.2 | 131.67 | 99.7 |
| Qwen2.5-3B-Instruct | 128 | mps | 984.7 ± 6.1 | 0.87 | 1549.8 | 117.67 | 99.7 |
