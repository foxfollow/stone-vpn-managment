#!/bin/bash
#
# main-vpn-manager.sh — централізована точка керування VPN-тунелями.
# Керує WireGuard (через wg-quick) та OpenVPN (через scripts/vpn-*.sh).
#
# Використання:
#   ./main-vpn-manager.sh status            показати всі активні тунелі (швидкий статус)
#   ./main-vpn-manager.sh list              показати доступні тунелі
#   ./main-vpn-manager.sh up <tunnel>       підняти тунель (назва WG-тунелю або 'openvpn')
#   ./main-vpn-manager.sh down [tunnel]     опустити тунель; без аргументу — всі
#   ./main-vpn-manager.sh cert <wg|openvpn> керування конфігами/сертифікатами
#   ./main-vpn-manager.sh dns               показати DNS по сервісах і встановити на вибраних
#   ./main-vpn-manager.sh dns fix [сервери] полагодити DNS, що зник після VPN
#   ./main-vpn-manager.sh help              ця довідка
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"

# Defaults (config.env may override any of these).
RESTORE_DNS=""
DNS_SERVICES=("Wi-Fi")

# Опціональний локальний конфіг (дефолти: RESTORE_DNS, DNS_SERVICES тощо).
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"

# Стандартні шляхи WireGuard (wg-quick шукає конфіги саме тут). НЕ міняти.
WG_DIRS=(/opt/homebrew/etc/wireguard /usr/local/etc/wireguard /etc/wireguard)
WG_RUN="/var/run/wireguard"        # тут wg-quick тримає <iface>.name (назва тунелю)
OVPN_PID="/tmp/openvpn.pid"

# ─── кольори (вимикаються коли вивід не в термінал) ──────────────────────────
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=''; G=''; R=''; Y=''; D=''; N=''
fi

die() { echo "${R}Помилка:${N} $*" >&2; exit 1; }

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

# PID запущеного openvpn (через PID-файл або pgrep), або порожньо.
ovpn_pid() {
    local pid=""
    [ -r "$OVPN_PID" ] && pid=$(cat "$OVPN_PID" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "$pid"; return 0
    fi
    pgrep -x openvpn 2>/dev/null | head -1
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

# Діючий глобальний DNS — те, що резолвер справді питає (а не те, що в преференсах).
dns_global_servers() {
    sc_show State:/Network/Global/DNS | awk '
        /ServerAddresses/                             { inblock = 1; next }
        inblock && /^[[:space:]]*}/                   { inblock = 0 }
        inblock && /^[[:space:]]*[0-9]+[[:space:]]*:/ { printf "%s ", $NF }'
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

    echo "${B}OpenVPN:${N}"
    local pid; pid=$(ovpn_pid)
    if [ -n "$pid" ]; then
        printf "  ${G}● запущено${N} ${D}(PID %s)${N}\n" "$pid"
    else
        echo "  ${D}не запущено${N}"
    fi
    echo ""

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
}

cmd_list() {
    echo "${B}Доступні тунелі:${N}"
    echo ""
    echo "${B}WireGuard${N} ${D}($(wg_config_dir 2>/dev/null || echo 'конфіги не знайдено'))${N}:"
    local cfgs; cfgs=$(wg_list_configs)
    if [ -n "$cfgs" ]; then
        echo "$cfgs" | sed 's/^/  /'
    else
        echo "  ${D}немає .conf файлів${N}"
    fi
    echo ""
    echo "${B}OpenVPN${N}:"
    echo "  openvpn   ${D}— інтерактивний вибір профілю (scripts/vpn-up.sh)${N}"
    echo ""
    echo "${D}Додати новий тунель: ./main-vpn-manager.sh cert <wg|openvpn>${N}"
}

cmd_up() {
    local tunnel="${1:-}"
    [ -n "$tunnel" ] || die "вкажи назву тунелю. Див. './main-vpn-manager.sh list'"

    if [ "$tunnel" = "openvpn" ]; then
        exec "$SCRIPTS/vpn-up.sh"
    fi

    command -v wg-quick >/dev/null 2>&1 || die "wg-quick не встановлено"
    local dir; dir=$(wg_config_dir) || die "директорію конфігів WireGuard не знайдено (${WG_DIRS[*]})"
    [ -f "$dir/$tunnel.conf" ] || die "конфіг '$tunnel.conf' не знайдено в $dir"

    echo "${B}Піднімаю WireGuard-тунель '$tunnel'...${N}"
    sudo wg-quick up "$(wg_target "$tunnel")"
}

cmd_down() {
    local tunnel="${1:-}"

    # Завжди показуємо статус перед вимкненням.
    cmd_status
    echo ""

    if [ -z "$tunnel" ]; then
        read -rp "Опустити ${R}ВСІ${N} активні тунелі? [y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }

        local map name iface
        map=$(wg_active_map)
        if [ -n "$map" ]; then
            while read -r name iface; do
                [ -n "$name" ] || continue
                echo "Опускаю WireGuard '$name'..."
                sudo wg-quick down "$(wg_target "$name")"
            done <<< "$map"
        fi
        if [ -n "$(ovpn_pid)" ]; then
            echo "Опускаю OpenVPN..."
            "$SCRIPTS/vpn-down.sh"
        fi
        restore_dns
        echo "${G}Готово.${N}"
        return
    fi

    if [ "$tunnel" = "openvpn" ]; then
        "$SCRIPTS/vpn-down.sh"
        restore_dns
        return
    fi

    echo "Опускаю WireGuard '$tunnel'..."
    sudo wg-quick down "$(wg_target "$tunnel")"
    restore_dns
}

cmd_cert() {
    local backend="${1:-}"
    case "$backend" in
        wg|wireguard)  exec "$SCRIPTS/wg-cert.sh" "${@:2}" ;;
        openvpn|ovpn)  exec "$SCRIPTS/vpn-cert.sh" "${@:2}" ;;
        "")
            echo "${B}Керування сертифікатами — оберіть бекенд:${N}"
            echo "  1) WireGuard"
            echo "  2) OpenVPN"
            read -rp "Номер [1-2]: " b
            case "$b" in
                1) exec "$SCRIPTS/wg-cert.sh" ;;
                2) exec "$SCRIPTS/vpn-cert.sh" ;;
                *) die "невірний вибір" ;;
            esac
            ;;
        *) die "невідомий бекенд '$backend'. Використовуй: cert wg | cert openvpn" ;;
    esac
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

