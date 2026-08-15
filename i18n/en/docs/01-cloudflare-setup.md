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

In your tunnel detail page → **Public Hostname** tab → add each row.
Four rows is the whole built-in surface:

| Subdomain  | Domain          | Type | URL                          | Backend behind it |
|------------|------------------|------|------------------------------|-------------------|
| `search`   | your root domain | HTTP | `host.docker.internal:30080` | Traefik → `manticore.infra-bridges:9308` |
| `mq`       | your root domain | HTTP | `host.docker.internal:30080` | Traefik → `rabbitmq.infra-bridges:15672` |
| `registry` | your root domain | HTTP | `host.docker.internal:30080` | Traefik → in-cluster Docker Registry |
| `*`        | your root domain | HTTP | `host.docker.internal:30080` | Traefik → your apps in the `apps` namespace |

**No `hooks` row, no `argocd` row, no `tekton` row, no `rollouts` row.**
v0.3.0 retired the inbound-webhook path and every in-cluster CI/CD
dashboard: the GitHub Actions runner long-polls github.com outbound-only
and `manifest-sync` polls the manifest repo on a CronJob schedule, so
nothing needs to reach *in*. Build status lives in the GitHub Actions UI,
deploy status in `outpost status`. See
[ADR-0003](../../../docs/decisions/0003-github-actions-engine-swap.md).

> **Wildcard subdomain note**: enter `*` in the Subdomain field (not
> `*.apps`). Apps follow the naming convention `<name>-apps.<root>` and
> get caught by this single broad `*.<root>` wildcard — it routes to
> k3s Traefik, where the IngressRoute matches the specific `<name>-apps`
> Host header. **Don't use `*.apps`** as a Subdomain — that's a two-level
> wildcard (`*.apps.<root>`) which Cloudflare's free Universal SSL
> doesn't cover (requires paid Advanced Certificate Manager, ~$10/mo).
> CF Tunnel also doesn't support partial-label wildcards like `*-apps`
> in Public Hostnames either; the `-apps` suffix is enforced inside
> k3s, not at the CF edge.

**Why every URL is the same**: cloudflared doesn't route — it just hands
the request to the next hop, and in `full` mode that hop is always the k3s
Traefik NodePort. Traefik does the second-level routing by Host header.
The one exception is a Compose-tier app onboarded with
`outpost onboard` (`tier=compose`): that writes a `Caddyfile.d/<app>.caddy`
fragment, and its Public Hostname row targets `caddy:80` instead.

**Why no HTTPS option**: TLS terminates at the Cloudflare edge; the tunnel
itself carries plain HTTP. The `Type` column intentionally has no HTTPS —
your users still hit `https://registry.<domain>`, which Cloudflare serves
with an auto-issued cert.

### Notes

- HTTP rows use `host.docker.internal:30080`. The cloudflared container
  has `extra_hosts: host-gateway` configured for that lookup (see
  `core/compose/docker-compose.yml`).
- The broad `*` wildcard catches every subdomain not specifically listed.
  More-specific entries (like `registry.<domain>`) override the wildcard
  automatically — CF Tunnel uses most-specific-wins matching.
- **Extra config for `registry`**: expand *Additional application
  settings → HTTP Settings → HTTP Host Header* and set it to
  `registry.<your-domain>`. Docker Registry is Host-header sensitive;
  without this, image pulls return 401.
- **TCP rows (`pg` / `redis` / `rabbitmq`) are optional and need work.**
  In `full` mode the data services are k3s StatefulSets behind ClusterIP
  Services in `infra-bridges` — there is no Compose container for a TCP
  row to target. If you want them, first expose the port on the Outpost
  host (`kubectl -n infra-bridges port-forward --address 0.0.0.0
  svc/postgres 5432:5432`) and point the row at
  `host.docker.internal:5432`. See `04-client-access.md` for the
  dev-workstation side and the `CF_TUNNEL_PROTOCOL=http2` caveat.

Save each row.

## Step 4 — Cloudflare-side self-check

The Outpost host hasn't run cloudflared yet, so we only verify what we
can see in the Cloudflare Dashboard at this point:

- [ ] The Tunnel detail page shows all four Public Hostnames you just added
- [ ] Tunnel status shows *Inactive* or *Down* — **expected**, because
      cloudflared isn't running locally yet
- [ ] DNS check: `dig registry.<root>` resolves to a Cloudflare IP range
      (NS has propagated and Public Hostnames have written DNS records).
      `NXDOMAIN` means NS hasn't switched yet or the row wasn't saved

> The "open the browser and see it answer" step is a **connectivity**
> check, which requires `bash bootstrap.sh` to have finished on the
> Outpost host. See `00-quickstart.md` Phase F.

## Hardening — Cloudflare Access (recommended)

A strong password + HTTPS is fine, but adding Zero Trust on top is cheap
and substantially safer:

1. **Zero Trust → Access → Applications → Add**
2. Type: **Self-hosted**
3. Application name: `RabbitMQ`
4. Application domain: `mq.<your-domain>`
5. Identity providers: One-time PIN (email OTP) is enough; GitHub OAuth
   also works
6. Policy → **Allow** → restrict to your email

Repeat for `search.<domain>`. Since v0.3.0 there is no inbound webhook
endpoint anywhere, so **no row has to be left unprotected** — the old
"don't put Access in front of `hooks.<domain>`" carve-out is gone with
the route itself.

One caveat on `registry.<domain>`: an Access policy in front of it will
break `docker pull` / `buildctl` pushes from anything that can't complete
the browser login. The in-cluster build path doesn't go through the edge
(it uses the `127.0.0.1:30500` NodePort), so this only affects pulls from
outside your host — decide based on whether you actually do those.
