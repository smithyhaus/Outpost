# CI/CD Test Gate + Automated Rollback + Multi-Channel Notifications

> **Status:** **Approved** (2026-05-10) — Phase 1 MVP in flight
> **Authors:** Outpost Eng
> **Created:** 2026-05-10
> **Related:** `plugins/git-provider/`, `plugins/registry/`, `core/k8s/05-tekton/`, `core/k8s/06-argocd/`

---

## TL;DR

Bolt three things onto the existing `Tekton (CI) → ArgoCD (CD)` pipeline:

1. **Test gates** — pre-deploy (Gate A) and post-deploy (Gate B)
2. **Automated rollback** — analysis fails → traffic is pulled back to the previous stable version
3. **Multi-channel notifications** — DingTalk / Feishu / WeCom / generic webhook, all plugin-driven

We don't reinvent any wheels. Everything below is **pieced together from upstream-standard tools**:

| Capability | Choice | Why |
|---|---|---|
| Test orchestration | **Testkube** | K8s-native CRDs, 30+ test engines, official Tekton integration, `end-test-failed` webhook out of the box |
| Progressive delivery + auto-rollback | **Argo Rollouts** | Same family as ArgoCD; AnalysisTemplate ships Web/Job/Prometheus providers; sub-second auto-rollback |
| Notification backend | **ArgoCD Notifications** (controller, in-tree since 2.3) + Tekton `finally` task | DingTalk/Feishu/WeCom/Slack/Email/webhook adapters all already exist; one Tekton task glues all three sources |
| Channel selection | Existing `plugins/` model. Add three new families: `notification/`, `test-runner/`, `rollout/` | Installing a channel = applying a plugin. Bootstrap re-reads `.env` and applies what is enabled |

Six new plugins total:
```
plugins/
├── notification/{dingtalk,feishu,wecom,webhook-generic}/   ← 4
├── test-runner/{testkube,catalog-tasks}/                   ← 2
└── rollout/argo-rollouts/                                   ← 1 (MVP-required)
```

---

## 1. Final Architecture

```
                        push                          finally task
  Developer ────────► Tekton Pipeline ─────────────────────────────► notification plugin
                          │                                          (DingTalk / Feishu / WeCom / webhook)
                          │ build & push image
                          │
                          ▼
                  ┌───────────────┐ Gate A
                  │  run-tests    │ ──── fail ──► abort, manifest never updated, notify
                  │  (Testkube)   │
                  └───────────────┘
                          │ ✓
                          ▼
                  update-manifest (image tag → manifest repo)
                          │
                          ▼
                  ArgoCD detects change → kubectl apply
                          │
                          ▼
                  ┌───────────────┐ Gate B
                  │ Argo Rollouts │  Canary 10% / 25% / 50% / 100%
                  │  Analysis     │     ↳ Each step runs an AnalysisTemplate
                  └───────────────┘     ↳ providers: Web (HTTP probe)
                          │              + Job (run a Testkube TestWorkflow)
                          │
                ┌─────────┴─────────┐
                │                   │
              pass ✓             fail ✗
                │                   │
                ▼                   ▼
          next canary step     Rollouts auto-rollback to last stable
                               argocd-notifications → notification plugin
                               (same webhook abstraction)
```

**Key insights:**
- **Tests are defined exactly once** (a Testkube `TestWorkflow` CRD). Gate A and Gate B share the same definition.
- **The notification payload is designed exactly once** (schema below). Tekton `finally`, ArgoCD notifications, and Testkube failure callbacks all emit the same shape.
- **Plugin enablement is `.env` only.** Re-run bootstrap to apply.

---

## 2. Component Selection — Candidate Comparison

### 2.1 Test orchestration: why Testkube

| Candidate | License | Tekton integration | Multi-language / framework | K8s-native CRD | Failure webhook | Verdict |
|---|---|---|---|---|---|---|
| **Testkube** | Apache 2.0 | ✅ Official `kubeshop/testkube-cli` Task | ✅ 30+: Cypress / Playwright / Postman / k6 / JMeter / Pytest / Jest / JUnit / Ginkgo / Maven / Gradle / `dotnet test` / etc. | ✅ `TestWorkflow`, `TestTrigger` | ✅ `end-test-failed` event, native | **Pick** |
| Tekton Catalog tasks (per language) | Apache 2.0 | Native | Each maintained separately | No | Need a custom finally task to glue | Too fragmented; cross-language contract not consistent |
| Argo Workflows + custom | Apache 2.0 | Through EventListener | Roll-your-own | Decent | Roll-your-own | Overlaps with Tekton; not test-shaped |
| Sonobuoy | Apache 2.0 | Weak | ❌ Cluster conformance, not app testing | ✅ | Weak | **Not applicable** |

