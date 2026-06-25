# Security Policy

## ⚠️ Personal-use tool — use at your own risk

This is a personal macOS helper for managing the author's own **WireGuard** and
**OpenVPN** tunnels. It is published for reference and convenience, provided
**as-is** under the [MIT license](LICENSE), with **no warranty** and **no
guarantee of fitness** for anyone else's setup.

It is **not** audited, hardened, or intended for production or multi-user
environments. **Read the scripts before running them** — several commands use
`sudo` and modify your routing table, DNS, and network interfaces. If you fork
it, review every hardcoded path and adapt it to your own machine.

## What this tool touches

- Runs `sudo` to create tun interfaces, bring tunnels up/down (`wg-quick`,
  `openvpn`), add host routes, and (optionally) reset DNS.
- Reads/writes WireGuard configs in the system dirs
  (`/etc/wireguard`, `/usr/local/etc/wireguard`, `/opt/homebrew/etc/wireguard`).
- Generates WireGuard private keys (`wg genkey`) written into system configs
  (`chmod 600`).

## Secrets — what is kept out of git

Credentials and machine-specific data are kept **out of version control** via
`.gitignore`. Only `*.example` templates are tracked.

| Not committed | Contains |
|---------------|----------|
| `auth.txt` | optional default VPN username |
| `config.env` | local defaults (gateway, username, profile dir) |
| `state.env` | last-used gateway / username |
| `*.conf`, `*.ovpn`, `*.ovpn.bak` | tunnel configs / profiles (may embed keys/certs) |
| `*.key`, `privatekey`, `publickey`, `*.psk` | WireGuard / TLS key material |

Handling rules:

- **Never commit** the files above. If you add new secret-bearing files, extend
  `.gitignore` first.
- **OTP / passwords are never stored.** They are entered interactively; a temp
  file `/tmp/ovpn-auth.XXXXXX` is created for the connect and deleted right after
  (and via an `EXIT` trap).
- Keep `auth.txt` and any key files `chmod 600`.
- **Do not commit infrastructure details** (real hostnames, internal IPs, account
  names). Keep examples generic (`vpn.example.com`, `10.0.0.x`). Before a commit,
  a quick sanity check should return nothing:
  ```bash
  git grep -niE 'your-real-host|your-internal-ip|your-username'
  ```

## Reporting

This is a personal project with no formal disclosure process or supported
versions. If you notice a security problem, please open an issue (omit any
sensitive details) or contact the author.
