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

def rhombus(val, x, y, w, h, fill=FILL, stroke=TEAL, sw=2, size=16, fc=None, bold=True):
    st = ("rhombus;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;strokeWidth=%s;"
          "fontSize=%d;fontColor=%s;align=center;verticalAlign=middle;" % (fill, stroke, sw, size, fc or stroke))
    if bold: st += "fontStyle=1;"
    return cell(val, st, x, y, w, h)

def trapezoid(val, x, y, w, h, fill=FILL, stroke=TEAL, sw=2, size=16, fc=None, bold=True, direction="north"):
    # 台形。direction で広い辺の向きを指定 (draw.io trapezoid は既定で下辺が広い)。
    st = ("shape=trapezoid;whiteSpace=wrap;html=1;fixedSize=1;fillColor=%s;strokeColor=%s;strokeWidth=%s;"
          "fontSize=%d;fontColor=%s;align=center;verticalAlign=middle;direction=%s;"
          % (fill, stroke, sw, size, fc or stroke, direction))
    if bold: st += "fontStyle=1;"
    return cell(val, st, x, y, w, h)

def plain_box(val, x, y, w, h, fill=BG, stroke=GREY, sw=1, size=16, fc=INK, bold=False, align="center"):
    st = ("rounded=0;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;strokeWidth=%s;"
          "fontSize=%d;fontColor=%s;align=%s;verticalAlign=middle;" % (fill, stroke, sw, size, fc, align))
    if bold: st += "fontStyle=1;"
    return cell(val, st, x, y, w, h)

