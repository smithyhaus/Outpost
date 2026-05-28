#!/bin/sh
# =============================================================================
# Registry tag prune + blob GC — runs INSIDE the docker-registry pod.
# -----------------------------------------------------------------------------
# Invocation:
#   The outer CronJob (registry-gc) uses `kubectl exec` to inject this
#   script's content via stdin into the registry pod and run it there.
#   The script has direct filesystem access to the registry storage volume
#   (faster + simpler than HTTP API for tag enumeration) AND the `registry`
#   binary for blob GC.
#
# Two-step cleanup:
#   1. Per-repo tag retention — keep N most recent (by FS mtime) tags,
#      DELETE the rest via the registry HTTP API. DELETE just removes the
#      tag → manifest reference; the underlying blobs become orphaned.
#   2. Blob garbage-collect — `registry garbage-collect --delete-untagged`
#      walks the storage and removes blobs no tag references.
#
# Without DELETE_ENABLED in the registry config, step 1 returns 405 and
# the script aborts; the registry plugin manifest sets this to "true" so
# the GC works out of the box.
#
# Tunables (env, set by the CronJob):
#   OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO   default 5
# =============================================================================
set -eu

KEEP_N="${OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO:-5}"
ROOT=/var/lib/registry/docker/registry/v2/repositories
REG_URL=http://localhost:5000

now="$(date -u +%FT%TZ)"
echo "[${now}] registry-gc: starting (keep ${KEEP_N} most-recent tags per repo)"

if [ ! -d "$ROOT" ]; then
  echo "[${now}] registry-gc: storage path ${ROOT} not present — nothing to do"
  exit 0
fi

# Capture initial disk usage for the summary at the end.
before=$(du -sh /var/lib/registry 2>/dev/null | awk '{print $1}')

deleted_tags=0
deleted_repos=0

# Walk every <repo>/_manifests/tags directory. find handles nested repo
# names (e.g. project/subapp) by going as deep as needed.
find "$ROOT" -type d -name tags 2>/dev/null | while read tags_dir; do
  # The repo path is everything between $ROOT/ and /_manifests/tags.
  manifests_dir="${tags_dir%/tags}"
  repo_path="${manifests_dir%/_manifests}"
  repo_name="${repo_path#${ROOT}/}"

  # Count existing tags. ls -t sorts newest-first by mtime.
  total=$(ls "$tags_dir" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$total" -le "$KEEP_N" ]; then
    echo "[${now}] registry-gc: ${repo_name}: ${total} tag(s) — under cap, skipping"
    continue
  fi

  excess=$(( total - KEEP_N ))
  echo "[${now}] registry-gc: ${repo_name}: ${total} tags, keeping ${KEEP_N}, deleting ${excess} oldest"

  # Take the tail (oldest) tags after the top KEEP_N.
  ls -t "$tags_dir" 2>/dev/null | tail -n "+$((KEEP_N + 1))" | while read tag; do
    link_file="${tags_dir}/${tag}/current/link"
    if [ ! -f "$link_file" ]; then
      echo "[${now}] registry-gc:   ${repo_name}:${tag} — no current/link, skipping"
      continue
    fi
    digest=$(cat "$link_file")
    # DELETE via raw HTTP. The registry:2 image (alpine) ships ONLY busybox
    # — busybox wget lacks --method=DELETE; curl is not installed. nc is
    # available and the registry protocol is simple enough to speak raw.
    # `-w 3` caps the wait at 3s so a slow registry can't hang the loop.
    code=$(printf 'DELETE /v2/%s/manifests/%s HTTP/1.1\r\nHost: localhost:5000\r\nConnection: close\r\n\r\n' \
      "$repo_name" "$digest" \
      | nc -w 3 localhost 5000 2>/dev/null \
      | awk 'NR==1 {print $2+0; exit}')
    case "$code" in
      202) echo "[${now}] registry-gc:   ${repo_name}:${tag} deleted (${digest})"
           deleted_tags=$((deleted_tags + 1))
           ;;
      404) echo "[${now}] registry-gc:   ${repo_name}:${tag} already gone (404)" ;;
      405) echo "[${now}] registry-gc:   FATAL — DELETE returned 405; ensure REGISTRY_STORAGE_DELETE_ENABLED=true"
           exit 2
           ;;
      0)   echo "[${now}] registry-gc:   ${repo_name}:${tag} delete failed (network/exec error)" ;;
      *)   echo "[${now}] registry-gc:   ${repo_name}:${tag} delete failed (HTTP ${code})" ;;
    esac
  done
  deleted_repos=$((deleted_repos + 1))
done

# Step 2: blob garbage-collect. --delete-untagged also reclaims storage for
# manifests that lost their last tag reference in step 1.
echo "[${now}] registry-gc: running blob garbage-collect..."
if registry garbage-collect /etc/docker/registry/config.yml --delete-untagged 2>&1 | tail -5; then
  echo "[${now}] registry-gc: garbage-collect succeeded"
else
  echo "[${now}] registry-gc: garbage-collect reported errors (non-fatal)"
fi

after=$(du -sh /var/lib/registry 2>/dev/null | awk '{print $1}')
echo "[${now}] registry-gc: done (disk: ${before} → ${after})"
