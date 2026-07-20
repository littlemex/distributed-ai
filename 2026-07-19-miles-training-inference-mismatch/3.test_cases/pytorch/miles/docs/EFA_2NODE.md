# 2-node EFA verification (p5en.48xlarge x2)

Hardware verification that multi-node NCCL runs over EFA on this cluster, using two
Capacity Block p5en.48xlarge nodes (8x H200 each, us-east-2a, same UltraCluster). No
placement group is used or needed: a Capacity Block already colocates its nodes within one
UltraCluster spine, and `PlacementGroupArn` on the reservation is null, so layering a
self-made cluster placement group would only risk "capacity reserved but PG-unsatisfiable".

## Result: EFA works across 2 nodes

`torchrun --nnodes 2 --nproc_per_node 8` running a NCCL all_reduce (16 GPUs), with
`NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET`:

- Both nodes: `NET/OFI Selected provider is efa, fabric is efa-direct (found 8 nics)`.
- Inter-node channels: `Channel .. : 3[3] -> 14[6] [send] via NET/Libfabric/3/GDRDMA`,
  `GPU Direct RDMA Enabled`. Zero `NET/Socket` lines (no TCP fallback).
- Bandwidth (algbw / busbw, all_reduce, 16 GPUs):

  | message | algbw | busbw |
  | --- | --- | --- |
  | 64 MB | 101.5 | 190.3 GB/s |
  | 256 MB | 100.5 | 188.5 GB/s |
  | 1024 MB | 127.2 | 238.4 GB/s |
  | 4096 MB | 135.8 | 254.7 GB/s |
  | 8192 MB | 137.1 | 257.1 GB/s |

busbw 190-257 GB/s is far above the ~10 GB/s a TCP path would give, confirming EFA. The
pods request `vpc.amazonaws.com/efa: 8` of the node's 16 EFA cards, so this is roughly half
the fabric; requesting all 16 is expected to reach ~300+ GB/s (a throughput improvement,
not a correctness issue).

## Root cause fixed: EFA security-group needs self-referencing egress

The first 2-node run failed even though NCCL selected the efa provider and established
GPUDirect RDMA channels: every data transfer timed out with
`NET/OFI ... Error 15 (Unreachable remote (never received a response))`.

Cause: the EFA security group had self-referencing all-traffic on **ingress** but only
`0.0.0.0/0` on **egress**. EFA's OS-bypass SRD traffic is not IP traffic, so a CIDR egress
rule does not authorize it -- EFA SGs need self-referencing all-traffic on BOTH directions.
Bootstrap (TCP over eth0) and NCCL init succeeded under the asymmetric rule, which is why
the failure only appeared at the first SRD data transfer.

Fix (in this repo's `infra/eks/sg.tf`): added `aws_security_group_rule.efa_node_egress_self`
(self-referencing, all protocols). Single-node EFA was unaffected because intra-node traffic
does not traverse the SG.

## How to reproduce the check

1. Two EFA nodes in the same subnet with the EFA SG (self-ref ingress AND egress).
2. sshd not required -- use torchrun with `--master_addr <rank0 pod IP>`; NCCL data path is
   EFA regardless of the launcher.
3. On each pod: `FI_PROVIDER=efa NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET
   NCCL_SOCKET_IFNAME=eth0 torchrun --nnodes 2 --node_rank <0|1> --nproc_per_node 8
   --master_addr <IP> --master_port 29500 bench.py`.
4. Pass: `Selected provider is efa` on both nodes, inter-node `[send] via NET/Libfabric`,
   no `NET/Socket`, busbw > 100 GB/s. Fail (TCP): busbw single-digit GB/s, or Error 15
   (check the SG self-ref egress rule first).
