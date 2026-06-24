# own-wg-openvpn-managment

Особистий набір bash-скриптів для керування VPN-тунелями на macOS — **WireGuard**
(через `wg-quick`) та **OpenVPN** (через Homebrew-версію `/opt/homebrew/sbin/openvpn`).

Призначення — мати **одну централізовану точку керування** (`main-vpn-manager.sh`)
для запуску/зупинки тунелів і перегляду статусу, незалежно від технології.
Brew-версія OpenVPN (на відміну від GUI OpenVPN Connect) правильно прописує
маршрути в ядро, тому використовується саме вона.

---

## Структура

```
.
├── main-vpn-manager.sh     # ← головна точка входу (WireGuard + OpenVPN)
├── OPENVPN_CLI.md          # детальна інструкція по OpenVPN-скриптах
├── config.env.example      # шаблон локального конфігу (дефолти)
├── config.env              # (gitignored) дефолти: LAN_GATEWAY, OVPN_USERNAME
├── state.env               # (gitignored, авто) останні вибори: LAST_GATEWAY, LAST_USERNAME
├── auth.txt.example        # шаблон файлу логіну
├── auth.txt                # (gitignored, опц.) дефолтний OpenVPN-логін, chmod 600
├── wire-first              # порожній плейсхолдер; назва WireGuard-тунелю
└── scripts/                # допоміжні скрипти
    ├── vpn-up.sh                       # OpenVPN: підключення (динамічне меню + логін + route-fix)
    ├── vpn-down.sh                     # OpenVPN: відключення
    ├── vpn-cert.sh                     # OpenVPN: керування профілями/сертифікатами
    ├── wg-cert.sh                      # WireGuard: генерація/імпорт/видалення конфігів
    ├── fix-ovpnagent.sh                # перезапуск агента OpenVPN Connect
    ├── nuclear-clean-dns.sh            # примусове очищення DNS
    └── com.local.ovpnagent-watchdog.plist  # LaunchDaemon-вотчдог агента
```

> WireGuard-конфіги (`.conf`) живуть у системних шляхах wg-quick
> (`/etc/wireguard`, `/usr/local/etc/wireguard`, `/opt/homebrew/etc/wireguard`),
> **не** в цьому репозиторії. OpenVPN-профілі (`.ovpn`) — у
> `~/Library/Application Support/OpenVPN Connect/profiles/`.

---

## Використання `main-vpn-manager.sh`

```bash
./main-vpn-manager.sh <команда> [тунель]
```

| Команда             | Опис                                                          |
|---------------------|--------------------------------------------------------------|
| `status`            | швидкий статус: усі активні тунелі (WireGuard + OpenVPN + utun) |
| `list`              | доступні тунелі (WG-конфіги + `openvpn`)                      |
| `up <тунель>`       | підняти тунель: назва WG-тунелю або `openvpn`                 |
| `down [тунель]`     | опустити тунель; без аргументу — всі (спершу показує статус)  |
| `cert <wg\|openvpn>`| додати/керувати конфігами та сертифікатами                    |
| `help`              | довідка                                                       |

### Приклади

```bash
# Подивитись що зараз активне
./main-vpn-manager.sh status

# Які тунелі взагалі доступні
./main-vpn-manager.sh list

# Підняти WireGuard-тунель за назвою
./main-vpn-manager.sh up wire-first

# Підключити OpenVPN (відкриє інтерактивне меню профілів + запит OTP)
./main-vpn-manager.sh up openvpn

# Опустити конкретний тунель
./main-vpn-manager.sh down wire-first

# Опустити ВСЕ (покаже статус і запитає підтвердження)
./main-vpn-manager.sh down

# Додати/згенерувати WireGuard-тунель або керувати .ovpn профілями
./main-vpn-manager.sh cert wg
./main-vpn-manager.sh cert openvpn
```

`up`/`down` потребують `sudo` (створення tun-інтерфейсу та `wg-quick`).
Скрипт викличе `sudo` сам — буде запит пароля.

---

## WireGuard — додавання тунелю

```bash
./main-vpn-manager.sh cert wg
```

- **Згенерувати новий** — створює пару ключів (`wg genkey`/`wg pubkey`), питає
  Address / DNS / Endpoint / PublicKey піра / AllowedIPs, збирає `.conf` і кладе у
  системну теку WireGuard (`sudo`, права 600). Виводить твій **публічний ключ** —
  передай його адміну сервера.
- **Імпортувати готовий** — `scripts/wg-cert.sh /path/to/tunnel.conf` покладе
  наданий `.conf` у системну теку.

Далі: `./main-vpn-manager.sh up <назва-тунелю>`.

---

## OpenVPN

Деталі по OpenVPN-частині (меню профілів, OTP, керування сертифікатами,
відновлення агента) — у [OPENVPN_CLI.md](OPENVPN_CLI.md).

Швидкий старт:

```bash
cp config.env.example config.env                     # (опц.) дефолти: LAN_GATEWAY, OVPN_USERNAME
cp auth.txt.example auth.txt && chmod 600 auth.txt   # (опц.) дефолтний логін
./main-vpn-manager.sh cert openvpn                   # додати .ovpn профіль(і)
./main-vpn-manager.sh up openvpn                     # підключитись (динамічне меню)
```

Логін питається лише якщо профіль має `auth-user-pass`; його можна змінити або
пропустити при підключенні. OTP/пароль ніде не зберігаються.

---

## Застереження

- **Не комітити** `auth.txt`, `config.env`, `state.env`, `*.key`, `*.conf`, `*.ovpn`,
  ключі WireGuard — вони містять логіни/ключі/сертифікати/мережеві деталі. Усе це у
  `.gitignore`; комітяться лише `*.example`-шаблони.
- **Не змінювати** системні шляхи WireGuard — `wg-quick` очікує конфіги саме
  у своїх стандартних директоріях.
