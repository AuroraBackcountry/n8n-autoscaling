# n8n-autoscaling — Context for Claude

## What this is

The deployment repo for a production, self-hosted n8n instance running on a Hetzner VPS — the automation backbone for Aurora Backcountry. Started as a fork of `conor-is-my-name/n8n-autoscaling`, but it's now on its own path: upstream is reference material only, and useful upstream commits are cherry-picked deliberately, never merged blindly (docker-compose.yml and autoscaler.py have intentionally diverged).

This repo's job is to always match what is actually deployed on the server. Treat `main` as the record of production.

## Stack and architecture

- Docker Compose stack, queue mode: `n8n` (editor/API) + `n8n-webhook` (dedicated webhook processor) + `n8n-worker` (autoscaled), Redis 7 (BullMQ queue), Postgres 17 + pgvector, Cloudflare Tunnel for all public traffic.
- Task runners run in **internal mode** (child processes inside each n8n container) — chosen for speed (~300ms vs ~2s per Code node vs external mode). `Dockerfile.runner` and `n8n-task-runners.json` are dormant; they only matter if external mode returns (needed for Puppeteer/Playwright browser automation).
- `autoscaler/autoscaler.py` polls Redis queue depth and scales `n8n-worker` between MIN/MAX replicas via `docker compose up --scale` through the mounted Docker socket.
- All n8n containers share the `n8n_main` volume — required for binary data to flow between webhook and workers in queue mode. Never split this.
- The n8n version is pinned in two places: `Dockerfile` (`n8nio/n8n`) and `Dockerfile.runner` (`n8nio/runners`). Always bump both to the same tag.

## Constraints and gotchas

- **This repo is public on GitHub.** Never commit secrets, server IPs, SSH details, or real `.env` values. Server-specific details live only in gitignored files: `.env`, `env.md`, `HETZNER_DEPLOYMENT_NOTES.md`.
- A change to docker-compose.yml or the Dockerfiles is not real until rolled out on the server. When making such changes, say explicitly whether they've been deployed.
- The compose file expects an external Docker network named `shark` (`docker network create shark` on a fresh host).
- The autoscaler image **bakes `docker-compose.yml` in at build time** (`COPY docker-compose.yml .` in `autoscaler/Dockerfile`). Any compose change affecting `n8n-worker` must be followed by `docker compose build n8n-autoscaler` on the server, or autoscaled workers will be created from the stale baked-in definition.
- Port bindings use `${TAILSCALE_IP:-127.0.0.1}` — empty `TAILSCALE_IP` means host-only. Never bind Postgres or n8n to 0.0.0.0; public traffic enters via the Cloudflare Tunnel only. DB access from a workstation goes through an SSH tunnel.
- Timezone is `America/Vancouver` (`GENERIC_TIMEZONE`): cron triggers fire in Pacific time, DB timestamps stay UTC.
- Community nodes: install via the UI on the main instance, then restart `n8n-webhook` and `n8n-worker` so existing containers rescan the shared nodes folder. Fresh autoscaled workers pick them up automatically.
- No tests, no CI. Verification = deploy and smoke-test (editor loads, `/healthz` ok, one short workflow + one Code node run).

## Development workflow

- **Upgrading n8n** (the most common task): follow `docs/n8n-version-upgrades.md`. Short version: pick a version from n8n releases, confirm the Docker Hub tags exist, bump both `FROM` lines to the same tag, commit and push, then on the server `git pull`, `docker compose build n8n n8n-webhook n8n-worker`, `docker compose up -d`, and verify `n8n --version` plus editor/webhook smoke tests. Rollback = revert the two `FROM` lines and rebuild.
- Server access commands and rollout details with real values: `HETZNER_DEPLOYMENT_NOTES.md` (gitignored, local machine only).
- Backups run from the `n8n-backup` service (ported from upstream, `backup` Compose profile): scheduled pg_dump + volume archives to the `backup_data` volume, optional rclone push to remote storage.
- Mid-day restarts of the stack are currently acceptable.

## Current focus

- Keep n8n as fast and optimized as possible (internal runners, runner memory tuning) and make version upgrades painless.
- Watch upstream for cherry-pickable improvements; adopt only what fits the internal-runner architecture.

## How to work in this repo

- Fix what's asked. If you see a bigger structural issue that the fix touches, name it briefly and ask before refactoring.
- If a change conflicts with patterns elsewhere in the repo (or with what's deployed), flag it before writing code.
- Follow existing patterns; this is an ops repo, so clarity and reproducibility beat cleverness.
- Read before guessing — especially the gitignored notes files, which hold the deployment truth.
