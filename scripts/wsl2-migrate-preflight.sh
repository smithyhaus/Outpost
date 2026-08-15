#!/usr/bin/env bash
# =============================================================================
# wsl2-migrate-preflight.sh — Outpost 迁移前的 WSL2 自动预检 + 代理自配。
# -----------------------------------------------------------------------------
# 在【新的 WSL2】里运行（阶段 2 在线安装【之前】）。它会自己去取数据：
#   • 探测 systemd 是否就绪
#   • 探测 WSL 网络模式（mirrored / nat）
#   • 从 Windows 注册表读出系统代理端口（不用你手填 1081）
#   • 实测拉 install.sh 真实 URL，自动选出一个可用的出网路径（直连 or v2ray 代理）
#   • 用【探到的端口】写好 docker / k3s / apt 三层代理 drop-in
#   • 给出 GO / NO-GO 结论
#   • （GO 后可选）交互式收集外部绑定值，当场跑阶段 2 在线安装
#
# 默认只读探测 + 写代理配置，不含任何密钥、不碰 Mac；仅当你在结尾【显式确认 y】，
# 才用你当场隐藏输入的值跑阶段 2 在线安装（值只在内存里，不写盘、不入库、不打日志）。
# 幂等：可反复运行。需要 sudo 写 /etc/systemd 与 /etc/apt。
#
#   用法:  bash wsl2-migrate-preflight.sh
# =============================================================================
set -uo pipefail   # 故意不开 -e：单项失败要继续往下诊断，最后统一给结论

# ---- 输出辅助 ---------------------------------------------------------------
if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=''; R=''; Y=''; B=''; D=''; N=''
fi
say()  { printf '%s\n' "$*"; }
hd()   { printf '\n%s\n' "${B}== $* ==${N}"; }
ok()   { printf '%s\n' "  ${G}✓${N} $*"; }
no()   { printf '%s\n' "  ${R}✗${N} $*"; }
warn() { printf '%s\n' "  ${Y}!${N} $*"; }

SUDO=''; [[ ${EUID:-$(id -u)} -ne 0 ]] && SUDO='sudo'

# install.sh 真正会拉的 URL —— 用它探测是最强信号（直接证明安装路径能通）
TARGET='https://raw.githubusercontent.com/smithyhaus/Outpost/main/VERSION'
probe() { curl -fsS --connect-timeout 3 -m 8 -o /dev/null "$@" "$TARGET" 2>/dev/null; }

PROXY=''        # 最终选定的代理 URL（空 = 直连可用 / 或没探到）
DIRECT_OK=0
SYSTEMD_OK=0
MODE='unknown'
REG_PORT=''

# ---- 0. 基本环境 ------------------------------------------------------------
hd "0. 基本环境"
say "  内核:   $(uname -r)"
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  ok "运行在 WSL2"
else
  warn "看起来不在 WSL2（脚本是为 WSL2 写的，仍会继续）"
fi
[[ -r /etc/os-release ]] && say "  发行版: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
say "  内存:   $(awk '/MemTotal/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null)    CPU: $(nproc 2>/dev/null) 线程"

# ---- 1. systemd -------------------------------------------------------------
hd "1. systemd（docker / k3s 自启动依赖；没它 bootstrap 必失败）"
if [[ -d /run/systemd/system ]]; then
  SYSTEMD_OK=1
  ok "systemd 是 init（/run/systemd/system 存在）"
  say "  状态: $(systemctl is-system-running 2>/dev/null || true)  ${D}(running 或 degraded 都行)${N}"
else
  no "systemd 不是 init。修复："
  say "      printf '[boot]\\nsystemd=true\\n' | sudo tee /etc/wsl.conf"
  say "      回 PowerShell 跑  wsl --shutdown，重进 WSL 后再跑本脚本"
fi

# ---- 2. WSL 网络模式 --------------------------------------------------------
hd "2. WSL 网络模式（决定 127.0.0.1 能否直达 Windows v2ray）"
command -v wslinfo >/dev/null 2>&1 && MODE="$(wslinfo --networking-mode 2>/dev/null || echo unknown)"
GW="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
NS="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)"
case "$MODE" in
  mirrored) ok "networkingMode = mirrored —— WSL 的 127.0.0.1 直达 Windows v2ray（推荐）" ;;
  nat)      warn "networkingMode = nat —— 127.0.0.1 不通 Windows，将改用宿主 IP（${GW:-未知}）。建议 .wslconfig 改 mirrored" ;;
  *)        warn "无法确定网络模式（wslinfo 不可用或旧版 WSL）—— 127.0.0.1 与宿主 IP 都会试" ;;
