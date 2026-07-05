#!/usr/bin/env python3
"""EmbeddingGemma-only JA retrieval accuracy, loading from pre-fetched flat dir."""
import json, os, sys, math
import numpy as np

LOCAL_ONNX = os.path.expanduser("~/egemma_int8/model_quantized.onnx")
REPO = "onnx-community/embeddinggemma-300m-ONNX"
QPFX = "task: search result | query: "
DPFX = "title: none | text: "

DATA = [
  ("日本の首都はどこですか", "日本の首都は東京で、政治・経済の中心地です。",
   ["富士山は日本で最も高い山で標高3776メートルです。","大阪は西日本最大の商業都市です。","北海道は日本最北の島です。"]),
  ("光合成とは何ですか", "光合成は植物が光エネルギーを使い二酸化炭素と水から糖を作る反応です。",
   ["呼吸は酸素を使いエネルギーを取り出す過程です。","蒸散は植物が水分を放出する現象です。","発酵は微生物が糖を分解する反応です。"]),
  ("消費税の標準税率は何パーセントですか", "日本の消費税の標準税率は10パーセントです。",
   ["所得税は累進課税で最高45パーセントです。","法人税率はおよそ23パーセントです。","軽減税率は食料品などに8パーセント適用されます。"]),
  ("水の沸点は摂氏何度ですか", "標準大気圧のもとで水の沸点は摂氏100度です。",
   ["水の氷点は摂氏0度です。","エタノールの沸点は約78度です。","人間の体温は約36度です。"]),
  ("機械学習における過学習とは", "過学習は訓練データに適合しすぎて未知データへの汎化性能が下がる現象です。",
   ["勾配降下法は損失を最小化する最適化手法です。","正則化は過学習を抑える手法の一つです。","バッチ正規化は学習を安定させます。"]),
  ("徳川家康が開いた幕府は", "徳川家康は江戸幕府を開き初代将軍となりました。",
   ["織田信長は室町幕府を滅ぼしました。","豊臣秀吉は天下統一を果たしました。","源頼朝は鎌倉幕府を開きました。"]),
  ("DNAの正式名称は", "DNAはデオキシリボ核酸の略で遺伝情報を担う分子です。",
   ["RNAはリボ核酸で転写に関わります。","タンパク質はアミノ酸から構成されます。","染色体はDNAが折りたたまれた構造です。"]),
  ("円周率のおよその値は", "円周率はおよそ3.14で円の周と直径の比を表します。",
   ["自然対数の底は約2.72です。","黄金比は約1.62です。","平方根2は約1.41です。"]),
  ("インフレーションとは何か", "インフレーションは物価が継続的に上昇し貨幣価値が下がる現象です。",
   ["デフレーションは物価が下がる現象です。","為替レートは通貨の交換比率です。","金利は資金を借りる際の費用です。"]),
  ("光の速さはおよそ秒速何キロメートルですか", "光の速さは真空中でおよそ秒速30万キロメートルです。",
   ["音の速さは秒速約340メートルです。","地球の公転速度は秒速約30キロメートルです。","第一宇宙速度は秒速約7.9キロメートルです。"]),
]

def log(*a): print(*a, file=sys.stderr, flush=True)
def ndcg10(flags):
    dcg=sum((1.0/math.log2(i+2)) for i,r in enumerate(flags[:10]) if r)
    return dcg/(1.0/math.log2(2))

def main():
    import onnxruntime as ort
    from transformers import AutoTokenizer
    tok=AutoTokenizer.from_pretrained(REPO)
    so=ort.SessionOptions(); so.intra_op_num_threads=os.cpu_count(); so.inter_op_num_threads=1
    sess=ort.InferenceSession(LOCAL_ONNX,sess_options=so,providers=["CPUExecutionProvider"])
    in_names={i.name for i in sess.get_inputs()}
    def enc(texts):
        e=tok(texts,padding=True,truncation=True,max_length=256,return_tensors="np")
        feed={}
        for k in ("input_ids","attention_mask","token_type_ids"):
            if k in in_names: feed[k]=e[k].astype(np.int64) if k in e else np.zeros_like(e["input_ids"],dtype=np.int64)
        o=sess.run(None,feed)[0]
        if o.ndim==3:
            m=e["attention_mask"][:,:,None].astype(np.float32); o=(o*m).sum(1)/np.clip(m.sum(1),1e-9,None)
        return o/np.clip(np.linalg.norm(o,axis=1,keepdims=True),1e-9,None)
    docs=[]; seen={}
    for q,g,ds in DATA:
        for d in [g]+ds:
            if d not in seen: seen[d]=len(docs); docs.append(d)
    de=enc([DPFX+d for d in docs])
    ndcgs=[]; recs=[]
    for q,g,ds in DATA:
        qe=enc([QPFX+q])[0]; order=np.argsort(-(de@qe))
        flags=[docs[order[i]]==g for i in range(len(order))]
        ndcgs.append(ndcg10(flags)); recs.append(1.0 if seen[g] in order[:10] else 0.0)
    rec={"kind":"embedding_accuracy","instance":os.environ.get("BENCH_INSTANCE","c8g.8xlarge"),
         "model":"embeddinggemma-300m","quant":"model_quantized.onnx","task":"ja_retrieval_mini",
         "n_queries":len(DATA),"corpus_size":len(docs),
         "ndcg@10":round(float(np.mean(ndcgs)),4),"recall@10":round(float(np.mean(recs)),4)}
    print(json.dumps(rec,ensure_ascii=False),flush=True)
    log(f"[embeddinggemma-300m] nDCG@10={rec['ndcg@10']} Recall@10={rec['recall@10']}")

if __name__=="__main__": main()
