<p align="center">
  <b>RU</b> <a href="ADVANCED.md">Русский</a> | <b>EN</b> English
</p>

# AmneziaWG 2.0 Installer: Advanced Documentation

This is a supplement to the main [README.en.md](README.en.md), containing deeper technical details, explanations, and advanced options for the AmneziaWG 2.0 installation and management scripts.

## Table of Contents

<a id="toc-adv"></a>
- [✨ Features (Detailed)](#features-detailed-adv)
- [🔐 AWG 2.0 Parameters](#awg2-params-adv)
- [⚙️ Client Configuration Details](#config-details-adv)
  - [AllowedIPs](#allowedips-adv)
  - [PersistentKeepalive](#persistentkeepalive-adv)
  - [DNS](#dns-adv)
  - [Changing Default Settings](#change-defaults-adv)
- [🔒 Server Security Settings](#security-adv)
  - [UFW Firewall](#ufw-adv)
  - [Kernel Parameters (Sysctl)](#sysctl-adv)
  - [Fail2Ban (Automatic Setup)](#fail2ban-adv)
- [🧹 Server Optimization](#optimization-adv)
- [📋 Configuration Examples](#config-examples-adv)
- [⚙️ CLI Parameters](#cli-params-adv)
  - [install_amneziawg.sh](#install-cli-adv)
  - [manage_amneziawg.sh](#manage-cli-adv)
- [🧑‍💻 Full List of Management Commands](#manage-commands-adv)
- [🛠️ Technical Details](#tech-details-adv)
  - [Script Architecture](#architecture-adv)
  - [DKMS](#dkms-adv)
  - [Key and Config Generation](#keygen-adv)
- [🔄 How to Update Scripts](#update-scripts-adv)
- [❓ FAQ (Additional Questions)](#faq-advanced-adv)
- [🩺 Diagnostics and Uninstall](#diag-uninstall-adv)
  - [Diagnostic Report Contents](#diagnostic-report-adv)
- [🔧 Troubleshooting (Detailed)](#troubleshooting-adv)
- [📊 Traffic Statistics (stats)](#stats-adv)
- [⏳ Temporary Clients (--expires)](#expires-adv)
- [📱 vpn:// URI Import](#vpnuri-adv)
- [📱 MTU and Mobile Clients](#mtu-mobile-adv)
- [📋 AWG 2.0 Client Compatibility](#client-compat-adv)
- [🐧 Debian Support](#debian-support-adv)
- [⚠️ Known Limitations](#limitations-adv)
- [🤝 Contributing](#contributing-adv)
- [💖 Acknowledgements](#thanks-adv)

---

> For the full version history, see [CHANGELOG.en.md](CHANGELOG.en.md).

---

<a id="features-detailed-adv"></a>
## ✨ Features (Detailed)

* **AmneziaWG 2.0:** Support for the next-generation protocol with extended obfuscation parameters (H1-H4 ranges, S3-S4, CPS I1).
* **Native key generation:** Keys are generated via `awg genkey/pubkey`, configs via Bash templates, QR codes via `qrencode`. The external Python/awgcfg.py dependency has been completely removed.
* **Automated installation:** Installs AmneziaWG, DKMS module, dependencies, configures networking, firewall, and sysctl.
* **Resume after reboot:** Uses a state file (`/root/awg/setup_state`) to continue after required reboots.
* **Automated system optimization:**
    * Removal of unnecessary packages (snapd, modemmanager, etc.)
    * Hardware-aware swap and network buffer tuning
    * NIC offload disabling (GRO/GSO/TSO) for VPN optimization
* **Secure by default:**
    * `UFW`: Policy `deny incoming`, SSH rate-limiting, VPN port allowed.
    * `IPv6`: Disabled by default via `sysctl` (optional).
    * `File permissions`: Strict permissions (600/700) on all keys and configs.
    * `Sysctl`: BBR congestion control, anti-spoofing, TCP optimization.
    * `Fail2Ban`: Automatic installation and SSH protection.
* **Backup:** `backup` command in the management script (including client keys).

---

<a id="awg2-params-adv"></a>
## 🔐 AWG 2.0 Parameters

All parameters are generated automatically during installation and saved to `/root/awg/awgsetup_cfg.init`. They are identical for the server and all clients.

| Parameter | Description | Range | Example |
|-----------|-------------|-------|---------|
| `Jc` | Number of junk packets | 4-8 | `6` |
| `Jmin` | Min junk size (bytes) | 40-89 | `55` |
| `Jmax` | Max junk size (bytes) | Jmin+100..Jmin+500 | `380` |
| `S1` | Init message padding (bytes) | 15-150 | `72` |
| `S2` | Response message padding (bytes) | 15-150, S1+56≠S2 | `56` |
| `S3` | Cookie message padding (bytes) | 8-55 | `32` |
| `S4` | Data message padding (bytes) | 4-27 | `16` |
| `H1` | Init message identifier | uint32 range | `134567-245678` |
| `H2` | Response message identifier | uint32 range | `3456789-4567890` |
| `H3` | Cookie message identifier | uint32 range | `56789012-67890123` |
| `H4` | Data message identifier | uint32 range | `456789012-567890123` |
| `I1` | CPS concealment packet | Format `<r N>` | `<r 128>` |

**Critical constraints:**
* H1-H4 ranges **must not overlap** (guaranteed by the generation algorithm).
* `S1 + 56 ≠ S2` — prevents init and response messages from having the same size.
* All nodes (server + clients) **must** use identical parameters.

---

<a id="config-details-adv"></a>
## ⚙️ Client Configuration Details

<a id="allowedips-adv"></a>
### AllowedIPs

Defines which traffic the **client** routes through the VPN tunnel.

1.  **Mode 1: All traffic (`0.0.0.0/0`)**
    * All client IPv4 traffic → VPN.
    * Maximum privacy. May block LAN access.

2.  **Mode 2: Amnezia List + DNS (Default)**
    * List of public IP ranges + DNS `1.1.1.1`, `8.8.8.8`.
    * **Purpose:** DPI bypass, DNS tunneling. Recommended.

3.  **Mode 3: Custom (Split-Tunneling)**
    * Only traffic to specified networks → VPN.
    * Example: `192.168.1.0/24,10.50.0.0/16`

**AllowedIPs Calculator:** [WireGuard AllowedIPs Calculator](https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator/).

<a id="persistentkeepalive-adv"></a>
### PersistentKeepalive

* **Default value:** `33` seconds.
* Maintains the UDP session through NAT.
* **Change:** `sudo bash /root/awg/manage_amneziawg.sh modify <name> PersistentKeepalive 25`

<a id="dns-adv"></a>
### DNS

* **Default value:** `1.1.1.1` (Cloudflare).
* DNS server for the client inside the VPN.
* **Change:** `sudo bash /root/awg/manage_amneziawg.sh modify <name> DNS "8.8.8.8,1.0.0.1"`

<a id="change-defaults-adv"></a>
### Changing Default Settings

To change the default DNS or PersistentKeepalive for **new** clients, edit the `render_client_config()` function in `awg_common.sh` **before** the first run.

---

<a id="security-adv"></a>
## 🔒 Server Security Settings

<a id="ufw-adv"></a>
### UFW Firewall

* **Policies:** Deny incoming, Allow outgoing, Deny routed.
* **Rules:** `limit 22/tcp` (SSH), `allow <vpn_port>/udp`, `route allow in on awg0 out on <nic>` (VPN traffic forwarding, added in v5.7.6).
* **Check:** `sudo ufw status verbose`

<a id="sysctl-adv"></a>
### Kernel Parameters (Sysctl)

File: `/etc/sysctl.d/99-amneziawg-security.conf`. Includes:
* IP forwarding
* IPv6 disable (optional)
* BBR congestion control + FQ qdisc
* TCP hardening (syncookies, rp_filter, RFC1337)
* ICMP redirects and source routing disabled
* Adaptive network buffers (rmem/wmem based on RAM)
* nf_conntrack_max = 65536
* kernel.sysrq = 0

<a id="fail2ban-adv"></a>
### Fail2Ban (Automatic Setup)

* Automatically installed and configured for SSH protection.
* **Settings:** Ban via `ufw`, 5 attempts → 1-hour ban.
* **Debian:** Automatically uses `backend = systemd` (journald). Ubuntu uses `backend = auto`.
* **Check:** `sudo fail2ban-client status sshd`.

#### Safe Configuration Loading (v5.7.2)

Starting with v5.7.2, the `awgsetup_cfg.init` parameters file is loaded via `safe_load_config()` — a whitelist parser that only accepts predefined keys (`AWG_*`, `OS_*`, `DISABLE_IPV6`, `ALLOWED_IPS_*`, `NO_TWEAKS`, etc.). The previous `source` method has been completely replaced. The parser correctly handles values in both single and double quotes (`'value'` or `"value"`).

This protects against potential code injection: even if the configuration file is modified, arbitrary commands will not execute.

---

<a id="optimization-adv"></a>
## 🧹 Server Optimization

The installer automatically optimizes the server:

**Removed packages:** `snapd`, `modemmanager`, `networkd-dispatcher`, `unattended-upgrades`, `packagekit`, `lxd-agent-loader`, `udisks2`. Cloud-init is removed **only** if it does not manage network configuration.

**Hardware-aware settings:**
* **Swap:** 1 GB if RAM ≤ 2 GB, 512 MB if RAM > 2 GB. `vm.swappiness = 10`.
* **NIC:** GRO/GSO/TSO offloads disabled (can interfere with VPN traffic).
* **Network buffers:** Automatic `rmem_max`/`wmem_max` tuning based on available RAM.

---

<a id="config-examples-adv"></a>
## 📋 Configuration Examples

<details>
<summary><strong>awgsetup_cfg.init (installation parameters)</strong></summary>

```bash
# AmneziaWG 2.0 installation configuration (auto-generated)
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=2
export ALLOWED_IPS='0.0.0.0/5, 8.0.0.0/7, ...'
export AWG_ENDPOINT=''
export AWG_Jc=6
export AWG_Jmin=55
export AWG_Jmax=780
export AWG_S1=72
export AWG_S2=56
export AWG_S3=32
export AWG_S4=16
export AWG_H1='234567-345678'
export AWG_H2='3456789-4567890'
export AWG_H3='56789012-67890123'
export AWG_H4='456789012-567890123'
export AWG_I1='<r 128>'
```
</details>

<details>
<summary><strong>awg0.conf (server config, keys masked)</strong></summary>

```ini
[Interface]
PrivateKey = [SERVER_PRIVATE_KEY]
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
Jc = 6
Jmin = 55
Jmax = 780
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 234567-345678
H2 = 3456789-4567890
H3 = 56789012-67890123
H4 = 456789012-567890123
I1 = <r 128>

[Peer]
#_Name = my_phone
PublicKey = [CLIENT_PUBLIC_KEY]
AllowedIPs = 10.9.9.2/32
```
</details>

<details>
<summary><strong>client.conf (client config, keys masked)</strong></summary>

```ini
[Interface]
PrivateKey = [CLIENT_PRIVATE_KEY]
Address = 10.9.9.2/32
DNS = 1.1.1.1
MTU = 1280
Jc = 6
Jmin = 55
Jmax = 780
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 234567-345678
H2 = 3456789-4567890
H3 = 56789012-67890123
H4 = 456789012-567890123
I1 = <r 128>

[Peer]
PublicKey = [SERVER_PUBLIC_KEY]
Endpoint = 203.0.113.1:39743
AllowedIPs = 0.0.0.0/5, 8.0.0.0/7, ...
PersistentKeepalive = 33
```
</details>

---

<a id="cli-params-adv"></a>
## 🖥️ CLI Parameters

<a id="install-cli-adv"></a>
### install_amneziawg.sh

```
Options:
  -h, --help            Show help
  --uninstall           Uninstall AmneziaWG
  --diagnostic          Generate diagnostic report
  -v, --verbose         Verbose output (including DEBUG)
  --no-color            Disable colored output
  --port=PORT           Set UDP port (1024-65535)
  --subnet=SUBNET       Set tunnel subnet (x.x.x.x/yy)
  --allow-ipv6          Keep IPv6 enabled
  --disallow-ipv6       Force-disable IPv6
  --route-all           Mode: All traffic (0.0.0.0/0)
  --route-amnezia       Mode: Amnezia List + DNS (default)
  --route-custom=NETS   Mode: Only specified networks
  --endpoint=IP         Specify external IP (for servers behind NAT)
  -y, --yes             Non-interactive mode (all confirmations auto-yes)
  --no-tweaks           Skip hardening/optimization (no UFW, Fail2Ban, sysctl tweaks)
```

<a id="manage-cli-adv"></a>
### manage_amneziawg.sh

```
Options:
  -h, --help            Show help
  -v, --verbose         Verbose output (for list)
  --no-color            Disable colored output
  --conf-dir=PATH       Specify AWG directory (default: /root/awg)
  --server-conf=PATH    Specify server config file
  --json                JSON output (for stats command)
  --expires=DURATION    Expiry duration for add (1h, 12h, 1d, 7d, 30d, 4w)
  --apply-mode=MODE     syncconf (default) or restart (bypass kernel panic)
```

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `AWG_SKIP_APPLY=1` | Skip apply_config. For automation: accumulate N operations, apply once |
| `AWG_APPLY_MODE=restart` | Full restart instead of syncconf (can be saved in `awgsetup_cfg.init`) |

---

<a id="manage-commands-adv"></a>
## 🧑‍💻 Full List of Management Commands

Usage: `sudo bash /root/awg/manage_amneziawg.sh <command>`:

* **`backup`:** Create a backup (configs + keys + client expiry data + cron).
* **`restore [file]`:** Restore from a backup (including expiry data and cron job).
* **`bot <on|off|setup|status>`:** Telegram bot management. `setup` to link Bot Token and Chat ID.
* **`warp <on|off|status|mode>`:** Cloudflare WARP management. Modes: `warp-only` (tunneling via WARP) and `direct` (normal mode).
* **`limit <name> <down> <up>|clear`:** Set speed limits (e.g., `10mbit 5mbit`) or clear them for a client.
* **`server`:** Detailed system statistics and VPN server status.
* **`check` / `status`:** Check server status (service, port, AWG 2.0 parameters).
* **`show`:** Run `awg show`.
* **`restart`:** Restart the AmneziaWG service.
* **`help`:** Show help.
* **`stats [--json]`:** Per-client traffic statistics. With `--json` — machine-readable format for integration.

### Usage Examples

```bash
# Setup Telegram Bot
sudo bash /root/awg/manage_amneziawg.sh bot setup

# Enable WARP (Dual VPN)
sudo bash /root/awg/manage_amneziawg.sh warp on

# Limit client speed to 50 Mbit
sudo bash /root/awg/manage_amneziawg.sh limit my_phone 50mbit 50mbit

# Clear limits
sudo bash /root/awg/manage_amneziawg.sh limit my_phone clear

# View system statistics
sudo bash /root/awg/manage_amneziawg.sh server
```

---

<a id="telegram-bot-adv"></a>
## 🤖 Telegram Bot

The script includes an interactive Telegram bot for remote server management.

**Features:**
*   **Client Management:** Add and remove clients directly from the chat.
*   **Statistics:** View traffic for each client.
*   **Monitoring:** The "Server" button shows CPU, RAM, Disk usage, and VPN uptime.
*   **Security:** The bot only responds to commands from the administrator (via Chat ID).

**Setup:**
1.  Create a bot via [@BotFather](https://t.me/BotFather) to get a **Token**.
2.  Obtain your **Chat ID** (e.g., via [@userinfobot](https://t.me/userinfobot)).
3.  Run setup: `sudo bash /root/awg/manage_amneziawg.sh bot setup`
4.  Enable the bot: `sudo bash /root/awg/manage_amneziawg.sh bot on`

The bot service is managed via systemd (`awg-bot.service`).

---

<a id="warp-limits-adv"></a>
## 🌐 Cloudflare WARP and Speed Limits

### Cloudflare WARP
Integration allows rerouting traffic from your VPN server into the Cloudflare network. Useful for:
1.  **Hiding your VPS IP** from target resources.
2.  **Accessing services** that block data center IPs.
3.  **Bypassing restrictions** of the hosting provider itself.

**Commands:**
*   `warp setup`: Install `warp-cli` client and register.
*   `warp on/off`: Enable/disable routing via WARP.
*   `warp mode`: Switch between modes (global proxy or selective).

### Speed Limits (Traffic Control)
Uses the system `tc` utility to limit client bandwidth.

**Important:** Limits are applied "on-the-fly" and stored in the server configuration. They are automatically reapplied upon interface restart.

**Example:** `sudo bash /root/awg/manage_amneziawg.sh limit user1 100mbit 100mbit`

---

---

<a id="tech-details-adv"></a>
## 🛠️ Technical Details

<a id="architecture-adv"></a>
### Script Architecture

| File | Purpose |
|------|---------|
| `install_amneziawg.sh` | Installer: 8-step state machine with resume support |
| `manage_amneziawg.sh` | Management: add/remove/list/regen/stats/backup/restore |
| `awg_common.sh` | Shared library: keys, configs, QR, peer management |
| `install_amneziawg_en.sh` | Installer (English version) |
| `manage_amneziawg_en.sh` | Management (English version) |
| `awg_common_en.sh` | Shared library (English version) |

`awg_common.sh` is loaded via `source` from both scripts. The installer downloads it at step 5.

```mermaid
graph TD
    A[install_amneziawg.sh] -->|"source (step 6)"| C[awg_common.sh]
    B[manage_amneziawg.sh] -->|"source"| C
    A -->|"wget (step 5)"| B
    A -->|"wget (step 5)"| C

    subgraph "State Machine (install)"
        S0[Step 0: Init] --> S1[Step 1: Update]
        S1 -->|reboot| S2[Step 2: DKMS]
        S2 -->|reboot| S3[Step 3: Module]
        S3 --> S4[Step 4: UFW]
        S4 --> S5[Step 5: Scripts]
        S5 --> S6[Step 6: Configs]
        S6 --> S7[Step 7: Service]
        S7 --> S99[Step 99: Done]
    end

    subgraph "Commands (manage)"
        M1[add / remove]
        M2[list / show / check]
        M3[modify / regen]
        M4[backup / restore]
        M5[restart]
        M6[stats / stats --json]
    end
```

<a id="dkms-adv"></a>
### DKMS

Ensures automatic rebuilding of the `amneziawg` kernel module on kernel updates. Check: `dkms status`.

<a id="keygen-adv"></a>
### Key and Config Generation

**Fully native** generation:
* **Keys:** `awg genkey` + `awg pubkey` (standard AmneziaWG utilities).
* **Configs:** Bash templates with AWG 2.0 parameters.
* **QR codes:** `qrencode -t png`.
* **Python/awgcfg.py:** Completely removed. The config deletion bug workaround is no longer needed.

Client keys are stored in `/root/awg/keys/` (permissions 600). Server keys are in `/root/awg/server_private.key` and `server_public.key`.

#### Version-Pinned URLs (v5.7.2)

The installer downloads `awg_common.sh` and `manage_amneziawg.sh` from URLs pinned to the specific version tag:

```
https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.8.0/awg_common.sh
```

This provides **supply chain pinning** — ensuring downloaded scripts match the installer version, even if `main` has already been updated.

For development, you can override the branch:

```bash
AWG_BRANCH=my-feature-branch sudo bash ./install_amneziawg_en.sh
```

---

<a id="update-scripts-adv"></a>
## 🔄 How to Update Scripts

To update the management and shared library scripts **without reinstalling the server**:

```bash
# Russian version:
wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.8.0/manage_amneziawg.sh
wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.8.0/awg_common.sh

# English version:
wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.8.0/manage_amneziawg_en.sh
wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.8.0/awg_common_en.sh

# Set permissions
chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh
```

> **Note:** Reinstalling `install_amneziawg.sh` is **not required** for management updates. A reinstallation is only necessary when switching protocol versions.

---

<a id="faq-advanced-adv"></a>
## ❓ FAQ (Additional Questions)

<details>
  <summary><strong>Q: How do I change the AmneziaWG port after installation?</strong></summary>
  <b>A:</b> 1. Change <code>ListenPort</code> in <code>/etc/amnezia/amneziawg/awg0.conf</code>. 2. Change <code>AWG_PORT</code> in <code>/root/awg/awgsetup_cfg.init</code>. 3. Update UFW (<code>sudo ufw delete allow &lt;old_port&gt;/udp</code>, <code>sudo ufw allow &lt;new_port&gt;/udp</code>). 4. Restart the service (<code>sudo systemctl restart awg-quick@awg0</code>). 5. <b>Regenerate ALL client configs</b> (<code>sudo bash /root/awg/manage_amneziawg.sh regen</code>) and distribute them.
</details>

<details>
  <summary><strong>Q: How do I change the internal VPN subnet?</strong></summary>
  <b>A:</b> The easiest way is to uninstall (<code>sudo bash ./install_amneziawg_en.sh --uninstall</code>) and reinstall, specifying the new subnet during initial setup.
</details>

<details>
  <summary><strong>Q: How do I change the MTU?</strong></summary>
  <b>A:</b> Starting with v5.7.4, <code>MTU = 1280</code> is set automatically. To change it: edit the <code>MTU = &lt;value&gt;</code> line in the <code>[Interface]</code> section of <code>/etc/amnezia/amneziawg/awg0.conf</code> and in client <code>.conf</code> files. Restart the service. See <a href="#mtu-mobile-adv">MTU and Mobile Clients</a> for details.
</details>

<details>
  <summary><strong>Q: Where are the AWG 2.0 parameters stored?</strong></summary>
  <b>A:</b> In <code>/root/awg/awgsetup_cfg.init</code> (variables AWG_Jc, AWG_S1..S4, AWG_H1..H4, AWG_I1). These same parameters are written to the server and client configs.
</details>

<details>
  <summary><strong>Q: Can I change AWG 2.0 parameters after installation?</strong></summary>
  <b>A:</b> Yes. This is useful if your ISP started fingerprinting your server by static obfuscation parameters (e.g. Russian DPI blocked specific H1-H4 ranges). Workflow as of v5.8.0:
  <ol>
    <li>Edit parameters (Jc, S1-S4, H1-H4, I1) in the <code>[Interface]</code> section of <code>/etc/amnezia/amneziawg/awg0.conf</code>.</li>
    <li>Restart the service: <code>sudo systemctl restart awg-quick@awg0</code>.</li>
    <li>Regenerate every client config: <code>sudo bash /root/awg/manage_amneziawg.sh regen &lt;name&gt;</code>. As of v5.8.0, <code>regen</code> reads live values directly from <code>awg0.conf</code> (the source of truth) instead of the cached <code>awgsetup_cfg.init</code>.</li>
    <li>Distribute the new <code>.conf</code> / QR codes / vpn:// URIs to clients.</li>
  </ol>
  <b>Important:</b> server and client parameters must match — otherwise the handshake fails. The easiest way to get a fresh set of randomized non-overlapping H1-H4 ranges is to reinstall the server (<code>--uninstall</code> followed by a fresh install) — every install generates a unique set.
</details>

<details>
  <summary><strong>Q: Server behind NAT — how do I specify the external IP?</strong></summary>
  <b>A:</b> Use the <code>--endpoint=&lt;external_IP&gt;</code> flag during installation: <code>sudo bash ./install_amneziawg_en.sh --endpoint=1.2.3.4</code>. Or specify it later via <code>sudo bash /root/awg/manage_amneziawg.sh regen</code> (the script will attempt to detect the IP automatically).
</details>

<details>
  <summary><strong>Q: How do I set up port forwarding (NAT) for AmneziaWG?</strong></summary>
  <b>A:</b> If the server is behind NAT (e.g., in a cloud with a private IP): 1. Forward the AmneziaWG UDP port (default 39743) to the external IP. 2. During installation, specify the external IP: <code>--endpoint=EXTERNAL_IP</code>. 3. Make sure the provider's firewall allows incoming UDP on that port.
</details>

<details>
  <summary><strong>Q: How do I change DNS for all existing clients?</strong></summary>
  <b>A:</b> Use the <code>modify</code> command for each client: <code>sudo bash /root/awg/manage_amneziawg.sh modify &lt;name&gt; DNS "8.8.8.8,1.0.0.1"</code>. Then regenerate configs: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>. To change the default DNS for new clients, edit <code>awg_common.sh</code>.
</details>

<details>
  <summary><strong>Q: How do I monitor VPN traffic?</strong></summary>
  <b>A:</b> 1. Current connections: <code>sudo awg show</code>. 2. Transfer stats: <code>sudo awg show awg0 transfer</code>. 3. Service logs: <code>sudo journalctl -u awg-quick@awg0 -f</code>. 4. Overall status: <code>sudo bash /root/awg/manage_amneziawg.sh check</code>.
</details>

<details>
  <summary><strong>Q: "Invalid key: s3" error when importing config in the Windows client?</strong></summary>
  <b>A:</b> You're using an outdated version of <code>amneziawg-windows-client</code> (< 2.0.0) that doesn't understand AWG 2.0 parameters. Update to <a href="https://github.com/amnezia-vpn/amneziawg-windows-client/releases"><b>version 2.0.0+</b></a>. Alternatively, use <a href="https://github.com/amnezia-vpn/amnezia-client/releases"><b>Amnezia VPN</b></a> >= 4.8.12.7.
</details>

<details>
  <summary><strong>Q: DKMS error after kernel update — what should I do?</strong></summary>
  <b>A:</b> 1. Check status: <code>dkms status</code>. 2. Try rebuilding: <code>sudo dkms install amneziawg/$(dkms status | grep amneziawg | head -1 | awk -F'[,/ ]+' '{print $2}')</code>. 3. Make sure kernel headers are installed: <code>sudo apt install linux-headers-$(uname -r)</code>. 4. If the error persists, run diagnostics: <code>sudo bash ./install_amneziawg_en.sh --diagnostic</code>.
</details>

<details>
  <summary><strong>Q: Detailed steps for VPN migration to another server?</strong></summary>
  <b>A:</b> 1. On the old server: <code>sudo bash /root/awg/manage_amneziawg.sh backup</code>. 2. Copy the archive: <code>scp root@old_server:/root/awg/backups/awg_backup_*.tar.gz .</code>. 3. Install AmneziaWG on the new server. 4. Copy the backup: <code>scp awg_backup_*.tar.gz root@new_server:/root/awg/backups/</code>. 5. Restore: <code>sudo bash /root/awg/manage_amneziawg.sh restore</code> (interactive selection, or specify the full archive path). 6. Regenerate configs with new IP: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>. 7. Distribute new configs to clients.
</details>

<details>
  <summary><strong>Q: Smartphone doesn't connect over cellular / doesn't work on iPhone</strong></summary>
  <b>A:</b> Add <code>MTU = 1280</code> to the <code>[Interface]</code> section of both server and client configs. Cellular networks have lower MTU than the default 1420, and iOS is strict about PMTU. See <a href="#mtu-mobile-adv">MTU and Mobile Clients</a> for details.
</details>

<details>
  <summary><strong>Q: Does AmneziaWG work in an LXC container?</strong></summary>
  <b>A:</b> No. AmneziaWG requires loading a kernel module via DKMS. LXC containers share the host kernel and cannot load custom modules. Use a full VM (KVM/QEMU) or bare-metal.
</details>

<details>
  <summary><strong>Q: <code>--endpoint</code> is rejected with "Invalid --endpoint" — what should I check?</strong></summary>
  <b>A:</b> As of v5.8.0, the value of <code>--endpoint</code> is validated before it is written to config files. Three formats are accepted: FQDN (<code>vpn.example.com</code>), IPv4 (<code>1.2.3.4</code>), and bracketed IPv6 (<code>[2001:db8::1]</code>). Newlines, CR, single and double quotes, backslash, spaces, and tabs are rejected — they could inject lines into <code>awgsetup_cfg.init</code> and client <code>.conf</code> files. IPv6 addresses must be wrapped in <code>[]</code>. If <code>AWG_ENDPOINT</code> in <code>awgsetup_cfg.init</code> fails validation on a later run, the installer emits <code>log_warn</code> and falls back to automatic detection via <code>get_server_public_ip</code>.
</details>

<details>
  <summary><strong>Q: "Another install_amneziawg.sh instance is already running" — what is this?</strong></summary>
  <b>A:</b> As of v5.8.0, the installer takes a process-wide <code>flock</code> on <code>/root/awg/.install.lock</code> at the beginning of <code>initialize_setup()</code>. This prevents two parallel runs from racing each other on <code>apt-get</code> and corrupting package state. If you see this error but no second installer is actually running (hung / crashed process), remove <code>/root/awg/.install.lock</code> and try again.
</details>

<details>
  <summary><strong>Q: Why did <code>--uninstall</code> not disable UFW?</strong></summary>
  <b>A:</b> This is the expected behaviour as of v5.8.0. The installer writes a marker file <code>/root/awg/.ufw_enabled_by_installer</code> <b>only if it had to enable UFW itself</b> (UFW was in <code>inactive</code> state before the install). During <code>--uninstall</code>, UFW is disabled <b>only</b> when that marker is present. If UFW was already active on the VPS before this script was installed (for example, protecting SSH or web services), <code>--uninstall</code> will remove our own rules (VPN port, <code>awg0</code> routing) but leave UFW running. This protects your firewall posture from destructive uninstall on a VPS that was already hardened. If you want to force UFW off anyway — run <code>ufw disable</code> manually.
</details>

<details>
  <summary><strong>Q: <code>regen</code> says "required AWG parameters missing" — what do I do?</strong></summary>
  <b>A:</b> As of v5.8.0, <code>load_awg_params</code> reads AWG parameters directly from the live <code>/etc/amnezia/amneziawg/awg0.conf</code> instead of the cached <code>awgsetup_cfg.init</code>. If you edited <code>awg0.conf</code> by hand and accidentally removed or corrupted one of the required fields (Jc, Jmin, Jmax, S1-S4, H1-H4), <code>regen</code> will fail with this error <b>instead of</b> silently using stale values from the init file. This is split-brain protection between server and clients. How to fix: (1) check that all 11 fields are present with <code>grep -E "^(Jc|Jmin|Jmax|S[1-4]|H[1-4]) = " /etc/amnezia/amneziawg/awg0.conf</code>; (2) if a field was removed, restore it from <code>/root/awg/awgsetup_cfg.init</code> or from an <code>awg0.conf.bak-*</code> backup; (3) restart the service and retry <code>regen</code>.
</details>

<details>
  <summary><strong>Q: Which client should I use for AWG 2.0?</strong></summary>
  <b>A:</b> Recommended: <a href="https://github.com/amnezia-vpn/amnezia-client/releases">Amnezia VPN</a> (version >= 4.8.12.7). Native AmneziaWG clients for Android and iOS also work. The standard WireGuard client <b>does not</b> support AWG parameters. See <a href="#client-compat-adv">AWG 2.0 Client Compatibility</a> for the full table.
</details>

<details>
  <summary><strong>Q: How do I limit bandwidth for clients?</strong></summary>
  <b>A:</b> AmneziaWG has no built-in bandwidth limiting. Use <code>tc</code> (traffic control): <code>sudo tc qdisc add dev awg0 root tbf rate 100mbit burst 32kbit latency 400ms</code>. This limits total interface throughput. For per-client limits, a more complex setup with <code>tc</code> and <code>iptables</code> (mark + class) is required.
</details>

---

<a id="diag-uninstall-adv"></a>
## 🩺 Diagnostics and Uninstall

* **Diagnostics:** `sudo bash /path/to/install_amneziawg_en.sh --diagnostic`. The report (including AWG 2.0 parameters) is saved to `/root/awg/diag_*.txt`.
* **Uninstall:** `sudo bash /path/to/install_amneziawg_en.sh --uninstall`. Will ask for confirmation and offer to create a backup.

<a id="diagnostic-report-adv"></a>
### Diagnostic Report Contents

The report (`--diagnostic`) includes the following sections:

| Section | Description |
|---------|-------------|
| OS | OS and kernel version |
| Hardware | RAM, CPU, Swap |
| Configuration | Contents of `awgsetup_cfg.init` |
| Server Config | `awg0.conf` (private key hidden) |
| Service Status | Systemd service status |
| AWG Status | Output of `awg show` |
| Network | Interfaces, ports, routes |
| Firewall | UFW rules |
| Journal | Last 50 lines of service log |
| DKMS | Kernel module status |

---

<a id="troubleshooting-adv"></a>
## 🔧 Troubleshooting (Detailed)

<details>
<summary><strong>No internet after connecting to VPN</strong></summary>

1. Check IP forwarding: `sysctl net.ipv4.ip_forward` (should be 1)
2. Check NAT rules: `iptables -t nat -L POSTROUTING -v`
3. Check client AllowedIPs (routing mode)
4. Check DNS: `nslookup google.com` from VPN
5. Check MTU: `ping -s 1280 -M do <server_IP>` — if it fails, reduce MTU
</details>

<details>
<summary><strong>Handshake succeeds but traffic doesn't flow</strong></summary>

1. Check MTU: add `MTU = 1280` to `[Interface]` in both server and client configs
2. Check iptables: `iptables -L FORWARD -v` — there should be an ACCEPT rule for awg0
3. Check NIC: `ip route get 1.1.1.1` — make sure PostUp/PostDown use the correct interface
</details>

<details>
<summary><strong>Port is occupied by another process</strong></summary>

1. Identify the process: `ss -lunp | grep :<port>`
2. Change the AmneziaWG port or stop the conflicting service
3. For port change instructions, see the FAQ "How do I change the port"
</details>

---

<a id="stats-adv"></a>
## 📊 Traffic Statistics (stats)

The `stats` command displays per-client traffic statistics.

**Standard output:**

```bash
sudo bash /root/awg/manage_amneziawg.sh stats
```

```
Client          Received        Sent            Latest handshake
───────────────────────────────────────────────────────────────────
my_phone        1.24 GiB        356.7 MiB       2 minutes ago
laptop          892.3 MiB       128.4 MiB       15 seconds ago
guest           0 B             0 B             (none)
```

**JSON output:**

```bash
sudo bash /root/awg/manage_amneziawg.sh stats --json
```

```json
[
  {
    "name": "my_phone",
    "ip": "10.9.9.2",
    "rx": 1332477952,
    "tx": 374083174,
    "last_handshake": 1710312180,
    "status": "active"
  }
]
```

---

<a id="expires-adv"></a>
## ⏳ Temporary Clients (--expires)

Create clients with automatic removal after expiration.

**Creating:**

```bash
sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d
```

**Duration formats:**

| Format | Description |
|--------|-------------|
| `1h` | 1 hour |
| `12h` | 12 hours |
| `1d` | 1 day |
| `7d` | 7 days |
| `30d` | 30 days |
| `4w` | 4 weeks |

**How it works:**

1. When a client is created with `--expires`, an expiration timestamp is saved to `/root/awg/expiry/<name>`.
2. A cron job `/etc/cron.d/awg-expiry` checks every 5 minutes.
3. Expired clients are automatically removed (config, keys, server config entry).
4. When the last expiry client is removed, the cron job is automatically cleaned up.

**Checking:** `list -v` shows remaining time for each client with an expiry.

---

<a id="vpnuri-adv"></a>
## 📱 vpn:// URI Import

When a client is created, a `.vpnuri` file is automatically generated with a `vpn://` URI for quick import into Amnezia Client.

**File location:** `/root/awg/<client_name>.vpnuri`

**Format:** The configuration is compressed via zlib (Perl `Compress::Zlib`) and Base64-encoded, forming a URI like `vpn://...`.

> Perl with `Compress::Zlib` and `MIME::Base64` modules must be present on the server. On Ubuntu and Debian they are installed by default. If Perl is absent, `.vpnuri` files are not created, but `.conf` files work as usual.

**Using with Amnezia Client:**

1. Copy the contents of the `.vpnuri` file
2. Open Amnezia Client
3. "Add VPN" → "Paste from clipboard"
4. The configuration is imported automatically

**Permissions:** `.vpnuri` files have 600 permissions (root only).

---

<a id="mtu-mobile-adv"></a>
## 📱 MTU and Mobile Clients

Starting with v5.7.4, `MTU = 1280` is set automatically in both server and client configs.

**Why:** Cellular networks (4G/LTE) often have an effective MTU below the default 1420, causing packet fragmentation or drops. iOS is strict about Path MTU Discovery and may fail to connect. 1280 is the minimum IPv6 MTU (RFC 8200), guaranteed to pass through any network. The speed impact is negligible.

**For installations before v5.7.4:**

Add `MTU = 1280` to the `[Interface]` section of both server and client configs manually. Restart the service:

```bash
sudo systemctl restart awg-quick@awg0
```

> vpn:// URIs for Amnezia Client have always included MTU = 1280 in all script versions.

---

<a id="client-compat-adv"></a>
## 📋 AWG 2.0 Client Compatibility

Not all clients support AWG 2.0. Check compatibility before choosing a client:

| Client | Platform | AWG 1.x | AWG 2.0 | Notes |
|--------|----------|---------|---------|-------|
| [Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases) | Windows, macOS, Linux, Android, iOS | ✅ | ✅ (>= 4.8.12.7) | Recommended. Supports vpn:// URI import |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-android) | Android | ✅ | ✅ (>= 2.0.0) | Lightweight tunnel manager. Import via `.conf` |
| [WG Tunnel](https://github.com/wgtunnel/android) | Android | ✅ | ⚠️ | FOSS client with auto-tunneling, split tunneling, F-Droid. AWG 2.0 — partial support |
| [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) | iOS | ✅ | ✅ | Native WG client for iOS |
| [WireSock VPN Client](https://www.ntkernel.com) | Windows | ✅ | ✅ | Commercial. Userspace WireGuard via NDISAPI |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) | Windows | ✅ | ✅ (>= 2.0.0) | Lightweight tunnel manager. Import via `.conf` |
| Standard WireGuard | All | ❌ | ❌ | Does not support AWG parameters |

> If a client shows an error about an unknown parameter (S3, S4, I1, or H1 as a range), use one of the first four clients in the table.

### Router Clients

| Project | Platform | Description |
|---------|----------|-------------|
| [AWG Manager](https://github.com/hoaxisr/awg-manager) | Keenetic (Entware) | Web interface for managing AWG tunnels on Keenetic routers |
| [AmneziaWG for Merlin](https://github.com/r0otx/asuswrt-merlin-amneziawg) | ASUS (Asuswrt-Merlin) | AWG 2.0 addon with web UI, GeoIP/GeoSite routing |

---

<a id="debian-support-adv"></a>
## 🐧 Debian Support

Starting with v5.6.0, the installer fully supports Debian 12 (bookworm) and Debian 13 (trixie).

**Ubuntu vs Debian differences:**

| Aspect | Ubuntu 24.04 | Debian 12 (bookworm) | Debian 13 (trixie) |
|--------|-------------|---------------------|-------------------|
| PPA codename | native | mapped to `focal` | mapped to `noble` |
| APT format | DEB822 `.sources` | `.list` | DEB822 `.sources` |
| Headers | `linux-headers-$(uname -r)` | fallback to `linux-headers-amd64` | fallback to `linux-headers-amd64` |
| deb-src | Yes | No | No |
| snapd/lxd cleanup | Yes | Skipped | Skipped |

**Debian prerequisites:**

Minimal Debian installations do not include `curl`:

```bash
apt-get update && apt-get install -y curl
```

**Expected warnings:**

During installation on Debian, you may see a `sudo removal refused` warning — this is normal, as Debian uses `sudo` as a system package and the script correctly skips its removal.

---

<a id="limitations-adv"></a>
## ⚠️ Known Limitations

* **LXC containers are not supported.** AmneziaWG requires a kernel module (DKMS). LXC shares the host kernel — loading a custom module from inside a container is not possible. Use a full VM or bare-metal server.

* **Assumes a dedicated server.** The script configures UFW, Fail2Ban, sysctl and optimizes the system for VPN. On servers running other services, use `--no-tweaks` to skip hardening.

* **Single AWG protocol version per server.** All clients share the same obfuscation parameters. You cannot have some clients on AWG 1.x and others on 2.0 simultaneously.

* **Ubuntu 25.10 / Debian 13:** The PPA may not have prebuilt packages. The installer builds the module from source via DKMS, which takes longer on first install.

---

<a id="contributing-adv"></a>
## 🤝 Contributing

Suggestions and fixes are welcome! Create an Issue or Pull Request in the [repository](https://github.com/bivlked/amneziawg-installer).

---

<a id="thanks-adv"></a>
## 💖 Acknowledgements

* The [Amnezia VPN](https://github.com/amnezia-vpn) team.

---

<p align="center">
  <a href="#amneziawg-20-installer-advanced-documentation">↑ Back to top</a>
</p>