cmd_dns() {
    command -v networksetup >/dev/null 2>&1 || die "networksetup недоступний"
    command -v scutil       >/dev/null 2>&1 || die "scutil недоступний"

    case "${1:-}" in
        fix|repair) cmd_dns_fix "${2:-}"; return ;;
    esac

    svc_device_load                       # прогріти кеш до циклу зі svc_is_vpn()
    echo "${B}=== DNS по мережевих сервісах ===${N}"
    local primary_iface primary_svc
    primary_iface=$(dns_primary_iface)
    primary_svc=$(svc_for_iface "$primary_iface")
    printf "  ${D}діючий резолвер:${N} ${G}%s${N} ${D}(первинний: %s / %s)${N}\n\n" \
        "$(dns_global_servers)" "${primary_svc:-—}" "${primary_iface:-—}"

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
    echo "  ${G}Конфлікту немає:${N} default несе реальний інтерфейс, перехоплення немає."
}

cmd_help() {
    cat <<EOF
${B}main-vpn-manager.sh${N} — керування VPN-тунелями (WireGuard + OpenVPN)

${B}Використання:${N}
  ./main-vpn-manager.sh <команда> [тунель]

${B}Команди:${N}
  ${G}status${N}            показати всі активні VPN-тунелі (швидкий статус)
  ${G}list${N}              показати доступні тунелі (WG-конфіги + openvpn)
  ${G}up${N} <тунель>       підняти тунель: назва WG-тунелю або 'openvpn'
  ${G}down${N} [тунель]     опустити тунель; без аргументу — всі
                    (перед вимкненням завжди показує статус)
  ${G}cert${N} <wg|openvpn> додати/керувати конфігами та сертифікатами
  ${G}dns${N}               показати DNS по сервісах і встановити на вибраних
  ${G}dns fix${N} [сервери] полагодити DNS, що зник після VPN (ClearVPN тощо)
  ${G}route${N}             підтвердити, хто володіє маршрутом (default + перехоплення)
  ${G}help${N}              ця довідка

${B}Приклади:${N}
  ./main-vpn-manager.sh status
  ./main-vpn-manager.sh up wire-first      # WireGuard-тунель
  ./main-vpn-manager.sh up openvpn         # інтерактивний вибір .ovpn профілю
  ./main-vpn-manager.sh down wire-first
  ./main-vpn-manager.sh down               # опустити все
  ./main-vpn-manager.sh cert wg            # додати/згенерувати WireGuard-тунель
  ./main-vpn-manager.sh cert openvpn       # керування .ovpn профілями
  ./main-vpn-manager.sh dns                # перевірити/додати DNS на інтерфейсах
  ./main-vpn-manager.sh dns fix            # DNS зник після VPN — полагодити
  ./main-vpn-manager.sh dns fix 1.1.1.1    # те саме, з явними серверами
  ./main-vpn-manager.sh route              # хто тримає default / чи є перехоплення

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

${B}Примітки:${N}
  • потребує sudo (створення tun-інтерфейсу, wg-quick)
  • WireGuard-конфіги шукаються у: ${WG_DIRS[*]}
  • керування сертифікатами: scripts/wg-cert.sh (WG), scripts/vpn-cert.sh (OpenVPN)
EOF
}

# ─── диспетчер ──────────────────────────────────────────────────────────────

case "${1:-help}" in
    status|st)       cmd_status ;;
    list|ls)         cmd_list ;;
    up|start)        shift; cmd_up "$@" ;;
    down|stop)       shift; cmd_down "$@" ;;
    cert)            shift; cmd_cert "$@" ;;
    dns)             shift; cmd_dns "$@" ;;
    route|rt)        cmd_route ;;
    help|-h|--help)  cmd_help ;;
    *)               die "невідома команда '${1}'. Див. './main-vpn-manager.sh help'" ;;
esac
