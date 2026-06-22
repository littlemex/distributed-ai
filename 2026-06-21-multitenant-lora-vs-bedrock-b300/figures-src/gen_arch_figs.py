#!/usr/bin/env python3
"""洗練トーンの構成図3枚を draw.io XML で生成 (silo_vs_pool と同デザイン言語)。
 パレット: 背景 #FBFCFD / 枠グレー #D8DEE4 / アクセント teal #2D6E6E / 文字 #1A2027 /
           サブ #5A6B7B / 淡teal塗り #EAF1F1 / 警告系 muted #B0563A / takeaway 黒帯 #1A2027
 AWS shape: mxgraph.aws4.resourceIcon (resIcon=...users/ec2/...)
出力: /tmp/slides2/{approach,opsloop,topology}.xml
"""
import os
OUT="/tmp/slides2"; os.makedirs(OUT, exist_ok=True)
INK="#1A2027"; SUB="#5A6B7B"; GREY="#D8DEE4"; TEAL="#2D6E6E"; FILL="#EAF1F1"; WARN="#B0563A"; BG="#FBFCFD"
_id=[1]
def nid():
    _id[0]+=1; return "n%d"%_id[0]
def esc(s): return s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
def cell(val,style,x,y,w,h):
    return ('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'%(nid(),esc(val).replace("\n","&#10;"),style,x,y,w,h))
# 全体の文字を大きく読みやすく: フォントは一律 SCALE 倍。アイコンも大型化。
# title/takeaway は削除 -> 図本体を上に詰めて拡大。
SCALE=1.9
def fs(size): return int(round(size*SCALE))
def txt(val,x,y,w,h,size=13,bold=False,italic=False,color=INK,align="left",valign="top"):
    st="text;html=1;whiteSpace=wrap;align=%s;verticalAlign=%s;fontSize=%d;fontColor=%s;"%(align,valign,fs(size),color)
    if bold: st+="fontStyle=1;"
    elif italic: st+="fontStyle=2;"
    return cell(val,st,x,y,w,h)
def boxr(x,y,w,h,fill=BG,stroke=GREY,sw=1,arc=4,dashed=False):
    st="rounded=1;arcSize=%d;fillColor=%s;strokeColor=%s;strokeWidth=%s;"%(arc,fill,stroke,sw)
    if dashed: st+="dashed=1;"
    return cell("",st,x,y,w,h)
ICON=2.0  # アイコン倍率 (要素ごとの w,h にこれを掛ける)
def icon(res,x,y,w=66,h=66,fill=TEAL,label="",lblcolor=SUB,lblsize=12):
    w=int(w*ICON); h=int(h*ICON)
    st=("sketch=0;html=1;fontSize=%d;fontColor=%s;verticalLabelPosition=bottom;verticalAlign=top;"
        "align=center;shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.%s;fillColor=%s;strokeColor=none;"%(fs(lblsize),lblcolor,res,fill))
    return cell(label,st,x,y,w,h)
def arrow(x1,y1,x2,y2,color="#9AA7B2",sw=1.5,dashed=False,label=""):
    st="endArrow=classic;html=1;strokeColor=%s;strokeWidth=%s;"%(color,sw)
    if dashed: st+="dashed=1;"
    if label: st+="fontSize=%d;fontColor=%s;"%(fs(11),SUB)
    return ('<mxCell id="%s" value="%s" style="%s" edge="1" parent="1"><mxGeometry relative="1" as="geometry">'
            '<mxPoint x="%d" y="%d" as="sourcePoint"/><mxPoint x="%d" y="%d" as="targetPoint"/></mxGeometry></mxCell>'
            %(nid(),esc(label),st,x1,y1,x2,y2))
def title(t,sub):
    return []  # タイトル削除 (ユーザー指示)
def takeaway(t):
    return []  # 下の黒帯削除 (ユーザー指示)
def wrap(cells):
    return ('<mxGraphModel dx="800" dy="600" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" '
            'arrows="1" fold="1" page="1" pageScale="1" pageWidth="1480" pageHeight="900" math="0" shadow="0">'
            '<root><mxCell id="0"/><mxCell id="1" parent="0"/>%s</root></mxGraphModel>'%"".join(cells))
def save(name,cells):
    # title を消したぶん全要素を上(-90)へ詰める。y="..." を一括シフト。
    import re
    body="".join(cells)
    def shift(m):
        return 'y="%d"'%(int(m.group(1))-90)
    body=re.sub(r'(?<![A-Za-z])y="(\d+)"', shift, body)
    # mxPoint の y= も同様にシフトされる (矢印端点)。x= は触らない。
    open(os.path.join(OUT,name),"w").write(
        '<mxGraphModel dx="800" dy="600" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" '
        'arrows="1" fold="1" page="1" pageScale="1" pageWidth="1480" pageHeight="730" math="0" shadow="0">'
        '<root><mxCell id="0"/><mxCell id="1" parent="0"/>%s</root></mxGraphModel>'%body)

