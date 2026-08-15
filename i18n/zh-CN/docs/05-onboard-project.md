# 05 — 接入新项目（onboard）

把一个新仓库纳入 CICD 体系，全程 ~ 5 分钟。

> **想先试通流水线再接自己的项目?** 直接用 `examples/hello-world/<lang>/`
> 里的现成 Hello-World 当应用仓库(支持 React / Vue / C# / Python / Java
> / Go),~2 分钟跑通端到端,所有 manifest 和 Dockerfile 都已就绪。
> 见 `../../../examples/hello-world/README.md`。

## 快速路径（命令速查）

下面的完整步骤覆盖所有细节；这里是已经熟悉流程的团队可以直接照抄的命令序列：

```bash
# 1. 新仓库?从 hello-world 模板 scaffold 一个(已有应用仓库+根目录 Dockerfile 则跳过)
bash scripts/outpost new-app <name> --lang <go|python|java|csharp|react|vue>

# 2. push 应用源码到 gitee(主)和 github(CI 触发面)

# 3. 把仓库注册进 Outpost:写入 OUTPOST_REPOS,并打印 CI 接线步骤 ——
#    没有任何 webhook 要配
bash scripts/outpost onboard <clone-url>

# 4. 把 CI 工作流拷进应用仓库(步骤 3 会打印确切路径)
cp templates/github/outpost-build.yml \
   <app-repo>/.github/workflows/outpost-build.yml

# 5. 把 deployment/service/ingress/kustomization scaffold 进
#    manifest 仓库的本地 clone
bash scripts/outpost manifest scaffold <app> --lang <lang> \
  --manifests-dir <manifest仓库本地clone路径>

# 6. 创建应用的 Postgres 数据库(应用不需要数据库则跳过)
bash scripts/outpost db create <app>

# 7. seal manifest 里引用的密钥
bash scripts/outpost seal <app> KEY=value ...

# 8. commit + push manifest 仓库 — 之后交给 manifest-sync 接管
bash scripts/outpost verify --app <app>   # 下一次 sync 之后确认 pod / 镜像
```

> ℹ️ **现在真正重要的注册表是 `OUTPOST_REPOS`。** 它取代了
> `WEBHOOK_REPO_WHITELIST`,但它**不是闸门**,而是
> **`verify.sh` 对账要遍历的正向清单**。没写进去的仓库照样能构建、能部署;
> 你丢掉的是反静默那一层 —— 因为没人再拿它的 live HEAD 去比对已部署的镜像
> tag。`outpost onboard` 会自动追加,`outpost off-board` 负责移除。

## 前置条件

- `bash bootstrap.sh` 已成功跑完
- manifest 仓库(`MANIFEST_REPO_URL`)存在,且至少有一个空的 `apps/` 目录
- GitHub Actions self-hosted runner 已注册且在线
  (`systemctl status 'actions.runner.*'`)
- 手边有 `INFRA.zh-CN.md` 拿连接串

## 步骤

### 1. 应用代码仓库

建仓库、推代码,根目录必须有 `Dockerfile`。

两个 remote,各司其职:

| Remote | 角色 | 必须同步吗 |
|--------|------|-----------|
| **gitee**(主) | 你 push 的地方、对账读的地方、manifest 仓库所在地 | — |
| **github**(副本) | 存在的唯一理由:GitHub Actions 从它触发构建工作流 | 是 —— 镜像死了 = 构建静默停止 |

推荐用**双推**保持同步(推的时候失败会当场在终端看到):

```bash
cd <app-repo>
git remote set-url --add --push origin <gitee-url>
git remote set-url --add --push origin <github-url>
# 现在一条 git push 同时到两个平台
```

另一个选择是 gitee 的**单向** push-mirror(gitee → github,在 gitee 仓库设置
里配)。只用单向的 —— gitee 官方文档自己就提醒双向镜像那 30 分钟的窗口可能
丢 commit。无论哪种,镜像死掉是靠 `verify.sh` 对账发现的,工作流内部没有任何
东西能察觉。

