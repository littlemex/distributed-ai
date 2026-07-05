#!/usr/bin/env python3
"""LLM-as-judge for JA summary quality using Claude Opus 4.8 on Bedrock.
For each (model, article) summary: judge 3 times, take MEDIAN per dimension.
Dimensions (1-5): coverage(要点網羅), faithfulness(忠実性/幻覚なし),
fluency(日本語の自然さ), conciseness(簡潔性). Overall = median of dim-medians.
Reads summaries_*.json (pulled from g6e). Emits JSON Lines.
"""
import json, os, sys, glob, statistics, re
import boto3

REGION="us-west-2"
JUDGE="us.anthropic.claude-opus-4-8"
N_JUDGE=3

RUBRIC="""あなたは日本語要約の厳格な評価者です。以下の「原文」と「要約」を読み、4観点を各1〜5の整数で採点してください。
- coverage(要点網羅): 原文の重要な要点を漏れなく含むか
- faithfulness(忠実性): 原文にない情報や誤り(幻覚)がないか
- fluency(日本語の自然さ): 文法・表現が自然で読みやすいか
- conciseness(簡潔性): 冗長でなく簡潔にまとまっているか
必ず次のJSONのみを出力: {"coverage":n,"faithfulness":n,"fluency":n,"conciseness":n}
"""

def judge_once(br, source, summary):
    prompt=f"{RUBRIC}\n\n原文:\n{source}\n\n要約:\n{summary}\n\nJSON:"
    r=br.converse(modelId=JUDGE,messages=[{"role":"user","content":[{"text":prompt}]}],
                  inferenceConfig={"maxTokens":200,"temperature":0.0})
    t=r["output"]["message"]["content"][0]["text"]
    m=re.search(r"\{[^{}]*\}",t,re.DOTALL)
    d=json.loads(m.group(0))
    return {k:int(d[k]) for k in ("coverage","faithfulness","fluency","conciseness")}

def main():
    br=boto3.client("bedrock-runtime",region_name=REGION)
    dims=["coverage","faithfulness","fluency","conciseness"]
    for f in sorted(glob.glob(os.path.expanduser("~/summaries_*.json"))):
        data=json.load(open(f)); tag=data["tag"]
        per_article=[]
        for item in data["summaries"]:
            runs=[]
            for _ in range(N_JUDGE):
                try: runs.append(judge_once(br,item["source"],item["summary"]))
                except Exception as e: print(f"[{tag}/{item['id']}] judge err: {e}",file=sys.stderr)
            if not runs: continue
            med={d:statistics.median([r[d] for r in runs]) for d in dims}  # median over 3 judges
            med["overall"]=round(statistics.median(list(med.values())),2)
            per_article.append(med)
            print(f"[{tag}/{item['id']}] {med}",file=sys.stderr)
        if not per_article: continue
        # model score = median across articles, per dimension
        agg={d:round(statistics.median([a[d] for a in per_article]),2) for d in dims}
        agg["overall"]=round(statistics.median([a["overall"] for a in per_article]),2)
        rec={"kind":"summary_quality_judge","model":data["model"],"tag":tag,
             "judge":JUDGE,"n_judge_per_item":N_JUDGE,"n_articles":len(per_article),
             "aggregation":"median over judges then median over articles","scores":agg}
        print(json.dumps(rec,ensure_ascii=False),flush=True)

if __name__=="__main__": main()
