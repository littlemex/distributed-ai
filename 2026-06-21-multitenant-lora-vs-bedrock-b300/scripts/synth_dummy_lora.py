#!/usr/bin/env python3
"""peft を介さず vLLM が読めるダミー LoRA adapter を直接合成する。

背景: Gemma 4 は `Gemma4ClippableLinear` という独自 Linear ラッパーを使うため、peft 0.19.1 の
get_peft_model() が "Target module ... is not supported" で失敗する (torch.nn.Linear でないため)。
だが我々のダミー adapter は重みの値が無意味でよい (serving 性能は rank/target_modules だけで決まる)。
→ peft を完全にスキップし、vLLM が期待する PEFT 形式 (adapter_config.json + adapter_model.safetensors)
   を、正しい shape の乱数テンソルで直接書き出す。

vLLM が要求する形式 (確認済み, vllm/lora/peft_helper.py):
  - adapter_config.json: peft_type=LORA, r, lora_alpha, target_modules, bias=none, use_dora=false
  - adapter_model.safetensors の key: base_model.model.<layer_path>.lora_A.weight / lora_B.weight
    lora_A: [r, in_features], lora_B: [out_features, r]

[重要] Gemma 4 は層ごとに attention 次元が異なる (heterogeneous, 実機 config で確定):
  - sliding_attention 層 (local) : head_dim=256, kv_heads=16 -> q_out=32*256=8192, kv_out=16*256=4096
  - full_attention 層 (global)   : head_dim=512(global_head_dim), kv_heads=4(num_global_key_value_heads)
                                   -> q_out=32*512=16384, kv_out=4*512=2048
  各層が sliding か full かは config の text_config.layer_types で決まる。
  o_proj の in_features = q_out なので層により 8192/16384 と変わる点にも注意。
  全層一律 shape で作ると vLLM ロード時に "size of tensor a (2048) must match b (4096)" で 500。

config から自動取得するため、--config-json に base モデルの config.json パスを渡せば
hidden/intermediate/layers/head_dim/global_head_dim/kv 構成/layer_types を読む。

使い方 (config 自動):
  python synth_dummy_lora.py --n 1000 --out-dir /mnt/k8s-disks/0/adapters/gemma4-31b \
     --config-json /path/to/gemma-4-31B-it/config.json --rank 16
"""
import argparse
import glob
import json
import os

import torch
from safetensors.torch import save_file


def load_dims(config_json):
    c = json.load(open(config_json))
    t = c.get("text_config", c)
    n = t["num_hidden_layers"]
    layer_types = t.get("layer_types")
    if not layer_types:
        # フォールバック: sliding_window_pattern (例 6) で full を周期配置
        period = t.get("sliding_window_pattern") or 6
        layer_types = ["full_attention" if (i + 1) % period == 0 else "sliding_attention"
                       for i in range(n)]
    return {
        "hidden": t["hidden_size"],
        "intermediate": t["intermediate_size"],
        "layers": n,
        "heads": t["num_attention_heads"],
        "head_dim": t["head_dim"],
        "global_head_dim": t.get("global_head_dim", t["head_dim"]),
        "kv_heads": t["num_key_value_heads"],
        "global_kv_heads": t.get("num_global_key_value_heads", t["num_key_value_heads"]),
        "layer_types": layer_types,
    }