### 2. 注册仓库

```bash
bash scripts/outpost onboard <clone-url>
```

它把 URL 追加进 `.env` 的 `OUTPOST_REPOS`(幂等),并打印 CI 接线步骤。
如果来源里带 `outpost.app.yaml`,还会**同时**按 Compose 层应用接入
(生成 Caddy 片段 + compose override)。常用参数:`--dry-run`、
`--manifests-dir <path> --lang <lang>`(顺手 scaffold k8s manifest)、
`--install-skill`(把 LLM 接入 skill 放进应用的 `.claude/skills/`)。

### 3. 应用仓库 —— CI 工作流

```bash
mkdir -p <app-repo>/.github/workflows
cp templates/github/outpost-build.yml \
   <app-repo>/.github/workflows/outpost-build.yml
# 部署分支不是 main 就改 `branches: [main]` 那一行
git -C <app-repo> add .github/workflows/outpost-build.yml
git -C <app-repo> commit -m "ci: outpost build workflow"
```

这个 ~40 行的文件就是每个仓库 CI 面的**全部**。真正的逻辑都在 runner 主机上
本仓库那些加固过的脚本里,通过 `$OUTPOST_ROOT` 解析(bootstrap 装 runner 时
写进 `~/actions-runner/.env`)。所以升级构建逻辑 = 在 Outpost 主机 `git pull`,
而不是改 N 个应用仓库。细节见 `templates/github/README.md`。

推到部署分支,runner 就会接手。在应用仓库的 **GitHub Actions** 页看,或在主机上看:

```bash
journalctl -u 'actions.runner.*' -n 200
```

### 4. manifest 仓库 —— `apps/<app>/`

> **更快的路径:** `bash scripts/outpost manifest scaffold <app> --lang <lang> --manifests-dir <path>`
> 会从对应的 hello-world 模板生成下面所有文件并完成改名。
> `outpost new-app <name> --lang <lang>` 则是 scaffold **应用侧**到
> `my-apps/<name>/`。全部子命令见 `outpost help`。

往 manifest 仓库里加:

```
apps/<app>/
├── deployment.yaml
├── service.yaml
├── ingress.yaml
└── kustomization.yaml     ← 存在时 manifest-sync 优先走 apply -k
```

`deployment.yaml` 的要点:

```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.<root>/<app>:latest   # ← 每次 push 由 CI 改写
          # 密钥来自 SealedSecret —— 见 4b。绝不要在这里内联明文连接串。
          envFrom:
            - secretRef:
                name: <app>-secrets
          # 非密钥配置可以内联:
          env:
            - name: LOG_LEVEL
              value: "info"
          # apps 命名空间自带 LimitRange(每容器默认 500m / 512Mi,
          # 上限 4cpu / 8Gi)。只有需要不同值时才自己声明。
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 1,    memory: 512Mi }
```

`ingress.yaml` 用 `<app>-apps.<root>` —— 被 Cloudflare Tunnel 那条 `*.<root>`
兜底通配接住,不用为每个应用改 CF。`-apps` 后缀保证 FQDN 只有一级子域,
免费 Universal SSL 的 `*.<root>` 证书才覆盖得到(二级 `*.apps.<root>` 要付费
Advanced Certificate Manager)。

**镜像 tag 格式:** CI 写的是 7 位短 SHA(`registry.<root>/<app>:abc1234`)。
这个 `sha-7` 形状是一份契约 —— `verify.sh` 对账拿它和仓库的 live 分支头做比较。
回滚用 `outpost rollback <app> [sha]`。

> ⚠️ `outpost manifest scaffold` 还会写第 5 个文件 `argocd-apps/<app>.yaml`。
> 那是**历史遗留**:`manifest-sync` 只读 `apps/`,一次只碰 `apps/` 之外的提交
> 会被记成 "nothing to apply"。这个文件无害,可以直接删。

#### 4b. 密钥 —— 绝不内联明文

