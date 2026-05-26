---
name: outpost-app-deploy
description: |
  Claude / LLM-driven onboarding skill for an application repository that
  ships an `outpost.app.yaml`. Detects whether outpost is already installed
  locally, installs it via the one-shot `install.sh` if needed, then runs
  `outpost onboard .` to register THIS repository's app with the running
  infras instance.
when_to_use: |
  Trigger automatically when:
    - The repository root contains an `outpost.app.yaml` file
    - The user says "deploy this", "onboard to outpost", or "set up locally"
  Do NOT trigger when:
    - The repository targets a different deployment platform (Vercel,
      Fly.io, k8s direct, etc.) — those have their own skills
    - The user only wants to BUILD (use the project's build skill instead)
---

# Outpost — app onboarding skill (LLM template)

> **Copy this file into your application repository** as `.claude/skills/outpost-deploy.skill.md`
> (or wherever your LLM tooling picks up skills). It is the same file regardless
> of which app uses it — the per-app variation lives in `outpost.app.yaml`.

## 1. What this skill does

When invoked, deploys this application to a local Outpost dev backend in
one command. Outpost itself is fetched from GitHub if it isn't already
installed on the machine — the user never needs to `git clone` the infras
repo manually.

## 2. Preconditions to check

Before doing anything, verify (in this order):

1. **`outpost.app.yaml` exists** at the repository root. If missing, point
   the user to `examples/outpost.app.yaml.minimal.example` in the Outpost
   repo and stop.
2. **Docker is installed and the daemon is running.** Tell the user to
   start Docker Desktop if not, then re-trigger.
3. **`git`, `bash`, and `curl` are on PATH.** Macs and Linux distros have
   these by default; WSL2 users sometimes need to install them.

## 3. Decide: install or onboard?

Run `command -v outpost`:

- **If `outpost` is on PATH:** the dev backend is already installed — skip
  to "5. Onboard this app". The user just wants this repo registered.
- **If `outpost` is NOT on PATH:** prompt the user with the install
  questions in step 4, then run the one-shot installer.

## 4. Required input for first-time install

Ask the user (only on first-time install — skip if `outpost` already exists):

> Outpost needs to know whether to run in **local mode** (just stateful
> services on your laptop — zero config) or **full mode** (public access
> via your own domain + Cloudflare Tunnel + GitOps CI/CD).
>
> 1. Mode? [`local` / `full`]
>
> If `full`, also need:
>   2. `ROOT_DOMAIN` (e.g. `mycompany.com`)
>   3. `CF_TUNNEL_TOKEN` (Cloudflare Dashboard → Zero Trust → Tunnels)
>   4. `GIT_USER` + `GIT_TOKEN` (for ArgoCD + Tekton)
>   5. `MANIFEST_REPO_URL` (an empty Git repo with `apps/` and
>      `argocd-apps/` directories — ArgoCD's source of truth)

Default to `local` if the user says "just deploy locally" or doesn't know.

## 5. Run the installer

```bash
# Local mode (zero config):
curl -fsSL https://raw.githubusercontent.com/smithyhaus/Outpost/main/install.sh \
  | APP_REPO="<this-app's-git-url-or-local-path>" bash

# Full mode (with Cloudflare + GitOps):
curl -fsSL https://raw.githubusercontent.com/smithyhaus/Outpost/main/install.sh \
  | OUTPOST_MODE=full \
    ROOT_DOMAIN=<value> \
    CF_TUNNEL_TOKEN=<value> \
    GIT_USER=<value> \
    GIT_TOKEN=<value> \
    MANIFEST_REPO_URL=<value> \
    APP_REPO="<this-app's-git-url-or-local-path>" \
    bash
```

`APP_REPO` makes the installer automatically run `outpost onboard` after
bootstrap completes — no second command needed.

When the working tree IS the app's source (local path is `.`), pass
`APP_REPO="$PWD"` so the installer onboards the in-progress code, not the
remote `main` of the repo.

## 6. Onboard a new app on an existing Outpost

If `outpost` is already on PATH (re-trigger of this skill, second app on
the same machine, etc.):

```bash
cd "$REPO_ROOT" && outpost onboard .
```

This reads `./outpost.app.yaml`, renders a Caddy fragment into
`~/outpost/core/compose/Caddyfile.d/<name>.caddy`, writes a compose
override (for `tier: compose` apps) into `~/outpost/core/compose/overrides/<name>.yml`,
and reloads the running Caddy container.

## 7. Verify the deploy

After onboarding, confirm the app is reachable:

```bash
# Check that the new fragment is loaded
docker exec caddy caddy fmt /etc/caddy/Caddyfile >/dev/null && echo "Caddy config valid"

# Compose-tier apps: bring up the container if it isn't running
cd ~/outpost/core/compose
docker compose -f docker-compose.yml -f overrides/<name>.yml up -d <name>

# k3s-tier apps: ArgoCD picks up the manifest repo change automatically;
# watch the rollout
outpost status
```

For full-mode installs, the public URL is `https://<host-from-outpost.app.yaml>`
where `<host>` resolves through the Cloudflare Tunnel.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `outpost: command not found` after install | `~/.local/bin` (or `/usr/local/bin`) not on PATH | Append `export PATH=…` to shell rc |
| `outpost.app.yaml validation failed` | Schema mismatch | Compare against `tests/schema/outpost-app.schema.json` |
| `caddy reload failed` | Fragment syntax error | `docker logs caddy --tail 30`; fix `outpost.app.yaml`; rerun `outpost onboard .` |
| `git clone failed` (in install.sh) | No internet / proxy | Set `OUTPOST_GIT_URL` to a mirror; for fully offline, `git clone` manually then `bash ~/outpost/install.sh` |

## 9. What this skill must NOT do

- **Never edit files inside `~/outpost/`** other than via `outpost onboard`.
  The infras repo is read-only from the app's perspective.
- **Never commit `outpost.app.yaml` rendered artifacts** (`Caddyfile.d/<name>.caddy`,
  `overrides/<name>.yml`) to source control. They're gitignored in the
  infras repo for a reason — they're per-installation, not per-app.
- **Never run `reset.sh` or `bash bootstrap.sh --force`** — they wipe data.
  If the user says "reinstall outpost", confirm twice and use a fresh
  `OUTPOST_DIR` instead.
