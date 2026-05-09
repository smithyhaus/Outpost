# CI/CD 测试网关 + 自动回滚 + 多通道告警

> **状态**:**Approved**(2026-05-10)— Phase 1 MVP 实施中
> **作者**:Outpost Eng
> **创建日期**:2026-05-10
> **关联**:`plugins/git-provider/`、`plugins/registry/`、`core/k8s/05-tekton/`、`core/k8s/06-argocd/`

---

## TL;DR

在现有 `Tekton (CI) → ArgoCD (CD)` 链路上,补齐三件事:

1. **测试网关**(Gate A 预部署 + Gate B 部署后)
2. **自动回滚**(部署后健康分析失败 → 自动撤回流量)
3. **多通道告警**(钉钉 / 飞书 / 企微 / 通用 webhook,plugin 化)

不重复造轮子,**全部用上游标准方案拼接**:

| 能力 | 选型 | 理由 |
|---|---|---|
| 测试编排 | **Testkube** | K8s 原生 CRD,30+ 测试引擎,官方 Tekton 集成,失败回调 webhook 一行配 |
| 渐进交付 + 自动回滚 | **Argo Rollouts** | ArgoCD 同门,AnalysisTemplate 内置 Web/Job/Prometheus provider,毫秒级自动撤回 |
| 多通道告警(后端) | **ArgoCD Notifications**(controller 内置)+ **Tekton `finally` task** | ArgoCD 2.3+ 自带钉/飞/企/Slack/email/webhook 适配器,Tekton 一个 task 串通三方 |
| 通道选择 | 沿用 `plugins/` 架构,新增 `notification/`、`test-runner/`、`rollout/` 三家族 | 装哪家 = `apply` 哪个 plugin,bootstrap 时按 `.env` 选择性启用 |

新增 plugin 家族 **总共 6 个 plugin**:
```
plugins/
├── notification/{dingtalk,feishu,wecom,webhook-generic}/   ← 4 个
├── test-runner/{testkube,catalog-tasks}/                   ← 2 个
└── rollout/argo-rollouts/                                   ← 1 个 (MVP 必装)
```

---

## 一、最终架构

```
                         push                          finally task
  开发者 ──────────► Tekton Pipeline ──────────────────────────────► 通知 plugin
                          │                                           (钉/飞/企/webhook)
                          │ build & push image
                          │
                          ▼
                  ┌───────────────┐ Gate A
                  │  run-tests    │ ──── 失败 ──► abort,manifest 不更新,通知
                  │  (Testkube)   │
                  └───────────────┘
                          │ ✓
                          ▼
                  update-manifest (image tag → manifest 仓库)
                          │
                          ▼
                  ArgoCD 检测变更 → kubectl apply
                          │
                          ▼
                  ┌───────────────┐ Gate B
                  │ Argo Rollouts │  Canary 10%/25%/50%/100%
                  │   分析模板    │     ↳ 每档 AnalysisTemplate 跑探针
                  └───────────────┘     ↳ provider: Web (HTTP 健康)
                          │              + Job (跑 Testkube TestWorkflow)
                          │
                ┌─────────┴─────────┐
                │                   │
              成功 ✓             失败 ✗
                │                   │
                ▼                   ▼
            进入下一档        Rollouts 自动回滚到上一稳定版
                            argocd-notifications → 通知 plugin
                            (同一个 webhook 抽象)
```

**关键洞见**:
- **测试定义只写一次**(Testkube `TestWorkflow` CRD),Gate A 和 Gate B 用同一份。
- **通知 payload 只设计一次**(下文契约),Tekton finally / ArgoCD 通知 / Testkube 失败回调都用相同 schema。
- **plugin 装载只改 `.env`**,bootstrap 重跑即可。

---

## 二、组件选型 — 候选对比

### 2.1 测试编排:为什么是 Testkube

