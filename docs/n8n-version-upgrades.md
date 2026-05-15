# n8n version upgrades (custom Docker build)

This repo extends the official n8n image with extra tools (ffmpeg, git, jq, curl, graphicsmagick, etc.). Upgrading n8n means **bumping the pinned base image tags** and **rebuilding** the three services that use `Dockerfile`.

## What to keep in sync

| File | What to change |
|------|----------------|
| `Dockerfile` | `FROM n8nio/n8n:<version>` |
| `Dockerfile.runner` | `FROM n8nio/runners:<version>` (same semver as n8n; used if you ever re-enable external task runners) |
| `env.md` | Update the “Pinned Docker bases” line and add a short changelog entry |

**Rule:** Use the **same version number** for `n8nio/n8n` and `n8nio/runners` (e.g. both `2.14.2`).

## Choose a target version

1. Check [n8n releases](https://github.com/n8n-io/n8n/releases) for notes, breaking changes, and migrations.
2. Confirm the tag exists on Docker Hub: [n8nio/n8n tags](https://hub.docker.com/r/n8nio/n8n/tags), [n8nio/runners tags](https://hub.docker.com/r/n8nio/runners/tags).
3. Optional: on the server (or any host with Docker), verify the image runs:
   ```bash
   docker pull n8nio/n8n:2.14.2
   docker run --rm n8nio/n8n:2.14.2 n8n --version
   ```

## Local (repo) steps

1. Edit `Dockerfile`: set `FROM n8nio/n8n:<new-version>`.
2. Edit `Dockerfile.runner`: set `FROM n8nio/runners:<new-version>`.
3. Update `env.md` (pinned bases + changelog).
4. Commit and push (or copy files to the server—see below).

## Server (Hetzner) steps

Default project path on the server: `/opt/n8n-autoscaling`.

**Option A — copy from your machine**

```bash
scp Dockerfile Dockerfile.runner root@<SERVER_IP>:/opt/n8n-autoscaling/
```

**Option B — `git pull` on the server** (if the repo is deployed from git)

```bash
ssh root@<SERVER_IP> 'cd /opt/n8n-autoscaling && git pull'
```

**Build and roll out**

```bash
ssh root@<SERVER_IP> 'cd /opt/n8n-autoscaling && \
  docker compose build n8n n8n-webhook n8n-worker && \
  docker compose up -d n8n n8n-webhook n8n-worker'
```

Docker will pull the new base layers when the `FROM` tag changes. You normally do **not** need `docker compose build --no-cache` unless you are debugging a bad cache.

## Verify after upgrade

```bash
ssh root@<SERVER_IP> 'docker exec n8n-autoscaling-n8n-1 n8n --version'
```

Smoke checks:

- Editor loads: `https://n8n.guideops.app` (or your `N8N_HOST`).
- Health: `https://n8n.guideops.app/healthz` → JSON with `"ok"`.
- Webhook path still works if you use a separate host (e.g. `webhook.guideops.app`).
- Run one short workflow and one Code node if you rely on internal task runners.

n8n applies database migrations on startup when needed; watch main container logs if something fails on first boot:

```bash
docker logs n8n-autoscaling-n8n-1 --tail 100
```

## Rollback

1. Revert the two `FROM` lines to the previous tag (or `git revert`).
2. On the server: same `docker compose build` + `up -d` commands as above.

## What this guide does **not** cover

- **Cloudflare / DNS** — unchanged by n8n upgrades unless you change hostnames.
- **`.env` secrets** — do not commit; server keeps its own `/opt/n8n-autoscaling/.env`.
- **Autoscaler / Redis / Postgres images** — separate from the n8n app image; upgrade only when you intend to.

## Quick checklist for the next upgrade

- [ ] Pick version from releases + confirm Docker tags exist.
- [ ] Bump `Dockerfile` and `Dockerfile.runner` to the same tag.
- [ ] Update `env.md` pinned version + changelog.
- [ ] Deploy files to server; `docker compose build n8n n8n-webhook n8n-worker`; `up -d`.
- [ ] Confirm `n8n --version` and basic UI / webhook smoke tests.
