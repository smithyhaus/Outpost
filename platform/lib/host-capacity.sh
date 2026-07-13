# shellcheck shell=bash
# =============================================================================
# Host capacity detection — feeds the dynamic apps-quota defaults.
# -----------------------------------------------------------------------------
# All functions are best-effort + portable across macOS (Darwin sysctl) and
# Linux (nproc / /proc/meminfo / free). On unrecognised platforms they emit
# conservative fallback numbers — never zero — so render_template won't
# explode and the bootstrap can still proceed.
#
# Auto-detection can ALWAYS be overridden by setting OUTPOST_APPS_* env
# vars before bootstrap.sh runs (see bootstrap.d/02-config.sh).
#
# Bats unit tests exercise the math with OUTPOST_HOST_CPU_OVERRIDE +
# OUTPOST_HOST_MEM_GB_OVERRIDE so the formulas don't drift silently.
# =============================================================================

# Return the host's vCPU count.
# Override for tests: OUTPOST_HOST_CPU_OVERRIDE=<int>
host_cpu_count() {
  if [[ -n "${OUTPOST_HOST_CPU_OVERRIDE:-}" ]]; then
    echo "${OUTPOST_HOST_CPU_OVERRIDE}"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) sysctl -n hw.ncpu 2>/dev/null || echo 4 ;;
    Linux)
      if command -v nproc >/dev/null 2>&1; then
        nproc
      else
        grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4
      fi
      ;;
    *) echo 4 ;;
  esac
}

# Return the host's physical RAM in whole GiB (rounded down).
# Override for tests: OUTPOST_HOST_MEM_GB_OVERRIDE=<int>
host_mem_gb() {
  if [[ -n "${OUTPOST_HOST_MEM_GB_OVERRIDE:-}" ]]; then
    echo "${OUTPOST_HOST_MEM_GB_OVERRIDE}"
    return 0
  fi
  local bytes=""
  case "$(uname -s)" in
    Darwin)
      bytes="$(sysctl -n hw.memsize 2>/dev/null)"
      ;;
    Linux)
      # /proc/meminfo is most universally available (no `free` dependency).
      local kb
      kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
      [[ -n "$kb" ]] && bytes=$(( kb * 1024 ))
      ;;
  esac
  if [[ -n "$bytes" && "$bytes" -gt 0 ]]; then
    echo $(( bytes / 1024 / 1024 / 1024 ))
  else
    echo 8  # conservative fallback
  fi
}

# Floor utility: returns max(floor, value). Both args must be integers.
_max() {
  local a="$1" b="$2"
  if (( a > b )); then echo "$a"; else echo "$b"; fi
}

# Derive ResourceQuota defaults from host capacity.
# CPU overcommits cleanly in K8s → limits.cpu can be 2× host;
# memory does NOT overcommit safely → limits.memory is sized from what is
# LEFT after the build engine's share, not from the raw host total. The old
# 3/4-of-host formula ignored buildkitd's 24Gi limit: on a 48GB host it
# granted apps 36Gi while buildkitd could take 24Gi — 60Gi of admissible
# limits on a 48GB machine (measured overcommit during the fleet-build OOM
# incident). Reserve = half the host, capped at 24Gi (buildkitd's limit in
# core/k8s/08-buildkit/deployment.yaml — keep the two in sync).
# Floor guarantees prevent tiny machines from getting non-functional quota.
#
# Outputs (echoed one per line, for capture into env vars):
#   <pods> <req_cpu> <lim_cpu> <req_mem_gi> <lim_mem_gi>
apps_quota_defaults() {
  local cpu mem_gb
  cpu="$(host_cpu_count)"
  mem_gb="$(host_mem_gb)"

  # CPU: requests = half of host, limits = double of host.
  local req_cpu lim_cpu
  req_cpu=$(_max "$(( cpu / 2 ))" 1)
  lim_cpu=$(( cpu * 2 ))

  # Memory: carve out the build-engine reserve first, then requests = 1/4 and
  # limits = 3/4 of the REMAINDER. Floors at 1Gi / 3Gi.
  local reserve_gi effective_gb req_mem_gi lim_mem_gi
  reserve_gi=$(( mem_gb / 2 ))
  (( reserve_gi > 24 )) && reserve_gi=24
  effective_gb=$(( mem_gb - reserve_gi ))
  req_mem_gi=$(_max "$(( effective_gb / 4 ))" 1)
  lim_mem_gi=$(_max "$(( effective_gb * 3 / 4 ))" 3)

  # Pods is host-independent — fixed default.
  echo "50 ${req_cpu} ${lim_cpu} ${req_mem_gi} ${lim_mem_gi}"
}
