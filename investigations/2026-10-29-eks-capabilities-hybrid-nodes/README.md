# Deploying to BYOI hybrid nodes and non-EKS Kubernetes from the EKS Capabilities managed Argo CD

This directory checks, on real infrastructure, whether one Managed Argo CD (the Argo CD that EKS Capabilities runs for you) can deploy Helm charts both to your own machines joined to EKS as hybrid nodes (bring your own infrastructure, BYOI) and to Kubernetes clusters that are not EKS (AKS, GKE, self-built clusters). Every number and log line in the accompanying Zenn article can be reproduced with the code here.

## Results

| # | Check | Result |
|---|---|---|
| T1 | Managed Argo CD deploys a Helm chart to a machine joined as a hybrid node | Deployed. The Pods run on that node with IPs from the BYOI pod CIDR and answer a request sent from a Pod on a cloud node |
| T2 | Register a non-EKS cluster in Managed Argo CD by API server URL and token | Refused. The Application condition shows `server should be specified as a cluster ARN` and no namespace is created on k3s |
| T3 | Managed Argo CD installs a relay Argo CD on EKS, and the relay Argo CD deploys to a non-EKS cluster (k3s) | Deployed. The two Applications on Managed Argo CD (`tier2-argocd` and `tier2-apps`) and the relay Argo CD's Application are Synced and Healthy |
| T4 | Change only the values of two Applications on Managed Argo CD (`podinfo-onprem` and `tier2-apps`) | On both targets the Deployment rolls out every replica and each Pod returns the new message on its own IP |
| T5 | A Deployment deleted by hand on the non-EKS cluster is recreated by the relay Argo CD | Recreated |
| T6 | With the cluster API endpoint private only, see where the hybrid node's kubelet connects | It connects to a private address in the hub VPC |

Managed Argo CD deploys only to targets given as EKS cluster ARNs. BYOI machines become reachable once they join an EKS cluster as hybrid nodes. Non-EKS clusters are reached through a relay Argo CD that Managed Argo CD installs.

## Layout

Three VPCs joined by a Transit Gateway stand in for three environments.

| VPC | CIDR | Role | Contents |
|---|---|---|---|
| hub | 10.0.0.0/16 | AWS | EKS cluster (private API endpoint only), one managed node group node, Managed Argo CD |
| onprem | 10.80.0.0/16 | BYOI | One EC2 instance joined as a hybrid node. Pod CIDR 10.81.0.0/16 |
| other | 10.90.0.0/16 | Non-EKS Kubernetes | One EC2 instance running k3s |

The Transit Gateway stands in for the VPN or Direct Connect link between BYOI and AWS. The BYOI EC2 instance has no instance profile; its only AWS identity is a Systems Manager hybrid activation, the same as when a physical server joins.

