# Ubuntu Server Setup Guide

### BSNL Static IP · SSH · Firewall · Admin User

- - -

## Prerequisites

| Requirement | Notes |
| ----------- | ----- |
| Ubuntu 20.04+ | Desktop or Server edition |
| root or a user with `sudo` | Script works either way |
| Static public IP from BSNL | Already purchased |
| Router admin access | For port forwarding |

- - -

## Quick Start

```bash
chmod +x ubuntu_server_setup.sh
sudo ./ubuntu_server_setup.sh        # as a sudo user
# OR
./ubuntu_server_setup.sh             # if already root
```

Other modes:

```bash
sudo ./ubuntu_server_setup.sh --status    # check all components
sudo ./ubuntu_server_setup.sh --repair    # re-fix broken components
```

- - -

## What the Script Installs

### 1 — System Update

Updates all packages before anything else is configured.

### 2 — OpenSSH Server

Installs `openssh-server` and enables it on boot.

### 3 — SSH Hardening

Writes a clean `/etc/ssh/sshd_config` with secure defaults:

| Setting | Value | Reason |
| ------- | ----- | ------ |
| Port | **2222** | Avoids mass scanners targeting port 22; also avoids BSNL blocking port 22 |
| PermitRootLogin | yes | Personal server — root login allowed |
| PasswordAuthentication | yes | Enabled initially — switch to keys later |
| MaxAuthTries | 4 | Limits password guessing per connection |
| LoginGraceTime | 30s | Shorter window for unauthenticated connections |
| X11Forwarding | no | Not needed on a headless server |

> Original config is backed up to `/etc/ssh/sshd_config.bak`. The new config is validated with `sshd -t` before restarting — if it has errors, the backup is auto-restored.

### 4 — UFW Firewall

* Default policy: **deny all inbound, allow all outbound**
* Always opens:

| Port | Purpose |
| ---- | ------- |
| 2222/tcp | SSH |
| 80/tcp | HTTP |
| 443/tcp | HTTPS |

### 5 — Fail2Ban

Blocks IPs that repeatedly fail SSH login:

* Bans after **4 failed attempts** within 10 minutes
* Ban lasts **1 hour**
* Config at `/etc/fail2ban/jail.local`

### 6 — Admin User Creation

Always runs. You are prompted once for the username (default: `webadmin`).

Creates the user with:
- `sudo` group membership
- Passwordless sudo
- `~/.ssh/authorized_keys` prepared for key-based login later
- You set the password interactively during setup

Root login is **enabled** — you can SSH as `root` directly or as `webadmin`.

### 7 — Static Local IP via Netplan

Always runs detection. The script reads your interface, current IP, and gateway automatically, shows them to you, and asks **only for confirmation**. Say `y` to lock it, `n` to skip.

This is important — your router's port forwarding points to a fixed local IP. If DHCP assigns a different IP after reboot, port forwarding breaks.

### 8 — aaPanel (manual — after script)

Install aaPanel separately after this script runs. UFW ports 80 and 443 are already open.
See the **aaPanel** section below for the install command.

- - -

## Router Port Forwarding (BSNL)

This is the most important manual step. Without it the server cannot be reached from outside your home.

### How it works

Your BSNL router receives your static public IP from BSNL. By default it blocks all inbound connections. Port forwarding says: *"when someone hits my public IP on port X, send it to local machine Y"*.

### Steps

1. Open your router admin panel in a browser:
    * BSNL FTTH (ZTE/Huawei): `192.168.1.1` or `192.168.0.1`
    * Username/password are printed on the router label (often `admin` / `admin`)
2. Find **Port Forwarding** (may be called Virtual Server, NAT, or Applications & Gaming)
3. Add these rules:

| Name | External Port | Internal IP | Internal Port | Protocol |
| ---- | ------------- | ----------- | ------------- | -------- |
| SSH | 2222 | *(server local IP)* | 2222 | TCP |
| HTTP | 80 | *(server local IP)* | 80 | TCP |
| HTTPS | 443 | *(server local IP)* | 443 | TCP |
| aaPanel | 7800 | *(server local IP)* | 7800 | TCP |
| phpMyAdmin | 888 | *(server local IP)* | 888 | TCP |

