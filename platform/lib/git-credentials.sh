# shellcheck shell=bash
# =============================================================================
# Outpost / platform/lib/git-credentials.sh
# -----------------------------------------------------------------------------
# Multi-host clone credentials for Tekton's git-clone task.
#
# The single-host case stays on core/k8s/05-tekton/secrets.template.yaml
# (rendered+applied unconditionally in Phase 8). This module is ONLY engaged
# when GIT_CREDENTIALS_EXTRA is non-empty — i.e. when GIT_PROVIDER_PLUGIN spans
# providers AND you build private app repos that live on a host OTHER than
# MANIFEST_REPO_URL's host. It emits a complete git-credentials Secret that
# carries one `tekton.dev/git-N` annotation + one `.git-credentials` line per
# host, so Tekton's basic-auth git-clone resolves the right PAT per host.
#
# Why a full-secret overwrite rather than a patch:
#   `.git-credentials` is a multi-line literal block and the annotations are a
#   map — patching either via kubectl is brittle. Emitting the whole Secret
#   (primary host-0 + extras host-1..N) keeps the output deterministic and
#   fixture-testable.
#
# Security:
#   The emitted YAML contains GIT_TOKEN + each extra token in cleartext (same
#   as the template it replaces). Callers MUST pipe it to a 0600 temp file or
#   straight into `kubectl apply -f -`, and MUST NOT echo it to logs.
#
# Requires platform/lib/portable.sh sourced first (err).
# =============================================================================

# render_git_credentials_extra
# -----------------------------------------------------------------------------
# Reads (env): GIT_HOST, GIT_USER, GIT_TOKEN  — the primary (tekton.dev/git-0),
#              derived from MANIFEST_REPO_URL by bootstrap.d/02-config.sh.
#              GIT_CREDENTIALS_EXTRA — comma-separated `host|user|token` entries.
# Emits (stdout): a complete git-credentials Secret manifest.
# Returns: 0 on success; non-zero (with stderr context) on malformed input.
render_git_credentials_extra() {
  if [[ -z "${GIT_HOST:-}" || -z "${GIT_USER:-}" || -z "${GIT_TOKEN:-}" ]]; then
    err "render_git_credentials_extra: GIT_HOST/GIT_USER/GIT_TOKEN must all be set"
    return 1
  fi

  # host-0 is always the primary (MANIFEST_REPO host).
  local annotations cred_lines
  annotations="    tekton.dev/git-0: https://${GIT_HOST}"
  cred_lines="    https://${GIT_USER}:${GIT_TOKEN}@${GIT_HOST}"

  local -a entries
  IFS=',' read -ra entries <<< "${GIT_CREDENTIALS_EXTRA:-}"

  local idx=1 entry host user token
  for entry in "${entries[@]}"; do
    # Trim surrounding whitespace (operators sometimes write "a, b").
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue

    IFS='|' read -r host user token <<< "$entry"
    # SECURITY: never echo $user/$token — log only the host. `$entry` carries a
    # cleartext PAT, and bootstrap runs under `set -euo pipefail`, so a raw
    # `err "...$entry"` would print the token to the terminal/redirected log.
    if [[ -z "$host" || -z "$user" || -z "$token" || "$host" == *"/"* || "$host" == *":"* ]]; then
      err "render_git_credentials_extra: bad GIT_CREDENTIALS_EXTRA entry (host='${host}'; omitting user/token)"
      err "  expected: host|user|token  (host = bare hostname, no scheme/path/port)"
      return 1
    fi
    # YAML-injection guard: a newline/CR in user or token would break out of the
    # scalar/literal block below. `read` already stops at \n so this is belt +
    # suspenders, but make the safety contract explicit rather than incidental.
    if [[ "$user" == *$'\n'* || "$user" == *$'\r'* || "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
      err "render_git_credentials_extra: user/token must not contain newline/CR (host='${host}')"
      return 1
    fi

    annotations+=$'\n'"    tekton.dev/git-${idx}: https://${host}"
    cred_lines+=$'\n'"    https://${user}:${token}@${host}"
    idx=$((idx + 1))
  done

  # NOTE: keep the `.gitconfig` block byte-identical to
  # core/k8s/05-tekton/secrets.template.yaml — the git-clone catalog task copies
  # it verbatim and a drift would change clone behavior for the primary host too.
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: git-credentials
  namespace: tekton-pipelines
  annotations:
${annotations}
type: Opaque
stringData:
  username: ${GIT_USER}
  password: ${GIT_TOKEN}
  .git-credentials: |
${cred_lines}
  .gitconfig: |
    [credential]
        helper = store
    [user]
        email = tekton-ci@local
        name = Tekton CI
YAML
}
