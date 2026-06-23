#!/usr/bin/env python3
"""llm-d / GIE EndpointPicker 実験 (Phase 2) の構成図を draw.io XML で生成。
figures-src-ja/gen_arch_figs.py と同じデザイン言語 (洗練トーン) を踏襲する。

 パレット: 背景 #FBFCFD / 枠グレー #D8DEE4 / アクセント teal #2D6E6E / 文字 #1A2027 /
           サブ #5A6B7B / 淡teal塗り #EAF1F1 / 警告系 muted #B0563A
 ページ: 1480 x 820 (figures-src-ja の標準)、タイトル/黒帯なし (本体を大きく)

出力 (figures-src-ja/ に配置する想定):
  llmd_epp_arch.xml  : EPP standalone 構成 (client→Envoy→ext_proc→EPP→InferencePool→8 Pod)
  llmd_profiles.xml  : 3 profile (rr/affinity/full) の scorer 構成と profile 差し替えだけで条件切替
  llmd_pitfalls.xml  : 実装のはまりポイント 4 件
  llmd_result.xml    : 計測結果の要点 (affinity 単独崩壊 vs full 最良 + 整合性 OK)
"""
import os
import re

OUT = os.environ.get("OUT", "/tmp/llmd-figs")
os.makedirs(OUT, exist_ok=True)

INK = "#1A2027"; SUB = "#5A6B7B"; GREY = "#D8DEE4"; TEAL = "#2D6E6E"
FILL = "#EAF1F1"; WARN = "#B0563A"; BG = "#FBFCFD"
TEALL = "#5E9C9C"; GOLD = "#C9A24A"; GOOD = "#2D6E6E"

_id = [1]
def nid():
    _id[0] += 1; return "k%d" % _id[0]
def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
def cell(val, style, x, y, w, h):
    return ('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
            % (nid(), esc(val).replace("\n", "&#10;"), style, x, y, w, h))

SCALE = 1.0  # figures-src-ja は実寸フォント指定なので等倍
def txt(val, x, y, w, h, size=14, bold=False, italic=False, color=INK, align="left", valign="top"):
    st = "text;html=1;whiteSpace=wrap;align=%s;verticalAlign=%s;fontSize=%d;fontColor=%s;" % (align, valign, size, color)
    if bold: st += "fontStyle=1;"
    elif italic: st += "fontStyle=2;"
    return cell(val, st, x, y, w, h)
def boxr(x, y, w, h, fill=BG, stroke=GREY, sw=1, arc=6, dashed=False):
    st = "rounded=1;arcSize=%d;fillColor=%s;strokeColor=%s;strokeWidth=%s;" % (arc, fill, stroke, sw)
    if dashed: st += "dashed=1;"
    return cell("", st, x, y, w, h)
def pill(val, x, y, w, h, fill=TEAL, fc="#FFFFFF", size=16, bold=True):
    st = "rounded=1;arcSize=24;fillColor=%s;strokeColor=none;fontSize=%d;fontColor=%s;verticalAlign=middle;align=center;" % (fill, size, fc)
    if bold: st += "fontStyle=1;"
    return cell(val, st, x, y, w, h)
def icon(res, x, y, w=66, h=66, fill=TEAL, label="", lblcolor=SUB, lblsize=13):
    st = ("sketch=0;html=1;fontSize=%d;fontColor=%s;verticalLabelPosition=bottom;verticalAlign=top;"
          "align=center;shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.%s;fillColor=%s;strokeColor=none;"
          % (lblsize, lblcolor, res, fill))
    return cell(label, st, x, y, w, h)
