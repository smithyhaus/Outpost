---
name: outpost-app-deploy
description: |
  Claude / LLM-driven onboarding skill for an application repository that
  ships an `outpost.app.yaml`. Encodes the Outpost architectural contract:
  stateless applications go to tier=k3s (named `<x>-apps.<ROOT_DOMAIN>`,
  routed through the single `*.<ROOT_DOMAIN>` CF Tunnel wildcard); stateful
  infrastructure additions go to tier=compose (top-level subdomain via
  Caddy). Detects whether outpost is installed locally, installs it via
  the one-shot install.sh if needed, then runs `outpost onboard .` to
  register THIS repository with the running infras.
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

> **Copy this file into your application repository** as
> `.claude/skills/outpost-deploy.skill.md` (or wherever your LLM tooling
> picks up skills). It is the same file regardless of which app uses it —
> the per-app variation lives in `outpost.app.yaml`. `outpost onboard
> --install-skill` will drop this copy for you.

## 0. The architectural contract — read this first

Outpost has two ingress paths, each owning a distinct workload tier. If you
get the tier wrong, you end up either (a) routing app traffic through the
data-layer caddy, or (b) putting stateful infrastructure on the k3s
wildcard ingress. Both break the contract.

```
                              cloudflared
                                   |
            +----------------------+----------------------+
            |                                             |
            v                                             v
   *.<ROOT_DOMAIN>                               <prefix>.<ROOT_DOMAIN>
   broad CF wildcard                             top-level (per-svc CF rule)
   (catches everything not specific)
            |                                             |
            v                                             v
       k3s Traefik                                    Caddy :80
            |                                             |
            v                                             v
   STATELESS APPLICATIONS                  STATEFUL INFRASTRUCTURE
   named `<x>-apps.<ROOT_DOMAIN>`          (extra DBs, queues, search,
   (HTTP servers, workers, queue           object stores — anything
   consumers, ML inference, CRUD,          that owns persistent data)
   dashboards)                                     tier=compose
        tier=k3s
```

**Why `<x>-apps.<root>` and not `<x>.apps.<root>`?** Cloudflare Universal
SSL covers `*.<ROOT_DOMAIN>` for free (one-level wildcard). Apps named
`<x>-apps.<root>` keep the FQDN at one level → free SSL works. Two-level
`<x>.apps.<root>` would require paid Advanced Certificate Manager (~$10/mo).
CF Tunnel can't use `*-apps.<root>` as a routing wildcard either (partial-
label wildcards aren't supported), so `-apps` is a NAMING CONVENTION,
enforced by validator + IngressRoute `Host()` matching.

**The skill enforces this contract:**

- If the repo's `outpost.app.yaml` declares `tier=k3s` and contains
  `spec.routes` or `spec.caddy_fragment`, `outpost onboard` refuses with
  a clear error — apps use Kubernetes IngressRoute in the manifest repo,
  not Caddy fragments.
- If the repo's yaml declares `tier=compose` and the host ends in
  `-apps.<root>`, `outpost onboard` refuses — that suffix is the apps
  naming convention; CF Tunnel routes `*.<root>` to k3s, so caddy never
  sees the traffic.

**Default to `tier=k3s`.** If you're not adding a stateful data service,
this is the right answer.

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
  to step 5. The user just wants this repo registered.
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

## 6. Onboarding an app on an existing Outpost

If `outpost` is already on PATH (re-trigger, second app on same machine):

### tier=k3s (stateless — DEFAULT for applications)

```bash
# Clone your manifests repo locally first (or reuse an existing clone).
git clone "$MANIFEST_REPO_URL" ~/code/my-manifests

# Onboard scaffolds deployment.yaml + service.yaml + ingress.yaml +
# kustomization.yaml + the argocd-app pointing at it.
cd "$REPO_ROOT"
outpost onboard . \
  --manifests-dir ~/code/my-manifests \
  --lang go    # or python | java | csharp | react | vue
```

For multi-product or path-based routing (the SCM-MCP-style fan-out),
adapt the scaffolded `apps/<name>/ingress.yaml` in your manifests repo —
add multiple `Rule` entries with different `PathPrefix` matchers, all
matching `Host(`<name>-apps.<ROOT_DOMAIN>`)`. See
`examples/outpost.app.yaml.multiproduct.example` (in the Outpost repo)
for the reference comment block.

Then commit + push the manifest repo — ArgoCD picks it up automatically.

### tier=compose (stateful infrastructure — rare)

```bash
cd "$REPO_ROOT" && outpost onboard .
```

This reads `./outpost.app.yaml`, renders a Caddy fragment into
`~/outpost/core/compose/Caddyfile.d/<name>.caddy`, writes a compose
override into `~/outpost/core/compose/overrides/<name>.yml`, reloads
caddy, and runs `docker compose up -d <name>`.

**Cloudflare side:** the broad `*.<root>` CF Tunnel wildcard routes to
k3s by default. A stateful infra subdomain needs a more specific entry
to override the wildcard. Go to Cloudflare Dashboard → Zero Trust →
Tunnels → your tunnel → Public Hostname and add:
- Host: `<your-prefix>.<your-domain>`
- Service: `http://caddy:80`

CF Tunnel uses most-specific-wins matching, so `es.example.com` (literal)
automatically takes precedence over `*.example.com` (wildcard).

## 7. Verify the deploy

```bash
# Compose-tier infra: container running?
docker ps | grep "<your-name>"

# k3s-tier apps: ArgoCD synced + pods running?
outpost status
kubectl get pods -n apps

# Public reachability (full mode):
curl -i "https://<host-from-outpost.app.yaml-or-ingress>"
```

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `tier=k3s forbids spec.routes` | Trying to put app routes in outpost.app.yaml | Move routing into your manifest repo's `ingress.yaml`. Apps use IngressRoute, not Caddy. |
| `tier=compose host ... ends with the apps naming convention` | Used the `-apps.<root>` suffix for a compose-tier service | Switch to `tier=k3s` (probably what you want) OR pick a non-apps top-level prefix |
| `outpost: command not found` | `~/.local/bin` not on PATH | Append `export PATH=...` to shell rc |
| `caddy reload failed` | Fragment syntax error | `docker logs caddy --tail 30`; fix yaml; rerun `outpost onboard .` |
| 502 from `<my-app>-apps.<root>` | App pod not Healthy in ArgoCD | `kubectl get pods -n apps`; `kubectl logs -n apps <pod>` |
| `tier=compose host '<x>-apps.<root>'` rejected | tried to put an app on the apps naming convention as tier=compose | switch to `tier=k3s` (probably what you want) OR pick a non-apps prefix |

## 9. What this skill must NOT do

- **Never edit files inside `~/outpost/`** other than via `outpost onboard`
  / `outpost off-board`. The infras repo is read-only from the app's
  perspective.
- **Never set tier=compose to get caddy ingress** for a stateless app.
  That's an architectural violation — the caddy path is for stateful infra.
- **Never add a top-level subdomain for an application** to bypass the
  apps naming convention. Apps use `<name>-apps.<root>` by design.
- **Never commit rendered artefacts** (`Caddyfile.d/<name>.caddy`,
  `overrides/<name>.yml`) — they're gitignored in the infras repo.
- **Never run `reset.sh` or `bash bootstrap.sh --force`** — they wipe
  data. If the user says "reinstall outpost", confirm twice and use a
  fresh `OUTPOST_DIR` instead.