> Run `./ubuntu_server_setup.sh --status` to see your server's current local IP.

4. Save and apply.
5. Test from mobile data (not your home WiFi):

```
ssh -p 2222 youruser@YOUR_BSNL_STATIC_IP
```

### BSNL Notes

* Port 22 is commonly blocked by BSNL — the script uses **port 2222** to avoid this.
* Port 80 and 443 may also be blocked on residential connections. If web hosting doesn't work from outside, call BSNL and ask them to unblock ports 80 and 443.
* If you have a BSNL modem in **bridge mode** behind your own router, set port forwarding on **your router**, not the BSNL modem.
* Your static IP won't change, so you only need to configure this once.

- - -

## aaPanel (Manual Install)

Run this **after** the setup script finishes (as root or via sudo):

``` bash
wget -O install.sh http://www.aapanel.com/script/install_6.0_en.sh
sudo bash install.sh
```

The installer takes 5–10 minutes. When done it prints your panel URL, username, and one-time password — **save them**.

Default panel URL:

```
http://YOUR_LOCAL_IP:7800
http://YOUR_PUBLIC_IP:7800   (after port forwarding on router)
```

Also add port forwarding for **7800** and **888** (phpMyAdmin) on your BSNL router to access the panel from outside.

On first login aaPanel asks you to install a web stack — choose **LNMP** (Nginx + MySQL + PHP). That's all you need for web hosting.

- - -

## Switching to SSH Key Authentication (Recommended Later)

Once your server is working, disable password login and use keys instead:

**On your local machine (the PC you connect from):**

``` bash
ssh-keygen -t ed25519 -C "myserver"
ssh-copy-id -p 2222 youruser@YOUR_SERVER_IP
```

**On the server**, after verifying key login works:

``` bash
sudo nano /etc/ssh/sshd_config
# Change:  PasswordAuthentication yes  →  PasswordAuthentication no
sudo systemctl restart ssh
```

- - -

## Maintenance Commands

``` bash
# Re-check and fix all components
./ubuntu_server_setup.sh --repair

# View all service statuses + IPs
./ubuntu_server_setup.sh --status

# View setup log
cat /var/log/ubuntu_server_setup.log

# See who Fail2Ban has banned
sudo fail2ban-client status sshd

# Unban an IP
sudo fail2ban-client unban <IP>

# View firewall rules
sudo ufw status numbered

# Restart SSH
sudo systemctl restart ssh
```

- - -

## Troubleshooting

| Problem | What to check |
| ------- | ------------- |
| `Connection refused` on SSH | `sudo ufw status` — is port 2222 open? `systemctl status ssh` — is it running? |
| SSH works on LAN but not internet | Port forwarding not set up, or wrong local IP in router rule |
| Got locked out by Fail2Ban | Wait 1 hour, or from router: `sudo fail2ban-client unban YOUR_IP` |
| aaPanel not reachable from internet | Port 7800 not forwarded, or BSNL blocking — try from local network first |
| Static IP broke the network | Boot to recovery, delete `/etc/netplan/99-static-server.yaml`, reboot |
| Script fails partway through | Run `./ubuntu_server_setup.sh --repair` |

- - -

## File Locations

| Path | Purpose |
| ---- | ------- |
| `/etc/ssh/sshd_config` | SSH daemon config |
| `/etc/ssh/sshd_config.bak` | Original SSH config backup |
| `/etc/fail2ban/jail.local` | Fail2Ban rules |
| `/etc/netplan/99-static-server.yaml` | Static local IP (if configured) |
| `/var/log/ubuntu_server_setup.log` | Script log |

- - -

## Quick Reference

``` bash
# Connect from anywhere
ssh -p 2222 youruser@YOUR_BSNL_STATIC_IP

# aaPanel
http://YOUR_BSNL_STATIC_IP:7800

# Script modes
./ubuntu_server_setup.sh              # full setup
./ubuntu_server_setup.sh --repair     # fix broken parts
./ubuntu_server_setup.sh --status     # show current status
```