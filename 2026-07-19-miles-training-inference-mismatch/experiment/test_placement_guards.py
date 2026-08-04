#!/usr/bin/env python3
"""配置(placement)検証の golden テスト: Python 側と bash 側が同じ判定をすることを固定する。

なぜ二重に検証しているのか
--------------------------
役割が違う。

  Python (gen_cells.py)  実験設計の整合性。spec が「この 2 セルは placement だけが違う」と
                         宣言したなら、本当にそうかを生成時に検証する。GPU 時間を使う前に
                         止められる唯一の場所。
  bash (recipe)          実行時入力の fail-closed 検証。recipe は env を手で書いて直接
                         叩くこともできるので、生成器を通らない経路が現実に存在する。
                         最後の砦なので削れない。

二重化そのものは正しいが、二重化はドリフトする。片方だけ厳しくなれば「生成器は通すのに
recipe が落ちる」あるいはその逆が起きて、どちらが正なのか分からなくなる。そこで
**同一の不正入力集合を両方に食わせて、両方が拒否することを固定する**のがこのテスト。

このテストが守っている事故
--------------------------
この study は「recipe が --colocate をハードコードし、COLOCATE 変数は banner の echo に
しか使われていなかった」ために、disaggregated アームが一度も走っていなかった。
検証が黙って無効化されている状態が最も危険なので、以下はすべて「黙って通ってはいけない」
入力である。
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from gen_cells import _expand_sync_method, check_comparisons  # noqa: E402

# The recipe under test. Defaults to the copy in this study, but the upstream test case's
# recipe must satisfy the same guards -- that is where the fix actually ships -- so allow
# pointing at it rather than maintaining a second copy of these cases.
# The recipe under test. The single source of truth is the upstream test case's recipe -- that
# is where the fix ships and what a user actually runs -- so default to it rather than keeping
# a second copy of it next to this harness. MILES_RECIPE overrides the path for a checkout in
# a different place.
# This repo mirrors the upstream test case under 3.test_cases/, and that mirror is what these
# guards check: keeping a third copy beside the harness is how the mirror and the original
# drifted apart in the first place. Point MILES_RECIPE at an upstream checkout to verify the
# two still agree.
_DEFAULT_RECIPE = (HERE.parent / "3.test_cases" / "pytorch" / "miles" / "recipe"
                   / "run_grpo_qwen3_4b.sh")
RECIPE = Path(os.environ.get("MILES_RECIPE", _DEFAULT_RECIPE))

# 正常系。ここから 1 項目ずつ壊して「両方が拒否するか」を見る。
GOOD_COLO = {
    "SYNC_METHOD": "colocated",
    "ACTOR_NUM_NODES": "1",
    "ACTOR_GPUS_PER_NODE": "8",
    "ROLLOUT_NUM_GPUS": "8",
    "ROLLOUT_GPUS_PER_ENGINE": "1",
    "CLUSTER_GPUS": "16",
}
GOOD_DISAGG = dict(GOOD_COLO, SYNC_METHOD="disaggregated")

# (ラベル, vars, python が落ちるか, bash が落ちるか, 期待する拒否理由)
#
# bash は SYNC_METHOD を読まない (COLOCATE を読む) ので、bash に食わせるときは
# SYNC_METHOD から COLOCATE へ変換する。変換できない不正 (未知の method) は
# python 専用のケースになる。
#
# 5 番目の要素は「両方が同じ理由で拒否したか」を見るための部分文字列である。
# 終了コードだけを見ると、bash が未定義変数エラーなど**別の理由で偶然落ちた**場合も
# テストが通ってしまう。それでは「このガードが働いた」ことを確認できていない。
CASES = [
    ("colocated with a rollout pool that is not the actor pool",
     dict(GOOD_COLO, ROLLOUT_NUM_GPUS="4"), True, True,
     "must equal the actor GPU count"),
    ("disaggregated that does not fit the cluster",
     dict(GOOD_DISAGG, ROLLOUT_NUM_GPUS="16"), True, True,
     "more than CLUSTER_GPUS"),
    ("engine size that does not divide the rollout pool",
     dict(GOOD_DISAGG, ROLLOUT_GPUS_PER_ENGINE="3"), True, True,
     "divisor of ROLLOUT_NUM_GPUS"),
    ("engine size zero",
     dict(GOOD_DISAGG, ROLLOUT_GPUS_PER_ENGINE="0"), True, True,
     "divisor of ROLLOUT_NUM_GPUS"),
    ("non-numeric GPU count",
     dict(GOOD_DISAGG, ROLLOUT_NUM_GPUS="8x"), True, True,
     "integer"),
    ("actor alone exceeds the cluster",
     dict(GOOD_COLO, ACTOR_NUM_NODES="4", ROLLOUT_NUM_GPUS="32"), True, True,
     "more than CLUSTER_GPUS"),
]

# bash 側だけの穴。生成器を通らず env を手で書く経路で起こる。
BASH_ONLY_CASES = [
    ("COLOCATE=True (capitalised) must not silently mean disaggregated", {"COLOCATE": "True"}),
    ("COLOCATE=1 must not silently mean disaggregated", {"COLOCATE": "1"}),
    ("COLOCATE=yes must not silently mean disaggregated", {"COLOCATE": "yes"}),
    ("COLOCATE empty must not silently mean disaggregated", {"COLOCATE": ""}),
]

# python 側だけの穴。spec の書き方の問題なので実行時には現れない。
PYTHON_ONLY_CASES = [
    ("unknown SYNC_METHOD", dict(GOOD_COLO, SYNC_METHOD="hybrid")),
    ("SYNC_METHOD contradicting an explicit COLOCATE",
     dict(GOOD_COLO, COLOCATE="false")),
    ("missing CLUSTER_GPUS leaves the capacity check unable to run",
     {k: v for k, v in GOOD_DISAGG.items() if k != "CLUSTER_GPUS"}),
    ("missing ROLLOUT_NUM_GPUS leaves the layout check unable to run",
     {k: v for k, v in GOOD_DISAGG.items() if k != "ROLLOUT_NUM_GPUS"}),
]


def run_recipe(vars_):
    """recipe を argv 生成の直前まで走らせ、(rc, stdout+stderr) を返す。

    `ray job submit` 以降を切り落とすので実際のジョブは投入されない。
    """
    body = []
    for line in RECIPE.read_text().splitlines():
        if line.startswith("ray job submit"):
            break
        body.append(line)
    body.append('printf "%s\\n" "${TRAIN_ARGS[@]}"')

    env = dict(os.environ)
    env.update({
        "MODEL_LOCAL": "/fsx/models/Qwen3-4B",
        "MODEL_DIST": "/fsx/models/Qwen3-4B_torch_dist",
        "PROMPT_DATA": "/fsx/data/d.jsonl", "EVAL_DATA": "/fsx/data/e.jsonl",
        "CHECKPOINT_DIR": "/fsx/runs/x/ckpt", "MODEL_SCRIPT": "qwen3-4B.sh",
        "RM_TYPE": "deepscaler", "NUM_ROLLOUT": "7", "ROLLOUT_BATCH_SIZE": "16",
        "N_SAMPLES_PER_PROMPT": "8", "GLOBAL_BATCH_SIZE": "128",
        "MAX_TOKENS_PER_GPU": "8192", "ROLLOUT_MAX_RESPONSE_LEN": "8192",
        "ROLLOUT_TEMPERATURE": "1.0", "LEARNING_RATE": "1e-6", "SAVE_INTERVAL": "1000",
        "TP_SIZE": "1", "PP_SIZE": "1", "CP_SIZE": "1", "EP_SIZE": "1",
        "ACTOR_NUM_NODES": "1", "ACTOR_GPUS_PER_NODE": "8",
        "ROLLOUT_NUM_GPUS": "8", "ROLLOUT_GPUS_PER_ENGINE": "1",
        "CLUSTER_GPUS": "16", "COLOCATE": "true",
    })
    for k, v in vars_.items():
        if k == "SYNC_METHOD":
            env["COLOCATE"] = "true" if v == "colocated" else "false"
        else:
            env[k] = str(v)

    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write("\n".join(body) + "\n")
        path = f.name
    try:
        p = subprocess.run(["bash", path], env=env, capture_output=True, text=True,
                           timeout=60)
        return p.returncode, p.stdout + p.stderr
    finally:
        os.unlink(path)


class TestBothLayersAgree(unittest.TestCase):
    """同じ不正入力を Python と bash の両方が拒否する。"""

    def test_shared_cases(self):
        for label, vars_, py_fails, sh_fails, reason in CASES:
            with self.subTest(label=label, layer="python"):
                if py_fails:
                    with self.assertRaises(ValueError, msg=f"python accepted: {label}") as e:
                        _expand_sync_method(vars_, "t")
                    # 同じ理由で拒否したことまで見る。別の理由で偶然落ちても
                    # 終了コードだけなら通ってしまう。
                    self.assertIn(reason, str(e.exception),
                                  f"python rejected {label} for the wrong reason")
                else:
                    _expand_sync_method(vars_, "t")
            with self.subTest(label=label, layer="bash"):
                rc, out = run_recipe(vars_)
                if sh_fails:
                    self.assertNotEqual(rc, 0, f"bash accepted: {label}\n{out[-800:]}")
                    self.assertIn(reason, out,
                                  f"bash rejected {label} for the wrong reason -- the guard "
                                  f"under test may not have run at all:\n{out[-800:]}")
                else:
                    self.assertEqual(rc, 0, f"bash rejected a valid case: {label}\n{out[-800:]}")

    def test_good_cases_pass_both(self):
        for label, vars_ in [("colocated", GOOD_COLO), ("disaggregated", GOOD_DISAGG)]:
            with self.subTest(label=label):
                _expand_sync_method(vars_, "ok")  # must not raise
                rc, out = run_recipe(vars_)
                self.assertEqual(rc, 0, f"bash rejected the good {label} case:\n{out[-800:]}")
                # 選ばれた方式が argv に現れていること。banner を信じず argv を見る。
                if label == "colocated":
                    self.assertIn("--colocate", out.splitlines())
                else:
                    self.assertNotIn("--colocate", out.splitlines())


class TestBashOnlyGuards(unittest.TestCase):
    """生成器を通らない経路の入力検証。"""

    def test_non_boolean_colocate_is_rejected(self):
        for label, vars_ in BASH_ONLY_CASES:
            with self.subTest(label=label):
                rc, out = run_recipe(vars_)
                self.assertNotEqual(rc, 0, f"bash accepted: {label}\n{out[-800:]}")
                # 「黙って disaggregated になった」のが最悪なので、
                # argv に --colocate が無いまま rc=0 で通ることを特に禁じる。
                self.assertNotIn("--rollout-num-gpus", out.splitlines()[-3:],
                                 "argv was rendered despite an invalid COLOCATE")


class TestPythonOnlyGuards(unittest.TestCase):
    """spec の書き方に起因する誤りは生成時に落とす。"""

    def test_spec_level_errors(self):
        for label, vars_ in PYTHON_ONLY_CASES:
            with self.subTest(label=label):
                with self.assertRaises(ValueError, msg=f"python accepted: {label}"):
                    _expand_sync_method(vars_, "t")


class TestComparisons(unittest.TestCase):
    """「この 2 セルは placement だけが違う」という宣言を検証する。

    これが無かったために、最初の disaggregated 測定は mem-fraction 0.85 で、
    比較相手の colocated は 0.8 だった。各セルは個別には正しく、実験だけが壊れていた。
    """

    def _spec(self, colo_mf, disagg_mf, **kw):
        common = dict(GOOD_COLO)
        common.pop("SYNC_METHOD")
        spec = {
            "base_path": "/dev/null",
            "common": dict(common, TP_SIZE="1", NUM_ROLLOUT="7"),
            "cells": [
                {"name": "colo", "vars": {"SYNC_METHOD": "colocated",
                                          "SGLANG_MEM_FRACTION": colo_mf}},
                {"name": "disagg", "vars": {"SYNC_METHOD": "disaggregated",
                                            "SGLANG_MEM_FRACTION": disagg_mf}},
            ],
            "comparisons": [{
                "label": "method at fixed mem-fraction",
                "cells": ["colo", "disagg"],
                "must_differ": ["SYNC_METHOD"],
                "must_match": ["SGLANG_MEM_FRACTION", "TP_SIZE", "NUM_ROLLOUT"],
                # Every remaining key has to be accounted for explicitly; see the
                # exhaustive-classification check in check_comparisons().
                "ignored": ["ACTOR_NUM_NODES", "ACTOR_GPUS_PER_NODE", "ROLLOUT_NUM_GPUS",
                            "ROLLOUT_GPUS_PER_ENGINE", "CLUSTER_GPUS"],
            }],
        }
        spec.update(kw)
        return spec

    def test_matched_pair_is_accepted(self):
        self.assertEqual(check_comparisons(self._spec("0.8", "0.8")), [])

    def test_mem_fraction_mismatch_is_caught(self):
        """まさに実際に起きた事故。0.8 対 0.85 を通してはいけない。"""
        problems = check_comparisons(self._spec("0.8", "0.85"))
        self.assertTrue(problems)
        self.assertIn("SGLANG_MEM_FRACTION", problems[0])

    def test_must_match_key_absent_from_both_is_not_agreement(self):
        """両方が黙っていることは一致ではない。"""
        spec = self._spec("0.8", "0.8")
        for c in spec["cells"]:
            c["vars"].pop("SGLANG_MEM_FRACTION")
        problems = check_comparisons(spec)
        self.assertTrue(problems)
        self.assertIn("absent", problems[0])

    def test_must_differ_that_does_not_differ_is_caught(self):
        spec = self._spec("0.8", "0.8")
        spec["cells"][1]["vars"]["SYNC_METHOD"] = "colocated"
        problems = check_comparisons(spec)
        self.assertTrue(any("must_differ" in p for p in problems))

    def test_unknown_cell_name_is_caught(self):
        spec = self._spec("0.8", "0.8")
        spec["comparisons"][0]["cells"] = ["colo", "typo"]
        problems = check_comparisons(spec)
        self.assertTrue(any("unknown cell" in p for p in problems))

    def test_unclassified_key_is_caught(self):
        """列挙し忘れたキーは「無害」ではなく「未分類」として落とす。

        0.8 対 0.85 の事故は must_match の列挙漏れそのものだった。allowlist 方式では
        同じ漏れが再発するので、両セルに現れる全キーの分類を要求する。
        """
        spec = self._spec("0.8", "0.8")
        spec["cells"][0]["vars"]["SOME_NEW_KNOB"] = "a"
        spec["cells"][1]["vars"]["SOME_NEW_KNOB"] = "b"
        problems = check_comparisons(spec)
        self.assertTrue(any("neither must_match" in p for p in problems))
        self.assertTrue(any("SOME_NEW_KNOB" in p for p in problems))

    def test_ignored_silences_a_key_deliberately(self):
        spec = self._spec("0.8", "0.8")
        spec["cells"][0]["vars"]["SOME_NEW_KNOB"] = "a"
        spec["cells"][1]["vars"]["SOME_NEW_KNOB"] = "b"
        spec["comparisons"][0]["ignored"].append("SOME_NEW_KNOB")
        self.assertEqual(check_comparisons(spec), [])

    def test_no_comparisons_is_silent(self):
        """comparisons を書かない既存 spec は無変更で通る。"""
        spec = self._spec("0.8", "0.85")
        del spec["comparisons"]
        self.assertEqual(check_comparisons(spec), [])


class TestExpansionInvariants(unittest.TestCase):
    """_expand_sync_method そのものの性質。placement 検証とは別の観点。"""

    def test_absent_sync_method_is_untouched(self):
        """SYNC_METHOD を使わない既存 spec は 1 バイトも変わってはいけない。

        この study には SYNC_METHOD を持たない cell が 13 spec 分ある。
        それらの生成結果が変わると、既発表の測定値と argv が一致しなくなる。
        """
        d = {"TP_SIZE": "1", "COLOCATE": "true"}
        self.assertEqual(_expand_sync_method(d, "x"), d)

    def test_sync_method_is_kept_in_output(self):
        """生成された env が監査対象なので、配置を COLOCATE から逆算させない。"""
        out = _expand_sync_method(GOOD_COLO, "c")
        self.assertEqual(out["SYNC_METHOD"], "colocated")
        self.assertEqual(out["COLOCATE"], "true")

    def test_input_is_not_mutated(self):
        d = dict(GOOD_COLO)
        snapshot = dict(d)
        _expand_sync_method(d, "pure")
        self.assertEqual(d, snapshot)

    def test_mem_fraction_is_not_derived(self):
        """mem-fraction を方式から導出してはいけない。

        colocated 経路だけが sync ごとに pause_generation + flush_cache を呼ぶので
        (update_weight_from_tensor.py:213-215)、mem-fraction は比較対象の量の内側に入る。
        導出すると交絡がハーネスに焼き込まれ、「両方式を同じ mem-fraction で測る」
        という実験そのものが表現できなくなる。
        """
        for label, vars_ in [("colocated", GOOD_COLO), ("disaggregated", GOOD_DISAGG)]:
            with self.subTest(label=label):
                self.assertNotIn("SGLANG_MEM_FRACTION", _expand_sync_method(vars_, "m"))


if __name__ == "__main__":
    if not RECIPE.is_file():
        print(f"recipe not found: {RECIPE}", file=sys.stderr)
        sys.exit(2)
    unittest.main(verbosity=2)
