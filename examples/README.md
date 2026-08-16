# Examples

Two flavors live here:

- **`demo-app/`** — manifest-only template. Use as a starting point when
  you write the K8s YAML for a brand-new application. Drop the YAMLs
  into your manifest repo, point to your application image, done.

- **`hello-world/<lang>/`** — minimum-viable application repos in 6
  popular languages (React / Vue / C# / Python / Java / Go). Use these
  to **smoke-test the full-mode CI/CD pipeline end-to-end**:
  `outpost onboard <this-repo-url>` (registers it in `OUTPOST_REPOS` and
  copies `templates/github/outpost-build.yml` into
  `.github/workflows/`), set up dual-push (or a gitee→github push-mirror),
  copy the bundled manifests into your manifest repo, push a commit. If
  `https://hello-<lang>-apps.<root>` returns "Hello from <Lang>" within
  a few minutes, the entire pipeline (GitHub Actions runner build →
  push to registry → update manifest → manifest-sync apply → Traefik
  route) is working. No webhook to configure anywhere.

See `hello-world/README.md` for the smoke-test walkthrough.
