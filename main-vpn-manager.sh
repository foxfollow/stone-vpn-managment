#!/bin/bash
#
# main-vpn-manager.sh — централізована точка керування VPN-тунелями.
# Керує WireGuard (через wg-quick), OpenVPN (через scripts/vpn-*.sh) та Defguard
# (через defguard-client).
#
# Використання:
#   ./main-vpn-manager.sh status            показати всі активні тунелі (швидкий статус)
#   ./main-vpn-manager.sh list              показати доступні тунелі
#   ./main-vpn-manager.sh up <tunnel>       підняти тунель (назва WG-тунелю, 'openvpn', 'cisco [хост]' або 'defguard [локація]')
#   ./main-vpn-manager.sh down [tunnel]     опустити тунель; без аргументу — меню
#   ./main-vpn-manager.sh cert <wg|openvpn> керування конфігами/сертифікатами
#   ./main-vpn-manager.sh dns               показати DNS по сервісах і встановити на вибраних
#   ./main-vpn-manager.sh dns fix [сервери] полагодити DNS, що зник після VPN
#   ./main-vpn-manager.sh dns split ...     split-DNS через /etc/resolver
#   ./main-vpn-manager.sh help              ця довідка
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"

# Defaults (config.env may override any of these).
RESTORE_DNS=""
DNS_SERVICES=("Wi-Fi")
DEFGUARD_CLI=""
DISABLED_BACKENDS="${DISABLED_BACKENDS:-}"   # також разово: DISABLED_BACKENDS=cisco ./main-vpn-manager.sh ...

# Опціональний локальний конфіг (дефолти: RESTORE_DNS, DNS_SERVICES тощо).
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"

# Стандартні шляхи WireGuard (wg-quick шукає конфіги саме тут). НЕ міняти.
WG_DIRS=(/opt/homebrew/etc/wireguard /usr/local/etc/wireguard /etc/wireguard)
WG_RUN="/var/run/wireguard"        # тут wg-quick тримає <iface>.name (назва тунелю)
OVPN_PROFILES="${OVPN_PROFILES_DIR:-$HOME/Library/Application Support/OpenVPN Connect/profiles}"

# ─── кольори (вимикаються коли вивід не в термінал) ──────────────────────────
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=''; G=''; R=''; Y=''; D=''; N=''
fi

die() { echo "${R}Помилка:${N} $*" >&2; exit 1; }

# ─── вимкнені бекенди (config.env: DISABLED_BACKENDS) ────────────────────────
# Вимкнений бекенд не показується в status/list/down і взагалі не опитується
# (жодних wg / pgrep openvpn / vpn state / defguard-client). Рядок, а не масив:
# /bin/bash 3.2 під set -u падає на порожньому масиві. Синоніми: wg, ovpn, dg.
BACKENDS="wireguard openvpn defguard cisco"

backend_canon() {
    case "$1" in
        wg|wireguard)     echo wireguard ;;
        ovpn|openvpn)     echo openvpn ;;
        dg|defguard)      echo defguard ;;
        cisco|anyconnect) echo cisco ;;
        *)                echo "$1" ;;
    esac
}

backend_on() {
    local b want; want=$(backend_canon "$1")
    for b in ${DISABLED_BACKENDS//,/ }; do
        [ "$(backend_canon "$b")" = "$want" ] && return 1
    done
    return 0
}

backend_need() { backend_on "$1" || die "бекенд '$(backend_canon "$1")' вимкнено в config.env (DISABLED_BACKENDS)"; }

# Вимкнені — одним рядком, щоб status/list чесно казали, чого не показують.
backends_off() {
    local b out=""
    for b in $BACKENDS; do backend_on "$b" || out+="$b "; done
    echo "${out% }"
}

# Друкарська помилка в config.env інакше мовчки нічого б не вимкнула.
backends_validate() {
    local b
    for b in ${DISABLED_BACKENDS//,/ }; do
        case " $BACKENDS " in
            *" $(backend_canon "$b") "*) ;;
            *) echo "${Y}config.env: невідомий бекенд у DISABLED_BACKENDS: '$b'${N} (є: $BACKENDS)" >&2 ;;
        esac
    done
}

# ─── WireGuard ──────────────────────────────────────────────────────────────

# Директорія конфігів WireGuard: спершу та, що містить *.conf, інакше перша наявна.
wg_config_dir() {
    local d
    shopt -s nullglob
    for d in "${WG_DIRS[@]}"; do
        [ -d "$d" ] || continue
        local f=("$d"/*.conf)
        [ ${#f[@]} -gt 0 ] && { echo "$d"; return 0; }
    done
    for d in "${WG_DIRS[@]}"; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Назви всіх доступних WG-тунелів (за *.conf у директорії конфігів).
wg_list_configs() {
    local dir f
    dir=$(wg_config_dir) || return 0
    shopt -s nullglob
    for f in "$dir"/*.conf; do
        basename "$f" .conf
    done
}

wg_has() { local dir; dir=$(wg_config_dir) && [ -f "$dir/$1.conf" ]; }

# Повний шлях до .conf якщо знайдено, інакше — лише ім'я (для wg-quick).
wg_target() {
    local name="$1" dir
    if dir=$(wg_config_dir) && [ -f "$dir/$name.conf" ]; then
        echo "$dir/$name.conf"
    else
        echo "$name"
    fi
}

# Активні WG-тунелі: друкує рядки "configname realiface" (utunN).
# wg-quick на macOS пише <utunN> у файл $WG_RUN/<tunnel-name>.name
# (тобто ІМ'Я ФАЙЛУ = назва тунелю, ВМІСТ = інтерфейс).
wg_active_map() {
    [ -d "$WG_RUN" ] || return 0
    local out="" nf need_sudo=0
    if [ -r "$WG_RUN" ] && [ -x "$WG_RUN" ]; then
        shopt -s nullglob
        local files=("$WG_RUN"/*.name)
        [ ${#files[@]} -gt 0 ] || return 0          # читається і порожня → тунелів немає
        for nf in "${files[@]}"; do
            if [ -r "$nf" ]; then
                out+="$(basename "$nf" .name) $(cat "$nf")"$'\n'
            else
                need_sudo=1                          # .name належить root
            fi
        done
    else
        need_sudo=1                                  # директорію не видно без sudo
    fi
    if [ -z "$out" ] && [ "$need_sudo" -eq 1 ]; then
        out=$(sudo -p "[sudo] пароль (статус WireGuard): " bash -c '
            shopt -s nullglob
            for nf in '"$WG_RUN"'/*.name; do
                printf "%s %s\n" "$(basename "$nf" .name)" "$(cat "$nf")"
            done
        ' 2>/dev/null)
    fi
    printf '%s' "$out"
}

# ─── OpenVPN ────────────────────────────────────────────────────────────────

# Запущені openvpn (їх може бути кілька): "PID<TAB>id" — id = профіль з --config.
ovpn_instances() {
    local pid cfg
    for pid in $(pgrep -x openvpn 2>/dev/null); do
        cfg=$(ps -p "$pid" -o command= 2>/dev/null | sed -n 's/.*--config \(.*\.ovpn\).*/\1/p')
        printf '%s\t%s\n' "$pid" "$(basename "${cfg:-?}" .ovpn)"
    done
}

ovpn_remote() {
    grep -E '^[[:space:]]*remote ' "$OVPN_PROFILES/$1.ovpn" 2>/dev/null | head -1 | awk '{print $2":"$3}'
}

# Стан екземпляра з його логу (шлях — з --log у командному рядку процесу):
# "up<TAB>utunN" | "connecting<TAB><остання помилка>" | "unknown<TAB>"  (лог недоступний).
# Лог від vpn-up.sh читається без sudo (640, staff); старі/чужі запуски — лише через sudo -n.
ovpn_state() {
    local pid="$1" log txt
    log=$(ps -p "$pid" -o command= 2>/dev/null | sed -n 's/.*--log \([^ ]*\).*/\1/p')
    [ -n "$log" ] || { printf 'unknown\t\n'; return; }
    if [ -r "$log" ]; then txt=$(cat "$log" 2>/dev/null)
    else txt=$(sudo -n cat "$log" 2>/dev/null) || { printf 'unknown\t\n'; return; }
    fi
    awk '
        /Initialization Sequence Completed/ { up = NR }
        /process restarting|Restart pause|SIGUSR1|SIGHUP/ { rs = NR }
        /Opened utun device/ { dev = $NF }
        /TLS Error|AUTH_FAILED|ERROR|Connection refused|unreachable|Exiting/ {
            err = $0; sub(/^[0-9-]+ [0-9:]+ /, "", err)
        }
        END {
            if (up && up > rs) printf "up\t%s\n", dev
            else printf "connecting\t%s\n", err
        }' <<< "$txt"
}

# Маршрути через інтерфейс (крім власної адреси тунелю, multicast і broadcast),
# одним рядком. Scoped default (прапорець I) — не повний тунель, а лише маршрут
# для сокетів, прив'язаних до інтерфейсу; NE-тунелі (Defguard) ставлять його завжди.
# Клоновані host-записи (W) — кеш ядра під живі з'єднання, не конфіг тунелю.
iface_routes() {
    local own; own=$(ifconfig "$1" 2>/dev/null | awk '/inet /{print $2}')
    netstat -rn -f inet 2>/dev/null | awk -v i="$1" -v own="$own" '
        $4 == i && $1 != own && $3 !~ /W/ && $1 !~ /^22[4-9]|^23[0-9]|^255\.255\.255\.255/ {
            d = $1; if (d == "default" && $3 ~ /I/) d = "default (scoped)"
            r = r (r ? ", " : "") d }
        END { print r }'
}

# Один рядок статусу OpenVPN-екземпляра (+ маршрути / помилка рядком нижче).
ovpn_status_line() {
    local pid="$1" id="$2" st info routes
    IFS=$'\t' read -r st info <<< "$(ovpn_state "$pid")"
    case "$st" in
        up)
            printf "  ${G}● %-16s${N} %-32s ${G}підключено${N} ${D}(%s, PID %s)${N}\n" "$id" "$(ovpn_remote "$id")" "${info:-?}" "$pid"
            routes=$(iface_routes "$info")
            [ -n "$info" ] && printf "      ${D}маршрути: %s${N}\n" "${routes:-немає}"
            ;;
        connecting)
            printf "  ${Y}◐ %-16s${N} %-32s ${Y}НЕ підключено${N} ${D}(PID %s, повторює спроби)${N}\n" "$id" "$(ovpn_remote "$id")" "$pid"
            [ -n "$info" ] && printf "      ${D}%s${N}\n" "$info"
            ;;
        *)
            printf "  ${D}? %-16s${N} %-32s ${D}стан невідомий — лог лише для root (PID %s)${N}\n" "$id" "$(ovpn_remote "$id")" "$pid"
            ;;
    esac
}

# ─── Cisco Secure Client (сторонній, але опускається через його ж CLI) ───────

cisco_cli() {
    local p
    for p in /opt/cisco/secureclient/bin/vpn /opt/cisco/anyconnect/bin/vpn; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Сервер, до якого під'єднаний Cisco, або порожньо (= не під'єднаний).
# Демони Cisco крутяться завжди — живий тунель видно лише з 'vpn state'.
cisco_connected_host() {
    local cli; cli=$(cisco_cli) || return 0
    "$cli" -s state 2>/dev/null | sed -n 's/.*Connected to \(.*\)\.$/\1/p' | head -1
}

# Хости з профілю Cisco — те, що GUI показує у випадному списку.
cisco_hosts() {
    local cli; cli=$(cisco_cli) || return 0
    "$cli" -s hosts 2>/dev/null | awk '
        /\[hosts\]:/ { h = 1; next }
        h && /^[[:space:]]*> / { sub(/^[[:space:]]*> /, ""); sub(/[[:space:]]+$/, ""); print }'
}

# GUI Cisco Secure Client. Поки він відкритий, агентом керує він, і `vpn connect`
# з CLI відмовляє. Тунель тримає vpnagentd, не GUI, тож закрити GUI безпечно.
cisco_gui_pid() {
    pgrep -f 'Cisco Secure Client\.app/Contents/MacOS/Cisco Secure Client' 2>/dev/null | head -1
}