def note_file(val, x, y, w, h, fill="#FFFDF5", stroke="#C9A24A", sw=1.6, size=14, fc=INK, align="left"):
    # 設定ファイル風 (右上が折れた note シェイプ)。YAML サンプルを入れる箱。
    st = ("shape=note;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;strokeWidth=%s;size=18;"
          "fontSize=%d;fontColor=%s;align=%s;verticalAlign=top;spacingLeft=8;spacingTop=6;fontFamily=Courier New;"
          % (fill, stroke, sw, size, fc, align))
    return cell(val, st, x, y, w, h)

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
    # 全フォント +8pt 方針。Pod は上段 (Pod 0/1/2) のみフル詳細、Pod 3-7 はコンパクト。
    c = [hdr("同じ 8 Pod・同じ EPP 経路のまま、scheduling profile を差し替えてルーティングだけを比較する")]
    # client
    c += [icon("users", 56, 360, 78, 78, fill=SUB, label="")]
    c += [txt("128 テナント\n(adapter-0..127)", 20, 446, 170, 48, size=22, color=SUB, align="center")]
    # bench note
    c += [txt("計測は同一ノードの bench Pod から\n(port-forward 不可: TTFT が歪む)", 16, 502, 220, 56, size=19, color=WARN, italic=True, align="center")]

    # EPP box (Envoy + scheduler の 2 コンテナ)。ルーティングアルゴリズム (scorer) も内部に表現。
    # 箱に余裕を持たせ、上下スペースを使って縦に広げる (EY=176, EH=512 -> 下端 688)。
    EX, EY, EW, EH = 244, 176, 392, 512
    c += [boxr(EX, EY, EW, EH, fill="#F7F9FA", stroke=TEAL, sw=2)]
    c += [txt("EPP Pod", EX+18, EY+12, EW-30, 28, size=21, bold=True, color=TEAL)]
    c += [txt("llm-d-inference-scheduler v0.8.0", EX+130, EY+16, EW-140, 24, size=15, color=SUB, italic=True)]
    # Envoy sidecar
    c += [boxr(EX+22, EY+52, EW-44, 104, fill=FILL, stroke=TEAL, sw=1.5)]
    c += [txt("Envoy sidecar  :8081", EX+38, EY+62, EW-72, 28, size=20, bold=True, color=INK)]
    c += [txt("OpenAI API の入口。ext_proc で EPP に\nendpoint 選択を委譲、ORIGINAL_DST で転送", EX+38, EY+92, EW-72, 52, size=17, color=SUB)]
    # arrow envoy->scheduler
    c += [arrow(EX+EW//2, EY+158, EX+EW//2, EY+186, color=TEAL, sw=2, label="ext_proc gRPC :9002", lblsize=16, lblcolor=TEAL)]
    # EPP scheduler (上部) + scorer リスト (ルーティングアルゴリズム本体)
    c += [boxr(EX+22, EY+192, EW-44, 296, fill="#EAF1F1", stroke=TEAL, sw=1.5)]
    c += [txt("EPP scheduler  :9002", EX+38, EY+202, EW-72, 28, size=20, bold=True, color=INK)]
    # 説明文: 短くして確実に 2 行。高さ 52px (2 行ぶん) を確保し見出しと干渉させない。
    c += [txt("各 Pod の /metrics を読み、scorer 合算で\nスコア最大の Pod を 1 つ選ぶ", EX+38, EY+232, EW-72, 52, size=16, color=SUB)]
    # scorer チップ群 (差し替え対象 = ルーティングアルゴリズム)
    c += [txt("scorer (= 差し替え対象):", EX+38, EY+292, EW-72, 24, size=16, bold=True, color=TEAL)]
    scs = [("lora-affinity", TEAL), ("prefix-cache", TEALL), ("kv-cache-util", TEALL), ("queue", TEALL)]
    sx = EX+38; sy = EY+324
    for i, (name, col) in enumerate(scs):
        cx = sx + (i % 2) * 164
        cy = sy + (i // 2) * 50
        c += [boxr(cx, cy, 152, 42, fill="#FFFFFF", stroke=col, sw=1.3, arc=8)]
        c += [txt(name, cx, cy+9, 152, 24, size=16, color=col, align="center", bold=(name == "lora-affinity"))]
    c += [txt("→ picker が最高スコアの Pod を採用", EX+38, sy+110, EW-72, 24, size=16, italic=True, color=SUB)]

    c += [arrow(134, 399, EX, 399, color=SUB, sw=2.5)]

    # InferencePool + 8 Pods。EPP と上下端を揃え、Pod 箱も広げる。
    PX, PY, PW, PH = 700, 176, 700, 512
    c += [boxr(PX, PY, PW, PH, fill=BG, stroke=GREY, sw=1.4, dashed=True)]
    c += [txt("InferencePool  (selector app=mt-lora-pool, targetPort 8000)", PX+16, PY+14, PW-30, 28, size=21, bold=True, color=SUB)]
    c += [txt("同一ノードの 8 GPU に 8 Pod を集約 / 各 Pod に adapter 0..127 を登録済み", PX+16, PY+46, PW-30, 26, size=18, color=SUB, italic=True)]

    # --- 上段 (Pod 0/1/2) フル詳細, 大きめ・余裕あり ---
    # 箱を 210px 幅に広げ、vLLM テキストと灰色ボックスを枠内に余裕で収める。
    full_xs = [PX+24, PX+254, PX+484]
    fy = PY+92
    for i, xx in enumerate(full_xs):
        c += [boxr(xx, fy, 210, 188, fill=BG, stroke=TEAL, sw=1.6)]
        c += [txt("Pod %d  (GPU %d)" % (i, i), xx+14, fy+10, 190, 24, size=19, bold=True, color=TEAL)]
        c += [icon("ec2", xx+12, fy+38, 42, 42, fill=TEAL, label="")]
        c += [txt("vLLM TP=1\n31B fp8\n:8000", xx+60, fy+38, 140, 60, size=17, color=INK)]
        c += [boxr(xx+12, fy+110, 186, 68, fill="#F2F4F6", stroke=GREY, sw=1, arc=4)]
        c += [txt("LoRA hot-set\nmax_loras=32\n+ CPU pool 1000", xx+22, fy+116, 174, 58, size=14, color=SUB)]
    c += [txt("(同じ設定の vLLM レプリカが 8 個)", full_xs[0], fy+196, 600, 22, size=15, color=SUB, italic=True)]

    # --- 下段 (Pod 3-7) コンパクト: ラベル + アイコンだけ ---
    comp_xs = [PX+24, PX+160, PX+296, PX+432, PX+568]
    cyy = PY+396
    for j, xx in enumerate(comp_xs):
        idx = j + 3
        c += [boxr(xx, cyy, 110, 100, fill=BG, stroke=TEAL, sw=1.3)]
        c += [txt("Pod %d" % idx, xx+10, cyy+10, 92, 24, size=18, bold=True, color=TEAL)]
        c += [txt("GPU %d" % idx, xx+10, cyy+34, 92, 20, size=15, color=SUB)]
        c += [icon("ec2", xx+36, cyy+54, 36, 36, fill=TEAL, label="")]

    # EPP -> pool (代表矢印)。full行(268-448)と compact行(572-)の隙間 y=512 に通す。
    c += [arrow(EX+EW, 512, PX, 512, color=TEAL, sw=2.5)]
    c += [txt("EPP が選んだ Pod IP:8000 へ転送  (x-gateway-destination-endpoint ヘッダ)",
              PX+12, 520, PW-24, 24, size=16, italic=True, color=TEAL, align="left")]

    # 下部 takeaway 帯 (1 行)
    c += [boxr(52, 712, 1360, 60, fill="#1A2027", stroke="none", arc=6)]
    c += [txt("Envoy + EPP は全条件で共通。差し替えるのは EPP の scheduling profile だけ → ルーティング戦略の差だけを公平に抽出できる",
              72, 726, 1320, 34, size=21, bold=True, color="#FFFFFF")]
    save("llmd_epp_arch.xml", c, ph=800)


# =====================================================================
# FIG B0: llm-d ルーティングロジック (初学者向け・採点メカニズムを具体例で)
#   「各 scorer が候補 Pod を 0〜1 で採点 → 重み付き合計が最大の Pod へ送る」
# =====================================================================
def fig_routing_logic():
    # 全フォント +4pt 版。列幅・行高・ページ高も比例して拡大しはみ出しを防ぐ。
    c = [hdr("llm-d のルーティング = 各 scorer が候補 Pod を 0〜1 で採点し、重み付き合計が最大の Pod へ送る")]

    # --- 左: 入ってくるリクエスト ---
    c += [icon("users", 56, 312, 84, 84, fill=SUB, label="")]
    c += [boxr(36, 412, 336, 110, fill=FILL, stroke=TEAL, sw=2)]
    c += [txt("テナント 5 のリクエスト", 54, 424, 306, 30, size=23, bold=True, color=INK)]
    c += [txt("model: adapter-5\n(このテナント専用 LoRA)", 54, 458, 306, 54, size=21, color=SUB)]
    c += [arrow(204, 412, 204, 372, color=SUB, sw=2.5)]
    c += [txt("EPP が候補 Pod を採点 →", 36, 540, 336, 28, size=21, italic=True, color=TEAL)]

    # --- 採点表 --- (列幅を広げて +4pt でも収まるように)
    TX = 396
    cols = [("候補 Pod", 232), ("lora-affinity\n(重み 3)", 208), ("queue 空き\n(重み 2)", 188),
            ("kv 空き\n(重み 2)", 168), ("重み付き合計", 224)]
    c += [txt("例: 同じ 3 Pod を 3 つの観点で採点する", TX+6, 150, 900, 30, size=22, bold=True, color=INK)]
    hy = 188
    hx = TX
    for name, wdt in cols:
        c += [boxr(hx, hy, wdt-8, 70, fill="#ECEFF2", stroke=GREY, sw=1, arc=4)]
        c += [txt(name, hx+6, hy+12, wdt-20, 52, size=20, bold=True, color=SUB, align="center")]
        hx += wdt
    # 行データ: (Pod名, 補足, affinity, affinityラベル, queue, queueラベル, kv, kvラベル, 合計, winner)
    rows = [
        ("Pod A", "adapter-5 あり", 1.0, "適合 1.0", 0.1, "満杯 0.1", 0.2, "逼迫 0.2", "3.6", False),
        ("Pod B", "adapter-5 あり", 1.0, "適合 1.0", 0.9, "空き 0.9", 0.8, "空き 0.8", "6.4", True),
        ("Pod C", "持っていない", 0.2, "不適合 0.2", 0.9, "空き 0.9", 0.9, "空き 0.9", "4.2", False),
    ]
    ry = 266
    rh = 96
    for podn, sub, aff, afl, q, ql, kv, kvl, total, win in rows:
        rowfill = "#E3EEEC" if win else BG
        rowstroke = TEAL if win else GREY
        sw = 2 if win else 1
        cx = TX
        # Pod 名セル
        c += [boxr(cx, ry, cols[0][1]-8, rh-8, fill=rowfill, stroke=rowstroke, sw=sw, arc=4)]
        c += [txt(podn, cx+14, ry+12, cols[0][1]-30, 30, size=24, bold=True, color=(TEAL if win else INK))]
        c += [txt(sub, cx+14, ry+50, cols[0][1]-30, 28, size=20, color=SUB)]
        cx += cols[0][1]
        # 3 つの scorer セル (ラベル + 0〜1 バー)
        for val, lab, wdt in [(aff, afl, cols[1][1]), (q, ql, cols[2][1]), (kv, kvl, cols[3][1])]:
            c += [boxr(cx, ry, wdt-8, rh-8, fill=rowfill, stroke=rowstroke, sw=sw, arc=4)]
            c += [txt(lab, cx+10, ry+14, wdt-26, 26, size=20, color=INK, align="center")]
            barw = wdt - 40
            c += [boxr(cx+16, ry+52, barw, 20, fill="#FFFFFF", stroke=GREY, sw=1, arc=3)]
            c += [boxr(cx+16, ry+52, max(6, int(barw*val)), 20, fill=(TEAL if val >= 0.6 else (WARN if val <= 0.3 else TEALL)), stroke="none", arc=3)]
            cx += wdt
        # 合計セル (winner は数字を上寄せにして下部に「採用」ラベルをセル内に収める)
        c += [boxr(cx, ry, cols[4][1]-8, rh-8, fill=rowfill, stroke=rowstroke, sw=sw, arc=4)]
        if win:
            c += [txt(total, cx+12, ry+8, cols[4][1]-28, 40, size=32, bold=True, color=TEAL, align="center")]
            c += [txt("← 採用 (最大)", cx+4, ry+rh-34, cols[4][1]-16, 26, size=20, bold=True, color=TEAL, align="center")]
        else:
            c += [txt(total, cx+12, ry+20, cols[4][1]-28, 44, size=34, bold=True, color=SUB, align="center")]
        ry += rh
    # 重みの式
    c += [txt("合計 = 3 × lora-affinity + 2 × queue空き + 2 × kv空き   (full profile の重み)",
              TX, ry+10, 1000, 28, size=20, italic=True, color=SUB)]

    # --- 下: 学び 2 つ (なぜ affinity 単独はダメで full が良いか) ---
    by = 624
    c += [boxr(36, by, 694, 140, fill="#FBF3F0", stroke=WARN, sw=1.6)]
    c += [txt("affinity だけ で採点すると", 54, by+20, 664, 30, size=22, bold=True, color=WARN)]
    c += [txt("A と B が同点 → 満杯の A を選び詰まる", 54, by+62, 664, 30, size=20, color=INK)]
    c += [boxr(748, by, 694, 140, fill="#E3EEEC", stroke=TEAL, sw=1.6)]
    c += [txt("full (affinity + queue + kv) なら", 766, by+16, 664, 30, size=22, bold=True, color=TEAL)]
    c += [txt("adapter あり かつ 空いている B を選ぶ", 766, by+56, 664, 30, size=20, color=INK)]
    c += [txt("= 局所性と負荷分散を両立", 766, by+92, 664, 30, size=20, italic=True, color=TEAL)]
    save("llmd_routing_logic.xml", c, ph=792)


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
        c += [boxr(x, 144, w, 552, fill=fillc, stroke=accent, sw=2)]
        c += [pill("profile-%s" % key, x+22, 162, 186, 40, fill=accent, size=17)]
        c += [txt(title, x+220, 168, w-230, 30, size=20, bold=True, color=accent)]
        # scorer chips
        yy = 226
        c += [txt("plugins (scheduling profile)", x+26, yy, w-44, 22, size=15, bold=True, color=SUB)]
        yy += 32
        for s in scorers:
            c += [boxr(x+26, yy, w-52, 46, fill="#FFFFFF", stroke=GREY, sw=1, arc=6)]
            c += [txt(s, x+40, yy+11, w-78, 24, size=17, color=INK)]
            yy += 54
        # note (結果): full の 5 scorer 列でも被らないよう下端 ny=556 に固定
        if note:
            ny = 556
            c += [boxr(x+26, ny, w-52, 122, fill="#FFFFFF", stroke=accent, sw=1.4, dashed=True, arc=6)]
            c += [txt("結果", x+40, ny+12, w-78, 24, size=16, bold=True, color=accent)]
            c += [txt(note[0], x+40, ny+44, w-78, 72, size=16, bold=True, color=accent)]
    # bottom takeaway
    c += [boxr(52, 716, 1360, 60, fill="#1A2027", stroke="none", arc=6)]
    c += [txt("GIE v1.5.0 の既定 profile は prefix-cache のみで lora-affinity を含まない → 明示的に足すのが必須",
              72, 730, 1320, 34, size=20, bold=True, color="#FFFFFF")]
    save("llmd_profiles.xml", c, ph=800)


# =====================================================================
# FIG C: はまりポイント
# =====================================================================
def fig_pitfalls():
    # 全テキスト 20pt 以上。2x2 カード、長文は要点だけに絞って枠内に収める。
    c = [hdr("8 Pod + EPP を実機で動かすときに踏んだ 4 つの落とし穴と対処")]
    items = [
        ("privileged で GPU 分離が崩れる",
         ["securityContext.privileged: true は",
          "device-plugin の GPU 分離を無効化。",
          "8 Pod 全部が cuda:0 を奪い OOM。"],
         "privileged を外す\n→ 各 Pod に別 GPU (275GB)"),
        ("LoRA 並列登録で engine が詰まる",
         ["50 並列 POST は vLLM の LoRA load",
          "直列化と競合し逆に遅い + 30s",
          "タイムアウト + curl ゾンビ大量発生。"],
         "逐次登録 (-m 付き) に変更\n既ロードは HTTP 400 で冪等スキップ"),
        ("lora_requests_info が空でエラー",
         ["EPP 起動直後は gauge の sample 行が",
          "出ず (LoRA を 1 度も捌く前)、",
          "affinity scorer が値を読めない。"],
         "profile 切替後にウォームアップ 1 周\n→ gauge を populate"),
        ("計測経路でフェアネスが崩れる",
         ["port-forward (Mac から) は TTFT が",
          "膨らみ前回 1Pod 計測と不整合。",
          "同一ノード Pod 間は実測 0.9ms。"],
         "vLLM と同一ノードの bench Pod\nから計測 (port-forward 不可)"),
    ]
    cw, ch = 672, 296
    xs = [56, 752]; ys = [148, 468]
    k = 0
    for yy in ys:
        for xx in xs:
            title, lines, fix = items[k]; k += 1
            c += [boxr(xx, yy, cw, ch, fill=BG, stroke=GREY, sw=1.4)]
            # 警告ヘッダ
            c += [boxr(xx, yy, cw, 56, fill="#FBF3F0", stroke="none", arc=6)]
            c += [txt("落とし穴 %d:  %s" % (k, title), xx+22, yy+15, cw-40, 30, size=22, bold=True, color=WARN)]
            # 問題 (3 行を個別 txt で確実に)
            ty = yy+72
            for ln in lines:
                c += [txt(ln, xx+22, ty, cw-44, 28, size=20, color=INK)]
                ty += 32
            # 対処 (見出し + 2 行ぶんを 100px ボックスに収める)
            c += [boxr(xx+18, yy+180, cw-36, 102, fill=FILL, stroke=TEAL, sw=1.3, arc=6)]
            c += [txt("対処", xx+32, yy+188, cw-64, 26, size=18, bold=True, color=TEAL)]
            c += [txt(fix, xx+32, yy+216, cw-64, 60, size=20, bold=True, color=TEAL)]
    save("llmd_pitfalls.xml", c, ph=792)


# =====================================================================
# FIG D: 結果の要点 (テキストで読ませる版。実データ折れ線は make_figures fig10)
# =====================================================================
def fig_result():
    # 全テキスト 20pt 以上。3 要点カード (各3行) + goodput 表 (5行)。
    c = [hdr("計測結果: lora-affinity 単独は高負荷で崩壊、queue/kv と合成した full が最良")]
    # 3 つの要点カード
    cards = [
        ("整合性 OK", TEAL, FILL,
         ["1Pod8proc → 8Pod に変えても", "TTFT/TPOT/Goodput は前回と一致。", "既存スライドの数値は不変。"]),
        ("affinity 単独 NG", WARN, "#FBF3F0",
         ["concurrency 512 で goodput 72 に崩壊", "(SLO 91.8%)。人気テナントの過集中で", "負荷分散が効かなくなる。"]),
        ("full BEST", "#1F5A5A", "#E3EEEC",
         ["concurrency 512 で goodput 124・", "SLO 100% で全条件トップ。affinity の", "局所性を queue/kv が補完。"]),
    ]
    x0 = 56; w = 444; gap = 18
    for i, (t, accent, fillc, lines) in enumerate(cards):
        x = x0 + i * (w + gap)
        c += [boxr(x, 150, w, 222, fill=fillc, stroke=accent, sw=2)]
        c += [txt(t, x+26, 166, w-44, 32, size=24, bold=True, color=accent)]
        ty = 210
        for ln in lines:
            c += [txt(ln, x+26, ty, w-48, 30, size=20, color=INK)]
            ty += 34

    # goodput 表 (conc 512 抜粋) — 数字で締める
    TY = 400
    c += [txt("飽和点 (concurrency 512) の goodput req/s と SLO 達成率", 56, TY, 1000, 28, size=22, bold=True, color=INK)]
    rows = [
        ("direct-rr (8Pod 直接RR)", "101.3", "98.6%", SUB),
        ("direct-affinity (静的シャード)", "117.8", "98.8%", SUB),
        ("EPP rr (random)", "119.9", "99.2%", SUB),
        ("EPP affinity 単独", "72.4", "91.8%", WARN),
        ("EPP full (全部入り)", "123.9", "100%", TEAL),
    ]
    LX, LW = 56, 1368
    ry = TY + 42; rh = 58
    # ヘッダ行
    c += [boxr(LX, ry, LW, 46, fill="#F2F4F6", stroke=GREY, sw=1, arc=4)]
    c += [txt("条件", LX+24, ry+11, 640, 26, size=20, bold=True, color=SUB)]
    c += [txt("goodput (req/s)", 760, ry+11, 300, 26, size=20, bold=True, color=SUB, align="center")]
    c += [txt("SLO 達成率", 1090, ry+11, 280, 26, size=20, bold=True, color=SUB, align="center")]
    ry += 54
    for name, gp, slo, col in rows:
        emph = (name.startswith("EPP full") or name.startswith("EPP affinity"))
        c += [boxr(LX, ry, LW, rh-8, fill=("#FFFFFF" if not emph else ("#E3EEEC" if "full" in name else "#FBF3F0")),
                   stroke=(col if emph else GREY), sw=(1.8 if emph else 1), arc=4)]
        c += [txt(name, LX+24, ry+12, 700, 28, size=20, bold=emph, color=(col if emph else INK))]
        c += [txt(gp, 760, ry+9, 300, 30, size=24, bold=True, color=col, align="center")]
        c += [txt(slo, 1090, ry+12, 280, 28, size=20, bold=emph, color=col, align="center")]
        ry += rh
    save("llmd_result.xml", c, ph=ry+28)


# =====================================================================
# FIG: 推論時にテナントコンテキストを LLM に入れる 2 つの直交する方法
#   左 = Retrieve (プロンプトに足す) / 右 = LoRA (weight に足す、薄い adapter B×A)
#   2 つは直交 = 別軸、組み合わせ可能。
# =====================================================================
def fig_tenant_context():
    # 全文字 20pt 以上。Retrieve(知識を入れ込む) / LoRA(低ランク adapter を足す) の 2 方法。
    # LoRA は台形 B/A で低ランク分解を表し、10x12 -> 10x2 + 2x12 = 120->44 (63%減) を具体例で示す。
    c = [hdr("テナント固有のコンテキストを LLM に与える方法は 2 つ。両者は直交し、併用できる")]

    PY, PH = 148, 392
    # --- 左パネル: Retrieve ---
    LX, PW = 56, 660
    c += [boxr(LX, PY, PW, PH, fill="#F7F9FA", stroke=SUB, sw=2)]
    c += [pill("方法 A", LX+24, PY+18, 150, 46, fill=SUB, size=21)]
    c += [txt("Retrieve", LX+190, PY+22, PW-200, 34, size=24, bold=True, color=SUB)]
    c += [txt("テナント固有のデータを外部ストアから取り出し、\n推論時に入力プロンプトへ入れ込む。", LX+28, PY+78, PW-56, 64, size=20, color=INK)]
    # 図: テナントDB → プロンプト → base model
    c += [icon("documents", LX+34, PY+168, 72, 72, fill=SUB, label="")]
    c += [txt("テナント別\nデータ", LX+18, PY+246, 150, 50, size=18, color=SUB, align="center")]
    c += [boxr(LX+200, PY+170, 290, 110, fill="#F2F4F6", stroke=GREY, sw=1.2, arc=6)]
    c += [txt("入力プロンプト", LX+214, PY+178, 270, 26, size=18, bold=True, color=INK)]
    c += [boxr(LX+214, PY+212, 262, 30, fill="#E7E2D6", stroke="#C9BFA6", sw=1, arc=4)]
    c += [txt("取り出したコンテキストを追記", LX+222, PY+215, 254, 24, size=15, color="#7A6E50")]
    c += [boxr(LX+214, PY+246, 150, 26, fill=FILL, stroke=TEAL, sw=1, arc=4)]
    c += [txt("ユーザの質問", LX+222, PY+248, 150, 22, size=14, color=TEAL)]
    c += [arrow(LX+108, PY+200, LX+200, PY+210, color=SUB, sw=2)]
    c += [arrow(LX+492, PY+222, LX+560, PY+222, color=SUB, sw=2)]
    c += [icon("ec2", LX+556, PY+188, 70, 70, fill=SUB, label="")]
    c += [txt("base model\n(共通)", LX+540, PY+262, 110, 50, size=16, color=SUB, align="center")]
    c += [txt("weight は触らず、毎回プロンプトに載せる\n→ 入力トークン (とコスト) が増える。", LX+28, PY+316, PW-56, 64, size=20, italic=True, color=SUB)]

    # --- 右パネル: LoRA ---
    RX = 764
    c += [boxr(RX, PY, PW, PH, fill="#EAF1F1", stroke=TEAL, sw=2)]
    c += [pill("方法 B", RX+24, PY+18, 150, 46, fill=TEAL, size=21)]
    c += [txt("LoRA", RX+190, PY+22, PW-200, 34, size=24, bold=True, color=TEAL)]
    c += [txt("テナント固有のデータを薄い adapter に学習し、\nbase の weight へ加算する。", RX+28, PY+78, PW-56, 64, size=20, color=INK)]
    # W + (B-A リボン) = W'。B,A を細い辺どうしで接続し砂時計型に (論文の標準形)。
    by = PY+154
    c += [plain_box("W", RX+30, by+2, 92, 96, fill="#FFFFFF", stroke=SUB, sw=2, size=30, fc=INK, bold=True)]
    c += [txt("+", RX+128, by+30, 28, 40, size=34, bold=True, color=TEAL, align="center")]
    # B = south (左広 d → 右狭 r), A = north (左狭 r → 右広 k) を隙間なく接続 = 砂時計リボン
    # (両端が広く中央がくびれる蝶ネクタイ = 論文の標準形。中央のくびれ = ランク r)
    rib_x = RX+162; rib_w = 88
    c += [trapezoid("B", rib_x, by+2, rib_w, 96, fill="#FFFFFF", stroke=TEAL, sw=2, size=24, direction="south")]
    c += [trapezoid("A", rib_x+rib_w, by+2, rib_w, 96, fill="#FFFFFF", stroke=TEAL, sw=2, size=24, direction="north")]
    # くびれ部 (=ランク r) の注記 (中央接続部の真下)
    c += [txt("くびれ = ランク r", rib_x+rib_w-70, by+100, 156, 24, size=16, color=TEAL, align="center")]
    c += [txt("=", RX+346, by+30, 28, 40, size=34, bold=True, color=TEAL, align="center")]
    c += [plain_box("W'", RX+380, by+2, 92, 96, fill=FILL, stroke=TEAL, sw=2, size=30, fc=TEAL, bold=True)]
    c += [txt("テナント版", RX+372, by+100, 108, 24, size=16, color=TEAL, align="center")]
    c += [txt("B×A の積で W と同じ形に戻る (薄い adapter = 数 MB)", RX+28, by+132, PW-56, 26, size=18, color=TEAL)]
    # 具体例 (数値)
    c += [boxr(RX+28, by+162, PW-56, 70, fill="#FFFFFF", stroke=TEAL, sw=1.4, dashed=True, arc=6)]
    c += [txt("例: 10×12 = 120 個  →  10×2 + 2×12 = 44 個", RX+44, by+170, PW-90, 28, size=20, bold=True, color=INK)]
    c += [txt("同じ 10×12 を再現できるのにデータ量は 63% 減", RX+44, by+200, PW-90, 26, size=18, color=TEAL)]

    # --- 下帯: 直交 + 接続 (短く) ---
    BY = 582
    c += [boxr(56, BY, 1368, 104, fill="#1A2027", stroke="none", arc=6)]
    c += [txt("2 つは直交し、併用もできる。", 80, BY+14, 1320, 30, size=22, bold=True, color="#FFFFFF")]
    c += [txt("プロンプトに入れる代わりに LoRA に焼く手もあるが、LoRA にも実行コストが乗る。"
              "どちらが有利かは実測しないと分からない。",
              80, BY+52, 1320, 30, size=20, color="#FFFFFF")]
    save("tenant_context.xml", c, ph=706)


# =====================================================================
# FIG: なぜ自前 routing でなく llm-d (GIE EndpointPicker) を使うのか (橋渡し)
# =====================================================================
def fig_why_llmd():
    c = [hdr("LoRA-aware ルーティングは「自前で書く」より「標準の OSS = llm-d / GIE」に乗る")]

    # 左: 自前 proxy / 右: llm-d EPP の対比 2 カラム
    PY, PH = 152, 300
    LX, PW = 56, 660
    # --- 左: 自前 ---
    c += [boxr(LX, PY, PW, PH, fill="#F7F9FA", stroke=SUB, sw=2)]
    c += [txt("自前 routing を書く", LX+28, PY+18, PW-56, 34, size=24, bold=True, color=SUB)]
    for k, line in enumerate([
        "consistent-hash proxy などを自作",
        "scorer の組み合わせ・優先度を都度実装",
        "メトリクス収集や heath check も自前",
        "→ 保守コスト大・再現性が低い"]):
        col = WARN if line.startswith("→") else INK
        c += [txt(("• " if not line.startswith("→") else "") + line, LX+34, PY+66+k*52, PW-66, 44, size=20, color=col, bold=line.startswith("→"))]

    # --- 右: llm-d EPP ---
    RX = 764
    c += [boxr(RX, PY, PW, PH, fill="#EAF1F1", stroke=TEAL, sw=2)]
    c += [txt("llm-d / GIE の EndpointPicker", RX+28, PY+18, PW-56, 34, size=24, bold=True, color=TEAL)]
    for k, line in enumerate([
        "Kubernetes SIG 標準の InferencePool / EPP",
        "scorer を差し替えるだけで戦略を変更",
        "メトリクス収集・採点は EPP が提供",
        "→ 保守が楽・実験の再現性が高い"]):
        col = TEAL if line.startswith("→") else INK
        c += [txt(("• " if not line.startswith("→") else "") + line, RX+34, PY+66+k*52, PW-66, 44, size=20, color=col, bold=line.startswith("→"))]

    # 中央の矢印 (自前 → 標準へ)
    c += [arrow(LX+PW+4, PY+PH//2, RX-4, PY+PH//2, color=TEAL, sw=3)]
    c += [txt("標準に\n乗る", LX+PW+8, PY+PH//2-44, 44, 40, size=16, bold=True, color=TEAL, align="center")]

    # 下帯: この後の流れ
    BY = 500
    c += [boxr(56, BY, 1368, 110, fill="#1A2027", stroke="none", arc=6)]
    c += [txt("だから本実験は llm-d (EPP) を使う。次から: EPP の構成 → ルーティングの全体像 → 採点ロジック → 実測。",
              80, BY+18, 1320, 32, size=22, bold=True, color="#FFFFFF")]
    c += [txt("ポイントは「profile を差し替えるだけで同じ 8 Pod・同じ経路のまま戦略を比較できる」こと (フェアな比較の土台)。",
              80, BY+58, 1320, 32, size=20, color="#FFFFFF")]
    save("why_llmd.xml", c, ph=636)


# =====================================================================
# FIG: Envoy + EPP アーキテクチャ (簡素版・データフロー骨格のみ)
#   詳細な scorer / adapter は別スライド (routing logic) が担うのでここでは省く。
# =====================================================================
def fig_epp_arch_simple():
    # GIE を「外枠 (標準が定める器)」として構造で表現。EPP と InferencePool は GIE の標準コンポーネント。
    # scheduling profile は設定ファイルの箱 (YAML サンプル) で見せ、EPP に差し込む形で「差し替え」を可視化。
    c = [hdr("EPP が送り先 Pod を選ぶ。判断ルールは設定ファイル (scheduling profile) で差し替える")]

    midy = 300
    # client
    c += [icon("users", 44, midy-44, 84, 84, fill=SUB, label="")]
    c += [txt("テナントの\nリクエスト", 18, midy+44, 140, 52, size=20, color=SUB, align="center")]
    c += [arrow(130, midy, 196, midy, color=SUB, sw=2.5)]

    # ===== GIE の外枠 (標準が定める器) =====
    GX, GY, GW, GH = 196, 150, 1228, 410
    c += [boxr(GX, GY, GW, GH, fill="#F4F7FA", stroke="#7A8CA0", sw=2, dashed=True)]
    c += [pill("GIE  (Gateway API Inference Extension) = Kubernetes 標準", GX+20, GY-2, 640, 40, fill="#7A8CA0", size=18)]

    # EPP Pod (GIE の標準コンポーネント。Envoy + EndpointPicker)
    EX, EY, EW, EH = GX+26, GY+58, 410, 322
    c += [boxr(EX, EY, EW, EH, fill="#FFFFFF", stroke=TEAL, sw=2.5)]
    c += [txt("EPP Pod", EX+20, EY+12, EW-36, 30, size=22, bold=True, color=TEAL)]
    c += [boxr(EX+22, EY+50, EW-44, 84, fill=FILL, stroke=TEAL, sw=1.5)]
    c += [txt("Envoy  :8081", EX+38, EY+58, EW-70, 28, size=21, bold=True, color=INK)]
    c += [txt("入口。ext_proc で EPP に委譲。", EX+38, EY+90, EW-70, 30, size=20, color=SUB)]
    c += [arrow(EX+EW//2, EY+136, EX+EW//2, EY+162, color=TEAL, sw=2.5, label="ext_proc", lblsize=19, lblcolor=TEAL)]
    c += [boxr(EX+22, EY+168, EW-44, 150, fill="#EAF1F1", stroke=TEAL, sw=1.5)]
    c += [txt("EndpointPicker (EPP)  :9002", EX+38, EY+176, EW-70, 28, size=21, bold=True, color=INK)]
    c += [txt("送り先を 1 つ選ぶ。判断ルールは:", EX+38, EY+206, EW-70, 26, size=20, color=SUB)]
    # 差し替え対象を EPP 内に明示 (金色で強調 → 矢印のターゲット)。scheduler 箱の内側に収める。
    c += [boxr(EX+38, EY+238, EW-76, 64, fill="#FFF7E0", stroke=GOLD, sw=1.6, arc=4)]
    c += [txt("scheduling\nprofile", EX+52, EY+246, EW-100, 50, size=21, bold=True, color="#9A7B1E")]

    # InferencePool (GIE の標準オブジェクト。8 Pod を束ねる)。EPP と下端を揃える (EH=322)。
    PX, PY2, PW2, PH2 = GX+GW-560, GY+58, 534, 322
    c += [boxr(PX, PY2, PW2, PH2, fill="#FBFCFD", stroke=GREY, sw=1.8)]
    c += [txt("InferencePool — 8 Pod", PX+20, PY2+12, PW2-36, 30, size=22, bold=True, color=SUB)]
    c += [txt("各 1 GPU で vLLM (Gemma 4 31B + LoRA)", PX+20, PY2+46, PW2-36, 26, size=18, color=SUB, italic=True)]
    gi=0
    for ry in range(2):
        for cx in range(4):
            gi+=1
            ix = PX+30 + cx*124
            iy = PY2+92 + ry*102
            c += [icon("ec2", ix, iy, 56, 56, fill=TEAL, label="")]
            c += [txt("Pod %d"%(gi-1), ix-12, iy+56, 80, 24, size=18, color=SUB, align="center")]
    # EPP -> pool (両ボックスの縦中心 = GY+58+322/2 = 369)
    amid = GY+58+161
    c += [arrow(EX+EW, amid, PX, amid, color=TEAL, sw=2.5)]
    c += [txt("転送", EX+EW+10, amid-30, 60, 24, size=19, italic=True, color=TEAL, align="center")]

    # ===== scheduling profile = 設定ファイルの箱 (EPP の判断ルールに差し込む) =====
    # YAML は whiteSpace=pre が壊れやすいので 1 行ずつ独立セルで配置 (はみ出し防止)。全 20pt。
    FX, FY, FW, FH = EX-8, 596, 600, 180
    c += [note_file("scheduling-profile.yaml", FX, FY, FW, FH, size=20)]
    yaml_lines = [
        "plugins:",
        "  - lora-affinity-scorer    weight: 3",
        "  - prefix-cache-scorer     weight: 3",
        "  - kv-cache-utilization    weight: 2",
        "  - queue-scorer            weight: 2",
        "  - max-score-picker",
    ]
    ly = FY+42
    for ln in yaml_lines:
        c += [cell(ln, "text;html=1;whiteSpace=nowrap;align=left;verticalAlign=middle;fontSize=20;fontColor=#5A6B7B;fontFamily=Courier New;",
                   FX+16, ly, FW-30, 22)]
        ly += 22
    # ファイル上端 → EPP 内「scheduling profile」金色箱の下辺への矢印
    c += [arrow(FX+260, FY, EX+EW//2, EY+302, color=GOLD, sw=3, dashed=True,
                label="この箱を差し替える", lblsize=20, lblcolor="#9A7B1E")]

    # 右下: 結論ひとこと
    c += [txt("profile を rr / affinity / full と差し替えるだけで、\n同じ 8 Pod・同じ経路のままルーティング戦略を比較できる。",
              PX, 612, PW2+40, 84, size=20, bold=True, color=INK)]
    save("epp_arch_simple.xml", c, ph=792)


if __name__ == "__main__":
    fig_arch()
    fig_profiles()
    fig_pitfalls()
    fig_result()
    fig_tenant_context()
    print("[OK] generated in", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f)
