# 03 — Windows 开机自启

让 Win11 启动时自动拉起 WSL2、docker、k3s 与 Compose 服务。

## 方案：Windows 任务计划

### 步骤

1. Win 任务计划程序（Task Scheduler）→ **创建任务**（不是"基本任务"）

2. **常规** tab：
   - 名称：`WSL Infra Autostart`
   - 选 "**用户登录时运行**" 或 "**计算机启动时**"（推荐前者）
   - 勾 "**使用最高权限运行**"
   - 配置 "Windows 10"（即使是 Win11）

3. **触发器** tab：
   - 新建 → "登录时" → 任意用户

4. **操作** tab：
   - 程序 / 脚本：`wsl.exe`
   - 添加参数：
     ```
     -d Ubuntu -u <你的 WSL 用户> -- bash -lc "cd ~/infra && ./status.sh > /tmp/infra-autostart.log 2>&1 &"
     ```
     替换 `<你的 WSL 用户>` 为实际用户名（如 `zff`）

5. **条件** tab：取消勾选 "只有在使用交流电源时才启动"

6. **设置** tab：
   - 允许按需运行 ✓
   - 失败后重试 3 次，每次 1 分钟

### 验证

```powershell
# 重启 Win 后等 30s
wsl -d Ubuntu -- docker ps        # 应当有容器运行
wsl -d Ubuntu -- kubectl get pods -A   # k3s 也应当起来
```

## 进阶：让 docker 与 k3s 在 WSL 内自启

WSL 内启用 systemd 后（见 docs/02），以下服务会自动启动：

- Docker：systemd 单元 `docker.service`（已自动 enable）
- k3s：安装时自动 `systemctl enable k3s.service`

Compose 容器配置了 `restart: unless-stopped`，docker 起来后会自动恢复。

K8s 内的 Deployment 也会随 k3s 启动而恢复。

所以 Windows 任务计划要做的事仅是：**触发 wsl.exe 启动 distro**（保持 distro 运行）。一旦 distro 起来，systemd 会接管所有服务自启。

## 让 WSL 后台保活（可选）

默认 WSL 在 8 秒无活动后会停止 distro。给任务计划加一个保活循环：

替换"操作"里的命令为：
```
wsl.exe -d Ubuntu -u <你的用户> -- bash -lc "while true; do sleep 60; done"
```

（这个命令会让 distro 一直处于运行态。或在 `.wslconfig` 加 `[experimental]\nautoMemoryReclaim=gradual`，让 WSL 不轻易完全停。）
