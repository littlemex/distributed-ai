| target | recipe | rc | saves | blocking_s | complete_s | steps_6_20_s | step_s | gb |
|---|---|---|---|---|---|---|---|---|
| fsx | ckpt_dcp_async | rc=0 | 4 | 5.45 | 34.24 | 73.7 | 0.88 | 96.38 |
| fsx | ckpt_dcp_async_pinned | rc=0 | 4 | 0.37 | 29.53 | 64.9 | 0.89 | 96.38 |
| fsx | ckpt_dcp_sync | rc=0 | 4 | 24.14 | 24.16 | 60.7 | 0.88 | 96.38 |
| fsx | ckpt_torch_checkpointing | rc=1 | 2 | 7.19 | None | None | 0.89 | None |
| fsx | ckpt_torch_checkpointing_buffered | rc=0 | 5 | 3.98 | 51.84 | 55.6 | 0.88 | 96.37 |
| local | ckpt_dcp_async | rc=0 | 4 | 5.5 | 18.1 | 39.5 | 0.88 | 96.38 |
| local | ckpt_dcp_async_pinned | rc=0 | 4 | 0.18 | 15.26 | 36.2 | 0.9 | 96.38 |
| local | ckpt_dcp_sync | rc=0 | 4 | 10.21 | 10.24 | 32.9 | 0.88 | 96.38 |
| local | ckpt_torch_checkpointing | rc=1 | 2 | 6.24 | None | None | 0.89 | None |
| local | ckpt_torch_checkpointing_buffered | rc=0 | 5 | 3.94 | 22.24 | 25.8 | 0.88 | 96.37 |
