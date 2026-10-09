# LuaTools on DroidDeck (Poco F9 Ultra Guide)

This guide documents the installation, architecture, and operation of **luatools-moon** on the **Poco F9 Ultra** (Qualcomm Snapdragon 8 Elite / Adreno 830) running **DroidDeck**.

---

## 1. Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Poco F9 Ultra (Android)                         │
│       Qualcomm Snapdragon 8 Elite (ARM64) · Adreno 830 (Turnip/Vulkan) │
├────────────────────────────────────────────────────────────────────────┤
│                          DroidDeck Environment                         │
│     PRoot / Wayland / Gamescope / Termux userspace                     │
├────────────────────────────────────────────────────────────────────────┤
│ Valve Native ARM64 Steam Client                                        │
│   Location: $HOME/.local/share/Steam/steamrtarm64/steam                │
│   Debugging: 127.0.0.1:$BL_CDP_PORT or 8080 (CEF CDP endpoint)         │
├────────────────────────────────────────────────────────────────────────┤
│ DroidDeck Supervisor Daemon                                            │
│   Script: $HOME/.local/share/Lumen/droiddeck-luatools-hook.sh          │
│   Start: "Start LuaTools" launcher (desktop / app menu), once per run  │
├────────────────────────────────────────────────────────────────────────┤
│ Lumen Sidecar (x86_64 translated via FEX-Emu / native ARM64)           │
│   Multi-arch runner: lumen-runner.sh -> droiddeck-fex run -- lumen.bin │
│   SELinux peerauth: probes /json/version loopback endpoint             │
│   Dynamic port: resolves BL_CDP_PORT from droiddeck-session agent     │
├────────────────────────────────────────────────────────────────────────┤
│ LuaTools Plugin Stack                                                  │
│   UI: Injected via Chrome DevTools Protocol into Steam CEF             │
│   Backend: Lua runtime under Lumen                                     │
│   Downloader: scripts/downloader.sh (ARM64 native 7zz / unzip fallback)│
│   Manifests: ~/.config/SLSsteam/manifests/                             │
└────────────────────────────────────────────────────────────────────────┘
```

### Key Technical Adaptations

1. **Native ARM64 Steam Client Compatibility:**
   - DroidDeck runs Valve's official native 64-bit ARM64 Steam client (`steamrtarm64/steam`).
   - The installer automatically detects DroidDeck ARM64, pre-seeds SLSsteam directory structures (`~/.config/SLSsteam/manifests`), and avoids loading incompatible 32-bit x86 `LD_AUDIT` hooks directly into the ARM64 linker.
   
2. **Android SELinux `/proc/net/tcp` Restriction Bypass:**
   - On Android kernels, `/proc/net/tcp` is locked down by SELinux for unprivileged processes, causing standard inode checks to report 0 sockets.
   - `lumen-aux/peerauth.lua` implements an authenticated HTTP probe against `127.0.0.1:<port>/json/version` to verify that the CDP endpoint belongs to Valve's Steam client before connecting.

3. **Dynamic CDP Port Discovery:**
   - DroidDeck's session manager (`droiddeck-session`) assigns dynamic CDP ports exported via `BL_CDP_PORT` and stored in `$BL_LAUNCH_DIR/agent/cdp-port`.
   - `lumen-aux/cefport.lua` inspects these environment and agent markers with fallback to 8080.

4. **Multi-Architecture Lumen Runner:**
   - `lumen-aux/lumen-runner.sh` launches Lumen through `/usr/local/bin/droiddeck-fex run --mode on --` or native ARM64 when available.

5. **ARM64 Downloader Script:**
   - `plugin/backend/scripts/downloader.sh` auto-detects `aarch64`/`arm64`, using native system `7zz` or `unzip`, falling back to FEX translation for bundled binaries.

---

## 2. Installation on Poco F9 Ultra

### Step 1: Device Prerequisites
On your Poco F9 Ultra (HyperOS / Android):
1. **Developer Options:**
   - Go to `Settings -> Additional settings -> Developer options`.
   - Enable **Disable child process restrictions** (prevents Android's Phantom Process Killer from terminating background FEX processes).
2. **Battery Optimization:**
   - Set the Termux / DroidDeck app battery usage to **No restrictions**.
3. **Acquire Wake-Lock:**
   - Inside Termux before starting DroidDeck:
     ```bash
     termux-wake-lock
     ```

### Step 2: Install LuaTools in DroidDeck
Open your DroidDeck desktop terminal (or SSH into the DroidDeck container):

#### Option A: One-Shot Online Installer
```bash
curl -fsSL https://raw.githubusercontent.com/helpmehtmlcom-create/luatools-moon/main/install.sh | bash
```

#### Option B: Local Repository Installation
If you cloned the repository locally:
```bash
cd luatools-moon
bash install.sh
```

The installer will:
- Recognize the DroidDeck ARM64 environment and allow PRoot UID 0.
- Verify native Steam bootstrap at `$HOME/.local/share/Steam/steamrtarm64/steam`.
- Extract Lumen and install `lumen-runner.sh`, `peerauth.lua`, and `cefport.lua`.
- Install the LuaTools plugin and configure `downloader.sh`.
- Install the background session supervisor (`droiddeck-luatools-hook.sh`).
- Add a **Start LuaTools** launcher (desktop and app menu); DroidDeck does not keep autostart entries.

---

## 3. Managing the Service

DroidDeck rebuilds `/usr/local/bin` and `/etc/xdg/labwc/autostart` at every launch and has no
user startup hook, so the supervisor cannot start itself. The installer adds a **Start LuaTools**
launcher to the desktop and the app menu. Tap it once after DroidDeck starts; the supervisor then
starts and stops Lumen with Steam on its own. LuaTools appears on Steam Store and Community pages.

The DroidDeck supervisor automatically monitors Steam and starts/stops Lumen:

```bash
# Check service status
droiddeck-luatools-hook status

# Start supervisor manually
droiddeck-luatools-hook start

# Stop supervisor and Lumen
droiddeck-luatools-hook stop
```

---

## 4. Diagnostics & Troubleshooting

To collect full scrubbed logs for troubleshooting:
```bash
bash diagnose.sh
```
This generates and uploads an anonymous diagnostic bundle including:
- DroidDeck session state and environment variables.
- FEX runner and ARM64 Steam binary presence.
- Lumen and Steam CEF logs.

### Checking Logs Directly
```bash
# View Lumen activity log
cat ~/.lumen.log

# View DroidDeck Steam session log
cat ~/.cache/droiddeck/steam-desktop.log
```

---

## 5. Uninstallation

To remove all LuaTools components, hooks, and configurations:
```bash
bash uninstall.sh
```
