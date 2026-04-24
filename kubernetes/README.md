# Kubernetes manifests

Source-controlled YAML manifests for the workloads running on the k3s cluster.

One directory per logical workload, e.g. `hello/`, `grafana/`, `structurizr/`, each holding the Deployment + Service (+ any supporting resources).

## Conventions

- **Namespace**: workloads go in `default` unless there's a good reason to segregate. When we start running multi-tenant or production-style setups, each tenant/env gets its own namespace.
- **Exposure**: workloads are exposed externally via nginx on `lab-gateway` (see `../services/nginx/conf.d/`), not via an in-cluster ingress. Services are either `ClusterIP` (proxied from outside via NodePort indirection) or `NodePort` when the external proxy needs a stable port.
- **Images pinned to version**: `image: traefik/whoami:v1.10`, never `:latest`. Reproducibility.
- **Resource requests + limits on every container**: small defaults for lab, nothing should be unbounded.

## Apply and verify

From any machine with `kubectl` pointed at this cluster:

```bash
kubectl apply -f kubernetes/hello/hello.yaml
kubectl get pods -l app=hello -o wide
kubectl get svc hello
```

## Layout

```
kubernetes/
  README.md             you are here
  hello/                smoke-test workload (whoami echo server)
    hello.yaml
```

New workloads go in their own directory under this one.