# ============ FIG 2: Approach A vs B (data flow) ============
c=title("Two ways to carry tenant identity into the pool","System prompt (injected every request) vs LoRA adapter (baked into weights)")
# ---- A panel ----
c+=[boxr(60,120,640,560,fill=BG,stroke=GREY,sw=1)]
c+=[txt("A.  System prompt",84,138,580,26,size=17,bold=True)]
c+=[icon("users",100,210,42,42,fill=SUB,label="User req")]
# request pill: long system prompt + short query
c+=[boxr(180,196,360,70,fill="#F2F4F6",stroke=GREY,sw=1,arc=8)]
c+=[boxr(190,206,250,22,fill="#E7E2D6",stroke="#C9BFA6",sw=1,arc=6)]
c+=[txt("long tenant system prompt",196,208,238,18,size=10,color="#7A6E50")]
c+=[boxr(190,234,90,22,fill=FILL,stroke=TEAL,sw=1,arc=6)]
c+=[txt("user query",196,236,80,18,size=10,color=TEAL)]
c+=[txt("payload billed in full, every request",180,272,360,16,size=10,color=WARN,italic=True)]
c+=[arrow(142,231,180,231,color="#9AA7B2")]
c+=[arrow(540,231,600,231,color="#9AA7B2")]
c+=[icon("ec2",600,210,44,44,fill=SUB,label="base model")]
c+=[txt("No training. Tenant behavior comes from the prompt.\n\nEvery request re-sends the full system prompt,\nso input tokens (and cost) grow with prompt size.\n\nNeeds per-tenant access control before injecting\ntenant data into the prompt.",
        100,330,560,200,size=14,color=INK)]
# ---- B panel ----
c+=[boxr(780,120,640,560,fill=BG,stroke=TEAL,sw=1.5)]
c+=[txt("B.  LoRA adapter",804,138,580,26,size=17,bold=True)]
c+=[icon("users",820,210,42,42,fill=SUB,label="User req")]
c+=[boxr(900,206,150,46,fill=FILL,stroke=TEAL,sw=1,arc=8)]
c+=[txt("short user query",908,218,134,20,size=11,color=TEAL)]
c+=[arrow(862,229,900,229)]
c+=[arrow(1050,229,1100,229)]
c+=[icon("ec2",1090,200,64,64,fill=TEAL,label="base model")]
# adapter shelf swapping in
c+=[boxr(1040,330,356,140,fill="#F2F4F6",stroke=GREY,sw=1,arc=8)]
c+=[txt("adapter pool (CPU): 1 base, many tenants",1052,338,330,18,size=11,color=SUB)]
for i,xx in enumerate([1052,1118,1184,1250,1316]):
    c+=[boxr(xx,364,56,56,fill=("#EAF1F1" if i==0 else "#FFFFFF"),stroke=(TEAL if i==0 else GREY),sw=1.2,arc=6)]
    c+=[txt("LoRA",xx,382,56,20,size=10,color=(TEAL if i==0 else "#9AA7B2"),align="center")]
c+=[arrow(1120,330,1130,272,color=TEAL,sw=1.6)]
c+=[txt("swap in ~1.2ms",1150,300,150,18,size=11,color=TEAL,italic=True)]
c+=[txt("Tenant data is baked into the adapter weights.\nUser prompt stays short -> cheaper prefill.\nAdapter swaps into the base model per request.",
        804,470,600,80,size=14,color=INK)]
c+=takeaway("Both pool tenants on one base model. A pays per-request input tokens; B pays a fixed per-token compute overhead (SGMV).")
save("approach.xml",c)

