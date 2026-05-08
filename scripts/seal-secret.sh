#!/bin/sh
# =============================================================================
# seal-secret.sh — 把一份明文 K8s Secret 加密成 SealedSecret,可安全入 git。
#
# 用法:
#   scripts/seal-secret.sh -i plain.yaml -o sealed.yaml
#   cat plain.yaml | scripts/seal-secret.sh > sealed.yaml
#   scripts/seal-secret.sh --in-place sealed.yaml         # 覆盖原文件
#
# 选项:
#   -i, --input <file>     明文 Secret yaml 路径(默认 stdin)
#   -o, --output <file>    输出 SealedSecret 路径(默认 stdout)
#   --in-place <file>      原地加密(读 file → 加密 → 写回 file)
#   -n, --controller-ns    sealed-secrets controller namespace(默认 kube-system)
#   -h, --help             显示帮助
#
# 前置:
#   - kubeseal 已装(bootstrap.sh 会装)
#   - kubectl 已连上集群,sealed-secrets controller 已运行
#
# 安全提示:
#   ! 永远不要把明文 yaml 提交到 git。建议先 cp 到 /tmp/,加密完立刻 rm。
#   ! 本脚本退出前不会主动删除明文,你自己负责。
# =============================================================================
set -eu

CONTROLLER_NS="kube-system"
INPUT=""
OUTPUT=""
IN_PLACE=""

usage() { sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)            INPUT="$2"; shift 2 ;;
    -o|--output)           OUTPUT="$2"; shift 2 ;;
    --in-place)            IN_PLACE="$2"; shift 2 ;;
    -n|--controller-ns)    CONTROLLER_NS="$2"; shift 2 ;;
    -h|--help)             usage 0 ;;
    *)  echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

# ---- 前置检查 ----------------------------------------------------------------
command -v kubeseal >/dev/null 2>&1 || {
  echo "ERROR: kubeseal not found. 请先跑 bootstrap.sh,或:" >&2
  echo "  brew install kubeseal     # macOS" >&2
  echo "  https://github.com/bitnami-labs/sealed-secrets/releases" >&2
  exit 2
}
command -v kubectl  >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 2; }

# 检查 controller 在运行
if ! kubectl -n "$CONTROLLER_NS" get deploy -l name=sealed-secrets-controller \
       --no-headers 2>/dev/null | grep -q .; then
  echo "ERROR: sealed-secrets controller 不在 namespace=$CONTROLLER_NS 中。" >&2
  echo "       确认集群连接 + 装了 sealed-secrets:  bash bootstrap.sh" >&2
  exit 2
fi

# ---- 模式互斥 ----------------------------------------------------------------
if [ -n "$IN_PLACE" ] && { [ -n "$INPUT" ] || [ -n "$OUTPUT" ]; }; then
  echo "ERROR: --in-place 与 -i/-o 互斥" >&2
  exit 1
fi

# ---- 解析输入 ----------------------------------------------------------------
TMP_IN="$(mktemp)"
trap 'rm -f "$TMP_IN" "${TMP_OUT:-}"' EXIT

if [ -n "$IN_PLACE" ]; then
  [ -f "$IN_PLACE" ] || { echo "ERROR: $IN_PLACE 不存在" >&2; exit 1; }
  cp "$IN_PLACE" "$TMP_IN"
  OUTPUT="$IN_PLACE"
elif [ -n "$INPUT" ]; then
  [ -f "$INPUT" ] || { echo "ERROR: $INPUT 不存在" >&2; exit 1; }
  cp "$INPUT" "$TMP_IN"
else
  cat > "$TMP_IN"
fi

# ---- 校验是 Secret 而不是其它资源 -------------------------------------------
if ! grep -qE '^kind:[[:space:]]+Secret[[:space:]]*$' "$TMP_IN"; then
  echo "ERROR: 输入不是 kind: Secret(可能是 SealedSecret 或别的)" >&2
  exit 1
fi

# ---- 加密 -------------------------------------------------------------------
TMP_OUT="$(mktemp)"
kubeseal \
  --controller-namespace="$CONTROLLER_NS" \
  --controller-name="sealed-secrets-controller" \
  --format=yaml \
  < "$TMP_IN" > "$TMP_OUT" 2> >(tee /dev/stderr | grep -q . && true)

if ! grep -q '^kind: SealedSecret' "$TMP_OUT"; then
  echo "ERROR: kubeseal 返回的不是 SealedSecret,请检查 controller 日志:" >&2
  echo "  kubectl -n $CONTROLLER_NS logs -l name=sealed-secrets-controller --tail=50" >&2
  exit 3
fi

# ---- 输出 -------------------------------------------------------------------
if [ -n "$OUTPUT" ]; then
  mv "$TMP_OUT" "$OUTPUT"
  echo "✓ SealedSecret written to: $OUTPUT" >&2
else
  cat "$TMP_OUT"
fi

# ---- 提醒清理明文 -----------------------------------------------------------
if [ -n "$INPUT" ] && [ "$INPUT" != "/dev/stdin" ]; then
  echo "" >&2
  echo "⚠ 记得删除明文文件: rm $INPUT" >&2
fi
