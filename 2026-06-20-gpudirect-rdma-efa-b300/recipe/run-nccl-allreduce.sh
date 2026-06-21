#!/usr/bin/env bash
# デモ2: 2 ノード x 8GPU = 16 GPU の nccl-tests all_reduce を EFA(GPUDirect RDMA)経由で回す。
# ノード間 SSH(鍵共有 + port 2222 sshd)をセットアップしてから mpirun で束ねる。
#
# 前提: manifests/10-two-nodes.yaml を apply 済み。
# Usage: NAMESPACE=myuser-gpudirect-rdma ./recipe/run-nccl-allreduce.sh
set -euo pipefail
NS="${NAMESPACE:-myuser-gpudirect-rdma}"
PORT="${SSH_PORT:-2222}"

SRV_IP="$(kubectl -n "$NS" get pod rdma-server -o jsonpath='{.status.podIP}')"
CLI_IP="$(kubectl -n "$NS" get pod rdma-client -o jsonpath='{.status.podIP}')"
echo "[info] server=$SRV_IP client=$CLI_IP ssh_port=$PORT"

echo "[step] server で SSH 鍵生成"
kubectl -n "$NS" exec rdma-server -- bash -lc '
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  [ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q
  cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  printf "StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\n" > /root/.ssh/config && chmod 600 /root/.ssh/config'

echo "[step] 同じ鍵ペアを client へ配布 (両ノードが相互に SSH 可能に)"
PRIV="$(kubectl -n "$NS" exec rdma-server -- bash -lc 'base64 -w0 < /root/.ssh/id_rsa')"
PUB="$(kubectl -n "$NS" exec rdma-server -- bash -lc 'cat /root/.ssh/id_rsa.pub')"
kubectl -n "$NS" exec rdma-client -- bash -lc "
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  echo '$PRIV' | base64 -d > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa
  echo '$PUB' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\n' > /root/.ssh/config && chmod 600 /root/.ssh/config"

echo "[step] 両 pod で sshd(port $PORT) 起動 (22 は node の実 sshd と衝突するため別ポート)"
for POD in rdma-server rdma-client; do
  kubectl -n "$NS" exec "$POD" -- bash -lc "mkdir -p /run/sshd; ssh-keygen -A 2>/dev/null; pgrep -f 'sshd -p $PORT' || /usr/sbin/sshd -p $PORT"
done

echo "[step] mpirun で 16 GPU all_reduce (NCCL_SOCKET_IFNAME は除外パターン ^ が必須)"
kubectl -n "$NS" exec rdma-server -- bash -lc "
export PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:\$PATH
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:/opt/amazon/openmpi/lib:/usr/local/cuda/lib64:\$LD_LIBRARY_PATH
mpirun --allow-run-as-root -np 16 -N 8 -H $SRV_IP:8,$CLI_IP:8 \
  --mca plm_rsh_args '-p $PORT' \
  -x LD_LIBRARY_PATH -x PATH \
  -x FI_PROVIDER=efa -x FI_EFA_USE_DEVICE_RDMA=1 -x FI_EFA_FORK_SAFE=1 \
  -x NCCL_SOCKET_IFNAME='^lo,docker,veth' -x NCCL_DEBUG=INFO \
  /opt/nccl-tests/build/all_reduce_perf -b 8M -e 2G -f 2 -g 1 2>&1 \
  | grep -iE 'Selected provider|transport protocol|busbw|Avg bus|^ *[0-9]+ +[0-9]+ +float'
"
echo "[done] 'Selected provider is efa' が出れば GPUDirect RDMA over EFA で動いた証拠"
