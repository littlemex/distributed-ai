#!/usr/bin/env python3
"""Qwen3-30B-A3B (MoE) の反復崩壊が miles の GRPO ループの外で再現するかを測る。

背景と、このスクリプトが答える問い
-----------------------------------
miles の GRPO rollout で 30B MoE を回すと、optimizer step を 1 回も踏む前から
`rollout/repetition_frac` が 0.633 (dense は 0.0)、reward 0、`mis_ppl_ratio` 1.78
になる。4 つの仮説 (応答長上限 / weight sync / 温度 / checkpoint 破損) は
すべて実測で否定済み (h200_results/P2R_30B_INVALID.md)。

`repetition_frac` は **SGLang が生成したテキスト**に対して計算される。したがって
miles の訓練ループを一切通さず、SGLang 単体で同じ checkpoint・同じプロンプト・
同じ sampling params で生成させれば、原因が rollout 側 (推論スタック) にあるのか
miles 側 (プロンプト組み立て・chat template・データ経路) にあるのかを切り分けられる。

セル設計 (各セルが単独で動かす軸を 1 つに絞る)
-----------------------------------------------
  A_repro   : SGLang, TP4/EP2, triton backend, miles と同一 sampling → miles を再現するか
  B_tp1     : TP=1, EP=1 に落とす            → sharding 軸 (TP/EP) を単独で動かす
  C_backend : moe_runner_backend を既定(auto)に → backend 軸を単独で動かす
  D_sampling: 推奨 sampling (top_p .95/top_k 20) → sampling 軸を単独で動かす
  E_dense   : 同じ経路で Qwen3-8B (dense)       → MoE 固有かの対照群
  F_hf      : HuggingFace transformers で生成   → engine 実装軸 (SGLang 依存かどうか)

事前宣言 (事後解釈を防ぐため、走らせる前に何が言えるかを決めておく)
--------------------------------------------------------------------
  A で反復が再現 → 原因は miles の訓練ループの外。推論経路 or モデル自体。
  A で再現しない → 原因は miles 側 (プロンプト/chat template/データ)。以降のセルは無意味になる。
  A 再現 かつ B で消える → sharding (TP/EP) 依存。SGLang PR #28244 型の
                            「重みレイアウトと kernel の不整合」仮説を支持。
  A 再現 かつ C で消える → moe_runner_backend triton が原因。
  A 再現 かつ D で消える → sampling params が原因 (top_p=1.0/top_k=-1 が MoE で致命的)。
                            ただし dense も同じ sampling なので「MoE 固有の脆弱性」という
                            性格になる。E との対比が効く。
  A 再現 かつ B/C/D すべてで消えない → モデル自体が反復する。SGLang 非依存かは F で決まる。
  F でも反復 → SGLang 実装ではなく Qwen3-30B-A3B というモデルの性質。

測定は miles の has_repetition を逐語移植した repetition.py で行う。生成テキストも
必ず全文保存する。圧縮率という間接指標だけを信用せず、後から目で確認できるようにする。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from repetition import has_repetition, repetition_diagnostics  # noqa: E402

# miles の実効設定。arguments.py の argparse 既定値と、30B run の実際の CLI から取った。
#   --rollout-temperature 1.0      (arguments.py:353 default=1.0、30B run も明示 1.0)
#   --rollout-top-p       1.0      (arguments.py:357 default=1.0、30B run は未指定 → 既定)
#   --rollout-top-k       -1       (arguments.py:360 default=-1、30B run は未指定 → 既定)
#   --rollout-stop        None     (arguments.py:403 default=None)
#   --rollout-stop-token-ids None  (arguments.py:414 default=None)
# 注意: Qwen3-30B-A3B の generation_config.json の推奨は temperature 0.6 / top_p 0.95 /
# top_k 20 だが、miles はこれを読まない。ただし **4B/8B dense も同じ推奨値を持ち、
# 同じく miles に無視されている**ので、「推奨値から外れている」ことは 30B 固有ではない。
MILES_SAMPLING = dict(temperature=1.0, top_p=1.0, top_k=-1)
QWEN_RECOMMENDED = dict(temperature=0.6, top_p=0.95, top_k=20)

# miles が DAPO-Math の prompt をどう組むか: jsonl の "prompt" は
# [{"role": "user", "content": "..."}] という messages 形式で、
# --apply-chat-template により tokenizer.apply_chat_template に通される。
DATA_PATH = "/fsx/data/dapo-math-17k/dapo-math-17k.jsonl"


def load_prompts(tokenizer, n: int) -> list[dict]:
    """miles と同じ手順でプロンプト文字列を組む。

    再現性のため先頭から順に取る。miles は --rollout-shuffle でシャッフルするので
    「同じ問題」ではないが、DAPO-Math は同種の数学問題の集合なので、
    反復崩壊が 63% の応答で起きるならどの部分集合でも観測できる。
    プロンプト依存性が疑われる場合は --offset で別の窓を見る。
    """
    out = []
    with open(DATA_PATH) as f:
        for i, line in enumerate(f):
            if len(out) >= n:
                break
            rec = json.loads(line)
            messages = rec["prompt"]
            text = tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True
            )
            out.append({"index": i, "text": text, "label": rec.get("label")})
    return out


def summarize(cell: str, results: list[dict], meta: dict, out_dir: Path) -> dict:
    """miles の repetition_frac と直接比較できる形に集計する。"""
    n = len(results)
    rep_flags = [r["diag"]["has_repetition"] for r in results]
    lens = [r["diag"]["n_chars"] for r in results]
    ratios = [r["diag"]["tail_compression_ratio"] for r in results]
    runs = [r["diag"]["longest_repeat_run"]["repeats"] for r in results]
    n_rep = sum(rep_flags)
    summary = {
        "cell": cell,
        "meta": meta,
        "n_samples": n,
        # miles の rollout/repetition_frac とまったく同じ定義・同じ集計
        "repetition_frac": (n_rep / n) if n else 0.0,
        "n_repetition": n_rep,
        "chars_mean": (sum(lens) / n) if n else 0.0,
        "chars_max": max(lens) if lens else 0,
        "over_10k_frac": (sum(1 for L in lens if L > 10000) / n) if n else 0.0,
        "tail_ratio_mean": (sum(ratios) / n) if n else 0.0,
        "tail_ratio_max": max(ratios) if ratios else 0.0,
        # 圧縮率とは独立な直接証拠: 同一文字列が何回連続反復したか
        "longest_repeat_repeats_max": max(runs) if runs else 0,
        "n_with_repeat_run_ge_5": sum(1 for k in runs if k >= 5),
        "finish_reasons": _count(r.get("finish_reason") for r in results),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{cell}.summary.json").write_text(json.dumps(summary, indent=2))
    # 生成テキスト全文。圧縮率という間接指標を信用せず後から目視できるようにする。
    with open(out_dir / f"{cell}.samples.jsonl", "w") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return summary


def _count(it) -> dict:
    d: dict[str, int] = {}
    for x in it:
        k = str(x)
        d[k] = d.get(k, 0) + 1
    return d


# ---------------------------------------------------------------- SGLang cells


def run_sglang(cell, model, tp, ep, backend, sampling, n_prompts, max_new, out_dir, extra=None):
    import sglang as sgl
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(model)
    prompts = load_prompts(tok, n_prompts)

    kwargs = dict(
        model_path=model,
        tp_size=tp,
        mem_fraction_static=0.85,
        log_level="warning",
        # miles の 30B run と揃える。dense セルでは EP/backend を渡さない。
    )
    if ep and ep > 1:
        kwargs["ep_size"] = ep
    if backend is not None:
        kwargs["moe_runner_backend"] = backend
    if extra:
        kwargs.update(extra)

    print(f"[{cell}] launching SGLang: {kwargs}", flush=True)
    t0 = time.time()
    engine = sgl.Engine(**kwargs)
    print(f"[{cell}] engine up in {time.time() - t0:.0f}s", flush=True)

    sp = dict(
        temperature=sampling["temperature"],
        top_p=sampling["top_p"],
        top_k=sampling["top_k"],
        max_new_tokens=max_new,
        # miles と同一: stop/stop_token_ids は None (既定の eos のみ)、
        # no_stop_trim=True、skip_special_tokens は miles 既定に合わせる。
        no_stop_trim=True,
        spaces_between_special_tokens=False,
    )
    print(f"[{cell}] sampling_params={sp}", flush=True)

    t0 = time.time()
    outs = engine.generate([p["text"] for p in prompts], sp)
    gen_s = time.time() - t0
    print(f"[{cell}] generated {len(outs)} samples in {gen_s:.0f}s", flush=True)

    results = []
    for p, o in zip(prompts, outs):
        text = o["text"]
        mi = o.get("meta_info", {}) or {}
        results.append(
            {
                "index": p["index"],
                "label": p["label"],
                "finish_reason": (mi.get("finish_type") or (mi.get("finish_reason") or {}).get("type")),
                "completion_tokens": mi.get("completion_tokens"),
                "response": text,
                "diag": repetition_diagnostics(text),
            }
        )

    meta = dict(engine="sglang", model=model, tp=tp, ep=ep, backend=backend,
                sampling=sampling, max_new_tokens=max_new, gen_seconds=round(gen_s, 1),
                extra=extra or {})
    s = summarize(cell, results, meta, out_dir)
    engine.shutdown()
    return s


# -------------------------------------------------------------------- HF cell


def run_hf(cell, model, sampling, n_prompts, max_new, out_dir):
    """HuggingFace transformers の素の実装で生成する。

    SGLang の独自 MoE kernel を一切通らない経路。ここでも反復するなら
    原因は SGLang 実装ではなくモデル (またはプロンプト/sampling) 側に確定する。
    遅いのでサンプル数は小さくする。
    """
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tok = AutoTokenizer.from_pretrained(model)
    prompts = load_prompts(tok, n_prompts)
    print(f"[{cell}] loading HF model (this is slow)...", flush=True)
    t0 = time.time()
    m = AutoModelForCausalLM.from_pretrained(
        model, dtype=torch.bfloat16, device_map="auto", trust_remote_code=True
    )
    m.eval()
    print(f"[{cell}] loaded in {time.time() - t0:.0f}s", flush=True)

    results = []
    for p in prompts:
        ids = tok(p["text"], return_tensors="pt").to(m.device)
        t0 = time.time()
        with torch.no_grad():
            out = m.generate(
                **ids,
                do_sample=True,
                temperature=sampling["temperature"],
                top_p=sampling["top_p"],
                # HF は top_k=0 が「無効」。SGLang の -1 に対応させる。
                top_k=(0 if sampling["top_k"] in (-1, None) else sampling["top_k"]),
                max_new_tokens=max_new,
                pad_token_id=tok.pad_token_id or tok.eos_token_id,
            )
        gen = out[0][ids["input_ids"].shape[1]:]
        text = tok.decode(gen, skip_special_tokens=True)
        n_new = int(gen.shape[0])
        results.append(
            {
                "index": p["index"],
                "label": p["label"],
                "finish_reason": ("length" if n_new >= max_new else "stop"),
                "completion_tokens": n_new,
                "response": text,
                "diag": repetition_diagnostics(text),
            }
        )
        d = results[-1]["diag"]
        print(f"[{cell}] idx={p['index']} tok={n_new} chars={d['n_chars']} "
              f"ratio={d['tail_compression_ratio']:.1f} rep={d['has_repetition']} "
              f"({time.time() - t0:.0f}s)", flush=True)

    meta = dict(engine="hf-transformers", model=model, sampling=sampling, max_new_tokens=max_new)
    return summarize(cell, results, meta, out_dir)


# ------------------------------------------------------------------------ main

CELLS = {
    # id: (fn kwargs) -- 各セルが単独で動かす軸をコメントで明示
    "A_repro": dict(  # miles の 30B run と完全に同一構成。再現するかどうかが最初の分岐点。
        model="/fsx/models/Qwen3-30B-A3B", tp=4, ep=2, backend="triton",
        sampling=MILES_SAMPLING),
    "B_tp1": dict(  # 動かす軸: sharding (TP4/EP2 -> TP1/EP1)。他は A と同一。
        model="/fsx/models/Qwen3-30B-A3B", tp=1, ep=1, backend="triton",
        sampling=MILES_SAMPLING),
    "C_backend": dict(  # 動かす軸: moe_runner_backend (triton -> 既定/auto)。他は A と同一。
        model="/fsx/models/Qwen3-30B-A3B", tp=4, ep=2, backend=None,
        sampling=MILES_SAMPLING),
    "D_sampling": dict(  # 動かす軸: sampling (miles 既定 -> Qwen 推奨)。他は A と同一。
        model="/fsx/models/Qwen3-30B-A3B", tp=4, ep=2, backend="triton",
        sampling=QWEN_RECOMMENDED),
    "E_dense": dict(  # 対照群: dense 8B を同じ経路で。MoE 固有かを決める。
        model="/fsx/models/Qwen3-8B", tp=4, ep=1, backend=None,
        sampling=MILES_SAMPLING),
    # B_tp1 は TP4/EP2 -> TP1/EP1 で 2 軸を同時に動かしたので、どちらが原因かを
    # 分離していない。次の 2 セルが 1 軸ずつ戻して決める。詳細と事前宣言は
    # CELLS_TP_EP.md にある。
    "F_tp4_ep1": dict(  # 動かす軸: EP のみ (A_repro から EP2 -> EP1)
        model="/fsx/models/Qwen3-30B-A3B", tp=4, ep=1, backend="triton",
        sampling=MILES_SAMPLING),
    "G_tp1_ep2": dict(  # 動かす軸: TP のみ (A_repro から TP4 -> TP1)
        model="/fsx/models/Qwen3-30B-A3B", tp=1, ep=2, backend="triton",
        sampling=MILES_SAMPLING),
    # EP が原因と分かった後の次の問い: EP>1 で一律に壊れるのか、EP に比例して悪化するのか。
    # EP は TP に従属するので EP4 には TP8 が要る (TP4/EP4 は起動しない)。
    "H_tp8_ep1": dict(  # EP1 の対照。TP8 でも EP1 なら健全か
        model="/fsx/models/Qwen3-30B-A3B", tp=8, ep=1, backend="triton",
        sampling=MILES_SAMPLING),
    "I_tp8_ep2": dict(  # TP8/EP2。TP を変えても EP2 で壊れるかを確認する
        model="/fsx/models/Qwen3-30B-A3B", tp=8, ep=2, backend="triton",
        sampling=MILES_SAMPLING),
    "J_tp8_ep4": dict(  # EP4。EP を増やすと悪化するかを見る
        model="/fsx/models/Qwen3-30B-A3B", tp=8, ep=4, backend="triton",
        sampling=MILES_SAMPLING),
    # EP>1 で何が変わるかは少なくとも 3 つある: expert がグループに分割される、
    # all-to-all dispatch/combine が走る、各 rank が持つ expert 数が減る。
    # 次の 2 セルは all-to-all 実装を差し替えて、そこが原因かを切り分ける。
    # ここで反復が消えれば all-to-all 実装、消えなければ expert 分割そのものが原因になる。
    "K_ep2_a2a_deepep": dict(  # 動かす軸: all-to-all 実装 (none -> deepep)
        model="/fsx/models/Qwen3-30B-A3B", tp=8, ep=2, backend="triton",
        sampling=MILES_SAMPLING, extra={"moe_a2a_backend": "deepep"}),
    "L_ep2_redundant0": dict(  # 動かす軸: expert 配置 (冗長 expert を明示 0 に)
        model="/fsx/models/Qwen3-30B-A3B", tp=8, ep=2, backend="triton",
        sampling=MILES_SAMPLING, extra={"ep_num_redundant_experts": 0}),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cell", required=True, help="A_repro / B_tp1 / C_backend / D_sampling / E_dense / F_hf")
    ap.add_argument("--n-prompts", type=int, default=32)
    ap.add_argument("--max-new", type=int, default=8192,
                    help="miles の --rollout-max-response-len と同じ 8192 が既定")
    ap.add_argument("--out", default="/fsx/moe-probe/results")
    args = ap.parse_args()

    out_dir = Path(args.out)
    if args.cell == "F_hf":
        s = run_hf("F_hf", "/fsx/models/Qwen3-30B-A3B", MILES_SAMPLING,
                   args.n_prompts, args.max_new, out_dir)
    else:
        if args.cell not in CELLS:
            raise SystemExit(f"unknown cell {args.cell}; known: {sorted(CELLS)} + F_hf")
        s = run_sglang(args.cell, n_prompts=args.n_prompts, max_new=args.max_new,
                       out_dir=out_dir, **CELLS[args.cell])

    print("\n===== SUMMARY =====")
    print(json.dumps(s, indent=2))
    # miles の実測値と並べて出す。比較の基準を毎回目の前に置く。
    print("\n(miles 実測の基準: 30B MoE repetition_frac 0.633 / dense 0.0)")


if __name__ == "__main__":
    main()
