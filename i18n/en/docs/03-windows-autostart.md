# 03 — Windows autostart (WSL2 only)

Make Win11 launch WSL2, docker, k3s, and the Compose stack at logon.

## Approach: Windows Task Scheduler

1. Open **Task Scheduler** → **Create Task** (not "Create Basic Task")
2. **General** tab:
   - Name: `WSL outpost autostart`
   - Choose **Run only when user is logged on** (or **Run whether user is
     logged on or not** if you want it earlier)
   - Check **Run with highest privileges**
   - Configure for: Windows 10 (works on Win11)
3. **Triggers** tab:
   - New → **At log on** → Any user
4. **Actions** tab:
   - Program/script: `wsl.exe`
   - Arguments:
     ```
     -d Ubuntu -u <your-wsl-user> -- bash -lc "cd ~/outpost && ./status.sh > /tmp/outpost-autostart.log 2>&1 &"
     ```
     Replace `<your-wsl-user>` with your actual WSL username
5. **Conditions** tab:
   - Uncheck **Start the task only if the computer is on AC power**
6. **Settings** tab:
   - Allow task to be run on demand
   - Restart on failure: 3 times, every 1 minute

### Verify

After Windows reboots:

```powershell
wsl -d Ubuntu -- docker ps              # containers should be running
wsl -d Ubuntu -- kubectl get pods -A    # k3s should be up
```

## Inside WSL — let systemd handle the rest

With systemd enabled (see [02-wsl-config.md](02-wsl-config.md)), the
following will autostart:

- `docker.service` (auto-enabled)
- `k3s.service` (enabled by `bootstrap.sh`)

Compose containers carry `restart: unless-stopped`, so docker recovers
them on its own. The K8s Deployments come back when `k3s.service` does.

The Task Scheduler entry's only job is to **launch the WSL distro** so
that systemd can take over. Once the distro is running, everything else
is automatic.

## Optional: keep WSL alive in the background

WSL stops the distro after ~8 seconds of inactivity by default. To pin
the distro running, change the action's command to:

```
wsl.exe -d Ubuntu -u <your-user> -- bash -lc "while true; do sleep 60; done"
```

Alternatively, set in `.wslconfig`:

```ini
[experimental]
autoMemoryReclaim=gradual
```
