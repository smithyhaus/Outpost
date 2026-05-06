# Tests

Three layers of automated validation:

```
tests/
├── lint.sh                  shellcheck + yamllint + docker compose config + i18n parity
├── bats/                    bats-core unit tests for shell utilities & contracts
├── regression/              load-bearing equivalence tests
│   └── golden/              snapshots that must not drift
└── schema/                  JSON schema lock (AI contract)
    └── verify-output.schema.json
```

## Running locally

```bash
# Static analysis
bash tests/lint.sh

# bats-core (install: brew install bats-core / npm i -g bats)
bats tests/bats/
bats tests/regression/

# All at once (mirrors CI)
bash tests/lint.sh && bats tests/bats/ tests/regression/
```

## What each layer guards

| Layer        | Guards against                                           |
|--------------|----------------------------------------------------------|
| lint         | bad bash, malformed YAML, broken Compose, i18n drift     |
| unit (bats)  | regressions in `platform/lib/portable.sh` helpers, plugin contract violations, JSON schema drift in `verify.sh` |
| regression   | the default `registry/self-hosted` plugin produces the same Kubernetes objects as the pre-plugin layout (mandated by the eng review) |
| schema       | `verify.sh --json` shape — the AI integration contract   |

## Updating the regression golden

Drift in `tests/regression/golden/` is a **fail by design**. If the change
is intentional:

1. Read the diff carefully.
2. Confirm with a maintainer that the change does not break existing
   self-hosted-registry installations.
3. Re-render and lock:
   ```bash
   ROOT_DOMAIN=example.test envsubst \
     < plugins/registry/self-hosted/manifest.yaml \
     > tests/regression/golden/registry-self-hosted.yaml
   ```
4. Commit with a message explaining the reason.

## CI

`.github/workflows/lint.yml` runs lint on every push.
`.github/workflows/test-matrix.yml` runs the bats + regression suites on
`ubuntu-latest` and `macos-latest`.
WSL2 is verified manually before each release (see `TODOS.md`).