| 候选 | License | Tekton 集成 | 多语言/多框架 | K8s 原生 CRD | 失败 webhook | 评价 |
|---|---|---|---|---|---|---|
| **Testkube** | Apache 2.0 | ✅ 官方 Task `kubeshop/testkube-cli` | ✅ 30+:Cypress / Playwright / Postman / k6 / JMeter / Pytest / Jest / JUnit / Ginkgo / Maven / Gradle / dotnet test 等 | ✅ `TestWorkflow` / `TestTrigger` | ✅ `end-test-failed` 事件直发 | **首选** |
| Tekton Catalog tasks(每语言一个) | Apache 2.0 | 原生 | 各自维护 | 否 | 需自己 finally task 串 | 太散,文件多,跨语言契约不一致 |
| Argo Workflows + 自定义 | Apache 2.0 | 通过 EventListener | 自己写 | 一般 | 自己写 | 重叠 Tekton,且不是测试导向 |
| Sonobuoy | Apache 2.0 | 弱 | ❌ 主要做集群一致性测试 | ✅ | 弱 | **不适用** — 是测集群不是测应用 |

**结论 — Testkube** 是 K8s 原生测试编排的事实标准(GitHub `kubeshop/testkube`,Apache 2.0,活跃维护到 2026)。它有官方 Tekton 集成文档,且把"测试"建模为 CRD,完美契合我们的 GitOps 哲学。

**Testkube 关键 CRD**(2026 主推):
- `TestWorkflow` — 取代旧的 `Test` / `TestSuite`,DAG 形式定义一组测试,可多步、可并行、可有依赖容器(数据库/redis 等)。
- `TestTrigger` — 把"集群事件 → 跑测试"声明化(可选,用于 post-deploy 自动触发)。

**调用方式**:Tekton 里加一个简单 task,跑 `testkube run testworkflow <name> --watch`(`--watch` 让 Tekton task 等到测试结束再退出,失败码 ≠ 0 自然让 Pipeline 失败)。

### 2.2 渐进交付 + 自动回滚:为什么是 Argo Rollouts

| 候选 | License | ArgoCD 配套 | Provider 多样性 | 自动回滚 | 流量切片 | 评价 |
|---|---|---|---|---|---|---|
| **Argo Rollouts** | Apache 2.0 | ✅ 同 argoproj | Prometheus / Web / **Kubernetes Job** / Datadog / NewRelic / InfluxDB / Wavefront | ✅ 默认行为 | Service mesh / Ingress / SMI 都支持 | **首选** |
| Flagger | Apache 2.0 | 弱 | Prometheus / Datadog | ✅ | Istio / Linkerd / NGINX / Traefik | 跟 Traefik 配合不错,但跟 ArgoCD 集成弱 |
| 自己写 (kubectl rollback + 探针) | — | — | — | 半自动 | — | 不推荐 |

**结论 — Argo Rollouts**。AnalysisTemplate 的 **Job provider** 是关键 — 它能直接把"跑一遍 Testkube TestWorkflow"作为分析步骤,**测试和回滚共享同一份测试定义**,没有第二条 truth source。

**关键概念**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: post-deploy-smoke
spec:
  metrics:
    - name: smoke-test
      provider:
        job:
          spec:                                    # 这就是一个 Job spec
            template:
              spec:
                containers:
                  - name: smoke
                    image: kubeshop/testkube-cli
                    args: ["run", "testworkflow", "{{args.app}}-smoke", "--watch"]