**Conclusion — Testkube** is the de-facto K8s-native test orchestrator (`kubeshop/testkube`, Apache 2.0, actively maintained through 2026). It has official Tekton integration docs, and modeling tests as CRDs aligns perfectly with our GitOps philosophy.

**Key Testkube CRDs (2026 line):**
- `TestWorkflow` — replaces older `Test` / `TestSuite`. DAG of test steps, parallelism, dependent sidecars (database, redis, etc.).
- `TestTrigger` — declarative "cluster event → run test" (optional, used for post-deploy auto-trigger).

**How we call it:** A simple Tekton task that runs `testkube run testworkflow <name> --watch`. `--watch` blocks until the test finishes; non-zero exit fails the pipeline naturally.

### 2.2 Progressive delivery + auto-rollback: why Argo Rollouts

| Candidate | License | ArgoCD pairing | Provider variety | Auto-rollback | Traffic shifting | Verdict |
|---|---|---|---|---|---|---|
| **Argo Rollouts** | Apache 2.0 | ✅ Same `argoproj` family | Prometheus / Web / **Kubernetes Job** / Datadog / NewRelic / InfluxDB / Wavefront | ✅ Default behavior | Service mesh / Ingress / SMI all supported | **Pick** |
| Flagger | Apache 2.0 | Weak | Prometheus / Datadog | ✅ | Istio / Linkerd / NGINX / Traefik | Decent with Traefik but weak ArgoCD coupling |
| DIY (kubectl rollback + probes) | — | — | — | Semi-automatic | — | Not recommended |

**Conclusion — Argo Rollouts.** The **Job provider** in AnalysisTemplate is the lever — it lets us run a Testkube TestWorkflow as the analysis step, so **the test definition and the rollback gate share one truth source**.

**Key idea:**
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
          spec:                                    # plain Job spec
            template:
              spec:
                containers:
                  - name: smoke
                    image: kubeshop/testkube-cli
                    args: ["run", "testworkflow", "{{args.app}}-smoke", "--watch"]
```

Job exits 0 → analysis passes, traffic continues to shift. Non-zero exit → auto-rollback + notify.

### 2.3 Multi-channel notifications: ArgoCD Notifications + Tekton finally

| Source | Tool | Built-in channels |
|---|---|---|
| **ArgoCD sync state** | argocd-notifications controller (in-tree since 2.3) | Slack / Email / Webhook / Telegram / Teams / Pushover / generic GraphQL / DingTalk / Feishu / WeCom (community templates) |
| **Tekton pipeline failure** | `finally` task + curl/HTTP | Any webhook |
| **Testkube test failure** | Testkube webhook (`end-test-failed`) | Any webhook |
| **Argo Rollouts rollback** | Rollouts events → argocd-notifications | Same as ArgoCD |

**Unified pattern:** **Every failure signal ends up as "webhook + template."** Each notification plugin contributes only two things in `manifest.yaml`:
1. SealedSecret (webhook URL + optional signing secret)
2. ConfigMap (message template that renders the unified payload into the vendor's format)

ArgoCD plugs in via `argocd-notifications-cm`; Tekton/Testkube use a shared `notify-task` that reads the same ConfigMap. **Plugins ship no code, only declarative config.**

---

## 3. Plugin Family Design

### 3.1 `plugins/notification/<provider>/`

Layout (DingTalk shown):
```
plugins/notification/dingtalk/
├── manifest.yaml         # Main manifest, kustomize entry
├── secret.template.yaml  # SealedSecret (webhook URL + sign key)
├── configmap.yaml        # Message template (DingTalk markdown shape)
├── argocd-binding.yaml   # Snippet merged into argocd-notifications-cm (triggers + templates)
├── preflight.sh          # Verifies DINGTALK_WEBHOOK_URL / DINGTALK_SIGN_SECRET in .env
└── README.md
```

New `.env` variables (each plugin owns its own):
```
# Comma-separated list of enabled notification plugins
NOTIFICATION_PROVIDERS=dingtalk,feishu

# DingTalk
DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=...
DINGTALK_SIGN_SECRET=SEC...

