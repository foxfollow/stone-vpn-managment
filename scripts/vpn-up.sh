#!/bin/bash
# OpenVPN: підключення.
# Динамічне меню профілів; логін і route-fix — інтерактивні, з пам'яттю останнього вибору.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Опціональний локальний конфіг (дефолти) + стан (останні вибори).
# shellcheck source=/dev/null
[ -f "$REPO_ROOT/config.env" ] && . "$REPO_ROOT/config.env"
STATE_FILE="$REPO_ROOT/state.env"
# shellcheck source=/dev/null
load_state() { [ -f "$STATE_FILE" ] && . "$STATE_FILE" || true; }
set_state() {
    local key="$1" val="$2"
    touch "$STATE_FILE"; chmod 600 "$STATE_FILE" 2>/dev/null || true
    grep -v "^${key}=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    printf '%s=%q\n' "$key" "$val" >> "$STATE_FILE"
}
load_state

PROFILES="${OVPN_PROFILES_DIR:-$HOME/Library/Application Support/OpenVPN Connect/profiles}"
AUTH="$REPO_ROOT/auth.txt"
# PID/лог — окремі на кожен профіль (/tmp/openvpn-<id>.pid|.log), щоб кілька тунелів
# могли працювати одночасно. Задаються після вибору профілю.

# Дефолти (стан → config.env → auth.txt)
DEFAULT_GW="${LAST_GATEWAY:-${LAN_GATEWAY:-}}"
DEFAULT_USER="${LAST_USERNAME:-${OVPN_USERNAME:-}}"
if [ -z "$DEFAULT_USER" ] && [ -f "$AUTH" ]; then
    DEFAULT_USER="$(head -1 "$AUTH")"
fi

# PID запущеного openvpn з цим профілем (за --config у командному рядку), або порожньо.
running_pid_for() {
    local pid
    for pid in $(pgrep -x openvpn 2>/dev/null); do
        if ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "--config $1 "; then
            echo "$pid"; return 0
        fi
    done
    return 0
}

# ─── Динамічне меню профілів ─────────────────────────────────────────────────
if [ ! -d "$PROFILES" ]; then
    echo "Теку профілів не знайдено: $PROFILES"
    echo "Додай профіль: ./main-vpn-manager.sh cert openvpn"
    exit 1
fi

