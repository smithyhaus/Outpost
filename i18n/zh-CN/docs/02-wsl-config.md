# 02 — WSL2 主机配置(仅 WSL 用户)

> macOS / Linux 原生用户**跳过本文档**。这一篇只在 Outpost 主机是 Windows + WSL2 时需要。
> macOS 和 Linux 的系统准备见 `00-quickstart.md` 的 Phase B-mac / B-linux。

## 一、`.wslconfig`（在 Windows 端）

文件路径：`C:\Users\<你>\.wslconfig`

```ini
[wsl2]
memory=48GB
processors=24
swap=16GB
networkingMode=mirrored
firewall=true
dnsTunneling=true
autoProxy=true

[experimental]
sparseVhd=true
hostAddressLoopback=true
```

修改后在 PowerShell（管理员）：
```powershell
wsl --shutdown
```
再次启动 WSL 即生效。

## 二、WSL Ubuntu 内基础设置

### 2.1 systemd（让 docker / k3s 用 systemd 管理）

```bash
sudo tee /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false
EOF
```

退出 WSL，PowerShell 执行 `wsl --shutdown`，重新进入 WSL 后 `systemctl status` 应当能正常返回。

### 2.2 Docker 镜像加速（国内必做）

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.nju.edu.cn"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
docker info | grep -A 3 "Registry Mirrors"
```

### 2.3 必备工具

```bash
sudo apt update
sudo apt install -y curl wget git openssl gettext-base ca-certificates jq
```

`gettext-base` 提供 `envsubst`，bootstrap.sh 渲染模板用。

## 三、验证

```bash
# Docker 正常
docker run --rm hello-world

# 内核
uname -a

# 内存（应该接近你 .wslconfig 里设置的）
free -h

# CPU 核数
nproc
```

## 四、常见坑

- **mirrored networking 不生效**：检查 Win11 版本（必须 22H2+），并确认没有 VPN 客户端劫持网卡
- **systemd 启不来**：`/etc/wsl.conf` 写错位置（不是 `/etc/wsl/conf`），且必须 `wsl --shutdown` 才生效
- **docker 启不来**：`sudo service docker start` 试一下看报错；mirrored networking 下偶尔 iptables 模块需要 `sudo modprobe ip_tables`
- **`.wslconfig` 不生效**：路径必须是 `C:\Users\<你>\.wslconfig`（不是 WSL 内），编辑后必须 `wsl --shutdown`
