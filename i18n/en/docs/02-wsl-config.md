# 02 — WSL2 host configuration (WSL2 only)

> macOS / native Linux users: **skip this doc**. It only applies when the
> Outpost host is Windows + WSL2. For macOS / Linux system prep, see
> `00-quickstart.md` Phase B-mac / B-linux.

## 1. `.wslconfig` (on the Windows side)

Path: `C:\Users\<you>\.wslconfig`

```ini
[wsl2]
memory=<half of host RAM, e.g. 32GB>
processors=<host cores - 4>
swap=8GB
networkingMode=mirrored
firewall=true
dnsTunneling=true
autoProxy=true

[experimental]
sparseVhd=true
hostAddressLoopback=true
```

After editing, run in PowerShell:

```powershell
wsl --shutdown
```

Reopen WSL — settings take effect.

## 2. WSL Ubuntu — basic configuration

### 2.1 Enable systemd

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

Exit WSL, run `wsl --shutdown` from PowerShell, reopen WSL.
`systemctl status` should now respond.

### 2.2 Docker mirror (recommended in restricted networks)

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.nju.edu.cn"
  ],
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "3"}
}
EOF
sudo systemctl restart docker
docker info | grep -A 3 "Registry Mirrors"
```

> Outpost's `bootstrap.sh` will write this file automatically if it
> does not exist. It will NOT overwrite an existing `daemon.json`.

### 2.3 Required tools

```bash
sudo apt update
sudo apt install -y curl wget git openssl gettext-base ca-certificates jq
```

`gettext-base` provides `envsubst`, used by `bootstrap.sh` to render
templates.

## 3. Verify

```bash
docker run --rm hello-world   # docker works
free -h                        # memory matches .wslconfig
nproc                          # CPU count matches .wslconfig
```

## 4. Common pitfalls

- **mirrored networking has no effect:** check Win11 ≥ 22H2; some VPN
  clients hijack the network adapter
- **systemd doesn't start:** `/etc/wsl.conf` location wrong, or you
  forgot to `wsl --shutdown`
- **Docker won't start:** try `sudo service docker start`; on mirrored
  networking sometimes `sudo modprobe ip_tables` is needed
- **`.wslconfig` ignored:** path must be `C:\Users\<you>\.wslconfig`
  (Windows side, not inside WSL); `wsl --shutdown` is required after edits
