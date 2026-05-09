# 01 — Cloudflare Tunnel setup

> Everything in this doc happens in a browser. It does **not** require
> the Outpost host to be running. After you finish, return to
> `00-quickstart.md` Phases D / E.

## Step 1 — move your domain's NS to Cloudflare

1. Sign in to https://dash.cloudflare.com
2. **Add a Site** → enter your root domain → Free plan
3. At your registrar, change NS to the two values Cloudflare gives you
4. Wait a few minutes / hours for propagation

## Step 2 — create a Tunnel

1. Left sidebar → **Zero Trust** → **Networks** → **Tunnels**
2. **Create a tunnel** → choose `Cloudflared` → name it (anything, e.g. `outpost`) → Save
3. On the install page, **copy only the token** (a long `eyJhIjoi…` string)
4. Put that in `.env` as `CF_TUNNEL_TOKEN=` later (see `00-quickstart.md` Phase D)
5. **Do NOT** run the install command on your host — Outpost runs cloudflared inside Compose, not directly on the host

## Step 3 — configure Public Hostnames

In your tunnel detail page → **Public Hostname** tab → add each row (mind the **Type** column: HTTP vs TCP):

| Subdomain | Domain          | Type | URL |
|-----------|------------------|------|-----|
| `search`  | your root domain | HTTP | `caddy:80` |
| `mq`      | your root domain | HTTP | `caddy:80` |
| `argocd`  | your root domain | HTTP | `host.docker.internal:30080` |
| `tekton`  | your root domain | HTTP | `host.docker.internal:30080` |
| `hooks`   | your root domain | HTTP | `host.docker.internal:30080` |
| `registry`| your root domain | HTTP | `host.docker.internal:30080` |
| `*.apps`  | your root domain | HTTP | `host.docker.internal:30080` |
| `pg`      | your root domain | TCP  | `postgres:5432` |
| `redis`   | your root domain | TCP  | `redis:6379` |
| `rabbitmq`| your root domain | TCP  | `rabbitmq:5672` |

**Why URLs look duplicated**: cloudflared doesn't route — it just hands the request to the next hop. Caddy (`caddy:80`, splits by Host header to meilisearch / rabbitmq UI) and k3s Traefik (`host.docker.internal:30080`, splits by Ingress to ArgoCD / Tekton EL / Registry / user apps) do the second-level routing.

**Why no HTTPS option**: TLS terminates at the Cloudflare edge; the tunnel itself carries plain HTTP. The `Type` column intentionally has no HTTPS — your users still hit `https://argocd.<domain>`, which Cloudflare serves with an auto-issued cert.

### Notes

- HTTP rows that go through Caddy use the container name `caddy:80` —
  cloudflared resolves it on the Compose network.
- HTTP rows that target k3s use `host.docker.internal:30080`. The
  cloudflared container has `extra_hosts: host-gateway` configured for
  that lookup (see `core/compose/docker-compose.yml`).
- TCP rows use the service:port form. Cloudflare will set up an L4 tunnel.
- `*.apps.<domain>` is a wildcard. Free plan supports it.
- **Extra config for `registry`**: expand *Additional application
  settings → HTTP Settings → HTTP Host Header* and set it to
  `registry.<your-domain>`. Docker Registry is Host-header sensitive;
  without this, image pulls return 401.

Save each row.

## Step 4 — Cloudflare-side self-check

The Outpost host hasn't run cloudflared yet, so we only verify what we
can see in the Cloudflare Dashboard at this point:

- [ ] The Tunnel detail page shows all 9 Public Hostnames you just added
- [ ] Tunnel status shows *Inactive* or *Down* — **expected**, because
      cloudflared isn't running locally yet
- [ ] DNS check: `dig argocd.<root>` resolves to a Cloudflare IP range
      (NS has propagated and Public Hostnames have written DNS records).
      `NXDOMAIN` means NS hasn't switched yet or the row wasn't saved

> The "open the browser and see the ArgoCD login page" step is a
> **connectivity** check, which requires `bash bootstrap.sh` to have
> finished on the Outpost host. See `00-quickstart.md` Phase F.

## Hardening — Cloudflare Access (recommended)

ArgoCD's strong password + HTTPS is fine, but adding Zero Trust on top
is cheap and substantially safer:

1. **Zero Trust → Access → Applications → Add**
2. Type: **Self-hosted**
3. Application name: `ArgoCD`
4. Application domain: `argocd.<your-domain>`
5. Identity providers: One-time PIN (email OTP) is enough; GitHub OAuth
   also works
6. Policy → **Allow** → restrict to your email

Repeat for `mq.<domain>` and `registry.<domain>`. **Do NOT** add Access
to `hooks.<domain>` — webhooks would fail. Webhook security is enforced
via `X-Gitee-Token` / `X-Hub-Signature-256` / `X-Gitlab-Token`.