esac
[[ -n "${GW:-}" ]] && say "  默认网关:           $GW"
[[ -n "${NS:-}" ]] && say "  resolv nameserver:  $NS"

# ---- 3. Windows 系统代理（从注册表读端口，免你手填）------------------------
hd "3. Windows 系统代理（注册表 ProxyServer）"
if command -v reg.exe >/dev/null 2>&1; then
  RK='HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  REG_ON="$(reg.exe query "$RK" /v ProxyEnable 2>/dev/null | tr -d '\r' | awk '/ProxyEnable/{print $NF}')"
  PS="$(reg.exe query "$RK" /v ProxyServer  2>/dev/null | tr -d '\r' | awk '/ProxyServer/{print $NF}')"
  if [[ "$PS" == *http=* ]]; then
    REG_PORT="$(printf '%s' "$PS" | sed -n 's/.*http=[^:]*:\([0-9][0-9]*\).*/\1/p')"
  elif [[ "$PS" == *:* ]]; then
    REG_PORT="${PS##*:}"
  fi
  [[ "$REG_PORT" =~ ^[0-9]+$ ]] || REG_PORT=''
  say "  ProxyEnable = ${REG_ON:-?}  ${D}(0x1=开, 0x0=关)${N}   ProxyServer = ${PS:-未设置}"
  if [[ "${REG_ON:-}" == "0x0" || "${REG_ON:-}" == "0" ]]; then
    warn "系统代理当前【关闭】—— 在 v2ray 里勾「设置系统代理 / 全局模式」探测会更准"
  fi
  [[ -n "$REG_PORT" ]] && ok "注册表端口: $REG_PORT（优先试它）"
else
  warn "reg.exe 不可用（WSL interop 可能被关）—— 跳过注册表，直接端口探测"
fi

# ---- 4. 自动探测可用出网路径 ------------------------------------------------
hd "4. 探测出网（实测拉 install.sh 的真实 URL）"
if probe; then
  DIRECT_OK=1
  ok "直连可达 GitHub —— 本机不需要代理"
else
  warn "直连不通 GitHub —— 开始探测 v2ray 代理"
  hosts=(127.0.0.1)
  [[ -n "${GW:-}" ]] && hosts+=("$GW")
  [[ -n "${NS:-}" && "$NS" != "${GW:-}" ]] && hosts+=("$NS")
  ports=()
  [[ -n "$REG_PORT" ]] && ports+=("$REG_PORT")
  for p in 10809 7890 1081 1080 2080 8889 10811 7891 1087 8080 8118; do
    [[ " ${ports[*]} " == *" $p "* ]] || ports+=("$p")
  done
  for h in "${hosts[@]}"; do
    for p in "${ports[@]}"; do
      if probe -x "http://$h:$p"; then PROXY="http://$h:$p"; break 2; fi
    done
  done
  if [[ -n "$PROXY" ]]; then
    ok "找到可用代理: ${B}$PROXY${N}"
  else
    no "所有候选都不通。逐项排查："
    say "      • v2ray 在跑吗？勾了「设置系统代理 / 全局」吗？勾了「允许来自局域网的连接」吗？"
    say "      • 网络模式是不是 mirrored（见第 2 节）？NAT 下要确保 v2ray 允许 LAN 且宿主 IP 正确"
    say "      • 试的端口是不是 v2ray 的 HTTP 入站口（不是 SOCKS 口）？"
  fi
fi

# ---- 5. 写代理 drop-in（仅当探到代理）--------------------------------------
hd "5. 写入 docker / k3s / apt 代理"
if [[ -n "$PROXY" ]]; then
  NP_DOCKER='localhost,127.0.0.1,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local'
  NP_K3S='localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local'
  $SUDO mkdir -p /etc/systemd/system/docker.service.d /etc/systemd/system/k3s.service.d
  printf '[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' \
    "$PROXY" "$PROXY" "$NP_DOCKER" | $SUDO tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
  printf '[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' \
    "$PROXY" "$PROXY" "$NP_K3S" | $SUDO tee /etc/systemd/system/k3s.service.d/http-proxy.conf >/dev/null
  printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" \
    | $SUDO tee /etc/apt/apt.conf.d/95proxy >/dev/null
  $SUDO systemctl daemon-reload 2>/dev/null || true
  systemctl is-active --quiet docker 2>/dev/null && $SUDO systemctl restart docker 2>/dev/null || true
  systemctl is-active --quiet k3s    2>/dev/null && $SUDO systemctl restart k3s    2>/dev/null || true
  ok "已写 docker drop-in / k3s drop-in / apt 95proxy（端口=$PROXY；服务装好后自动生效）"

  ENV_FILE="$HOME/.outpost-proxy.env"
  cat > "$ENV_FILE" <<EOF
