# 01 — Cloudflare Tunnel setup

## Step 1 — move your domain's NS to Cloudflare

1. Sign in to https://dash.cloudflare.com
2. **Add a Site** → enter your root domain → Free plan
3. At your registrar, change NS to the two values Cloudflare gives you
4. Wait a few minutes / hours for propagation

## Step 2 — create a Tunnel

1. Left sidebar → **Zero Trust** → **Networks** → **Tunnels**
2. **Create a tunnel** → choose `Cloudflared` → name it `selfhost` → Save
3. On the install page, **copy only the token** (a long `eyJhIjoi…` string)
4. Put that in `.env` as `CF_TUNNEL_TOKEN=`

## Step 3 — configure Public Hostnames

In your tunnel detail page → **Public Hostname** tab → add each row:

| Subdomain | Domain          | Type | URL |
|-----------|------------------|------|-----|
| `search`  | your root domain | HTTP | `caddy:80` |
| `mq`      | your root domain | HTTP | `caddy:80` |
| `argocd`  | your root domain | HTTP | `host.docker.internal:30080` |
| `hooks`   | your root domain | HTTP | `host.docker.internal:30080` |
| `registry`| your root domain | HTTP | `host.docker.internal:30080` |
| `*.apps`  | your root domain | HTTP | `host.docker.internal:30080` |
| `pg`      | your root domain | TCP  | `postgres:5432` |
| `redis`   | your root domain | TCP  | `redis:6379` |
| `rabbitmq`| your root domain | TCP  | `rabbitmq:5672` |

Notes:
- HTTP rows that go through Caddy use the container name `caddy:80` —
  cloudflared resolves it on the Compose network.
- HTTP rows that target k3s use `host.docker.internal:30080`. The
  cloudflared container has `extra_hosts` configured for that lookup.
- TCP rows use the service:port form. Cloudflare will set up an L4 tunnel.
- `*.apps.<domain>` is a wildcard. Free plan supports it.

Save each row. Verify:

```bash
docker logs cloudflared --tail 50
# Expected: "Registered tunnel connection" repeated for each region.
```

Open `https://argocd.<your-domain>` in a browser; you should see ArgoCD's
login page once both layers are running.

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
to `hooks.<domain>` — that breaks webhook delivery.