Running EKS Hybrid Nodes on EC2 or in other clouds is [not supported by AWS](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html#hybrid-nodes-general). This layout is a stand-in for verification, not a production design.

## Directory

```
2026-10-29-eks-capabilities-hybrid-nodes/
├── terraform/
│   ├── main.tf                  three VPCs, Transit Gateway, EKS, hybrid node, k3s, Managed Argo CD
│   └── userdata/                boot scripts for the hybrid node and k3s
├── k8s/
│   ├── cilium-values.yaml       Cilium that runs only on hybrid nodes
│   ├── t1-podinfo-onprem.yaml   T1 Application
│   ├── t2-podinfo-direct.yaml   T2 Application
│   ├── t3-tier2-argocd.yaml     T3 relay Argo CD and the Application it owns
│   └── k3s-deployer-sa.yaml     ServiceAccount the relay Argo CD uses on k3s
├── scripts/
│   ├── run-all.sh               build, verify and delete in order; deletion always runs
│   ├── env.sh                   derives every other value from three inputs (read by run-all.sh and cleanup.sh)
│   ├── verify.sh                runs T1 to T6 and prints [PASS] or [FAIL] for each
│   ├── port-forward.sh          reaches the private API endpoint through an SSM port forward
│   ├── register-k3s.sh          registers k3s as an Argo CD cluster
│   ├── ssm-run.sh               runs a command through SSM Run Command
│   └── cleanup.sh               deletes everything
└── results/                     verify.sh output (verify.log)
```

Every operation on a node goes through SSM Run Command; SSH is not used.

## Reproduce

Requirements: Terraform 1.9 or later, AWS CLI v2 with the Session Manager plugin, kubectl, Helm 3.8 or later, Python 3, and nc. Authenticate the AWS CLI with permissions to create and delete VPC, EKS, EC2, IAM, Systems Manager and S3 resources, and with at least an hour left before the credentials expire. The AWS account needs an IAM Identity Center instance and a user, because Managed Argo CD signs in through Identity Center; Identity Center may be in another Region. `env.sh` first checks the tools, their versions and the AWS CLI credentials, and stops before creating anything if one is missing.

Set three values for your environment. `AWS_REGION` is where the environment is built, `IDC_REGION` is the Region of IAM Identity Center, and `TF_STATE_BUCKET` is your S3 bucket for the Terraform state.

```bash
export AWS_REGION=us-east-2
export IDC_REGION=us-east-1
export TF_STATE_BUCKET=your-terraform-state-bucket
```

`scripts/env.sh` derives the rest. It looks up the state bucket's Region, and if Identity Center has exactly one user, makes that user the Managed Argo CD admin. With several users it stops before creating anything and prints one `export TF_VAR_idc_admin_user_name=...` line per user; paste the line for the admin in the same shell and run `./scripts/run-all.sh` again.

Then build, verify and delete. The build takes about 20 minutes and the checks about 15.

```bash
git clone https://github.com/littlemex/distributed-ai.git && cd distributed-ai/investigations/2026-10-29-eks-capabilities-hybrid-nodes && ./scripts/run-all.sh
```

`run-all.sh` stops before creating anything when a value is missing or cannot be looked up, when several Identity Center users exist, when the state cannot be read, or when the state key (`eks/ekscap-hub/terraform.tfstate`) is not empty. Otherwise it runs `terraform apply`, `verify.sh` and `cleanup.sh` in order, and `cleanup.sh` runs even when the build or the checks fail. `verify.sh` prints `[PASS]` or `[FAIL]` for each of T1 to T6 and writes the same lines to `results/verify.log`. A last line of `build=0 verify=0 cleanup=0` with exit status 0 means the build, every check and the deletion all succeeded.

`verify.sh` reaches the EKS API endpoint on local port 8443. If the port is in use it stops; set `export LOCAL_PORT=` to a free port and run again. Pressing Ctrl-C makes `run-all.sh` delete what it built with `cleanup.sh` before it exits.

While it runs, you are billed for the EKS cluster, Managed Argo CD, three EC2 instances (managed node group, hybrid node, k3s), the hybrid node per-vCPU fee, a NAT Gateway, and a Transit Gateway with three attachments. If `cleanup` ends non-zero, something is left; run the following in the same shell until its last line is `deregister=0 destroy=0 resources left in state=0`.

```bash
./scripts/cleanup.sh
```

To delete from a new shell, run the three `export` lines first (and `TF_VAR_idc_admin_user_name` if you set it), then run `./scripts/cleanup.sh` in the cloned directory.

## What each check shows

**T1** shows that Managed Argo CD deploys directly to a BYOI machine. Argo CD talks only to the EKS API server on the AWS side, and the Kubernetes scheduler decides which node runs a Pod, so setting `nodeSelector` to `eks.amazonaws.com/compute-type: hybrid` in the Application places the Pods on the BYOI machine. `verify.sh` checks that every Pod runs on that node with an IP in 10.81.0.0/16 and that a Pod on a cloud node gets an answer through the Service.

**T2** shows that a non-EKS cluster cannot be registered in Managed Argo CD directly. The error text indicates that building the RESTConfig fails because `server` is not an ARN. The [AWS documentation](https://docs.aws.amazon.com/eks/latest/userguide/argocd-comparison.html) says "The capability supports only Amazon EKS clusters as deployment targets using EKS cluster ARNs (not Kubernetes API server URLs)." `verify.sh` keeps the full condition text on an `[INFO]` line.

**T3** shows how to reach a non-EKS cluster. Managed Argo CD installs a regular open source Argo CD on the hub cluster (Helm chart `argo-cd`) and also deploys the Applications that Argo CD owns (Helm chart `argocd-apps`). The relay Argo CD is a regular Argo CD, so it can register k3s by API URL and token. It shares the CRDs that Managed Argo CD installed, so the chart runs with `crds.install: false` and the relay Argo CD stays on the same minor version as Managed Argo CD (3.4). The relay Argo CD cannot target the hub it runs on (`cluster.inClusterEnabled: "false"`), and the k3s Application uses the AppProject `edge`, which allows only the `podinfo-other` namespace on k3s and only the podinfo chart repository, instead of `default`. Some settings are left at the chart defaults: the relay Argo CD's application-controller has a ClusterRole that can read and write the whole hub cluster, and its UI and API use the local admin rather than Identity Center.

**T4** shows that changing what is deployed takes only the Applications on Managed Argo CD, because the relay Argo CD's Applications are also delivered by Managed Argo CD as `argocd-apps` values. The cluster secret that registers k3s holds a token, so `register-k3s.sh` writes it directly to the relay Argo CD's namespace and Managed Argo CD does not deliver it. A target counts as done when the Deployment's ready, updated and total replicas all equal the new count and every Running Pod returns the new message on its own IP. Both targets are polled in one loop every 5 seconds, so the seconds are an upper bound from the first patch that includes the polling interval and the SSM Run Command round trips.

**T5** shows that the relay Argo CD detects drift on its target and reverts it. The deletion time and the recreated Deployment's `creationTimestamp` both come from the k3s machine's clock.

**T6** shows that the path to BYOI is private. A cluster with hybrid nodes [cannot use public and private endpoint access together](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-cluster-create.html), because nodes outside the VPC would resolve the endpoint to public IPs. Here the endpoint is private only, so the kubelet reaches an ENI in the hub VPC through the Transit Gateway. Managed Argo CD [can deploy to private-only clusters](https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html#_private_clusters).

## Limits

- BYOI and the non-EKS cluster are simulated on EC2. On real BYOI machines the hybrid node goes through VPN or Direct Connect, and the OS must be on the [AWS supported list](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-os.html).
- VMs or bare metal in other clouds are not supported as hybrid nodes by AWS. nodeadm has no code that detects and rejects other clouds, but that does not make them supported.
- To keep the checks short, Argo CD was given `AmazonEKSClusterAdminPolicy` and `cluster-admin`. In production, narrow namespaces and resources to [least privilege](https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html#_production_setup_with_least_privilege).
- Maintaining the relay Argo CD (upgrades, availability) is your responsibility. AWS runs only Managed Argo CD.
- The T4 seconds are upper bounds that include the polling interval and SSM Run Command round trips, not the time Argo CD itself takes to apply a change.
- Deployment to a non-EKS cluster was checked with k3s only; AKS and GKE were not tried.
- T2 decides pass or fail from the error text that Managed Argo CD returns. If AWS changes the text, T2 reports FAIL even though the target is still refused.
