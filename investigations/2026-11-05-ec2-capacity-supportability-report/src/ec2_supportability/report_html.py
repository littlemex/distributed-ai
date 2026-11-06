"""The HTML report: one self-contained bilingual (English / Japanese) page made from the data document.

The visual style reproduces the Cloudscape Design System (visual-refresh) token values in plain CSS; the token names
are kept in comments so a real Cloudscape port is a mechanical swap.
"""
from __future__ import annotations

import html

from .collect import QUOTA_PER_HOUR, RANK, Preflight, best_score, failed_pairs, region_of
from .document import requested_azs

def bi(en: str, ja: str) -> str:
    """Paired text. CSS shows exactly one of the two according to <html lang>."""
    return f'<span class="en">{html.escape(en)}</span><span class="ja">{html.escape(ja)}</span>'


def bi_raw(en_html: str, ja_html: str) -> str:
    """Like bi() for fragments that already contain trusted markup."""
    return f'<span class="en">{en_html}</span><span class="ja">{ja_html}</span>'


PARTIAL_MARK = '<sup class="partial" title="Some requests for this row failed, so this best score may be incomplete / このタイプの一部のリクエストが失敗したので、この最良スコアは不完全かもしれません">†</sup>'


def pill(score, failed=False, not_offered=False, state=None) -> str:
    """One cell. `state` names a reason that comes before the others, with the labels the table output uses."""
    if score is None and state == "unknown_az":
        return '<span class="pill unk">Unknown AZ</span>'
    if score is None and state == "not_sent":
        return '<span class="pill ns">Not sent</span>'
    if score is None and not_offered:
        return '<span class="pill no">Not offered</span>'
    if score is None and failed:
        return '<span class="pill err">Error</span>'
    if score is None:
        return '<span class="pill na">N/A</span>'
    label = {"high": "High", "medium": "Medium", "low": "Low"}.get(score, html.escape(str(score)))
    cls = score if score in RANK else "na"
    return f'<span class="pill {cls}">{label}</span>'


def region_groups(azs):
    groups = []
    for az in azs:
        r = region_of(az)
        if groups and groups[-1][0] == r:
            groups[-1][1].append(az)
        else:
            groups.append((r, [az]))
    return groups


def heatmap(cells, types, azs, failed=frozenset(), not_offered=frozenset(), partial=False,
            unknown_azs=frozenset(), sent=True) -> str:
    """One table per market and amount. Columns are every AZ asked for; an AZ EC2 did not know keeps its column."""
    out = ['<div class="tablewrap"><table><thead><tr><th rowspan="2" class="sticky">',
           bi("Instance type", "インスタンスタイプ"), "</th>"]
    for r, g in region_groups(azs):
        out.append(f'<th colspan="{len(g)}" class="grp">{html.escape(r)}</th>')
    out.append('<th rowspan="2" class="grp">' + bi("Best", "最良") + "</th></tr><tr>")
    for _, g in region_groups(azs):
        for az in g:
            out.append(f'<th class="az">{html.escape(az)}</th>')
    out.append("</tr></thead><tbody>")
    for t in types:
        row = [cells.get((t, az)) for az in azs]
        out.append(f'<tr><th class="sticky mono">{html.escape(t)}</th>')
        for x, az in zip(row, azs):
            state = "unknown_az" if az in unknown_azs else None if sent else "not_sent"
            out.append(f"<td>{pill(x, (t, az) in failed, (t, az) in not_offered, state)}</td>")
        best = best_score(row)
        known = [az for az in azs if az not in unknown_azs]
        any_failed = any((t, az) in failed for az in known) or partial
        all_no = bool(known) and all((t, az) in not_offered for az in known)
        if best is None and not sent:
            out.append(f'<td class="bestcol">{pill(None, state="not_sent")}</td></tr>')
            continue
        mark = PARTIAL_MARK if any_failed and best is not None else ""
        out.append(f'<td class="bestcol">{pill(best, best is None and any_failed, best is None and all_no)}{mark}</td></tr>')
    out.append("</tbody></table></div>")
    return "".join(out)


