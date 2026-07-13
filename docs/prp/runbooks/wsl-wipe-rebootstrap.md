# WSL 清空重装 Runbook(一条 bootstrap 收敛)

> 适用场景:接受丢弃 WSL 上全部数据,从零重建 Outpost。
> 2026-07-13 goal-review 后编写;彼时 main 已含:CN egress vendoring、
> buildkitd 自愈、coredns IP 自愈、verdaccio 接入 bootstrap、verify 收尾自检。

## 0. 清空前必带走的东西(在 WSL 里执行)

只有两样是**不可再生**的,其余全部可由 bootstrap/CI 重建:

```bash
cd ~/Outpost   # WSL 上的 infras 克隆
# 1) .env —— 全部口令/配置(gitignored)
# 2) secrets-backup/ —— sealed-secrets 主密钥(gitignored)。
#    没有它,manifests 仓库里所有 SealedSecret 永久无法解密,
#    17 个应用的 secrets 要全部重新 seal 一遍。
tar czf /mnt/c/Users/<你>/outpost-carry.tgz .env secrets-backup/
```

可选(默认放弃,与"清空"决定一致):
- Postgres 业务数据:`docker exec postgres pg_dumpall -U postgres > /mnt/c/Users/<你>/pg-all.sql`
- @hy/* npm 包:不必备份,Mac 侧 `scripts/publish-hy-to-verdaccio.sh` 可重新发布

## 1. 清空(Windows PowerShell)

```powershell
wsl --shutdown
wsl --unregister <发行版名>     # 例: Ubuntu
# 重新安装发行版,进入后装好 systemd(Ubuntu 默认已启用)
```

## 2. 重建

```bash
git clone https://github.com/smithyhaus/Outpost.git ~/Outpost && cd ~/Outpost
tar xzf /mnt/c/Users/<你>/outpost-carry.tgz    # 放回 .env + secrets-backup/

# .env 清理两行再跑(让新默认值生效):
#   删除 TESTKUBE_MODE=oss        → 采纳新默认 skip(不再等 GAR 超时 5 分钟)
#   删除 ARGOCD_ADMIN_PASSWORD=…  → 让新集群的真实密码重新写入
sed -i '/^TESTKUBE_MODE=/d; /^ARGOCD_ADMIN_PASSWORD=/d' .env

bash bootstrap.sh   # 结尾自动跑 verify.sh,横幅按结果措辞
```

bootstrap 自身现在负责:k3s(CN 镜像)+ metrics-server、compose 数据服务、
ArgoCD/Tekton/sealed-secrets/rollouts(vendored 清单,无 CN 直连)、buildkit
(自愈 daemon)、verdaccio、coredns IP 自愈 CronJob、PV Retain 守护、
sealed-secrets 主密钥恢复(读 secrets-backup/)。

## 3. bootstrap 后的三个手工步骤(内容层,机制无法代劳)

```bash
# 1) 重新发布 @hy/* 私有包(Mac 侧,verdaccio 是空的)
bash scripts/publish-hy-to-verdaccio.sh

# 2) webhook 注册(需要 admin 权限 GIT_TOKEN;幂等)
bash scripts/outpost register-webhooks --dry-run   # 先看
bash scripts/outpost register-webhooks

# 3) (若放弃了 pg 备份)业务库结构重建:各服务 prisma db push / 迁移脚本
```

## 4. 验收(全链路闭环)

```bash
./verify.sh                      # 期望 ALL PASS(或仅 WARN)
kubectl top node                 # metrics 工作
# 推一个测试 commit 到任意 fst-* 仓库 → 观察:
kubectl get pipelinerun -n tekton-pipelines -w   # 热构建端到端 ~2min(冷 ~7min)
# ArgoCD 全绿:
kubectl get application -n argocd
```

## 已知残余风险(接受项)

- buildkitd 单点(自愈已覆盖锁死/脏缓存,最坏 ~13min 自动恢复)
- 数据层仍在宿主 compose(coredns 自愈已覆盖 IP 漂移;结构性搬进 k8s 是
  下一阶段,见 docs/prp/reviews/ 相关记录)
- cloudflared healthcheck 的 `tunnel ready` 子命令在极老镜像上可能不存在,
  首次 `docker compose up` 后确认 `docker ps` 显示 healthy;异常则删掉该
  healthcheck 块再 up