# Feishu
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...

# WeCom
WECOM_WEBHOOK_URL=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...

# Generic webhook (when you have your own receiver)
GENERIC_WEBHOOK_URL=https://your-collector.example.com/hook
```

Bootstrap selectively applies based on `NOTIFICATION_PROVIDERS`.

### 3.2 `plugins/test-runner/<runner>/`

```
plugins/test-runner/
├── testkube/                      # Recommended path
│   ├── manifest.yaml              # Testkube Helm values + namespace
│   ├── webhook-on-failure.yaml    # Testkube Webhook CRD: failure → notify
│   ├── preflight.sh
│   └── README.md
└── catalog-tasks/                 # Lightweight path (skip Testkube)
    ├── manifest.yaml              # Pulls in golang-test/pytest/jest/junit/dotnet-test from Tekton Catalog
    └── README.md
```

`.env`:
```
TEST_RUNNER=testkube         # or catalog-tasks or none
TESTKUBE_MODE=oss            # or cloud (requires API key, opt-in)
```

### 3.3 `plugins/rollout/argo-rollouts/`

```
plugins/rollout/argo-rollouts/
├── manifest.yaml                       # Rollouts controller + Dashboard
├── analysistemplate-default.yaml       # Default AnalysisTemplate (Web provider HTTP probe)
├── analysistemplate-smoke.yaml         # Job-provider template that calls a Testkube smoke workflow
├── ingressroute.yaml                   # Rollouts Dashboard via Traefik (rollouts.${ROOT_DOMAIN})
└── README.md
```

MVP-required. `.env`:
```
ROLLOUTS_DASHBOARD_HOST=rollouts.${ROOT_DOMAIN}
```

---

## 4. Contracts

### 4.1 Test contract (application repo side)

**Fallback priority:**

1. Repo root `outpost.test.yaml` (declarative; supports dependent sidecars):
```yaml
# my-app/outpost.test.yaml
version: 1
sidecars:                       # dependent services
  - name: postgres
    image: postgres:16-alpine
    env: { POSTGRES_PASSWORD: testpass }
runner:
  image: my-app/test:latest     # or dockerfile: ./Dockerfile.test
  command: ["pytest", "-v"]
gates:
  pre-deploy:                   # Gate A
    timeout: 10m
  post-deploy-smoke:            # Gate B (driven by Rollouts)
    enabled: true
    image: my-app/smoke:latest
    timeout: 5m
```

2. Repo root `Dockerfile.test` (simple fallback): build → kubectl run → exit code is the result.

3. Neither present → `when` clause skips (not a failure), just one fewer gate.

### 4.2 Notification payload schema (normalized)

```typescript
{
  event: "tekton.pipelinerun.failed"          // | "argocd.app.degraded"
                                               // | "argocd.app.sync_failed"
                                               // | "rollout.aborted"
                                               // | "rollout.completed"
                                               // | "testkube.test.failed",
  level: "info" | "warn" | "error",
  app:   string,                               // app name = repo-name
  env:   string,                               // dev / staging / prod
  commit: string,                              // short SHA
  ref:   string,                               // branch / tag
  url:   string,                               // jump link (Tekton Dashboard / ArgoCD UI)
  text:  string                                // one-line human summary
}
```

Each plugin keeps a Go template in its ConfigMap that renders this payload to the vendor's format. DingTalk example:
```yaml
title: "[{{.level}}] {{.app}} - {{.event}}"
markdown: |
  ### {{.app}} `{{.commit}}` failed in `{{.env}}`
  - Event: {{.event}}
  - Detail: [open]({{.url}})
  - Summary: {{.text}}