def sensitivity(results, types, azs, amounts, not_offered=frozenset()) -> str:
    out = ['<div class="tablewrap"><table><thead><tr><th class="sticky">',
           bi("Instance type", "インスタンスタイプ"), "</th>"]
    out.extend(f'<th class="az">{a:,}</th>' for a in amounts)
    out.append("</tr></thead><tbody>")
    for t in types:
        out.append(f'<tr><th class="sticky mono">{html.escape(t)}</th>')
        for a in amounts:
            if not results[a].groups:
                out.append(f"<td>{pill(None, state='not_sent')}</td>")
                continue
            cells, failed = results[a].cells, failed_pairs(results[a])
            best = best_score(cells.get((t, az)) for az in azs)
            any_failed = any((t, az) in failed for az in azs) or results[a].partial
            all_no = all((t, az) in not_offered for az in azs)
            mark = PARTIAL_MARK if any_failed and best is not None else ""
            out.append(f"<td>{pill(best, best is None and any_failed, best is None and all_no)}{mark}</td>")
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def agg_pill(g) -> str:
    if g.aggregate:
        return pill(g.aggregate)
    return bi("request failed, see API errors", "リクエスト失敗 (API エラーを参照)") if g.error else bi("not in the response", "応答に含まれていません")


def aggregate_block(groups) -> str:
    """The aggregate score belongs to ONE request. When a run was split, say which slice."""
    if not groups:
        return ""
    if len(groups) == 1:
        g = groups[0]
        return ('<div class="agg"><b>' + bi("Aggregate score", "集約スコア") + "</b> " + agg_pill(g) + "</div>")
    out = ['<div class="agg"><b>' + bi("Aggregate score per request", "リクエストごとの集約スコア")
           + "</b><ul>"]
    for i, g in enumerate(groups, 1):
        types = "(attribute-based)" if g.types is None else ", ".join(g.types[:3]) + (f" +{len(g.types) - 3}" if len(g.types) > 3 else "")
        out.append(f"<li>{i}/{len(groups)}: <span class='mono'>{html.escape(types)}</span> x "
                   f"<span class='mono'>{html.escape(', '.join(g.azs))}</span> "
                   + agg_pill(g) + "</li>")
    out.append("</ul>"
               + bi("The run was split to stay within the per-request limits: 100 combinations (Quotas page) and 10 AZs and 50 instance types (AWS CLI reference). The documentation does not say how to combine aggregates, so each one is shown for its own request.",
                    "1 リクエストの上限に収めるため分割しました。上限は、組み合わせ 100 組 (Quotas のページ)、AZ 10 個とインスタンスタイプ 50 個 (AWS CLI リファレンス) です。ドキュメントは分けた集約の扱いを書いていないので、集約はリクエストごとに表示しています。")
               + "</div>")
    return "".join(out)