# Підключити Cisco через CLI (`vpn connect <хост>`). Групу, логін, пароль і банер
# питає сам vpn у терміналі — тут нічого не зберігається.
cisco_up() {
    local cli host="${1:-}" cur
    cli=$(cisco_cli) || die "Cisco Secure Client CLI не знайдено (/opt/cisco/secureclient/bin/vpn)"
    cur=$(cisco_connected_host)
    [ -n "$cur" ] && { echo "Cisco вже під'єднано до $cur."; return 0; }

    if [ -z "$host" ]; then
        local -a hosts=()
        local h i
        while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done <<< "$(cisco_hosts)"
        if [ "${#hosts[@]}" -eq 1 ]; then
            host="${hosts[0]}"
        elif [ "${#hosts[@]}" -gt 1 ]; then
            echo "${B}Cisco — до якого хоста?${N}"
            for i in "${!hosts[@]}"; do printf "  %2d) %s\n" "$((i + 1))" "${hosts[$i]}"; done
            read -rp "Номер [1-${#hosts[@]}] або адреса: " i
            if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#hosts[@]}" ]; then
                host="${hosts[$((i - 1))]}"
            else
                host="$i"
            fi
        else
            read -rp "Адреса Cisco-шлюзу (у профілі хостів немає): " host
        fi
        [ -n "$host" ] || die "хост не вказано"
    fi

    local gui; gui=$(cisco_gui_pid)
    if [ -n "$gui" ]; then
        echo "${Y}Відкритий GUI Cisco Secure Client (PID $gui)${N} — поки він працює, CLI не підключає."
        local a; read -rp "Закрити GUI? Тунелю це не шкодить — його тримає vpnagentd. [Y/n]: " a
        case "$a" in n|N) echo "Скасовано."; return 1 ;; esac
        osascript -e 'quit app "Cisco Secure Client"' >/dev/null 2>&1
        sleep 1
    fi

    echo "${B}Підключаю Cisco до $host...${N}"
    "$cli" connect "$host"
    cur=$(cisco_connected_host)
    if [ -n "$cur" ]; then
        echo "${G}● Cisco під'єднано до $cur${N}"
    else
        echo "${R}Cisco не під'єднано${N} ($("$cli" -s state 2>/dev/null | sed -n 's/.*state: //p' | tail -1))."
        return 1
    fi
}

# ─── Defguard (NetworkExtension net.defguard, керується власним CLI) ─────────
#
# На macOS Defguard — не wg-quick, а системне розширення net.defguard.VPNExtension.
# Кожна локація — окремий VPN-сервіс SystemConfiguration (Hardware Port net.defguard),
# тож живий стан видно з `scutil --nc list` без sudo, а utun/адресу/DNS — зі
# `scutil --nc status <uuid>`. State-стор тут не допоможе: живий тунель пише
# State:/Network/Service/<ІНШИЙ uuid>, без Setup-запису і без зв'язку з сесією.
# І `defguard-client status --json` на macOS віддає "interface": "".
# DNS ставиться як Supplemental з MatchDomains [""] — тобто для ВСІХ доменів,
# першим у списку (як Cisco), поки тунель піднятий.
# Підключати/відключати — лише через defguard-client: він ділить БД із GUI, сам
# проходить MFA і пише конфіг у NE (sudo не потрібен). Розширення крутиться 24/7,
# навіть коли нічого не під'єднано, — його процес нічого не означає.
# УВАГА: `scutil --nc show <uuid>` друкує privateKey тунелю — сирий вивід не показувати.

# CLI лежить усередині бандла і в PATH сам не потрапляє. Запускати ТІЛЬКИ за
# справжнім шляхом: NetworkExtension шукає бандл застосунку від шляху exec, і
# через симлінк (/opt/homebrew/bin) не знаходить net.defguard.VPNExtension →
# "Failed to save tunnel configuration" ("Missing plugin type"). Для локацій без
# MFA це непомітно (старий профіль ще валідний), а MFA-локація стартує з
# протухлим ключем сесії й падає з WireGuardError 8. Тому симлінки розгортаємо.
dg_cli() {
    local p
    for p in /Applications/Defguard.app/Contents/MacOS/defguard-client \
             "$DEFGUARD_CLI" "$(command -v defguard-client 2>/dev/null)"; do
        [ -n "$p" ] && [ -x "$p" ] || continue
        [ -L "$p" ] && p=$(realpath "$p" 2>/dev/null)
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Сесії Defguard зі `scutil --nc list`: "стан<TAB>uuid<TAB>назва".
# Стан: Connected | Connecting | Disconnecting | Reasserting | Disconnected.
dg_sessions() {
    scutil --nc list 2>/dev/null | awk '/\[VPN:net\.defguard\]/ {
        st = $0; sub(/^[^(]*\(/, "", st); sub(/\).*/, "", st)
        name = $0; sub(/^[^"]*"/, "", name); sub(/".*/, "", name)
        u = ""; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]+-[0-9A-F]+-[0-9A-F]+-/) { u = $i; break }
        print st "\t" u "\t" name }'
}

# Назва → "стан<TAB>uuid" (порожньо, якщо такої сесії немає).
dg_session() {
    dg_sessions | awk -F'\t' -v n="$1" '$3 == n { print $1 "\t" $2; exit }'
}

# Живі параметри сесії: "utunN<TAB>адреса<TAB>dns1 dns2…" (порожні поля → "-").
dg_info() {
    scutil --nc status "$1" 2>/dev/null | awk '
        /^[[:space:]]*InterfaceName :/ && !ifc { ifc = $NF }
        /^[[:space:]]*Addresses :/    { blk = "a"; next }
        /^[[:space:]]*DNSServers :/   { blk = "d"; next }
        blk && /^[[:space:]]*}/       { blk = ""; next }
        blk == "a" && /[0-9]+ :/ && !addr { addr = $NF }
        blk == "d" && /[0-9]+ :/      { dns = dns (dns ? " " : "") $NF }
        END { printf "%s\t%s\t%s\n", ifc ? ifc : "-", addr ? addr : "-", dns ? dns : "-" }'
}
dg_iface() { dg_info "$1" | cut -f1 | sed 's/^-$//'; }

