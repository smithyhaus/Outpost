# 08 — Sealed Secrets (commit plaintext-free secrets to git)

> Platform capability + general workflow. **The actual encryption runs
> per-application** because every app has different secret fields.

## How it works

```
┌───────────────────────────┐                  ┌─────────────────────────┐
│ Your laptop (kubeseal CLI)│ ──pubkey encrypt─►│ git: sealed-secret.yaml │
└───────────────────────────┘                  └─────────────────────────┘
                                                          │
                                                          │ ArgoCD apply
                                                          ▼
                              ┌──────────────────────────────────────────┐
                              │ Cluster: sealed-secrets controller (priv)│
                              │   → decrypts to a real Secret            │
                              │   → app envFrom / volumeMount it         │
                              └──────────────────────────────────────────┘
```

The public key is harmless to share (`kubeseal --fetch-cert` retrieves it).
The private key lives only in `kube-system/sealed-secrets-controller`.
A SealedSecret in git stays unreadable even if the repo is public or forked.

## What the platform provides

- **`kubeseal` CLI** — `bootstrap.sh` installs it locally (macOS / Linux / WSL2).
- **Cluster controller** — `bootstrap.sh` Phase 6 deploys it into `kube-system`.
- **Public-key backup** — `secrets-backup/sealed-secrets-pub.pem` on your machine.

## How an application uses it (per-app implementation)

Minimum 4 commands:

```bash
# 1. Write a plaintext Secret to a temp file (DO NOT commit this!)
cat > /tmp/<app>-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: <app>-secret
  namespace: <app>
type: Opaque
stringData:
  DATABASE_URL: "postgres://..."
  ...
EOF

# 2. Encrypt
kubeseal --controller-namespace=kube-system --format=yaml \
  < /tmp/<app>-secret.yaml > apps/<app>/sealed-secret.yaml

# 3. Destroy plaintext
rm /tmp/<app>-secret.yaml

# 4. Commit
git add apps/<app>/sealed-secret.yaml
git commit -m "feat(<app>): seal secrets" && git push
```

In practice each application ships a small `scripts/onboard.sh` that
chains these — because (1) the app knows which fields it needs, and
(2) the app knows which values come from `infras/.env` (PG/Redis/MQ
passwords) vs which are business-side (OAuth client_secret, API keys).
That logic is application-coupled and shouldn't live in the platform.

Reference implementation:
`gitee.com/ufasterai/scm-mcp` → `scripts/onboard.sh`.

## Rotating a secret

Re-run the application's onboard script. After the SealedSecret syncs:

```bash
kubectl rollout restart -n <app> deploy
```

## Controller disaster recovery

If the private key changes (controller reinstall, k3s rebuild) every
existing SealedSecret in git becomes undecryptable. Prevent it:

```bash
# bootstrap.sh already saves the public key
ls $SK_INFRA_DIR/secrets-backup/sealed-secrets-pub.pem

# Full private-key export (store in 1Password / Bitwarden / vault, NEVER git)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml
```

Restore:

```bash
kubectl apply -f sealed-secrets-keys-backup.yaml
kubectl rollout restart -n kube-system deploy/sealed-secrets-controller
```

## Common issues

### `kubeseal: invalid public key`

Local cache is stale (controller was reinstalled). Wipe it and retry:

```bash
rm -rf ~/.config/kubeseal
```

### Cluster keeps logging `cannot decrypt`

Controller's private key doesn't match what was used at encryption time.
Common after a controller reinstall. Either restore the private-key
backup, or have the application re-run its onboard script to regenerate
the SealedSecret with the current public key.