Outpost 开箱带 SealedSecret。机制与灾备见
[08-seal-secret.md](./08-seal-secret.md);标准示例在
[`examples/demo-app/`](../../../examples/demo-app/) —— 看它的
`README.md`、`secret.example.yaml`、`sealed-secret.example.yaml`。

最短路径:

```bash
# 1. 取集群的封装公钥
kubeseal --fetch-cert > /tmp/pub.pem

# 2. 明文放在 manifest 仓库之外(封完就删)
cp examples/demo-app/secret.example.yaml ~/secrets/<app>.yaml
$EDITOR ~/secrets/<app>.yaml          # 按 INFRA.zh-CN.md 填 <REPLACE_*>

# 3. 封装 —— 输出进 manifest 仓库
kubeseal --cert /tmp/pub.pem -o yaml \
  < ~/secrets/<app>.yaml \
  > <manifest-repo>/apps/<app>/sealed-secret.yaml

# 4. 只提交 SealedSecret,永远不要提交明文
rm ~/secrets/<app>.yaml
```

**跨 reset 存活:** Outpost 会自动把 RSA 主密钥备份到
`secrets-backup/sealed-secrets-master.key.yaml`,下次 `bootstrap.sh` 自动恢复。
普通 `reset.sh` 保留该文件;`reset.sh --hard` 会抹掉它(所有已有 SealedSecret
都必须重新封装)。见 [08-seal-secret.md](./08-seal-secret.md)。

### 5. push manifest 仓库

```bash
git add apps/<app>/
git commit -m "feat: onboard <app>"
git push
```

`manifest-sync`(命名空间 `outpost-ci`)每 `MANIFEST_SYNC_INTERVAL` 分钟拉一次,
比对 `applied_head..HEAD`,对每个被改动的 `apps/<dir>` 执行 `kubectl apply -k`,
然后等 rollout。除此之外没有任何要配的东西:**manifest 仓库也不需要 webhook**,
也没有 sync 按钮要按。等不及的话:

```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
outpost logs sync
```

### 6. 看部署结果

```bash
outpost status                # sync 心跳:last_sync_ts / applied_head / last_result
outpost verify --app <app>    # pod + 已部署镜像 + 近期 events
outpost logs <app>            # 'apps' 命名空间里该应用的日志
```

应用地址:`https://<app>-apps.<root>`。

### 7.（可选）接测试网关 + 自动回滚

在应用仓库根放 `outpost.test.yaml`,CI 就会在**改 manifest 之前**跑测试
(Gate A —— 测试红了 manifest 就不动,集群永远看不到坏镜像)。
把 `ROLLOUT_PLUGIN=argo-rollouts` 打开,再把 `Deployment` 换成
`argoproj.io/v1alpha1/Rollout`,就有了金丝雀 + 自动回滚;`manifest-sync`
认得 `Rollout` 这个 kind,读到 `Degraded` 就判定本次 sync 失败。
多通道告警(钉钉 / 飞书 / 企微 / 通用 webhook)在
`build-failed` / `deploy-failed` / `verify-failed` 时扇出。

操作步骤见 [`00-quickstart.md`](./00-quickstart.md) 的 Phase J。
设计史(Tekton/ArgoCD 时代 —— 看**为什么**,别照抄**怎么做**):
[`proposals/cicd-test-gate.md`](./proposals/cicd-test-gate.md)。

### 8.（可选）每应用构建配置 —— `outpost.build.yaml`

默认 CI 用 `./Dockerfile`、上下文 `./`,并带上 registry plugin 相关的默认参数。
在应用仓库根放一个 `outpost.build.yaml` 可以覆盖其中任意项:

```yaml
dockerfile: ./services/api/Dockerfile     # monorepo / 子目录构建
context: ./services/api
buildArgs:                                # 每项变成 --build-arg=KEY=VAL
  - MAVEN_MIRROR=https://nexus.example.com/repository/maven-public
  - JAVA_VERSION=21
extraArgs:                                # kaniko 时代的透传字段
  - --single-snapshot
```