# 由 wsl2-migrate-preflight.sh 生成 —— 跑在线安装前先: source ~/.outpost-proxy.env
export http_proxy=$PROXY
export https_proxy=$PROXY
export HTTP_PROXY=$PROXY
export HTTPS_PROXY=$PROXY
export no_proxy=localhost,127.0.0.1,::1,gitee.com,git.gitee.com,.svc,.cluster.local
export NO_PROXY=\$no_proxy
EOF
  ok "已写 $ENV_FILE（autoProxy 没注入时的确定性兜底）"
else
  if [[ "$DIRECT_OK" == "1" ]]; then ok "直连可用，跳过代理写入"; else warn "没探到代理，跳过写入（先解决第 4 节问题再重跑）"; fi
fi

# ---- 6. 复验 ----------------------------------------------------------------
hd "6. 复验"
if [[ "$DIRECT_OK" == "1" ]]; then
  ok "直连出网正常"
elif [[ -n "$PROXY" ]]; then
  probe -x "$PROXY" && ok "经 $PROXY 出网正常" || no "复验失败，代理可能不稳定"
fi
if [[ -n "${https_proxy:-}" ]]; then
  ok "autoProxy 已注入 shell：https_proxy=$https_proxy"
else
  warn "当前 shell 未设 https_proxy（autoProxy 未生效）—— 用 source ~/.outpost-proxy.env 兜底"
fi

# ---- 结论 GO / NO-GO --------------------------------------------------------
hd "结论"
GO=1
[[ "$SYSTEMD_OK" == "1" ]] || { GO=0; no "systemd 未就绪（见第 1 节）"; }
[[ "$DIRECT_OK" == "1" || -n "$PROXY" ]] || { GO=0; no "没有可用出网路径（见第 4 节）"; }

if [[ "$GO" != "1" ]]; then
  say ""
  say "${R}${B}  NO-GO —— 先修上面标 ✗ 的项，再重跑本脚本（幂等）。${N}"
  exit 1
fi

say ""
say "${G}${B}  GO —— 预检通过，可进入阶段 2 在线安装。${N}"

# ---- 7. 阶段 2 — 在线安装（可选，交互式；默认不装）-------------------------
# 没有可交互的 tty（脚本被管道喂入等）就退回"手动安装"提示，绝不盲跑。
if [[ ! -e /dev/tty ]]; then
  say "  下一步（同一个 shell 里手动跑）："
  [[ -n "$PROXY" ]] && say "    ${D}source ~/.outpost-proxy.env${N}"
  say "    再粘贴阶段 2 的一行式安装命令（把那几个值填好）。"
  exit 0
fi

hd "7. 阶段 2 — 在线安装（交互式）"
say "  现在可直接发起在线安装。需要你粘几个【外部绑定】值；非密钥项有默认，回车即用。"
say "  ${D}密钥隐藏输入、只存在内存：不写盘、不入库、不打日志。${N}"
printf '  现在就跑阶段 2 在线安装吗？[y/N] '
read -r ans </dev/tty
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
  say ""
  say "  已跳过安装。稍后手动跑："
  [[ -n "$PROXY" ]] && say "    ${D}source ~/.outpost-proxy.env${N}"
  say "    再粘贴阶段 2 的一行式安装命令。"
  exit 0
fi

