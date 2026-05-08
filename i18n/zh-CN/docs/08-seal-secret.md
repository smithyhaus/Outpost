# 08 — Sealed Secret(把明文密钥安全地放进 git)

> 平台特性说明 + 各应用通用做法。**具体加密执行由各应用自己干**,
> 因为每个应用的 secret 内容不同。

## 怎么工作

```
┌──────────────────────────┐                  ┌────────────────────────┐
│ 应用本机 (kubeseal CLI)  │ ──公钥加密──>    │ git: sealed-secret.yaml │
└──────────────────────────┘                  └────────────────────────┘
                                                          │
                                                          │ ArgoCD apply
                                                          ▼
                              ┌──────────────────────────────────────────┐
                              │ 集群: sealed-secrets controller (私钥)   │
                              │   → 自动解密为 Secret → 给应用 envFrom    │
                              └──────────────────────────────────────────┘
```

公钥任何人都能拿(集群里 `kubeseal --fetch-cert` 即可),私钥只在
`kube-system/sealed-secrets-controller` 里。SealedSecret 在 git 里即便
被 fork / 泄露也无法解密。

## 平台提供什么

- **kubeseal CLI**:`bootstrap.sh` 在本机自动安装(macOS / Linux / WSL2)
- **集群侧 controller**:`bootstrap.sh` Phase 6 部署到 `kube-system`
- **公钥备份**:`secrets-backup/sealed-secrets-pub.pem`(本机)

## 应用怎么用(每个应用各自实现)

最小流程,4 行命令:

```bash
# 1. 写一份明文 Secret 到临时文件(不要进 git!)
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

# 2. 加密
kubeseal --controller-namespace=kube-system --format=yaml \
  < /tmp/<app>-secret.yaml > apps/<app>/sealed-secret.yaml

# 3. 销毁明文
rm /tmp/<app>-secret.yaml

# 4. 提交
git add apps/<app>/sealed-secret.yaml
git commit -m "feat(<app>): seal secrets" && git push
```

每个应用通常会自己写一个 `scripts/onboard.sh` 把上面这 4 步串起来 —
因为 ① 应用知道自己要哪些字段 ② 应用知道哪些值能从 `infras/.env`
派生(pg/redis/mq 密码),哪些是业务侧值(client_secret 等)。这些
逻辑跟应用强相关,不该塞进平台。

参考实现:`gitee.com/ufasterai/scm-mcp` 的 `scripts/onboard.sh`。

## 旋转密钥

应用层重新跑一次自己的 onboard 脚本就行;ArgoCD 同步后强制重启:

```bash
kubectl rollout restart -n <app> deploy
```

## 控制器灾难恢复

私钥变了(controller 重装、k3s 重做)所有现有 SealedSecret 都解不出。
预防:

```bash
# bootstrap.sh 自动备份了公钥
ls $SK_INFRA_DIR/secrets-backup/sealed-secrets-pub.pem

# 完整私钥导出(放进 1Password / Bitwarden,绝对不入 git)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml
```

恢复:

```bash
kubectl apply -f sealed-secrets-keys-backup.yaml
kubectl rollout restart -n kube-system deploy/sealed-secrets-controller
```

## 常见问题

### `kubeseal: invalid public key`
本机缓存的公钥过期(controller 重装)。删缓存重试:
```bash
rm -rf ~/.config/kubeseal
```

### 集群端 SealedSecret 一直报 `cannot decrypt`
私钥与加密时的公钥不匹配。常见于 controller 被重装。要么用备份的私钥
恢复,要么应用端重生成 sealed-secret(即重跑 onboard 脚本)。