所有键都可选;文件不存在就完全保持默认。

> **v0.3 关于 `extraArgs` 的说明:** 构建引擎已经换成 buildkit
> (`buildctl` 打集群内的守护进程),不再是 kaniko。
> `scripts/ci/build-image.sh` 只从 `extraArgs` 里接受 `--build-arg=K=V`,
> **kaniko 专有的参数会被静默忽略** —— 这个过滤是刻意的(不过滤的话,
> 一个仓库的配置就能注入第二个 `buildctl` 参数,覆盖共享 registry 里
> 另一个应用的镜像 tag)。要传构建参数请用 `buildArgs`。

实例:
[`../../../examples/hello-world/go/outpost.build.yaml`](../../../examples/hello-world/go/outpost.build.yaml)。

## 排查

### 构建根本没启动

push 到了 gitee 但没到 github,或者 runner 挂了。按顺序查:

```bash
git ls-remote <github-url> refs/heads/main   # 镜像是不是最新的?
systemctl status 'actions.runner.*'          # runner 活着吗?
bash verify.sh                               # ci.runner.online / ci.workflow.<app>
```

这些情况 `verify.sh` 对账都能从外部抓到:一个仓库的 live HEAD 超过
`OUTPOST_STALENESS_THRESHOLD`(默认 1800 秒)还没变成已部署的 tag,就是 FAIL
并点名该仓库。

### 工作流失败了

在应用仓库的 GitHub Actions 页打开那次运行(或
`journalctl -u 'actions.runner.*' -n 200`),看是哪一步红:

- `Build image` —— Dockerfile 有错、拉基础镜像超时,或 buildkitd 没 Ready
  (`kubectl -n buildkit get pods`)
- `Run tests (Gate A)` —— 测试真挂了,或 runner 主机缺 `yq` / `docker`
- `Update manifest` —— manifest 仓库没有 `apps/<app>/`,或 `GIT_TOKEN` 没 push 权

### 镜像构建成功了,但应用没更新

- 看 manifest 仓库有没有 CI 机器人的新提交
  (`chore(<app>): bump image to <sha>`)。没有 → 工作流的 `Update manifest`
  那一步没跑或失败了
- 有提交 → 问题在 CD 那半边:先 `outpost status`(`last_sync_ts` 新鲜吗?
  `last_result=ok` 吗?),再 `outpost logs sync`

### apps 里的 Pod CrashLoopBackOff
- 通常是连接串写错(bridge service 名字打错)
- `kubectl describe pod -n apps <pod>` 看 events
- `kubectl exec -it -n apps <pod> -- nslookup postgres.infra-bridges.svc.cluster.local`

### 我用 kubectl apply 上去的东西不见了

正常。`apps` 命名空间的事实来源是 manifest 仓库。你的改动不会被立刻覆盖
(self-heal 循环已经没了),但它悄悄偏离了声明,等这个应用下次 manifest
变更时就被抹掉。要改请改 manifest 仓库。

## 多 Git 平台

`GIT_PROVIDER_PLUGIN` 接受逗号分隔列表(如 `.env` 里写
`GIT_PROVIDER_PLUGIN=gitee,github,gitlab`)。v0.3 里它是**凭据契约,不是路由
契约**:每个列出的 provider 的 `preflight.sh` 会对它管辖 host 下的每个
`OUTPOST_REPOS` 条目做一次带认证的 `git ls-remote`,token 被吊销会在 bootstrap
当场报错,而不是以后悄悄断掉构建。没有 EventListener 要装配,也没有每家
provider 的 webhook 签名要配。

应用仓库在 manifest 仓库**之外**的 host 上时,补一份分 host 的凭据:

```env
GIT_CREDENTIALS_EXTRA=github.com|ci-bot|ghp_xxxx,gitlab.mycorp.com|ci-bot|glpat-yyyy
```

改完任一变量后重跑 `bash bootstrap.sh`。
