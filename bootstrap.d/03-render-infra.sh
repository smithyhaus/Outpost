# shellcheck shell=bash
# =============================================================================
# Phase 3 — Render INFRA.md / INFRA.zh-CN.md credential vault.
# =============================================================================
phase "Phase 3 / 10 Render credential vault"

# Local mode uses a slimmer template (no public hosts, no GitOps section).
if [[ "$OUTPOST_MODE" == "local" ]]; then
  TMPL_BASENAME="INFRA.local.md.template"
else
  TMPL_BASENAME="INFRA.md.template"
fi

for tmpl in "i18n/en/${TMPL_BASENAME}" "i18n/zh-CN/${TMPL_BASENAME}"; do
  [[ -f "$tmpl" ]] || continue
  out_lang="${tmpl#i18n/}"
  out_lang="${out_lang%%/*}"
  if [[ "$out_lang" == "en" ]]; then
    render_template "$tmpl" "INFRA.md"
  else
    render_template "$tmpl" "INFRA.${out_lang}.md"
  fi
done
[[ -f INFRA.md ]] && chmod 600 INFRA.md
[[ -f INFRA.zh-CN.md ]] && chmod 600 INFRA.zh-CN.md
ok "Credential vault(s) rendered"
