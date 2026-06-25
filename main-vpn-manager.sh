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
#   ./main-vpn-manager.sh help              ця довідка
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"

# Стандартні шляхи WireGuard (wg-quick шукає конфіги саме тут). НЕ міняти.
WG_DIRS=(/opt/homebrew/etc/wireguard /usr/local/etc/wireguard /etc/wireguard)
WG_RUN="/var/run/wireguard"        # тут wg-quick тримає <iface>.name (назва тунелю)
OVPN_PID="/tmp/openvpn.pid"

# ─── кольори (вимикаються коли вивід не в термінал) ──────────────────────────
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=''; G=''; R=''; D=''; N=''
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

# ─── команди ────────────────────────────────────────────────────────────────

cmd_status() {
    echo "${B}=== Статус VPN ===${N}"
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
    utuns=$(ifconfig 2>/dev/null | awk '/^utun[0-9]/{i=$1; sub(/:$/,"",i)} i && /inet [0-9]/{print i": "$2; i=""}')
    if [ -n "$utuns" ]; then
        echo "$utuns" | sed 's/^/  /'
    else
        echo "  ${D}немає${N}"
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
        echo "${G}Готово.${N}"
        return
    fi

    if [ "$tunnel" = "openvpn" ]; then
        exec "$SCRIPTS/vpn-down.sh"
    fi

    echo "Опускаю WireGuard '$tunnel'..."
    sudo wg-quick down "$(wg_target "$tunnel")"
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
  ${G}help${N}              ця довідка

${B}Приклади:${N}
  ./main-vpn-manager.sh status
  ./main-vpn-manager.sh up wire-first      # WireGuard-тунель
  ./main-vpn-manager.sh up openvpn         # інтерактивний вибір .ovpn профілю
  ./main-vpn-manager.sh down wire-first
  ./main-vpn-manager.sh down               # опустити все
  ./main-vpn-manager.sh cert wg            # додати/згенерувати WireGuard-тунель
  ./main-vpn-manager.sh cert openvpn       # керування .ovpn профілями

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
    help|-h|--help)  cmd_help ;;
    *)               die "невідома команда '${1}'. Див. './main-vpn-manager.sh help'" ;;
esac
