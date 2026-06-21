#!/usr/bin/env python3
"""Bedrock (Approach A) 用に、テナントごとに distinct な system prompt を持つ
shareGPT 形式の JSONL データセットを生成する。

設計意図 (§1): テナントごとに system prompt の内容が異なる → Bedrock の prompt
caching は効かない (そもそも Gemma には caching 機能が無い, F1)。よって毎回フルの
input トークンを課金される。これを system-prompt サイズ短->長で sweep して、
入力トークン量がコストとレイテンシ (TTFT) に与える影響を測る。

system-prompt サイズ: short(128) / medium(512) / long(2048) / xlarge(8192) トークン。
各テナント (tenant_id) はシードで固定された再現可能な乱文を持つ。

出力: bedrock_dataset_{size}_{n}tenants.jsonl

使い方:
  python gen_bedrock_dataset.py                       # 全 size x n を生成
  python gen_bedrock_dataset.py --sizes long --n 1000
"""
import argparse
import hashlib
import json
import random

SYSTEM_PROMPT_TOKENS = {"short": 128, "medium": 512, "long": 2048, "xlarge": 8192}

# テナント設定文を模した語彙 (企業ごとのポリシー/構成説明という想定)。
WORDS = (
    "configuration system tenant enterprise policy compliance regulation "
    "service account access control role permission deployment infrastructure "
    "monitoring alerting logging audit trail security governance"
).split()


def make_system_prompt(tenant_id: int, target_tokens: int) -> str:
    n_words = int(target_tokens * 0.75)  # 1 token ~= 0.75 words (英語概算)
    rng = random.Random(
        int.from_bytes(hashlib.md5(f"tenant-{tenant_id}".encode()).digest(), "big")
    )
    header = f"Tenant {tenant_id:04d} configuration: "
    body = " ".join(rng.choice(WORDS) for _ in range(n_words))
    return header + body


def gen_dataset(n_tenants: int, sp_size: str, out_file: str) -> None:
    target_tokens = SYSTEM_PROMPT_TOKENS[sp_size]
    with open(out_file, "w") as f:
        for tid in range(n_tenants):
            row = {
                "tenant_id": tid,  # affinity proxy 用 (X-Tenant-ID に流用可)
                "conversations": [
                    {"from": "system", "value": make_system_prompt(tid, target_tokens)},
                    {"from": "human", "value": "Summarize your configuration. " + "word " * 96},
                ],
            }
            f.write(json.dumps(row) + "\n")
    print(f"[OK] {out_file}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sizes", nargs="*", default=list(SYSTEM_PROMPT_TOKENS),
                   choices=list(SYSTEM_PROMPT_TOKENS))
    p.add_argument("--n", type=int, nargs="*", default=[100, 500, 1000])
    args = p.parse_args()

    for sp in args.sizes:
        for n in args.n:
            gen_dataset(n, sp, f"bedrock_dataset_{sp}_{n}tenants.jsonl")
