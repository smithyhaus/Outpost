# Plan: Outpost v0.4 Phase 3 — Onboard Primitives

## Summary

Add three independently-callable, idempotent `outpost` subcommands —
`outpost db create`, `outpost seal-from-template`, `outpost manifest scaffold`
— that generalize what `SCM MCP/scripts/onboard.sh` did by hand. Each emits a
structured JSON object (`{step, status, detail, written_files[], next_action}`)
under `--json`, and human-readable lines by default. Pure logic lives in a
unit-tested lib; the subcommands are thin wrappers in `scripts/outpost`.

## User Story

As a developer (or an AI agent acting for one) onboarding a project to an
already-bootstrapped outpost, I want single-purpose commands to create the
app database, seal its secret, and scaffold its manifests — so that I never
hand-write `onboard.sh` or 21 YAML files again, and Phase 5's `outpost
onboard` has clean primitives to orchestrate.

## Problem → Solution

**Current state**: onboarding a real project means hand-writing a per-app
`onboard.sh` (建库 + sealed-secret) and ~21 manifest YAMLs. `outpost` exposes
`seal` (a `kubeseal` KEY=VALUE wrapper) and `new-app` (scaffolds app *code*
into `my-apps/`) but nothing that provisions a DB, seals from a *template*,
or scaffolds *manifests into a manifests repo*.

**Desired state**: `outpost db create <app>`, `outpost seal-from-template
<app> …`, `outpost manifest scaffold <app> …` — each idempotent, each
JSON-capable, each holding the ADR 0002 mechanism-vs-content boundary.

## Metadata

- **Complexity**: Large
- **Source PRD**: `docs/prp/prds/outpost-v0.4-real-project-onboarding.prd.md`
- **PRD Phase**: Phase 3 — Onboard primitives
- **Governing ADR**: `docs/decisions/0002-onboarding-primitives-in-platform.md`
- **Estimated Files**: 6 (2 created libs/schema + 1 created lib + 3 test files; `scripts/outpost` updated)
- **Depends on**: Phase 1 + Phase 2 (shipped). Phase 4 runs in parallel; this plan does not touch webhook code.

---

## UX Design

### Before

```
$ # onboard a new app — no outpost support
$ vim scripts/onboard.sh        # hand-write 95 lines: createdb + kubeseal + yaml
$ vim apps/myapp/deployment.yaml      # hand-write
$ vim apps/myapp/service.yaml         # hand-write
$ ... 19 more files ...
$ ./scripts/onboard.sh          # bespoke, per-project, untested
```

### After

```
$ outpost db create myapp
[ OK ] database "myapp" created
       ↳ next: reference it in your secret template, then seal it

$ outpost seal-from-template myapp \
    --template ./secret.template.yaml --output ./manifests/apps/myapp/sealed-secret.yaml
[ OK ] sealed → ./manifests/apps/myapp/sealed-secret.yaml
       ↳ next: commit the SealedSecret to the manifests repo

$ outpost manifest scaffold myapp --lang go --manifests-dir ./manifests
[ OK ] scaffolded 5 files under ./manifests
       ↳ next: review the files, then commit them

