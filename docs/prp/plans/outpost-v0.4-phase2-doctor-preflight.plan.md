# Plan: `outpost doctor` — Ex-Ante Preflight (Outpost v0.4 Phase 2)

## Summary

Add `outpost doctor` — a pre-bootstrap preflight that surfaces the failure modes
which today only appear half-way through `bootstrap.sh` (port collisions, Docker
down, unresolved domain, malformed Cloudflare token, unreachable build images,
blocked egress). It mirrors `verify.sh` exactly in structure (the ex-post health
checker) but runs *before* anything is installed, emits human + `--json` output
with a `fix_hint` per failed check, and is fully read-only / idempotent.

## User Story

As **the Outpost maintainer (or an AI agent) about to run `bootstrap.sh` or
`outpost onboard`**, I want **one command that tells me exactly what will break
before I start**, so that **a port collision or a bad token is a 2-second clear
message up front, not a confusing Docker/kubectl error 5 minutes into a phase**.

## Problem → Solution

**Current state**: `verify.sh` is *ex-post* — it tells you what broke *after*
bootstrap. There is no *ex-ante* check. The two cheapest failure modes have no
good error today: a host port already bound (Compose dies with
`Bind for 0.0.0.0:5432 failed: port is already allocated` mid-Phase-4) and a
malformed `CF_TUNNEL_TOKEN` (cloudflared silently fails to register). During the
SCM MCP onboarding these surfaced as confusing mid-pipeline errors.

**Desired state**: `outpost doctor` runs every cheap precondition check up front,
prints `PASS`/`WARN`/`FAIL` with a concrete `fix_hint` for each failure, supports
`--json` for AI agents, exits `0`/`2`/`1`, and never mutates anything.

## Metadata

- **Complexity**: Large (1 new ~200-line script + 1 new lib + 1 schema + 2 new test files + 2 small UPDATEs = 7 files)
- **Source PRD**: `docs/prp/prds/outpost-v0.4-real-project-onboarding.prd.md`
- **PRD Phase**: Phase 2 — `outpost doctor` ex-ante
- **Estimated Files**: 7 (4 created, 1 created lib, 2 updated)

---

## UX Design

### Before
```
$ bash bootstrap.sh
... Phase 1 OK ... Phase 2 OK ... Phase 3 OK ...
Phase 4 / 10 Compose
ERROR: Bind for 0.0.0.0:5432 failed: port is already allocated
        ↑ 4 phases + ~90s in before the real problem shows
```

### After
```
$ outpost doctor
═══ 1. Tooling ═══
[PASS] tool.docker — found at /usr/local/bin/docker
[PASS] docker.daemon — running
═══ 2. Host ports ═══
[FAIL] port.5432 — in use (PID 9123, postgres)
       ↳ fix: stop the process on :5432 — it collides with the postgres
              container. `lsof -iTCP:5432 -sTCP:LISTEN`; or `brew services stop postgresql`
═══ Summary ═══
PASS: 7  WARN: 1  FAIL: 1   → exit 1
$ # fix it, re-run, then bootstrap.sh — no surprise mid-install
```

### Interaction Changes

| Touchpoint | Before | After | Notes |
|---|---|---|---|
| New CLI subcommand | — | `outpost doctor [--egress h1,h2]` | Standalone, like `outpost verify` |
| AI agent preflight | none | `outpost doctor --json` → parse `checks[].fix_hint` | New AI-facing surface |
| `bootstrap.sh` | unchanged | unchanged | doctor is NOT auto-wired into bootstrap (see NOT Building) |
| New top-level script | `verify.sh`, `status.sh` | `+ doctor.sh` | Sibling, same conventions |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `verify.sh` | 1-105, 307-330 | **The template.** doctor.sh mirrors its structure: header, `record`/`section`, mode-awareness, JSON emit, exit codes |
| P0 | `platform/lib/portable.sh` | 17-62, 100-110 | `SK_C_*` colors, `log/ok/warn/err`, `detect_os`/`SK_OS`, `require_cmd` |
| P0 | `scripts/outpost` | 79-82, 312-327 | `cmd_status` exec pattern + the router `case` to extend |
| P0 | `tests/schema/verify-output.schema.json` | all (41) | Schema to clone for `doctor-output.schema.json` (+`fix_hint`) |
| P1 | `tests/bats/verify-schema.bats` | all (40) | JSON-shape assertion pattern (jq-based) |
| P1 | `tests/bats/eventlistener-assemble.bats` | 10-31 | bats pattern for a file that sources a `platform/lib/*.sh` to unit-test its functions |
| P1 | `tests/bats/outpost-cli.bats` | 18-25 | The help-subcommands assertion to extend with `doctor` |
| P1 | `bootstrap.d/01-preflight.sh` | all (28) | The existing (in-bootstrap) preflight — doctor supersedes/anticipates it; do not duplicate-wire |
| P2 | `core/compose/docker-compose.yml` | 88-89, 117-118, 140-141, 164-165 | Authoritative host-bound ports: 5432 / 6379 / 5672 / 9308 (NOT 15672). Note: 9306 + 9312 are also bound by Manticore but doctor only checks 9308 as the load-bearing port. |