```

### 4.3 Default trigger rules

| Event | main branch | Non-main branches |
|---|---|---|
| Tekton pipeline failed | ✅ Always notify | Silent |
| Tekton pipeline succeeded | Silent | Silent |
| ArgoCD sync failed | ✅ Always notify | ✅ Always notify |
| ArgoCD app degraded | ✅ Always notify | ✅ Always notify |
| Rollouts rolled back | ✅ Always notify (error level) | ✅ Always notify |
| Rollouts completed | ✅ Always notify (info level, opt-out) | Silent |
| Testkube test failed | ✅ Always notify | Silent |

Each plugin exposes a `notification.outpost.io/main-only: "true|false"` annotation as an override.

---

## 5. Pipeline Changes

### 5.1 `core/k8s/05-tekton/pipeline-build.yaml` diff (sketch)

```yaml
spec:
  tasks:
    - name: fetch-source        # existing
    - name: build-and-push      # existing
    - name: run-tests           # NEW ⬇
      runAfter: [build-and-push]
      timeout: "20m"
      when:                     # only if outpost.test.yaml or Dockerfile.test exists
        - input: "$(tasks.fetch-source.results.has-tests)"
          operator: in
          values: ["true"]
      taskRef:
        name: outpost-run-tests   # provided by test-runner plugin
      params:
        - name: app-name
          value: $(params.repo-name)
    - name: update-manifest     # existing, but runAfter changes to [run-tests]
      runAfter: [run-tests]

  finally:                       # NEW ⬇
    - name: notify-on-failure
      when:
        - input: "$(tasks.status)"
          operator: in
          values: ["Failed"]
      taskRef:
        name: outpost-notify     # contributed jointly by notification plugins
      params:
        - name: payload
          value: |
            {"event":"tekton.pipelinerun.failed", "level":"error",
             "app":"$(params.repo-name)", "commit":"$(params.image-tag)",
             "ref":"$(params.branch)", ...}
```

### 5.2 `fetch-source` gets a new result

After `git-clone`, add a small step that checks the repo root for `outpost.test.yaml` / `Dockerfile.test` and writes the answer to a task result `has-tests`. The pipeline uses that result to decide whether Gate A runs.

---

## 6. Phased Delivery

### Phase 1 (MVP, this iteration) — ~5h CC / ~3 weeks human

- [ ] `plugins/notification/{dingtalk,feishu,wecom,webhook-generic}/` four-pack
- [ ] `plugins/test-runner/testkube/` + `plugins/test-runner/catalog-tasks/`
- [ ] `plugins/rollout/argo-rollouts/`
- [ ] `core/k8s/05-tekton/pipeline-build.yaml` adds `run-tests` + `finally`
- [ ] `core/k8s/06-argocd/notifications-cm.template.yaml` adds plugin adapter snippets
- [ ] `bootstrap.sh` adds Phase J: apply notification + test-runner + rollout plugins
- [ ] `examples/hello-world-*/` six languages each get `outpost.test.yaml` + `tests/` (smoke)
- [ ] `i18n/{en,zh-CN}/docs/00-quickstart.md` adds "Phase J: Notifications & Auto-Rollback"
- [ ] `INFRA.md` regenerated
- [ ] bats tests: plugin manifest rendering + preflight invariants + payload schema validation

### Phase 2 (Hardening) — Follow-up

- Notification dedup / suppression (collapse same-app, same-failure within 5 minutes)
- Escalation chains (N consecutive error-level failures → phone / PagerDuty)
- Rollouts AnalysisTemplate hooked to Prometheus (requires a Prometheus plugin)
- Test report archival (Testkube emits Allure / JUnit XML → upload to S3/MinIO)
- Pull request preview environments (PR triggers Tekton + ephemeral namespace)

### Phase 3 (Optional)

- Test result dashboard (Testkube Dashboard + Grafana)
- Multi-cluster (staging/prod split, cross-cluster Rollouts analysis)
- ChatOps (DingTalk/Feishu bots that trigger rollback / pause)

---

## 7. Risks and Open Concerns

| Risk | Impact | Mitigation |
|---|---|---|
| Testkube footprint | Each TestWorkflow spins ≥1 pod; small clusters feel it | ResourceQuota; tight default limits; README note for local k3d users to disable on demand |
| Argo Rollouts forces Deployment → Rollout CRD | Existing apps need manifest changes | examples lead by example; hello-world all use Rollout (also validates rollback). **Whether the user app actually switches is up to the user**; installing the plugin does not force conversion |
| Notification storms | One big incident could fire 100 messages a second | Phase 2 dedup; MVP relies on the main-only switch |
| Webhook URL leakage | Anyone with the DingTalk/Feishu URL can post | Mandatory SealedSecret; `.env` plaintext is sealed before landing in cluster |
| Flaky tests → false rollback | Network blip = rollback, repeat | AnalysisTemplate defaults `consecutiveErrorLimit=3`, `failureLimit=2` |
| Multi-plugin fan-out complexity | 4 channels enabled = 4 messages per incident | Designed-in behavior. Per-plugin `enabled: false` switch lets you mute one channel without uninstall |

---

## 8. File-Level Change List

```
NEW:
  i18n/en/docs/proposals/cicd-test-gate.md                  ← this file (English)
  i18n/zh-CN/docs/proposals/cicd-test-gate.md               ← this file (Chinese)
  plugins/notification/dingtalk/{manifest.yaml,secret.template.yaml,configmap.yaml,argocd-binding.yaml,preflight.sh,README.md}
  plugins/notification/feishu/...                            (same shape)
  plugins/notification/wecom/...                             (same shape)
  plugins/notification/webhook-generic/...                   (same shape)
  plugins/test-runner/testkube/{manifest.yaml,webhook-on-failure.yaml,preflight.sh,README.md}
  plugins/test-runner/catalog-tasks/{manifest.yaml,README.md}
  plugins/rollout/argo-rollouts/{manifest.yaml,analysistemplate-default.yaml,analysistemplate-smoke.yaml,ingressroute.yaml,README.md}
  core/k8s/05-tekton/notify-task.yaml                       ← shared task, called by Pipeline finally
  core/k8s/05-tekton/run-tests-task.yaml                    ← shared task, called by Pipeline
  core/k8s/06-argocd/notifications-cm.template.yaml         ← argocd-notifications-cm main template
  examples/hello-world-{react,vue,csharp,python,java,go}/outpost.test.yaml
  examples/hello-world-{react,vue,csharp,python,java,go}/tests/...
  tests/bats/notification-plugins.bats
  tests/bats/test-runner-plugins.bats
  tests/bats/rollout-plugin.bats