```

Job exit 0 → 该档分析通过,流量继续切;exit ≠ 0 → 自动回滚 + 通知。

### 2.3 多通道告警:ArgoCD Notifications + Tekton finally

| 来源 | 工具 | 内置通道 |
|---|---|---|
| **ArgoCD 同步状态** | argocd-notifications controller(2.3+ 已合主仓) | Slack / Email / Webhook / Telegram / **Teams** / **Pushover** / 通用 GraphQL / 钉钉 / 飞书 / 企微均有社区 template |
| **Tekton Pipeline 失败** | `finally` task + curl/HTTP | 任意 webhook |
| **Testkube 测试失败** | Testkube webhook(`end-test-failed`) | 任意 webhook |
| **Argo Rollouts 回滚** | Rollouts events → argocd-notifications | 同 ArgoCD |

**统一思路**:**所有失败信号最后都走"webhook + 模板"**。每家 plugin 在 `manifest.yaml` 里只贡献两件事:
1. SealedSecret(webhook URL + 可选签名 secret)
2. ConfigMap(消息 template,把统一 payload 渲染成自家格式)

ArgoCD 那边直接 `argocd-notifications-cm` 接;Tekton/Testkube 那边走一个共用的 `notify-task`(读同一个 ConfigMap)。**plugin 不写代码,只贡献声明式配置**。

---

## 三、Plugin 家族详细设计

### 3.1 `plugins/notification/<provider>/`

文件结构(以 dingtalk 为例):
```
plugins/notification/dingtalk/
├── manifest.yaml         # 主清单,kustomize 入口
├── secret.template.yaml  # SealedSecret(webhook URL + sign key)
├── configmap.yaml        # 消息模板(钉钉 markdown 格式)
├── argocd-binding.yaml   # 一段 argocd-notifications-cm 片段(triggers + templates)
├── preflight.sh          # 检查 DINGTALK_WEBHOOK_URL / DINGTALK_SIGN_SECRET 是否在 .env
└── README.md
```

`.env` 新增变量(每家 plugin 自己管):
```
# 启用的通知 plugin(逗号分隔)
NOTIFICATION_PROVIDERS=dingtalk,feishu

# 钉钉
DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=...
DINGTALK_SIGN_SECRET=SEC...

# 飞书
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...

# 企微
WECOM_WEBHOOK_URL=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...

# 通用 webhook(自己接 receiver 时用)
GENERIC_WEBHOOK_URL=https://your-collector.example.com/hook
```

bootstrap 时根据 `NOTIFICATION_PROVIDERS` 选择性 apply。

### 3.2 `plugins/test-runner/<runner>/`

```
plugins/test-runner/
├── testkube/                      # 推荐路径
│   ├── manifest.yaml              # Testkube Helm chart values + namespace
│   ├── webhook-on-failure.yaml    # Testkube 自带 Webhook CRD,失败回调到 notify
│   ├── preflight.sh
│   └── README.md
└── catalog-tasks/                 # 轻量路径(给不想装 Testkube 的人)
    ├── manifest.yaml              # 引入 Tekton Catalog 的 golang-test/pytest/jest/junit/dotnet-test 任务
    ├── README.md
```

`.env`:
```
TEST_RUNNER=testkube         # 或 catalog-tasks 或 none
```

### 3.3 `plugins/rollout/argo-rollouts/`

```
plugins/rollout/argo-rollouts/
├── manifest.yaml             # Rollouts controller + Dashboard
├── analysistemplate-default.yaml  # 默认 AnalysisTemplate(Web provider 探针)
├── analysistemplate-smoke.yaml    # 调用 Testkube smoke 的 Job-provider 模板
├── ingressroute.yaml         # Rollouts Dashboard 走 traefik(rollouts.${ROOT_DOMAIN})
└── README.md
```

MVP 必装。`.env`:
```
ROLLOUTS_DASHBOARD_HOST=rollouts.${ROOT_DOMAIN}
```

---

## 四、契约约定

### 4.1 测试契约(应用仓库这边)

**优先级 fallback**:

1. 仓库根 `outpost.test.yaml`(声明式,支持依赖服务):
```yaml
# 应用仓库:my-app/outpost.test.yaml
version: 1
sidecars:                       # 起依赖服务
  - name: postgres
    image: postgres:16-alpine
    env: { POSTGRES_PASSWORD: testpass }