$ outpost db create myapp --json
{"step":"db.create","status":"exists","detail":"database \"myapp\" already present","written_files":[],"next_action":"reference it in your secret template, then seal it"}
```

### Interaction Changes

| Touchpoint | Before | After | Notes |
|---|---|---|---|
| Provision DB | `docker exec postgres psql … CREATE DATABASE` by hand | `outpost db create <app>` | Idempotent; JSON-capable |
| Seal a secret | `kubeseal` invocation memorized per app, or `outpost seal KEY=VAL` | `outpost seal-from-template <app> --template … --output …` | App owns the template (ADR 0002) |
| Scaffold manifests | hand-write 5 YAML per app | `outpost manifest scaffold <app> --lang … --manifests-dir …` | Generic skeleton; app values are parameters |
| AI-agent consumption | none | `--json` on all three | Feeds Phase 5 / Phase 6 |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `scripts/outpost` | 1-72, 197-281, 318-335 | CLI skeleton: helpers (`_die`/`_need`/`_confirm`), `usage()`, `cmd_seal` + `cmd_new_app` (closest analogs), the router `case` |
| P0 | `doctor.sh` | 30-110, 242-270 | `--json` arg parse, `json_esc()`, the `[[ MODE == json ]]` printf branch, exit-code convention 0/1/2 |
| P0 | `platform/lib/portable.sh` | 112-171 | `render_template <src> <dst>` — envsubst + strict `${VAR}` residue check; the exact mechanism `seal-from-template` needs |
| P0 | `platform/lib/doctor-checks.sh` | all (1-58) | The "pure helpers in a lib, sourced by the orchestrator, unit-tested separately" pattern to mirror for `onboard-lib.sh` |
| P0 | `docs/decisions/0002-onboarding-primitives-in-platform.md` | all | The mechanism-vs-content boundary every primitive must hold |
| P1 | `scripts/update-manifest.sh` | 44-52, 78-97, 175-179 | Required-input validation (`: "${VAR:?}"`), image-ref parsing, the `git diff --quiet` idempotency-skip idiom |
| P1 | `examples/hello-world/go/manifest/` | deployment.yaml, service.yaml, ingress.yaml, kustomization.yaml | The manifest shapes `scaffold` instantiates; note hardcoded `hello-go` / `registry.example.com` / `…apps.example.com` are the substitution points |
| P1 | `examples/demo-app/argocd-application.yaml` | all | Template for the generated `argocd-apps/<app>.yaml`; substitution points: `name`, `repoURL`, `targetRevision`, `path` |
| P1 | `examples/demo-app/secret.example.yaml` | all | Existing plaintext-Secret shape; note it uses `<REPLACE_*>` placeholders — see GOTCHA on `${VAR}` vs `<REPLACE_*>` |
| P1 | `tests/bats/update-manifest.bats` | 1-45 | bats harness pattern: `mktemp -d`, seed, `skip` when a tool is absent |
| P1 | `tests/bats/doctor-checks.bats` | all (1-53) | Unit-test pattern for a pure lib: `source` the lib in `setup()`, exercise each function |
| P2 | `tests/schema/doctor-output.schema.json` | all | Schema style to mirror for `onboard-output.schema.json` |
| P2 | `core/compose/docker-compose.yml` | 72-93 | The `postgres` container (name `postgres`, env `POSTGRES_USER/PASSWORD/DB`) `db create` talks to |
| P2 | `tests/bats/outpost-cli.bats` | 18-25 | The `help` assertion loop that must learn the new subcommands |

## External Documentation

No external research needed — feature uses only established internal
patterns (`render_template`, `kubeseal`, `psql` via `docker exec`, bats).
Tool behaviour relied on: `kubeseal --controller-namespace=kube-system
--format=yaml` (already used by `cmd_seal`, `scripts/outpost:236`);
`psql -tAc` for scriptable single-value queries.

---

## Patterns to Mirror

### CLI_SUBCOMMAND + ROUTER
```bash
# SOURCE: scripts/outpost:86-88, 321-333
cmd_doctor() {
  exec bash "$OUTPOST_HOME/doctor.sh" "$@"
}
# ...
case "$SUB" in
  status)         cmd_status "$@" ;;
  doctor)         cmd_doctor "$@" ;;
  *) echo "$(_red unknown): $SUB"; usage; exit 1 ;;
esac
```
New: `cmd_db` / `cmd_seal_from_template` / `cmd_manifest`, plus router lines
`db) cmd_db "$@" ;;`, `seal-from-template) cmd_seal_from_template "$@" ;;`,
`manifest) cmd_manifest "$@" ;;`.

### NESTED DISPATCH (new — model on the flat `case` already in the file)
```bash
# SOURCE: scripts/outpost:127-141 (cmd_open's `case "$target"`)
case "$target" in
  argocd)   ... ;;
  *) _die "unknown target: $target (try: argocd|tekton|...)" ;;
