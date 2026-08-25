# n8n-autoscaling — Repo context

## What this is

The deployment repo for a production, self-hosted n8n instance running on a Hetzner VPS — the automation backbone for Aurora Backcountry. Started as a fork of `conor-is-my-name/n8n-autoscaling`, but it's now on its own path: upstream is reference material only, and useful upstream commits are cherry-picked deliberately, never merged blindly (docker-compose.yml and autoscaler.py have intentionally diverged).

This repo's job is to always match what is actually deployed on the server. Treat `main` as the record of production.

## Stack and architecture

- Docker Compose stack, queue mode: `n8n` (editor/API) + `n8n-webhook` (dedicated webhook processor) + `n8n-worker` (autoscaled), Redis 7 (BullMQ queue), Postgres 17 + pgvector, Cloudflare Tunnel for all public traffic.
- Task runners run in **internal mode** (child processes inside each n8n container) — chosen for speed (~300ms vs ~2s per Code node vs external mode). `Dockerfile.runner` and `n8n-task-runners.json` are dormant; they only matter if external mode returns (needed for Puppeteer/Playwright browser automation, or Python Code nodes with packages).
- `autoscaler/autoscaler.py` polls Redis queue depth and scales `n8n-worker` between MIN/MAX replicas via `docker compose up --scale` through the mounted Docker socket. Each worker runs `worker --concurrency=20` (compose command), so bursts are absorbed in-process before container scaling kicks in.
- All n8n containers share the `n8n_main` volume — required for binary data to flow between webhook and workers in queue mode. Never split this.
- The n8n version is pinned in two places: `Dockerfile` (`n8nio/n8n`) and `Dockerfile.runner` (`n8nio/runners`). Always bump both to the same tag.
- **AI Assistant (`instance-ai`) runs on a self-hosted sandbox**: `sandbox-certs` (one-shot mTLS bootstrap into the `sandbox_tls` volume), `sandbox-api`, and `sandbox-runner-1`, a **privileged Docker-in-Docker** container that executes the code the Assistant writes. Confined to `n8n-network` with no host port bindings and never on `shark`. n8n deliberately does **not** `depends_on` these services, so a sandbox failure disables the Assistant without touching workflow execution.
- `n8n-backup` (Compose `backup` profile, active in production): scheduled pg_dump + Redis RDB + n8n volume archive to the `backup_data` volume, uploaded to Cloudflare R2 via rclone. Runs daily 02:00 UTC and on every container start (`BACKUP_RUN_ON_START=true`), so each stack restart takes a free pre-change snapshot. Restore drill last passed 2026-07-09.

## Constraints and gotchas

- **This repo is public on GitHub.** Never commit secrets, server IPs, SSH details, or real `.env` values. Server-specific details live only in gitignored files: `.env`, `env.md`, `HETZNER_DEPLOYMENT_NOTES.md`, `backup/rclone.conf` (R2 credentials).
- A change to docker-compose.yml or the Dockerfiles is not real until rolled out on the server. When making such changes, say explicitly whether they've been deployed.
- The autoscaler image **bakes `docker-compose.yml` in at build time** (`COPY docker-compose.yml .` in `autoscaler/Dockerfile`). Any compose change affecting `n8n-worker` must be followed by `docker compose build n8n-autoscaler` on the server, or autoscaled workers will be created from the stale baked-in definition.
- The compose file expects an external Docker network named `shark` (`docker network create shark` on a fresh host).
- Port bindings use `${TAILSCALE_IP:-127.0.0.1}` — empty `TAILSCALE_IP` means host-only. Never bind Postgres or n8n to 0.0.0.0; public traffic enters via the Cloudflare Tunnel only. DB access from a workstation goes through an SSH tunnel.
- The n8n base image has no package manager (`apk` is stripped) — extra tools are COPY'd in from an Alpine builder stage. Single binaries only; a full runtime tree (e.g. python3) is deliberately not added (n8n's internal-mode Python runner is debug-only per upstream; the startup warning about it is known and harmless).
- **`sandbox-runner-1` is the highest-privilege container in this stack.** It is privileged Docker-in-Docker on the host that holds Postgres, every workflow credential, and the n8n encryption key, and its job is running LLM-written code. n8n's own docs call the self-hosted sandbox dev/test-grade and recommend Daytona for production; self-hosting was chosen deliberately (2026-08-24) to keep code and workflow data inside the network. If the risk calculus ever changes, switching to Daytona is an `.env` + compose change, not a rebuild.
- The `.env` on the server is authoritative; the local copy is a synced backup. Some values deliberately override compose defaults (e.g. `EXECUTIONS_DATA_SAVE_ON_SUCCESS=all` — kept for execution history in the UI; flip to `none` if DB volume ever becomes a concern).
- Timezone is `America/Vancouver` (`GENERIC_TIMEZONE`): cron triggers fire in Pacific time, DB timestamps stay UTC.
- Community nodes: install via the UI on the main instance, then restart `n8n-webhook` and `n8n-worker` so existing containers rescan the shared nodes folder. Fresh autoscaled workers pick them up automatically.
- No tests, no CI. Verification = deploy and smoke-test (editor loads, `/healthz` ok, one short workflow + one Code node run).

## Development workflow

- **Upgrading n8n is automated**: the `biweekly-n8n-upgrade` scheduled Claude task (1st & 15th, 9am) checks Docker Hub's `stable` tag, gates on breaking changes, bumps, takes a pre-upgrade backup, deploys, verifies, and rolls back on failure. `docs/n8n-version-upgrades.md` is the manual runbook it follows — keep the two consistent if either changes.
- Server access commands and rollout details with real values: `HETZNER_DEPLOYMENT_NOTES.md` (gitignored, local machine only).
- Mid-day restarts of the stack are currently acceptable.

## Current focus

- Steady state: the stack was hardened and automated in July 2026 (localhost-only ports, R2 backups with verified restore, biweekly auto-upgrades, worker concurrency 20). Keep it that way — prefer small, deployed-and-verified changes.
- Known deferred performance levers, to pull if volume grows: Postgres memory tuning (still on stock defaults) and the `EXECUTIONS_DATA_SAVE_ON_SUCCESS` decision above.
- Watch upstream for cherry-pickable improvements; adopt only what fits the internal-runner architecture.

## How to work in this repo

- Fix what's asked. If you see a bigger structural issue that the fix touches, name it briefly and ask before refactoring.
- If a change conflicts with patterns elsewhere in the repo (or with what's deployed), flag it before writing code.
- Follow existing patterns; this is an ops repo, so clarity and reproducibility beat cleverness.
- Read before guessing — especially the gitignored notes files, which hold the deployment truth.