runner:
  image: my-app/test:latest     # 或 dockerfile: ./Dockerfile.test
  command: ["pytest", "-v"]
gates:
  pre-deploy:                   # Gate A
    timeout: 10m
  post-deploy-smoke:            # Gate B(给 Rollouts 跑)
    enabled: true
    image: my-app/smoke:latest
    timeout: 5m
```

2. 仓库根 `Dockerfile.test`(简单 fallback):build → kubectl run → exit code 即结果。

3. 都没有 → `when` clause skip(不算失败),只是少一道闸。

### 4.2 通知 payload schema(归一化)

```typescript
{
  event: "tekton.pipelinerun.failed"          // | "argocd.app.degraded"
                                               // | "argocd.app.sync_failed"
                                               // | "rollout.aborted"
                                               // | "rollout.completed"
                                               // | "testkube.test.failed",
  level: "info" | "warn" | "error",
  app:   string,                               // 应用名 = repo-name
  env:   string,                               // dev/staging/prod
  commit: string,                              // short SHA
  ref:   string,                               // branch / tag
  url:   string,                               // 跳转链接(Tekton Dashboard / ArgoCD UI)
  text:  string                                // 一句话说人话
}
```

每个通知 plugin 在自己的 ConfigMap 里放 Go template,把这个 payload 渲染成自家格式。例如钉钉:
```yaml
title: "[{{.level}}] {{.app}} - {{.event}}"
markdown: |
  ### {{.app}} `{{.commit}}` 在 `{{.env}}` 失败
  - 事件:{{.event}}
  - 详情:[查看]({{.url}})
  - 摘要:{{.text}}
```

### 4.3 触发规则(默认)

| 事件 | main 分支 | 非 main 分支 |
|---|---|---|
| Tekton pipeline 失败 | ✅ 必发 | 静默 |
| Tekton pipeline 成功 | 静默 | 静默 |
| ArgoCD sync failed | ✅ 必发 | ✅ 必发 |
| ArgoCD app degraded | ✅ 必发 | ✅ 必发 |
| Rollouts 回滚 | ✅ 必发(error 级) | ✅ 必发 |
| Rollouts 上线完成 | ✅ 必发(info 级,可选关) | 静默 |
| Testkube 测试失败 | ✅ 必发 | 静默 |

每家 plugin 留 `notification.outpost.io/main-only: "true|false"` annotation 开关,允许覆盖。

---

## 五、Pipeline 改造

### 5.1 `core/k8s/05-tekton/pipeline-build.yaml` diff(示意)

```yaml
spec:
  tasks:
    - name: fetch-source        # 原有
    - name: build-and-push      # 原有
    - name: run-tests           # 新增 ⬇
      runAfter: [build-and-push]
      timeout: "20m"
      when:                     # 仓库根有 outpost.test.yaml 或 Dockerfile.test 才跑
        - input: "$(tasks.fetch-source.results.has-tests)"
          operator: in
          values: ["true"]
      taskRef:
        name: outpost-run-tests   # 由 test-runner plugin 提供
      params:
        - name: app-name
          value: $(params.repo-name)
    - name: update-manifest     # 原有,但 runAfter 改成 [run-tests]
      runAfter: [run-tests]

  finally:                       # 新增 ⬇
    - name: notify-on-failure
      when:
        - input: "$(tasks.status)"
          operator: in
          values: ["Failed"]
      taskRef:
        name: outpost-notify     # 由 notification plugin 共同贡献
      params:
        - name: payload
          value: |
            {"event":"tekton.pipelinerun.failed", "level":"error",
             "app":"$(params.repo-name)", "commit":"$(params.image-tag)",
             "ref":"$(params.branch)", ...}