esac
```
`cmd_db` dispatches its first arg the same way: `case "${1:-}" in create) … ;;
*) _die "outpost db <create>" ;; esac`.

### ERROR_HANDLING
```bash
# SOURCE: scripts/outpost:28-29
_die()  { echo "$(_red ERROR): $*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "missing tool: $1"; }
# SOURCE: scripts/update-manifest.sh:47-52  (required-input guard)
: "${MANIFEST_REPO_URL:?env MANIFEST_REPO_URL is required}"
```

### ENVSUBST + STRICT RESIDUE CHECK
```bash
# SOURCE: platform/lib/portable.sh:130-171
render_template() {            # render_template <src> <dst>
  # ... checks every ${VAR} in <src> is exported; returns 1 + err() on miss
  envsubst < "$src" > "$dst"
}
```
`seal-from-template` calls `render_template "$template" "$tmp"` — a non-zero
return is a hard error (unresolved `${VAR}`), not a silent empty seal.

### JSON EMIT + ESCAPING
```bash
# SOURCE: doctor.sh:243-245, 257-258
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '; }
printf '{"status":"%s","id":"%s",...}' "$status" "$(json_esc "$id")" ...
```

### IDEMPOTENCY SKIP
```bash
# SOURCE: scripts/update-manifest.sh:175-179
if git diff --quiet -- "$TARGET"; then
  echo "No changes in $TARGET. Skipping commit."; exit 0
fi
```
`manifest scaffold` mirrors the *intent*: compare intended output to an
existing file with `cmp -s`; identical → `unchanged`, different → `drift`.

### TEST_STRUCTURE — pure lib unit test
```bash
# SOURCE: tests/bats/doctor-checks.bats:7-15
setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "${INFRA_ROOT}/platform/lib/doctor-checks.sh"
}
@test "doctor_port_state: a free high port reports free" {
  [ "$(doctor_port_state 49231)" = "free" ]
}
```

### TEST_STRUCTURE — e2e with tmp dir + tool skip
```bash
# SOURCE: tests/bats/update-manifest.bats:9-20
setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  command -v git >/dev/null 2>&1 || skip "git not available"
  TMP="$(mktemp -d)"
}
```

### PORTABLE SED (in-place)
```bash
# SOURCE: scripts/outpost:265-270
portable_sed_i="-i"; [[ "$(uname -s)" == "Darwin" ]] && portable_sed_i="-i ''"
sed $portable_sed_i -e "s|hello-${lang}|${name}|g" "$f"
```
Prefer building output with a render step over in-place `sed` where possible;
this idiom is the fallback if in-place editing is unavoidable.

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `platform/lib/onboard-lib.sh` | CREATE | Pure helpers: JSON emit, DB-name sanitize, idempotency compares, manifest substitution. Source-only, unit-tested (mirrors `doctor-checks.sh`). |
| `scripts/outpost` | UPDATE | Source `portable.sh` + `onboard-lib.sh`; add `cmd_db`, `cmd_seal_from_template`, `cmd_manifest`; 3 router lines; 3 `usage()` entries. |
| `tests/schema/onboard-output.schema.json` | CREATE | Locks the `--json` object shape (the AI contract). |
| `tests/bats/onboard-lib.bats` | CREATE | Unit tests for every pure function in `onboard-lib.sh`. |
| `tests/bats/onboard-primitives.bats` | CREATE | E2e tests: arg validation, `manifest scaffold` file output + idempotency, `--json` schema shape; `skip` the docker/kubeseal-dependent paths when absent. |
| `tests/bats/outpost-cli.bats` | UPDATE | Add `db`, `seal-from-template`, `manifest` to the `help` assertion loop. |

## NOT Building

- **`outpost onboard` orchestration** — that is Phase 5. Phase 3 ships only
  the independently-callable primitives.
- **Webhook registration** — Phase 4 (parallel).
- **`outpost.app.yaml` schema / parser** — a PRD "Could"; `manifest scaffold`
  takes CLI flags this phase. If `outpost.app.yaml` lands later, scaffold can
  read it then.
- **`core/templates/app-skeleton/` tree** — deliberately NOT created.
  `manifest scaffold` reuses `examples/hello-world/<lang>/manifest/` +
  `examples/demo-app/argocd-application.yaml` as its template source (DRY;
  avoids a second copy of the manifest shapes). See Risks R5.
- **Dockerfile scaffolding / `--legacy`** — Phase 5.
- **`~/.outpost/state/` state files** — Phase 5 owns cross-step state; Phase 3
  primitives are stateless (idempotency is derived from live system state:
  `pg_database`, files on disk).
- **Docs (`05-onboard-project.md` etc.)** — Phase 9 doc-sync.
- **Modifying or deprecating `outpost seal`** — the existing `seal` stays;
  `seal-from-template` is additive (template-input mode).

---

## Step-by-Step Tasks

### Task 1: Create `platform/lib/onboard-lib.sh` — pure helpers
- **ACTION**: New source-only lib, header in the `doctor-checks.sh` style
  ("Source-only — never executed", note unit-tested by `onboard-lib.bats`).
- **IMPLEMENT**:
  - `onboard_db_name <app>` — echo a Postgres-safe DB name: lowercase, map any
    char outside `[a-z0-9_]` to `_` (`tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_'`).
    If the result starts with a digit, prefix `app_`.
  - `onboard_json_esc <str>` — copy of doctor.sh's `json_esc` (`sed` escape `\`
    and `"`, `tr` newlines/tabs to spaces).
  - `onboard_emit_json <step> <status> <detail> <next_action> <file...>` —
    print one JSON object `{"step","status","detail","written_files":[…],
    "next_action"}`; `written_files` built from the remaining args; every
    string value passed through `onboard_json_esc`.
  - `onboard_files_identical <path-a> <path-b>` — `cmp -s "$a" "$b"` wrapper;
    return 0 if identical (used for the `unchanged` vs `drift` decision).
  - `onboard_render_subst <src> <dst> <SED_EXPR...>` — read `<src>`, apply the
    given `sed` expressions, write `<dst>`; pure string substitution for the
    manifest scaffold (no envsubst — manifests are not env-templated).
- **MIRROR**: `platform/lib/doctor-checks.sh` (whole file) for shape; the
  `tr -c` sanitisation idiom from `doctor.sh:231` (Phase 2 fix).
