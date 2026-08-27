#!/usr/bin/env python3
"""Render a conversation-affinity router in front of the serving replicas, for an A/B.

AIPerf sends `X-Correlation-ID`, and it is stable for every turn of one conversation — InferenceX's own
recipes say so and use it as the hash key. With the plain Kubernetes Service a conversation's later turns
land on whichever replica the connection picks, and a turn that lands on the replica without its prefix
pays full prefill: measured, the two replicas reported 86.2% and 66.1% cache hit rates during the same
run, and consecutive identical calls oscillated between 35,904 and 9,504 cached tokens.

This is nginx with `hash ... consistent`, not vllm-router or Envoy, deliberately. It exists to answer one
question — how much of the missing tenth is routing — with the fewest new moving parts. If affinity wins,
promoting it to the router the benchmark's own recipes use is the follow-up, not this.

Two things it must not get wrong, because either would fake a pass:
  * SSE must stream. `proxy_buffering off` and HTTP/1.1, or every time-to-first-token becomes a
    time-to-last-token and the comparison is meaningless.
  * The hash key must actually arrive. nginx hashes an empty string to a single upstream, which would look
    like perfect affinity while proving nothing, so the key is logged per request and the log is checked.
"""

import subprocess
import sys

CTX = "distai-eks"
NS = "qwen-trial"


def pod_ips() -> list[str]:
    out = subprocess.run(
        ["kubectl", "--context", CTX, "-n", NS, "get", "pod",
         "-l", "app.kubernetes.io/name=vllm-serving",
         "--field-selector=status.phase=Running",
         "-o", "jsonpath={range .items[*]}{.status.podIP}{'\\n'}{end}"],
        capture_output=True, text=True, check=True)
    return [ip for ip in out.stdout.split("\n") if ip.strip()]


CONF = """\
worker_processes auto;
events {{ worker_connections 8192; }}
http {{
  # The hash key is logged so a run can prove the header was present. An absent key hashes to one
  # upstream and would read as perfect affinity.
  log_format affinity '$remote_addr key=[$http_x_correlation_id] -> $upstream_addr $status $request_time';
  access_log /dev/stdout affinity;
  upstream vllm {{
    hash $http_x_correlation_id consistent;
{servers}
    keepalive 256;
  }}
  server {{
    listen 8000;
    # Agentic turns can take a minute and a half on a cache miss.
    proxy_connect_timeout 30s;
    proxy_send_timeout 1200s;
    proxy_read_timeout 1200s;
    client_max_body_size 512m;
    location / {{
      proxy_pass http://vllm;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $host;
      # Streaming, not buffering: without this every TTFT becomes a TTLT.
      proxy_buffering off;
      proxy_request_buffering off;
      chunked_transfer_encoding on;
    }}
  }}
}}
"""

MANIFEST = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: qwen-affinity-conf
  namespace: {ns}
data:
  nginx.conf: |
{conf}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen-affinity
  namespace: {ns}
spec:
  replicas: 1
  selector: {{matchLabels: {{app: qwen-affinity}}}}
  template:
    metadata:
      labels: {{app: qwen-affinity}}
      annotations: {{karpenter.sh/do-not-disrupt: "true"}}
    spec:
      containers:
        - name: nginx
          image: public.ecr.aws/nginx/nginx:1.27-alpine
          ports: [{{containerPort: 8000}}]
          volumeMounts:
            - {{name: conf, mountPath: /etc/nginx/nginx.conf, subPath: nginx.conf}}
          resources:
            requests: {{cpu: "2", memory: 1Gi, ephemeral-storage: 512Mi}}
            limits: {{cpu: "4", memory: 2Gi, ephemeral-storage: 1Gi}}
      volumes:
        - {{name: conf, configMap: {{name: qwen-affinity-conf}}}}
---
apiVersion: v1
kind: Service
metadata:
  name: qwen-affinity
  namespace: {ns}
spec:
  selector: {{app: qwen-affinity}}
  ports: [{{port: 8000, targetPort: 8000}}]
"""


def main() -> int:
    ips = pod_ips()
    if len(ips) < 2:
        print(f"affinity routing needs at least two replicas; found {len(ips)}", file=sys.stderr)
        return 1
    servers = "\n".join(f"    server {ip}:8000 max_fails=0;" for ip in ips)
    conf = CONF.format(servers=servers)
    print(MANIFEST.format(ns=NS, conf="\n".join("    " + line for line in conf.split("\n"))))
    print(f"# upstreams: {', '.join(ips)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
