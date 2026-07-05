#!/usr/bin/env python3
"""Generate JA summaries from a local vLLM OpenAI server for quality eval.
Fixed set of JA source articles -> each model summarizes -> saved to JSON.
Qwen3 thinking disabled. Usage: summ_generate.py <model_repo> <tag> <port>
"""
import json, os, sys, re
import urllib.request

# Fixed JA source articles (news/report/technical). Kept moderate length.
ARTICLES = [
  {"id":"biz","text":"当社は本日、次期中期経営計画を発表した。今後三年間で海外売上比率を現在の二割から四割へ引き上げることを目標に掲げ、特に東南アジア市場への投資を加速する。国内では既存事業の収益性改善を進めると同時に、生成AIを活用した業務効率化により営業利益率を五ポイント改善する方針だ。一方で、原材料価格の高騰と円安が引き続き経営リスクであると認識しており、調達先の多様化と為替ヘッジを強化する。人的資本への投資として、三年間で従業員一人あたりの研修時間を倍増させる計画も明らかにした。"},
  {"id":"sci","text":"研究チームは、常温で動作する新型の量子ビットの開発に成功したと発表した。従来の量子コンピュータは絶対零度に近い極低温環境を必要とし、大規模な冷却装置が普及の障壁となっていた。今回開発された素子はダイヤモンド中の窒素空孔центрを利用し、室温でも量子状態を一定時間保持できる。研究者らは、この技術により量子コンピュータの小型化と省エネルギー化が進むと期待を示す一方、実用化にはエラー訂正技術のさらなる向上が不可欠だと慎重な見方も示した。論文は国際学術誌に掲載された。"},
  {"id":"pol","text":"政府は、少子化対策の一環として、来年度から児童手当の対象年齢を高校卒業まで拡大する方針を固めた。所得制限も撤廃し、すべての世帯が対象となる。財源については社会保険料への上乗せと既存予算の組み替えで賄う計画だが、現役世代の負担増を懸念する声も根強い。専門家は、手当の拡充だけでなく、保育所の整備や働き方改革を同時に進めなければ出生率の改善は限定的だと指摘している。野党は財源の説明が不十分だと批判しており、国会での議論は難航が予想される。"},
  {"id":"tech","text":"大規模言語モデルの推論コストを下げる手法として、量子化が注目されている。モデルの重みを三十二ビットから四ビットや八ビットに圧縮することで、必要なメモリ量と計算量を削減できる。特に混合エキスパートと呼ばれる構造では、入力ごとに一部の専門家だけを活性化するため、総パラメータ数が大きくても実際の計算量は小さく、高いスループットが得られる。ただし過度な量子化は精度低下を招くため、用途に応じてビット幅を選ぶ必要がある。CPU上での推論でも、命令セットの最適化により実用的な速度が出せるようになってきた。"},
  {"id":"env","text":"国連の報告書によると、世界の平均気温は産業革命前と比べてすでに一・二度上昇しており、このままでは今世紀末までに三度近く上昇する恐れがある。報告書は、各国が現在掲げる温室効果ガス削減目標では不十分だと警告し、二〇三〇年までに排出量を半減させる必要があると強調した。再生可能エネルギーへの転換、森林の保全、そして途上国への資金支援が鍵になるとしている。専門家は、技術的な解決策は存在するものの、実行には政治的な意思と国際協調が欠かせないと述べた。"},
]

def strip_think(t):
    t=re.sub(r"<think>.*?</think>","",t,flags=re.DOTALL)
    t=re.sub(r"<think>.*","",t,flags=re.DOTALL)
    if "assistantfinal" in t: t=t.split("assistantfinal")[-1]
    return t.strip()

def chat(port, model, prompt, no_think, max_tokens=400):
    msg=prompt+(" /no_think" if no_think else "")
    payload={"model":model,"messages":[{"role":"user","content":msg}],"temperature":0.3,"max_tokens":max_tokens}
    if no_think: payload["chat_template_kwargs"]={"enable_thinking":False}
    req=urllib.request.Request(f"http://localhost:{port}/v1/chat/completions",
        data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=180) as r:
        return strip_think(json.loads(r.read())["choices"][0]["message"]["content"])

def main():
    model=sys.argv[1]; tag=sys.argv[2]; port=int(sys.argv[3])
    no_think=("qwen3" in tag.lower())
    out=[]
    for a in ARTICLES:
        p=f"次の日本語の文章を、要点を漏らさず3文以内で簡潔に要約してください。要約文のみを出力してください。\n\n文章:\n{a['text']}\n\n要約:"
        s=chat(port,model,p,no_think)
        out.append({"id":a["id"],"source":a["text"],"summary":s})
        print(f"[{tag}/{a['id']}] {s[:80]}...",file=sys.stderr)
    with open(os.path.expanduser(f"~/summaries_{tag}.json"),"w",encoding="utf-8") as f:
        json.dump({"model":model,"tag":tag,"no_think":no_think,"summaries":out},f,ensure_ascii=False,indent=2)
    print(f"WROTE summaries_{tag}.json",file=sys.stderr)

if __name__=="__main__": main()