# Налаштовані цілі з defguard-client (~1с, тож не на кожен статус):
# "kind<TAB>назва<TAB>endpoint<TAB>mfa<TAB>routing"; kind = location | tunnel.
# Порожні поля → "-": таби — пробільні для read, підряд вони б злиплись.
dg_targets() {
    local cli; cli=$(dg_cli) || return 0
    command -v jq >/dev/null 2>&1 || return 0
    "$cli" list --json 2>/dev/null | jq -r '
        def rt: if .route_all_traffic then "all" else "split" end;
        (.locations[]? | ["location", .name, (.endpoint // "-"),
                          (if .mfa_enabled then (.mfa_method // "yes") else "-" end), rt]),
        (.tunnels[]?   | ["tunnel", .name, (.endpoint // "-"), "-", rt])
        | map(tostring | if . == "" then "-" else . end) | @tsv'
}

# Чи це локація чи імпортований тунель — CLI потребує --tunnel для других.
dg_kind() { dg_targets | awk -F'\t' -v n="$1" '$2 == n { print $1; exit }'; }

# Чекати, поки сесія дійде до стану $2 (до ~20с): NE під'єднується асинхронно.
# Викликається ПІСЛЯ виходу CLI — NE вже має бути Connecting; якщо сесія 3с поспіль
# Disconnected, старту не було (MFA відхилено тощо) — чекати далі марно.
dg_wait() {
    local name="$1" want="$2" i st idle=0
    for i in $(seq 1 20); do
        st=$(dg_session "$name" | cut -f1)
        [ "$st" = "$want" ] && return 0
        if [ "$st" = Disconnected ]; then
            idle=$((idle + 1)); [ "$idle" -ge 3 ] && return 1
        else
            idle=0
        fi
        sleep 1
    done
    return 1
}

# PID запущеного застосунку Defguard (GUI). CLI — той самий бінарник, але з
# аргументами, тож точний збіг командного рядка ловить лише GUI.
# Навіщо: GUI 2.1.0 за ~300 мс ЗУПИНЯЄ MFA-локацію, підняту з CLI (stop від PID
# GUI у логах nesessionmanager), і просить код ще раз у своєму вікні. Локації без
# MFA не чіпає.
dg_gui_pid() {
    pgrep -fx '/Applications/Defguard.app/Contents/MacOS/defguard-client' 2>/dev/null | head -1
}

# Один рядок статусу сесії (+ маршрути / DNS рядками нижче). $4 = endpoint або порожньо.
dg_status_line() {
    local st="$1" uuid="$2" name="$3" ep="${4:-}" iface addr dns routes gdns first
    case "$st" in
        Connected)
            IFS=$'\t' read -r iface addr dns <<< "$(dg_info "$uuid")"
            printf "  ${G}● %-16s${N} %-32s ${G}підключено${N} ${D}(%s, %s)${N}\n" \
                "$name" "$ep" "$iface" "$addr"
            if [ "$iface" != "-" ]; then
                routes=$(iface_routes "$iface")
                printf "      ${D}маршрути: %s${N}\n" "${routes:-немає}"
            fi
            [ "$dns" != "-" ] || return 0
            # Supplemental для всіх доменів: зазвичай DNS тунелю — перший у резолвері.
            # Якщо ні — інший VPN (Cisco, другий Defguard) став попереду, і внутрішні
            # імена підуть не туди (macOS іде далі лише на таймаут, не на NXDOMAIN).
            gdns=$(dns_global_servers); first=${gdns%% *}
            if [ "$first" = "${dns%% *}" ]; then
                printf "      ${D}DNS: %s — перший у резолвері${N}\n" "$dns"
            else
                printf "      ${Y}DNS: %s — не перший у резолвері (%s)${N}\n" "$dns" "${gdns% }"
                echo "      ${D}внутрішні імена: dns split add <домен> ${dns%% *}${N}"
            fi
            ;;
        Connecting|Reasserting|Disconnecting)
            printf "  ${Y}◐ %-16s${N} %-32s ${Y}%s${N}\n" "$name" "$ep" "$st"
            ;;
    esac
}

# Меню вибору цілі Defguard (якщо ціль одна — без питань). Друкує назву.
dg_pick() {
    local -a names=() kinds=()
    local kind name ep mfa rt st i
    while IFS=$'\t' read -r kind name ep mfa rt; do
        [ -n "$name" ] || continue
        names+=("$name"); kinds+=("$kind")
    done <<< "$(dg_targets)"
    [ "${#names[@]}" -gt 0 ] || die "у Defguard немає локацій/тунелів (додай інстанс у застосунку)"
    [ "${#names[@]}" -eq 1 ] && { echo "${names[0]}"; return 0; }
    {
        echo "${B}Defguard — куди підключитись?${N}"
        i=0
        while IFS=$'\t' read -r kind name ep mfa rt; do
            [ -n "$name" ] || continue
            st=$(dg_session "$name" | cut -f1)
            printf "  %2d) %-16s %-32s ${D}%s, MFA %s, %s%s${N}\n" "$((i + 1))" "$name" "$ep" \
                "$kind" "$mfa" "$rt" "${st:+, $st}"
            i=$((i + 1))
        done <<< "$(dg_targets)"
    } >&2
    read -rp "Номер [1-${#names[@]}]: " i
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#names[@]}" ] || die "невірний вибір"
    echo "${names[$((i - 1))]}"
}

# Підключити локацію/тунель. Решта аргументів іде в `defguard-client connect`
# (напр. --all-traffic, --code 123456, --mfa-method email). MFA-код CLI питає сам.
dg_up() {
    local cli name="${1:-}" kind st mfa gui
    cli=$(dg_cli) || die "defguard-client не знайдено (встанови Defguard.app або задай DEFGUARD_CLI у config.env)"
    command -v jq >/dev/null 2>&1 || die "потрібен jq (розбір 'defguard-client list --json')"
    [ $# -gt 0 ] && shift
    [ -n "$name" ] || name=$(dg_pick) || exit 1

    kind=$(dg_kind "$name")
    [ -n "$kind" ] || die "у Defguard немає локації/тунелю '$name'. Див. './main-vpn-manager.sh list'"
    st=$(dg_session "$name" | cut -f1)
    [ "$st" = Connected ] && { echo "Defguard '$name' вже підключено."; return 0; }

    local -a args=(connect "$name")
    [ "$kind" = tunnel ] && args+=(--tunnel)

    mfa=$(dg_targets | awk -F'\t' -v n="$name" '$2 == n { print $4; exit }')
    gui=$(dg_gui_pid)
    if [ "$mfa" != "-" ] && [ -n "$gui" ]; then
        echo "${Y}Defguard.app запущений (PID $gui).${N} Він зупиняє MFA-тунель, піднятий з CLI,"
        echo "і просить код ще раз у своєму вікні — код з CLI згорить даремно."
        echo "${D}Закрий застосунок (трей → Quit) і повтори, або підключайся прямо в ньому.${N}"
        local go; read -rp "Все одно підключати з CLI? [y/N]: " go
        case "$go" in y|Y) ;; *) echo "Скасовано."; return 1 ;; esac
    fi

    echo "${B}Підключаю Defguard '$name'...${N}"
    # "Connected to …" CLI друкує, щойно віддав команду NE, — навіть якщо тунель
    # одразу впаде. Правду каже лише стан сесії, тож чекаємо на нього.
    "$cli" "${args[@]}" "$@" || die "defguard-client connect завершився з помилкою"
    if ! dg_wait "$name" Connected; then
        echo "${R}Сесія '$name' не піднялась${N} (стан: $(dg_session "$name" | cut -f1))."
        echo "${D}Причина з боку розширення: /usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS \"$name\"' | grep -i error${N}"
        return 1
    fi
    # GUI зупиняє чужу MFA-сесію не одразу, а за мить після Connected.
    if [ "$mfa" != "-" ] && [ -n "$(dg_gui_pid)" ]; then
        sleep 2
        st=$(dg_session "$name" | cut -f1)
        if [ "$st" != Connected ]; then
            echo "${R}Defguard.app зупинив '$name'${N} і просить MFA у своєму вікні (стан: $st)."
            echo "${D}Підтверди там або закрий застосунок і повтори 'up $name'.${N}"
            return 1
        fi
    fi
    local uuid; uuid=$(dg_session "$name" | cut -f2)
    dg_status_line Connected "$uuid" "$name" \
        "$(dg_targets | awk -F'\t' -v n="$name" '$2 == n { print $3; exit }')"
}

# Відключити одну ціль або все (all). Без CLI — запасний `scutil --nc stop`
# (GUI тоді може показувати застарілий стан до перезапуску).
dg_down() {
    local name="${1:-all}" cli uuid
    if cli=$(dg_cli); then
        if [ "$name" = all ]; then
            "$cli" disconnect --all
        else
            local -a args=(disconnect "$name")
            [ "$(dg_kind "$name")" = tunnel ] && args+=(--tunnel)
            "$cli" "${args[@]}"
        fi
        return
    fi
    while IFS=$'\t' read -r _ uuid n; do
        [ -n "$uuid" ] || continue
        [ "$name" = all ] || [ "$n" = "$name" ] || continue
        scutil --nc stop "$uuid"
    done <<< "$(dg_sessions | awk -F'\t' '$1 != "Disconnected"')"
}

# ─── DNS ────────────────────────────────────────────────────────────────────
#
# У macOS DNS живе у ДВОХ шарах SystemConfiguration:
#   Setup:/Network/Service/<uuid>/DNS  — преференси; сюди пише `networksetup`.
#   State:/Network/Service/<uuid>/DNS  — рантайм; сюди пишуть VPN-розширення
#                                        (NetworkExtension: ClearVPN, FortiClient).
# State перемагає Setup. Тому `networksetup -setdnsservers` на VPN-сервісі — no-op,
# поки розширення тримає свій State-запис; а коли тунель помирає, його резолвер
# може лишитись у State і «з'їсти» всі запити (ping зависає без виводу).
#
# Друге, і головне: SystemConfiguration перераховує State:/Network/Global/DNS лише
# на РЕАЛЬНУ зміну значення. Записати той самий DNS = не станеться нічого, і
# протухлий глобальний резолвер виживе. Звідси dns_bounce(): empty → значення.

sc_show() { printf 'show %s\nquit\n' "$1" | scutil 2>/dev/null; }

# UUID-и сервісів, що мають State-ключ <kind> (DNS | IPv4 | IPv6).
sc_service_uuids() {
    printf 'list State:/Network/Service/.*/%s\nquit\n' "$1" | scutil 2>/dev/null \
        | sed -n "s|.*State:/Network/Service/\(.*\)/$1.*|\1|p"
}

# ServerAddresses з DNS-ключа SC, через пробіл (з пробілом у кінці).
sc_dns_servers() {
    sc_show "$1" | awk '
        /ServerAddresses/                             { inblock = 1; next }
        inblock && /^[[:space:]]*}/                   { inblock = 0 }
        inblock && /^[[:space:]]*[0-9]+[[:space:]]*:/ { printf "%s ", $NF }'
}

# Діючий глобальний DNS — те, що резолвер справді питає (а не те, що в преференсах).
dns_global_servers() { sc_dns_servers State:/Network/Global/DNS; }

# Хто записав глобальний DNS: "Supplemental: com.cisco.anyconnect 0" → com.cisco.anyconnect.
# UUID = звичайний мережевий сервіс; reverse-DNS назва = VPN-клієнт перехопив резолвер.
dns_global_owner() {
    sc_show State:/Network/Global/DNS | awk -F' : ' '/__CONFIGURATION_ID__/ { print $2 }' \
        | awk '{ print ($1 ~ /:$/ ? $2 : $1) }'
}

# Підказка, коли резолвер — список від чужого VPN. macOS переходить до наступного
# сервера лише на ТАЙМАУТ, не на NXDOMAIN: якщо першим стоїть 8.8.8.8, внутрішні
# імена тунелю (чий DNS далі у списку) не резолвляться ніколи.
dns_owner_hint() {
    local owner servers ifc
    owner=$(dns_global_owner); servers=$(dns_global_servers)
    case "$owner" in
        "") return 0 ;;
        *-*-*-*-*)
            # UUID — норм, якщо це фізичний сервіс. Але NE-тунелі (Defguard) теж
            # пишуть DNS під UUID — тоді його видає InterfaceName=utunN.
            ifc=$(sc_show "State:/Network/Service/$owner/DNS" | awk '/InterfaceName/ { print $NF }')
            iface_is_utun "$ifc" || return 0
            owner="$(utun_owner "$ifc") ($ifc)"
            [ "$owner" = " ($ifc)" ] && owner="тунель $ifc"
            ;;
    esac
    printf "  ${Y}резолвер задає %s${N} — першим питається %s; наступні лише на таймаут.\n" \
        "$owner" "${servers%% *}"
    echo "  ${D}Внутрішні імена іншого тунелю не резолвляться? → './main-vpn-manager.sh dns split'${N}"
}

dns_primary_iface() { sc_show State:/Network/Global/IPv4 | awk '/PrimaryInterface/ { print $NF }'; }
dns_primary_uuid()  { sc_show State:/Network/Global/IPv4 | awk '/PrimaryService/   { print $NF }'; }

# ─── Маршрути ────────────────────────────────────────────────────────────────
# Хто справді несе трафік — маршрут, а не DNS. `route -n get` надійніший за
# парсинг netstat: питає ядро про конкретний напрямок.
route_default_iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
route_default_gw()    { route -n get default   2>/dev/null | awk '/gateway:/{print $2}'; }
route_iface_for()     { route -n get "$1" 2>/dev/null | awk '/interface:/{print $2}'; }

# Split-default: повнотунельні VPN (ClearVPN) перехоплюють УВЕСЬ трафік двома
# /1-маршрутами (0/1 + 128.0/1), що б'ють `default`, не видаляючи його. Друкує
# інтерфейси, на які вони вказують (напр. utun8), якщо такі є — це і є «викрадач».
route_split_default() {
    netstat -rn -f inet 2>/dev/null | awk '$1=="0/1" || $1=="128.0/1" { print $NF }' | sort -u
}

# "ім'я<TAB>BSD-пристрій" по кожному увімкненому сервісу.
# svc_is_vpn() смикається на кожен рядок списку, а networksetup — недешевий процес,
# тож кеш прогріваємо явно (svc_device_load) у батьківському шелі: самі svc_device*
# викликаються з $( ), і присвоєння всередині сабшела назовні б не вижило.
_SVC_DEVICE_CACHE=""
svc_device_load() {
    [ -n "$_SVC_DEVICE_CACHE" ] && return 0
    _SVC_DEVICE_CACHE=$(networksetup -listnetworkserviceorder 2>/dev/null | awk '
        /^\([0-9]+\) / { name = $0; sub(/^\([0-9]+\) /, "", name); next }
        /Device: / && name != "" {
            dev = $0; sub(/.*Device: /, "", dev); sub(/\).*$/, "", dev)
            print name "\t" dev; name = ""
        }')
    return 0
}
svc_device_pairs() { svc_device_load; printf '%s\n' "$_SVC_DEVICE_CACHE"; }

svc_for_iface() { svc_device_pairs | awk -F'\t' -v d="$1" '$2 == d { print $1; exit }'; }
svc_device()    { svc_device_pairs | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'; }

# Сервіс без BSD-пристрою — VPN (NE/IPSec). Його DNS задає сам тунель, не networksetup.
svc_is_vpn() { [ -z "$(svc_device "$1")" ]; }

iface_is_utun() { case "${1:-}" in utun[0-9]*) return 0 ;; esac; return 1; }

# Чи відповідає DNS-сервер на запити (таймаут ~2с). 0 = живий.
dns_probe() {
    if command -v dig >/dev/null 2>&1; then
        dig +time=2 +tries=1 +short "@$1" apple.com >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup -timeout=2 -retry=1 apple.com "$1" >/dev/null 2>&1
    else
        return 0        # нема чим перевірити — вважаємо живим, аби не радити зайвого
    fi
}

# Процеси сторонніх VPN, що можуть тримати utun: NE-розширення (ClearVPN,
# FortiClient, Cisco acsockext) + vpnagentd (Cisco). pgrep, а не ps|grep — щоб
# не зловити власний grep. Наші openvpn/wireguard-go сюди навмисно не входять:
# їх опускає звичайний 'down'.
vpn_tunnel_procs() {
    pgrep -fl 'SystemExtensions/.*(vpn|wireguard|tunnel|anyconnect)|vpnagentd' 2>/dev/null \
        | grep -vi 'security-monitor'
}

# Роль процесу за його cmdline. Критично для 'dns fix': Cisco vpnagentd та
# acsockext крутяться 24/7, НАВІТЬ коли AnyConnect не під'єднаний, — вони не
# тримають чужий тунель. Тобто коли живий лише ClearVPN, у списку все одно
# висять 2 демони Cisco. Провайдера активного тунелю (ClearVPN) — ось кого
# опускати. Друкує "kind|коротка_мітка"; kind = tunnel | daemon.
vpn_proc_role() {
    case "$1" in
        *vpnagentd*|*acsockext*|*anyconnect*) echo "daemon|Cisco-демон (фоновий)" ;;
        *clearvpn*)                           echo "tunnel|ClearVPN" ;;
        *wireguard*)                          echo "tunnel|NE WireGuard-тунель" ;;
        *forti*)                              echo "tunnel|FortiClient" ;;
        *)                                    echo "tunnel|NE VPN-тунель" ;;
    esac
}

# Осиротілі резолвери: State-DNS є, а State-IPv4 вже немає — тунель мертвий,
# а його DNS лишився. Первинний сервіс не чіпаємо ніколи.
dns_orphan_uuids() {
    local primary live uuid
    primary=$(dns_primary_uuid)
    live=$(sc_service_uuids IPv4)
    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue
        [ "$uuid" = "$primary" ] && continue
        printf '%s\n' "$live" | grep -qxF "$uuid" && continue
        echo "$uuid"
    done < <(sc_service_uuids DNS)
}