def build_lora_tensors(d, rank, dtype):
    """layer_types に従い per-layer で attention proj の次元を切り替えて生成。
    vLLM の packed mapping (qkv_proj<-q,k,v / gate_up_proj<-gate,up) は vLLM 側が結合するので、
    PEFT 保存側は展開形 (q/k/v/o/gate/up/down_proj) で個別に持つ。lora_A=[r,in], lora_B=[out,r]。"""
    hidden, inter = d["hidden"], d["intermediate"]
    sd = {}
    for li, lt in enumerate(d["layer_types"]):
        if lt == "full_attention":  # global
            hd, kvh = d["global_head_dim"], d["global_kv_heads"]
        else:                        # sliding (local)
            hd, kvh = d["head_dim"], d["kv_heads"]
        q_out = d["heads"] * hd
        kv_out = kvh * hd
        proj = {
            "self_attn.q_proj": (hidden, q_out),
            "self_attn.k_proj": (hidden, kv_out),
            "self_attn.v_proj": (hidden, kv_out),
            "self_attn.o_proj": (q_out, hidden),
            "mlp.gate_proj": (hidden, inter),
            "mlp.up_proj": (hidden, inter),
            "mlp.down_proj": (inter, hidden),
        }
        for path, (in_f, out_f) in proj.items():
            key = f"base_model.model.model.layers.{li}.{path}.lora_{{ab}}.weight"
            sd[key.format(ab="A")] = torch.randn(rank, in_f, dtype=dtype) * 0.02
            sd[key.format(ab="B")] = torch.zeros(out_f, rank, dtype=dtype)
    return sd


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--n", type=int, default=1000)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--config-json", required=True,
                   help="base モデルの config.json パス (glob 可)。次元を自動取得")
    p.add_argument("--rank", type=int, default=16)
    p.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16"])
    args = p.parse_args()

    cfg_path = sorted(glob.glob(args.config_json))[0] if "*" in args.config_json else args.config_json
    d = load_dims(cfg_path)
    n_full = sum(1 for lt in d["layer_types"] if lt == "full_attention")
    print(f"[INFO] dims from {cfg_path}: hidden={d['hidden']} layers={d['layers']} "
          f"(full={n_full}, sliding={d['layers']-n_full}) "
          f"local(hd={d['head_dim']},kv={d['kv_heads']}) global(hd={d['global_head_dim']},kv={d['global_kv_heads']})")
    dtype = torch.bfloat16 if args.dtype == "bfloat16" else torch.float16
    cfg = {
        "peft_type": "LORA", "auto_mapping": None, "base_model_name_or_path": "",
        "revision": None, "task_type": "CAUSAL_LM", "inference_mode": True,
        "r": args.rank, "lora_alpha": args.rank, "lora_dropout": 0.0,
        "target_modules": ["q_proj", "k_proj", "v_proj", "o_proj",
                           "gate_proj", "up_proj", "down_proj"],
        "bias": "none", "use_dora": False, "use_rslora": False,
        "fan_in_fan_out": False, "modules_to_save": None, "init_lora_weights": True,
    }

    os.makedirs(args.out_dir, exist_ok=True)
    print(f"[INFO] building per-layer lora tensors (rank={args.rank}, layers={d['layers']})")
    sd = build_lora_tensors(d, args.rank, dtype)
    n_params = sum(t.numel() for t in sd.values())
    print(f"[INFO] {len(sd)} tensors, {n_params/1e6:.1f}M params/adapter "
          f"(~{n_params*2/1e6:.0f}MB bf16)")

    # adapter-0 に実体、残りは safetensors をハードリンク (ディスク節約)。
    a0 = os.path.join(args.out_dir, "adapter-0")
    os.makedirs(a0, exist_ok=True)
    save_file(sd, os.path.join(a0, "adapter_model.safetensors"))
    with open(os.path.join(a0, "adapter_config.json"), "w") as f:
        json.dump(cfg, f, indent=2)
    src = os.path.join(a0, "adapter_model.safetensors")

    for i in range(1, args.n):
        adir = os.path.join(args.out_dir, f"adapter-{i}")
        os.makedirs(adir, exist_ok=True)
        dst = os.path.join(adir, "adapter_model.safetensors")
        if not os.path.exists(dst):
            os.link(src, dst)
        with open(os.path.join(adir, "adapter_config.json"), "w") as f:
            json.dump(cfg, f, indent=2)
        if i % 100 == 0:
            print(f"  [INFO] {i}/{args.n}")

    print(f"[OK] {args.n} adapters in {args.out_dir}")
    os.system(f"du -sh {src} {args.out_dir}")


if __name__ == "__main__":
    main()