- **IMPORTS**: none — pure bash, bash-3.2-safe (no associative arrays).
- **GOTCHA**: `onboard_emit_json`'s variadic `<file...>` must tolerate zero
  files (`db create` writes none). Under `set -u`, guard the loop:
  `local files=("${@:5}"); [[ ${#files[@]} -gt 0 ]] && for f in …`.
- **VALIDATE**: `bash -n platform/lib/onboard-lib.sh`; covered by Task 8.

### Task 2: Wire libs into `scripts/outpost`
- **ACTION**: After the `.env` load block (`scripts/outpost:17-21`), source
  `portable.sh` then `onboard-lib.sh`.
- **IMPLEMENT**:
  ```bash
  # shellcheck source=platform/lib/portable.sh
  source "$OUTPOST_HOME/platform/lib/portable.sh"
  # shellcheck source=platform/lib/onboard-lib.sh
  source "$OUTPOST_HOME/platform/lib/onboard-lib.sh"
  ```
- **MIRROR**: `doctor.sh:35-38` (the two `source` lines with shellcheck
  directives).
- **IMPORTS**: n/a.
- **GOTCHA**: `scripts/outpost` runs under `set -euo pipefail`. `portable.sh`
  and `onboard-lib.sh` are pure definitions — sourcing is safe — but the new
  `cmd_*` functions must NOT rely on `-e` to surface failures: a failed
  `docker exec` / `kubeseal` under `-e` aborts the shell *before* the JSON is
  emitted. Every fallible external call in Tasks 3-5 must be wrapped
  `if ! cmd …; then <emit error JSON> ; exit 1; fi`.
- **VALIDATE**: `bash -n scripts/outpost`; `bash scripts/outpost help` still works.

### Task 3: `cmd_db` + `outpost db create <app> [--json]`
- **ACTION**: Add `cmd_db()` with nested dispatch on `create`.
- **IMPLEMENT**:
  - Parse: `sub="${1:-}"; shift || true`. `case "$sub" in create) … ;; *)
    _die "outpost db <create> <app> [--json]" ;; esac`.
  - In `create`: read `<app>` (required, else `_die`), parse `--json` flag.
  - `_need docker`. Compute `db="$(onboard_db_name "$app")"`.
  - Require `POSTGRES_USER` (from `.env`); default per `02-config.sh`
    (`postgres`). If `.env` absent → `_die "run bootstrap first / no .env"`.
  - Existence check (idempotent):
    `docker exec postgres psql -U "$POSTGRES_USER" -tAc \
      "SELECT 1 FROM pg_database WHERE datname='$db'"` → if output `1`,
    status `exists`; else run
    `docker exec postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE \"$db\""`,
    status `created`.
  - If the first `docker exec` fails (container down): status `error`,
    `next_action` = "start the data layer: docker compose up -d postgres".
  - Emit: human lines via `ok()`/`err()`, OR `onboard_emit_json db.create
    "$status" "$detail" "$next_action"` (no files) when `--json`.
  - Exit `0` for `created`/`exists`, `1` for `error`.
- **MIRROR**: `cmd_seal` arg handling (`scripts/outpost:197-201`); `_need`
  pattern; `docker exec … psql` from `SKILL.md:228`.
- **IMPORTS**: n/a.
- **GOTCHA**: DB name with a hyphen (`hello-go`) is an invalid bare Postgres
  identifier — `onboard_db_name` maps `-`→`_`, and the `CREATE DATABASE`
  statement still double-quotes the (now-safe) name defensively. The
  `psql -tAc` flags matter: `-t` tuples-only, `-A` unaligned — so the output
  is exactly `1` or empty, scriptable.
- **VALIDATE**: `outpost db` with no sub → non-zero + usage; `outpost db
  create` with no app → non-zero; with a running postgres, `create` twice →
  `created` then `exists` (Task 9, `skip` if no docker).

### Task 4: `cmd_seal_from_template` + `outpost seal-from-template <app> --template <p> --output <p> [--json]`
- **ACTION**: Add `cmd_seal_from_template()`.
- **IMPLEMENT**:
  - Parse `<app>` (required) then `--template`, `--output`, `--json` (mirror
    `cmd_verify`'s `while/case` arg loop, `scripts/outpost:92-97`).
  - `--template` and `--output` required → `_die` with usage if missing.
  - `_need kubeseal`; `_need envsubst` (render_template needs it).
  - `[[ -r "$template" ]]` else error.
  - `tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT` (mirror `cmd_seal:203-204`).
  - `if ! render_template "$template" "$tmp"; then` → status `error`,
    `next_action` = "set the missing ${VAR}s (render_template prints which)";
    emit + exit 1. (`render_template` already prints the unresolved vars.)
  - `mkdir -p "$(dirname "$output")"`.
  - `if ! kubeseal --controller-namespace=kube-system --format=yaml \
       < "$tmp" > "$output"; then` → status `error`, `next_action` =
    "is the sealed-secrets controller running? (kubectl -n kube-system
    get pods)"; emit + exit 1.
  - Success: status `sealed`, `written_files=("$output")`, `next_action` =
    "commit $output to the manifests repo".