# Викинути осиротілі резолвери з рантайм-стору (потребує root).
# Увага: scutil ЗАВЖДИ виходить з rc=0 — навіть на "Permission denied". Успішний
# remove не друкує нічого, тож єдиний надійний тест помилки — непорожній вивід.
dns_purge_orphans() {
    local uuid out found=0 purged=0
    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue
        found=$((found + 1))
        out=$(printf 'open\nremove State:/Network/Service/%s/DNS\nquit\n' "$uuid" | sudo scutil 2>&1)
        if [ -n "${out//[[:space:]]/}" ]; then
            echo "  ${R}не прибрано${N} ${D}$uuid${N}: $(printf '%s' "$out" | tr -s '[:space:]' ' ')"
        else
            echo "  ${G}прибрано${N} резолвер мертвого тунелю: ${D}$uuid${N}"
            purged=$((purged + 1))
        fi
    done < <(dns_orphan_uuids)
    [ "$found" -eq 0 ] && echo "  ${D}осиротілих резолверів немає${N}"
    return 0
}

# empty → значення. Два реальні переходи, бо на однакове значення SC не реагує.
dns_bounce() {
    local svc="$1" val="$2"
    sudo networksetup -setdnsservers "$svc" empty || return 1
    [ "$val" = "empty" ] && return 0
    # shellcheck disable=SC2086
    sudo networksetup -setdnsservers "$svc" $val
}

dns_flush() {
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder 2>/dev/null
}

# Відновити DNS після відключення VPN (config.env: RESTORE_DNS). Порожньо = не чіпати.
restore_dns() {
    [ -n "$RESTORE_DNS" ] || return 0
    local svc available
    available=$(networksetup -listallnetworkservices 2>/dev/null)
    for svc in "${DNS_SERVICES[@]}"; do
        if printf '%s\n' "$available" | grep -qxF "$svc"; then
            echo "Відновлюю DNS на '$svc': $RESTORE_DNS"
            dns_bounce "$svc" "$RESTORE_DNS"
        fi
    done
    dns_purge_orphans
    dns_flush
    echo "DNS кеш очищено."
}

# ─── команди ────────────────────────────────────────────────────────────────

cmd_status() {
    echo "${B}=== Статус VPN ===${N}"
    echo ""

    # Хто насправді володіє мережею: цей блок, а не список utun, показує,
    # що сторонній VPN (ClearVPN/Cisco) захопив маршрути й DNS.
    echo "${B}Мережа:${N}"
    local piface presolver psvc
    piface=$(dns_primary_iface)
    presolver=$(dns_global_servers); presolver="${presolver% }"
    if [ -n "$piface" ]; then
        if iface_is_utun "$piface"; then
            printf "  первинний: %s ${Y}(VPN-тунель тримає маршрути й DNS)${N}\n" "$piface"
        else
            psvc=$(svc_for_iface "$piface")
            printf "  первинний: %s${D}%s${N}\n" "$piface" "${psvc:+ ($psvc)}"
        fi
        printf "  діючий DNS: %s\n" "${presolver:-${R}(порожньо — резолюція зламана; спробуй 'dns fix')${N}}"
        dns_owner_hint
    else
        echo "  ${R}немає первинного сервісу — мережа не сконфігурована${N}"
    fi

    # Маршрут за замовчуванням + перехоплення. Саме тут видно VPN-на-VPN
    # конфлікт: повнотунельний VPN забирає default або ставить split 0/1+128/1.
    local diface dgw split
    diface=$(route_default_iface); dgw=$(route_default_gw)
    if [ -n "$diface" ]; then
        if iface_is_utun "$diface"; then
            printf "  маршрут: default → %s ${Y}(VPN тримає весь трафік)${N}\n" "$diface"
        else
            printf "  маршрут: default → %s${D}%s${N}\n" "$diface" "${dgw:+ ($dgw)}"
        fi
    else
        echo "  ${R}маршрут: немає default — трафік нікуди не піде${N}"
    fi
    split=$(route_split_default | tr '\n' ' ')
    [ -n "${split// /}" ] && \
        printf "  ${Y}перехоплення: 0/1+128.0/1 → %s — повнотунельний VPN обходить default${N}\n" "${split% }"
    echo ""

    if backend_on wireguard; then
        echo "${B}WireGuard:${N}"
        if command -v wg >/dev/null 2>&1; then
            local map; map=$(wg_active_map)
            if [ -n "$map" ]; then
                local name iface
                while read -r name iface; do
                    [ -n "$name" ] || continue
                    printf "  ${G}● %-16s${N} UP   ${D}(%s)${N}\n" "$name" "$iface"
                done <<< "$map"
            else
                echo "  ${D}немає активних тунелів${N}"
            fi
        else
            echo "  ${D}wg не встановлено${N}"
        fi
        echo ""
    fi

    if backend_on openvpn; then
        echo "${B}OpenVPN:${N}"
        local pid id ovpn; ovpn=$(ovpn_instances)
        if [ -n "$ovpn" ]; then
            while IFS=$'\t' read -r pid id; do
                ovpn_status_line "$pid" "$id"
            done <<< "$ovpn"
        else
            echo "  ${D}не запущено${N}"
        fi
        echo ""
    fi

    if backend_on cisco && cisco_cli >/dev/null; then
        echo "${B}Cisco Secure Client:${N}"
        local chost; chost=$(cisco_connected_host)
        if [ -n "$chost" ]; then
            printf "  ${G}● під'єднано${N} ${D}(%s)${N}\n" "$chost"
        else
            echo "  ${D}не під'єднано${N}"
        fi
        echo ""
    fi

    local dgs=""; backend_on defguard && dgs=$(dg_sessions)
    if backend_on defguard && { [ -n "$dgs" ] || dg_cli >/dev/null; }; then
        echo "${B}Defguard:${N}"
        local st uuid dname targets="" shown=0
        # endpoint бере CLI (~1с) — лише коли є що показувати.
        grep -qv '^Disconnected' <<< "$dgs" && targets=$(dg_targets)
        while IFS=$'\t' read -r st uuid dname; do
            [ -n "$uuid" ] && [ "$st" != Disconnected ] || continue
            dg_status_line "$st" "$uuid" "$dname" \
                "$(awk -F'\t' -v n="$dname" '$2 == n { print $3; exit }' <<< "$targets")"
            shown=1
        done <<< "$dgs"
        [ "$shown" -eq 1 ] || echo "  ${D}не під'єднано${N}"
        echo ""
    fi

    echo "${B}utun-інтерфейси:${N}"
    local utuns
    # Кожен заголовок інтерфейсу скидає i, інакше utun без IPv4 підбирає inet
    # наступного інтерфейсу (utun0 «крав» адресу en0).
    utuns=$(ifconfig 2>/dev/null | awk '
        /^[a-z][a-z0-9]*:/ { i = /^utun[0-9]/ ? substr($1, 1, length($1) - 1) : "" ; next }
        i && /^[[:space:]]*inet [0-9]/ { print i": "$2; i="" }')
    if [ -n "$utuns" ]; then
        echo "$utuns" | sed 's/^/  /'
    else
        # utun без IPv4 — це не живий тунель (link-local IPv6 є майже завжди),
        # але корисно бачити, що інтерфейси взагалі існують.
        local idle; idle=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -c '^utun[0-9]')
        echo "  ${D}немає з IPv4${N}${D} (utun-інтерфейсів без IPv4: $idle)${N}"
    fi
    local off; off=$(backends_off)
    [ -z "$off" ] || { echo ""; echo "${D}вимкнено в config.env (не перевіряється): $off${N}"; }
}

cmd_list() {
    echo "${B}Доступні тунелі:${N}"
    echo ""
    if backend_on wireguard; then
        echo "${B}WireGuard${N} ${D}($(wg_config_dir 2>/dev/null || echo 'конфіги не знайдено'))${N}:"
        local cfgs; cfgs=$(wg_list_configs)
        if [ -n "$cfgs" ]; then
            echo "$cfgs" | sed 's/^/  /'
        else
            echo "  ${D}немає .conf файлів${N}"
        fi
        echo ""
    fi
    if backend_on openvpn; then
        echo "${B}OpenVPN${N}:"
        echo "  openvpn   ${D}— інтерактивний вибір профілю (scripts/vpn-up.sh)${N}"
        echo ""
    fi
    local ccli
    if backend_on cisco && ccli=$(cisco_cli); then
        echo "${B}Cisco Secure Client${N} ${D}($ccli)${N}:"
        local chosts ch cur; chosts=$(cisco_hosts); cur=$(cisco_connected_host)
        if [ -n "$chosts" ]; then
            while IFS= read -r ch; do
                [ -n "$ch" ] || continue
                if [ -n "$cur" ] && [ "${ch%%:*}" = "${cur%%:*}" ]; then
                    printf "  %-30s ${G}● під'єднано${N}\n" "$ch"
                else
                    printf "  %s\n" "$ch"
                fi
            done <<< "$chosts"
        else
            echo "  ${D}у профілі немає хостів (можна: up cisco <адреса>)${N}"
        fi
        echo "  ${D}підключити: up cisco [хост]   (GUI має бути закритий — спитає)${N}"
        echo ""
    fi
    local dcli
    if backend_on defguard && dcli=$(dg_cli); then
        echo "${B}Defguard${N} ${D}($dcli)${N}:"
        local targets kind name ep mfa rt st
        targets=$(dg_targets)
        if ! command -v jq >/dev/null 2>&1; then
            echo "  ${Y}потрібен jq для розбору 'defguard-client list --json'${N}"
        elif [ -n "$targets" ]; then
            while IFS=$'\t' read -r kind name ep mfa rt; do
                [ -n "$name" ] || continue
                st=$(dg_session "$name" | cut -f1)
                [ "$st" = Connected ] && st="${G}● підключено${N}" || st=""
                printf "  %-16s %-32s ${D}%s, MFA %s, трафік %s${N} %s\n" \
                    "$name" "$ep" "$kind" "$mfa" "$rt" "$st"
            done <<< "$targets"
            echo "  ${D}підключити: up defguard [назва]   (або up <назва>, якщо немає WG-конфігу з такою)${N}"
        else
            echo "  ${D}немає локацій (додай інстанс у застосунку Defguard)${N}"
        fi
        echo ""
    fi
    local off; off=$(backends_off)
    [ -z "$off" ] || echo "${D}вимкнено в config.env: $off${N}"
    echo "${D}Додати новий тунель: ./main-vpn-manager.sh cert <wg|openvpn>${N}"
}

cmd_up() {
    local tunnel="${1:-}"
    [ -n "$tunnel" ] || die "вкажи назву тунелю. Див. './main-vpn-manager.sh list'"

    case "$tunnel" in
        openvpn)     backend_need openvpn;  exec "$SCRIPTS/vpn-up.sh" ;;
        defguard|dg) backend_need defguard; shift; dg_up "$@"; return ;;
        dg:*)        backend_need defguard; shift; dg_up "${tunnel#dg:}" "$@"; return ;;
        cisco)       backend_need cisco;    shift; cisco_up "$@"; return ;;
    esac
    # Голе ім'я без WG-конфігу, але з такою локацією в Defguard → Defguard.
    if backend_on defguard && { ! backend_on wireguard || ! wg_has "$tunnel"; } \
            && dg_cli >/dev/null && [ -n "$(dg_kind "$tunnel")" ]; then
        shift; dg_up "$tunnel" "$@"; return
    fi

    backend_need wireguard
    command -v wg-quick >/dev/null 2>&1 || die "wg-quick не встановлено"
    local dir; dir=$(wg_config_dir) || die "директорію конфігів WireGuard не знайдено (${WG_DIRS[*]})"
    [ -f "$dir/$tunnel.conf" ] || die "конфіг '$tunnel.conf' не знайдено в $dir"

    echo "${B}Піднімаю WireGuard-тунель '$tunnel'...${N}"
    sudo wg-quick up "$(wg_target "$tunnel")"
}