CSS = """
:root{
  --ink:#0f141a;           /* color-text-body-default */
  --ink2:#424650;          /* color-text-heading-secondary */
  --ink3:#656871;          /* color-text-body-secondary */
  --bg:#f6f6f9;            /* color-background-cell-shaded */
  --card:#ffffff;          /* color-background-container-content */
  --line:#c6c6cd;          /* color-border-divider-default */
  --line2:#ebebf0;         /* color-border-divider-secondary */
  --link:#006ce0;          /* color-text-link-default */
  --nav:#0f141a;           /* same value as --ink */
  --ok-bg:#effff1;--ok:#00802f;       /* status: success */
  --warn-bg:#fffce9;--warn:#855900;   /* status: warning */
  --err-bg:#fff5f5;--err:#db0000;     /* status: error */
  --info-bg:#f0fbff;--info:#006ce0;   /* status: info */
  --r-pill:20px;           /* border-radius-button */
  --r-card:16px;           /* border-radius-container */
  --font:'Open Sans','Helvetica Neue',Roboto,Arial,'Hiragino Kaku Gothic ProN','Noto Sans JP',sans-serif;
  --mono:Monaco,Menlo,Consolas,'Courier Prime',Courier,'Courier New',monospace;
}
*{box-sizing:border-box}
html[lang="en"] .ja{display:none}
html[lang="ja"] .en{display:none}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.6 var(--font)}
.topnav{background:var(--nav);color:#fff;padding:10px 24px;font-weight:700;display:flex;gap:16px;align-items:center}
.topnav small{font-weight:400;color:var(--line)}
.topnav .sp{flex:1}
.lang button{font:inherit;color:#fff;background:transparent;border:1px solid var(--line);padding:2px 14px;cursor:pointer}
.lang button:first-child{border-radius:var(--r-pill) 0 0 var(--r-pill)}
.lang button:last-child{border-radius:0 var(--r-pill) var(--r-pill) 0;border-left:0}
.lang button[aria-pressed="true"]{background:#fff;color:var(--ink)}
.wrap{max-width:1280px;margin:0 auto;padding:16px 24px 48px}
.crumbs{color:var(--ink3);font-size:12px;margin:8px 0}
h1{font-size:28px;line-height:1.3;margin:4px 0;font-weight:700}
h2{font-size:18px;margin:0 0 12px;font-weight:700}
h3{font-size:14px;margin:18px 0 8px;font-weight:700;color:var(--ink2)}
.lead{color:var(--ink2);margin:0 0 16px}
.card{background:var(--card);border-radius:var(--r-card);padding:20px 24px;margin:16px 0;
  box-shadow:0 1px 1px 0 rgba(0,28,36,.3),1px 1px 1px 0 rgba(0,28,36,.15),-1px 1px 1px 0 rgba(0,28,36,.15)}
.kv{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}
.kv .k{color:var(--ink3);font-size:12px;font-weight:700}
.kv .v{font-size:16px;word-break:break-all}
.mono{font-family:var(--mono);font-size:13px}
.alert{border-radius:8px;padding:12px 16px;margin:12px 0;border:1px solid}
.alert.info{background:var(--info-bg);border-color:var(--info)}
.alert.err{background:var(--err-bg);border-color:var(--err)}
.alert.warn{background:var(--warn-bg);border-color:var(--warn)}
.pill{display:inline-block;min-width:64px;text-align:center;padding:1px 10px;border-radius:var(--r-pill);font-weight:700;font-size:12px}
.pill.high{background:var(--ok-bg);color:var(--ok);box-shadow:inset 0 0 0 1px var(--ok)}
.pill.medium{background:var(--warn-bg);color:var(--warn);box-shadow:inset 0 0 0 1px var(--warn)}
.pill.low{background:var(--err-bg);color:var(--err);box-shadow:inset 0 0 0 1px var(--err)}
.pill.err{background:var(--err-bg);color:var(--err);box-shadow:inset 0 0 0 1px var(--err);border-style:dashed}
.pill.no{background:var(--bg);color:var(--ink3);box-shadow:inset 0 0 0 1px var(--line);border-style:dotted;font-weight:400}
.partial{color:var(--err);cursor:help;font-weight:700}
.pill.na{background:var(--bg);color:var(--ink3);box-shadow:inset 0 0 0 1px var(--line);font-weight:400}
.pill.unk{background:var(--bg);color:var(--ink3);box-shadow:inset 0 0 0 2px var(--line);font-weight:400;font-style:italic}
.pill.ns{background:var(--card);color:var(--ink3);box-shadow:none;border:1px dashed var(--line);font-weight:400}
.tablewrap{overflow-x:auto;border:1px solid var(--line2);border-radius:8px}
table{border-collapse:collapse;width:100%;background:#fff}
th,td{padding:8px 12px;border-bottom:1px solid var(--line2);text-align:center;white-space:nowrap}
thead th{background:var(--bg);font-size:12px;color:var(--ink2)}
th.sticky{text-align:left;position:sticky;left:0;background:#fff;z-index:1}
thead th.sticky{background:var(--bg)}
th.grp{border-left:1px solid var(--line2)}
th.az{font-family:var(--mono);font-weight:400}
td.bestcol{border-left:2px solid var(--line)}
tr:last-child td,tr:last-child th{border-bottom:none}
.agg{margin:8px 0 12px;color:var(--ink2)}
.agg ul{margin:6px 0;padding-left:20px}
.legend{display:grid;gap:8px}
.legend div{display:flex;gap:12px;align-items:baseline}
.legend .pill{flex:none}
.sec{border-top:1px solid var(--line2);margin-top:20px;padding-top:4px}
ul.plain{margin:6px 0;padding-left:20px}
footer{color:var(--ink3);font-size:12px;margin-top:24px}
"""

JS = """
(function(){
  var KEY='supportability-report-lang', root=document.documentElement;
  function show(l){
    root.setAttribute('lang',l);
    document.title=root.getAttribute('data-title-'+l);
    document.querySelectorAll('.lang button').forEach(function(b){
      b.setAttribute('aria-pressed', b.getAttribute('data-lang')===l ? 'true':'false');
    });
  }
  var saved=null; try{saved=localStorage.getItem(KEY)}catch(e){}
  var explicit=root.getAttribute('data-lang-explicit')==='1';
  show(!explicit && (saved==='en'||saved==='ja') ? saved : root.getAttribute('lang'));
  document.querySelectorAll('.lang button').forEach(function(b){
    b.addEventListener('click',function(){
      var l=b.getAttribute('data-lang'); show(l);
      try{localStorage.setItem(KEY,l)}catch(e){}
    });
  });
})();
"""

