# 06 — 故障排查

## 通用诊断

```bash
./status.sh           # 快速快照 + sync 心跳
./verify.sh           # 详细检查
./verify.sh --json    # 机器可解析,供 AI agent 使用
```

`verify.sh` 的检查 id 是 `<area>.<subject>`,和下面的小节一一对应:
`compose.*` / `cloudflared.*`、`k8s.*` / `buildkit.*`、`ci.*`、
`sync.*`、`reconcile.*`、`data.*`、`edge.*`、`creds.*`。

## Compose 层

`full` 模式下 Compose 里只有 `cloudflared` + `caddy`(`edge` profile),
数据服务已经搬进 k3s —— 见
[ADR-0004](../../../docs/decisions/0004-data-layer-in-k3s.md)。
`local` 模式下则只有那四个数据服务(`local-data` profile)。

### 容器起不来
```bash
cd core/compose
docker compose ps
docker compose logs <service> --tail 100
```

### cloudflared 没连通
```bash
docker logs cloudflared --tail 100
```
找 `Registered tunnel connection`。常见失败:
- `failed to fetch token` → `CF_TUNNEL_TOKEN` 错了 / 过期
- `connection refused` → CF Public Hostname 的 URL 指错了 service:port
- QUIC 被封(UDP/7844)→ `.env` 里设 `CF_TUNNEL_PROTOCOL=http2` 后重启。
  注意这会让 `cloudflared access` 的 TCP 路由彻底不可用
- DNS 问题 → `docker exec cloudflared nslookup api.cloudflare.com`

## k3s / K8s

### k3s 起不来(Linux/WSL2)
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 200
```
WSL2 常见原因:缺 cgroup v2 → 在 `/etc/wsl.conf` 启用 systemd;
iptables 模块不可用 → `sudo apt install iptables`;6443 端口被占。

### Traefik 不在 NodePort 30080
```bash
kubectl get helmchartconfig -n kube-system
kubectl describe svc -n kube-system traefik
```
类型应为 `NodePort`,端口里应有 `web: 30080`。cloudflared 是通过
`host.docker.internal:30080` 找过来的,所以它一挂,所有公网 HTTP 路由都死。

### Pod 一直 Pending
```bash
kubectl describe pod -n <ns> <pod>
```
常见:`Insufficient memory`(给 WSL 加内存);`unbound PVC`(local-path
provisioner 没跑);`exceeded quota`(`apps` 命名空间带 `ResourceQuota` ——
`kubectl describe quota -n apps`)。

## 数据层(`infra-bridges`)

`verify.sh` 的 id:`data.postgres` / `data.redis` / `data.rabbitmq` /
`data.manticore`。每一项都是在 pod 内部执行的真实带认证探测,所以 FAIL
意味着服务真的挂了或在拒绝凭据。

```bash
kubectl -n infra-bridges get pods
kubectl -n infra-bridges logs sts/postgres --tail 200

# verify.sh 跑的就是这几条探测
kubectl -n infra-bridges exec sts/postgres  -- sh -c 'pg_isready -U "$POSTGRES_USER"'
kubectl -n infra-bridges exec deploy/redis  -- sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
kubectl -n infra-bridges exec sts/rabbitmq  -- rabbitmq-diagnostics -q ping
```

应用连不上数据服务,几乎总是连接串里的 Service 名写错了。这些名字在两种模式下
都不变:

```bash
kubectl exec -it -n apps <pod> -- \
  nslookup postgres.infra-bridges.svc.cluster.local
```

> 集群 DNS 里已经**没有** `host.docker.internal` 了。任何应用配置还指着它
> 就是 bug —— CoreDNS 的 `coredns-custom` 桥已在 bootstrap 时删除。

## 构建引擎(buildkit + registry)

### `buildkit.daemon` FAIL —— 所有构建都会失败
```bash
kubectl -n buildkit get pods
kubectl -n buildkit logs deploy/buildkitd --tail 200
kubectl wait --for=condition=Available deployment/buildkitd -n buildkit --timeout=420s
```
守护进程的 startupProbe 在恢复脏缓存时允许约 6 分钟,所以刚重启后"还没
Ready"是正常的;"一直没 Ready"不正常。

### runner 连不上 buildkitd 或 registry
两者都以 NodePort 暴露给主机:

```bash
curl -s http://127.0.0.1:30500/v2/            # registry API → {}
nc -z 127.0.0.1 30750 && echo buildkitd-ok    # buildkitd gRPC
kubectl -n outpost-ci get svc                 # NodePort 定义在这
```

### push 401 / 拉镜像 401
- 自建 registry 在集群层面是匿名的;从外面访问 `https://registry.<root>`
  报 401 通常是 Cloudflare 那条 **HTTP Host Header** 覆盖没配
  (见 `01-cloudflare-setup.md`)
- `aliyun-acr` 需要真实凭据 —— 检查 `.env` 里的 `ALIYUN_ACR_*`

## CI(GitHub Actions self-hosted runner)

