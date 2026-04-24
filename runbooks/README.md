# Runbooks

Stage-by-stage operational guides for the home lab. One file per logical phase. Each runbook documents what was done, why, how to verify, and how to roll back.

These are the authoritative "how it actually happened" record. Architecture intent lives in [`../architecture/`](../architecture/); scripts that automate stage 1 live in [`../scripts/`](../scripts/); these runbooks describe the operator actions taken on the running lab.

## Index

| Runbook | Phase | Status |
|---|---|---|
| [`stage-2-lab-gateway.md`](./stage-2-lab-gateway.md) | Steps 1-4: promote `lab-gateway` to the real egress router (Tailscale, dual-homing, iptables NAT, fleet default-gateway flip) | Done |
| [`stage-2-step-5-coredns.md`](./stage-2-step-5-coredns.md) | Step 5: CoreDNS on `lab-gateway` for `*.lab.local` resolution and Tailscale Split DNS | Done |
| [`stage-2-step-6-nginx.md`](./stage-2-step-6-nginx.md) | Step 6: nginx reverse proxy on `lab-gateway` with DNS wildcard for unknown `*.lab.local` | Done |
| [`stage-2-step-7-ufw.md`](./stage-2-step-7-ufw.md) | Step 7: host firewall policy on every lab VM | Done |
| [`stage-3-k3s-cluster.md`](./stage-3-k3s-cluster.md) | Stage 3 steps 1-2: k3s server on controlplane, agents on node01/node02 | Done |

Stage 1 (provisioning the 8-VM fleet from a template) is automated end to end in [`../scripts/`](../scripts/) and doesn't need a runbook, the scripts are the runbook.

## Conventions used inside each runbook

- **Goal**: one sentence describing what the phase accomplishes.
- **Architecture change**: before/after diff of the lab's topology or service set.
- **Prerequisites**: what must already be in place for the phase to make sense.
- **Steps**: each step is a section with:
  - **What we did**: the concrete operator action.
  - **Why**: the reasoning, especially any non-obvious tradeoffs.
  - **Commands**: the exact commands used, in copy-pasteable blocks.
  - **Verify**: how to confirm it worked.
  - **Rollback**: how to undo it cleanly.
- **Deployed artifacts**: pointers to configuration files that embody the phase's end state (netplan YAML, iptables rules, etc.).
- **Gotchas**: things that bit us during execution. Kept so we don't re-discover them.
- **Next**: what comes after.
