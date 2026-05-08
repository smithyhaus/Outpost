# Examples

Two flavors live here:

- **`demo-app/`** — manifest-only template. Use as a starting point when
  you write the K8s YAML for a brand-new application. Drop the YAMLs
  into your manifest repo, point to your application image, done.

- **`hello-world/<lang>/`** — minimum-viable application repos in 6
  popular languages (React / Vue / C# / Python / Java / Go). Use these
  to **smoke-test the full-mode CI/CD pipeline end-to-end**: push to
  Gitee/GitHub/GitLab as a new repo, copy the bundled manifests into
  your manifest repo, configure the webhook, push a commit. If
  `https://hello-<lang>.apps.<root>` returns "Hello from <Lang>" within
  ~2 minutes, the entire pipeline (Tekton clone → kaniko build → push
  to registry → update manifest → ArgoCD sync → Traefik route) is
  working.

See `hello-world/README.md` for the smoke-test walkthrough.
