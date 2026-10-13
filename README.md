# macOS Cloud Desktop on GitHub Actions 🍏

Run a full, interactive **macOS Desktop GUI (Apple Silicon / Intel)** inside GitHub Actions runners and connect directly from **Kali Linux**, Linux, Windows, or mobile with near-zero latency.

---

## ⚡ Features

- **Apple Silicon & Intel Support**: Runs natively on `macos-latest` (Apple Silicon M-series) or configurable to `macos-14`, `macos-15`, and `macos-13`.
- **Multiple Zero-Friction Tunneling Engines**:
  - **Ngrok (Fastest)**: Low latency with region selection (e.g., `in` for India / Chennai).
  - **Pinggy (Tokenless Backup)**: Direct public TCP endpoint without needing any accounts.
  - **tmate (Encrypted SSH Tunnel)**: Bulletproof, encrypted SSH port-forwarding straight into your Kali terminal.
- **6-Hour Persistent Sessions**: Maxes out GitHub Actions runner duration (360 minutes).
- **Pre-Configured Audio & Screen Sharing**: Native Apple Remote Management enabled with full root/admin permissions.

---

## 🚀 How to Run

1. Go to the **Actions** tab in this repository.
2. Select **macOS Cloud Desktop (VNC)**.
3. Click **Run workflow**:
   - *(Optional)* Paste your **Ngrok Auth Token** (or add `NGROK_AUTH_TOKEN` in Repo Secrets).
   - *(Optional)* Change Password (default: `FarisMac2026`).
   - *(Optional)* Choose Region (default: `in` for lowest ping in India).
   - *(Optional)* Choose macOS Runner (default: `macos-latest`).
4. Click **Run workflow**.
5. Click on the active workflow run and open the **macOS Desktop Runner** log.
6. Copy the connection endpoint from the banner!

---

## 💻 How to Connect from Kali Linux

Default credentials:
- **Username**: `runner` (or `runneradmin`)
- **Password**: `FarisMac2026`

### Option 1: Remmina (Recommended GUI)

Remmina is the best graphical remote client on Kali Linux:

1. Launch Remmina from Kali application menu or run in terminal:
   ```bash
   remmina &
   ```
2. In the top connection bar:
   - Protocol: Select **VNC**
   - Address: Enter the Ngrok or Pinggy address (e.g. `0.tcp.in.ngrok.io:12345` or `...a.pinggy.link:4321`)
3. Hit **Enter** and type the password: `FarisMac2026`.
4. You are inside macOS!

### Option 2: CLI TigerVNC (`vncviewer`)

If you prefer lightweight command line:

```bash
sudo apt update && sudo apt install -y tigervnc-viewer
vncviewer <tunnel-address>:<port>
```
*Example:*
```bash
vncviewer 0.tcp.in.ngrok.io:12345
```

### Option 3: Encrypted SSH Tunnel via tmate (No Ngrok Needed)

If you don't have an Ngrok token:
1. In the GitHub Actions log, copy the `ssh ...` command printed by the `action-tmate` step.
2. On Kali Linux, add local port forwarding `-L 5900:localhost:5900`:
   ```bash
   ssh -L 5900:localhost:5900 <user>@<host>
   ```
3. In another terminal on Kali, simply connect to localhost:
   ```bash
   vncviewer localhost:5900
   ```
   *(Or in Remmina: connect to `localhost:5900`)*

---

## 🛡️ Architecture & Security

- macOS Ventura, Sonoma, and Sequoia runners natively run Aqua WindowServer for CI testing.
- Remote Management (`kickstart`) activates Apple's RFB/VNC daemon on port 5900.
- All sessions are isolated and ephemeral.

### Why `kickstart` alone gives you a black screen

This trips up almost everyone. Enabling VNC with `kickstart` gets you a listening
port, a working RFB handshake and a successful password prompt — and then a
**black screen** with this message from macOS itself:

> Screen recording might be disabled. Screen Sharing or Remote Management must be
> enabled from System Settings or via MDM.

The port being open is not the same thing as screen sharing being enabled. Since
**macOS 12.1, `kickstart` can start the VNC daemon but cannot grant it Screen
Recording access.** Apple's own documentation says so:

> In macOS 12.1 or later, Screen Sharing can't be enabled by the `kickstart`
> command-line tool. You can use a mobile device management (MDM) solution to
> enable Remote Management.
> — [Apple Remote Desktop User Guide](https://support.apple.com/guide/remote-desktop/apd8b1c65bd/mac)

So the framebuffer grab is refused by TCC and you get a black screen. Two things
that do **not** fix it:

- **`tccutil`** can only *reset* a permission, never grant one. There is no
  command that grants Screen Recording.
- **Toggling it in System Settings** — there is no human at the desktop of a CI
  runner.

GitHub's own macOS runner images solve this by pre-seeding a row for
`com.apple.screensharing.agent` directly into `TCC.db`, and the `runner-images`
maintainers have confirmed the hosted images allow runtime writes to that
database. `scripts/grant_tcc.sh` does exactly that, for **Screen Recording**
(the black screen) plus **Accessibility** and **Listen Event** (so you can
actually control the machine, not just look at it).

It runs automatically inside `setup_vnc.sh` before the agent is started, and it
builds a schema-aware `INSERT` from `PRAGMA table_info(access)` so it keeps
working as Apple adds columns in macOS 14/15/26.

### If it still shows a black screen

Run the workflow and read the **Health Check** step:

| What it prints | What it means |
| --- | --- |
| `NOT LISTENING` | ARD never started — check the ARD output above it in the log. |
| `SIP status: enabled` | **Not fixable by script.** A SIP-protected `TCC.db` cannot be written, so the grant never lands. Move to a self-hosted / EC2 Mac or a managed Mac host. |
| console owner is `root` or `loginwindow` | No user is logged into the GUI, so there is no framebuffer to capture. |
| grant row missing | The write failed — read the `grant_tcc.sh` errors in the log. |

### Security notes — read before exposing this

- **Legacy VNC is on by default and it is the weak link.** `-setvnclegacy`
  enables the obsolete VNC4 protocol with a DES-obfuscated password. That
  protocol is the basis of published macOS Screen Sharing RCEs, and you are
  publishing it to the open internet via ngrok/Pinggy. Set the **`legacy_vnc`
  input to `no`** if your client supports Apple's own authentication (Remmina and
  TigerVNC both do), and prefer an SSH tunnel over a public endpoint.
- The default password `FarisMac2026` is printed in this README. Always pass
  your own.
- Anyone who connects lands on an admin-capable account (`-privs -all`,
  `-allUsers`). Treat the tunnel endpoint as a credential.
