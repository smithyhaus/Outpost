# shellcheck shell=bash
# =============================================================================
# Outpost / platform/lib/onboard-lib.sh
# -----------------------------------------------------------------------------
# Pure helpers for the v0.4 onboard primitives — `outpost db create`,
# `outpost seal-from-template`, `outpost manifest scaffold`. Source-only:
# never executed directly. Every function here is side-effect-free except
# onboard_render_subst (which writes its <dst> file); all are unit-tested by
# tests/bats/onboard-lib.bats — same rationale as doctor-checks.sh /
# cel-helpers.sh (testable logic lives in a lib, not inline in the CLI).
#
# Governed by ADR 0002 (docs/decisions/0002-onboarding-primitives-in-platform.md):
# these helpers carry generic onboarding *mechanism* only. No app-specific
# content (secret keys, DB schema, manifest values) is hardcoded here.
#
# bash 3.2-safe (macOS default): no associative arrays, no `mapfile`.
# =============================================================================

# Map an app name to a Postgres-safe database identifier: lowercase, every
# character outside [a-z0-9_] becomes '_'. A leading digit is prefixed with
# 'app_' — Postgres unquoted identifiers cannot start with a digit, and even
# though callers quote the name, a clean identifier avoids surprises in psql
# output and downstream tooling.
onboard_db_name() {
  local raw safe
  raw="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_')"
  case "$raw" in
    [0-9]*) safe="app_${raw}" ;;
    *)      safe="$raw" ;;
  esac
  printf '%s' "$safe"
}

# JSON-escape a string for embedding inside a double-quoted JSON value:
# backslash, double-quote, and control chars (newline/CR/tab → space).
# Copy of doctor.sh's json_esc — kept here so onboard-lib is self-contained.
onboard_json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
}

# Emit one JSON object describing an onboard primitive's result.
#   onboard_emit_json <step> <status> <detail> <next_action> [<file>...]
# `written_files` is built from the 5th argument onward and may be empty
# (`outpost db create` writes no files). Every value is JSON-escaped.
onboard_emit_json() {
  local step="$1" status="$2" detail="$3" next_action="$4"
  shift 4
  local files=("$@")
  local files_json="" first=1 f
  if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
      [[ $first -eq 0 ]] && files_json+=','
      first=0
      files_json+="\"$(onboard_json_esc "$f")\""
    done
  fi
  printf '{"step":"%s","status":"%s","detail":"%s","written_files":[%s],"next_action":"%s"}\n' \
    "$(onboard_json_esc "$step")" \
    "$(onboard_json_esc "$status")" \
    "$(onboard_json_esc "$detail")" \
    "$files_json" \
    "$(onboard_json_esc "$next_action")"
}

# Return 0 if two files exist and are byte-identical, non-zero otherwise.
# Drives `manifest scaffold`'s unchanged-vs-drift decision. A missing file
# (cmp exit 2) counts as "not identical".
onboard_files_identical() {
  cmp -s "$1" "$2" 2>/dev/null
}

