# pcx: let an AI CLI on PC1 operate PC2

English ｜ [繁體中文](README.md)

PC2 only runs OpenSSH (no AI installed, nobody needs to be signed in). On PC1 you run `pcx <name> "<command>"` and get back the full output plus a final `[exit code: N]` line.
The same commands work over a LAN, a direct Ethernet cable, a VPN, a cloud VM or a jump host.

- **PC1**: the computer you are using. Requires Windows, PowerShell 7 (`pwsh`) and the OpenSSH client.
- **PC2**: the computer being operated: Windows or Ubuntu/Debian (or a cloud VM that already has SSH).

Other docs (Traditional Chinese): [AI-GUIDE.md](AI-GUIDE.md) (rules for AI agents) and [DEVELOPMENT.md](DEVELOPMENT.md) (design and development notes). The built-in help (`pcx help`) and all script messages are in Traditional Chinese.

## Setup

### Easiest: the interactive wizard (Windows PC2)

Double-click `WIZARD.cmd` (or run `pcx wizard`). The wizard asks step by step and runs the commands for you: installing pcx, choosing the network setup, generating the install folder, telling you to run `INSTALL.cmd` on PC2, registering and testing, offering to disable password login, and writing `AGENTS.md`. For hosts already registered, its menu can check whether they are online, harden, teardown (you must type the host name to confirm) or forget them. The wizard never asks for or stores any password. If PC2 runs Ubuntu, the wizard points you to `pcx guide` instead.

### Manual (about 3 steps)

**1. PC1: install pcx and generate the install folder for PC2**

```powershell
.\pcx.ps1 install                 # one-time; after reopening the terminal, pcx works from any folder
pcx invite windows                # or: pcx invite ubuntu
```

`invite` creates a plain-text folder `pcx-pc2-windows` / `pcx-pc2-ubuntu` in the current directory (scripts, your public key `pcx.pub` and a `README.txt`, with no encoding or obfuscation). Add `-SingleFile` to produce a single file instead, or `-Out <name>` to choose the output name.

**2. PC2: copy the whole folder over and run it**

- Windows: double-click `INSTALL.cmd`. It requests administrator rights through UAC by itself (right-click "Run as administrator" also works).
- Ubuntu: `bash install.sh` (runs through sudo).

At the end it prints the IP and a ready-to-copy `pcx add ...` command.

**3. PC1: register and test**

```powershell
pcx add pc2 admin@192.168.1.50    # register, test the connection and check admin/sudo rights on PC2
pcx pc2 "hostname"                # done when it prints PC2's name and [exit code: 0]
pcx harden pc2                    # recommended: disable password login on PC2 once the key works
pcx agents                        # optional: add "use pcx for remote work" to AGENTS.md in this folder
```

If the same PC2 (same user, address, port and jump host) is already registered under another name, `pcx add` refuses with `DUPLICATE_HOST`. Add `-Force` only if you really want both names.

**Updating pcx**: after `git pull`, run `pcx install` again from the project folder to copy the new version into `~\.pcx`.

## Built-in help and guide

The help text is built into `pcx.ps1`, so after `pcx install` you do not need this README:

```powershell
pcx guide            # shows how far setup has got (install → invite → PC2 install → add → rights → harden → agents) and the next command
pcx guide pc2        # same, and also checks whether pc2 is online
pcx help             # full manual
pcx help errors      # a single topic: setup admin errors env daily remove security ai notes
pcx wizard           # Windows wizard (for people; refuses to run in non-interactive terminals such as AI tools)
```

`pcx guide` only reads state. It never prompts and never changes anything, so an AI CLI can run it safely.

## Administrator / root rights

Many tasks need admin rights (installing services, changing settings, restarting services, `harden`, `teardown`). `pcx add` checks and records this; `pcx list` shows it.

| PC2 | How it works |
|---|---|
| Windows | Register with an **administrator account** on PC2 (the key is written to `administrators_authorized_keys`, which only applies to administrators). The SSH session is then already elevated, with no UAC prompt. For local administrator accounts, install sets `LocalAccountTokenFilterPolicy=1` (otherwise Windows filters remote logons of local accounts down to standard rights); the previous value is recorded and restored on removal. **This also gives full admin rights to other remote logons such as SMB/WinRM**, so make sure every local admin account has a strong password. |
| Ubuntu | SSH is non-interactive, so `sudo` fails if it asks for a password. Either ① add `-PasswordlessSudo` when generating the install folder (grants passwordless sudo, **equivalent to root**, revoked on removal), or ② leave it off and do root tasks yourself on PC2. AI agents always use `sudo -n` and never get your password. |