```

### 5.2 `fetch-source` 加输出

让 `git-clone` 之后再加一个小 step,检测仓库根有没有 `outpost.test.yaml` / `Dockerfile.test`,把结果写到 task result `has-tests`。Pipeline 用这个 result 决定是否跑 Gate A。

---

## 六、分期交付计划

### Phase 1(MVP,本次实施)— 估时 ~5h CC / ~3 周人工

- [ ] `plugins/notification/{dingtalk,feishu,wecom,webhook-generic}/` 四件套
- [ ] `plugins/test-runner/testkube/` + `plugins/test-runner/catalog-tasks/`
- [ ] `plugins/rollout/argo-rollouts/`
- [ ] `core/k8s/05-tekton/pipeline-build.yaml` 加 `run-tests` + `finally`
- [ ] `core/k8s/06-argocd/notifications-cm.template.yaml` 加 plugin 适配片段
- [ ] `bootstrap.sh` 新增 Phase J:apply notification + test-runner + rollout plugins
- [ ] `examples/hello-world-*/` 6 个语种各加 `outpost.test.yaml` + `tests/` 目录(冒烟)
- [ ] `i18n/{en,zh-CN}/docs/00-quickstart.md` 加 "Phase J:配置通知和自动回滚"
- [ ] `INFRA.md` 重新生成
- [ ] bats 测试:plugin manifest 渲染 + preflight 不变量 + payload schema 校验

### Phase 2(硬化)— 后续

- 告警去重 / 降噪(同一应用 5 分钟内同种失败合并)
- 升级链(error 级失败连续 N 次 → 升级到电话/PagerDuty)
- Rollouts AnalysisTemplate 接入 Prometheus(需要 Prometheus plugin)
- 测试报告归档(Testkube 自带 Allure / JUnit XML 输出 → 上传 S3/MinIO)
- Pull Request 预览环境(PR 触发 Tekton + 临时 namespace)

### Phase 3(可选)

- 测试结果可视化大盘(Testkube Dashboard + Grafana)
- 多集群部署(staging/prod 分集群,Rollouts 跨集群分析)
- ChatOps(从钉钉/飞书机器人触发 rollback / pause)

---

## 七、风险与待评估

| 风险 | 影响 | 缓解 |
|---|---|---|
| Testkube 资源开销 | 每个 TestWorkflow 启 1+ pod,小集群有压力 | 加 ResourceQuota,默认 limits 严格;本地 k3d 场景下出 README 提示按需关 |
| Argo Rollouts 强制 Deployment → Rollout CRD | 现有应用要改 manifest | examples 里先示范一例;hello-world 全部用 Rollout(同时验证回滚)。但**应用层是否换 Rollout 由用户决定**,plugin 装上不强制 |
| 通知风暴 | 一次大故障可能秒发 100 条 | Phase 2 加去重;MVP 先靠 main-only 开关 |
| Webhook URL 泄漏 | 钉钉/飞书 webhook 谁拿到都能发消息 | 必须走 SealedSecret;`.env` 里的明文走 sealed-secrets 落集群 |
| 测试不稳定 → 误回滚 | 网络抖一下回滚一次,反复抖 | AnalysisTemplate 默认 `consecutiveErrorLimit=3`,`failureLimit=2` |
| 多 plugin 并存 fan-out 复杂度 | 4 通道全开 = 一次故障 4 条消息 | 设计上**就是要 fan-out**,这是预期行为;留 plugin 级别 `enabled: false` 开关临时关单家 |

---

## 八、文件级变更清单

```
新增:
  docs/proposals/cicd-test-gate.md                          ← 本文件
  plugins/notification/dingtalk/{manifest.yaml,secret.template.yaml,configmap.yaml,argocd-binding.yaml,preflight.sh,README.md}
  plugins/notification/feishu/...                            (同上结构)
  plugins/notification/wecom/...                             (同上结构)
  plugins/notification/webhook-generic/...                   (同上结构)
  plugins/test-runner/testkube/{manifest.yaml,webhook-on-failure.yaml,preflight.sh,README.md}
  plugins/test-runner/catalog-tasks/{manifest.yaml,README.md}
  plugins/rollout/argo-rollouts/{manifest.yaml,analysistemplate-default.yaml,analysistemplate-smoke.yaml,ingressroute.yaml,README.md}
  core/k8s/05-tekton/notify-task.yaml                       ← 共享 task,被 Pipeline finally 引用
  core/k8s/05-tekton/run-tests-task.yaml                    ← 共享 task,被 Pipeline 引用
  core/k8s/06-argocd/notifications-cm.template.yaml         ← argocd-notifications-cm 主模板
  examples/hello-world-{react,vue,csharp,python,java,go}/outpost.test.yaml
  examples/hello-world-{react,vue,csharp,python,java,go}/tests/...
  tests/bats/notification-plugins.bats
  tests/bats/test-runner-plugins.bats
  tests/bats/rollout-plugin.bats