- **MIRROR**: `cmd_seal` (`scripts/outpost:197-240`) — the `mktemp`+`trap`,
  the `kubeseal` invocation line `236`; `render_template` usage from
  `eventlistener-assemble.sh:62`.
- **IMPORTS**: `render_template` (from `portable.sh`, sourced in Task 2).
- **GOTCHA**: SealedSecret ciphertext is **non-deterministic** — `kubeseal`
  re-encrypts with fresh randomness each run, so `seal-from-template` is NOT
  byte-stable on rerun and `written_files` always reports the (re)written
  output. Idempotency for sealing is defined at the *plaintext* level
  (same template + same env → same decrypted Secret), not the file level.
  Status is always `sealed` on success — there is no `unchanged` for seal.
  Document this in the command's header comment.
- **GOTCHA**: the app's template uses `${VAR}` placeholders (envsubst form),
  NOT the legacy `<REPLACE_*>` style in `examples/demo-app/secret.example.yaml`.
  This is deliberate — `render_template`'s residue check only works on
  `${VAR}`. Note it; `examples/demo-app/secret.example.yaml` reconciliation
  is Phase 9 doc-sync, out of scope here.
- **VALIDATE**: missing `--template`/`--output` → non-zero; a template with an
  unset `${VAR}` → status `error` (Task 9, no kubeseal needed for that path).

### Task 5: `cmd_manifest` + `outpost manifest scaffold <app> --lang <l> --manifests-dir <d> [--json] [--force]`
- **ACTION**: Add `cmd_manifest()` with nested dispatch on `scaffold`.
- **IMPLEMENT**:
  - Dispatch `scaffold` like Task 3's `cmd_db`.
  - Parse `<app>`, `--lang`, `--manifests-dir`, `--json`, `--force`.
  - Validate `--lang` against the set of `examples/hello-world/*/` dirs
    (`go python java csharp react vue`); `_die` with the list if unknown.
  - `src="examples/hello-world/$lang/manifest"`; require
    `deployment.yaml service.yaml ingress.yaml` present in `$src` (error if a
    lang example lacks one — see Risks R2).
  - Compute substitutions: `hello-$lang`/`hello-world-$lang` → `$app`;
    `registry.example.com` → `${REGISTRY_PULL_HOST:-registry.example.com}`;
    `apps.example.com` → `apps.${ROOT_DOMAIN}`.
  - Target paths under `--manifests-dir`:
    `apps/$app/{deployment,service,ingress,kustomization}.yaml` and
    `argocd-apps/$app.yaml` — **5 files**.
  - `deployment/service/ingress`: render from `$src/*` via
    `onboard_render_subst` (the `sed` substitutions above).
  - `kustomization.yaml`: **generated** (generic — `resources:` =
    the 3 files, `images:` entry `name/newName` = the app image,
    `newTag: placeholder`). Do not copy the per-lang example's
    kustomization — generating it sidesteps the python/others gap (R2).
  - `argocd-apps/$app.yaml`: render from
    `examples/demo-app/argocd-application.yaml` — substitute `demo-app`→`$app`,
    `repoURL` → `${MANIFEST_REPO_URL}`, `targetRevision` →
    `${MANIFEST_REPO_BRANCH:-main}`, `path` → `apps/$app`.
  - **Idempotency**: for each of the 5, render into a temp file first, then:
    target absent → write it, count as written; target present and
    `onboard_files_identical` → skip, mark `unchanged`; target present and
    differs → do NOT overwrite (unless `--force`), mark `drift`.
  - Overall status: any `drift` → `drift` (exit 2); all `unchanged` →
    `unchanged` (exit 0); else `scaffolded` (exit 0).
  - `written_files` = the paths actually written; `next_action` for `drift` =
    "N files differ from the scaffold; inspect them, or re-run with --force".
- **MIRROR**: `cmd_new_app` (`scripts/outpost:242-281`) — the
  `examples/hello-world/$lang` source resolution and `sed` rename; the
  `git diff --quiet` *intent* from `update-manifest.sh:175` (here: `cmp -s`).
- **IMPORTS**: `onboard_render_subst`, `onboard_files_identical` (Task 1).
- **GOTCHA**: `manifest scaffold` must never silently overwrite a file the
  user has hand-edited — that is data loss. "Reconcile when drifted" (PRD
  success signal) is implemented as *report* drift, not *clobber* it; `--force`
  is the explicit opt-in. This is a deliberate, documented deviation from a
  literal reading of the PRD — record it in the plan's Notes and the command
  header.