## External Documentation

No external research needed — feature uses only standard tools (`docker`,
`curl`, bash `/dev/tcp`, `df`, `getent`/`nslookup`) and established internal
patterns (the `verify.sh` structure, the `platform/lib/*.sh` + bats split).

GOTCHA captured from exploration: TODOS.md listed host port `15672` — that is
**wrong**. `core/compose/docker-compose.yml` host-binds only `5432/6379/5672/9308`
(plus Manticore's 9306/9312); RabbitMQ's `15672` management UI is caddy-proxied,
never host-bound. doctor checks the 4 load-bearing ports.

---

## Patterns to Mirror

### SCRIPT_HEADER_AND_MODE (verify.sh:1-49)
```bash
#!/usr/bin/env bash
set -uo pipefail
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT" || { echo "ERROR: cannot cd to $INFRA_ROOT" >&2; exit 1; }
source "${INFRA_ROOT}/platform/lib/portable.sh"

MODE="human"
case "${1:-}" in --json) MODE="json" ;; --quiet) MODE="quiet" ;; esac

# Load env best-effort — doctor MUST work before bootstrap (no .env yet).
if [[ -f .env ]]; then set -a; source .env; set +a; fi
ROOT_DOMAIN="${ROOT_DOMAIN:-example.com}"
OUTPOST_MODE="${OUTPOST_MODE:-local}"
detect_os 2>/dev/null || SK_OS="unknown"
```
NOTE: `set -uo pipefail` — **no `-e`** (verify.sh deliberately omits `-e` so a
failing check doesn't abort the script). doctor must do the same.

### RECORD_AND_SECTION (verify.sh:54-79) — extended with fix_hint
```bash
PASS_CNT=0; WARN_CNT=0; FAIL_CNT=0
RESULTS=()
# doctor's record takes a 4th arg (fix_hint) — verify.sh has 3.
record() {
  local status="$1" id="$2" detail="$3" fix_hint="${4:-}"
  RESULTS+=("$status|$id|$detail|$fix_hint")
  case "$status" in
    PASS) PASS_CNT=$((PASS_CNT+1)) ;;
    WARN) WARN_CNT=$((WARN_CNT+1)) ;;
    FAIL) FAIL_CNT=$((FAIL_CNT+1)) ;;
  esac
  if [[ "$MODE" == "human" ]]; then
    case "$status" in
      PASS) echo -e "${SK_C_GREEN}[PASS]${SK_C_RESET} $id ${SK_C_DIM}— $detail${SK_C_RESET}" ;;
      WARN) echo -e "${SK_C_YELLOW}[WARN]${SK_C_RESET} $id ${SK_C_DIM}— $detail${SK_C_RESET}" ;;
      FAIL) echo -e "${SK_C_RED}[FAIL]${SK_C_RESET} $id ${SK_C_DIM}— $detail${SK_C_RESET}" ;;
    esac
    [[ -n "$fix_hint" && "$status" != "PASS" ]] && echo -e "       ${SK_C_DIM}↳ fix: $fix_hint${SK_C_RESET}"
  fi
}
```

### JSON_EMIT (verify.sh:308-320) — extended with fix_hint
```bash
if [[ "$MODE" == "json" ]]; then
  printf '{"schema_version":"1","summary":{"pass":%d,"warn":%d,"fail":%d,"os":"%s","mode":"%s"},"checks":[' \
    "$PASS_CNT" "$WARN_CNT" "$FAIL_CNT" "${SK_OS:-unknown}" "$OUTPOST_MODE"
  first=1
  for r in "${RESULTS[@]}"; do
    [[ $first -eq 0 ]] && printf ','; first=0
    status="${r%%|*}"; rest="${r#*|}"
    id="${rest%%|*}"; rest="${rest#*|}"
    detail="${rest%%|*}"; fix_hint="${rest#*|}"
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '; }
    printf '{"status":"%s","id":"%s","detail":"%s","fix_hint":"%s"}' \
      "$status" "$id" "$(esc "$detail")" "$(esc "$fix_hint")"
  done
  printf ']}\n'
fi
```

### EXIT_CODES (verify.sh:327-329)
```bash
[[ $FAIL_CNT -gt 0 ]] && exit 1
[[ $WARN_CNT -gt 0 ]] && exit 2
exit 0
```

### CLI_SUBCOMMAND_EXEC (scripts/outpost:80-82)
```bash
cmd_status() { exec bash "$OUTPOST_HOME/status.sh" "$@"; }
```

### LIB_PLUS_BATS_SPLIT (the established "logic in lib, tested by bats" pattern)
`02-config.sh:115` comment: *"All actual logic lives in platform/lib/{registry-config,cel-helpers}.sh so it has bats coverage."* — `platform/lib/eventlistener-assemble.sh` + `tests/bats/eventlistener-assemble.bats` is the reference: the bats file `source`s the lib in `setup()` and unit-tests each function.

### BATS_SCHEMA_LOCK (tests/bats/verify-schema.bats:11-39)
```bash
@test "verify.sh --json produces shape conforming to the locked schema" {
  command -v jq >/dev/null || skip "jq not available"
  out=$(cd "$INFRA_ROOT" && bash verify.sh --json 2>/dev/null || true)
  echo "$out" | jq -e . >/dev/null
  echo "$out" | jq -e '.schema_version == "1"' >/dev/null
  # ...summary count cross-check...
}
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `platform/lib/doctor-checks.sh` | CREATE | Pure, sourcable check functions — so synthetic-failure cases are unit-testable (mirrors the registry-config/cel-helpers lib pattern) |
| `doctor.sh` | CREATE | Top-level orchestrator at repo root, sibling of `verify.sh`/`status.sh` |
| `scripts/outpost` | UPDATE | Add `cmd_doctor`, router case, usage entry |
| `tests/schema/doctor-output.schema.json` | CREATE | Locks the `--json` shape (AI contract) — clone of verify's schema + `fix_hint` |
| `tests/bats/doctor-checks.bats` | CREATE | Unit tests for the lib — the synthetic-failure suite (port busy, bad CF token, …) |
| `tests/bats/doctor.bats` | CREATE | End-to-end: run `doctor.sh`, assert JSON shape vs schema, exit codes, CLI wiring |
| `tests/bats/outpost-cli.bats` | UPDATE | Add `doctor` to the advertised-subcommands help assertion |

## NOT Building

- **Auto-wiring doctor into `bootstrap.sh`** — doctor stays standalone like
  `verify.sh` (also not auto-run). A human runs it before `bootstrap.sh`;
  `outpost onboard` (PRD Phase 5) will call it. Auto-failing bootstrap on a
  doctor WARN is a behavior change out of scope here.
- **PSA-label check** — the PRD Phase 2 scope listed "`tekton-pipelines` PSA
  label set", but that label is *output* of bootstrap Phase 8, not a
  precondition. Checking it pre-bootstrap would always fail. It is already
  regression-locked by `cicd-walls.bats` (B6) from Phase 1. Excluded.
- **Semantic per-wall exit codes** (`21`/`22`/`23`…) — PRD Phase 6 owns the
  formal exit-code catalog. doctor uses verify.sh's `0`/`1`/`2` convention.
- **A formal `fix_hint` error-code schema** beyond the field itself — Phase 6.
- **Cluster-state checks** — doctor is ex-ante; anything needing `kubectl`
  belongs to `verify.sh`.
- **Auto-remediation** — doctor reports + hints, never fixes.

---

## Step-by-Step Tasks

### Task 1: Create `platform/lib/doctor-checks.sh` — pure check functions
- **ACTION**: Create `platform/lib/doctor-checks.sh`.
- **IMPLEMENT**: A source-only lib (no top-level execution) with these functions,
  each returning status via stdout (`free`/`busy`, `valid`/`invalid`, …) so bats
  can unit-test them. Header comment mirrors `platform/lib/eventlistener-assemble.sh:1-15`.
  ```bash
  # shellcheck shell=bash
  # =============================================================================
  # Outpost / platform/lib/doctor-checks.sh
  # Pure precondition-check helpers for doctor.sh. Source-only — never executed.
  # Each function is side-effect-free and unit-tested by tests/bats/doctor-checks.bats.
  # =============================================================================

  # Is a TCP port accepting connections on localhost? Echoes "busy" or "free".
  # Uses bash /dev/tcp — no lsof/nc dependency.
  doctor_port_state() {
    local port="$1"
    if (echo >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      echo "busy"
    else
      echo "free"
    fi
  }

  # Best-effort "what holds this port" string for a fix_hint. Empty if unknown.
  doctor_port_holder() {
    local port="$1"
    command -v lsof >/dev/null 2>&1 || { echo ""; return; }
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN -Fcn 2>/dev/null \
      | awk '/^c/{c=substr($0,2)} /^n/{print c" ("substr($0,2)")"; exit}'
  }

  # Does CF_TUNNEL_TOKEN look like a Cloudflare tunnel token?
  # Real tokens are a long base64url string (>= 80 chars, [A-Za-z0-9_-=]).
  # Echoes "valid" or "invalid". Empty input → "invalid".
  doctor_cf_token_state() {
    local tok="$1"
    if [[ -n "$tok" && ${#tok} -ge 80 && "$tok" =~ ^[A-Za-z0-9_=-]+$ ]]; then
      echo "valid"
    else
      echo "invalid"
    fi
  }

  # Does a hostname resolve via DNS? Echoes "ok" or "nxdomain".
  # Tries getent (Linux), then host, then nslookup, then python — whichever exists.
  doctor_dns_state() {
    local host="$1"
    if command -v getent >/dev/null 2>&1; then
      getent hosts "$host" >/dev/null 2>&1 && { echo ok; return; }
    fi
    if command -v host >/dev/null 2>&1; then
      host -W 3 "$host" >/dev/null 2>&1 && { echo ok; return; }
    fi
    if command -v nslookup >/dev/null 2>&1; then
      nslookup "$host" >/dev/null 2>&1 && { echo ok; return; }
    fi
    echo nxdomain
  }
  ```
- **MIRROR**: `LIB_PLUS_BATS_SPLIT`; header style from `platform/lib/eventlistener-assemble.sh:1-15`.
- **IMPORTS**: none — pure bash. Functions assume bash (`/dev/tcp`, `[[ =~ ]]`).
- **GOTCHA**: `/dev/tcp` is bash-only — fine, every Outpost script runs under
  bash. `doctor_port_holder` degrades to `""` when `lsof` is absent (common on
  minimal Linux) — doctor must tolerate an empty holder string.
- **VALIDATE**: `bash -n platform/lib/doctor-checks.sh`; `shellcheck` clean via `tests/lint.sh`.

### Task 2: Create `doctor.sh` — the orchestrator
- **ACTION**: Create `doctor.sh` at the repo root (sibling of `verify.sh`).
- **IMPLEMENT**: Mirror `verify.sh` end-to-end. Structure:
  1. **Header + mode** — `SCRIPT_HEADER_AND_MODE` pattern. Additionally parse
     `--egress h1,h2,...` into an `EGRESS_HOSTS` array (default empty).
  2. `source platform/lib/portable.sh` **and** `source platform/lib/doctor-checks.sh`.
  3. `record` (4-arg, with `fix_hint`) + `section` + `has_cmd`/`docker_ok` —
     `RECORD_AND_SECTION` pattern.
  4. **Section 1 — Tooling**: `REQUIRED_TOOLS` per mode (local: `docker openssl
     envsubst curl`; full: `+ kubectl helm git`). For each: PASS if present,
     FAIL with `fix_hint` "install <cmd> — `brew install <cmd>` / `apt-get install <pkg>`".
     `docker info` → `docker.daemon` PASS/FAIL (hint: "start Docker Desktop, or
     `sudo systemctl start docker`"). `docker compose version` → `docker.compose_v2`.
     `record PASS platform.os "$SK_OS" ""` and `platform.mode`.
  5. **Section 2 — Host ports** (both modes): for `p` in `5432 6379 5672 9308`:
     `state=$(doctor_port_state "$p")`. `free` → PASS. `busy` → FAIL,
     `holder=$(doctor_port_holder "$p")`, fix_hint
     `"port $p is in use${holder:+ by $holder} — it collides with the <svc> container; stop it before bootstrap"`.
     Map port→service in a small case (`5432→postgres` etc.) for the detail.
  6. **Section 3 — Disk** (both modes, WARN-only): best-effort free space at
     `docker info --format '{{.DockerRootDir}}'`; `df -Pk` that path; if < 5 GB
     → WARN (hint: "low disk where Docker stores data — `docker system prune`").
     If the path can't be `df`'d (macOS Docker Desktop VM) → WARN
     `"could not determine Docker disk free space"`, no fix_hint. Never FAIL.
  7. **Sections 4-7 — full mode only** (`if [[ "$OUTPOST_MODE" == "full" ]]`):
     - `dns.root_domain`: `doctor_dns_state "$ROOT_DOMAIN"` (skip with WARN if
       `ROOT_DOMAIN == example.com`). nxdomain → FAIL, hint "move ROOT_DOMAIN's
       nameservers to Cloudflare and wait for propagation".
     - `cf.token`: `doctor_cf_token_state "${CF_TUNNEL_TOKEN:-}"`. invalid → FAIL,
       hint "CF_TUNNEL_TOKEN looks malformed — re-copy the tunnel token from the
       Cloudflare Zero Trust dashboard".
     - `net.host_docker_internal`: `docker run --rm --add-host=host.docker.internal:host-gateway alpine:3.20 getent hosts host.docker.internal`
       (only if `docker_ok`). Non-zero → FAIL, hint "host.docker.internal not
       resolvable from containers — k3s pods can't reach the data layer".
     - `image.kaniko`: `docker manifest inspect gcr.io/kaniko-project/executor:v1.5.1 >/dev/null`
       → FAIL on error, hint "cannot reach the kaniko build image — check network
       / registry mirror". WARN (not FAIL) if `docker` itself is down (already
       reported by `docker.daemon`).
  8. **Section 8 — Egress** (only if `EGRESS_HOSTS` non-empty, any mode): for each
     host, `curl -sS -o /dev/null --max-time 8 "https://$host"` (also try plain
     `$host`); unreachable → FAIL, hint "build pods will need to reach <host> —
     it's unreachable from this machine; check firewall/DNS". Empty list → one
     PASS `egress.skipped` "no --egress hosts given".
  9. **Output** — `JSON_EMIT` pattern (4-field checks) for `--json`; human
     summary line otherwise; `EXIT_CODES` (0/2/1).
- **MIRROR**: every pattern above; the section/record flow is `verify.sh:85-330`.
- **IMPORTS**: `source platform/lib/portable.sh`, `source platform/lib/doctor-checks.sh`.
- **GOTCHA**:
  - `set -uo pipefail` — **no `-e`** (a failing check must not abort the script).
  - doctor must run **before `.env` exists** — load `.env` best-effort, default
    every var (`ROOT_DOMAIN:-example.com`, `OUTPOST_MODE:-local`, `CF_TUNNEL_TOKEN:-`).
  - `docker run` / `docker manifest inspect` only when `docker info` succeeded —
    otherwise emit WARN "skipped — docker not running", do not let the command
    error noisily.
  - Read-only: no `mkdir`, no writes, `docker run --rm`. Idempotent by construction.
- **VALIDATE**: `bash -n doctor.sh`; `bash doctor.sh` runs and prints a summary;
  `bash doctor.sh --json | jq -e .` is valid JSON; `shellcheck` clean.

### Task 3: Wire `doctor` into the `outpost` CLI
- **ACTION**: Edit `scripts/outpost`.
- **IMPLEMENT**:
  1. Add a `cmd_doctor` function next to `cmd_status` (~line 82):
     ```bash
     cmd_doctor() { exec bash "$OUTPOST_HOME/doctor.sh" "$@"; }
     ```
  2. Add a router case (in the `case "$SUB"` block, near `status`/`verify`):
     ```bash
       doctor)         cmd_doctor "$@" ;;
     ```
  3. Add a usage line under the `$(_yellow PLATFORM)` block in `usage()`:
     ```
       doctor [--egress h1,h2]           Pre-bootstrap preflight — catch
                                         port/Docker/DNS/token failures up front
     ```
- **MIRROR**: `CLI_SUBCOMMAND_EXEC` (`cmd_status`); router style `scripts/outpost:316-326`.
- **IMPORTS**: none.
- **GOTCHA**: `cmd_doctor` uses `exec bash` so `$OUTPOST_HOME` (set at
  `scripts/outpost:12`) — not the CWD — locates `doctor.sh`. `doctor.sh` lives at
  the repo root, same as `status.sh`/`verify.sh`, so `$OUTPOST_HOME/doctor.sh`.
- **VALIDATE**: `bash scripts/outpost doctor --json | jq -e .` works;
  `bash scripts/outpost help` lists `doctor`.

### Task 4: Create `tests/schema/doctor-output.schema.json`
- **ACTION**: Create the JSON schema locking doctor's `--json` shape.
- **IMPLEMENT**: Clone `tests/schema/verify-output.schema.json`, retitle, and add
  `fix_hint` (required) to each `checks[]` item:
  ```json
  {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://github.com/smithyhaus/outpost/blob/main/tests/schema/doctor-output.schema.json",
    "title": "Outpost doctor.sh output",
    "description": "Schema for the JSON output of doctor.sh --json. Stable across patch/minor versions; bumps schema_version on breaking changes.",
    "type": "object",
    "required": ["schema_version", "summary", "checks"],
    "additionalProperties": false,
    "properties": {
      "schema_version": {"type": "string", "enum": ["1"]},
      "summary": {
        "type": "object",
        "required": ["pass", "warn", "fail", "os"],
        "additionalProperties": false,
        "properties": {
          "pass": {"type": "integer", "minimum": 0},
          "warn": {"type": "integer", "minimum": 0},
          "fail": {"type": "integer", "minimum": 0},
          "os":   {"type": "string", "enum": ["macos", "linux", "wsl2", "unknown"]},
          "mode": {"type": "string", "enum": ["local", "full", "unknown"]}
        }
      },
      "checks": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["status", "id", "detail", "fix_hint"],
          "additionalProperties": false,
          "properties": {
            "status":   {"type": "string", "enum": ["PASS", "WARN", "FAIL"]},
            "id":       {"type": "string", "pattern": "^[a-z][a-z0-9_.-]*$"},
            "detail":   {"type": "string"},
            "fix_hint": {"type": "string", "description": "Remediation hint; empty string for PASS checks."}
          }
        }
      }
    }
  }
  ```
- **MIRROR**: `tests/schema/verify-output.schema.json` exactly, +`fix_hint`.
- **IMPORTS**: none.
- **GOTCHA**: `additionalProperties:false` on the check item means doctor's JSON
  must emit **exactly** `status,id,detail,fix_hint` — no extras. Keep the JSON_EMIT
  printf in sync with this.
- **VALIDATE**: `jq -e . tests/schema/doctor-output.schema.json` is valid JSON.

### Task 5: Create `tests/bats/doctor-checks.bats` — synthetic-failure unit tests
- **ACTION**: Create the unit-test file for `platform/lib/doctor-checks.sh`.
- **IMPLEMENT**: `setup()` sources the lib (mirror `eventlistener-assemble.bats:10-17`).
  Tests:
  ```bash
  #!/usr/bin/env bats
  # Unit tests for platform/lib/doctor-checks.sh — the synthetic-failure suite.
  setup() {
    INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    source "${INFRA_ROOT}/platform/lib/doctor-checks.sh"
  }

  # ---- doctor_port_state ----
  @test "doctor_port_state: a free high port reports free" {
    # Pick a port nothing should hold.
    [ "$(doctor_port_state 49231)" = "free" ]
  }
  @test "doctor_port_state: an occupied port reports busy" {
    command -v nc >/dev/null || skip "nc not available"
    nc -l 49232 >/dev/null 2>&1 &
    local pid=$!
    sleep 0.3
    run doctor_port_state 49232
    kill "$pid" 2>/dev/null || true
    [ "$output" = "busy" ]
  }

  # ---- doctor_cf_token_state (synthetic: bad CF token → red) ----
  @test "doctor_cf_token_state: empty token is invalid" {
    [ "$(doctor_cf_token_state '')" = "invalid" ]
  }
  @test "doctor_cf_token_state: short junk is invalid" {
    [ "$(doctor_cf_token_state 'not-a-token')" = "invalid" ]
  }
  @test "doctor_cf_token_state: a long base64url string is valid" {
    local tok; tok=$(printf 'A%.0s' {1..120})
    [ "$(doctor_cf_token_state "$tok")" = "valid" ]
  }

  # ---- doctor_dns_state ----
  @test "doctor_dns_state: a bogus domain is nxdomain" {
    [ "$(doctor_dns_state 'no-such-host.invalid')" = "nxdomain" ]
  }

  # ---- doctor_port_holder degrades gracefully ----
  @test "doctor_port_holder: returns a string (possibly empty), never errors" {
    run doctor_port_holder 49233
    [ "$status" -eq 0 ]
  }
  ```
- **MIRROR**: `eventlistener-assemble.bats` setup() + `@test` structure.
- **IMPORTS**: sources `platform/lib/doctor-checks.sh`.
- **GOTCHA**: the `nc -l` test must `skip` when `nc` is absent (some CI images);
  background the listener, `sleep 0.3` for it to bind, always `kill` it even if
  the assertion fails (kill before the assertion line). `.invalid` TLD is
  RFC-2606 reserved → guaranteed NXDOMAIN, safe for the DNS test.
- **VALIDATE**: `bats tests/bats/doctor-checks.bats` — all pass.

### Task 6: Create `tests/bats/doctor.bats` — end-to-end + schema lock
- **ACTION**: Create the e2e test file for `doctor.sh`.
- **IMPLEMENT**:
  ```bash
  #!/usr/bin/env bats
  # End-to-end tests for doctor.sh — JSON shape (AI contract), exit codes, CLI wiring.
  setup() {
    INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    DOCTOR="${INFRA_ROOT}/doctor.sh"
    SCHEMA="${INFRA_ROOT}/tests/schema/doctor-output.schema.json"
    CLI="${INFRA_ROOT}/scripts/outpost"
  }

  @test "doctor.sh: bash syntax is valid" {
    run bash -n "$DOCTOR"
    [ "$status" -eq 0 ]
  }

  @test "doctor.sh: human run prints a Summary and exits 0/1/2" {
    run bash "$DOCTOR"
    [[ "$output" =~ "Summary" ]]
    [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 ]]
  }

  @test "doctor.sh --json: valid JSON conforming to the locked schema shape" {
    command -v jq >/dev/null || skip "jq not available"
    out=$(cd "$INFRA_ROOT" && bash doctor.sh --json 2>/dev/null || true)
    echo "$out" | jq -e . >/dev/null
    echo "$out" | jq -e '.schema_version == "1"' >/dev/null
    echo "$out" | jq -e '.summary | has("pass") and has("warn") and has("fail") and has("os")' >/dev/null
    echo "$out" | jq -e '.checks | type == "array"' >/dev/null
    # every check has all 4 fields incl. fix_hint
    echo "$out" | jq -e '.checks | all(has("status") and has("id") and has("detail") and has("fix_hint"))' >/dev/null
    echo "$out" | jq -e '.checks | all(.status as $s | (["PASS","WARN","FAIL"]|index($s)) != null)' >/dev/null
    # summary counts equal the grouping of checks
    [ "$(echo "$out" | jq '[.checks[]|select(.status=="PASS")]|length')" = "$(echo "$out" | jq '.summary.pass')" ]
    [ "$(echo "$out" | jq '[.checks[]|select(.status=="FAIL")]|length')" = "$(echo "$out" | jq '.summary.fail')" ]
  }

  @test "doctor.sh --json: failing checks carry a non-empty fix_hint" {
    command -v jq >/dev/null || skip "jq not available"
    out=$(cd "$INFRA_ROOT" && bash doctor.sh --json 2>/dev/null || true)
    # Any FAIL/WARN check that exists must have a fix_hint string field (may be
    # empty for some WARNs, but the field is always present — asserted above).
    echo "$out" | jq -e '.checks | all(.fix_hint | type == "string")' >/dev/null
  }

  @test "doctor.sh: a malformed CF_TUNNEL_TOKEN in full mode is reported FAIL with a fix_hint" {
    command -v jq >/dev/null || skip "jq not available"
    out=$(cd "$INFRA_ROOT" && OUTPOST_MODE=full ROOT_DOMAIN=example.com \
          CF_TUNNEL_TOKEN=bogus bash doctor.sh --json 2>/dev/null || true)
    echo "$out" | jq -e '.checks[] | select(.id=="cf.token") | .status == "FAIL"' >/dev/null
    echo "$out" | jq -e '.checks[] | select(.id=="cf.token") | .fix_hint | length > 0' >/dev/null
  }

  @test "outpost CLI: doctor subcommand is wired and runs" {
    run bash "$CLI" doctor --json
    [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 ]]
    [[ "$output" =~ "schema_version" ]]
  }
  ```
- **MIRROR**: `BATS_SCHEMA_LOCK` (`verify-schema.bats`); `outpost-cli.bats` run-style.
- **IMPORTS**: none (subprocess invocation, not sourcing — doctor.sh has top-level code).
- **GOTCHA**: doctor.sh has top-level executable code (like verify.sh) — bats must
  **run it as a subprocess** (`bash doctor.sh`), never `source` it. The CF-token
  synthetic test sets env inline so it is hermetic regardless of the host's real
  `.env`. `|| true` after the run because doctor exits non-zero on FAIL/WARN and
  `out=$(...)` under bats would otherwise abort the test.
- **VALIDATE**: `bats tests/bats/doctor.bats` — all pass.

### Task 7: Add `doctor` to the `outpost-cli.bats` help assertion
- **ACTION**: Edit `tests/bats/outpost-cli.bats`.
- **IMPLEMENT**: In the test `"outpost help: prints usage with all advertised
  subcommands"` (line 22), add `doctor` to the `for sub in ...` list:
  ```bash
  for sub in status verify doctor open logs rollback seal new-app decommission; do
  ```
- **MIRROR**: the existing line — just one token added.
- **IMPORTS**: none.
- **GOTCHA**: `doctor` must actually appear in `usage()` output (Task 3 step 3) or
  this test fails — Task 3 and Task 7 are a pair.
- **VALIDATE**: `bats tests/bats/outpost-cli.bats` — all pass.

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| `doctor_port_state` free | unused high port | `free` | no |
| `doctor_port_state` busy | port held by `nc -l` | `busy` | **synthetic failure** |
| `doctor_cf_token_state` empty | `''` | `invalid` | edge |
| `doctor_cf_token_state` junk | `not-a-token` | `invalid` | **synthetic failure** |
| `doctor_cf_token_state` valid | 120-char base64url | `valid` | no |
| `doctor_dns_state` bogus | `*.invalid` | `nxdomain` | **synthetic failure** |
| `doctor.sh --json` | run | schema-conforming JSON, 4-field checks | contract |
| `doctor.sh` full + bad token | `CF_TUNNEL_TOKEN=bogus` | `cf.token` = FAIL + fix_hint | **synthetic failure** |
| `outpost doctor` | via CLI | runs, emits JSON | wiring |

### Edge Cases Checklist
- [x] **No `.env` (pure pre-bootstrap)** — doctor loads `.env` best-effort, defaults all vars.
- [x] **Docker daemon down** — `docker.daemon` FAIL; container-based checks WARN-skip, no noisy errors.
- [x] **`lsof` absent** — `doctor_port_holder` returns `""`; port FAIL still emitted with a generic hint.
- [x] **`nc` / `jq` absent in CI** — affected tests `skip`.
- [x] **macOS Docker Desktop VM disk** — `disk.docker` degrades to WARN, never FAIL.
- [x] **local mode** — full-mode sections (DNS/token/kaniko/host-gateway) skipped.
- [N/A] Concurrent access / permission denied — read-only tool.

---

## Validation Commands

### Static Analysis
```bash
bash -n doctor.sh platform/lib/doctor-checks.sh
bash tests/lint.sh
```
EXPECT: zero syntax errors; `[ OK ] lint passed` (shellcheck clean on the 2 new shell files + `scripts/outpost`).

### Unit Tests — new + affected
```bash
bats tests/bats/doctor-checks.bats
bats tests/bats/doctor.bats
bats tests/bats/outpost-cli.bats
```
EXPECT: all pass. `outpost-cli.bats` still green (now asserts `doctor` in help).

### Full Test Suite
```bash
bats tests/bats/ tests/regression/
```
EXPECT: no regressions — was 154 tests after Phase 1; doctor adds ~13.

### Schema Validity
```bash
jq -e . tests/schema/doctor-output.schema.json >/dev/null && echo "schema OK"
```
EXPECT: `schema OK`.

### Manual Validation
- [ ] `bash doctor.sh` on this machine — eyeball PASS/WARN/FAIL + fix-hint lines render.
- [ ] `bash doctor.sh --json | jq .` — pretty JSON, every check has `fix_hint`.
- [ ] `OUTPOST_MODE=full ROOT_DOMAIN=example.com CF_TUNNEL_TOKEN=bad bash doctor.sh` — `cf.token` shows FAIL + hint.
- [ ] `bash scripts/outpost doctor` and `bash scripts/outpost help | grep doctor`.
- [ ] Synthetic port test: `nc -l 5432 &` then `bash doctor.sh` → `port.5432` FAIL; kill the listener.

---

## Acceptance Criteria
- [ ] All 7 tasks completed
- [ ] `bash tests/lint.sh` passes
- [ ] `bats tests/bats/ tests/regression/` — all green, no regressions
- [ ] `doctor.sh --json` validates against `doctor-output.schema.json` shape
- [ ] Every `checks[]` object has `status,id,detail,fix_hint`; FAIL checks have non-empty `fix_hint`
- [ ] `outpost doctor` wired into the CLI + listed in `help`
- [ ] doctor is read-only / idempotent — no file writes, `docker run --rm` only
- [ ] Synthetic-failure tests cover port-busy, bad-CF-token, bogus-DNS

## Completion Checklist
- [ ] Code follows discovered patterns (verify.sh structure, lib+bats split, CLI router)
- [ ] Error handling matches codebase — `record`-based, `set -uo pipefail` no `-e`
- [ ] Logging follows conventions — `SK_C_*` colors, `[PASS]/[WARN]/[FAIL]`
- [ ] Tests follow the `tests/bats/` pattern
- [ ] No hardcoded values that should be derived — port list is hardcoded but matches `core/compose/docker-compose.yml` (commented)
- [ ] Documentation — i18n docs + CHANGELOG deferred to PRD Phase 9; `usage()` updated inline
- [ ] No unnecessary scope additions (see NOT Building)
- [ ] Self-contained — no codebase searching needed during implementation

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `docker run`-based checks (host.docker.internal, kaniko) slow or flaky offline | M | Med | They are full-mode only; WARN-skip cleanly when `docker info` fails; `--max-time` on curl; small `alpine:3.20` image |
| Port check false-positive (a *legitimate* PG already running is "busy") | M | Low | That IS a real precondition conflict for Outpost's own PG container — FAIL is correct; the fix_hint explains the collision |
| `disk.docker` unreliable on macOS Docker Desktop VM | H | Low | WARN-only, never FAIL; explicitly documented as best-effort |
| JSON `\|`-delimiter collision if a `fix_hint` contains `\|` | L | Med | All hint strings are author-controlled and `\|`-free (same assumption verify.sh makes for `detail`) |
| `nc`/`jq` missing in a CI image breaks tests | L | Low | Every dependent test `skip`s when its tool is absent (matches `verify-schema.bats`) |
| Schema drift between `JSON_EMIT` printf and `doctor-output.schema.json` | M | Med | `doctor.bats` asserts the live `--json` shape against the 4 required fields — drift fails CI |

## Notes

- **PRD-vs-reality corrections found during exploration** (logged per the
  "verify plan assumptions" practice):
  1. TODOS.md listed host port `15672` — wrong. `core/compose/docker-compose.yml`
     binds only `5432/6379/5672/9308` (plus Manticore 9306/9312); `15672` is caddy-proxied. doctor checks 4 load-bearing ports.
  2. PRD Phase 2 scope listed a `tekton-pipelines` PSA-label check — that label
     is *output* of bootstrap, not a precondition; excluded (already covered by
     `cicd-walls.bats` B6). See NOT Building.
- **Design decision — egress check is `--egress`-flag-driven, not a config var.**
  Egress targets are per-onboarding-session and app-specific (SCM MCP needed
  `apidocs.scm321.com`). A CLI flag keeps Phase 2 out of `.env`/`02-config.sh`;
  `outpost onboard` (Phase 5) will pass `--egress` derived from the app.
- **Design decision — `doctor.sh` at repo root**, not `scripts/`. Its siblings
  `verify.sh` and `status.sh` are at root and the CLI execs them as
  `$OUTPOST_HOME/<name>.sh`. Consistency wins.
- **Design decision — lib + bats split.** Pure check logic lives in
  `platform/lib/doctor-checks.sh` precisely so the synthetic-failure cases
  (port busy, bad token) are unit-testable without a real cluster — the same
  rationale `02-config.sh:115` gives for `registry-config.sh`/`cel-helpers.sh`.
- **Exit codes**: doctor uses verify.sh's `0`/`1`/`2`. The PRD Phase 6 semantic
  exit-code catalog (`21`/`22`/…) is deliberately deferred — see NOT Building.
- **Doc/CHANGELOG**: `usage()` is updated inline; i18n docs (`i18n/*/docs/`) and
  CHANGELOG/VERSION are consolidated into PRD Phase 9.

---

*Generated: 2026-05-20*
*Source PRD phase: Phase 2 — outpost-v0.4-real-project-onboarding.prd.md*