CHANGED:
  core/k8s/05-tekton/pipeline-build.yaml                    ← adds run-tests + finally
  bootstrap.sh                                               ← adds Phase J
  .env.example                                               ← adds NOTIFICATION_PROVIDERS / *_WEBHOOK_URL / TEST_RUNNER / TESTKUBE_MODE / ROLLOUTS_DASHBOARD_HOST
  i18n/en/docs/00-quickstart.md                              ← adds Phase J chapter
  i18n/zh-CN/docs/00-quickstart.md                          ← adds Phase J chapter
  INFRA.md                                                   ← regenerated
  README.md                                                  ← Plugin matrix gets new families
```

---

## 9. Acceptance Criteria

Visible signals that the MVP is done:

1. After `bootstrap.sh`, `kubectl get pods -n testkube && kubectl get pods -n argo-rollouts` are all Ready.
2. `argocd-notifications-controller` is up in `argocd-server` namespace.
3. Break `examples/hello-world-go/main.go` on purpose → push → Tekton fails at `run-tests` → DingTalk receives a failure message → manifest repo unchanged → cluster app unaffected.
4. Break `examples/hello-world-go/main.go` so its health check returns 500 → push → Tekton green → ArgoCD syncs → Rollouts canary first step's analysis fails → **auto-rollback** → DingTalk receives the rollback message → `kubectl argo rollouts get rollout hello-world-go` shows the previous revision restored.
5. Install two notification plugins (DingTalk + Feishu) → one failure delivers to both.

---

## 10. Decisions Locked (confirmed by user, 2026-05-10)

| # | Decision point | Choice |
|---|---|---|
| 1 | Testkube deployment mode | **OSS self-hosted**; plugin keeps a `TESTKUBE_MODE=oss\|cloud` switch; default `oss` |
| 2 | `outpost.test.yaml` schema | Start at `version: 1`; reserve room for backward-compatible bumps |
| 3 | AnalysisTemplate defaults | `successCondition: result == "Passed"` / `failureLimit: 2` / `consecutiveErrorLimit: 3` |
| 4 | DingTalk signing | Signed webhook supported; `DINGTALK_SIGN_SECRET` optional, empty falls back to plain webhook |
| 5 | Proposal location | i18n: `i18n/en/docs/proposals/cicd-test-gate.md` + `i18n/zh-CN/docs/proposals/cicd-test-gate.md` (bilingual) |

---

## References

- Testkube official Tekton integration: https://docs.testkube.io/articles/tekton
- Testkube Argo Workflows integration: https://docs.testkube.io/articles/argoworkflows-integration
- Testkube ArgoCD integration: https://docs.testkube.io/articles/argocd-integration
- Argo Rollouts AnalysisTemplate: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo Rollouts Best Practices: https://argo-rollouts.readthedocs.io/en/stable/best-practices/
- ArgoCD Notifications (in-tree): https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/
- Testkube vs Argo Workflows (official comparison): https://testkube.io/vs/argo-workflows