def arrow(x1, y1, x2, y2, color=SUB, sw=2.0, dashed=False, label="", lblsize=13, lblcolor=None):
    st = "endArrow=classic;html=1;strokeColor=%s;strokeWidth=%s;" % (color, sw)
    if dashed: st += "dashed=1;"
    if label:
        st += "fontSize=%d;fontColor=%s;labelBackgroundColor=#FFFFFF;" % (lblsize, lblcolor or SUB)
    return ('<mxCell id="%s" value="%s" style="%s" edge="1" parent="1"><mxGeometry relative="1" as="geometry">'
            '<mxPoint x="%d" y="%d" as="sourcePoint"/><mxPoint x="%d" y="%d" as="targetPoint"/></mxGeometry></mxCell>'
            % (nid(), esc(label), st, x1, y1, x2, y2))
def hdr(val, x=52, y=64, w=1360):
    # 既存図と同じ斜体サブヘッダ (上部の一文説明)
    return cell(val, "text;html=1;align=left;fontSize=23;fontStyle=2;fontColor=#5A6B7B;",
                x, y, w, 32)

def save(name, cells, ph=820):
    body = "".join(cells)
    open(os.path.join(OUT, name), "w").write(
        '<mxfile host="embed.diagrams.net"><diagram id="%s" name="Page-1">'
        '<mxGraphModel dx="1500" dy="900" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" '
        'arrows="1" fold="1" page="1" pageScale="1" pageWidth="1480" pageHeight="%d" math="0" shadow="0">'
        '<root><mxCell id="0"/><mxCell id="1" parent="0"/>%s</root></mxGraphModel></diagram></mxfile>'
        % (nid(), ph, body))