修改:
  core/k8s/05-tekton/pipeline-build.yaml                    ← 加 run-tests + finally
  bootstrap.sh                                               ← 加 Phase J,apply 通知/测试/回滚 plugins
  .env.example                                               ← 加 NOTIFICATION_PROVIDERS / *_WEBHOOK_URL / TEST_RUNNER / ROLLOUTS_DASHBOARD_HOST
  i18n/en/docs/00-quickstart.md                              ← 加 Phase J 章节
  i18n/zh-CN/docs/00-quickstart.md                          ← 加 Phase J 章节
  INFRA.md                                                   ← 重新生成
  README.md                                                  ← Plugin matrix 加新家族
```

---

## 九、验收标准

MVP 完成的可见信号:

1. `bootstrap.sh` 跑完后,`kubectl get pods -n testkube && kubectl get pods -n argo-rollouts` 都 Ready。
2. `argocd-server` 命名空间里 `argocd-notifications-controller` 起来。
3. 改 `examples/hello-world-go/main.go` 故意写错 → push → Tekton 在 `run-tests` 步骤红 → 钉钉收到失败消息 → manifest 仓库未变 → 集群应用未受影响。
4. 改 `examples/hello-world-go/main.go` 让健康检查永远返回 500 → push → Tekton 通过 → ArgoCD sync → Rollouts canary 第一档分析失败 → **自动回滚** → 钉钉收到回滚消息 → `kubectl argo rollouts get rollout hello-world-go` 显示已回到上一版。
5. 装两家通知 plugin(钉钉 + 飞书)→ 同一次失败两边都收到。

---

## 十、已锁定的决策(2026-05-10 用户确认)

| # | 决策点 | 选择 |
|---|---|---|
| 1 | Testkube 部署模式 | **OSS 自托管**;plugin 留 `TESTKUBE_MODE=oss\|cloud` 开关,默认 `oss` |
| 2 | `outpost.test.yaml` schema | 起 `version: 1`,留向后兼容空间 |
| 3 | AnalysisTemplate 默认阈值 | `successCondition: result == "Passed"` / `failureLimit: 2` / `consecutiveErrorLimit: 3` |
| 4 | 钉钉签名 | 支持加签 webhook;`DINGTALK_SIGN_SECRET` 可选,为空走裸 webhook |
| 5 | 提案归档位置 | 走 i18n:`i18n/en/docs/proposals/cicd-test-gate.md` + `i18n/zh-CN/docs/proposals/cicd-test-gate.md` 双语版本 |

---

## 参考资料

- Testkube 官方 Tekton 集成: https://docs.testkube.io/articles/tekton
- Testkube Argo Workflows 集成: https://docs.testkube.io/articles/argoworkflows-integration
- Testkube ArgoCD 集成: https://docs.testkube.io/articles/argocd-integration
- Argo Rollouts AnalysisTemplate: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo Rollouts Best Practices: https://argo-rollouts.readthedocs.io/en/stable/best-practices/
- ArgoCD Notifications(已合主仓): https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/
- Testkube vs Argo Workflows 官方对比: https://testkube.io/vs/argo-workflows