# Plain string substitution: read <src>, apply each sed expression in order,
# write <dst>.
#   onboard_render_subst <src> <dst> <sed-expr>...
# Used by `manifest scaffold` — manifests are not env-templated, so this is
# deliberately plain sed, not envsubst (contrast render_template, which is
# for ${VAR} templates and enforces a residue check).
onboard_render_subst() {
  local src="$1" dst="$2"
  shift 2
  if [[ $# -eq 0 ]]; then
    cat "$src" > "$dst"
    return
  fi
  local args=() e
  for e in "$@"; do
    args+=(-e "$e")
  done
  sed "${args[@]}" "$src" > "$dst"
}

# =============================================================================
# outpost.app.yaml helpers — v0.5 `outpost onboard <repo-or-path>` support.
# All require yq (mikefarah, v4+); the project already requires it for
# read-build-config and the kaniko task.
# =============================================================================

# Validate the minimum-required shape of an outpost.app.yaml. Returns 0 if
# the file has the required apiVersion/kind/metadata.name/spec.tier and the
# routes-vs-caddy_fragment exclusion holds; emits one error per missing
# field on stderr and returns 1 otherwise. Pure check — does not render.
onboard_app_validate() {
  local cfg="$1"
  if [[ ! -r "$cfg" ]]; then
    echo "outpost.app: not readable: $cfg" >&2
    return 1
  fi
  local errs=0 v
  v=$(yq -r '.apiVersion // ""' "$cfg")
  if [[ "$v" != "outpost.dev/v1" ]]; then
    echo "outpost.app: apiVersion must be 'outpost.dev/v1' (got: '$v')" >&2
    errs=$((errs + 1))
  fi
  v=$(yq -r '.kind // ""' "$cfg")
  if [[ "$v" != "App" ]]; then
    echo "outpost.app: kind must be 'App' (got: '$v')" >&2
    errs=$((errs + 1))
  fi
  v=$(yq -r '.metadata.name // ""' "$cfg")
  if [[ -z "$v" ]]; then
    echo "outpost.app: metadata.name is required" >&2
    errs=$((errs + 1))
  elif ! [[ "$v" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
    echo "outpost.app: metadata.name '$v' must match ^[a-z][a-z0-9-]{0,62}\$" >&2
    errs=$((errs + 1))
  fi
  v=$(yq -r '.spec.tier // ""' "$cfg")
  case "$v" in
    compose|k3s) : ;;
    "") echo "outpost.app: spec.tier is required (compose|k3s)" >&2; errs=$((errs + 1)) ;;
    *)  echo "outpost.app: spec.tier '$v' must be 'compose' or 'k3s'" >&2; errs=$((errs + 1)) ;;
  esac
  local tier has_routes has_frag
  tier=$(yq -r '.spec.tier // ""' "$cfg")
  has_routes=$(yq -r '(.spec.routes // [] | length) > 0' "$cfg")
  has_frag=$(yq -r '(.spec.caddy_fragment // "") != ""' "$cfg")
  if [[ "$has_routes" == "true" && "$has_frag" == "true" ]]; then
    echo "outpost.app: spec.routes and spec.caddy_fragment are mutually exclusive" >&2
    errs=$((errs + 1))
  fi

  # Tier contract: caddy = stateful infrastructure, k3s = stateless apps.
  # k3s-tier apps expose themselves via Kubernetes IngressRoute in their
  # manifest repo (which gives them the *.apps.<ROOT_DOMAIN> wildcard for
  # free). Caddy fragments here are reserved for stateful infra sidecars.
  # See SKILL.md §7 + docs/onboarding/outpost-app.skill.md for the rationale.
  if [[ "$tier" == "k3s" ]]; then
    if [[ "$has_routes" == "true" ]]; then
      echo "outpost.app: tier=k3s forbids spec.routes — applications expose ingress" >&2
      echo "             via Kubernetes IngressRoute in the manifest repo, not via" >&2
      echo "             Caddy fragments. Move path-based routing into the IngressRoute" >&2
      echo "             generated under apps/<name>/ingress.yaml in your manifests repo." >&2
      errs=$((errs + 1))
    fi
    if [[ "$has_frag" == "true" ]]; then
      echo "outpost.app: tier=k3s forbids spec.caddy_fragment — same rule as routes." >&2
      errs=$((errs + 1))
    fi
  fi

  # tier=compose: routes/hosts must be top-level subdomains. Hosts containing
  # `.apps.` collide with the k3s wildcard (cloudflared → host:30080 →
  # k3s Traefik), so a compose-tier service on `mcp.apps.<root>` would be
  # unreachable: caddy never sees the traffic. Reject early with a clear
  # explanation rather than letting the user debug 502s.
  if [[ "$tier" == "compose" && "$has_routes" == "true" ]]; then
    local bad_host
    bad_host=$(yq -r '[.spec.routes[]?.host // "" | select(test("\\.apps\\.|\\.apps$"))] | .[0] // ""' "$cfg")
    if [[ -n "$bad_host" ]]; then
      echo "outpost.app: tier=compose host '$bad_host' contains '.apps.'" >&2
      echo "             The *.apps.<ROOT_DOMAIN> wildcard belongs to the k3s ingress;" >&2
      echo "             Caddy never sees that traffic. Either:" >&2
      echo "               (a) Use a top-level subdomain: '<prefix>.\${ROOT_DOMAIN}'." >&2
      echo "                   You will need a matching Cloudflare Tunnel Public Hostname." >&2
      echo "               (b) If this is an APPLICATION (not stateful infra), switch to" >&2
      echo "                   spec.tier=k3s — you get the wildcard ingress for free." >&2
      errs=$((errs + 1))
    fi
  fi

  [[ "$errs" -eq 0 ]]
}

# Render the Caddy fragment for one app from its outpost.app.yaml. Writes
# the result to stdout (caller redirects to Caddyfile.d/<name>.caddy).
#
#   onboard_render_caddy_fragment <cfg.yaml>
#
# If spec.caddy_fragment is set, emits it verbatim with a generated header.
# Otherwise walks spec.routes[] and emits the declarative-form translation.
# Routes with a wildcard path (ends in /*) use `handle_path` (auto-strips
# the matched prefix); exact paths use a named `@matcher` + `handle`. The
# rewrite/rewrite_path_prefix/upstream semantics mirror the JSON schema.
onboard_render_caddy_fragment() {
  local cfg="$1"
  local name fragment src_hint
  name=$(yq -r '.metadata.name' "$cfg")
  src_hint=$(basename "$cfg")
  fragment=$(yq -r '.spec.caddy_fragment // ""' "$cfg")
  printf '# Generated by `outpost onboard` from %s — do not edit by hand.\n' "$src_hint"
  printf '# App: %s\n\n' "$name"
  if [[ -n "$fragment" ]]; then
    printf '%s\n' "$fragment"
    return 0
  fi
  # Caddy matcher identifiers allow [a-zA-Z0-9_], not hyphens.
  local slug
  slug=$(printf '%s' "$name" | tr '-' '_')
  local route_count
  route_count=$(yq -r '(.spec.routes // []) | length' "$cfg")
  if [[ "$route_count" -eq 0 ]]; then
    printf '# (no routes declared)\n'
    return 0
  fi
  local i j host default_upstream rule_count
  for ((i = 0; i < route_count; i++)); do
    host=$(yq -r ".spec.routes[$i].host" "$cfg")
    default_upstream=$(yq -r ".spec.routes[$i].default_upstream // \"\"" "$cfg")
    rule_count=$(yq -r "(.spec.routes[$i].rules // []) | length" "$cfg")
    local host_matcher="${slug}_host_${i}"
    printf '@%s host %s\n' "$host_matcher" "$host"
    printf 'handle @%s {\n' "$host_matcher"
    for ((j = 0; j < rule_count; j++)); do
      local upstream rewrite rpp_old rpp_new path_list rule_matcher
      upstream=$(yq -r ".spec.routes[$i].rules[$j].upstream" "$cfg")
      rewrite=$(yq -r ".spec.routes[$i].rules[$j].rewrite // \"\"" "$cfg")
      rpp_old=$(yq -r ".spec.routes[$i].rules[$j].rewrite_path_prefix[0] // \"\"" "$cfg")
      rpp_new=$(yq -r ".spec.routes[$i].rules[$j].rewrite_path_prefix[1] // \"\"" "$cfg")
      path_list=$(yq -r ".spec.routes[$i].rules[$j].path[]?" "$cfg" | tr '\n' ' ')
      rule_matcher="${slug}_h${i}_r${j}"
      # Always use `path` matcher (not `handle_path`) — handle_path's
      # auto-strip-matched-prefix collides badly with rewrite_path_prefix
      # when the two prefixes differ. Explicit `uri strip_prefix` /
      # `uri replace` directives give predictable behavior.
      if [[ -n "$path_list" ]]; then
        printf '    @%s path %s\n' "$rule_matcher" "$path_list"
        printf '    handle @%s {\n' "$rule_matcher"
      else
        printf '    handle {\n'
      fi
      if [[ -n "$rewrite" ]]; then
        # Full URI replacement (sees all paths in this matcher get rewritten
        # to a single string). Use sparingly — only when every match should
        # collapse to the same upstream URI.
        printf '        rewrite * %s\n' "$rewrite"
      elif [[ -n "$rpp_old" ]]; then
        if [[ -z "$rpp_new" ]]; then
          # Strip-only: /api/v1/foo → /foo (when rpp_old=/api/v1).
          printf '        uri strip_prefix %s\n' "$rpp_old"
        else
          # Prefix swap: /api/v1/foo → /v2/foo (when rpp_old=/api/v1, rpp_new=/v2).
          # The trailing `1` limits replacement to the first occurrence.
          printf '        uri replace %s %s 1\n' "$rpp_old" "$rpp_new"
        fi
      fi
      printf '        reverse_proxy %s\n' "$upstream"
      printf '    }\n'
    done
    if [[ -n "$default_upstream" ]]; then
      printf '    handle {\n'
      printf '        reverse_proxy %s\n' "$default_upstream"
      printf '    }\n'
    fi
    printf '}\n'
    if (( i < route_count - 1 )); then
      printf '\n'
    fi
  done
}

# Render a docker-compose override snippet describing one app's compose
# service. Emitted as a complete compose file with a single `services:`
# entry under `metadata.name`. Caller drops this at
# `core/compose/overrides/<name>.yml`; loaded via `-f` chain or COMPOSE_FILE.
onboard_render_compose_override() {
  local cfg="$1"
  local name image container_name
  name=$(yq -r '.metadata.name' "$cfg")
  image=$(yq -r '.spec.compose.image // ""' "$cfg")
  container_name=$(yq -r ".spec.compose.container_name // \"$name\"" "$cfg")
  if [[ -z "$image" ]]; then
    echo "onboard_render_compose_override: spec.compose.image is required for tier=compose" >&2
    return 1
  fi
  printf '# Generated by `outpost onboard` for app: %s — do not edit by hand.\n' "$name"
  printf '# Loaded via: COMPOSE_FILE=docker-compose.yml:overrides/%s.yml\n' "$name"
  printf 'name: infra\n'
  printf 'services:\n'
  printf '  %s:\n' "$name"
  printf '    image: %s\n' "$image"
  printf '    container_name: %s\n' "$container_name"
  printf '    restart: unless-stopped\n'
  printf '    networks: [infra]\n'

  local i p
  local ports_count
  ports_count=$(yq -r '(.spec.compose.ports // []) | length' "$cfg")
  if [[ "$ports_count" -gt 0 ]]; then
    printf '    ports:\n'
    for ((i = 0; i < ports_count; i++)); do
      p=$(yq -r ".spec.compose.ports[$i]" "$cfg")
      printf '      - "%s"\n' "$p"
    done
  fi

  local env_keys env_key env_val efo_count
  env_keys=$(yq -r '(.spec.compose.env // {}) | keys | .[]?' "$cfg")
  efo_count=$(yq -r '(.spec.compose.env_from_outpost // []) | length' "$cfg")
  if [[ -n "$env_keys" || "$efo_count" -gt 0 ]]; then
    printf '    environment:\n'
    if [[ -n "$env_keys" ]]; then
      while IFS= read -r env_key; do
        [[ -z "$env_key" ]] && continue
        env_val=$(yq -r ".spec.compose.env[\"$env_key\"]" "$cfg")
        printf '      %s: %s\n' "$env_key" "$env_val"
      done <<< "$env_keys"
    fi
    for ((i = 0; i < efo_count; i++)); do
      env_key=$(yq -r ".spec.compose.env_from_outpost[$i]" "$cfg")
      printf '      %s: ${%s}\n' "$env_key" "$env_key"
    done
  fi

  local vol_count
  vol_count=$(yq -r '(.spec.compose.volumes // []) | length' "$cfg")
  if [[ "$vol_count" -gt 0 ]]; then
    printf '    volumes:\n'
    for ((i = 0; i < vol_count; i++)); do
      p=$(yq -r ".spec.compose.volumes[$i]" "$cfg")
      printf '      - %s\n' "$p"
    done
  fi

  local dep_count
  dep_count=$(yq -r '(.spec.compose.depends_on // []) | length' "$cfg")
  if [[ "$dep_count" -gt 0 ]]; then
    printf '    depends_on:\n'
    for ((i = 0; i < dep_count; i++)); do
      p=$(yq -r ".spec.compose.depends_on[$i]" "$cfg")
      printf '      - %s\n' "$p"
    done
  fi
}
