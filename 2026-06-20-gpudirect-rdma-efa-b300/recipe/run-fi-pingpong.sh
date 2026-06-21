#!/usr/bin/env bash
# デモ1: 2 ノード間で fi_pingpong を回し、EFA RDMA の往復レイテンシ(RTT)を測る。
#
# 前提: manifests/10-two-nodes.yaml を apply 済みで rdma-server / rdma-client が
#       別ノードで Running になっていること。
#
# Usage: NAMESPACE=myuser-gpudirect-rdma ./recipe/run-fi-pingpong.sh
set -euo pipefail
NS="${NAMESPACE:-myuser-gpudirect-rdma}"

SRV_IP="$(kubectl -n "$NS" get pod rdma-server -o jsonpath='{.status.podIP}')"
echo "[info] server IP = $SRV_IP (hostNetwork なので node IP)"

echo "[step] EFA provider 確認 (fi_info -p efa)"
kubectl -n "$NS" exec rdma-server -- \
  bash -lc 'export PATH=/opt/amazon/efa/bin:$PATH; fi_info -p efa -t FI_EP_RDM | head -8'

echo "[step] server 側で fi_pingpong をバックグラウンド起動"
kubectl -n "$NS" exec rdma-server -- bash -lc \
  'export PATH=/opt/amazon/efa/bin:$PATH; pkill fi_pingpong 2>/dev/null || true;
   nohup fi_pingpong -p efa -e rdm -I 1000 >/tmp/pp.log 2>&1 & echo started'
sleep 3

echo "[step] client 側から接続して RTT 測定"
kubectl -n "$NS" exec rdma-client -- bash -lc \
  "export PATH=/opt/amazon/efa/bin:\$PATH; fi_pingpong -p efa -e rdm -I 1000 $SRV_IP"

echo "[done] usec/xfer 列が 1 往復あたりのマイクロ秒 (RTT 相当)"
