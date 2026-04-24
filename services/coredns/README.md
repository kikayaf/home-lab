# CoreDNS

Source-controlled config for the CoreDNS instance that serves `*.lab.local` resolution across the lab.

## Deployed on

`lab-gateway` (`192.168.100.201`), as a Docker container, bound to the lab interface. Config file `Corefile` is mounted read-only at `/etc/coredns/Corefile`.

## What it does

- **`lab.local` zone**: authoritative for every lab VM's FQDN (`lab-gateway.lab.local`, `lab-k3s-controlplane.lab.local`, etc.), populated by the `hosts` plugin. `reload 5s` means edits to `Corefile` take effect without restarting the container.
- **Everything else**: forwarded upstream to `1.1.1.1` and `8.8.8.8`, cached 5 minutes.

## Deploy / update

From the Windows host:

```powershell
scp C:\vmimages\services\coredns\Corefile lab-gateway:/tmp/Corefile
ssh lab-gateway "sudo mkdir -p /opt/coredns && sudo mv /tmp/Corefile /opt/coredns/Corefile && sudo chmod 644 /opt/coredns/Corefile"
```

If the container is already running and you just updated the Corefile, the `reload 5s` directive makes CoreDNS pick up the new config automatically. For larger changes or to be certain:

```bash
docker restart coredns
```

## First-time container run

On `lab-gateway`:

```bash
docker run -d \
    --name coredns \
    --restart unless-stopped \
    -p 192.168.100.201:53:53/udp \
    -p 192.168.100.201:53:53/tcp \
    -v /opt/coredns:/etc/coredns:ro \
    coredns/coredns:1.11.3 \
    -conf /etc/coredns/Corefile
```

Port binding is scoped to `192.168.100.201:53` so we don't conflict with `systemd-resolved` on `127.0.0.53:53` (lab-gateway's own stub resolver).

## Adding a new VM

Edit `Corefile`, add a line in the `hosts` block:

```
192.168.100.209 lab-newvm.lab.local
```

Commit, `scp` to lab-gateway, done. The `reload 5s` inside the `hosts` block does the rest.
