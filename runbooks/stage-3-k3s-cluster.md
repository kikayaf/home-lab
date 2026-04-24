# Stage 3, Steps 1-2: k3s cluster (control plane + 2 agents)

## Goal

Stand up a 3-node Kubernetes cluster across `lab-k3s-controlplane` (server) and `lab-k3s-node01` / `lab-k3s-node02` (agents). After this, workloads can be deployed as pods and the rest of stage 3 layers on top.

## Architecture change

**Before (end of stage 2):** three VMs (`lab-k3s-controlplane`, `lab-k3s-node01`, `lab-k3s-node02`) running Ubuntu with nothing on them. Networking, DNS, nginx, firewall all handled by stage 2.

**After (end of step 3.2):** those same three VMs form a functioning Kubernetes cluster. One control plane (API server, scheduler, controller-manager, embedded SQLite datastore) and two workers (kubelet + containerd hosting pods).

## Prerequisites

- Stage 2 complete (DNS, routing, nginx, ufw).
- Swap disabled on all three VMs (cloud-init handled this at provision).
- All three VMs reach the internet via `lab-gateway` (confirmed in stage 2 step 4).

## Step 3.1: k3s server on lab-k3s-controlplane

### What we did

Installed k3s in server mode with Traefik disabled. Traefik is k3s's default in-cluster ingress; we already have nginx on lab-gateway doing reverse proxy, so we don't want two ingress layers. External HTTP lands at nginx, which forwards to k3s Services (NodePort or ClusterIP).

### Commands

```bash
ssh lab-k3s-controlplane

curl -sfL https://get.k3s.io | sh -s - server \
    --write-kubeconfig-mode=644 \
    --disable=traefik \
    --tls-san=lab-k3s-controlplane.lab.local \
    --tls-san=192.168.100.202 \
    --node-name=lab-k3s-controlplane
```

Flag reasoning:

- `--write-kubeconfig-mode=644`: kubeconfig at `/etc/rancher/k3s/k3s.yaml` is readable by regular users, so we can `scp` it around later.
- `--disable=traefik`: no default ingress controller; nginx on lab-gateway owns that responsibility.
- `--tls-san=lab-k3s-controlplane.lab.local` and `--tls-san=192.168.100.202`: adds both the FQDN and the direct IP as valid subjects on the API server's TLS cert, so kubectl from different names doesn't trip over cert mismatches.
- `--node-name=lab-k3s-controlplane`: without this, k3s would use the Linux hostname, which is identical here. Explicit for clarity.

### Verify

After the install finishes:

```bash
# kubeconfig location (not the default ~/.kube/config)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

# Service healthy
sudo systemctl status k3s --no-pager | head
# active (running)

# Cluster state
kubectl get nodes
# NAME                    STATUS   ROLES           AGE   VERSION
# lab-k3s-controlplane    Ready    control-plane   1m    v1.34.6+k3s1

kubectl get pods -A
# kube-system   coredns-<hash>                          1/1 Running
# kube-system   local-path-provisioner-<hash>           1/1 Running
# kube-system   metrics-server-<hash>                   1/1 Running
```

### Save the node token

Agents need this to join:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Treat it as a secret. It's not catastrophic on its own (also needs network reach to `:6443`, which is tailnet / lab-subnet only), but don't commit it. Rotate with `k3s token rotate` if it leaks.

### Rollback

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

Removes k3s, kubelet state, containerd state, and the systemd unit.

## Step 3.2: Join lab-k3s-node01 and lab-k3s-node02 as agents

### What we did

Same k3s installer script, but in agent mode, pointed at the control plane via env vars.

### Commands (run on each agent VM)

```bash
ssh lab-k3s-node01

curl -sfL https://get.k3s.io | \
    K3S_URL=https://192.168.100.202:6443 \
    K3S_TOKEN=<token-from-server> \
    sh -s - agent \
    --node-name=lab-k3s-node01
```

Repeat for `lab-k3s-node02` with `--node-name=lab-k3s-node02`.

Why env vars instead of flags for URL/token:

- `K3S_URL` has the side-effect of switching the installer into agent mode. Elegant if a little implicit.
- `K3S_TOKEN` is passed via env so it doesn't show up in `ps` output. After install, the token is hashed into `/var/lib/rancher/k3s/agent/node-password` and the env var isn't persisted.

### Verify

On each agent:

```bash
sudo systemctl status k3s-agent --no-pager | head
# active (running)
```

On the control plane:

```bash
kubectl get nodes -o wide
```

Expected: three Ready nodes with correct internal IPs and matching k3s version:

```
NAME                    STATUS   ROLES           VERSION        INTERNAL-IP
lab-k3s-controlplane    Ready    control-plane   v1.34.6+k3s1   192.168.100.202
lab-k3s-node01          Ready    <none>          v1.34.6+k3s1   192.168.100.203
lab-k3s-node02          Ready    <none>          v1.34.6+k3s1   192.168.100.204
```

### Rollback (per agent)

```bash
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

Removes the agent from the cluster and cleans up local state.

## Deployed configuration artifacts

- **k3s server**: `lab-k3s-controlplane`, v1.34.6+k3s1, `/usr/local/bin/k3s`. Systemd unit `/etc/systemd/system/k3s.service`. Kubeconfig at `/etc/rancher/k3s/k3s.yaml` (mode 644). SQLite datastore at `/var/lib/rancher/k3s/server/db/`.
- **k3s agents**: node01 and node02, same version. Systemd unit `/etc/systemd/system/k3s-agent.service`. Kubelet state at `/var/lib/kubelet/`. containerd at `/var/lib/rancher/k3s/agent/containerd/`.
- **System pods running on the control plane**: CoreDNS (cluster DNS, separate from lab-gateway's CoreDNS and serving `*.svc.cluster.local` for internal service discovery), local-path-provisioner (HostPath storage class), metrics-server (node/pod metrics API).

## Gotchas

**A. Pre-existing `kubectl` binary shadows the k3s install.** Our template image already had `/usr/local/bin/kubectl` from an earlier session. The k3s installer sees it and skips the symlink with `Skipping /usr/local/bin/kubectl symlink to k3s, already exists`. The stray binary has no default kubeconfig, so it tries `localhost:8080` and errors out. Fix: set `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` in your shell. Alternative fix is to remove `/usr/local/bin/kubectl` and let k3s's symlink replace it.

**B. Cluster DNS ("cluster.local") vs lab DNS ("lab.local").** k3s runs its OWN CoreDNS inside the cluster for service discovery (`foo.namespace.svc.cluster.local`). Our lab-gateway CoreDNS serves `*.lab.local`. They're completely separate and don't conflict; they live at different IPs and answer different zones. The cluster's CoreDNS listens on a ClusterIP internal to the pod network (10.43.x.x); lab CoreDNS listens on 192.168.100.201.

**C. k3s version v1.34.6+k3s1 is newer than the docs I was working from.** k3s follows upstream Kubernetes; both are on a fast release cadence. If this runbook goes stale, the install command itself is the same; only the observed version string changes.

## Next

- `stage-3-step-3-kubectl.md` (planned): kubectl access from `lab-gateway` and from the Mac, so we don't need to SSH into the control plane for every `kubectl apply`.
- `stage-3-step-4-smoke-test.md` (planned): first workload (nginx echo server or similar), exposed via nginx on lab-gateway at `hello.lab.local` to verify the whole stack.
- Then real workloads: postgres+minio on lab-datastore, observability stack on lab-ai-ops, Structurizr Lite on lab-platform-eng.