- **GOTCHA**: `--manifests-dir` must exist (it is a checkout of the manifests
  repo); error clearly if absent — do NOT `mkdir` a repo root. The
  `apps/$app/` and `argocd-apps/` subdirs ARE created (`mkdir -p`).
- **VALIDATE**: unknown `--lang` → non-zero; scaffold into an empty temp dir →
  5 files written, status `scaffolded`; immediate re-run → status `unchanged`,
  0 files written; edit one file, re-run → status `drift`, exit 2 (Task 9).

### Task 6: Router + `usage()` entries
- **ACTION**: Add 3 router cases and 3 `usage()` lines.
- **IMPLEMENT**:
  - Router (`scripts/outpost:321`): `db) cmd_db "$@" ;;`,
    `seal-from-template) cmd_seal_from_template "$@" ;;`,
    `manifest) cmd_manifest "$@" ;;`.
  - `usage()` APPLICATION section: one line each, in the `cmd_seal`/`cmd_new_app`
    description style (`scripts/outpost:53-65`).
- **MIRROR**: existing router + `usage()` block exactly.
- **IMPORTS**: n/a.
- **GOTCHA**: keep the router alphabetically loose but put `seal-from-template`
  adjacent to `seal` so the relationship is visible.
- **VALIDATE**: `outpost help` lists all three; `outpost-cli.bats` (Task 10).

### Task 7: `tests/schema/onboard-output.schema.json`
- **ACTION**: New JSON Schema (draft 2020-12) locking the `--json` object.
- **IMPLEMENT**: `type: object`, `additionalProperties: false`,
  `required: [step, status, detail, written_files, next_action]`:
  - `step`: enum `["db.create","seal.from-template","manifest.scaffold"]`
  - `status`: enum `["created","exists","sealed","scaffolded","unchanged","drift","error"]`
  - `detail`: string
  - `written_files`: array of string
  - `next_action`: string
- **MIRROR**: `tests/schema/doctor-output.schema.json` (header, `$schema`,
  `$id` style).
- **IMPORTS**: n/a.
- **GOTCHA**: it is a *single object* per invocation — not the
  `{summary,checks[]}` envelope doctor/verify use. Each primitive runs once
  and emits once.
- **VALIDATE**: `python3 -c 'import json;json.load(open(...))'` or
  `jq . < schema` — valid JSON; shape exercised by Task 9.