# Опустити один елемент меню down: wg:<name> | openvpn | ovpn:<id> | cisco | dg:<назва|all>.
down_one() {
    case "$1" in
        wg:*)
            echo "Опускаю WireGuard '${1#wg:}'..."
            sudo wg-quick down "$(wg_target "${1#wg:}")"
            ;;
        openvpn)
            "$SCRIPTS/vpn-down.sh"
            ;;
        ovpn:*)
            "$SCRIPTS/vpn-down.sh" "${1#ovpn:}"
            ;;
        cisco)
            # Cisco сам відкочує свій DNS, restore_dns тут не потрібен.
            echo "Від'єдную Cisco Secure Client..."
            "$(cisco_cli)" -s disconnect | grep -E 'state:|error' | sed 's/^[[:space:]]*>> /  /'
            ;;
        dg:*)
            # NE сам відкочує свій DNS/маршрути — restore_dns теж не потрібен.
            echo "Від'єдную Defguard '${1#dg:}'..."
            dg_down "${1#dg:}"
            ;;
    esac
}

# Третьосторонні тунелі (Cisco, Defguard) прибирають свій DNS самі — після них
# досить скинути кеш; restore_dns лише для наших wg-quick/openvpn.
down_is_foreign() { case "$1" in cisco|dg:*) return 0 ;; esac; return 1; }

cmd_down() {
    local tunnel="${1:-}"

    # Завжди показуємо статус перед вимкненням.
    cmd_status
    echo ""

    if [ -n "$tunnel" ]; then
        local item
        case "$tunnel" in
            openvpn|cisco) backend_need "$tunnel"; item="$tunnel" ;;
            defguard|dg)   backend_need defguard;  item="dg:${2:-all}" ;;
            dg:*)          backend_need defguard;  item="$tunnel" ;;
            *)
                # Голе ім'я: живий WG-тунель/конфіг має пріоритет, інакше — сесія Defguard.
                if backend_on defguard && [ -n "$(dg_session "$tunnel")" ] && { ! backend_on wireguard \
                        || { ! wg_has "$tunnel" && ! wg_active_map | grep -q "^$tunnel "; }; }; then
                    item="dg:$tunnel"
                else
                    backend_need wireguard
                    item="wg:$tunnel"
                fi ;;
        esac
        down_one "$item"
        if down_is_foreign "$item"; then dns_flush; else restore_dns; fi
        return
    fi

    # Без аргументу — меню з усього, що зараз живе.
    local items=() labels=() name iface map=""
    backend_on wireguard && map=$(wg_active_map)
    while read -r name iface; do
        [ -n "$name" ] || continue
        items+=("wg:$name"); labels+=("WireGuard  $name ${D}($iface)${N}")
    done <<< "$map"
    local opid oid
    while IFS=$'\t' read -r opid oid; do
        [ -n "$opid" ] || continue
        local ost; ost=$(ovpn_state "$opid" | cut -f1)
        case "$ost" in up) ost="підключено" ;; connecting) ost="НЕ підключено" ;; *) ost="стан ?" ;; esac
        items+=("ovpn:$opid"); labels+=("OpenVPN    $oid ${D}($(ovpn_remote "$oid"), $ost, PID $opid)${N}")
    done <<< "$(backend_on openvpn && ovpn_instances)"
    local chost=""; backend_on cisco && chost=$(cisco_connected_host)
    [ -n "$chost" ] && { items+=(cisco); labels+=("Cisco      ${D}($chost)${N}"); }
    local dst duuid dname
    while IFS=$'\t' read -r dst duuid dname; do
        [ -n "$duuid" ] && [ "$dst" != Disconnected ] || continue
        items+=("dg:$dname"); labels+=("Defguard   $dname ${D}($(dg_iface "$duuid"), $dst)${N}")
    done <<< "$(backend_on defguard && dg_sessions)"

    [ "${#items[@]}" -gt 0 ] || { echo "Активних тунелів немає."; return 0; }

    echo "${B}Що опустити?${N}"
    local i
    for i in "${!items[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${labels[$i]}"
    done
    read -rp "Номери через кому / all / Enter=скасувати: " pick

    local targets=() idx idxs
    case "$pick" in
        "")             echo "Скасовано."; return 0 ;;
        all|ALL|y|Y)    targets=("${items[@]}") ;;
        *)
            IFS=',' read -ra idxs <<< "$pick"
            for idx in "${idxs[@]}"; do
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#items[@]}" ]; then
                    targets+=("${items[$((idx - 1))]}")
                else
                    echo "Пропускаю невірний номер: $idx"
                fi
            done
            ;;
    esac
    [ "${#targets[@]}" -gt 0 ] || { echo "Нічого не вибрано."; return 0; }

    local t ours=0
    for t in "${targets[@]}"; do
        down_one "$t"
        down_is_foreign "$t" || ours=1
    done
    if [ "$ours" -eq 1 ]; then restore_dns; else dns_flush; fi
    echo "${G}Готово.${N}"
}

cmd_cert() {
    local backend="${1:-}"
    case "$backend" in
        wg|wireguard)  backend_need wireguard; exec "$SCRIPTS/wg-cert.sh" "${@:2}" ;;
        openvpn|ovpn)  backend_need openvpn;   exec "$SCRIPTS/vpn-cert.sh" "${@:2}" ;;
        "")
            echo "${B}Керування сертифікатами — оберіть бекенд:${N}"
            echo "  1) WireGuard"
            echo "  2) OpenVPN"
            read -rp "Номер [1-2]: " b
            case "$b" in
                1) backend_need wireguard; exec "$SCRIPTS/wg-cert.sh" ;;
                2) backend_need openvpn;   exec "$SCRIPTS/vpn-cert.sh" ;;
                *) die "невірний вибір" ;;
            esac
            ;;
        *) die "невідомий бекенд '$backend'. Використовуй: cert wg | cert openvpn" ;;
    esac
}

# Випадок 3 «dns fix» для NE-тунелів без CLI: показати процеси, що можуть
# тримати тунель, і вбити вибрані. 1 = скасовано / нічого не вибрано.
fix_kill_tunnel_procs() {
    local iface="$1"
    local -a rpids=() rnames=() rkind=() rlabel=()
    local line pid cmd0 role
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid=$(printf '%s' "$line" | awk '{print $1}')
        cmd0=$(printf '%s' "$line" | cut -d' ' -f2-)   # повний cmd — для класифікації
        role=$(vpn_proc_role "$cmd0")
        rpids+=("$pid"); rnames+=("$(basename "$(printf '%s' "$line" | awk '{print $2}')")")
        rkind+=("${role%%|*}"); rlabel+=("${role#*|}")
    done < <(vpn_tunnel_procs)
    if [ "${#rpids[@]}" -eq 0 ]; then
        echo "  Процесів тунелю не бачу. Відключи VPN у його застосунку і повтори."
        return 1
    fi
    # Провайдери живих тунелів — вперед, фонові демони — назад. Так номер 1
    # майже завжди і є винуватець, а не Cisco-демон, який тут просто крутиться.
    local -a kpids=() knames=() kkind=() klabel=()
    local i tuncount=0
    for i in "${!rpids[@]}"; do [ "${rkind[$i]}" = "tunnel" ] && {
        kpids+=("${rpids[$i]}"); knames+=("${rnames[$i]}"); kkind+=("tunnel"); klabel+=("${rlabel[$i]}"); tuncount=$((tuncount+1)); }; done
    for i in "${!rpids[@]}"; do [ "${rkind[$i]}" = "daemon" ] && {
        kpids+=("${rpids[$i]}"); knames+=("${rnames[$i]}"); kkind+=("daemon"); klabel+=("${rlabel[$i]}"); }; done

    echo "  Процеси, що можуть тримати тунель ${D}(первинний: $iface)${N}:"
    local mk
    for i in "${!kpids[@]}"; do
        mk="${Y}"; [ "${kkind[$i]}" = "daemon" ] && mk="${D}"
        printf "   %2d) ${mk}%-20s${N} ${D}PID %-6s %s${N}\n" \
            "$((i + 1))" "${klabel[$i]}" "${kpids[$i]}" "${knames[$i]}"
    done
    echo ""
    echo "  ${D}Cisco-демони (vpnagentd/acsockext) крутяться завжди — тунель вони тримають${N}"
    echo "  ${D}лише коли AnyConnect під'єднаний. Опускай ПРОВАЙДЕРА активного VPN (жовті).${N}"
    [ "$tuncount" -eq 1 ] && \
        echo "  ${G}Схоже, винуватець — №1 (${klabel[0]}).${N}"
    echo "  ${D}Для ClearVPN надійніше Disconnect у застосунку: kill відроджує systemextensionsd.${N}"
    echo ""
    local pick
    read -rp "  Вбити — які? [номери через кому / all / n=ні]: " pick
    local -a ksel=()
    case "$pick" in
        ""|n|N) echo "  Скасовано. Відключи VPN у застосунку і повтори 'dns fix'."; return 1 ;;
        all|ALL|всі) ksel=("${kpids[@]}") ;;
        *)
            local idx idxs
            IFS=',' read -ra idxs <<< "$pick"
            for idx in "${idxs[@]}"; do
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#kpids[@]}" ]; then
                    ksel+=("${kpids[$((idx - 1))]}")
                else
                    echo "  Пропускаю невірний номер: $idx"
                fi
            done
            ;;
    esac
    [ "${#ksel[@]}" -gt 0 ] || { echo "  Нічого не вибрано."; return 1; }
    local p
    for p in "${ksel[@]}"; do
        echo "  kill $p"
        sudo kill "$p" 2>/dev/null
    done
    sleep 2
    # НЕ kill -0: для root-процесу без root він дає EPERM і на живому.
    for p in "${ksel[@]}"; do
        if ps -p "$p" >/dev/null 2>&1; then
            echo "  ще живий — kill -9 $p"
            sudo kill -9 "$p" 2>/dev/null
        fi
    done
}

