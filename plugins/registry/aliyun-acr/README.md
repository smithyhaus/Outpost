# Plugin: registry / aliyun-acr

External managed registry on Alibaba Cloud (ACR — Container Registry).

## What you get

- Tekton credentials Secret so the build pipeline can `docker push` to ACR
- Application namespace pull-secret so k3s pulls images from ACR
- No in-cluster registry pod runs

## When to use

- You already have an Aliyun account
- You want a managed registry with replication, scanning, and HA
- You want the registry behind Aliyun's auth (no public anonymous push)

## Setup checklist

1. Aliyun Console → **Container Registry** → create a Personal or Enterprise instance
2. Create a **namespace** (e.g. `outpost`)
3. Settings → **Access Credential** → set/reset the registry password
4. Fill `.env`:

   ```env
   REGISTRY_PLUGIN=aliyun-acr
   ALIYUN_ACR_REGISTRY=registry.cn-hangzhou.aliyuncs.com
   ALIYUN_ACR_NAMESPACE=outpost
   ALIYUN_ACR_USER=<your-acr-user>
   ALIYUN_ACR_PASSWORD=<your-acr-password>
   ```

5. `bash bootstrap.sh` — preflight will reject if any of the four are blank

## Image tags

Tekton pushes images to:

```
${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}/<repo>:<short-sha>
```

## Costs

- Personal: free, with bandwidth & repo-count limits
- Enterprise: paid; supports replication, RAM-IP whitelist, image scanning

See https://www.aliyun.com/product/acr for current pricing.
