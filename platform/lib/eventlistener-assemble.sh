# shellcheck shell=bash
# =============================================================================
# Outpost / platform/lib/eventlistener-assemble.sh
# -----------------------------------------------------------------------------
# Splice the active git-provider plugin's trigger.yaml into the
# provider-agnostic EventListener base template.
#
# Two strict invariants:
#   - Both inputs go through render_template (envsubst + unresolved-${VAR}
#     check), so a missing GIT_WEBHOOK_SECRET / CEL_WHITELIST_LIST / etc.
#     aborts loudly rather than producing a broken EventListener.
#   - The plugin trigger.yaml is spliced at the literal marker line
#     `# OUTPOST_TRIGGERS_HERE`, indented to fit under `spec.triggers:`.
#     Marker line is removed; if it appears more than once the function
#     aborts (sigil ambiguity = silent failure waiting to happen).
#     Marker intentionally avoids the `__VAR__` pattern reserved by
#     plugin-contract.bats for forbidden envsubst leftovers.
#
# Contract:
#   assemble_eventlistener <plugin_trigger_src> <base_template_src> <output>
#     - Renders both inputs via render_template into temp files.
#     - Reads the plugin trigger file, indents each line by 4 spaces, and
#       substitutes for the marker in the base template.
#     - Writes the assembled YAML to <output>.
#     - Returns 0 on success; non-zero (with stderr context) on failure.
#
# Requires platform/lib/portable.sh sourced first (render_template, err, ok).
# =============================================================================

# Indent string used to push the plugin trigger block under `triggers:`.
EL_TRIGGER_INDENT="    "
# Marker line authors write in eventlistener-base.yaml. Must appear exactly
# once; if absent or duplicated we refuse to assemble.
EL_TRIGGER_MARKER="# OUTPOST_TRIGGERS_HERE"

assemble_eventlistener() {
  local trigger_src="$1" base_src="$2" out="$3"

  if [[ -z "$trigger_src" || -z "$base_src" || -z "$out" ]]; then
    err "assemble_eventlistener: usage: <plugin_trigger> <base_template> <output>"
    return 1
  fi
  if [[ ! -r "$trigger_src" ]]; then
    err "assemble_eventlistener: plugin trigger not readable: $trigger_src"
    return 1
  fi
  if [[ ! -r "$base_src" ]]; then
    err "assemble_eventlistener: base template not readable: $base_src"
    return 1
  fi

  local rendered_trigger rendered_base
  rendered_trigger=$(mktemp)
  rendered_base=$(mktemp)
  # NOTE: cleanup is inline rather than via `trap RETURN` because bash's
  # RETURN trap fires on every function-return inside the same shell —
  # including the inner render_template calls in subtle ways depending on
  # bash version + the `declare -ft` trace flag. We've seen the trap
  # delete $rendered_base before the awk splice in some shells. Inline
  # cleanup at every exit point avoids the surprise.

  if ! render_template "$trigger_src" "$rendered_trigger"; then
    rm -f "$rendered_trigger" "$rendered_base"
    return 1
  fi
  if ! render_template "$base_src" "$rendered_base"; then
    rm -f "$rendered_trigger" "$rendered_base"
    return 1
  fi

  # Marker presence + uniqueness check. Doing this BEFORE the splice gives
  # a clear error instead of a silently-broken EventListener.
  local marker_count
  marker_count=$(grep -cF "$EL_TRIGGER_MARKER" "$rendered_base" || true)
  if [[ "$marker_count" -ne 1 ]]; then
    err "assemble_eventlistener: base template must contain exactly one '$EL_TRIGGER_MARKER' line (found $marker_count in $base_src)"
    rm -f "$rendered_trigger" "$rendered_base"
    return 1
  fi

  # Splice: every line of rendered_trigger gets prefixed with EL_TRIGGER_INDENT
  # and replaces the marker line.
  awk -v marker="$EL_TRIGGER_MARKER" \
      -v indent="$EL_TRIGGER_INDENT" \
      -v trigger_file="$rendered_trigger" '
    {
      if (index($0, marker) > 0) {
        while ((getline line < trigger_file) > 0) {
          print indent line
        }
        close(trigger_file)
      } else {
        print
      }
    }
  ' "$rendered_base" > "$out"

  rm -f "$rendered_trigger" "$rendered_base"
  return 0
}

# =============================================================================
# assemble_eventlistener_multi — splice MORE THAN ONE provider trigger.
# -----------------------------------------------------------------------------
# Why this exists:
#   GIT_PROVIDER_PLUGIN accepts a comma-separated list (gitee,github,gitlab) so
#   one cluster can ingest webhooks from every provider on the single
#   `el-build-listener`. The EventListener's `triggers:` field is a LIST, and
#   each provider's trigger.yaml short-circuits on its own header-type filter
#   (X-Gitee-Token / X-Hub-Signature-256 / X-Gitlab-Event), so stacking them is
#   safe — an inbound push matches exactly one trigger and the rest no-op.
#
# How:
#   Concatenate the raw plugin trigger files (each a `- name: <provider>-push`
#   YAML list item) into one combined trigger source, then delegate to
#   assemble_eventlistener — so the render + marker-uniqueness + splice logic
#   has exactly ONE implementation. A newline is forced between files so a
#   trigger that lacks a trailing newline can't fuse its last line onto the
#   next file's first line.
#
# Contract:
#   assemble_eventlistener_multi <base_template> <output> <trigger1> [trigger2 ...]
#     - At least one trigger file is required (empty list is a usage error —
#       a webhook listener with zero triggers silently drops every push).
#     - Returns 0 on success; non-zero (with stderr context) on failure.
# =============================================================================
assemble_eventlistener_multi() {
  local base_src="$1" out="$2"
  shift 2 || true

  if [[ -z "$base_src" || -z "$out" || $# -eq 0 ]]; then
    err "assemble_eventlistener_multi: usage: <base_template> <output> <trigger1> [trigger2 ...]"
    return 1
  fi

  local combined t
  combined=$(mktemp)
  for t in "$@"; do
    if [[ ! -r "$t" ]]; then
      err "assemble_eventlistener_multi: plugin trigger not readable: $t"
      rm -f "$combined"
      return 1
    fi
    cat "$t" >> "$combined"
    printf '\n' >> "$combined"
  done

  assemble_eventlistener "$combined" "$base_src" "$out"
  local rc=$?
  rm -f "$combined"
  return $rc
}
