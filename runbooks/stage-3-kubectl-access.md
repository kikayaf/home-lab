# Stage 3, Step 3: kubectl access from lab-gateway and Mac

## Goal

Make `kubectl` work against the k3s cluster from `lab-gateway` (useful for edge admin) and from your Mac over Tailscale (day-to-day use). Avoid having to SSH into the control plane for every `kubectl` command.

## Architecture change

**Before:** `kubectl` only worked from `lab-k3s-controlplane` itself, using `/etc/rancher/k3s/k3s.yaml` (server URL `https://127.0.0.1:6443`).

**After:** `kubectl` works from anywhere with Tailscale and the right kubeconfig. Kubeconfig server URL points at `https://192.168.100.202:6443`. The TLS SAN we added at server install (`--tls-san=192.168.100.202` and `--tls-san=lab-k3s-controlplane.lab.local`) lets clients validate the API server's cert when hitting those names.

## Prerequisites

- Steps 3.1 and 3.2 done (server running on controlplane, agents joined).
- Mac has Tailscale installed and accepting subnet routes (so `192.168.100.0/24` is reachable).

## Step 3.3.1: Install kubectl on lab-gateway

k3s's kubeconfig works with any kubectl client; we don't need k3s's bundled one elsewhere. Pin the client version to the cluster version.

```bash
ssh lab-gateway

KUBECTL_VERSION=v1.34.6
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl

kubectl version --client
```

## Step 3.3.2: Copy the kubeconfig and rewrite the server URL

```bash
# On lab-gateway
mkdir -p ~/.kube
scp lab-k3s-controlplane:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Rewrite 127.0.0.1 -> 192.168.100.202 so it works from off-host
sed -i 's|server: https://127.0.0.1:6443|server: https://192.168.100.202:6443|' ~/.kube/config

chmod 600 ~/.kube/config

kubectl get nodes
```

Alternate server URL using the FQDN (same TLS SAN machinery):

```bash
sed -i 's|server: https://192.168.100.202:6443|server: https://lab-k3s-controlplane.lab.local:6443|' ~/.kube/config
```

Either works. IP is a tiny bit faster (no DNS lookup per request); FQDN is more resilient if the control plane IP changes.

## Step 3.3.3: Install kubectl on Mac and copy the kubeconfig

On the Mac:

```bash
# Install kubectl (direct, since no Homebrew)
uname -m    # check arch: arm64 = Apple Silicon, x86_64 = Intel

# For Apple Silicon:
curl -LO "https://dl.k8s.io/release/v1.34.6/bin/darwin/arm64/kubectl"

# For Intel:
# curl -LO "https://dl.k8s.io/release/v1.34.6/bin/darwin/amd64/kubectl"

chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl

# Pull the kubeconfig from lab-gateway (note the explicit adminuser@)
mkdir -p ~/.kube
scp adminuser@lab-gateway:~/.kube/config ~/.kube/config
chmod 600 ~/.kube/config

kubectl get nodes -o wide
```

Three nodes Ready from the Mac confirms the whole tailnet subnet-route path.

## Deployed configuration artifacts

- `/usr/local/bin/kubectl` on `lab-gateway` and Mac (v1.34.6 matches cluster).
- `~/.kube/config` on `lab-gateway` (adminuser's home) and on Mac (Felix's home). Server URL rewritten to the cluster IP or FQDN.
- `chmod 600` on both copies (contains client cert + key for cluster-admin).

## Gotchas

**A. Tailscale SSH username mismatch.** When SSHing from Mac to `lab-gateway`, Tailscale SSH intercepts the connection. If your Mac user doesn't match any Linux user on lab-gateway, Tailscale SSH rejects with `failed to look up local user "<name>"`. Workaround: always specify `adminuser@hostname` when SSHing/SCPing from the Mac. Long-term fix: add an SSH config alias that sets `User adminuser` or configure Tailscale ACLs to map your Mac user to adminuser.

**B. Stale known_hosts.** After we rebuilt any VM during stage 2 troubleshooting, the new SSH host keys don't match the ones cached on previous clients. Fix: `ssh-keygen -R <hostname>` and reconnect once to accept the new key.

**C. Pre-existing kubectl on lab-k3s-controlplane.** Left over from some earlier step; k3s noticed and didn't overwrite with its own symlink. Without `KUBECONFIG` set, the stray kubectl defaults to `localhost:8080` and fails. Fix: `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` in the shell, documented in stage-3-k3s-cluster.md's gotchas.

## Next

- [`stage-3-smoke-test.md`](./stage-3-smoke-test.md): the first workload end-to-end, proving DNS + subnet routing + nginx + k3s NodePort + pod scheduling all work together.
