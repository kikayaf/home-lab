# Stage 3, Step 4: smoke-test workload

## Goal

Prove the whole stack in one request. Deploy a tiny echo server on k3s, expose it via nginx at `http://hello.lab.local`, curl from the Mac over Tailscale, and verify the request hits a pod and comes back.

After this step, we know everything we built in stages 2 and 3 cooperates correctly. Every future workload is just a new pair of files following this pattern.

## Architecture change

Nothing structural. First workload lands on the cluster. The nginx + k3s + DNS handoff is exercised for real.

## Prerequisites

- Stage 2 complete (nginx, CoreDNS with wildcard, Tailscale, ufw).
- Stage 3 steps 1-3 done (cluster up, kubectl accessible).

## Step 3.4.1: Deploy the workload

Manifest at [`../kubernetes/hello/hello.yaml`](../kubernetes/hello/hello.yaml):

- `Deployment` with 2 replicas of `traefik/whoami:v1.10` (tiny Go echo server).
- `Service` of type `NodePort` on port `30080`, so nginx can reach it on any node's lab IP.

Apply from Windows PowerShell:

```powershell
scp C:\vmimages\kubernetes\hello\hello.yaml lab-gateway:/tmp/hello.yaml
ssh lab-gateway "kubectl apply -f /tmp/hello.yaml"

ssh lab-gateway "kubectl get pods -l app=hello -o wide"
ssh lab-gateway "kubectl get svc hello"
```

Expected:

- 2 pods `Running`, one on `lab-k3s-node01` and one on `lab-k3s-node02`. Pod IPs in `10.42.x.x`.
- Service `hello` of type `NodePort` with port `30080:80/TCP`.

### Design notes

- **NodePort over ClusterIP + ingress**: we don't have a k8s ingress controller (traefik disabled, no nginx-ingress installed, no MetalLB). The simplest way to expose the Service to nginx on lab-gateway is `NodePort`: kube-proxy listens on a fixed port (30080) on every node's network interface. nginx on lab-gateway proxies to any node:30080 and kube-proxy routes to a pod.
- **Explicit nodePort**: we pin `30080` in the manifest. Without this, k8s picks a random port in `30000-32767` on every apply, and nginx has to be updated. Pinning keeps nginx's config stable.
- **CPU/memory limits on the container**: defense against runaway code. `10m` CPU request, `50m` limit, `16Mi`/`64Mi` memory. whoami uses way less than this.

## Step 3.4.2: Add the nginx vhost

Config at [`../services/nginx/conf.d/hello.conf`](../services/nginx/conf.d/hello.conf):

- Upstream block with all three lab-k3s node IPs (`:30080` each).
- Server block matching `server_name hello.lab.local`, `proxy_pass http://k3s_hello`.
- Proxy headers set so the backend sees the real client (via `X-Forwarded-For` and `X-Real-IP`).

Push and reload:

```powershell
scp C:\vmimages\services\nginx\conf.d\hello.conf lab-gateway:/tmp/hello.conf
ssh lab-gateway "sudo mv /tmp/hello.conf /opt/nginx/conf.d/hello.conf && sudo chmod 644 /opt/nginx/conf.d/hello.conf"
ssh lab-gateway "docker exec nginx nginx -t && docker exec nginx nginx -s reload"
```

### Design notes

- **Upstream with all three nodes**: works even on the control plane where there's no hello pod, because kube-proxy on every node (including the control plane) handles NodePort traffic and routes to a pod.
- **`max_fails=2 fail_timeout=5s`**: if a node is down, nginx skips it after 2 failures for 5 seconds. Graceful degradation.

## Step 3.4.3: Verify from Mac

```bash
dig hello.lab.local +short
# 192.168.100.201 (wildcard -> lab-gateway)

curl -s http://hello.lab.local/
# Full whoami response: Hostname, IPs, headers

# Hit it multiple times, Hostname should flip between the two pods
for i in 1 2 3 4 5 6; do curl -s http://hello.lab.local/ | grep Hostname; done
```

### What to look for in the response

- `Hostname: hello-<replicaset>-<pod>` — which pod served the request.
- `IP: 10.42.x.x` — pod IP on the k3s cluster network.
- `RemoteAddr: 10.42.0.0:<port>` — what the pod sees as the caller. `10.42.0.0` is kube-proxy; the real client is masked by iptables SNAT inside the cluster. This is normal for NodePort Services.
- `X-Real-IP: 100.x.y.z` — the client's tailnet IP, preserved by nginx. This is how you see the actual caller when SNAT has hidden it at the cluster level.
- `X-Forwarded-For: 100.x.y.z` — same.
- `Host: hello.lab.local` — the original Host header, also preserved.

## Full request path, in order

```
Mac curl http://hello.lab.local/

1. Mac DNS                  tailnet Split DNS: *.lab.local -> 192.168.100.201
2. CoreDNS @ lab-gateway    wildcard -> 192.168.100.201
3. Mac TCP 80               routed via tailnet subnet router (Tailscale)
                            egress: lab-gateway eth0 on 192.168.100.0/24
4. nginx :80                matches server_name hello.lab.local
                            proxy_pass to http://k3s_hello upstream
5. One of 3 node IPs:30080  kube-proxy iptables rules
6. kube-proxy               DNAT to a pod IP (10.42.x.x)
7. hello pod (whoami)       responds with request details
8. reverse path             back up the chain
```

## Deployed configuration artifacts

- `kubernetes/hello/hello.yaml`: Deployment + Service.
- `services/nginx/conf.d/hello.conf`: nginx vhost.
- No state persisted on disk (whoami is stateless).

## Pattern for future workloads

Every additional web-facing service follows this pattern:

1. Write a manifest in `kubernetes/<service>/` with Deployment + Service (optionally ConfigMap, PersistentVolumeClaim, etc.).
2. `kubectl apply` it.
3. Write an nginx vhost in `services/nginx/conf.d/<service>.conf` with upstream pointing at the Service's NodePort (or a direct node IP if the service runs on a specific VM outside the cluster).
4. `scp` + `docker exec nginx -s reload`.
5. `curl http://<service>.lab.local/` to verify.

No DNS edits (the wildcard catches everything). No extra firewall rules (ufw allows lab subnet full access). No extra Tailscale config.

## Removing the smoke-test workload (optional)

You can leave `hello` running as a canary for future sanity checks:

```bash
curl -s http://hello.lab.local/ | grep Hostname
```

If it returns a pod hostname, the stack is healthy.

To remove:

```bash
kubectl delete -f /tmp/hello.yaml
# and delete services/nginx/conf.d/hello.conf + reload nginx
```

## Next

Stage 3 is now past its foundational phase. Upcoming workload runbooks (one per service as they get deployed):

- Postgres + MinIO + restic on `lab-datastore`.
- Observability stack (Prometheus, Grafana, Loki) on `lab-ai-ops` or on the cluster.
- Structurizr Lite on `lab-platform-eng` (self-hosted, self-documenting).
- code-server (or similar) on `lab-platform-eng` + Tailscale Funnel for browser-based lab access from restricted networks.
- Workflow runner on `lab-automation`.
