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
PIDFILE="/tmp/openvpn.pid"
LOGFILE="/tmp/openvpn.log"

# Дефолти (стан → config.env → auth.txt)
DEFAULT_GW="${LAST_GATEWAY:-${LAN_GATEWAY:-}}"
DEFAULT_USER="${LAST_USERNAME:-${OVPN_USERNAME:-}}"
if [ -z "$DEFAULT_USER" ] && [ -f "$AUTH" ]; then
    DEFAULT_USER="$(head -1 "$AUTH")"
fi

# Перевірка що вже не запущено
if sudo test -f "$PIDFILE" 2>/dev/null && sudo kill -0 "$(sudo cat "$PIDFILE")" 2>/dev/null; then
    echo "VPN вже запущено (PID $(sudo cat "$PIDFILE")). Спочатку виконай ./main-vpn-manager.sh down openvpn"
    exit 1
fi

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
    printf "  %d) %-30s %s\n" "$i" "$(basename "$f" .ovpn)" "$remote"
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

# ─── Route-fix (per-connection, з пам'яттю; можна пропустити/змінити) ─────────
# Хости беруться з рядка(ів) `remote` ОБРАНОГО профілю. Шлюз — інтерактивно.
echo ""

# Detect active IPv4 default gateways from the routing table
GW_IFACES=()
GW_ADDRS=()
while IFS=' ' read -r _iface _gw; do
    GW_IFACES+=("$_iface")
    GW_ADDRS+=("$_gw")
done < <(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $2~/^[0-9]+\./{print $4, $2}')

echo "Route-fix шлюз:"
n=1
for _idx in "${!GW_ADDRS[@]}"; do
    printf "  %d) %-12s %s\n" "$n" "${GW_IFACES[$_idx]}" "${GW_ADDRS[$_idx]}"
    n=$((n+1))
done
LAST_ENTRY=0
if [ -n "$DEFAULT_GW" ]; then
    printf "  %d) (останній)   %s\n" "$n" "$DEFAULT_GW"
    LAST_ENTRY=$n
    n=$((n+1))
fi
TOTAL_GW=$((n-1))

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
    REMOTE_HOSTS=$(grep -E '^[[:space:]]*remote ' "$PROFILE" | awk '{print $2}' | sort -u)
    for VPN_HOST in $REMOTE_HOSTS; do
        HOST_IP=$(python3 -c "import socket; print(socket.gethostbyname('$VPN_HOST'))" 2>/dev/null || echo "$VPN_HOST")
        CURRENT_GW=$(route -n get "$HOST_IP" 2>/dev/null | awk '/gateway:/{print $2}')
        if [ "$CURRENT_GW" != "$GATEWAY" ]; then
            sudo route -q delete -host "$HOST_IP" 2>/dev/null || true
            sudo route -q add -host "$HOST_IP" "$GATEWAY" 2>/dev/null || true
        fi
    done
    echo "Route-fix застосовано через $GATEWAY"
else
    echo "Route-fix пропущено."
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
        IFACE=$(ifconfig 2>/dev/null | awk '/^utun[0-9]/{cur=$1; sub(/:$/,"",cur)} cur && /inet [0-9]/{print cur; exit}')
        echo "Інтерфейс: $IFACE"
        netstat -rn -f inet | grep "$IFACE" | grep -v fe80 || true
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
