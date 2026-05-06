# Plugin: registry / self-hosted

In-cluster Docker Registry v2. The default. No external account required.

## What you get

- A `registry:2` Deployment in the `registry` namespace
- 50 Gi PersistentVolume on k3s `local-path` storage
- Traefik IngressRoute exposing it on `registry.<ROOT_DOMAIN>`
- `containerd` on the k3s node is configured to pull from this host without TLS

## When to use

- Personal / dev environment
- You don't want to depend on a cloud registry account
- You want zero ongoing cost

## When NOT to use

- Multi-tenant / public-facing (this registry has no auth — anyone with the
  hostname can push and pull). For public exposure, layer **Cloudflare Access**
  in front, or switch to `aliyun-acr`, ECR, or a Harbor instance.
- You need image scanning, signing, or replication (use Harbor / ECR / GCR)

## Configuration

| Variable               | Default | Purpose                              |
|------------------------|---------|--------------------------------------|
| `REGISTRY_STORAGE_GB`  | 50      | PVC size                             |
| `ROOT_DOMAIN`          | —       | Used to build `registry.<domain>`    |