### Task 8: `tests/bats/onboard-lib.bats` — unit tests
- **ACTION**: New bats file; `source` `onboard-lib.sh` in `setup()`.
- **IMPLEMENT** (one `@test` each):
  - `onboard_db_name`: `hello-go` → `hello_go`; `MyApp` → `myapp`;
    `9lives` → `app_9lives`; `a.b/c` → `a_b_c`.
  - `onboard_json_esc`: a string with `"` and `\` is escaped; a newline
    becomes a space.
  - `onboard_emit_json`: with 0 files → `written_files` is `[]`; with 2 files
    → both appear; output parses as JSON (`echo … | jq -e .`, `skip` if no jq).
  - `onboard_files_identical`: identical files → status 0; differing → non-0.
  - `onboard_render_subst`: a `sed` expr is applied; output written to dst.
- **MIRROR**: `tests/bats/doctor-checks.bats` structure.
- **IMPORTS**: n/a.
- **GOTCHA**: `onboard_emit_json` with `set -u` and zero files — assert this
  path explicitly (the empty-array expansion guard from Task 1).
- **VALIDATE**: `bats tests/bats/onboard-lib.bats` all green.

### Task 9: `tests/bats/onboard-primitives.bats` — e2e tests
- **ACTION**: New bats file exercising the three subcommands via the CLI.
- **IMPLEMENT**:
  - `setup()`: `INFRA_ROOT`, `CLI="$INFRA_ROOT/scripts/outpost"`, `TMP=$(mktemp -d)`.
  - Arg-validation (no external deps): `db` with no sub → non-zero;
    `db create` no app → non-zero; `seal-from-template` missing `--template`
    → non-zero; `manifest scaffold --lang bogus` → non-zero.
  - `manifest scaffold` happy path (no cluster needed): scaffold `--lang go`
    into `$TMP/manifests` (pre-`mkdir`) → 5 files exist; re-run → status
    `unchanged`; mutate one file → status `drift`, `status -eq 2`.
  - `manifest scaffold --json` → output conforms to the schema shape
    (`jq -e` checks: required keys present, `status` in enum); `skip` if no jq.
  - `seal-from-template` residue path: a template with an unset `${NOPE}` →
    status `error`, exit 1 (no `kubeseal` needed — `render_template` fails first).
  - `db create`: `skip "docker not available" ` unless `docker info` succeeds
    AND `docker exec postgres true` succeeds; when it does, `create` twice →
    `created` then `exists`.
  - `seal-from-template` full path: `skip` unless `kubeseal` present AND
    controller reachable.
- **MIRROR**: `tests/bats/update-manifest.bats` (tmp-dir + `skip`),
  `tests/bats/doctor.bats:27-45` (the `jq -e` schema-shape assertions).
- **IMPORTS**: n/a.
- **GOTCHA**: tests must be hermetic — `manifest scaffold` writes only under
  `$TMP`; never touch the real repo. `db create` test DB name must be unique
  (`outpost_bats_$$`) and the test should `DROP DATABASE` in teardown, or
  accept the `exists` branch as the idempotency proof without cleanup.
- **VALIDATE**: `bats tests/bats/onboard-primitives.bats` green (with skips on
  a machine lacking docker/kubeseal).

### Task 10: Update `tests/bats/outpost-cli.bats` help assertion
- **ACTION**: Add the 3 new subcommands to the `help` assertion loop.
- **IMPLEMENT**: `scripts/outpost-cli.bats:22` —
  `for sub in status verify doctor open logs rollback seal seal-from-template db manifest new-app decommission; do`.
- **MIRROR**: the existing loop verbatim.
- **IMPORTS**: n/a.
- **GOTCHA**: `seal` is a substring of `seal-from-template` — the `*"$sub"*`
  glob still matches both correctly; no change needed beyond adding tokens.
- **VALIDATE**: `bats tests/bats/outpost-cli.bats` green.

---

## Testing Strategy

### Unit Tests (`onboard-lib.bats`)

| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| `onboard_db_name` hyphen | `hello-go` | `hello_go` | — |
| `onboard_db_name` uppercase | `MyApp` | `myapp` | — |
| `onboard_db_name` leading digit | `9lives` | `app_9lives` | yes |
| `onboard_db_name` punctuation | `a.b/c` | `a_b_c` | yes |
| `onboard_json_esc` quotes/backslash | `a"b\c` | `a\"b\\c` | yes |
| `onboard_json_esc` newline | `a⏎b` | `a b` | yes |
| `onboard_emit_json` zero files | step+status, no files | `"written_files":[]` | yes (set -u) |
| `onboard_emit_json` two files | step+status+2 paths | both in array, valid JSON | — |
| `onboard_files_identical` same | two identical files | exit 0 | — |
| `onboard_files_identical` differ | two different files | exit non-0 | — |

### E2e Tests (`onboard-primitives.bats`)

| Test | Input | Expected | Edge Case? |
|---|---|---|---|
| `db` no sub | `outpost db` | non-zero + usage | — |
| `db create` no app | `outpost db create` | non-zero | yes |
| `seal-from-template` no `--template` | missing flag | non-zero | yes |
| `seal-from-template` residue | template with unset `${NOPE}` | status `error`, exit 1 | yes |
| `manifest scaffold` unknown lang | `--lang bogus` | non-zero + lang list | yes |
| `manifest scaffold` fresh | empty manifests dir | 5 files, status `scaffolded` | — |
| `manifest scaffold` rerun | same dir again | status `unchanged`, 0 written | yes (idempotency) |
| `manifest scaffold` drift | one file edited, rerun | status `drift`, exit 2 | yes |
| `manifest scaffold --json` | fresh scaffold | conforms to schema shape | — |
| `db create` ×2 | running postgres | `created` then `exists` | yes (`skip` w/o docker) |
| `seal-from-template` full | valid template + controller | status `sealed`, file written | `skip` w/o kubeseal |

### Edge Cases Checklist
- [x] Empty input (no app / no sub) — arg-validation tests
- [x] Invalid types (bad `--lang`, leading-digit DB name) — covered
- [x] Idempotent rerun (`exists` / `unchanged`) — covered
- [x] Drift without clobber (`drift` + exit 2) — covered
- [x] Missing external tool — `skip` (docker, kubeseal, jq)
- [x] Unresolved `${VAR}` in template — `render_template` error path
- [ ] Concurrent access — N/A (primitives are single-shot; Phase 5 owns ordering)
- [x] `set -u` empty-array expansion in `onboard_emit_json`

---

## Validation Commands

### Static Analysis
```bash
bash -n scripts/outpost platform/lib/onboard-lib.sh
bash tests/lint.sh
```
EXPECT: no syntax errors; `[ OK ] lint passed`.

### Unit + E2e Tests
```bash
bats tests/bats/onboard-lib.bats tests/bats/onboard-primitives.bats tests/bats/outpost-cli.bats
```
EXPECT: all pass (docker/kubeseal-dependent tests `skip` if absent).

### Full Test Suite
```bash
bats tests/bats/ tests/regression/
```
EXPECT: no regressions — 167 prior tests + the new onboard tests, 0 failures.