TITLE_EN = "EC2 Capacity Manager - real-time supportability check"
TITLE_JA = "EC2 Capacity Manager - リアルタイム supportability チェック"


def render(ctx: dict) -> str:
    h = [f'<!doctype html><html lang="{ctx["lang"]}" data-lang-explicit="{1 if ctx["lang_explicit"] else 0}" data-title-en="{html.escape(TITLE_EN)}" '
         f'data-title-ja="{html.escape(TITLE_JA)}"><head><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         f"<title>{html.escape(TITLE_EN if ctx['lang'] == 'en' else TITLE_JA)}</title>",
         f"<style>{CSS}</style></head><body>",
         '<div class="topnav">EC2 Capacity Manager <small>' + bi("Check supportability report", "Check supportability レポート")
         + '</small><span class="sp"></span><span class="lang" role="group" aria-label="Language">'
         '<button type="button" data-lang="en" aria-pressed="false">English</button>'
         '<button type="button" data-lang="ja" aria-pressed="false">日本語</button></span></div>',
         '<div class="wrap">',
         '<div class="crumbs">EC2 &gt; Capacity Manager &gt; Check supportability</div>',
         "<h1>" + bi("Real-time supportability check", "リアルタイム supportability チェック") + "</h1>",
         '<p class="lead">' + bi(
             "Each score compares the capacity an instance type and Availability Zone combination holds right now with the amount you asked for. "
             "It reflects capacity at a point in time. It doesn't reserve capacity or guarantee that a later launch will succeed.",
             "各スコアは、インスタンスタイプと Availability Zone の組み合わせがいま保有しているキャパシティを、要求した量と比べたものです。"
             "ある時点のキャパシティを反映したもので、キャパシティを予約せず、後の起動が成功することも保証しません。") + "</p>"]

    pf = ctx.get("pf") or Preflight(azs=ctx["azs"], types=ctx["types"])
    if ctx.get("status"):
        h.append("<div class='alert err'><b>" + bi(
            f"This run did not obtain every score you asked for (exit status {ctx['status']}).",
            f"この実行では、要求したスコアをすべては取得できませんでした (終了コード {ctx['status']})。") + "</b> " + bi(
            "Read the Error, Not offered, Unknown AZ, Not sent and N/A marks, the checks before sending and the API errors below before using any number on this page.",
            "このページの数値を使う前に、下の Error、Not offered、Unknown AZ、Not sent、N/A の表示、送信前の確認、API エラーを読んでください。") + "</div>")

    # How to read (restates the documentation, nothing more)
    h.append('<div class="card"><h2>' + bi("How to read the scores", "スコアの読み方") + "</h2>"
             '<div class="legend">'
             f"<div>{pill('high')}<span>" + bi("The combination holds several times your request. Proceed.",
                                              "要求量の数倍を保有しています。先へ進めてよい水準です。") + "</span></div>"
             f"<div>{pill('medium')}<span>" + bi(
                 "The combination can cover your request with little to spare. Workable rather than safe; a launch can still fail.",
                 "要求量をぎりぎり満たせる程度です。安全というより実行可能な水準で、起動は失敗する場合があります。") + "</span></div>"
             f"<div>{pill('low')}<span>" + bi(
                 "The combination holds less than you asked for, though some capacity is likely still available.",
                 "要求量より少ない保有量ですが、一部のキャパシティはまだ残っていると見込まれます。") + "</span></div>"
             f"<div>{pill(None)}<span>" + bi(
                 "This instance type x AZ pair is not in the response. The documentation does not say why a requested pair can be absent.",
                 "このインスタンスタイプと AZ の組み合わせは応答に含まれていません。要求した組み合わせが応答に無い理由は、ドキュメントに書かれていません。") + "</span></div>"
             f"<div>{pill(None, False, True)}<span>" + bi(
                 "EC2 reports that this instance type is not offered in this AZ (checked with DescribeInstanceTypeOfferings before sending, not with Capacity Manager).",
                 "EC2 によると、このインスタンスタイプはこの AZ では提供されていません (送信前に Capacity Manager ではなく DescribeInstanceTypeOfferings で確認しました)。") + "</span></div>"
             f"<div>{pill(None, state='unknown_az')}<span>" + bi(
                 "EC2 does not know this AZ ID, so it was not sent (found before sending with DescribeAvailabilityZones).",
                 "EC2 がこの AZ ID を知らないので、送っていません (送信前に DescribeAvailabilityZones で確認しました)。") + "</span></div>"
             f"<div>{pill(None, state='not_sent')}<span>" + bi(
                 "No request was sent for this market and amount, for example because Capacity Manager was not usable. The reason is at the top of the page.",
                 "この市場と量にはリクエストを送っていません。Capacity Manager が使えなかった場合などで、理由はページの先頭にあります。") + "</span></div>"
             f"<div>{pill(None, True)}<span>" + bi(
                 "The request that contained this pair failed, or returned no usable score for it. The error is listed under API errors below.",
                 "この組み合わせを含むリクエストが失敗したか、この組み合わせの使えるスコアを返しませんでした。エラーは下の API エラーに載せています。") + "</span></div>"
             "<div><span class=\"partial\">†</span><span>" + bi(
                 "Some requests for this row failed, so the best score shown may be incomplete.",
                 "この行の一部のリクエストが失敗したので、表示している最良スコアは不完全かもしれません。") + "</span></div>"
             "</div>"
             '<ul class="plain">'
             "<li>" + bi("Scores are relative to the amount you ask for: the same combination can score High for 50 instances and Low for 5,000 at the same moment.",
                         "スコアは要求量に対する相対値です。同じ組み合わせでも、同時点で 50 台なら High、5,000 台なら Low になりえます。") + "</li>"
             "<li>" + bi("No score, including High, guarantees that a launch will succeed. Insufficient capacity errors remain possible. For critical workloads use Capacity Reservations or Future-dated Capacity Reservations regardless of score.",
                         "High を含め、どのスコアも起動の成功を保証しません。容量不足エラーは起こりえます。重要なワークロードには、スコアに関係なく Capacity Reservation か将来日付の Capacity Reservation を使います。") + "</li>"
             "<li>" + bi("The aggregate score rates the whole set of options in one request. Low scores per combination with a High aggregate is intended: no single combination can carry the request, but the options together can.",
                         "集約スコアは、1 つのリクエストに含めた選択肢の集合全体への評価です。組み合わせごとが Low でも全体が High になるのは意図した動作で、単独では支えきれなくても全体では支えられるという意味です。") + "</li>"
             "<li>" + bi("The Spot scores are built on Spot placement score (SPS). SPS rates your flexibility as a whole rather than individual combinations, and the Spot aggregate score gives equivalent guidance. If you already use SPS directly, read the aggregate as your Spot signal. The documentation does not say how to read the per-combination Spot values.",
                         "Spot のスコアは Spot placement score (SPS) を土台にしています。SPS は個々の組み合わせではなく、選択肢全体の柔軟性を評価し、Spot の集約スコアが同等の指針になります。すでに SPS を直接使っている場合は、集約スコアを Spot の信号として読みます。組み合わせごとの Spot の値の読み方は、ドキュメントに書かれていません。") + "</li>"
             "<li>" + bi("Run checks when you plan or review a workload rather than on every launch.",
                         "チェックは、起動のたびではなく、ワークロードを計画するときや見直すときに実行します。") + "</li>"
             "<li>" + bi("After an InsufficientCapacityError, check the score again for the same instance type, AZ and amount. High: the combination has capacity but needs to resize hosts to produce instances at your requested size, so launch what you can and retry the rest every few minutes. Medium or Low: the combination has limited available capacity for your request, so launch in another combination that scored High or add more instance types.",
                         "InsufficientCapacityError が出た後は、同じインスタンスタイプ、AZ、要求量でもう一度スコアを確認します。High なら、その組み合わせにキャパシティはあるものの、要求したサイズのインスタンスを作るためにホストのリサイズが必要な状態です。起動できる分を起動し、残りは数分おきに再試行します。Medium か Low なら、要求に対して空きが限られているので、High だった別の組み合わせで起動するか、インスタンスタイプを増やします。") + "</li>"
             "</ul></div>")

    # Scope of this run
    st = ctx["state"]
    h.append('<div class="card"><h2>' + bi("Scope of this run", "この実行の範囲") + '</h2><div class="kv">')
    kv = [(("Account", "アカウント"), ctx["identity"]["Account"]),
          (("Caller", "呼び出し元"), ctx["identity"]["Arn"]),
          (("Region the API was called in", "API を呼んだ Region"), ctx["region"]),
          (("Capacity Manager status", "Capacity Manager の状態"),
           st.get("status", "unknown")),
          (("Run time (JST)", "実行時刻 (JST)"), ctx["now"]),
          ((f"API requests sent in this run, SDK automatic retries not counted (quota: {QUOTA_PER_HOUR} per account per hour, shared with other runs)", f"この実行で送った API リクエスト数、SDK の自動再試行は含まない (上限: アカウントあたり 1 時間 {QUOTA_PER_HOUR} 回、他の実行と共有)"),
           str(ctx["calls"]))]
    for (ken, kja), v in kv:
        h.append(f"<div><div class='k'>{bi(ken, kja)}</div><div class='v'>{html.escape(str(v))}</div></div>")
    h.append("</div><ul class='plain'>"
             "<li>" + bi("The API is called in the Region where Capacity Manager is enabled; one call can cover Availability Zones in any Region.",
                         "API は Capacity Manager を有効にした Region で呼びます。1 回の呼び出しで、どの Region の Availability Zone も対象にできます。") + "</li>"
             "<li>" + bi("Availability Zones are given as AZ IDs (for example apne1-az4). AWS maps AZ names such as ap-northeast-1c to physical zones separately for each account, while an AZ ID identifies the same physical location in every account (AWS RAM documentation, Availability Zone IDs for your AWS resources).",
                         "Availability Zone は AZ ID (例 apne1-az4) で指定します。AWS は ap-northeast-1c のような AZ 名をアカウントごとに別々に物理ゾーンへ対応付けますが、AZ ID はどのアカウントでも同じ物理的な場所を指します (AWS RAM ドキュメントの Availability Zone IDs for your AWS resources)。") + "</li>"
             "<li>" + bi("Available only to AWS Support customers on the Unified Operations plan. Quotas: 100 queries per account per hour and 100 instance type x AZ combinations per request. The documentation does not say whether other accounts would see the same score, so treat the results as this account's.",
                         "AWS Support の Unified Operations プランのお客様だけが使えます。上限は、アカウントあたり 1 時間 100 クエリ、1 リクエストあたり 100 組のインスタンスタイプと AZ の組み合わせです。他のアカウントでも同じスコアになるかはドキュメントに書かれていないので、結果はこのアカウントのものとして扱います。") + "</li></ul>")
    for en, ja in ctx["log"]:
        h.append(f"<div class='alert info'>{bi(en, ja)}</div>")
    if st.get("needs_enable"):
        h.append("<div class='alert warn'>" + bi_raw(
            "Capacity Manager is not enabled, so no scores were requested. Re-run with <code>--enable</code> to enable it in this Region (allowed in one Region per account).",
            "Capacity Manager が無効なので、スコアは取得していません。この Region で有効にするには <code>--enable</code> を付けて再実行します (1 アカウントにつき 1 Region だけ)。") + "</div>")
    if st.get("status") == "elsewhere":
        h.append("<div class='alert warn'>" + bi(
            "Capacity Manager is enabled in a different Region of this account (it can be enabled in one Region only). Run again with that Region as --region; the Region is named in the message below.",
            "このアカウントでは、別の Region で Capacity Manager が有効です (有効にできるのは 1 つの Region だけです)。その Region を --region にして、もう一度実行してください。Region 名は下のメッセージに出ています。") + "</div>")
    if st["error"]:
        h.append("<div class='alert err'><b>" + bi("Could not read or enable Capacity Manager:", "Capacity Manager の確認または有効化に失敗:")
                 + f"</b> <span class='mono'>{html.escape(st['error'])}</span></div>")
    h.append("</div>")

    dropped = sorted({(m, a, v, e) for m in ctx["markets"] for a in ctx["amounts"]
                      for g in ctx["results"][m][a].groups for v, _kind, e in g.dropped})
    if pf.bad_azs or pf.excluded_types or pf.notes or dropped or (ctx["state"].get("enabled") and not any(
            ctx["results"][m][a].groups for m in ctx["markets"] for a in ctx["amounts"])):
        h.append("<div class='card'><h2>" + bi("Checks before sending", "送信前の確認") + "</h2><ul class='plain'>")
        if pf.bad_azs:
            h.append("<li>" + bi("AZ IDs that EC2 does not know (not sent): ", "EC2 が知らない AZ ID (送信していません): ")
                     + f"<span class='mono'>{html.escape(', '.join(pf.bad_azs))}</span></li>")
        if pf.excluded_types:
            h.append("<li>" + bi("Instance types not offered in any requested AZ (not sent): ", "指定した AZ のどこにも提供されていないインスタンスタイプ (送信していません): ")
                     + f"<span class='mono'>{html.escape(', '.join(pf.excluded_types))}</span></li>")
        for m, a, v, e in dropped:
            h.append("<li>" + bi("The API rejected a value by name, so the request was repeated without it: ",
                                 "API が値を名指しで拒否したので、その値を除いてリクエストをやり直しました: ")
                     + f"<span class='mono'>{html.escape(v)}</span> ({html.escape(m)} / {a:,}) "
                     + f"<span class='mono'>{html.escape(e)}</span></li>")
        for en, ja in pf.notes:
            h.append(f"<li>{bi(en, ja)}</li>")
        if not any(ctx["results"][m][a].groups for m in ctx["markets"] for a in ctx["amounts"]) and ctx["state"].get("enabled"):
            h.append("<li>" + bi("Nothing was left to send, so no Capacity Manager request was made.",
                                 "送信するものが残らなかったので、Capacity Manager へのリクエストはしていません。") + "</li>")
        h.append("</ul></div>")

    errors = [(m, a, i, len(ctx["results"][m][a].groups), g.error)
              for m in ctx["markets"] for a in ctx["amounts"]
              for i, g in enumerate(ctx["results"][m][a].groups, 1) if g.error]
    if errors:
        h.append("<div class='card'><div class='alert err'><b>" + bi("API errors", "API エラー") + "</b><ul class='plain'>"
                 + "".join(f"<li><span class='mono'>{html.escape(m)} / {a:,} {html.escape(ctx['unit'])} / "
                           f"{bi('request', 'リクエスト')} {i}/{n}: {html.escape(e)}</span></li>"
                           for m, a, i, n, e in errors) + "</ul>"
                 + bi("One invalid value makes the whole request fail, so every pair in that request has no score. Fix the value named in the message and run again. ",
                      "1 つでも不正な値があるとリクエスト全体が失敗し、そのリクエストの組み合わせはすべてスコアなしになります。メッセージが示す値を直して、もう一度実行してください。")
                 + bi("These are the raw error texts from the API or the SDK, or messages this tool wrote when a response was not usable (UnexpectedResponse). The documentation does not say which error an account without the Unified Operations plan receives; the checks are available only to AWS Support customers on that plan.",
                      "上は API または SDK が返したエラーの原文か、応答が使えなかったときにこのツールが書いたメッセージ (UnexpectedResponse) です。Unified Operations プランでないアカウントでどのエラーが返るかは、ドキュメントに書かれていません。このチェックは、そのプランの AWS Support のお客様だけが使えます。")
                 + "</div></div>")

    for market in ctx["markets"]:
        res = ctx["results"][market]
        name_en, name_ja = ("On-Demand", "オンデマンド") if market == "on-demand" else ("Spot", "スポット")
        h.append(f"<div class='card'><h2>{bi(name_en, name_ja)} <span class='mono'>({html.escape(market)})</span></h2>")
        if market == "spot":
            split = any(len(res[a].groups) > 1 for a in ctx["amounts"])
            h.append("<div class='alert info'>" + bi(
                "Spot scores are built on Spot placement score (SPS), which rates your flexibility as a whole. If you already use SPS directly, read the aggregate as your Spot signal.",
                "Spot のスコアは Spot placement score (SPS) を土台にしており、SPS は柔軟性の全体を評価します。すでに SPS を直接使っている場合は、集約スコアを Spot の信号として読みます。")
                + bi(" The per-combination values below are shown as returned, and Best is the highest of them; the documentation does not say how to read per-combination Spot values.",
                     " 下の組み合わせごとの値は返ってきた値をそのまま示したもので、「最良」はその中の最高値です。組み合わせごとの Spot の値の読み方は、ドキュメントに書かれていません。")
                + (bi(" This run was split into several requests, so each aggregate covers only its own slice of your options; to get one aggregate, narrow the run to a single request.",
                      " この実行は複数のリクエストに分けたので、各集約スコアは選択肢の一部分だけを対象にしています。1 つの集約スコアを得たい場合は、1 回のリクエストに収まるよう絞り込みます。") if split else "")
                + "</div>")
        types = ctx["types"] or sorted({t for a in ctx["amounts"] for t in res[a].types})
        sent_any = any(res[a].groups for a in ctx["amounts"])
        if not sent_any:
            h.append("<div class='alert warn'>" + bi("No request was sent for this market, so there are no scores to show.",
                                                    "この市場にはリクエストを送っていないので、表示できるスコアはありません。") + "</div>")
            if not ctx["types"]:  # attribute-based: the types are not known, so there are no rows to mark Not sent
                h.append("</div>")
                continue
        h.append("<h3>" + bi("Best score per type as the requested amount grows (best Availability Zone for each type)",
                             "要求量を増やしたときの、タイプごとの最良スコア (各タイプで最も良い Availability Zone)") + "</h3>")
        h.append(sensitivity(res, types, ctx["azs"], ctx["amounts"], pf.not_offered))
        for amt in ctx["amounts"]:
            r = res[amt]
            h.append("<div class='sec'><h3>" + bi(f"Request: {amt:,} {ctx['unit']}", f"要求量: {amt:,} {ctx['unit']}") + "</h3>")
            bad = sum(1 for g in r.groups if g.error or g.dropped)
            if bad:
                h.append("<div class='alert warn'>" + bi(
                    f"{bad} of {len(r.groups)} requests failed or lost a value (see API errors and Checks before sending). Pairs of those requests show as Error"
                    + ("; in attribute-based mode their instance types are unknown, so those rows are missing and every Best value is marked as possibly incomplete." if r.partial else "."),
                    f"{len(r.groups)} 件のリクエストのうち {bad} 件が失敗したか、値を除いて送りました (API エラーと送信前の確認を参照)。それらの組み合わせは Error と表示します"
                    + ("。属性指定ではインスタンスタイプが分からないので、該当する行は表に出ず、すべての最良スコアが不完全かもしれません。" if r.partial else "。")) + "</div>")
            h.append(aggregate_block(r.groups))
            h.append(heatmap(r.cells, types, requested_azs({"azs": ctx["azs"], "pf": pf}), failed_pairs(r), pf.not_offered, r.partial,
                             frozenset(pf.bad_azs), bool(r.groups)))
            h.append("</div>")
        h.append("</div>")

    h.append("<footer>" + bi(
        "These scores are EC2 Capacity Manager Data under the AWS Service Terms. You may use them solely for your internal capacity planning and workload management. "
        "You may not disclose them to any third party other than contractors or agents acting on your behalf, and you may not use them, or allow others to use them, "
        "directly or indirectly to develop, improve or offer a similar or competing product or service. "
        "AWS may suspend your use of EC2 Capacity Manager if it reasonably believes these terms are violated. "
        "The AWS documentation also states that the results can't be shared with third parties. "
        "This tool runs on your machine, calls the API in your account, and writes the file only to the output path (by default under ~/tmp/supportability/), or, when the run is not complete or the path cannot be used, next to it with a .failed- or .unplaced- name; whether that directory is synced or shared is up to you. "
        "This is a summary, not legal advice; read the current AWS Service Terms.",
        "このスコアは、AWS サービス条件でいう EC2 Capacity Manager Data です。自社の内部のキャパシティ計画とワークロード管理の目的に限って使えます。"
        "あなたのために行動する委託先または代理人を除く第三者には開示できず、同種または競合する製品やサービスの開発、改良、提供に、直接か間接かを問わず、使うことも他者に使わせることもできません。"
        "AWS が違反していると合理的に判断した場合、EC2 Capacity Manager の利用が停止されることがあります。"
        "AWS のドキュメントも、結果を第三者と共有できないと書いています。"
        "このツールは手元のマシンで動き、あなたのアカウントで API を呼び、ファイルは出力パス (既定では ~/tmp/supportability/ の下) にだけ書き出します。実行が完了しなかったとき、またはそのパスが使えないときは、同じディレクトリに .failed- または .unplaced- の付いた別名で書き出します。そのディレクトリが同期や共有の対象かどうかは、利用者の管理です。"
        "これは要約であり、法的な助言ではありません。最新の AWS サービス条件を確認してください。")
        + "<br>" + bi("Generated by", "生成:") + " ec2-supportability</footer></div>"
        f"<script>{JS}</script></body></html>")
    return "".join(h)


# ---------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------
