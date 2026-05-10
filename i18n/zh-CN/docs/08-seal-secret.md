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
- **公钥备份**:`secrets-backup/sealed-secrets-pub.pem`
- **私钥备份(v0.2 起)**:`secrets-backup/sealed-secrets-master.key.yaml`
  Phase 6 末尾自动备份,**下次 bootstrap Phase 6 开始处自动恢复**。
  这是 `reset.sh` + `bootstrap.sh` 循环之后,manifest 仓库里已有的
  SealedSecret 仍能解密的关键。文件在 .gitignore。
  `reset.sh` 默认保留;`--hard` 才彻底清(强制把所有现有 SealedSecret
  重 seal 到新密钥对)。

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

### 同一台主机(集群 reset / 重建)

`bootstrap.sh` Phase 6 末尾自动把 master key 备份到
`secrets-backup/sealed-secrets-master.key.yaml`,**下次 bootstrap Phase 6
开始处自动 restore**。所以最常见的"清掉集群重建"路径:

```bash
bash reset.sh                      # 默认保留 secrets-backup/
bash bootstrap.sh                  # restore master key → 老 SealedSecret 继续解密
```

无需重新 seal。验证:

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
# 跨 reset 同一个 Secret 名,说明密钥对真的保住了。
```

### 主机本身丢了(off-host 灾难)

如果整台主机消失(笔记本损坏 / VM 丢),`secrets-backup/` 里的 key 也没了。
防御办法:**把 master key 复制到密码管理器**。

```bash
cat secrets-backup/sealed-secrets-master.key.yaml
# → 整段 YAML 存进 1Password / Bitwarden / Vault 等。
# 新主机首次 bootstrap **之前**把 YAML 写回到
# secrets-backup/sealed-secrets-master.key.yaml。
```

### 强制轮换密钥

```bash
bash reset.sh --hard               # 彻底清掉 secrets-backup/
bash bootstrap.sh                  # 生成全新的 master key
# 把所有 manifest 仓库里的 SealedSecret 用新公钥重 seal 一次。
```

`--hard` 适用场景:怀疑 master key 已泄露,或想给新环境一个干净起点。

## 常见问题

### `kubeseal: invalid public key`
本机缓存的公钥过期(controller 重装)。删缓存重试:
```bash
rm -rf ~/.config/kubeseal
```

### 集群端 SealedSecret 一直报 `cannot decrypt`
私钥与加密时的公钥不匹配。常见于 controller 被重装。要么用备份的私钥
恢复,要么应用端重生成 sealed-secret(即重跑 onboard 脚本)。