Without the needed rights, pcx raises `NO_ADMIN` (at registration), `ADMIN_REQUIRED` or `SUDO_PASSWORD_REQUIRED` (when running commands).

## When pcx cannot fix something: errorRequest

When pcx or the install scripts hit a problem they cannot solve, they print a fixed-format block:

```
[errorRequest:AUTH_REJECTED]
  問題: ...   (problem)
  需要: ...   (what you need to do)
```

Do what the "需要" (need) line says, then continue. An AI agent that sees this block stops and relays it to you. `[hint:...]` lines (such as `[hint:ENCODING]`) are only hints, not errors.

| Source | Codes |
|---|---|
| PC1 connection | `SSH_CLIENT_MISSING`, `HOST_NOT_REGISTERED`, `DUPLICATE_HOST`, `AUTH_REJECTED`, `UNREACHABLE`, `SSH_NOT_RUNNING`, `DNS_FAILED`, `HOSTKEY_CHANGED`, `KEY_UNREADABLE`, `NETWORK_BLOCKED`, `CONNECT_FAILED` |
| Rights and execution | `NO_ADMIN`, `ADMIN_REQUIRED`, `SUDO_PASSWORD_REQUIRED`, `RUN_TIMEOUT` |
| harden / removal | `HARDEN_PRECHECK_FAILED`, `HARDEN_NO_ADMIN`, `HARDEN_NO_SUDO`, `HARDEN_FAILED`, `HARDEN_VERIFY_FAILED`, `TEARDOWN_FAILED`, `UNINSTALL_PARTIAL` |
| PC2 install (Windows) | `WINDOWS_CAPABILITY_QUERY_FAILED`, `OPENSSH_NOT_AVAILABLE`, `OPENSSH_INSTALL_FAILED`, `SSHD_START_FAILED`, `NO_IP_ADDRESS` |
| PC2 install (Ubuntu) | `NOT_DEBIAN`, `NO_SYSTEMD`, `APT_FAILED`, `APT_UPGRADE_FAILED`, `SSHD_START_FAILED`, `SUDOERS_INVALID`, `NO_IP_ADDRESS` |

See `pcx help errors` for what each code means.

## Network setups

| Setup | How |
|---|---|
| LAN | Default (`-AllowFrom LocalSubnet`) |
| Direct Ethernet cable | Give both machines static IPs on the same subnet (e.g. 192.168.50.1 / .2); everything else is the same |
| VPN (Tailscale, etc.) | `pcx invite windows -AllowFrom 100.64.0.0/10`, then `pcx add` with the VPN IP or name |
| Specific source subnet | `pcx invite ubuntu -AllowFrom 192.168.1.0/24` |
| Cloud VM | Usually already has SSH and a key: `pcx add vm1 ubuntu@PUBLIC_IP -Key C:\keys\vm.pem`, no invite needed |
| Through a jump host | `pcx add pc2 admin@INTERNAL_IP -Jump user@jumphost` |
| Port other than 22 | Add `-Port 2222` to `pcx add` |

In the cloud, never open port 22 to the whole internet: restrict the security group to your fixed IP, or use a VPN.

## Daily use

```powershell
pcx pc2 "Get-Service sshd"            # PowerShell syntax on Windows, bash on Ubuntu
pcx pc2 -File .\fix.ps1               # run a local script on PC2 (.sh for Ubuntu)
pcx put pc2 .\app.zip C:/temp/app.zip # upload a file or folder (write Windows remote paths as C:/temp/x)
pcx get pc2 /var/log/syslog .\syslog  # download
pcx list                              # registered hosts, targets, OS and admin status; flags names that point to the same host
pcx status                            # check all registered hosts in parallel (about 5 s; exit code 1 if any is offline)
pcx clean                             # unregister hosts whose remote access is gone; offline ones are kept unless -IncludeOffline
pcx forget pc2                        # delete only PC1's local registration, without connecting to PC2 (old name: pcx remove)
```

