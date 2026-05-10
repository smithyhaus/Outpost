# demo-app — secrets workflow reference

This directory shows the **canonical Outpost pattern** for app secrets:

1. Plaintext lives **outside** the manifest repo (or only briefly in your
   working tree for a `kubeseal` pass).
2. The manifest repo only ever holds the encrypted **SealedSecret**.
3. The Deployment uses `envFrom: { secretRef: ... }` to consume the
   decrypted Secret — same name, no Deployment change when keys rotate.

## Files

| File                          | Lives where                                   | Contains                |
|-------------------------------|------------------------------------------------|-------------------------|
| `deployment.yaml`             | manifest repo (`apps/demo-app/`)              | Pod spec + envFrom      |
| `service.yaml`, `ingress.yaml`| manifest repo                                  | usual K8s plumbing      |
| `argocd-application.yaml`     | manifest repo (`argocd-apps/demo-app.yaml`)    | ArgoCD Application      |
| `secret.example.yaml`         | **NEVER commit with real values** — workspace | Plaintext Secret source |
| `sealed-secret.example.yaml`  | manifest repo (after `kubeseal`)              | Encrypted SealedSecret  |

## Workflow

```bash
# 0. (one-time) install kubeseal locally — bootstrap auto-installs it
#    on the Outpost host; for your laptop:
brew install kubeseal      # macOS
# or download the matching release from
#   https://github.com/bitnami-labs/sealed-secrets/releases

# 1. fetch the cluster's public sealing cert
kubeseal --fetch-cert > /tmp/pub.pem

# 2. fill secret.example.yaml with real values from INFRA.md
cp examples/demo-app/secret.example.yaml ~/secrets/demo-app.yaml
$EDITOR ~/secrets/demo-app.yaml      # replace every <REPLACE_*>

# 3. seal it
kubeseal --cert /tmp/pub.pem -o yaml \
  < ~/secrets/demo-app.yaml \
  > <manifest-repo>/apps/demo-app/sealed-secret.yaml

# 4. commit ONLY the SealedSecret
cd <manifest-repo>
git add apps/demo-app/sealed-secret.yaml
git commit -m "feat(demo-app): seal app secrets"
git push

# 5. ArgoCD picks up the change → sealed-secrets-controller decrypts →
#    Deployment's envFrom finds demo-app-secrets → Pod restarts with envs

# 6. delete the plaintext file
rm ~/secrets/demo-app.yaml
```

## Cluster-reset survivability

Outpost backs up the sealed-secrets master RSA keypair to
`secrets-backup/sealed-secrets-master.key.yaml` after every bootstrap, and
`reset.sh` preserves that file by default. The next `bootstrap.sh` restores
the same keypair into the new cluster — your manifest repo's existing
SealedSecrets keep decrypting.

To force key rotation (e.g. after a real key compromise):

```bash
bash reset.sh --hard         # also wipes secrets-backup/
bash bootstrap.sh             # generates a fresh key
# Re-seal every SealedSecret in every manifest repo against the new key.
```

## Anti-pattern (what `deployment.yaml` used to do — fixed)

```yaml
# ❌ DO NOT do this — plaintext password in the manifest repo
env:
  - name: DATABASE_URL
    value: "postgres://postgres:RealPasswordHere@postgres..."
```

The old version of `deployment.yaml` told users to copy passwords directly
from `INFRA.md` and paste them into the manifest repo. That made every
manifest repo a credential vault. The current `deployment.yaml` uses
`envFrom: { secretRef: { name: demo-app-secrets } }` and pulls the values
from a SealedSecret instead. **Don't regress to the old pattern.**
