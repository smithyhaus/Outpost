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
- **Public-key backup** — `secrets-backup/sealed-secrets-pub.pem`.
- **Private-key backup (since v0.2)** —
  `secrets-backup/sealed-secrets-master.key.yaml`. Auto-saved at the end
  of Phase 6 and **auto-restored at the start of Phase 6** on the next
  bootstrap. This is what lets a `reset.sh` + `bootstrap.sh` cycle keep
  the same RSA keypair, so existing SealedSecrets in your manifest repos
  stay decryptable. The file is gitignored.
  `reset.sh` preserves it by default; pass `--hard` to wipe the master
  key (forces every SealedSecret to be re-sealed against a fresh keypair).

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

### Same host (cluster reset / rebuild)

`bootstrap.sh` Phase 6 backs up the master key to
`secrets-backup/sealed-secrets-master.key.yaml` and **automatically
restores it at the start of the next bootstrap**. So for the common
"blow away the cluster, rebuild" path:

```bash
bash reset.sh                      # preserves secrets-backup/ by default
bash bootstrap.sh                  # restores master key → SealedSecrets still decrypt
```

No re-sealing needed. Verify:

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
# Same Secret name across resets — confirms the keypair was preserved.
```

### Different host / off-host disaster

If the entire host disappears (laptop dies, VM lost), the key in
`secrets-backup/` is also gone. Defend against this by **copying the
master key to a password manager**:

```bash
cat secrets-backup/sealed-secrets-master.key.yaml
# → store the YAML in 1Password / Bitwarden / Hashicorp Vault, etc.
# Re-create on the new host BEFORE first bootstrap by writing the
# YAML back to secrets-backup/sealed-secrets-master.key.yaml.
```

### Force a key rotation

```bash
bash reset.sh --hard               # wipes secrets-backup/ entirely
bash bootstrap.sh                  # generates a fresh master key
# Re-seal every SealedSecret in every manifest repo against the new key.
```

`--hard` is the right path when you suspect the master key has been
compromised, or when you want a clean slate for a new environment.

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
