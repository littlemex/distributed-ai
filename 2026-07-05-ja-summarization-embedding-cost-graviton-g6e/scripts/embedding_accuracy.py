#!/usr/bin/env python3
"""Japanese embedding retrieval-accuracy probe (reference-grade).
Builds a small JA query->gold-doc set with distractors, computes nDCG@10 and
Recall@10 per model. Purpose: sanity-check that JA embedding is NOT broken and
relative ordering matches published JMTEB. NOT a full JMTEB run.
Emits JSON Lines. Prefixes are applied per model (critical for ruri/e5/gemma).
"""
import json, os, sys, math
import numpy as np

# (name, hf_repo, onnx_path, query_prefix, doc_prefix)
MODELS = [
    ("ruri-v3-30m",  "sirasagi62/ruri-v3-30m-ONNX",  "onnx/model_int8.onnx", "検索クエリ: ", "検索文書: "),
    ("ruri-v3-70m",  "sirasagi62/ruri-v3-70m-ONNX",  "onnx/model_int8.onnx", "検索クエリ: ", "検索文書: "),
    ("ruri-v3-130m", "sirasagi62/ruri-v3-130m-ONNX", "onnx/model_int8.onnx", "検索クエリ: ", "検索文書: "),
    ("ruri-v3-310m", "sirasagi62/ruri-v3-310m-ONNX", "onnx/model_int8.onnx", "検索クエリ: ", "検索文書: "),
    ("me5-small",    "intfloat/multilingual-e5-small","onnx/model.onnx",     "query: ",     "passage: "),
]
# EmbeddingGemma handled separately (flat-dir load) if present.

# Small JA retrieval set: (query, gold_doc, [distractors...]). Hand-written, factual.
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

def ndcg_at_k(ranked_gold_flags, k=10):
    dcg=0.0
    for i,rel in enumerate(ranked_gold_flags[:k]):
        if rel: dcg += 1.0/math.log2(i+2)
    # ideal: 1 relevant doc at top
    idcg = 1.0/math.log2(2)
    return dcg/idcg if idcg>0 else 0.0

def encode(sess, tok, in_names, texts, seqlen=128):
    import numpy as np
    enc = tok(texts, padding=True, truncation=True, max_length=seqlen, return_tensors="np")
    feed={}
    for k in ("input_ids","attention_mask","token_type_ids"):
        if k in in_names:
            feed[k]=enc[k].astype(np.int64) if k in enc else np.zeros_like(enc["input_ids"],dtype=np.int64)
    out = sess.run(None, feed)[0]
    # mean-pool if 3D (token embeddings); else assume already pooled
    if out.ndim==3:
        mask = enc["attention_mask"][:,:,None].astype(np.float32)
        out = (out*mask).sum(1)/np.clip(mask.sum(1),1e-9,None)
    # L2 normalize
    out = out/np.clip(np.linalg.norm(out,axis=1,keepdims=True),1e-9,None)
    return out

def main():
    import onnxruntime as ort
    from transformers import AutoTokenizer
    from huggingface_hub import hf_hub_download
    instance=os.environ.get("BENCH_INSTANCE","unknown")

    so=ort.SessionOptions(); so.intra_op_num_threads=os.cpu_count(); so.inter_op_num_threads=1
    so.graph_optimization_level=ort.GraphOptimizationLevel.ORT_ENABLE_ALL

    # build corpus: all gold + all distractors (unique), track gold index per query
    all_docs=[];
    for q,g,ds in DATA:
        all_docs.append(g); all_docs.extend(ds)
    # dedup preserving order
    seen={}; docs=[]
    for d in all_docs:
        if d not in seen: seen[d]=len(docs); docs.append(d)

    for name,repo,onnx_rel,qpfx,dpfx in MODELS:
        try:
            tok=AutoTokenizer.from_pretrained(repo)
            local=hf_hub_download(repo,onnx_rel)
            sess=ort.InferenceSession(local,sess_options=so,providers=["CPUExecutionProvider"])
            in_names={i.name for i in sess.get_inputs()}
        except Exception as e:
            log(f"[{name}] load FAIL: {e}"); continue
        try:
            doc_emb=encode(sess,tok,in_names,[dpfx+d for d in docs])
            ndcgs=[]; recalls=[]
            for q,g,ds in DATA:
                qe=encode(sess,tok,in_names,[qpfx+q])[0]
                sims=doc_emb@qe
                order=np.argsort(-sims)
                gold_idx=seen[g]
                flags=[docs[order[i]]==g for i in range(len(order))]
                ndcgs.append(ndcg_at_k(flags,10))
                recalls.append(1.0 if gold_idx in order[:10] else 0.0)
            rec={"kind":"embedding_accuracy","instance":instance,"model":name,"quant":onnx_rel.split("/")[-1],
                 "task":"ja_retrieval_mini","n_queries":len(DATA),"corpus_size":len(docs),
                 "ndcg@10":round(float(np.mean(ndcgs)),4),"recall@10":round(float(np.mean(recalls)),4)}
            print(json.dumps(rec,ensure_ascii=False),flush=True)
            log(f"[{name}] nDCG@10={rec['ndcg@10']} Recall@10={rec['recall@10']}")
        except Exception as e:
            log(f"[{name}] eval FAIL: {e}")

if __name__=="__main__":
    main()
