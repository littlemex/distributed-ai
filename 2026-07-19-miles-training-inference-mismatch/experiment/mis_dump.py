"""Per-token logprob dump, wrapping the upstream mismatch helper.

WHY. The recorded metrics are aggregates (mean mis_kl over a step), so they cannot say
*where* in a sequence the train/rollout gap arises. The position profile is what
distinguishes the two readings of the O(T^2) claim in arXiv:2602.01826 Thm 3.1: a gap
that is flat in position accumulates like T, one that grows with position like T^2.
Attention is causal, so the profile measured on an 8192-token run already answers the
question for longer runs -- no max_len sweep, and none of the confounds a sweep brings.

HOW IT HOOKS IN. `--custom-tis-function-path` points at
`compute_mis_weights_with_cp_dumping` below, which dumps and then delegates to the
upstream function unchanged. Two details of the upstream code decide the design:

  1. CP. `compute_mis_weights_with_cp` receives log probs that are *this CP rank's
     slice* ("log probs from training backend on this cp rank", mis.py docstring) and
     all-gathers them internally. Megatron splits a sequence into 2*CP zigzag chunks
     (rank r holds chunk r and chunk 2*CP-1-r) to balance causal attention, so a rank's
     slice is neither contiguous nor positionally labelled. Dumping the raw arguments
     under CP>1 would silently produce position-scrambled data. This module therefore
     dumps only under CP==1, where the argument *is* the full sequence, and refuses
     loudly otherwise. The alternative -- reimplementing the gather here -- would
     duplicate upstream logic that is the very thing under measurement.

  2. use_tis. The `if not args.use_tis: return None, ...` early return sits inside
     `compute_mis_weights` (mis.py:209), i.e. *below* this wrapper. So the wrapper runs
     for baseline cells too, and a bf16 control group does get dumped. That matters
     because the bf16 arm is the comparison the fp8 slope is measured against.

FORMAT. Compressed npz of float32 arrays, written to a temp path and renamed, so a
killed job cannot leave a half-written file for the analysis to trip over. JSON text was
~57MB per call per rank and ran inside the training step; npz is ~12MB before
compression. r is order 1e-3, so float32 is kept and float16 is not an option.

ENV:
  MIS_DUMP_DIR    destination directory; dumping is off when unset
  MIS_DUMP_TAG    filename prefix (default "run")
  MIS_DUMP_EVERY  dump every Nth call (default 1). Raising it thins the write, which is
                  synchronous with training, but a stride larger than the run's call count
                  writes nothing and warns about nothing -- so the default is 1
"""

import os
import time

import numpy as np
import torch

from examples.train_infer_mismatch_helper.mis import (
    compute_mis_weights_with_cp as _upstream_compute_mis_weights_with_cp,
)

_CALL_COUNTER = {"n": 0}
# Distinguishes re-runs that share MIS_DUMP_DIR/TAG. Without it, a repeat run reopens
# the same filenames with mode "w" and destroys the earlier dump.
_RUN_ID = os.environ.get("RAY_JOB_ID") or os.environ.get("MIS_DUMP_RUN_ID") or str(int(time.time()))
_CP_WARNED = {"done": False}


def _dump_dir():
    d = os.environ.get("MIS_DUMP_DIR", "").strip()
    return d or None


def _rank():
    try:
        import torch.distributed as dist

        if dist.is_available() and dist.is_initialized():
            return dist.get_rank()
    except Exception:
        pass
    return int(os.environ.get("RANK", "0"))


def _cp_size(args):
    """CP size, or None when it cannot be determined.

    None means "do not dump". Returning 1 on an exception would turn "unknown" into
    "safe", which is the precise confusion this guard exists to prevent: a CP=2 run whose
    mpu lookup failed would be dumped as if its tensors were whole sequences. args
    carries context_parallel_size independently of Megatron's init state, so the two are
    cross-checked and any disagreement also yields None.
    """
    cfg = getattr(args, "context_parallel_size", None)
    try:
        from megatron.core import mpu

        live = int(mpu.get_context_parallel_world_size())
    except Exception:
        live = None
    if cfg is not None and live is not None and int(cfg) != live:
        return None
    if live is not None:
        return live
    return int(cfg) if cfg is not None else None


