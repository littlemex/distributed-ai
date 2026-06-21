#!/usr/bin/env python3
"""ダミー LoRA adapter を訓練なしで N 枚生成する。

マルチテナント serving 性能計測用。serving のレイテンシ/スループットは LoRA 重みの
"値" には依存せず rank と target_modules だけで決まるため、乱数初期化の adapter で
十分に性能を測れる(出力は ignore_eos で固定長にするため NaN/ゴミ出力でも計測に影響なし)。

vLLM の制約 (確認済み, vllm/lora/peft_helper.py validate_legal):
  - rank <= --max-lora-rank
  - bias == 'none'
  - use_dora == False

実ディスク節約: adapter-0 だけ実体を持ち、adapter-1.. は重みファイルをハードリンク
(inode 共有)。adapter_config.json のみ各 adapter 固有。
注意: vLLM は lora_int_id でキャッシュ管理するためロード時はデデュープされず個別に
CPU RAM へ載る (27B rank-16 bf16 = ~217MB/枚 × 1000 = 211GB)。ディスク節約だけが効く。

使い方:
  python mint_dummy_lora_adapters.py --model google/gemma-3-27b-it --n 1000 --out-dir /adapters/gemma3-27b
  python mint_dummy_lora_adapters.py --model google/gemma-3-4b-it  --n 1000 --out-dir /adapters/gemma3-4b
"""
import argparse
import json
import os

import torch

# Gemma3ForCausalLM の attention + MLP。vLLM 側は packed_modules_mapping で
#   qkv_proj <- [q_proj, k_proj, v_proj] / gate_up_proj <- [gate_proj, up_proj]
# に再結合するため、PEFT 保存側は展開形の 7 モジュール名で保存する。
TARGET_MODULES = [
    "q_proj", "k_proj", "v_proj", "o_proj",
    "gate_proj", "up_proj", "down_proj",
]


def mint(base_model_name: str, n: int, out_dir: str, rank: int = 16) -> None:
    from peft import LoraConfig, get_peft_model
    from transformers import AutoConfig, AutoModelForCausalLM

    lora_config = LoraConfig(
        r=rank,
        lora_alpha=rank,           # scaling = lora_alpha / r = 1.0
        target_modules=TARGET_MODULES,
        bias="none",               # vLLM は bias tensors 非サポート
        use_dora=False,            # vLLM に DoRA カーネル実装なし
        task_type="CAUSAL_LM",
        init_lora_weights=True,
    )

    # meta デバイスで config のみから骨格を組む (27B の実重みダウンロード不要)。
    config = AutoConfig.from_pretrained(base_model_name)
    with torch.device("meta"):
        model = AutoModelForCausalLM.from_config(config)
    peft_model = get_peft_model(model, lora_config)
    peft_model = peft_model.to_empty(device="cpu")

    # lora_A/B を小さなランダム値で初期化 (meta -> empty は未初期化のため明示的に埋める)。
    for name, param in peft_model.named_parameters():
        if "lora_" in name:
            torch.nn.init.normal_(param, mean=0.0, std=0.02)

    os.makedirs(out_dir, exist_ok=True)
    adapter0_dir = os.path.join(out_dir, "adapter-0")
    os.makedirs(adapter0_dir, exist_ok=True)
    peft_model.save_pretrained(adapter0_dir)  # adapter_config.json + adapter_model.safetensors

    weights_src = os.path.join(adapter0_dir, "adapter_model.safetensors")
    config_src = os.path.join(adapter0_dir, "adapter_config.json")

    for i in range(1, n):
        adir = os.path.join(out_dir, f"adapter-{i}")
        os.makedirs(adir, exist_ok=True)
        dst = os.path.join(adir, "adapter_model.safetensors")
        if not os.path.exists(dst):
            os.link(weights_src, dst)  # ハードリンク (実ディスク = 1 コピー分)
        with open(config_src) as f:
            cfg = json.load(f)
        cfg["adapter_id"] = i  # メタ情報 (vLLM は無視するが追跡用)
        with open(os.path.join(adir, "adapter_config.json"), "w") as f:
            json.dump(cfg, f, indent=2)
        if i % 100 == 0:
            print(f"  [INFO] {i}/{n} adapters created")

    print(f"[OK] {n} adapters in {out_dir}")
    os.system(f"du -sh {weights_src} {out_dir}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", default="google/gemma-3-27b-it")
    p.add_argument("--n", type=int, default=1000)
    p.add_argument("--out-dir", default="/adapters/gemma3-27b")
    p.add_argument("--rank", type=int, default=16)
    args = p.parse_args()
    mint(args.model, args.n, args.out_dir, args.rank)
