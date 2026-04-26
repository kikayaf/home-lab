# Structurizr (self-hosted DSL renderer)

Self-hosted renderer for the architecture DSL at [`../../architecture/workspace.dsl`](../../architecture/workspace.dsl). Uses the current `structurizr/structurizr` image in `local` mode (the successor to the now-deprecated `structurizr/lite`).

## Deployed on

`lab-platform-eng` (`192.168.100.208`) as a Docker container on port `8081` (internal). Reached via nginx at `https://arch.lab.local`.

## What it does

Structurizr (in `local` mode) is a Java web app that watches a directory for a `workspace.dsl` file, parses it, and serves the System Context, Container, Component, and Deployment views as interactive diagrams. Changes to the DSL trigger auto-reload within a few seconds.

The diagrams are generated on-demand from the DSL; no image files, no export step. The rendered page is what anyone visiting `arch.lab.local` sees, always reflecting the current committed DSL.

## How the DSL gets to lab-platform-eng

Structurizr Lite needs the `workspace.dsl` file in its working directory. Since the canonical source is in this git repo, we clone the repo onto `lab-platform-eng` and mount the `architecture/` subdirectory into the container.

Update options:

- **Manual**: `ssh lab-platform-eng` then `cd /srv/structurizr/home-lab && git pull`. Fine for personal lab.
- **Cron**: `*/5 * * * * cd /srv/structurizr/home-lab && git pull --quiet` on lab-platform-eng. Picks up changes within 5 minutes.
- **Push from Windows host**: `scp C:\vmimages\architecture\workspace.dsl lab-platform-eng:/srv/structurizr/home-lab/architecture/workspace.dsl`. Useful when editing on Windows and wanting immediate update without committing.

Any of them works; the container only cares that the file on disk changes.

## First-time install

See [`../../runbooks/stage-3-structurizr.md`](../../runbooks/stage-3-structurizr.md) for the full walkthrough.

## Security notes

- The DSL contains no secrets (credentials are references like "postgres at lab-datastore" not actual passwords), so exposing the rendered diagrams to the whole lab is fine.
- No auth in front today. Anyone on the tailnet or lab subnet can view. If we ever want to gate access, add nginx basic auth or put it behind Cloudflare Access.
- Source DSL is world-readable in git (public repo) so there's no additional exposure from rendering it.
