# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal macOS Bash tooling to manage VPN tunnels from one place. Two backends:

- **WireGuard** via `wg-quick` (configs live in system paths, not the repo).
- **OpenVPN** via the Homebrew binary `/opt/homebrew/sbin/openvpn` — used instead of
  the OpenVPN Connect GUI because the brew CLI writes routes into the kernel correctly.

`main-vpn-manager.sh` is the single entry point that dispatches to both. There is no
build, no test framework, and no package — scripts run directly. Repo-facing docs
(`README.md`, `OPENVPN_CLI.md`) are in Ukrainian; this file is the AI-facing reference.

## Project layout & purpose of each file

```
main-vpn-manager.sh   Central dispatcher. Commands: status | list | up <t> | down [t]
                      | cert <wg|openvpn> | help. WireGuard via wg-quick; "openvpn" and
                      "cert" delegate to scripts/*.sh.
README.md             User-facing overview + usage (Ukrainian).
OPENVPN_CLI.md        Detailed OpenVPN reference (Ukrainian).
config.env.example    Template for config.env (committed).
config.env            Local defaults (LAN_GATEWAY, OVPN_USERNAME, ...). GITIGNORED.
state.env             Auto-written last choices (LAST_GATEWAY, LAST_USERNAME). GITIGNORED.
auth.txt.example      Template for auth.txt (committed).
auth.txt              Optional default OpenVPN username, one line, chmod 600. GITIGNORED.
wire-first            Empty placeholder; "wire-first" is a WireGuard tunnel NAME (its
                      real config is /etc/wireguard/wire-first.conf in the system path).
scripts/
  vpn-up.sh           OpenVPN connect: dynamic profile menu, optional login, route-fix.
  vpn-down.sh         OpenVPN disconnect: kill by PID file, fallback pkill -x openvpn.
  vpn-cert.sh         OpenVPN profile/cert management (list/add/replace-cert/delete).
  wg-cert.sh          WireGuard config management (list/generate/import/delete).
  fix-ovpnagent.sh    Restart the OpenVPN Connect agent daemon if its socket vanished.
  nuclear-clean-dns.sh   Force-clear DNS from Wi-Fi / iPhone USB + flush resolver.
  com.local.ovpnagent-watchdog.plist   LaunchDaemon watchdog for the agent socket.
```

## How to test the scripts

There are no unit tests. Validate changes like this:

- **Syntax check (no side effects):** `bash -n main-vpn-manager.sh` and the same for each
  `scripts/*.sh`.
- **Sudo-free smoke tests:** `./main-vpn-manager.sh help`, `list`, and `status` all run
  without root and without touching network state — use them to verify parsing/dispatch.
  (`status`/`down` may prompt for `sudo` only if an active WireGuard runtime dir is
  root-readable-only; see below.)
- **`shellcheck scripts/*.sh main-vpn-manager.sh`** if available.
- **Real connect/disconnect** (`up`/`down`) changes routing and needs `sudo` — only run
  when you actually intend to alter the user's network; prefer asking first.

## Architecture & non-obvious facts

- **WireGuard tunnel detection (macOS-specific).** `wg-quick up <name>` writes the tunnel
  name into `/var/run/wireguard/<utunN>.name`. `main-vpn-manager.sh` reads those files to
  map config name → live interface for `status`. That dir / those files may be root-owned,
  so `wg_active_map()` reads sudo-free first and only falls back to `sudo` when the dir is
  genuinely inaccessible (it deliberately avoids a sudo prompt when the dir is just empty).
- **`wg-quick up/down` is passed a full `.conf` path** when found (`wg_target()`), so tunnels
  in any of the three search dirs work, not only `/etc/wireguard`.
- **OpenVPN scripts resolve repo root from their own location:** `vpn-up.sh` computes
  `REPO_ROOT="$SCRIPT_DIR/.."` to find `auth.txt`. If you move scripts around, keep this
  relationship (scripts live one level under the repo root).
- **Login is optional and auto-detected.** `vpn-up.sh` prompts for user/pass only if the
  chosen profile has a bare `auth-user-pass` line. Default username precedence: `state.env`
  LAST_USERNAME → `config.env` OVPN_USERNAME → `auth.txt` first line; overridable or skippable
  per connect. When needed it writes a temp `/tmp/ovpn-auth.XXXXXX` (user+OTP) for
  `--auth-user-pass` and deletes it once up (and via an EXIT trap). OTP is never stored.
- **Route fix (`vpn-up.sh`) is per-connection, not hardcoded.** On some LANs macOS routes the
  VPN server out the wrong interface; the script can force `-host` routes via a gateway. The
  gateway is prompted each connect (default `state.env` LAST_GATEWAY → `config.env`
  LAN_GATEWAY), can be overridden/skipped, and is remembered. Target hosts are derived from the
  chosen profile's `remote` line(s) — nothing network-specific is committed.
- **OpenVPN profile menu is dynamic** in `vpn-up.sh` — built by scanning the profiles dir and
  reading each `remote` line (no hardcoded filenames/hosts). Profiles live in
  `~/Library/Application Support/OpenVPN Connect/profiles/` (shared with the GUI, named by
  ms-timestamp); override the dir via `config.env` OVPN_PROFILES_DIR.
- **Local config/state.** `vpn-up.sh` sources `config.env` (optional defaults) and `state.env`
  (written via the inline `set_state KEY VAL` helper, which rewrites one key). Both gitignored;
  `state.env` is created on first connect.
- **`wg-cert.sh` mirrors `vpn-cert.sh`'s UX** for WireGuard: list / generate keypair
  (`wg genkey|pubkey`, optional `wg genpsk`) + scaffold `.conf` from a template / import an
  existing `.conf` / delete. Writes to the wg system dirs via `sudo` (chmod 600); tunnel names
  are validated against wg-quick's `[a-zA-Z0-9_=+.-]{1,15}` interface-name rule.
- **State files:** PID `/tmp/openvpn.pid`, log `/tmp/openvpn.log`. `vpn-up.sh` polls the log
  for `Initialization Sequence Completed` (success) vs `AUTH_FAILED`/`fatal error`.
- **The ovpnagent watchdog is a separate concern** from the brew-CLI connection path: the
  plist + `fix-ovpnagent.sh` keep the *GUI* agent's socket alive and are independent.

## Cautions

- **Do not change WireGuard system paths.** `wg-quick` expects configs in its standard dirs
  (`/etc/wireguard`, `/usr/local/etc/wireguard`, `/opt/homebrew/etc/wireguard`); the manager
  searches those. Don't relocate configs into the repo or rewrite these paths.
- **Never commit secrets.** `auth.txt`, `config.env`, `state.env`, `*.key`, `*.conf`,
  `*.ovpn`/`*.ovpn.bak`, WG keys (`privatekey`/`publickey`/`*.psk`), `secrets/`, `.env` are
  gitignored (logins / private keys / embedded certs / network details). Commit the `*.example`
  templates, not the real files.
- **Permissions / privileges.** `up`/`down` and live status need root: creating the tun
  interface and `wg-quick` require `sudo` (or membership in the `wheel` group). Read-only
  `help`/`list` (and basic `status`) do not.
```
