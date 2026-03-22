# Ubuntu Server Setup

### BSNL Static IP · SSH · UFW Firewall · Fail2Ban · Admin User

> Script repo: [github.com/desiEdgeCode/server_setup](https://github.com/desiEdgeCode/server_setup)

---

## Prerequisites

| Requirement | Notes |
| ----------- | ----- |
| Ubuntu 20.04+ | Desktop or Server edition |
| root or a user with `sudo` | Script works either way |
| Static public IP from BSNL | Already purchased |
| Router admin access | For port forwarding |

---

## Quick Start

**Download and run in one go:**

```bash
# wget
wget -O ubuntu_server_setup.sh https://raw.githubusercontent.com/desiEdgeCode/server_setup/main/ubuntu_server_setup.sh
chmod +x ubuntu_server_setup.sh
./ubuntu_server_setup.sh

# curl
curl -o ubuntu_server_setup.sh https://raw.githubusercontent.com/desiEdgeCode/server_setup/main/ubuntu_server_setup.sh
chmod +x ubuntu_server_setup.sh
./ubuntu_server_setup.sh
```

**Or clone the repo:**

```bash
git clone https://github.com/desiEdgeCode/server_setup.git
cd server_setup
chmod +x ubuntu_server_setup.sh
./ubuntu_server_setup.sh
```

Other modes:

```bash
sudo ./ubuntu_server_setup.sh --status    # check all components
sudo ./ubuntu_server_setup.sh --repair    # re-fix broken components
```

---

## Privilege Handling

The script detects your permission level automatically at startup:

| Situation | Behaviour |
| --------- | --------- |
| Running as **root** | Continues immediately |
| Running as a **sudo-capable user** | Prompts to re-launch with `sudo` automatically (recommended — press Enter) |
| **No sudo / no root** | Exits with instructions on how to fix it |

---

## What the Script Installs

### 1 — System Update

Updates all packages before anything else is configured.

### 2 — OpenSSH Server

Installs `openssh-server` and enables it on boot.

### 3 — SSH Hardening

Writes a clean `/etc/ssh/sshd_config` with these settings:

| Setting | Value | Reason |
| ------- | ----- | ------ |
| Port | **2222** | Avoids mass scanners targeting 22; BSNL often blocks port 22 |
| PermitRootLogin | yes | Personal server — root login allowed |
| PasswordAuthentication | yes | Enabled initially — switch to keys later |
| UsePAM | yes | Required for password auth on Ubuntu |
| MaxAuthTries | 4 | Limits password guessing per connection |
| LoginGraceTime | 30s | Shorter window for unauthenticated connections |
| X11Forwarding | no | Not needed on a headless server |

> Original config is backed up to `/etc/ssh/sshd_config.bak`. The new config is validated with `sshd -t` before restarting — if it has errors, the backup is auto-restored.

### 4 — UFW Firewall

- Default policy: **deny all inbound, allow all outbound**
- Always opens:

| Port | Purpose |
| ---- | ------- |
| 2222/tcp | SSH |
| 80/tcp | HTTP |
| 443/tcp | HTTPS |

### 5 — Fail2Ban

Blocks IPs that repeatedly fail SSH login:

- Bans after **4 failed attempts** within 10 minutes
- Ban lasts **1 hour**
- Config at `/etc/fail2ban/jail.local`

### 6 — Admin User Creation

Always runs. You are prompted once for the username (default: `webadmin`).

Creates the user with:
- `sudo` group membership + passwordless sudo
- `~/.ssh/authorized_keys` prepared for key-based login later
- Password set interactively during setup

Root login is **enabled** — you can SSH as `root` directly or as `webadmin`.

### 7 — Static Local IP via Netplan

Always auto-detects your interface, current IP, and gateway, then shows them and asks for **confirmation only**. Say `y` to lock it static, `n` to skip.

Locking the local IP is recommended — your router's port forwarding rules target a specific local IP. If DHCP reassigns a different one after reboot, port forwarding breaks.

---

## Router Port Forwarding (BSNL)

This is the most important manual step. Without it the server cannot be reached from outside your home.

### How it works

Your BSNL router receives your static public IP. By default it blocks all inbound connections. Port forwarding tells the router: *"when someone hits my public IP on port X, forward it to local machine Y"*.

### Steps

1. Open your router admin panel in a browser:
   - BSNL FTTH (ZTE/Huawei): `192.168.1.1` or `192.168.0.1`
   - Credentials are printed on the router label (often `admin` / `admin`)
2. Find **Port Forwarding** (may be called Virtual Server, NAT, or Applications & Gaming)
3. Add these rules:

| Name | External Port | Internal IP | Internal Port | Protocol |
| ---- | ------------- | ----------- | ------------- | -------- |
| SSH | 2222 | *(server local IP)* | 2222 | TCP |
| HTTP | 80 | *(server local IP)* | 80 | TCP |
| HTTPS | 443 | *(server local IP)* | 443 | TCP |

> Run `./ubuntu_server_setup.sh --status` to see your server's current local IP.

4. Save and apply.
5. Test from mobile data (not your home WiFi):

```bash
ssh -p 2222 root@YOUR_BSNL_STATIC_IP
```

### BSNL Notes

- Port 22 is commonly blocked by BSNL — the script uses **port 2222** to avoid this.
- Ports 80 and 443 may be blocked on residential connections. Call BSNL and ask them to unblock these if web hosting doesn't work from outside.
- If you have a BSNL modem in **bridge mode** behind your own router, configure port forwarding on **your router**, not the BSNL modem.
- Your static IP never changes, so you only need to configure this once.

---

## Switching to SSH Key Authentication (Recommended Later)

Once your server is working, switch from password to key-based login:

**On your local machine:**

```bash
ssh-keygen -t ed25519 -C "myserver"
ssh-copy-id -p 2222 root@YOUR_SERVER_IP
```

**On the server**, after verifying key login works:

```bash
nano /etc/ssh/sshd_config
# Change:  PasswordAuthentication yes  →  PasswordAuthentication no
systemctl restart ssh
```

---

## Maintenance Commands

```bash
# Re-check and fix all components
./ubuntu_server_setup.sh --repair

# View all service statuses + IPs
./ubuntu_server_setup.sh --status

# View setup log
cat /var/log/ubuntu_server_setup.log

# See who Fail2Ban has banned
fail2ban-client status sshd

# Unban an IP
fail2ban-client unban <IP>

# View firewall rules
ufw status numbered

# Restart SSH
systemctl restart ssh
```

---

## Troubleshooting

| Problem | What to check |
| ------- | ------------- |
| `Connection refused` on SSH | `ufw status` — is port 2222 open? `systemctl status ssh` — is it running? |
| SSH works on LAN but not internet | Port forwarding not set up, or wrong local IP in the router rule |
| Got locked out by Fail2Ban | Wait 1 hour, or: `fail2ban-client unban YOUR_IP` |
| Static IP broke the network | Boot to recovery, delete `/etc/netplan/99-static-server.yaml`, reboot |
| Script fails partway through | Run `./ubuntu_server_setup.sh --repair` |

---

## File Locations

| Path | Purpose |
| ---- | ------- |
| `/etc/ssh/sshd_config` | SSH daemon config |
| `/etc/ssh/sshd_config.bak` | Original SSH config backup |
| `/etc/fail2ban/jail.local` | Fail2Ban rules |
| `/etc/netplan/99-static-server.yaml` | Static local IP (if configured) |
| `/var/log/ubuntu_server_setup.log` | Script run log |

---

## Quick Reference

```bash
# SSH in from anywhere
ssh -p 2222 root@YOUR_BSNL_STATIC_IP

# Script modes
./ubuntu_server_setup.sh              # full setup
./ubuntu_server_setup.sh --repair     # fix broken parts
./ubuntu_server_setup.sh --status     # show current status
```
