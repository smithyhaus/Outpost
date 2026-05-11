#!/usr/bin/env bash
# =============================================================================
# build_cel_whitelist — convert WEBHOOK_REPO_WHITELIST (comma-separated URLs)
# into a CEL list literal usable inside a Tekton EventListener interceptor.
# -----------------------------------------------------------------------------
# Tested by tests/bats/cel-helpers.bats.
#
# CEL syntax: ['url1','url2',...]  — single-quoted string elements.
# Output goes to ${CEL_WHITELIST_LIST}; the EventListener filter:
#   size(${CEL_WHITELIST_LIST}) == 0 || body.repository.git_http_url in ${CEL_WHITELIST_LIST}
# short-circuits to true when the list is empty (back-compat: accept any repo).
#
# Inputs : WEBHOOK_REPO_WHITELIST (comma-separated, may be empty/unset).
# Exports: CEL_WHITELIST_LIST.
# =============================================================================

build_cel_whitelist() {
  if [[ -z "${WEBHOOK_REPO_WHITELIST:-}" ]]; then
    CEL_WHITELIST_LIST="[]"
    export CEL_WHITELIST_LIST
    return 0
  fi
  local out="["
  local entry trimmed
  IFS=',' read -ra _wl <<< "${WEBHOOK_REPO_WHITELIST}"
  for entry in "${_wl[@]}"; do
    trimmed="${entry// /}"
    [[ -z "$trimmed" ]] && continue
    out+="'$trimmed',"
  done
  CEL_WHITELIST_LIST="${out%,}]"
  export CEL_WHITELIST_LIST
  unset _wl entry trimmed
}