# =====================================================================
# FIG A: EPP standalone アーキテクチャ
#   client → Envoy(8081) → ext_proc(gRPC) → EPP scheduler → 選んだ Pod IP:8000
#   EPP が InferencePool の 8 endpoint からメトリクスを読んで 1 つ選ぶ
# =====================================================================
def fig_arch():
    c = [hdr("同じ 8 Pod・同じ EPP 経路のまま、scheduling profile を差し替えてルーティングだけを比較する")]
    # client
    c += [icon("users", 60, 360, 70, 70, fill=SUB, label="")]
    c += [txt("128 テナント\n(adapter-0..127)", 30, 432, 150, 40, size=14, color=SUB, align="center")]
    # bench note
    c += [txt("計測は同一ノードの bench Pod から\n(port-forward 不可: TTFT が歪む)", 28, 478, 200, 44, size=11, color=WARN, italic=True, align="center")]

    # EPP box (Envoy + scheduler の 2 コンテナ)
    EX, EY, EW, EH = 250, 250, 360, 300
    c += [boxr(EX, EY, EW, EH, fill="#F7F9FA", stroke=TEAL, sw=2)]
    c += [txt("EPP Pod  (llm-d-inference-scheduler v0.8.0)", EX+16, EY+12, EW-30, 22, size=15, bold=True, color=TEAL)]
    # Envoy sidecar
    c += [boxr(EX+24, EY+48, EW-48, 96, fill=FILL, stroke=TEAL, sw=1.5)]
    c += [txt("Envoy sidecar  :8081", EX+38, EY+58, EW-70, 20, size=14, bold=True, color=INK)]
    c += [txt("OpenAI API の入口。ext_proc で\nEPP に endpoint 選択を委譲し、\nORIGINAL_DST で当該 Pod へ転送", EX+38, EY+82, EW-70, 56, size=12, color=SUB)]
    # arrow envoy->scheduler
    c += [arrow(EX+EW//2, EY+148, EX+EW//2, EY+176, color=TEAL, sw=2, label="ext_proc gRPC :9002", lblsize=11, lblcolor=TEAL)]
    # EPP scheduler
    c += [boxr(EX+24, EY+182, EW-48, 96, fill="#EAF1F1", stroke=TEAL, sw=1.5)]
    c += [txt("EPP scheduler  :9002", EX+38, EY+192, EW-70, 20, size=14, bold=True, color=INK)]
    c += [txt("InferencePool の 8 endpoint から\nscheduling profile に従い 1 つ選ぶ\n(metrics-data-source が /metrics を読む)", EX+38, EY+216, EW-70, 56, size=12, color=SUB)]

    c += [arrow(132, 395, EX, 395, color=SUB, sw=2.5)]

    # InferencePool + 8 Pods
    PX, PY, PW, PH = 700, 150, 700, 540
    c += [boxr(PX, PY, PW, PH, fill=BG, stroke=GREY, sw=1.4, dashed=True)]
    c += [txt("InferencePool  (selector app=mt-lora-pool, targetPort 8000)", PX+16, PY+12, PW-30, 22, size=15, bold=True, color=SUB)]
    c += [txt("同一ノードの 8 GPU に 8 Pod を集約 / 各 Pod に adapter 0..127 を登録済み", PX+16, PY+38, PW-30, 20, size=12, color=SUB, italic=True)]
    xs = [PX+30, PX+250, PX+470]
    ys = [PY+80, PY+250, PY+420]
    gi = 0
    for ry, yy in enumerate(ys):
        for cx, xx in enumerate(xs):
            if gi >= 8: break
            gi += 1
            c += [boxr(xx, yy, 190, 130, fill=BG, stroke=TEAL, sw=1.4)]
            c += [txt("Pod %d  (GPU %d)" % (gi-1, gi-1), xx+12, yy+8, 170, 18, size=12, bold=True, color=TEAL)]
            c += [icon("ec2", xx+10, yy+30, 34, 34, fill=TEAL, label="")]
            c += [txt("vLLM TP=1\n31B fp8 :8000", xx+52, yy+32, 130, 36, size=11, color=INK)]
            c += [boxr(xx+12, yy+92, 166, 28, fill="#F2F4F6", stroke=GREY, sw=1, arc=4)]
            c += [txt("LoRA hot-set max_loras=32", xx+18, yy+98, 156, 16, size=9, color=SUB)]
    # EPP -> pool (代表矢印)。Pod 行と被らないよう row0(230-360)/row1(400-) の隙間 y=380 に入れる。
    c += [arrow(EX+EW, 380, PX, 380, color=TEAL, sw=2.5)]
    c += [txt("EPP が選んだ Pod IP:8000 へ転送  (x-gateway-destination-endpoint ヘッダ)",
              PX+12, 366, PW-24, 26, size=12, italic=True, color=TEAL, align="center")]

    # 下部 takeaway 帯 (1 行)
    c += [boxr(52, 720, 1360, 56, fill="#1A2027", stroke="none", arc=6)]
    c += [txt("Envoy + EPP は全条件で共通。差し替えるのは EPP の scheduling profile だけ → ルーティング戦略の差だけを公平に抽出できる",
              72, 734, 1320, 30, size=16, bold=True, color="#FFFFFF")]
    save("llmd_epp_arch.xml", c, ph=800)


# =====================================================================
# FIG B: 3 profile の scorer 構成
# =====================================================================
def fig_profiles():
    c = [hdr("EPP の scheduling profile を 3 通り用意し、ConfigMap 差し替え + rollout restart だけで切り替える")]
    cols = [
        ("rr", "RR (baseline)", "#5A6B7B", "#F7F9FA",
         ["random-picker のみ", "scorer 無効 ≒ round-robin", "EPP 経路自体の中立性を測る"],
         []),
        ("affinity", "affinity 単独", "#B0563A", "#FBF3F0",
         ["lora-affinity-scorer (w=1)", "max-score-picker",
          "要求 adapter を既に持つ Pod を最優先"],
         ["人気テナントを同じ Pod に\n過集中 → 高負荷で崩壊"]),
        ("full", "full (llm-d 代表)", "#2D6E6E", "#EAF1F1",
         ["queue-scorer (w=2)", "kv-cache-utilization (w=2)",
          "prefix-cache-scorer (w=3)", "lora-affinity-scorer (w=3)", "max-score-picker"],
         ["affinity の局所性 +\nqueue/kv で負荷分散"]),
    ]
    x0 = 70; w = 430; gap = 18
    for i, (key, title, accent, fillc, scorers, note) in enumerate(cols):
        x = x0 + i * (w + gap)
        c += [boxr(x, 150, w, 540, fill=fillc, stroke=accent, sw=2)]
        c += [pill("profile-%s" % key, x+20, 168, 170, 36, fill=accent, size=15)]
        c += [txt(title, x+200, 174, w-210, 26, size=18, bold=True, color=accent)]
        # scorer chips
        yy = 232
        c += [txt("plugins (scheduling profile)", x+24, yy, w-40, 18, size=12, bold=True, color=SUB)]
        yy += 28
        for s in scorers:
            c += [boxr(x+24, yy, w-48, 40, fill="#FFFFFF", stroke=GREY, sw=1, arc=6)]
            c += [txt(s, x+36, yy+10, w-70, 22, size=14, color=INK)]
            yy += 50
        # note
        if note:
            ny = 540
            c += [boxr(x+24, ny, w-48, 90, fill="#FFFFFF", stroke=accent, sw=1.4, dashed=True, arc=6)]
            c += [txt(("結果: " + note[0]), x+36, ny+14, w-70, 64, size=14, bold=True, color=accent)]
    # bottom takeaway
    c += [boxr(52, 720, 1360, 56, fill="#1A2027", stroke="none", arc=6)]
    c += [txt("GIE v1.5.0 の既定 profile は prefix-cache のみで lora-affinity を含まない → 明示的に足すのが必須",
              72, 734, 1320, 30, size=16, bold=True, color="#FFFFFF")]
    save("llmd_profiles.xml", c, ph=800)


# =====================================================================
# FIG C: はまりポイント
# =====================================================================
def fig_pitfalls():
    c = [hdr("8 Pod + EPP を実機で動かすときに踏んだ 4 つの落とし穴と対処")]
    items = [
        ("privileged で GPU 分離が崩れる",
         "securityContext.privileged: true を付けると device-plugin の GPU 分離が無効化され、"
         "8 Pod 全部が cuda:0 を奪い合って OOM クラッシュ。",
         "privileged を外す → 各 Pod に別 GPU が割り当たる (275GB/Pod)"),
        ("LoRA 並列登録で engine が詰まる",
         "register の 50 並列 POST は vLLM 内部の LoRA load 直列化と競合し、逆に遅くなり "
         "completion も 30s タイムアウト。curl に -m が無くゾンビ大量発生。",
         "逐次登録 (-m 付き) に変更。既ロードは HTTP 400 が即返り冪等にスキップ"),
        ("lora_requests_info が空でエラー",
         "EPP 起動直後は vllm:lora_requests_info の sample 行が出ず "
         "(LoRA リクエストを 1 度も捌く前は HELP/TYPE のみ)、affinity scorer が読めない。",
         "profile 切替後にウォームアップを 1 周流して gauge を populate"),
        ("計測経路でフェアネスが崩れる",
         "port-forward 経由 (Mac から) で計測すると TTFT が不当に膨らみ、前回 1Pod 計測と"
         "整合しない。同一ノード Pod 間は実測 0.9ms。",
         "vLLM と同一ノード・同一イメージの bench Pod から計測"),
    ]
    xs = [70, 750]; ys = [150, 440]
    k = 0
    for ry, yy in enumerate(ys):
        for cx, xx in enumerate(xs):
            title, problem, fix = items[k]; k += 1
            c += [boxr(xx, yy, 660, 270, fill=BG, stroke=GREY, sw=1.4)]
            # 警告ヘッダ
            c += [boxr(xx, yy, 660, 50, fill="#FBF3F0", stroke="none", arc=6)]
            c += [txt("[落とし穴 %d]  %s" % (k, title), xx+20, yy+13, 620, 26, size=17, bold=True, color=WARN)]
            c += [txt(problem, xx+20, yy+64, 620, 120, size=14, color=INK)]
            # 対処
            c += [boxr(xx+16, yy+186, 628, 64, fill=FILL, stroke=TEAL, sw=1.3, arc=6)]
            c += [txt("[対処] " + fix, xx+30, yy+198, 600, 44, size=14, bold=True, color=TEAL)]
    save("llmd_pitfalls.xml", c, ph=740)


# =====================================================================
# FIG D: 結果の要点 (テキストで読ませる版。実データ折れ線は make_figures fig10)
# =====================================================================
def fig_result():
    c = [hdr("計測結果: lora-affinity 単独は高負荷で崩壊、queue/kv と合成した full が最良")]
    # 3 つの要点カード
    cards = [
        ("整合性 [OK]", TEAL, FILL,
         "構成を 1Pod8proc → 8Pod に変えても\nTTFT / TPOT / Goodput は前回と一致。\n既存スライドの数値・損益分岐は不変。"),
        ("affinity 単独 [NG]", WARN, "#FBF3F0",
         "concurrency 512 で goodput 72 req/s に崩壊\n(SLO 91.8%)。人気テナントの過集中で\n負荷分散が効かなくなる。"),
        ("full [BEST]", "#1F5A5A", "#E3EEEC",
         "concurrency 512 で goodput 124 req/s・\nSLO 100% で全条件中トップ。affinity の\n局所性を queue/kv balance が補完。"),
    ]
    x0 = 70; w = 432; gap = 17
    for i, (t, accent, fillc, body) in enumerate(cards):
        x = x0 + i * (w + gap)
        c += [boxr(x, 150, w, 200, fill=fillc, stroke=accent, sw=2)]
        c += [txt(t, x+24, 166, w-40, 30, size=20, bold=True, color=accent)]
        c += [txt(body, x+24, 208, w-44, 130, size=15, color=INK)]

    # goodput 表 (conc 512 抜粋) — 数字で締める
    TY = 386
    c += [txt("飽和点 (concurrency 512) の goodput req/s と SLO 達成率", 70, TY, 900, 24, size=16, bold=True, color=INK)]
    rows = [
        ("direct-rr (8Pod 直接RR)", "101.3", "98.6%", SUB),
        ("direct-affinity (静的シャード)", "117.8", "98.8%", SUB),
        ("EPP rr (random)", "119.9", "99.2%", SUB),
        ("EPP affinity 単独", "72.4", "91.8%", WARN),
        ("EPP full (全部入り)", "123.9", "100%", TEAL),
    ]
    ry = TY + 36; rh = 52
    # ヘッダ行
    c += [boxr(70, ry, 1340, 40, fill="#F2F4F6", stroke=GREY, sw=1, arc=4)]
    c += [txt("条件", 90, ry+9, 600, 22, size=14, bold=True, color=SUB)]
    c += [txt("goodput (req/s)", 760, ry+9, 260, 22, size=14, bold=True, color=SUB, align="center")]
    c += [txt("SLO 達成率", 1080, ry+9, 260, 22, size=14, bold=True, color=SUB, align="center")]
    ry += 48
    for name, gp, slo, col in rows:
        emph = (name.startswith("EPP full") or name.startswith("EPP affinity"))
        c += [boxr(70, ry, 1340, rh-8, fill=("#FFFFFF" if not emph else ("#E3EEEC" if "full" in name else "#FBF3F0")),
                   stroke=(col if emph else GREY), sw=(1.6 if emph else 1), arc=4)]
        c += [txt(name, 90, ry+10, 660, 24, size=15, bold=emph, color=(col if emph else INK))]
        c += [txt(gp, 760, ry+8, 260, 26, size=18, bold=True, color=col, align="center")]
        c += [txt(slo, 1080, ry+10, 260, 24, size=15, bold=emph, color=col, align="center")]
        ry += rh
    save("llmd_result.xml", c, ph=ry+30)


if __name__ == "__main__":
    fig_arch()
    fig_profiles()
    fig_pitfalls()
    fig_result()
    print("[OK] generated in", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f)
