# Outpost

> **Spin up a full self-hosted dev backend in one command — anywhere.**
> Postgres / Redis / RabbitMQ / Meilisearch + a complete GitOps CI/CD pipeline,
> exposed on your own domain via Cloudflare Tunnel. Works on macOS, Linux, and
> Windows (WSL2). Plugin-driven. AI-friendly out of the box.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL2-green.svg)]()
[![中文](https://img.shields.io/badge/lang-中文-red.svg)](README.zh-CN.md)

---

## What you get in one `bash bootstrap.sh`

```
            Cloudflare edge (HTTPS, no public IP needed)
                                │
                                ▼
                      cloudflared tunnel (egress)
                       ┌────────┴────────┐
                       ▼                 ▼
              ┌──────────────┐    ┌────────────────────┐
              │  Compose     │    │  k3s cluster       │
              │              │    │                     │
              │  Postgres    │    │  ArgoCD (GitOps)   │
              │  + pgvector  │    │  Tekton + webhook  │
              │  Redis       │    │  Registry          │
              │  RabbitMQ    │    │  Your apps         │
              │  Meilisearch │    │                     │
              └──────────────┘    └────────────────────┘
```

- **Data layer (Compose)** — runs the stateful services that almost every
  project needs in development.
- **App layer (k3s)** — runs your applications and a complete GitOps pipeline:
  push to git → Tekton builds → image to registry → ArgoCD deploys.
- **One Cloudflare Tunnel** exposes everything on subdomains of your own
  domain. No router config, no public IP, works behind double NAT.

## Quick start

```bash
git clone https://github.com/smithyhaus/outpost.git ~/outpost
cd ~/outpost
cp .env.example .env       # edit ROOT_DOMAIN + CF_TUNNEL_TOKEN at minimum
bash bootstrap.sh          # ~5 minutes
```

After it finishes:

- Open `INFRA.md` for every connection string and password
- ArgoCD UI: `https://argocd.<your-domain>`
- Webhook URL for your Git provider: `https://hooks.<your-domain>`

See [`i18n/en/docs/`](i18n/en/docs/) for full setup guides.

## Why Outpost

| Pain | Outpost answer |
|------|---------------------|
| "I need Postgres + Redis + RabbitMQ for my dev box, but spinning each up + exposing them is annoying." | One `bootstrap.sh`, all services up with TLS-terminated public domain. |
| "My ISP doesn't give me a public IP / blocks 80/443." | Cloudflare Tunnel — egress-only, works behind any NAT. |
| "I want push-to-deploy locally without setting up Jenkins." | Tekton + ArgoCD pre-wired. Push to your Git provider, app rolls out. |
| "I'm on macOS / Linux / WSL2 and most tutorials assume just one." | One installer detects the OS and uses the right path. |
| "I don't want to commit to one Docker registry / one Git platform." | Plugin model — swap registries (self-hosted ↔ Aliyun ACR) and Git providers (Gitee / GitHub / GitLab) by changing one env var. |

## Plugins

| Kind          | Built-in plugins                    |
|---------------|-------------------------------------|
| Registry      | `self-hosted` (default), `aliyun-acr` |
| Git provider  | `gitee` (default), `github`, `gitlab` |

Switch by editing `.env`:

```env
REGISTRY_PLUGIN=aliyun-acr
GIT_PROVIDER_PLUGIN=github
```

See [`plugins/README.md`](plugins/README.md) for the plugin contract and how to author your own.

## AI-friendly by design

This project ships first-class context for AI coding agents:

- [`SKILL.md`](SKILL.md) — Claude-style operating skill (architecture, invariants, common tasks)
- [`llms.txt`](llms.txt) — generic [llms.txt](https://llmstxt.org) discovery file
- [`verify.sh --json`](verify.sh) — machine-parseable health output (schema locked at `tests/schema/verify-output.schema.json`)
- [`i18n/en/docs/07-ai-verification.md`](i18n/en/docs/07-ai-verification.md) — verification playbook AI agents can follow

Drop Outpost into a Claude Code session and ask "is the stack healthy?" — it will run `verify.sh --json` and give you a structured report.

## Documentation

| Topic | English | 中文 |
|-------|---------|------|
| Architecture | [`ARCHITECTURE.md`](ARCHITECTURE.md) | (English only — single source) |
| Cloudflare setup | [docs/01](i18n/en/docs/01-cloudflare-setup.md) | [docs/01](i18n/zh-CN/docs/01-cloudflare-setup.md) |
| WSL2 config | [docs/02](i18n/en/docs/02-wsl-config.md) | [docs/02](i18n/zh-CN/docs/02-wsl-config.md) |
| Windows autostart | [docs/03](i18n/en/docs/03-windows-autostart.md) | [docs/03](i18n/zh-CN/docs/03-windows-autostart.md) |
| Client TCP access | [docs/04](i18n/en/docs/04-client-access.md) | [docs/04](i18n/zh-CN/docs/04-client-access.md) |
| Onboard a project | [docs/05](i18n/en/docs/05-onboard-project.md) | [docs/05](i18n/zh-CN/docs/05-onboard-project.md) |
| Troubleshooting | [docs/06](i18n/en/docs/06-troubleshooting.md) | [docs/06](i18n/zh-CN/docs/06-troubleshooting.md) |
| AI verification | [docs/07](i18n/en/docs/07-ai-verification.md) | [docs/07](i18n/zh-CN/docs/07-ai-verification.md) |

## Status

Outpost is **v1.0** — feature-complete for the milestones listed in
[`TODOS.md`](TODOS.md). Roadmap items (tunnel plugins, Cursor/Copilot AI
adapters, Helm packaging) live there.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). New plugins, doc translations, and
platform fixes are especially welcome.

## License

[Apache License 2.0](LICENSE).

---

<sub>Outpost is a project by **[smithyhaus](https://github.com/smithyhaus)** — a workshop for small, sharp tools that punch above their weight.</sub>