- Remote commands run for at most 120 seconds by default (`-RunTimeout`); the connect timeout is 60 seconds (`-Timeout`).
- stdin is closed, so a command waiting for input does not hang; it reports `RUN_TIMEOUT` instead. Use non-interactive forms (`apt -y`, `sudo -n`).
- If output from a Chinese-locale Windows PC2 is garbled, add `-Encoding 950`.

## Removal

| Goal | Command |
|---|---|
| Remove remote access from one PC2 and unregister it | `pcx teardown pc2` |
| Delete one name on PC1 only, leave PC2 alone | `pcx forget pc2` |
| **Remove everything (all PC2s + PC1)** | `pcx uninstall -All -Yes` |
| Clean PC1 only, leave PC2s alone | `pcx uninstall -Yes` |
| Also uninstall OpenSSH Server | Add `-UninstallServer` to `teardown` / `uninstall` |
| Clean PC1 even if remote removal fails | Add `-Force` to `uninstall` (PC2 keeps authorizing your key) |
| PC1 is gone; remove directly on PC2 | Windows: double-click `REMOVE.cmd` in the folder. Ubuntu: `bash remove.sh` |

If several names point to the same host, `teardown` warns and asks for confirmation first (`-Yes` skips it), and on success unregisters every name for that host. To drop just an extra name, use `forget`.

PC2 is restored from the original state recorded at install time: only pcx's own key is removed (other keys stay), and the firewall rule, password-login setting, default shell and `LocalAccountTokenFilterPolicy` are restored, and passwordless sudo is revoked. SSH is disabled only if pcx installed it or it was not running before, so a cloud VM that already used SSH keeps it.
On PC1, the `pcx` command, `~\.pcx`, the dedicated key `id_ed25519_pcx` and pcx's blocks in `~/.ssh/config` are deleted.

## Security and OpenSSH updates

- Password login is left unchanged at install time (so you cannot lock yourself out if the key does not work). Once `pcx add` confirms the key works, run `pcx harden <name>` to disable password login. It verifies key login before changing anything and checks again afterwards.
- Source restriction: on Windows a firewall rule always limits connections to the `-AllowFrom` sources. On Ubuntu a rule is added **only if ufw is already active**. When ufw is inactive (the desktop default), port 22 is open to every source, so enable ufw yourself or rely on an upstream firewall.
- Run `pcx teardown <name>` when you no longer need access so SSH is not left open. This is the most effective protection.
- The scripts **never upgrade** OpenSSH automatically; they only print the version at the end of install, and Ubuntu also mentions available updates.
  - Ubuntu: upgrade yourself after reviewing, with `sudo apt install --only-upgrade openssh-server`, or add `-UpgradeServer` to `pcx invite ubuntu` to upgrade during install (non-interactive and keeps your config files, but restarts sshd and may pull in openssl/libc upgrades).
  - Windows: OpenSSH is maintained by Windows Update, so keep Windows updated.
- When a serious OpenSSH vulnerability is announced, check the official OpenSSH advisory and your distribution's tracker (for example [Ubuntu CVE](https://ubuntu.com/security/cves) or the [Debian Security Tracker](https://security-tracker.debian.org/tracker/)) to see whether you are affected. For example, [CVE-2026-123158](https://security-tracker.debian.org/tracker/CVE-2026-123158) ("SSHole"), disclosed in November 2026, mainly affects musl-based systems without PAM (such as Alpine); one mitigation is disabling password login, which is what `pcx harden` does.

## Notes

- Rights after login: an administrator on Windows; on Ubuntu, the account that ran `install.sh` (root-equivalent with `-PasswordlessSudo`).
- The dedicated key `~/.ssh/id_ed25519_pcx` has no passphrase (so no typing is needed). Anyone holding the private key controls PC2, so protect it. Across networks, pair pcx with a VPN or source-IP restrictions.
- AI sandboxes on PC1 (such as Codex) may block network access by default, which stops `ssh` (`NETWORK_BLOCKED`, `KEY_UNREADABLE`). Loosen the sandbox or use an approval mode.
- On a direct cable without static IPs, the OS assigns `169.254.x.x`; the install summary marks these, and static IPs are recommended.
- The SSH default shell on a Windows PC2 is set to PowerShell 7 (or Windows PowerShell if 7 is missing), so remote commands use PowerShell syntax.
- Config locations: registered hosts in `~\.pcx\hosts.json`; connection settings in `~\.ssh\config` blocks marked `# >>> pcx <name> >>>`.