def _is_tp_rank_zero():
    """True only on TP rank 0.

    The loss runs on every TP rank of the last PP stage, and train/rollout logprobs are
    identical across those ranks. Dumping from all of them would make the analysis count
    each sequence TP times: n inflates, and the sequence-level bootstrap CI narrows by
    roughly sqrt(TP), which is exactly the statistic the accumulation verdict rests on.
    Fails closed, since a duplicate is worse than a gap here.
    """
    try:
        from megatron.core import mpu

        return mpu.get_tensor_model_parallel_rank() == 0
    except Exception:
        return False


def _write_dump(d, tag, rank, call_n, train_lps, rollout_lps, masks,
                total_lengths, response_lengths):
    arrays = {}
    for i, (tr, ro, lm) in enumerate(zip(train_lps, rollout_lps, masks)):
        arrays[f"train_{i}"] = tr.detach().float().cpu().numpy().astype(np.float32)
        arrays[f"rollout_{i}"] = ro.detach().float().cpu().numpy().astype(np.float32)
        arrays[f"mask_{i}"] = lm.detach().to(torch.uint8).cpu().numpy()
    arrays["n_seq"] = np.asarray([len(train_lps)])
    # Absolute position needs the prompt offset: a response token at index t attends to
    # prompt_len + t cached entries, and prompt-length differences between arms would
    # otherwise be read as a position effect.
    arrays["total_lengths"] = np.asarray([int(x) for x in total_lengths])
    arrays["response_lengths"] = np.asarray([int(x) for x in response_lengths])
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"{tag}_{_RUN_ID}_rank{rank}_call{call_n}.npz")
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        np.savez_compressed(f, **arrays)
    os.replace(tmp, path)


def compute_mis_weights_with_cp_dumping(
    args, *, pg_loss, train_log_probs, rollout_log_probs, loss_masks,
    total_lengths, response_lengths, **kwargs,
):
    d = _dump_dir()
    if d:
        try:
            _CALL_COUNTER["n"] += 1
            call_n = _CALL_COUNTER["n"]
            cp = _cp_size(args)
            if cp is None or cp != 1:
                # Loud once, then quiet: these are design limits, not transient errors,
                # and neither must be mistaken for "the dump was empty by chance".
                # "CP>1" and "CP unknown" are distinct findings for an audit, so they
                # get distinct messages.
                if not _CP_WARNED["done"]:
                    if cp is None:
                        print(
                            "[mis_dump] DUMP DISABLED: context_parallel_size could not "
                            "be determined (args and megatron.core.mpu disagree or "
                            "neither is readable). Refusing to dump rather than assume "
                            "CP=1.",
                            flush=True,
                        )
                    else:
                        print(
                            f"[mis_dump] DUMP DISABLED: context_parallel_size={cp}. The "
                            "arguments are this rank's zigzag CP shards, so a per-token "
                            "dump would be position-scrambled. Run the dump cells with "
                            "CP=1.",
                            flush=True,
                        )
                    _CP_WARNED["done"] = True
            elif not _is_tp_rank_zero():
                pass  # duplicate of TP rank 0; see _is_tp_rank_zero
            else:
                # Default 1, not 4. With a stride of 4 a run making fewer than 4 calls
                # writes nothing at all and says nothing about it, so "the dump produced no
                # data" and "the dump never fired" look identical from the outside -- the
                # exact confusion this instrumentation exists to prevent. Every spec sets
                # MIS_DUMP_EVERY=1 explicitly, so the safe value is also the used one.
                every = int(os.environ.get("MIS_DUMP_EVERY", "1"))
                if every > 0 and call_n % every == 0:
                    _write_dump(
                        d, os.environ.get("MIS_DUMP_TAG", "run"), _rank(), call_n,
                        train_log_probs, rollout_log_probs, loss_masks,
                        total_lengths, response_lengths,
                    )
        except Exception as e:
            # Never take the training job down for instrumentation. But do say so: a
            # silent failure here looks identical to "no data was produced".
            print(f"[mis_dump] WARNING dump failed: {type(e).__name__}: {e}", flush=True)

    return _upstream_compute_mis_weights_with_cp(
        args, pg_loss=pg_loss, train_log_probs=train_log_probs,
        rollout_log_probs=rollout_log_probs, loss_masks=loss_masks,
        total_lengths=total_lengths, response_lengths=response_lengths, **kwargs,
    )