# ============ FIG 3: LLMOps governance loop ============
# レイアウト方針: 左=ガバナンス境界(縦に3ステップ), 右=共有プール。
# 2本の横断矢印は高さを大きく分離 (上=adapter 実線, 下=generated data 破線) し、
# ラベルは矢印の中点付近の "空き帯" に専用テキストで置いて被りを防ぐ。
c=title("The LLMOps loop: govern training data, pool the inference","Adapters cross the boundary because data is baked into weights; system prompts need access control")
# --- left: governance boundary (dashed), 3 steps stacked vertically ---
c+=[boxr(60,130,520,460,fill="#FAFAFB",stroke="#B6BFC8",sw=1.4,arc=4,dashed=True)]
c+=[txt("Per-tenant governance boundary",84,146,480,20,size=13,bold=True,color=SUB)]
c+=[txt("(may be on-prem / isolated VPC / account)",84,168,480,16,size=11,color=SUB,italic=True)]
c+=[icon("data_lake",110,224,46,46,fill=SUB,label="1. collect in/out")]
c+=[arrow(168,247,250,247,label="")]
c+=[icon("glue",250,224,46,46,fill=SUB,label="2. shape (PII)")]
c+=[arrow(273,294,273,360,color="#9AA7B2")]
c+=[icon("sagemaker",250,360,46,46,fill=TEAL,label="3. LoRA fine-tune")]
c+=[txt("data is converted into adapter weights",110,430,420,18,size=12,color=SUB,italic=True)]
# --- right: shared pool ---
c+=[boxr(700,130,720,300,fill=BG,stroke=TEAL,sw=1.5,arc=4)]
c+=[txt("Shared GPU pool  (cost-efficient, multi-tenant)",724,146,660,20,size=14,bold=True,color=TEAL)]
c+=[icon("ec2",724,200,44,44,fill=TEAL)]
c+=[icon("ec2",784,200,44,44,fill=TEAL)]
c+=[icon("ec2",844,200,44,44,fill=TEAL)]
c+=[txt("4. Multi-LoRA serving",910,196,480,22,size=14,bold=True)]
c+=[txt("LoRA: adapters pooled here.\nsystem prompt: inject tenant info only\nafter per-tenant DB access control.",910,222,490,64,size=12,color=INK)]
c+=[icon("rds",1320,330,44,44,fill=SUB,label="tenant DB")]
c+=[arrow(1342,330,1000,300,color="#9AA7B2",dashed=True)]
c+=[txt("access-controlled\ninjection",1120,316,180,34,size=10,color=SUB,italic=True)]
# --- crossing arrow 1 (HIGH): adapter leaves boundary into pool ---
c+=[arrow(310,360,700,232,color=TEAL,sw=2.4)]
c+=[boxr(470,248,320,30,fill="#FFFFFF",stroke="none",arc=4)]
c+=[txt("adapter crosses boundary (no raw data inside)",470,250,320,24,size=12,bold=True,color=TEAL,align="center")]
# --- crossing arrow 2 (LOW): generated data loops back to collect ---
c+=[arrow(900,460,180,300,color="#9AA7B2",sw=1.5,dashed=True)]
c+=[boxr(440,560,560,30,fill="#FFFFFF",stroke="none",arc=4)]
c+=[txt("generated data -> next round of FT (per tenant policy)",440,562,560,24,size=12,color=SUB,italic=True,align="center")]
c+=takeaway("Train inside the tenant boundary; serve in a shared pool. LoRA adapters can cross the boundary because the data lives in the weights, not in the open.")
save("opsloop.xml",c)

# ============ FIG 4: 8-GPU topology ============
c=title("One p6-b300 node = 8x TP=1 replicas (data-parallel pool)","31B fp8 fits on one GPU, so independent replicas beat tensor-parallel (no per-token comm)")
c+=[txt("128 tenants",80,150,200,20,size=13,bold=True,color=SUB)]
c+=[icon("users",90,180,46,46,fill=SUB,label="")]
# load balancer
c+=[boxr(250,300,150,120,fill=FILL,stroke=TEAL,sw=1.5,arc=8)]
c+=[txt("front LB",258,312,134,18,size=13,bold=True,color=TEAL,align="center")]
c+=[txt("round-robin\nor tenant-affinity\n(llm-d / GIE)",258,336,134,60,size=11,color=SUB,align="center")]
c+=[arrow(140,300,250,340,color="#9AA7B2",sw=1.5,label="requests")]
# 8 GPU replicas in 2 rows of 4
xs=[470,700,930,1160]; ys=[170,420]
gi=0
for ry,yy in enumerate(ys):
    for cx,xx in enumerate(xs):
        gi+=1
        c+=[boxr(xx,yy,210,210,fill=BG,stroke=GREY,sw=1,arc=6)]
        c+=[txt("GPU %d"%(gi-1),xx+14,yy+10,120,18,size=12,bold=True,color=INK)]
        c+=[icon("ec2",xx+14,yy+34,40,40,fill=TEAL,label="")]
        c+=[txt("vLLM TP=1",xx+62,yy+38,130,16,size=11,color=INK)]
        c+=[txt("31B fp8 ~32GB",xx+62,yy+56,140,14,size=10,color=SUB)]
        # hot-set strip
        c+=[boxr(xx+14,yy+90,182,40,fill="#F2F4F6",stroke=GREY,sw=1,arc=5)]
        c+=[txt("LoRA hot-set (max_loras=32)",xx+20,yy+96,172,14,size=9,color=SUB)]
        for k in range(6):
            c+=[boxr(xx+22+k*28,yy+110,22,14,fill=FILL,stroke=TEAL,sw=0.8,arc=3)]
        c+=[txt("KV cache fp8  ~230GB free",xx+14,yy+138,182,14,size=10,color=SUB)]
        c+=[txt("+1000 adapters in CPU pool",xx+14,yy+156,182,14,size=10,color=SUB)]
        # arrow from LB to each replica (only draw to row representatives to avoid clutter)
# a few representative arrows from LB (上段/下段の先頭 replica へ。右端への線は被るので省く)
c+=[arrow(400,330,470,250,color="#C7CFD6",sw=1)]
c+=[arrow(400,365,470,500,color="#C7CFD6",sw=1)]
c+=[txt("...to all 8 replicas",410,300,120,16,size=10,color="#9AA7B2",italic=True)]
c+=takeaway("Model fits on 1 GPU -> 8 independent replicas maximize aggregate throughput. Tensor-parallel would only add per-token communication cost.")
save("topology.xml",c)

print("[OK] generated approach.xml / opsloop.xml / topology.xml")