`verify.sh` 的 id:`ci.runner`、`ci.runner.unit`、`ci.runner.online`、
`ci.workflow.<app>`。

### `ci.runner` WARN —— "runner not configured"
`GITHUB_RUNNER_PAT` 是空的,bootstrap 跳过了 runner 安装。
**永远不会有构建被触发。** 在 `.env` 里设好 `GITHUB_RUNNER_URL` +
`GITHUB_RUNNER_PAT` 后重跑 `bash bootstrap.sh`。(只有跑本仓库自己的
CI/e2e 时,这个状态才算合法。)

### `ci.runner.unit` FAIL —— 没有在跑的 runner 服务
```bash
systemctl status 'actions.runner.*'
cd ~/actions-runner && sudo ./svc.sh status
sudo ./svc.sh start
journalctl -u 'actions.runner.*' -n 200
```
这种情况下 push 会**在 GitHub 那边排队**而不是报错,应用侧看起来一切正常 ——
这条检查就是那个信号。

### `ci.runner.online` FAIL —— "CI trigger path down"
GitHub API 说没有在线 runner,或者 API 本身连不上。
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com   # 代理/出网通吗?
systemctl status 'actions.runner.*'
```
走代理时,runner 从它自己的 env 文件读代理变量(`~/actions-runner/.env`,
bootstrap 时从 `~/.outpost-proxy.env` 灌进去)。如果手动跑能通、做成服务就不通,
先看这个文件。另外确认 PAT 还有 `admin:org`(组织地址)或仓库 admin 权限。

### `ci.workflow.<app>` FAIL / WARN
- `no workflow runs yet` → 应用仓库里缺
  `.github/workflows/outpost-build.yml`(从 `templates/github/` 拷)
- `last run: failure` → 去 GitHub Actions 页打开那次运行;三个关键步骤是
  `Build image`、`Run tests (Gate A)`、`Update manifest`

### push 根本没到 github
github 副本只是 CI 触发面,镜像死掉是无声的:
```bash
git ls-remote <github-url> refs/heads/main
git ls-remote <gitee-url>  refs/heads/main   # 两边应该一致
```
重新检查双推 remote(`git remote -v`)或 gitee 的 push-mirror 设置。
对账机制存在的意义,正是抓这一类失败。

## CD(manifest-sync)

`verify.sh` 的 id:`sync.cronjob`、`sync.heartbeat`、`sync.result`。

### `sync.cronjob` FAIL —— CronJob 不见了
什么都不会部署。重跑 `bash bootstrap.sh`(Phase 8 会重建它,并阻塞到写出
新鲜心跳为止)。

### `sync.heartbeat` FAIL —— 心跳过期
心跳超过 3× `MANIFEST_SYNC_INTERVAL`;不管 CronJob 对象在不在,sync 都已经
不跑了。
```bash
kubectl -n outpost-ci get cm sync-heartbeat -o yaml
kubectl -n outpost-ci get jobs
kubectl -n outpost-ci get pods
outpost logs sync
```
常见原因:机器睡了/停了(WSL distro 停止)、SA 丢了 apply 权限,或上一个 job
卡死(`concurrencyPolicy: Forbid` 意味着一个挂住的 job 会挡掉后面所有 tick,
删掉它)。

### `sync.result` FAIL —— 上一次运行出错
`outpost logs sync` 会打印原因。`last_result` 的值本身就有自述性:

| `last_result` | 含义 |
|---|---|
| `error:git-clone` / `error:git-fetch` | 拉不到 manifest 仓库 —— `notify-secrets` Secret 里的 `GIT_USER`/`GIT_TOKEN`,或 gitee 不可达 |
| `error:unexpected-rc=<n>` | job 异常中断;去看 pod 日志 |
| 其他非 `ok` 值 | 某个应用的 apply 或 rollout-wait 失败 —— 日志里会点名 |

### sync 跑得好好的,但我的应用没变
```bash
outpost status        # applied_head —— 是你 push 的那个 commit 吗?
```
`manifest-sync` 只 apply `applied_head` 到 `HEAD` 之间**有变化的**
`apps/<dir>`。只动了 `argocd-apps/` 或文档的提交会被记成 "nothing to apply"
—— 那个目录是历史遗留,被直接忽略。

要强制把当前 head 的所有 `apps/<dir>` 全量重 apply,把记住的位置清掉即可 ——
`applied_head` 为空时下一次就是全量 sync:

```bash
kubectl -n outpost-ci delete cm sync-heartbeat
kubectl -n outpost-ci create job manifest-sync-full --from=cronjob/manifest-sync
```

(脚本同样认环境变量 `FORCE_SYNC=1`,走的是同一条代码路径。)

### 立刻触发一次 sync
```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
outpost logs sync
```

## 对账(最终裁判)

`verify.sh` 的 id:`reconcile.git`、`reconcile.manifest`、`reconcile.repos`、
`reconcile.<app>`。

`reconcile.<app>` FAIL 的含义是:这个仓库的 **live 分支头**在
`OUTPOST_STALENESS_THRESHOLD`(默认 1800 秒)内没有变成**已部署的镜像 tag**。
它**故意**不告诉你是哪一环断了 —— 它告诉你整条链断了,而这正是过去能连续
几天没人发现的那件事。按顺序排查:

1. push 到 github 了吗?(`git ls-remote`)
2. runner 在线吗?(`ci.runner.*`)
3. 工作流红了吗?(GitHub Actions 页)
4. manifest 仓库拿到那条 bump 提交了吗?
5. sync 活着且是绿的吗?(`sync.*`)

`reconcile.repos` WARN 表示 `OUTPOST_REPOS` 是空的 —— 反静默那一层是瞎的。
把应用接进来(`outpost onboard <url>`)。

## 测试网关、自动回滚、告警

(只有你选了才生效 —— 见 `00-quickstart.md` Phase J。)

### Gate A 总是被跳过
仓库根既没有 `outpost.test.yaml` 也没有 `Dockerfile.test`。这是干净的 no-op,
不是失败。加上任一文件即可启用。`TEST_RUNNER` 为 `none` 或 `catalog-tasks` 时
Gate A 同样 no-op。

### Gate A 报 "yq required" / "docker required"
两者都跑在 **runner 主机**上,不在集群里。请在那台机器上装 `yq`
(mikefarah v4+)和 Docker。Gate A **故意**拒绝降级成裸机执行:应用仓库里的
命令属于不可信代码,所以永远在容器里跑,工作区 bind-mount 到 `/workspace`。

### Gate A 报 `sh: <tool> not found`
命令默认在 `alpine:3.20` 里执行。要么在 `outpost.test.yaml` 里把
`runner.image` 设成真正带工具链的镜像(`golang:1.23-alpine`、
`python:3.12-alpine` 等),要么在命令里自己装。

### 金丝雀老是自动回滚
只在 `ROLLOUT_PLUGIN=argo-rollouts` 时相关。
```bash
kubectl get rollout -n apps
kubectl describe rollout -n apps <name>
```
`manifest-sync` 轮询 `.status.phase`,读到 `Degraded` 就判定本次 sync 失败,
于是发 `deploy-failed`。

### 告警不触发
- `.env` 里 `NOTIFICATION_PROVIDERS` 是空的 → 至少填一个通道后重跑 bootstrap
- 确认 provider 配置真的进了集群,用
  `kubectl -n outpost-ci describe secret notify-secrets` —— 它只列出 key 名
  和字节数。**不要**在这里用 `-o jsonpath='{.data}'` 或 `-o yaml`,
  那会把 base64 值直接打进终端和 shell 历史
- 构建失败的告警从 **runner** 发出,不走集群:那条路径通过
  `notify-fanout.sh --env-file` 直接读 `.env`
- 钉钉 / 飞书的加签 webhook:主机时钟偏移会让 HMAC 签名失效 —— 保持时钟同步

## 网络 / Cloudflare

### 域名解析不了
```bash
dig registry.<root>
```
应返回 Cloudflare 的 IP。NXDOMAIN = NS 没切,或 Public Hostname 没配。

### 域名能解析但 502 / 521 / 522 / 524
- 502:后端服务挂了(Traefik,或它背后的应用)
- 521 / 522 / 524:cloudflared 连不到 origin → 确认容器在跑、
  `docker logs cloudflared`、Traefik 还占着 NodePort 30080

### 本来好好的,整个域名突然全黑
WSL2 上,distro 一停,cloudflared、k3s、runner 一起停。检查 Windows 的自启动
任务和 `/tmp/outpost-autostart.log`(见 `03-windows-autostart.md`)。
`outpost-verify.timer` 是 `Persistent=true` 的,distro 回来后会补跑一次
`verify.sh` —— 告警就是从那儿来的。

## 守卫定时器不报警

```bash
systemctl status outpost-verify.timer
systemctl list-timers outpost-verify.timer
journalctl -u outpost-verify.service -n 100
```
它每 30 分钟(开机后 5 分钟起)跑一次 `verify.sh --quiet`,FAIL 通过
`notify-fanout.sh` 扇出。它**刻意**活在主机上、集群和 GitHub 之外 ——
关掉它,你就回到了靠手工发现故障的年代。macOS 没有 systemd,请用
LaunchAgent 调度 `platform/systemd/outpost-verify-run.sh`。

## 最后手段 —— 完全重置

```bash
./reset.sh         # 输入确认串。保留 secrets-backup/
./bootstrap.sh     # 从 secrets-backup/ 恢复 sealed-secrets 主密钥
```

如果怀疑 sealed-secrets 主密钥泄露,或想要彻底干净的环境(包括强制重封所有
已有 SealedSecret):

```bash
./reset.sh --hard  # 连 secrets-backup/ 一起清 —— 之后 manifest 仓库里
                   # 每一个 SealedSecret 都必须重新封装
./bootstrap.sh
```

整机重建(换 WSL2 机器、清 distro)请改走
`../../../docs/prp/runbooks/wsl2-redeploy-0.3.md` —— 它覆盖了 `reset.sh`
不管的数据快照步骤。
