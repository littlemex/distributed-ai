"""Optimizer step time for Llama 3 8B-shaped matrices sharded over one 8-GPU node.

Every 2D weight of Llama 3 8B (32 layers x wq, wk, wv, wo, w1, w2, w3; embeddings and norms are left
out because Muon is not applied to them) is created as an FP32 DTensor sharded on dim 0 over all
ranks, the way FSDP stores it. Gradients are random with the same layout. Then one optimizer is
stepped and timed:

  adamw       torch.optim.AdamW on the sharded DTensors (the usual FSDP optimizer, element-wise)
  muon-gather every rank gathers every full gradient and runs torch.optim.Muon on all of them
              (what Muon costs if you only have FSDP: Newton-Schulz needs whole matrices)
  distmuon    torchtitan's FlexShard DistMuon: each matrix is assigned whole to one rank (Owned),
              Newton-Schulz runs once per matrix in BF16, and redistribution overlaps compute per layer

Timing: --warmup steps, then --steps steps; each step is bracketed by a barrier and a CUDA sync and
the maximum over ranks is kept. Rank 0 appends one JSON line per optimizer to --out.

  torchrun --standalone --nproc_per_node=8 optimizer_step_bench.py --optimizers adamw,distmuon --out r.jsonl
"""
import argparse
import json
import os
import statistics
import time

import torch
import torch.distributed as dist
from torch.distributed.device_mesh import init_device_mesh
from torch.distributed.tensor import Shard, distribute_tensor

LLAMA3_8B = {"dim": 4096, "kv_dim": 1024, "ffn": 14336, "layers": 32}


def shapes(layers):
    d, kv, f = LLAMA3_8B["dim"], LLAMA3_8B["kv_dim"], LLAMA3_8B["ffn"]
    per = {"attention.wq": (d, d), "attention.wk": (kv, d), "attention.wv": (kv, d), "attention.wo": (d, d),
           "feed_forward.w1": (f, d), "feed_forward.w2": (d, f), "feed_forward.w3": (f, d)}
    return [(f"layers.{i}.{n}", s) for i in range(layers) for n, s in per.items()]


def make_params(mesh, layers, seed):
    g = torch.Generator(device="cuda").manual_seed(seed)
    out = []
    for fqn, (r, c) in shapes(layers):
        full = torch.randn(r, c, device="cuda", generator=g) * 0.02
        p = torch.nn.Parameter(distribute_tensor(full, mesh, [Shard(0)]))
        p.grad = distribute_tensor(torch.randn(r, c, device="cuda", generator=g) * 1e-3, mesh, [Shard(0)])
        out.append((fqn, p))
        del full
    return out


def build(name, params, layers):
    if name == "adamw":
        return torch.optim.AdamW([p for _, p in params], lr=3e-4, foreach=True), None
    if name == "muon-gather":
        full = []
        for _, p in params:
            q = torch.nn.Parameter(p.full_tensor())
            q.grad = p.grad.full_tensor()
            full.append(q)
        return torch.optim.Muon(full, lr=1e-3, weight_decay=0.1, momentum=0.95), full
    if name == "distmuon":
        from torchtitan.distributed.flex_shard import BucketConfig, ComputeLayout, Owned
        from torchtitan.distributed.flex_shard.dist_muon import DistMuon
        layout = {fqn: ComputeLayout(shardings_by_mesh_axis={"dp_shard": Owned()}, compute_dtype=torch.bfloat16)
                  for fqn, _ in params}
        buckets = [BucketConfig(patterns=(f"layers.{i}.*",), name=f"layers.{i}") for i in range(layers)]
        group = {"params": [p for _, p in params], "param_names": [f for f, _ in params]}
        return DistMuon([group], compute_sharding_by_fqn=layout, bucket_configs=buckets,
                        lr=1e-3, weight_decay=0.1, momentum=0.95), None
    raise ValueError(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--optimizers", default="adamw,muon-gather,distmuon")
    ap.add_argument("--layers", type=int, default=LLAMA3_8B["layers"])
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--steps", type=int, default=10)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    dist.init_process_group("nccl")
    rank, world = dist.get_rank(), dist.get_world_size()
    torch.cuda.set_device(int(os.environ["LOCAL_RANK"]))
    mesh = init_device_mesh("cuda", (world,), mesh_dim_names=("dp_shard",))
    for name in a.optimizers.split(","):
        params = make_params(mesh, a.layers, seed=1234)
        torch.cuda.reset_peak_memory_stats()
        rec = {"optimizer": name, "world": world, "layers": a.layers,
               "params_b": sum(r * c for _, (r, c) in shapes(a.layers)) / 1e9}
        try:
            opt, _keep = build(name, params, a.layers)
            times = []
            for i in range(a.warmup + a.steps):
                dist.barrier(); torch.cuda.synchronize(); t0 = time.perf_counter()
                opt.step()
                torch.cuda.synchronize(); dt = torch.tensor(time.perf_counter() - t0, device="cuda")
                dist.all_reduce(dt, op=dist.ReduceOp.MAX)
                if i >= a.warmup:
                    times.append(dt.item() * 1000)
            peak = torch.tensor(torch.cuda.max_memory_allocated() / 2**30, device="cuda")
            dist.all_reduce(peak, op=dist.ReduceOp.MAX)
            rec.update({"ok": True, "step_ms_median": round(statistics.median(times), 2),
                        "step_ms_min": round(min(times), 2), "peak_mem_gib": round(peak.item(), 2), "steps_ms": times})
        except Exception as e:  # record and continue with the next optimizer
            rec.update({"ok": False, "error": repr(e)[:2000]})
        if rank == 0:
            print(json.dumps({k: v for k, v in rec.items() if k != "steps_ms"}), flush=True)
            with open(a.out, "a") as f:
                f.write(json.dumps(rec) + "\n")
        del params
        opt = _keep = None
        torch.cuda.empty_cache(); dist.barrier()
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
