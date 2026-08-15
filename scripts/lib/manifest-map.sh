# shellcheck shell=sh
# =============================================================================
# scripts/lib/manifest-map.sh — repo-name → manifest apps/<dir> resolution.
# -----------------------------------------------------------------------------
# Single source of truth for the naming convention between application REPO
# names and their directory inside the manifest repo. Extracted from
# scripts/update-manifest.sh (v0.3.0) so three consumers share ONE mapping:
#   - scripts/update-manifest.sh   (CI: bump image tag after a build)
#   - scripts/outpost rollback     (rewrite the manifest to an older tag)
#   - verify.sh reconciliation     (live HEAD vs deployed tag, per repo)
#
# The convention (learned from the fleet, do not "simplify"):
#   The repo name often carries an `fst-` prefix or `-web` suffix that the
#   manifest dir drops (fst-product-service -> product-service,
#   fst-admin-web -> fst-admin, fst-bff-ops -> bff-ops). The BFFs live INSIDE
#   their frontend's app dir (fst-bff-admin -> apps/fst-admin,
#   fst-bff-miniapp -> apps/fst-miniapp), hence the fst-bff-* -> fst-*
#   variant. Candidates are tried in order; first existing dir wins.
#
# POSIX sh (sourced by /bin/sh scripts AND bash callers; also bash-3.2 safe).
# =============================================================================

# manifest_app_dir_candidates <app_name>
# -----------------------------------------------------------------------------
# Echo the ordered candidate dir names (one per line, WITHOUT the apps/
# prefix). Duplicates are possible (e.g. a name with no fst-/-web affixes
# yields the same candidate 4 times) — resolve_manifest_app_dir stops at the
# first hit, so that's harmless; error messages dedupe for readability.
manifest_app_dir_candidates() {
  _mm_app="${1:?manifest_app_dir_candidates: app name required}"
  _mm_bff=$(printf '%s' "$_mm_app" | sed 's/^fst-bff-/fst-/')
  printf '%s\n' "$_mm_app" "${_mm_app#fst-}" "${_mm_app%-web}" "$_mm_bff"
}

# resolve_manifest_app_dir <app_name> [<manifest_root>]
# -----------------------------------------------------------------------------
# Echo the RELATIVE manifest dir ("apps/<dir>") for <app_name>, resolved
# against <manifest_root> (default: current directory). Returns 1 (nothing
# echoed) when no candidate dir exists — the caller owns the error message
# (each caller has different remediation advice).
resolve_manifest_app_dir() {
  _mm_app="${1:?resolve_manifest_app_dir: app name required}"
  _mm_root="${2:-.}"
  for _mm_cand in $(manifest_app_dir_candidates "$_mm_app"); do
    if [ -d "$_mm_root/apps/$_mm_cand" ]; then
      printf 'apps/%s\n' "$_mm_cand"
      return 0
    fi
  done
  return 1
}