# Ремонт «DNS зник / усе висить». Три випадки:
#   1) все здорове — нічого не чіпаємо;
#   2) мертвий тунель лишив резолвер у State — purge осиротілих + bounce (класика);
#   3) первинний — ЖИВИЙ, але зламаний VPN (utunN, резолвери мовчать): він тримає
#      default route і DNS → чорна діра для ВСЬОГО трафіку, інші VPN теж не
#      з'єднаються зі своїм сервером. Конфігурацією DNS це не лікується — треба
#      опустити тунель; пропонуємо вбити його процес, потім відновлюємо DNS.
cmd_dns_fix() {
    local want="${1:-}" iface svc cand available cur servers s alive=0 probeline=""

    echo "${B}=== Ремонт DNS ===${N}"
    iface=$(dns_primary_iface)
    servers=$(dns_global_servers)
    printf "  первинний інтерфейс : %s\n" "${iface:-${R}немає${N}}"
    # shellcheck disable=SC2086
    for s in $servers; do
        if dns_probe "$s"; then alive=$((alive + 1)); probeline+="${G}${s} ✓${N} "
        else probeline+="${R}${s} ✗${N} "; fi
    done
    printf "  діючий резолвер     : %s\n" "${probeline:-${R}(порожньо)${N}}"

    # ── Випадок 3: первинний — живий VPN-тунель ─────────────────────────────
    if iface_is_utun "$iface"; then
        if [ "$alive" -gt 0 ]; then
            echo ""
            echo "  Первинний — VPN-тунель ($iface), і його DNS відповідає. Лагодити нічого."
            return 0
        fi
        echo ""
        echo "  ${R}Первинний — VPN-тунель ($iface), але його резолвери НЕ відповідають.${N}"
        echo "  Він тримає default route і DNS → чорна діра для всього трафіку"
        echo "  (навіть інші VPN не досягнуть свого сервера). Поки тунель живий,"
        echo "  перенастроювання DNS безсиле — треба опустити тунель."
        local diface split
        diface=$(route_default_iface)
        split=$(route_split_default | tr '\n' ' ')
        printf "  ${D}маршрут: default → %s${N}\n" "${diface:-—}"
        [ -n "${split// /}" ] && \
            printf "  ${D}перехоплення 0/1+128.0/1 → %s${N}\n" "${split% }"
        echo ""
        local owner; owner=$(utun_owner "$iface")
        case "$owner" in
            "Defguard "*)
                # Розширення Defguard живе 24/7 і відроджується — kill тут глухий кут.
                # CLI знімає сесію коректно (і GUI бачить той самий стан).
                local a
                read -rp "  Тунель тримає ${owner}. Від'єднати через defguard-client? [Y/n]: " a
                case "$a" in n|N) echo "  Скасовано."; return 1 ;; esac
                dg_down "${owner#Defguard }" || return 1
                ;;
            *)
                fix_kill_tunnel_procs "$iface" || return 1
                ;;
        esac

        # macOS зриває маршрут+DNS тунелю АСИНХРОННО: процес помер миттєво, а
        # SystemConfiguration ще ~5-10с тримає utun первинним і його резолвери
        # глобальними. Без очікування re-probe нижче ловить цей проміжний стан
        # і бреше «маршрути/мережа», хоча kill спрацював (ping оживає за мить).
        # Тож чекаємо, поки первинний перестане бути utun, а не фіксовану паузу.
        printf "  чекаю, поки тунель відпустить мережу"
        local waited=0
        while [ "$waited" -lt 20 ]; do
            iface=$(dns_primary_iface)
            iface_is_utun "$iface" || break
            printf "."
            sleep 1
            waited=$((waited + 1))
        done
        echo ""
        if iface_is_utun "$iface"; then
            echo "  ${Y}тунель ($iface) досі первинний після ${waited}с${N} — розширення,"
            echo "  ${Y}схоже, перезапустилось і знову підняло тунель.${N} kill тут — глухий кут:"
            echo "  systemextensionsd відроджує процес. Відключи VPN у ЙОГО застосунку"
            echo "  (кнопкою Disconnect), тоді повтори 'dns fix'."
            return 1
        fi
        echo ""
    elif [ "$alive" -gt 0 ] && [ -z "$want" ] && [ -z "$(dns_orphan_uuids)" ]; then
        # ── Випадок 1: все здорове ──────────────────────────────────────────
        echo ""
        echo "  Все здорове: резолвер відповідає, осиротілих записів немає."
        echo "  ${D}Форсувати перевстановлення: ./main-vpn-manager.sh dns fix <сервери>${N}"
        return 0
    fi

    # ── Випадок 2 (і хвіст 3-го): purge осиротілих + bounce реального сервісу ──
    iface=$(dns_primary_iface)
    svc=$(svc_for_iface "$iface")
    if [ -z "$svc" ]; then
        available=$(networksetup -listallnetworkservices 2>/dev/null)
        for cand in "${DNS_SERVICES[@]}"; do
            printf '%s\n' "$available" | grep -qxF "$cand" && { svc="$cand"; break; }
        done
        [ -n "$svc" ] || die "не знайшов реального сервісу для ремонту (див. DNS_SERVICES у config.env)"
    fi
    printf "  ремонтую через '%s'\n" "$svc"

    dns_purge_orphans

    [ -n "$want" ] || want="$RESTORE_DNS"
    if [ -z "$want" ]; then
        cur=$(networksetup -getdnsservers "$svc" 2>/dev/null | grep -vi "aren't any" | tr '\n' ' ')
        want="$cur"
    fi
    [ -n "${want// /}" ] || want="1.1.1.1"

    echo "  перевстановлюю DNS на '$svc': $want"
    dns_bounce "$svc" "$want" || die "не вдалося встановити DNS на '$svc'"
    dns_flush

    # ── Чесна перевірка: правильна конфігурація — ще не робочий DNS ─────────
    local ok=0
    iface=$(dns_primary_iface)
    servers=$(dns_global_servers)
    # shellcheck disable=SC2086
    for s in $servers; do dns_probe "$s" && { ok=1; break; }; done
    printf "\n  первинний: %s, діючий резолвер: %s\n" "${iface:-—}" "${servers:-(порожньо)}"
    if [ "$ok" -eq 1 ]; then
        echo "${G}Готово — DNS відповідає.${N}"
    else
        echo "${R}Резолвер досі не відповідає.${N} Конфігурацію DNS виправлено, тож проблема"
        echo "нижче — маршрути/мережа."
        if iface_is_utun "$iface"; then
            echo "Первинний досі $iface — VPN не відпустив мережу; відключи його в застосунку."
        fi
        return 1
    fi
}

# Split-DNS через /etc/resolver/<домен>: запити до домену йдуть на вказаний сервер,
# хоч би що записав у глобальний резолвер інший VPN (Cisco ставить 8.8.8.8 першим,
# а на NXDOMAIN macOS до наступного сервера не переходить). Файли в /etc/resolver
# не чіпає ні Cisco, ні wg-quick — тому це єдиний стійкий спосіб.
RESOLVER_DIR="/etc/resolver"

cmd_dns_split() {
    local action="${1:-}" domain="${2:-}"
    case "$action" in
        ""|list|ls)
            echo "${B}=== Split-DNS ($RESOLVER_DIR) ===${N}"
            local f any=0
            shopt -s nullglob
            for f in "$RESOLVER_DIR"/*; do
                any=1
                printf "  ${G}%-28s${N} → %s\n" "$(basename "$f")" \
                    "$(awk '/^nameserver/ { printf "%s ", $2 }' "$f")"
            done
            [ "$any" -eq 1 ] || echo "  ${D}немає правил${N}"
            echo ""
            echo "  ${D}додати:  ./main-vpn-manager.sh dns split add <домен> [сервер ...]${N}"
            echo "  ${D}забрати: ./main-vpn-manager.sh dns split rm <домен>${N}"
            ;;
        add)
            [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
                || die "вкажи домен: dns split add <домен> [сервер ...]"
            shift 2
            local servers=("$@")
            if [ "${#servers[@]}" -eq 0 ]; then
                read -rp "DNS-сервер для '$domain' (напр. DNS з WG-конфігу): " srv
                [ -n "$srv" ] || { echo "Скасовано."; return 0; }
                read -ra servers <<< "$srv"
            fi
            local sv
            for sv in "${servers[@]}"; do
                [[ "$sv" =~ ^[0-9a-fA-F.:]+$ ]] || die "не схоже на IP: $sv"
            done
            sudo mkdir -p "$RESOLVER_DIR" || return 1
            printf 'nameserver %s\n' "${servers[@]}" | sudo tee "$RESOLVER_DIR/$domain" >/dev/null || return 1
            dns_flush
            echo "${G}*.$domain → ${servers[*]}${N}"
            if command -v dscacheutil >/dev/null 2>&1; then
                echo "  ${D}перевір: dscacheutil -q host -a name <хост>.$domain${N}"
            fi
            ;;
        rm|del|remove)
            [ -n "$domain" ] || die "вкажи домен: dns split rm <домен>"
            [ -f "$RESOLVER_DIR/$domain" ] || die "правила для '$domain' немає"
            sudo rm -f "$RESOLVER_DIR/$domain" && dns_flush && echo "Прибрано: $domain"
            ;;
        *) die "dns split [list | add <домен> [сервер ...] | rm <домен>]" ;;
    esac
}

cmd_dns() {
    command -v networksetup >/dev/null 2>&1 || die "networksetup недоступний"
    command -v scutil       >/dev/null 2>&1 || die "scutil недоступний"

    case "${1:-}" in
        fix|repair) cmd_dns_fix "${2:-}"; return ;;
        split)      shift; cmd_dns_split "$@"; return ;;
    esac

    svc_device_load                       # прогріти кеш до циклу зі svc_is_vpn()
    echo "${B}=== DNS по мережевих сервісах ===${N}"
    local primary_iface primary_svc
    primary_iface=$(dns_primary_iface)
    primary_svc=$(svc_for_iface "$primary_iface")
    printf "  ${D}діючий резолвер:${N} ${G}%s${N} ${D}(первинний: %s / %s)${N}\n" \
        "$(dns_global_servers)" "${primary_svc:-—}" "${primary_iface:-—}"
    dns_owner_hint
    echo ""

    local default_dns="${RESTORE_DNS:-8.8.8.8}"
    local svc dns tag svc_names=() svc_dns=() svc_tag=()
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        case "$svc" in \**) continue ;; esac          # вимкнені сервіси (з *)
        dns=$(networksetup -getdnsservers "$svc" 2>/dev/null)
        if printf '%s' "$dns" | grep -qi "aren't any"; then
            dns="(немає)"
        else
            dns=$(printf '%s' "$dns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        fi
        tag=""; svc_is_vpn "$svc" && tag="← VPN: DNS керує тунель"
        svc_names+=("$svc"); svc_dns+=("$dns"); svc_tag+=("$tag")
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

    [ "${#svc_names[@]}" -gt 0 ] || { echo "  (активних сервісів не знайдено)"; return 0; }

    local i mark
    for i in "${!svc_names[@]}"; do
        # VPN-сервіси приглушені: писати в них DNS через networksetup здебільшого марно.
        if   [ -n "${svc_tag[$i]}" ];            then mark="${D}"
        elif [ "${svc_dns[$i]}" = "(немає)" ];   then mark="${Y}"
        else                                          mark="${G}"; fi
        printf "  ${mark}%2d)${N} %-24s ${D}%-16s${N} ${D}%s${N}\n" \
            "$((i + 1))" "${svc_names[$i]}" "${svc_dns[$i]}" "${svc_tag[$i]}"
    done

    echo ""
    echo "  ${D}DNS зник після VPN? → ./main-vpn-manager.sh dns fix${N}"
    echo ""
    read -rp "Встановити DNS — на яких сервісах? [номери через кому / all / n=ні]: " pick
    [ -n "$pick" ] || { echo "Скасовано."; return 0; }
    case "$pick" in n|N) echo "Скасовано."; return 0 ;; esac

    read -rp "Який DNS? [Enter=$default_dns]: " dns_in
    local dns_val="${dns_in:-$default_dns}"
    [ -n "$dns_val" ] || { echo "Порожньо — скасовано."; return 0; }

    local targets=()
    case "$pick" in
        all|ALL|всі) targets=("${svc_names[@]}") ;;
        *)
            local idx idxs
            IFS=',' read -ra idxs <<< "$pick"
            for idx in "${idxs[@]}"; do
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#svc_names[@]}" ]; then
                    targets+=("${svc_names[$((idx - 1))]}")
                else
                    echo "Пропускаю невірний номер: $idx"
                fi
            done
            ;;
    esac

    [ "${#targets[@]}" -gt 0 ] || { echo "Нічого не вибрано."; return 0; }
    for svc in "${targets[@]}"; do
        if svc_is_vpn "$svc"; then
            echo "${Y}Увага:${N} '$svc' — VPN-сервіс. Його DNS задає сам тунель через"
            echo "        State-стор, тож цей запис буде проігноровано. Потрібен 'dns fix'."
        fi
        echo "DNS '$dns_val' → '$svc'"
        dns_bounce "$svc" "$dns_val"
    done
    dns_flush
    printf "  ${D}діючий резолвер тепер:${N} ${G}%s${N}\n" "$(dns_global_servers)"
    echo "${G}Готово.${N}"
}

# Чий це utun: "WireGuard <назва>" / "OpenVPN <профіль>" / "Cisco Secure Client" /
# назва NE-сервісу (ClearVPN…) / порожньо. Без sudo.
utun_owner() {
    local u="$1" nf names=() pid id st dev key svc name
    # WireGuard: wireguard-go тримає $WG_RUN/<utunN>.sock (видно всім), а
    # <назва>.name часто root 400 — тоді назву беремо, лише якщо тунель один.
    if backend_on wireguard && [ -e "$WG_RUN/$u.sock" ]; then
        for nf in "$WG_RUN"/*.name; do
            [ -e "$nf" ] || continue
            names+=("$(basename "$nf" .name)")
            [ -r "$nf" ] && [ "$(cat "$nf" 2>/dev/null)" = "$u" ] && \
                { echo "WireGuard $(basename "$nf" .name)"; return; }
        done
        [ ${#names[@]} -eq 1 ] && echo "WireGuard ${names[0]}" || echo "WireGuard"
        return
    fi
    while IFS=$'\t' read -r pid id; do
        [ -n "$pid" ] || continue
        IFS=$'\t' read -r st dev <<< "$(ovpn_state "$pid")"
        [ "$st" = up ] && [ "$dev" = "$u" ] && { echo "OpenVPN $id"; return; }
    done <<< "$(backend_on openvpn && ovpn_instances)"
    # Defguard: State-сервіс живого тунелю з сесією не пов'язаний — питаємо сесії.
    while IFS=$'\t' read -r st key name; do
        [ "$st" = Connected ] && [ "$(dg_iface "$key")" = "$u" ] && { echo "Defguard $name"; return; }
    done <<< "$(backend_on defguard && dg_sessions)"
    # Сторонні VPN: State-сервіс, чий IPv4.InterfaceName = цей utun.
    for key in $(printf 'list State:/Network/Service/.*/IPv4\nquit\n' | scutil 2>/dev/null | awk '{print $NF}'); do
        [ "$(sc_show "$key" | awk '/InterfaceName/{print $NF}')" = "$u" ] || continue
        svc=${key#State:/Network/Service/}; svc=${svc%/IPv4}
        case "$svc" in
            com.cisco.anyconnect) echo "Cisco Secure Client" ;;
            *) name=$(sc_show "Setup:/Network/Service/$svc" | sed -n 's/^ *UserDefinedName : //p')
               echo "${name:-VPN-сервіс $svc}" ;;
        esac
        return
    done
}

