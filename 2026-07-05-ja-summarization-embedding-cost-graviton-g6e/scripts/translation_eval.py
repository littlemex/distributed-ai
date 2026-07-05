#!/usr/bin/env python3
"""Translation sanity probe v2: disables thinking/reasoning and strips <think>.
JA<->EN chrF via sacrebleu. Reference-grade sanity, NOT full WMT.
Usage: translate_eval2.py <model_repo> <tag> <port>
"""
import json, os, sys, re
import urllib.request

PAIRS = [
  ("近年、生成AIの進歩により、機械翻訳の品質は人間の翻訳に近づきつつある。",
   "In recent years, advances in generative AI have brought machine translation quality close to that of human translation."),
  ("この製品は防水機能を備えており、雨の日でも安心して使用できます。",
   "This product is waterproof, so you can use it with confidence even on rainy days."),
  ("会議は来週の火曜日の午後三時に変更されましたのでご注意ください。",
   "Please note that the meeting has been rescheduled to 3 p.m. next Tuesday."),
  ("彼女は長年の研究の末、新しい治療法の開発に成功した。",
   "After many years of research, she succeeded in developing a new treatment."),
  ("この地域は自然災害が多いため、防災対策が重要である。",
   "Because this region has many natural disasters, disaster prevention measures are important."),
]

def strip_think(t):
    # remove <think>...</think> and any leading reasoning up to a marker
    t = re.sub(r"<think>.*?</think>", "", t, flags=re.DOTALL)
    t = re.sub(r"<think>.*", "", t, flags=re.DOTALL)  # unclosed
    # gpt-oss harmony: keep text after 'assistantfinal' if present
    if "assistantfinal" in t:
        t = t.split("assistantfinal")[-1]
    return t.strip()

def chat(port, model, prompt, max_tokens=512, no_think=False):
    msg = prompt + (" /no_think" if no_think else "")
    payload = {"model": model, "messages":[{"role":"user","content":msg}],
               "temperature":0.2, "max_tokens":max_tokens}
    if no_think:
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    body=json.dumps(payload).encode()
    req=urllib.request.Request(f"http://localhost:{port}/v1/chat/completions",
                               data=body,headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=180) as r:
        d=json.loads(r.read())
    return strip_think(d["choices"][0]["message"]["content"])

def main():
    model=sys.argv[1]; tag=sys.argv[2]; port=int(sys.argv[3])
    no_think = ("qwen3" in tag.lower())  # Qwen3 supports enable_thinking=False
    import sacrebleu
    j2e_h=[]; j2e_r=[]; e2j_h=[]; e2j_r=[]; samples=[]
    for ja,en in PAIRS:
        h1=chat(port,model,f"次の日本語を自然な英語に翻訳してください。訳文のみを出力してください。\n\n{ja}", no_think=no_think)
        h2=chat(port,model,f"Translate the following English into natural Japanese. Output only the translation.\n\n{en}", no_think=no_think)
        j2e_h.append(h1); j2e_r.append(en); e2j_h.append(h2); e2j_r.append(ja)
        samples.append({"ja":ja,"en":en,"ja2en":h1,"en2ja":h2})
    chrf=sacrebleu.CHRF()
    rec={"kind":"translation_accuracy","model":model,"tag":tag,"n_pairs":len(PAIRS),
         "no_think":no_think,
         "ja2en_chrf":round(chrf.corpus_score(j2e_h,[j2e_r]).score,2),
         "en2ja_chrf":round(chrf.corpus_score(e2j_h,[e2j_r]).score,2),
         "metric":"chrF (sacrebleu, reference-grade sanity, NOT full WMT)"}
    print(json.dumps(rec,ensure_ascii=False),flush=True)
    with open(os.path.expanduser(f"~/translate_samples2_{tag}.json"),"w",encoding="utf-8") as f:
        json.dump({"summary":rec,"samples":samples},f,ensure_ascii=False,indent=2)
    print(f"[{tag}] ja2en={rec['ja2en_chrf']} en2ja={rec['en2ja_chrf']} no_think={no_think}",file=sys.stderr)

if __name__=="__main__": main()
