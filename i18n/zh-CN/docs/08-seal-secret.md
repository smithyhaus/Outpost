# 08 — Sealed Secret(把明文密钥安全地放进 git)

> 适用所有接 Outpost CICD 的项目。明文 K8s Secret 不能进 git 仓库,
> 用 SealedSecret 加密后才能提交;集群里的 sealed-secrets controller
> 会用私钥自动解密回原 Secret。

## 怎么工作

```
┌──────────────────────────┐                  ┌────────────────────────┐
│ 你的本机 (kubeseal CLI)  │ ──公钥加密──>    │ git: sealed-secret.yaml │
└──────────────────────────┘                  └────────────────────────┘
                                                          │
                                                          │ ArgoCD apply
                                                          ▼
                              ┌──────────────────────────────────────────┐
                              │ 集群: sealed-secrets controller (私钥)   │
                              │   → 自动解密为 Secret → 给应用 envFrom    │
                              └──────────────────────────────────────────┘
```

公钥任何人都可以拿(集群里 `kubeseal --fetch-cert` 即可),私钥只在
`kube-system/sealed-secrets-controller`。所以 SealedSecret 在 git 里
即便被 fork / 泄露也无法解密。

## 前置

- 集群已 bootstrap,sealed-secrets controller 在 `kube-system` 跑着
- 本机有 kubeseal CLI(bootstrap.sh 会自动装)
- 本机 kubeconfig 指向目标集群

## 用法(应用接入流程的一步)

每个应用的 manifest 仓 `apps/<app>/` 下要有一个 `sealed-secret.yaml`。
生成它的标准动作:

```bash
# 1. 拷模板,填真实值(连接串从 INFRA.md §0 速查表抄)
cp apps/<app>/secret.template.yaml /tmp/<app>-secret.yaml
$EDITOR /tmp/<app>-secret.yaml

# 2. 用 infras 提供的脚本加密
~/zff/项目/infras/scripts/seal-secret.sh \
  -i /tmp/<app>-secret.yaml \
  -o apps/<app>/sealed-secret.yaml

# 3. 销毁明文
rm /tmp/<app>-secret.yaml

# 4. 提交
git add apps/<app>/sealed-secret.yaml
git commit -m "feat(<app>): seal secrets"
git push
```

## secret.template.yaml 该长什么样

每个应用自己定,基本骨架:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <app>-secret
  namespace: <app>
type: Opaque
stringData:
  DATABASE_URL: "CHANGE_ME"
  REDIS_URL: "CHANGE_ME"
  # ... 应用需要的连接串和密钥
```

注意:
- `metadata.namespace` **必须填**,SealedSecret 默认是 namespace-scoped 的
- 字段类型用 `stringData`,kubeseal 会自动 base64 编码

## 旋转密钥

直接重新跑一遍上面的流程,git push 后 ArgoCD 自动同步;新 Secret 写入
集群后,Pod 会在下次重启时拿到新值。强制立刻生效:

```bash
kubectl rollout restart -n <app> deploy
```

## 控制器灾难恢复

如果 sealed-secrets controller 重装,私钥变了,所有现有 SealedSecret
都解不出来。预防:

```bash
# bootstrap.sh 自动备份的公钥
ls $SK_INFRA_DIR/secrets-backup/sealed-secrets-pub.pem

# 完整私钥导出(更稳妥,放进密码管理器)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml
# ↑ 这个文件极其敏感!放 1Password / Bitwarden,绝对不入 git
```

恢复:

```bash
kubectl apply -f sealed-secrets-keys-backup.yaml
kubectl rollout restart -n kube-system deploy/sealed-secrets-controller
```

## 常见问题

### `ERROR: sealed-secrets controller 不在 namespace=kube-system 中`
集群没装,或没在默认 namespace。先 `bash bootstrap.sh` 装上;
若 controller 在别的 namespace,加 `-n <ns>` 给 seal-secret.sh。

### `kubeseal: invalid public key`
本机缓存的公钥过期(controller 被重装)。删缓存重试:
```bash
rm -rf ~/.config/kubeseal
```

### 我能看明文吗?
解密发生在控制器内,你拿不到明文(这是设计)。Pod 启动时通过
`envFrom: secretRef:` 注入。要本地调试用同一份连接串,从 INFRA.md
速查表抄。

## 谁该读这篇

- 任何要把应用接 Outpost CICD 的人
- 帮新人 onboarding 的 maintainer
- 处理"密钥泄露 / 旋转 / 找回"事件的 oncall