# Усі маршрути, які дають VPN: по кожному живому utun (з IPv4) — що через нього
# йде, і хто його власник; плюс host-маршрути до VPN-серверів через LAN-шлюз
# (route-fix з vpn-up.sh / wg-quick тримають так підложку тунелю).
route_vpn_table() {
    local tbl u ip owner rows
    tbl=$(netstat -rn -f inet 2>/dev/null)
    echo "  ${D}маршрути VPN-тунелів:${N}"
    local found=0
    while read -r u ip; do
        [ -n "$u" ] || continue
        found=1
        owner=$(utun_owner "$u")
        rows=$(awk -v i="$u" -v own="$ip" '
            $4 == i && $1 != own && $1 !~ /^22[4-9]|^23[0-9]|^255\.255\.255\.255/ {
                d = $1; if (d == "default" && $3 ~ /I/) d = "default (scoped)"
                g = ($2 ~ /^link#|^utun/ || $2 == own) ? "" : "via " $2
                printf "      %-22s %s\n", d, g; n++ }
            END { if (!n) print "      (немає)" }' <<< "$tbl")
        printf "    ${G}%s${N} %s ${D}— %s, %s маршр.${N}\n" "$u" "$ip" \
            "${owner:-власник невідомий}" "$(grep -cv '(немає)' <<< "$rows")"
        printf '%s\n' "$rows"
    done <<< "$(ifconfig 2>/dev/null | awk '
        /^[a-z][a-z0-9]*:/ { i = /^utun[0-9]/ ? substr($1, 1, length($1) - 1) : "" ; next }
        i && /^[[:space:]]*inet [0-9]/ { print i" "$2; i="" }')"
    [ "$found" -eq 1 ] || echo "    ${D}немає живих тунелів${N}"

    # Статичні /32 через шлюз на фізичному інтерфейсі = маршрути до VPN-серверів.
    rows=$(awk '$1 ~ /\/32$/ && $3 ~ /G/ && $3 ~ /S/ && $4 !~ /^utun|^lo/ {
        printf "      %-22s via %s (%s)\n", $1, $2, $4 }' <<< "$tbl")
    if [ -n "$rows" ]; then
        echo "    ${D}до VPN-серверів повз тунель (route-fix):${N}"
        printf '%s\n' "$rows"
    fi
}

# Підтвердити, хто ВОЛОДІЄ поточним маршрутом. Суто read-only (без sudo): показує
# default-інтерфейс, split-default 0/1+128.0/1 (як повнотунельні VPN обходять
# default), куди реально йдуть тестові адреси, і які utun живі (мають IPv4). Не
# чіпає маршрути навмисне: видаляти те, що встановив VPN, крихко — його чинить
# лише опускання тунелю (це вже робить 'dns fix' / кнопка Disconnect у застосунку).
cmd_route() {
    command -v route >/dev/null 2>&1 || die "route недоступний"
    echo "${B}=== Маршрут (хто несе трафік) ===${N}"

    local diface dgw split
    diface=$(route_default_iface); dgw=$(route_default_gw)
    if [ -n "$diface" ]; then
        if iface_is_utun "$diface"; then
            printf "  default → %s ${Y}(VPN-тунель тримає весь трафік)${N}\n" "$diface"
        else
            printf "  default → %s${D}%s${N}\n" "$diface" "${dgw:+ (шлюз $dgw)}"
        fi
    else
        echo "  ${R}default відсутній — трафік нікуди не піде${N}"
    fi

    split=$(route_split_default | tr '\n' ' ')
    if [ -n "${split// /}" ]; then
        printf "  ${Y}перехоплення: 0/1+128.0/1 → %s${N}\n" "${split% }"
        echo "  ${D}(повнотунельний VPN, напр. ClearVPN, обходить default цими /1-маршрутами)${N}"
    else
        echo "  ${D}split-default (0/1,128.0/1): немає${N}"
    fi

    # Куди РЕАЛЬНО підуть пакети до тестових адрес — це і є ground truth.
    local t ti
    echo ""
    echo "  ${D}куди йдуть тестові адреси:${N}"
    for t in 1.1.1.1 8.8.8.8; do
        ti=$(route_iface_for "$t")
        if iface_is_utun "$ti"; then
            printf "    %-9s → %s ${Y}(через VPN)${N}\n" "$t" "$ti"
        else
            printf "    %-9s → %s\n" "$t" "${ti:-${R}—${N}}"
        fi
    done

    # Живі тунелі (utun з IPv4) — кандидати на «викрадача» маршруту.
    local utuns
    utuns=$(ifconfig 2>/dev/null | awk '
        /^[a-z][a-z0-9]*:/ { i = /^utun[0-9]/ ? substr($1, 1, length($1) - 1) : "" ; next }
        i && /^[[:space:]]*inet [0-9]/ { print i" "$2; i="" }')
    echo ""
    echo "  ${D}живі utun (мають IPv4):${N}"
    if [ -n "$utuns" ]; then
        echo "$utuns" | sed 's/^/    /'
    else
        echo "    ${D}немає${N}"
    fi

    echo ""
    route_vpn_table

    # Діагноз: конфлікт = utun несе default або є split на utun.
    echo ""
    if iface_is_utun "$diface" || [ -n "${split// /}" ]; then
        echo "  ${R}Повнотунельний VPN тримає маршрут.${N} Коли це ClearVPN/Cisco поверх"
        echo "  робочих VPN — вони душать одне одного: робочий тунель втрачає підложку,"
        echo "  зривається й перепідключається (utun блимає). Лікується лише опусканням"
        echo "  зайвого тунелю: ${G}./main-vpn-manager.sh dns fix${N} (запропонує вбити) або"
        echo "  Disconnect у самому застосунку VPN."
        return 1
    fi

    # Фізичний default буває так само мертвим: USB-Ethernet у роутер без аплінку
    # перебиває Wi-Fi за порядком сервісів — шлюз є, інтернету немає.
    if [ -n "$diface" ] && ! net_iface_online "$diface"; then
        local dsvc alt
        dsvc=$(svc_for_iface "$diface")
        echo "  ${R}default несе ${dsvc:-$diface} ($diface), але інтернету через нього немає.${N}"
        if alt=$(net_first_online "$diface"); then
            printf "  А ось тут інтернет є: ${G}%s${N} (%s).\n" "${alt%%$'\t'*}" "${alt##*$'\t'}"
            echo "  Це не VPN, а порядок мережевих сервісів macOS:"
            echo "  ${G}./main-vpn-manager.sh net auto${N} — підняти робочий сервіс на верх."
        else
            echo "  ${D}Інші інтерфейси теж не бачать мережу — проблема вище за macOS.${N}"
        fi
        return 1
    fi

    echo "  ${G}Конфлікту немає:${N} default несе реальний інтерфейс з інтернетом."
}

# ─── пріоритет мережевих сервісів (Wi-Fi vs Ethernet) ───────────────────────
#
# macOS обирає ПЕРВИННИЙ сервіс не за наявністю інтернету, а за «Service Order»:
# виграє найвищий сервіс, у якого є IPv4 + шлюз. Тому USB-Ethernet у роутер без
# аплінку (шлюз є, інтернету немає) забирає default у Wi-Fi. Лікується порядком
# сервісів, а не маршрутами: ручний `route change default` живе до першої зміни
# стану мережі, після чого configd переписує все назад.

# Порядок сервісів: "enabled<TAB>назва<TAB>hwport<TAB>device". Порожній device =
# VPN-сервіс (він останній — порожнє поле в кінці не злипається з сусідами);
# hwport у VPN = провайдер (net.defguard, com.wireguard.macos, IPSec…).
net_services() {
    networksetup -listnetworkserviceorder 2>/dev/null | awk '
        /^\([0-9]+\) |^\(\*\) / {
            en = ($0 ~ /^\(\*\)/) ? 0 : 1
            name = $0; sub(/^\([0-9*]+\) /, "", name)
            if ((getline dline) <= 0) next
            hw = dline; sub(/.*Hardware Port: /, "", hw); sub(/, Device:.*$/, "", hw)
            dev = dline; sub(/.*Device: /, "", dev); sub(/\).*$/, "", dev)
            print en "\t" name "\t" (hw == "" ? "-" : hw) "\t" dev
        }'
}

# Чи є в інтерфейсу справжній аплінк (не просто шлюз). ICMP подекуди ріжуть —
# тому фолбек на HTTP через той самий інтерфейс.
net_iface_online() {
    local dev="$1" t
    [ -n "$dev" ] || return 1
    for t in 1.1.1.1 8.8.8.8; do
        ping -c1 -W 1200 -b "$dev" "$t" >/dev/null 2>&1 && return 0
    done
    command -v curl >/dev/null 2>&1 &&
        curl -sfm 3 --interface "$dev" http://captive.apple.com/hotspot-detect.html >/dev/null 2>&1
}

# Перший увімкнений сервіс (за порядком), у якого є адреса й реальний інтернет.
# Аргумент — device, який треба пропустити (поточний зламаний default).
net_first_online() {
    local skip="${1:-}" en name hw dev
    while IFS=$'\t' read -r en name hw dev; do
        [ "$en" = 1 ] && [ -n "$dev" ] || continue
        [ "$dev" = "$skip" ] && continue
        [ -n "$(ipconfig getifaddr "$dev" 2>/dev/null)" ] || continue
        net_iface_online "$dev" && { printf '%s\t%s\n' "$name" "$dev"; return 0; }
    done < <(net_services)
    return 1
}

# Підняти сервіс на верх Service Order. Порядок задається ПОВНИМ списком —
# networksetup приймає лише перелік усіх сервісів, інакше «parameters not valid».
net_apply_top() {
    local target="$1" en name hw dev found=0 thw="" tdev=""
    local -a rest=()
    while IFS=$'\t' read -r en name hw dev; do
        [ -n "$name" ] || continue
        if [ "$name" = "$target" ]; then found=1; thw="$hw"; tdev="$dev"; else rest+=("$name"); fi
    done < <(net_services)
    [ "$found" = 1 ] || die "немає такого сервісу: $target"
    echo "${D}sudo networksetup -ordernetworkservices \"$target\" …${N}"
    sudo networksetup -ordernetworkservices "$target" "${rest[@]}" || return 1
    echo "${G}✓${N} «$target» тепер перший у порядку сервісів."
    if [ -z "$tdev" ]; then
        # VPN-сервіс нагорі: macOS ранжує резолвери (order у scutil --dns) і вибирає
        # первинний за цим порядком — це має вагу, коли тунель піднятий.
        echo "  ${D}це VPN-сервіс ($thw): порядок діє, лише поки його тунель піднятий.${N}"
        echo "  ${D}первинним він стане, тільки якщо тунель несе default (all-traffic).${N}"
    fi
    # Порядок застосовується миттєво, але глобальний стан оновлюється не в ту ж мить.
    sleep 1
    local pi; pi=$(dns_primary_iface)
    printf "  первинний інтерфейс: %s\n" "${pi:-—}"
}

# Автофікс: первинний сервіс без інтернету → підняти найвищий, у якого він є.
net_auto() {
    local primary; primary=$(dns_primary_iface)
    if [ -z "$primary" ]; then
        echo "${R}Первинного інтерфейсу немає взагалі.${N} Мережа не піднята."
        return 1
    fi
    if iface_is_utun "$primary"; then
        echo "  default тримає VPN-тунель ${Y}$primary${N} — це не питання порядку сервісів."
        echo "  Дивись: ${G}./main-vpn-manager.sh route${N} / ${G}dns fix${N}"
        return 1
    fi
    local psvc; psvc=$(svc_for_iface "$primary")
    if net_iface_online "$primary"; then
        echo "${G}Все гаразд:${N} первинний ${psvc:-$primary} ($primary) має інтернет."
        return 0
    fi
    echo "  ${R}Первинний ${psvc:-$primary} ($primary) без інтернету.${N} Шукаю робочий…"
    local alt
    if ! alt=$(net_first_online "$primary"); then
        echo "  ${R}Жоден інший інтерфейс теж не бачить мережу.${N} Піднімати нічого."
        return 1
    fi
    net_apply_top "${alt%%$'\t'*}"
}

cmd_net() {
    command -v networksetup >/dev/null 2>&1 || die "networksetup недоступний"
    case "${1:-show}" in
        auto) net_auto; return $? ;;
        top)  shift; [ $# -ge 1 ] || die 'вкажіть сервіс: net top "Wi-Fi"'
              net_apply_top "$*"; return $? ;;
        show) ;;
        *)    die "невідомий підрежим: $1 (є: auto | top <сервіс>)" ;;
    esac

    echo "${B}=== Пріоритет мережевих сервісів ===${N}"
    echo "${D}(первинним стає найвищий сервіс зі шлюзом — навіть якщо інтернету там немає)${N}"
    echo ""
    local primary; primary=$(dns_primary_iface)
    local -a pick=()
    local i=0 en name hw dev ip gw online mark vtag dst
    while IFS=$'\t' read -r en name hw dev; do
        [ -n "$name" ] || continue
        i=$((i + 1)); pick[i]="$name"
        mark="  "; [ -n "$dev" ] && [ "$dev" = "$primary" ] && mark="${G}→${N} "
        if [ "$en" = 0 ]; then
            printf "  %s%2d) ${D}%-32s %-7s вимкнений${N}\n" "$mark" "$i" "$name" "${dev:--}"
            continue
        fi
        if [ -z "$dev" ]; then
            vtag="VPN-сервіс"
            if [ "$hw" = net.defguard ] && backend_on defguard; then
                vtag="Defguard"
                dst=$(dg_session "$name" | cut -f1)
                [ "$dst" = Connected ] && vtag="Defguard ${N}${G}● підключено${N}${D}"
            fi
            printf "  %s%2d) %-32s ${D}%-7s %s${N}\n" "$mark" "$i" "$name" "-" "$vtag"
            continue
        fi
        ip=$(ipconfig getifaddr "$dev" 2>/dev/null)
        if [ -z "$ip" ]; then
            printf "  %s%2d) ${D}%-32s %-7s без адреси${N}\n" "$mark" "$i" "$name" "$dev"
            continue
        fi
        gw=$(ipconfig getoption "$dev" router 2>/dev/null)
        if net_iface_online "$dev"; then online="${G}інтернет є${N}"; else online="${R}інтернету НЕМАЄ${N}"; fi
        printf "  %s%2d) %-32s %-7s %-15s ${D}шлюз %-15s${N} %s\n" \
            "$mark" "$i" "$name" "$dev" "$ip" "${gw:--}" "$online"
    done < <(net_services)

    echo ""
    printf "  ${D}→ = первинний зараз (%s)${N}\n" "${primary:-немає}"
    echo ""
    printf "Підняти сервіс на верх — номер; вимкнути сервіс — ${D}off <номер>${N}; Enter — нічого: "
    local ans; read -r ans
    case "$ans" in
        "" | n | N) echo "Нічого не змінено."; return 0 ;;
        off\ *|off*)
            local num="${ans#off}"; num="${num// /}"
            case "$num" in ""|*[!0-9]*) die "потрібен номер: off <номер>" ;; esac
            [ -n "${pick[$num]:-}" ] || die "немає такого номера: $num"
            echo "${D}sudo networksetup -setnetworkserviceenabled \"${pick[$num]}\" off${N}"
            sudo networksetup -setnetworkserviceenabled "${pick[$num]}" off &&
                echo "${G}✓${N} «${pick[$num]}» вимкнено (вмикається тим самим із 'on')."
            ;;
        *[!0-9]*) die "потрібен номер або 'off <номер>'" ;;
        *)
            [ -n "${pick[$ans]:-}" ] || die "немає такого номера: $ans"
            net_apply_top "${pick[$ans]}"
            ;;
    esac
}

