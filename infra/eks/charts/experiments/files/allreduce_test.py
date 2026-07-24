# Minimal torch-neuronx all-reduce DDP test. Each rank all-reduces a ones tensor and
# asserts the sum equals world_size, proving every rank (across both nodes) joined the
# collective. The Neuron DLC ships no ready multi-node sample, so this is embedded in the
# chart (mounted from a ConfigMap) for a self-contained, network-independent check with a
# known expected output. NUM_STEPS is overridable via env.
import os
import time

import torch
import torch.distributed as dist
import torch_xla.core.xla_model as xm
import torch_xla.distributed.xla_backend  # noqa: F401  (registers the 'xla' backend)


def rprint(txt):
    rank = os.environ.get("RANK", os.environ.get("LOCAL_RANK", "unk"))
    if int(rank) == 0:
        print(f"[rank {rank}] {txt}", flush=True)


dist.init_process_group("xla")
xm.rendezvous("first")

device = xm.xla_device()
world_size = int(os.environ.get("WORLD_SIZE", 0))
num_steps = int(os.environ.get("NUM_STEPS", "20"))

t0 = time.time()
for c in range(num_steps):
    xones = torch.ones((2, 3)).to(device)
    result = xm.all_reduce("sum", xones)
    xm.mark_step()
    result_cpu = result.cpu()
    expected = torch.ones((2, 3)) * world_size
    assert torch.all(result_cpu == expected), f"ERROR: {result_cpu} != {expected}"
    rprint(f"step {c}: result={result_cpu[0][0].item()} (expected {world_size})")

rprint(f"ALL {num_steps} STEPS OK. world_size={world_size} elapsed={time.time() - t0:.2f}s")
xm.rendezvous("final")
rprint("DONE - SUCCESS")
