# P3: weight sync 計測 (設計を P1 の発見で改訂)

## 当初設計 (Fable 提案)

方式軸 (colocated CUDA IPC vs disaggregated NCCL/EFA) x モデルサイズ (1.7B/4B/8B) で
time = 固定オーバーヘッド + サイズ/実効帯域 の線形フィットを取り、B300 実測
(colocated 1.5s / disagg 0.3s / 30B disagg 10.1s) と突き合わせる。
事前予測は「colocated が遅い原因は ipc_collect() GC と Ray IPC handle 往復という
ソフト要因なのでハード不変、H200 でも 1.5s が再現する」。

## 改訂理由: P1 で TP 依存が見つかった

P1 の副産物として、H200 colocated の weight sync が TP で大きく動くことが判明した。

| TP | weight sync |
|---|---|
| 1 | 0.5s |
| 2 | 1.8s |

事前予測の 1.5s は「H200 TP1 では 0.5s」で外れており、むしろ TP2 の 1.8s が
B300 の 1.5s に近い。つまり B300 の 1.5s は「colocated だから遅い」のではなく
**その run の TP 設定が効いていた**可能性がある。だとすると「colocated は
disaggregated より 5 倍遅い」という既存の結論は、方式差ではなく TP 差を
方式差と誤って帰属していた恐れがある。これは既発表の主張に関わるので確認が要る。

## 改訂後の測定軸

3 軸に拡張する。

1. **方式**: colocated (CUDA IPC) vs disaggregated (NCCL/EFA、trainer をノード A・
   rollout エンジンをノード B に置く純 EFA パス)
2. **TP**: 1 / 2 / 4 / 8 (P1 の値は step 0 の単一測定なので、ここで定常値を複数回取る)
3. **モデルサイズ**: 1.7B / 4B / 8B (線形フィットで切片=レイテンシ支配と
   傾き=帯域支配を分離)

全組み合わせは 2x4x3=24 セルで多すぎるので、次の順で削る。
- まず colocated x TP{1,2,4,8} x 4B (4 セル) で TP 依存を確定させる
- 次に disaggregated x TP{1,8} x 4B (2 セル) で「方式差は TP を揃えても残るか」を見る
  -> ここが B300 結論の再検証の核心
- 最後に colocated x TP1 x {1.7B, 8B} (2 セル) でサイズスケーリング

計 8 セル。NUM_ROLLOUT=3 にして各セルで weight sync を 3 回踏ませ、
初回 (接続確立を含む) と定常を分けて記録する。

## 何が言えるか

- TP を揃えても colocated が disaggregated より遅ければ、既存の帰属 (ソフト要因) は
  正しく、B300 の結論もそのまま成立する。追加で TP 依存という新しい軸が付く。
- TP を揃えたら差が消えるなら、B300 の「5 倍差」は TP 交絡であり、既存の主張を
  訂正する必要がある。これは自分たちの過去の結論を否定する結果だが、
  正確さの方が重要。
- いずれにせよ「TP を上げると訓練は速くなるが weight sync は遅くなる」という
  トレードオフの定量化は実務的な新知見になる。