cmd_help() {
    cat <<EOF
${B}main-vpn-manager.sh${N} — керування VPN-тунелями (WireGuard + OpenVPN + Defguard + Cisco)

${B}Використання:${N}
  ./main-vpn-manager.sh <команда> [тунель]

${B}Команди:${N}
  ${G}status${N}            показати всі активні VPN-тунелі (швидкий статус)
  ${G}list${N}              показати доступні тунелі (WG-конфіги + openvpn + Cisco-хости + Defguard-локації)
  ${G}up${N} <тунель>       підняти тунель: назва WG-тунелю, 'openvpn', 'cisco [хост]' або 'defguard [локація]'
  ${G}down${N} [тунель]     опустити тунель (WG-назва | openvpn | cisco | defguard [локація]); без
                    аргументу — меню з номерами активних тунелів
                    (перед вимкненням завжди показує статус)
  ${G}cert${N} <wg|openvpn> додати/керувати конфігами та сертифікатами
  ${G}dns${N}               показати DNS по сервісах і встановити на вибраних
  ${G}dns fix${N} [сервери] полагодити DNS, що зник після VPN (ClearVPN тощо)
  ${G}dns split${N} ...     split-DNS: домен → свій сервер (/etc/resolver), стійко до Cisco
  ${G}route${N}             хто володіє маршрутом (default + перехоплення) + усі маршрути VPN-тунелів
  ${G}net${N}               порядок мережевих сервісів + де реально є інтернет
  ${G}net auto${N}          підняти на верх той сервіс, у якого інтернет справді є
  ${G}net top${N} <сервіс>  вручну зробити сервіс первинним (напр. "Wi-Fi")
  ${G}help${N}              ця довідка

${B}Приклади:${N}
  ./main-vpn-manager.sh status
  ./main-vpn-manager.sh up wire-first      # WireGuard-тунель
  ./main-vpn-manager.sh up openvpn         # інтерактивний вибір .ovpn профілю
  ./main-vpn-manager.sh down wire-first
  ./main-vpn-manager.sh down               # меню: вибрати номер або all
  ./main-vpn-manager.sh up cisco           # Cisco через CLI (хост із профілю; логін/пароль спитає vpn)
  ./main-vpn-manager.sh down cisco         # від'єднати Cisco Secure Client
  ./main-vpn-manager.sh up defguard        # Defguard: меню локацій (MFA-код спитає)
  ./main-vpn-manager.sh up defguard staff --all-traffic   # решта аргументів → defguard-client connect
  ./main-vpn-manager.sh down defguard      # від'єднати всі Defguard-сесії
  ./main-vpn-manager.sh net top staff      # Defguard-сервіс «staff» на верх порядку сервісів
  ./main-vpn-manager.sh cert wg            # додати/згенерувати WireGuard-тунель
  ./main-vpn-manager.sh cert openvpn       # керування .ovpn профілями
  ./main-vpn-manager.sh dns                # перевірити/додати DNS на інтерфейсах
  ./main-vpn-manager.sh dns fix            # DNS зник після VPN — полагодити
  ./main-vpn-manager.sh dns fix 1.1.1.1    # те саме, з явними серверами
  ./main-vpn-manager.sh dns split add corp.lan 10.0.0.1   # *.corp.lan → 10.0.0.1
  ./main-vpn-manager.sh route              # хто тримає default / чи є перехоплення
  ./main-vpn-manager.sh net                # список сервісів за пріоритетом
  ./main-vpn-manager.sh net auto           # Ethernet без інтернету перебив Wi-Fi — полагодити
  ./main-vpn-manager.sh net top "Wi-Fi"    # завжди спершу Wi-Fi

${B}Про 'dns fix':${N}
  VPN-розширення (ClearVPN, FortiClient, Cisco) пишуть DNS у рантайм-стор macOS
  (State), який перемагає все, що ставить 'networksetup'. Звідси два зломи:
  1) тунель помер, а його резолвер лишився — 'dns fix' викидає осиротілі записи
     і форсує перерахунок (перезапис тим самим значенням macOS ігнорує);
  2) тунель ЖИВИЙ, але зламаний: він первинний (utunN), а його резолвери мовчать.
     Тоді він тримає default route і DNS → висне ВЕСЬ трафік, і навіть інші VPN
     не з'єднаються зі своїм сервером. Це не лікується конфігурацією — 'dns fix'
     знаходить процес тунелю, пропонує його вбити і потім відновлює DNS.
  Наприкінці 'dns fix' сам перевіряє резолвер і чесно скаже, якщо не допомогло.

${B}Про 'net':${N}
  macOS обирає первинний інтерфейс за порядком сервісів, а не за наявністю
  інтернету: перемагає найвищий сервіс, у якого є IPv4 зі шлюзом. Тому
  USB-Ethernet, увімкнений у роутер без аплінку, забирає весь трафік у Wi-Fi —
  шлюз є, інтернету немає. 'net' показує, де інтернет РЕАЛЬНО є (пінг з
  прив'язкою до інтерфейсу), 'net auto' піднімає робочий сервіс на верх.
  Правити 'route change default' марно: configd перепише при першій же зміні
  стану мережі — лікує тільки порядок сервісів (він постійний).

${B}Про Defguard:${N}
  На macOS це NetworkExtension (net.defguard), не wg-quick: кожна локація — окремий
  VPN-сервіс. Підключення/відключення йде через defguard-client (без sudo; CLI
  шукається в PATH, у /Applications/Defguard.app або в DEFGUARD_CLI з config.env).
  Свій DNS Defguard ставить для ВСІХ доменів і першим у резолвері (як Cisco);
  кілька тунелів з внутрішніми іменами → 'dns split add <домен> <dns>'.
  CLI запускається лише з бандла: через симлінк він не збереже тунель
  ("Failed to save tunnel configuration"), і MFA-локації не підключаться.

${B}Вимкнути бекенди:${N}
  config.env: DISABLED_BACKENDS="cisco openvpn"  (wireguard | openvpn | defguard | cisco).
  Вимкнений не показується в status/list/down і не опитується. За замовчуванням
  увімкнено все. Разово: DISABLED_BACKENDS=cisco ./main-vpn-manager.sh status

${B}Примітки:${N}
  • потребує sudo (створення tun-інтерфейсу, wg-quick); Defguard — ні
  • WireGuard-конфіги шукаються у: ${WG_DIRS[*]}
  • керування сертифікатами: scripts/wg-cert.sh (WG), scripts/vpn-cert.sh (OpenVPN)
EOF
}

# ─── диспетчер ──────────────────────────────────────────────────────────────

backends_validate

case "${1:-help}" in
    status|st)       cmd_status ;;
    list|ls)         cmd_list ;;
    up|start)        shift; cmd_up "$@" ;;
    down|stop)       shift; cmd_down "$@" ;;
    cert)            shift; cmd_cert "$@" ;;
    dns)             shift; cmd_dns "$@" ;;
    route|rt)        cmd_route ;;
    net|prio)        shift; cmd_net "$@" ;;
    help|-h|--help)  cmd_help ;;
    *)               die "невідома команда '${1}'. Див. './main-vpn-manager.sh help'" ;;
esac
