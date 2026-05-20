# shellcheck shell=bash
# =============================================================================
# Outpost / platform/lib/doctor-checks.sh
# -----------------------------------------------------------------------------
# Pure precondition-check helpers for doctor.sh. Source-only — never executed.
# Each function is side-effect-free and unit-tested by
# tests/bats/doctor-checks.bats — that is why the logic lives here, not inline
# in doctor.sh (same rationale as registry-config.sh / cel-helpers.sh).
# =============================================================================

# Is a TCP port accepting connections on localhost? Echoes "busy" or "free".
# Uses bash /dev/tcp — no lsof / nc dependency.
doctor_port_state() {
  local port="$1"
  if (echo >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    echo "busy"
  else
    echo "free"
  fi
}

# Best-effort "what holds this port" string for a fix_hint (e.g.
# "postgres (127.0.0.1:5432)"). Empty string when lsof is absent or finds
# nothing — callers must tolerate an empty result.
doctor_port_holder() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || { echo ""; return; }
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN -Fcn 2>/dev/null \
    | awk '/^c/{c=substr($0,2)} /^n/{print c" ("substr($0,2)")"; exit}'
}

# Does CF_TUNNEL_TOKEN look like a Cloudflare tunnel token?
# Real tokens are a long base64url string (>= 80 chars, [A-Za-z0-9_=-]).
# Echoes "valid" or "invalid". Empty / short / junk input → "invalid".
doctor_cf_token_state() {
  local tok="$1"
  if [[ -n "$tok" && ${#tok} -ge 80 && "$tok" =~ ^[A-Za-z0-9_=-]+$ ]]; then
    echo "valid"
  else
    echo "invalid"
  fi
}

# Does a hostname resolve via DNS? Echoes "ok" or "nxdomain".
# Tries getent (Linux), then host, then nslookup — whichever exists.
doctor_dns_state() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1 && { echo "ok"; return; }
  fi
  if command -v host >/dev/null 2>&1; then
    host -W 3 "$host" >/dev/null 2>&1 && { echo "ok"; return; }
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" >/dev/null 2>&1 && { echo "ok"; return; }
  fi
  echo "nxdomain"
}