# --- 交互式收集（printf -v 直接赋值，避免子 shell 捕获 prompt 文本）---------
prompt_val() {     # $1=varname  $2=label  $3=default
  local __in
  if [[ -n "$3" ]]; then printf '  %s [%s]: ' "$2" "$3"; else printf '  %s: ' "$2"; fi
  read -r __in </dev/tty
  printf -v "$1" '%s' "${__in:-$3}"
}
prompt_secret() {  # $1=varname  $2=label（隐藏输入）
  local __in
  printf '  %s: ' "$2"
  read -rs __in </dev/tty; printf '\n'
  printf -v "$1" '%s' "$__in"
}
mask() { local s="$1" n=${#1}; (( n<=8 )) && { printf '****（%d 字符）' "$n"; return; }; printf '%s…%s（%d 字符）' "${s:0:4}" "${s: -4}" "$n"; }

# 非密钥默认值（可回车接受；非密钥，内置默认无泄露风险）
prompt_val    ROOT_DOMAIN        'ROOT_DOMAIN'        'ufaster.cn'
prompt_val    GIT_USER           'GIT_USER'           'godzff'
prompt_val    MANIFEST_REPO_URL  'MANIFEST_REPO_URL'  'https://gitee.com/ufasterai/manifests.git'
# v0.3: webhook 已整体退役; CI 触发面是 GitHub Actions runner + 轮询对账。
prompt_val    GITHUB_RUNNER_URL  'GITHUB_RUNNER_URL（org 地址）' 'https://github.com/smithyhaus'
prompt_val    OUTPOST_REPOS      'OUTPOST_REPOS（逗号分隔 <clone-url>[#branch]，从 Mac .env 粘贴）' ''
# 密钥：必须当场粘贴，脚本不内置
prompt_secret CF_TUNNEL_TOKEN    'CF_TUNNEL_TOKEN（从 Mac .env 粘贴，隐藏输入）'
prompt_secret GIT_TOKEN          'GIT_TOKEN（从 Mac .env 粘贴，隐藏输入）'
prompt_secret GITHUB_RUNNER_PAT  'GITHUB_RUNNER_PAT（admin:org 权限 PAT，隐藏输入）'

# 必填校验
miss=()
for v in ROOT_DOMAIN GIT_USER MANIFEST_REPO_URL OUTPOST_REPOS CF_TUNNEL_TOKEN GIT_TOKEN GITHUB_RUNNER_PAT; do
  [[ -n "${!v}" ]] || miss+=("$v")
done
if (( ${#miss[@]} )); then
  no "缺少必填值：${miss[*]} —— 重跑本脚本再填"
  exit 1
fi

# 打码确认
hd "确认（密钥已打码）"
say "    ROOT_DOMAIN        = $ROOT_DOMAIN"
say "    GIT_USER           = $GIT_USER"
say "    MANIFEST_REPO_URL  = $MANIFEST_REPO_URL"
say "    GITHUB_RUNNER_URL  = $GITHUB_RUNNER_URL"
say "    OUTPOST_REPOS      = ${OUTPOST_REPOS:0:60}…（共 ${#OUTPOST_REPOS} 字符）"
say "    CF_TUNNEL_TOKEN    = $(mask "$CF_TUNNEL_TOKEN")"
say "    GIT_TOKEN          = $(mask "$GIT_TOKEN")"
say "    GITHUB_RUNNER_PAT  = $(mask "$GITHUB_RUNNER_PAT")"
printf '  确认无误、开始安装？[y/N] '
read -r ans2 </dev/tty
[[ "$ans2" =~ ^[Yy]$ ]] || { say "  已取消（值未落盘）。"; exit 0; }

# 让本进程带上代理（curl 拉 install.sh + 其内部 git/apt 都吃得到）
if [[ -n "$PROXY" ]]; then
  export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
  export no_proxy='localhost,127.0.0.1,::1,gitee.com,git.gitee.com,.svc,.cluster.local'
  export NO_PROXY="$no_proxy"
fi

hd "拉取并运行 install.sh"
say "  ${D}幂等：失败修好后重跑本脚本即可；值会再问一遍，不留痕。${N}"
curl -fsSL https://raw.githubusercontent.com/smithyhaus/Outpost/main/install.sh \
  | ROOT_DOMAIN="$ROOT_DOMAIN" \
    CF_TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" \
    GIT_USER="$GIT_USER" \
    GIT_TOKEN="$GIT_TOKEN" \
    MANIFEST_REPO_URL="$MANIFEST_REPO_URL" \
    OUTPOST_REPOS="$OUTPOST_REPOS" \
    GITHUB_RUNNER_URL="$GITHUB_RUNNER_URL" \
    GITHUB_RUNNER_PAT="$GITHUB_RUNNER_PAT" \
    bash
rc=$?

say ""
if [[ $rc -eq 0 ]]; then
  ok "install.sh 跑完（退出码 0）。自检：cd ~/outpost && ./status.sh && ./verify.sh"
  say "  ${D}Path B 还要逐个 onboard 应用：bash scripts/outpost onboard <app-git-url>${N}"
else
  no "install.sh 退出码 $rc —— 看上面的报错；修好后重跑本脚本（幂等）。"
fi
exit $rc