PROFILE_LIST=()
echo ""
echo "Оберіть VPN-профіль:"
i=1
for f in "$PROFILES"/*.ovpn; do
    [ -f "$f" ] || continue
    remote=$(grep -E '^[[:space:]]*remote ' "$f" | head -1 | awk '{print $2":"$3}')
    PROFILE_LIST+=("$f")
    mark=""; [ -n "$(running_pid_for "$f")" ] && mark="  ● запущено"
    printf "  %2d) %-16s %-36s%s\n" "$i" "$(basename "$f" .ovpn)" "$remote" "$mark"
    i=$((i + 1))
done

if [ "${#PROFILE_LIST[@]}" -eq 0 ]; then
    echo "  (профілів немає) — додай: ./main-vpn-manager.sh cert openvpn"
    exit 1
fi

echo ""
read -rp "Номер [1-${#PROFILE_LIST[@]}]: " CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#PROFILE_LIST[@]}" ]; then
    echo "Невірний вибір."
    exit 1
fi
PROFILE="${PROFILE_LIST[$((CHOICE - 1))]}"
PROFILE_ID="$(basename "$PROFILE" .ovpn)"
PIDFILE="/tmp/openvpn-$PROFILE_ID.pid"
LOGFILE="/tmp/openvpn-$PROFILE_ID.log"

RUNNING_PID=$(running_pid_for "$PROFILE")
if [ -n "$RUNNING_PID" ]; then
    echo "Профіль $PROFILE_ID вже запущено (PID $RUNNING_PID)."
    echo "Опустити: ./main-vpn-manager.sh down openvpn"
    exit 1
fi

# ─── Логін (лише якщо профіль його потребує) ─────────────────────────────────
# Профіль потребує user/pass, якщо має голий рядок `auth-user-pass` (без inline-файлу).
AUTH_ARGS=()
TMPAUTH=""
if grep -qE '^[[:space:]]*auth-user-pass[[:space:]]*$' "$PROFILE"; then
    echo ""
    if [ -n "$DEFAULT_USER" ]; then
        read -rp "Логін [Enter=$DEFAULT_USER, або введи інший]: " USER_IN
        USERNAME="${USER_IN:-$DEFAULT_USER}"
    else
        read -rp "Логін: " USERNAME
    fi
    [ -n "$USERNAME" ] || { echo "Логін порожній."; exit 1; }
    set_state LAST_USERNAME "$USERNAME"

    read -rsp "Пароль/OTP для '$USERNAME': " OTP
    echo ""

    TMPAUTH=$(mktemp /tmp/ovpn-auth.XXXXXX)
    chmod 600 "$TMPAUTH"
    printf '%s\n%s\n' "$USERNAME" "$OTP" > "$TMPAUTH"
    AUTH_ARGS=(--auth-user-pass "$TMPAUTH")
    trap 'rm -f "$TMPAUTH"' EXIT
else
    echo "Профіль не потребує логіну (auth-user-pass відсутній) — пропускаю."
fi

# utun-інтерфейс, через який іде найточніший маршрут до IP (longest-prefix), або порожньо.
# Повний тунель (default/def1 через utun) не рахується — route-fix для нього якраз і потрібен.
# Статичні -host маршрути не через utun (залишки route-fix) ігноруються — інакше вони
# маскують тунельний маршрут і VPN-у-VPN ніколи не визначиться.
tunnel_iface_for() {
    netstat -rn -f inet 2>/dev/null | python3 -c '
import sys, ipaddress
ip = ipaddress.ip_address(sys.argv[1])
best = None
for line in sys.stdin:
    p = line.split()
    if len(p) < 4 or not (p[0][0].isdigit() or p[0] == "default"):
        continue
    dest, flags, iface = p[0], p[2], p[3]
    if dest == "default":
        net = ipaddress.ip_network("0.0.0.0/0")
    else:
        addr, _, plen = dest.partition("/")
        octs = addr.split(".")
        try:
            net = ipaddress.ip_network("%s/%s" % (".".join((octs + ["0"] * 4)[:4]),
                                                  plen or 8 * len(octs)), strict=False)
        except ValueError:
            continue
    if ip not in net:
        continue
    if "H" in flags and "S" in flags and not iface.startswith("utun"):
        continue
    if best is None or net.prefixlen > best[0]:
        best = (net.prefixlen, iface)
if best and best[0] > 1 and best[1].startswith("utun"):
    print(best[1])
' "$1" 2>/dev/null
}

# ─── Route-fix (per-connection, з пам'яттю; можна пропустити/змінити) ─────────
# Хости беруться з рядка(ів) `remote` ОБРАНОГО профілю. Сервери, що вже доступні через
# інший тунель (VPN-у-VPN), route-fix не потребують — для них шлюз навіть не питаємо.
echo ""

NEED_IPS=(); NEED_HOSTS=()
for VPN_HOST in $(grep -E '^[[:space:]]*remote ' "$PROFILE" | awk '{print $2}' | sort -u); do
    HOST_IP=$(python3 -c "import socket; print(socket.gethostbyname('$VPN_HOST'))" 2>/dev/null || echo "$VPN_HOST")
    VIA_TUN=$(tunnel_iface_for "$HOST_IP")
    if [ -n "$VIA_TUN" ]; then
        echo "Сервер $VPN_HOST ($HOST_IP) доступний через тунель $VIA_TUN — route-fix не потрібен."
        # Якщо фактичний маршрут іде повз тунель — це статичний -host залишок route-fix; прибрати.
        ROUTE_NOW=$(route -n get "$HOST_IP" 2>/dev/null)
        NOW_IF=$(awk '/interface:/{print $2}' <<< "$ROUTE_NOW")
        if [ "$NOW_IF" != "$VIA_TUN" ] && grep -q 'HOST' <<< "$ROUTE_NOW" && grep -q 'STATIC' <<< "$ROUTE_NOW"; then
            echo "  прибираю старий маршрут повз тунель ($NOW_IF)"
            sudo route -q delete -host "$HOST_IP" >/dev/null 2>&1 || true
        fi
    else
        NEED_IPS+=("$HOST_IP"); NEED_HOSTS+=("$VPN_HOST")
    fi
done

if [ "${#NEED_IPS[@]}" -eq 0 ]; then
    echo "Route-fix пропущено."
else
    # Кандидати: LAN default-шлюзи + шлюзи активних тунелів (для сервера, який сидить за
    # тунелем, але тунель не роздає до нього маршрут) + останній використаний.
    GW_IFACES=(); GW_ADDRS=(); GW_TAGS=()
    while IFS=' ' read -r _iface _gw; do
        GW_IFACES+=("$_iface"); GW_ADDRS+=("$_gw"); GW_TAGS+=("")
    done < <(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $2~/^[0-9]+\./ && $4!~/^utun/{print $4, $2}')
    while IFS=' ' read -r _iface _gw; do
        [ -n "$_iface" ] || continue
        # Маршрут на власну адресу тунелю (10.x.y/24 → 10.x.y.2) — не шлюз.
        ifconfig "$_iface" 2>/dev/null | awk '/inet /{print $2}' | grep -qxF "$_gw" && continue
        GW_IFACES+=("$_iface"); GW_ADDRS+=("$_gw"); GW_TAGS+=("(тунель)")
    done < <(netstat -rn -f inet 2>/dev/null | awk '$4~/^utun/ && $2~/^[0-9]+\./ && $3~/G/{print $4, $2}' | sort -u)

    echo "Route-fix для: ${NEED_HOSTS[*]} (${NEED_IPS[*]})"
    echo "Шлюз:"
    n=1
    for _idx in "${!GW_ADDRS[@]}"; do
        printf "  %d) %-7s %-15s %s\n" "$n" "${GW_IFACES[$_idx]}" "${GW_ADDRS[$_idx]}" "${GW_TAGS[$_idx]}"
        n=$((n+1))
    done
    LAST_ENTRY=0
    if [ -n "$DEFAULT_GW" ]; then
        printf "  %d) %-7s %s\n" "$n" "-" "$DEFAULT_GW (останній)"
        LAST_ENTRY=$n
        n=$((n+1))
    fi
    TOTAL_GW=$((n-1))
    [ "${#GW_TAGS[@]}" -gt 0 ] && [[ " ${GW_TAGS[*]} " == *"(тунель)"* ]] && \
        echo "  Сервер за іншим VPN, але маршруту до нього немає? Обери шлюз тунелю."

    echo ""
    if [ "$TOTAL_GW" -gt 0 ]; then
        if [ -n "$DEFAULT_GW" ]; then
            read -rp "Вибір [Enter=$DEFAULT_GW / 1-${TOTAL_GW} / IP / '-' пропустити]: " GW_IN
        else
            read -rp "Вибір [1-${TOTAL_GW} / IP / Enter=пропустити]: " GW_IN
        fi
    else
        if [ -n "$DEFAULT_GW" ]; then
            read -rp "Route-fix шлюз [Enter=$DEFAULT_GW / IP / '-' пропустити]: " GW_IN
        else
            read -rp "Route-fix шлюз [IP / Enter=пропустити]: " GW_IN
        fi
    fi

    GATEWAY=""
    case "$GW_IN" in
        "")
            GATEWAY="${DEFAULT_GW:-}"
            ;;
        "-"|n|N|skip)
            GATEWAY=""
            ;;
        *)
            if [[ "$GW_IN" =~ ^[0-9]+$ ]] && [ "$GW_IN" -ge 1 ] && [ "$GW_IN" -le "$TOTAL_GW" ]; then
                if [ "$LAST_ENTRY" -gt 0 ] && [ "$GW_IN" -eq "$LAST_ENTRY" ]; then
                    GATEWAY="${DEFAULT_GW:-}"
                else
                    GATEWAY="${GW_ADDRS[$((GW_IN-1))]}"
                fi
            else
                GATEWAY="$GW_IN"
            fi
            ;;
    esac

    if [ -n "$GATEWAY" ]; then
        set_state LAST_GATEWAY "$GATEWAY"
        for HOST_IP in "${NEED_IPS[@]}"; do
            CURRENT_GW=$(route -n get "$HOST_IP" 2>/dev/null | awk '/gateway:/{print $2}')
            if [ "$CURRENT_GW" != "$GATEWAY" ]; then
                sudo route -q delete -host "$HOST_IP" >/dev/null 2>&1 || true
                sudo route -q add -host "$HOST_IP" "$GATEWAY" >/dev/null 2>&1 || true
            fi
        done
        echo "Route-fix застосовано через $GATEWAY"
    else
        echo "Route-fix пропущено."
    fi
fi

echo "Підключення..."

# Профіль GUI часто не має рядка `dev` — GUI додає його сам, а CLI вимагає явно.
# Додаємо --dev tun (на macOS виділяє utun), лише якщо профіль його не задає.
DEV_ARGS=()
if ! grep -qE '^[[:space:]]*dev[[:space:]]' "$PROFILE"; then
    DEV_ARGS=(--dev tun)
fi

# Capture stdout+stderr so pre-daemon noise doesn't clutter the terminal.
# set -e is temporarily disabled to get the real exit code without silent death.
# Залишки попереднього запуску цього ж профілю дали б хибний успіх/падіння в циклі нижче.
sudo rm -f "$PIDFILE" "$LOGFILE"
set +e
LAUNCH_OUT=$(sudo /opt/homebrew/sbin/openvpn \
    --config "$PROFILE" \
    "${DEV_ARGS[@]}" \
    "${AUTH_ARGS[@]}" \
    --daemon \
    --writepid "$PIDFILE" \
    --log "$LOGFILE" \
    --script-security 2 \
    --connect-retry-max 1 2>&1)
LAUNCH_RC=$?
set -e
if [ "$LAUNCH_RC" -ne 0 ]; then
    echo "OpenVPN не вдалося запустити (код $LAUNCH_RC):"
    [ -n "$LAUNCH_OUT" ] && echo "$LAUNCH_OUT"
    sudo cat "$LOGFILE" 2>/dev/null || true
    exit 1
fi
# Лог читабельний для свого користувача (staff) — щоб `status` бачив стан тунелю без sudo.
# Секретів у ньому немає (пароль/OTP openvpn не логує).
sudo chgrp staff "$LOGFILE" 2>/dev/null && sudo chmod 640 "$LOGFILE" 2>/dev/null || true

FAIL_PAT="AUTH_FAILED|auth-failure|fatal error|TLS Error|TLS handshake failed|Exiting due to fatal|SIGTERM received|Connection refused|Network unreachable"

# Чекаємо поки підніметься тунель (до 45 секунд), потім видаляємо tmpauth
echo -n "Очікування тунелю"
for i in $(seq 1 45); do
    sleep 1
    echo -n "."

    if sudo grep -q "Initialization Sequence Completed" "$LOGFILE" 2>/dev/null; then
        echo ""
        echo "Підключено!"
        [ -n "$TMPAUTH" ] && rm -f "$TMPAUTH"
        # Інтерфейс саме цього екземпляра — з його логу (інших тунелів може бути кілька).
        IFACE=$(sudo grep -oE 'Opened utun device utun[0-9]+' "$LOGFILE" 2>/dev/null | tail -1 | awk '{print $NF}')
        [ -n "$IFACE" ] || IFACE=$(sudo grep -oE '/sbin/ifconfig utun[0-9]+' "$LOGFILE" 2>/dev/null | tail -1 | awk '{print $NF}')
        echo "Інтерфейс: $IFACE"
        [ -n "$IFACE" ] && { netstat -rn -f inet | grep -w "$IFACE" | grep -v fe80 || true; }
        exit 0
    fi

    if sudo grep -qE "$FAIL_PAT" "$LOGFILE" 2>/dev/null; then
        echo ""
        echo "Помилка підключення:"
        sudo grep -E "$FAIL_PAT|ERROR" "$LOGFILE" | tail -5
        exit 1
    fi

    # Якщо процес вже завершився — немає сенсу чекати далі
    OPID=$(sudo cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$OPID" ] && ! sudo kill -0 "$OPID" 2>/dev/null; then
        echo ""
        echo "OpenVPN завершився несподівано. Лог:"
        sudo tail -10 "$LOGFILE"
        exit 1
    fi
done

echo ""
echo "Тунель не піднявся за 45 секунд. Останні рядки логу:"
sudo tail -10 "$LOGFILE"
echo "(повний лог: sudo tail -50 $LOGFILE)"