### Schema Validation
```bash
python3 -c 'import json; json.load(open("tests/schema/onboard-output.schema.json"))'
```
EXPECT: valid JSON.

### Manual Validation
- [ ] `outpost help` shows `db`, `seal-from-template`, `manifest`.
- [ ] `outpost manifest scaffold demo --lang go --manifests-dir /tmp/m` (after
  `mkdir /tmp/m`) writes 5 files; re-run prints `unchanged`.
- [ ] `outpost db create demo --json` emits a single JSON object that matches
  `onboard-output.schema.json`.
- [ ] With the data layer up: `outpost db create demo` twice → `created`,
  then `exists`.

---

## Acceptance Criteria
- [ ] All 10 tasks completed
- [ ] All validation commands pass
- [ ] Unit + e2e tests written and passing; full suite has no regressions
- [ ] No `bash -n` / lint errors
- [ ] Each subcommand: human output by default, valid JSON under `--json`
- [ ] Each subcommand idempotent (`exists` / `unchanged` on rerun; `drift`
  reported, never silently clobbered)
- [ ] Mechanism-vs-content boundary (ADR 0002) held — no app specifics
  hardcoded in outpost; verified in code review

## Completion Checklist
- [ ] Code follows the discovered CLI / lib / test patterns
- [ ] Error handling uses `_die` / explicit `if ! …` (not bare `set -e` aborts)
- [ ] JSON escaping via `onboard_json_esc` on every interpolated value
- [ ] Tests follow `doctor-checks.bats` / `update-manifest.bats` patterns
- [ ] No hardcoded values — DB user / registry host / domain from `.env`
- [ ] `core/templates/` NOT created (examples reused)
- [ ] No scope creep into Phase 4 (webhook) or Phase 5 (`onboard`/state)
- [ ] Self-contained — implementable from this plan without further searching

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **R1** SealedSecret ciphertext is non-deterministic — `seal-from-template` is not byte-stable on rerun | H (certain) | L | Define seal idempotency at the plaintext level; status always `sealed`; document in the command header + plan Notes |
| **R2** `examples/hello-world/<lang>/manifest/` is inconsistent — `python` has only deployment/service/ingress, `go` also has kustomization+rollout | M | M | `scaffold` *generates* kustomization.yaml + argocd-application.yaml; only needs deployment/service/ingress from the example, and errors clearly if one is missing. Normalising the examples is a separate cleanup |
| **R3** `scripts/outpost`'s `set -e` aborts a `cmd_*` before the error JSON is emitted | M | M | Every fallible external call wrapped `if ! …; then <emit error> ; exit 1; fi` (Task 2 GOTCHA); covered by the residue-path test |
| **R4** "Reconcile when drifted" (PRD) read literally = overwrite hand-edited files = data loss | L | H | `scaffold` *reports* drift (exit 2) and never clobbers without `--force`; documented deviation |
| **R5** PRD says `core/templates/` is "introduced by Phase 5", but `manifest scaffold` (Phase 3) needs templates | — | L | Resolved: reuse `examples/` as the template source; no `core/templates/` tree. The PRD's Phase-5 attribution was loose; noted here so Phase 5 doesn't recreate it |
| **R6** Two `seal*` commands (`seal`, `seal-from-template`) may confuse users | L | L | Keep them adjacent in `usage()` and the router; the PRD names `seal-from-template` explicitly. Folding into `seal --template` is a possible future simplification, out of scope |

## Notes

- **ADR 0002 compliance** is the load-bearing constraint. Each primitive ships
  generic *mechanism*; all app *content* enters as parameters: `db create`
  makes an empty DB (no schema/seed); `seal-from-template` takes the app's
  template via `--template`; `manifest scaffold` takes app name / lang /
  registry / domain as flags + `.env`, never hardcoded. The code review for
  this phase must apply the ADR's test: *"would this line change for a
  different app?"* — if yes, it is misplaced.
- **Deliberate deviations from a literal PRD reading**, both recorded above:
  (1) `manifest scaffold` reports drift rather than reconciling-by-overwrite
  (R4); (2) no `core/templates/` tree — `examples/` is reused (R5).
- **`written_files` for `db create`** is always `[]` (it writes no files) —
  the field is kept for a uniform JSON shape across the three primitives.
- **Phase 5 hand-off**: these three `cmd_*` functions are what `outpost
  onboard` (Phase 5) will call in sequence. Keeping them as functions in
  `scripts/outpost` (not separate scripts) means Phase 5 can invoke them
  in-process; the JSON `next_action` field is the human-facing breadcrumb,
  while Phase 5 reads `status` programmatically.
- **`outpost.app.yaml`** is intentionally not introduced; if a later phase
  adds it, `manifest scaffold` can read defaults from it instead of flags
  without breaking the flag interface.
```
