this is the project i devleoped for the mainly on my CachyOS[arch] to make config script enable system wide proxy :)

---

# 🔁 CachyOS / Arch Proxy Toggle – Final

A smart, system‑wide proxy switcher that **remembers your original settings** and restores them exactly when you turn the proxy off.  
It works across shells, desktop environments, package managers, and even applications like Firefox – all with a single command.

---

## ✨ Features

- **One‑command toggle** – `on` / `off` / `status`
- **Persistent across reboots** – your proxy stays active until you disable it
- **Snapshot & rollback** – every file modified is backed up and restored to its **pre‑proxy state**
- **Supports multiple layers**:
  - `/etc/environment` – system‑wide env vars
  - `~/.bashrc` / `~/.profile` – Bash login shells
  - Fish shell profile
  - `sudo` – keeps your proxy for elevated commands
  - `systemd` – user and system services
  - `GNOME` – desktop proxy settings
  - `pacman` / `makepkg` – downloads through the proxy (using `curl`)
  - `Flatpak` – system‑wide proxy for Flatpak
  - `proxychains` – for CLI tools that need forced proxying
  - **Firefox** – sets it to use the system proxy (or **directly to no proxy** when turned off)
  - **Shelly** – wraps both CLI and GUI versions, plus the GNOME launcher
- **Runtime overrides** – use a different proxy without changing the defaults
- **Detailed logging** – every action is logged to `~/.local/state/proxy-toggle/proxy-toggle.log`
- **Safety first** – the script never overwrites a backup while the proxy is enabled; disabling always restores the original state

---

## 📦 Requirements

- **Arch Linux** or any **Arch‑based** distribution (CachyOS, EndeavourOS, Manjaro, …)
- `sudo` access
- `bash` (the script uses `#!/usr/bin/env bash`)
- Optional, but recommended for full functionality:
  - `curl`
  - `proxychains4`
  - `gsettings` (GNOME)
  - `flatpak`
  - `fish` (if you use Fish)
  - Firefox (if you want automatic proxy handling)

---

## 🚀 Installation

1. **Clone or download** the script.  
   Save it as, for example, `proxy-toggle.sh` in a directory of your choice (e.g., `~/bin/`).

2. **Make it executable**:
   ```bash
   chmod +x ~/bin/proxy-toggle.sh
   ```

3. (Optional) **Add it to your `PATH`** so you can run it from anywhere:
   ```bash
   sudo ln -s ~/bin/proxy-toggle.sh /usr/local/bin/proxy-toggle
   ```

> **Important**: The script **must be run as a normal user** – it will call `sudo` internally when needed.  
> Never run it with `sudo` directly – the script will refuse to run as root.

---

## 🧭 Usage

```bash
./proxy-toggle.sh on                  # Use default proxy (192.168.43.1:44355)
./proxy-toggle.sh on 10.0.0.1 8080    # Override host/port for this activation
./proxy-toggle.sh 10.0.0.1 8080 on    # Same override, different order
./proxy-toggle.sh off                 # Disable proxy, restore all original settings
./proxy-toggle.sh status              # Show current state and what’s configured
```

### Default proxy

The hard‑coded defaults are:
- **Host**: `192.168.43.1`
- **Port**: `44355`

These are **always** the fallback values. When you supply a different host/port, it only overrides them **for that activation**. The defaults remain unchanged for the next `on` call without arguments.

---

## 🔧 How it works 

1. **Turning on (`on`)**:
   - The script checks if a proxy is already active. If not, it **snapshots** every configuration file it will touch (environment, GNOME, pacman, etc.) and stores them in `/var/lib/proxy-toggle-final/originals/`.
   - It then writes the new proxy settings into all those places.
   - It sets the proxy for the **current shell** environment.
   - Finally, it creates a flag file (`/var/lib/proxy-toggle-final/enabled`) to remember that the proxy is active.

2. **Turning off (`off`)**:
   - If the flag exists, the script **restores** every file from the snapshot.
   - It forces Firefox to use **no proxy** (to avoid stale manual settings).
   - It clears the systemd and D‑Bus environment variables.
   - It wipes the state directory, leaving no trace of the proxy configuration.

3. **Runtime override**:
   - Even if you use a non‑default host/port while turning on, the **original snapshots** are still taken before any changes – so when you turn off, you go back to exactly what you had before that activation.

4. **Firefox special treatment**:
   - On `on`, Firefox is set to use the **system proxy** (mode `5`).
   - On `off`, Firefox is forcefully set to **direct connection** (mode `0`). This ensures that any previous manual proxy settings in Firefox don’t interfere.

---

## 🗂️ Files and directories involved

| File / Directory | Purpose |
|------------------|---------|
| `/var/lib/proxy-toggle-final/` | State directory with originals and the enabled flag |
| `/etc/environment` | System‑wide environment variables |
| `/etc/profile.d/proxy.sh` | Bash login profile snippet |
| `/etc/fish/conf.d/proxy.fish` | Fish shell profile |
| `/etc/sudoers.d/99-proxy-env` | `sudo` environment keepers |
| `/etc/pacman.conf` | Pacman configuration – adds a `XferCommand` with `curl` and proxy |
| `/etc/flatpak/config` | Flatpak system proxy settings |
| `/etc/proxychains.conf` | Proxychains configuration – adds the proxy to the list |
| `/usr/local/bin/{shelly,shelly-ui}` | Wrappers that run Shelly through `proxychains` |
| `~/.local/share/applications/com.shellyorg.shelly.desktop` | User copy of Shelly’s desktop launcher with the wrapper |
| Firefox profile `user.js` | Sets `network.proxy.type` to 5 (system) or 0 (direct) |

---

## 📝 Logging

Everything is logged to:
```
~/.local/state/proxy-toggle/proxy-toggle.log
```
The log file is automatically rotated when it exceeds 1 MB (keeps a `.old` copy).  
Check it if something doesn’t work as expected.

---

## 🧪 Status output

Running `./proxy-toggle.sh status` gives you a quick overview of:
- Whether the proxy is enabled
- The active proxy URL
- Which components are currently configured (GNOME, pacman, Flatpak, proxychains, Shelly, etc.)
- A connectivity test to `https://aur.archlinux.org` (if enabled)

---

## ⚠️ Troubleshooting tips

- **“sudo authentication failed”** – make sure you have passwordless `sudo` or type your password when prompted.
- **Firefox doesn’t use the proxy** – close Firefox completely and reopen it after toggling. The script writes to `user.js`; Firefox reads it on startup.
- **Changes don’t appear in the current terminal** – open a new terminal or source your profile (`. ~/.profile`) – environment variables are only set for new shells.
- **Pacman downloads still go direct** – pacman uses the `XferCommand` only when the `[options]` section exists. If it doesn’t, the script will abort with a clear error.
- **Flatpak refuses to use proxy** – restart the `flatpak-system-helper` service (the script does this automatically).

---

## 🗑️ Uninstalling

If you no longer need the script:
1. Turn the proxy off first: `./proxy-toggle.sh off`
2. Delete the script file.
3. Optionally remove the state directory: `sudo rm -rf /var/lib/proxy-toggle-final`
4. Remove any leftover wrapper files (they are restored/removed by the `off` command anyway).

---

## 📄 License

This script is provided “as is”, without warranty of any kind.  
Feel free to use, modify, and share it – but please keep the original credits if you distribute a modified version.

---

## 🙌 Credits

Written for personal use on **CachyOS**, but should work on any Arch‑based system.  
If you improve it, contributions are welcome!

---

*Happy toggling!* =)
