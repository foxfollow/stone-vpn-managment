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
if [ -n "$DEFAULT_GW" ]; then
    read -rp "Route-fix шлюз [Enter=$DEFAULT_GW, '-' пропустити, або інший IP]: " GW_IN
else
    read -rp "Route-fix шлюз [Enter=пропустити, або введи IP]: " GW_IN
fi
case "$GW_IN" in
    "")            GATEWAY="$DEFAULT_GW" ;;
    "-"|n|N|skip)  GATEWAY="" ;;
    *)             GATEWAY="$GW_IN" ;;
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

sudo /opt/homebrew/sbin/openvpn \
    --config "$PROFILE" \
    "${AUTH_ARGS[@]}" \
    --daemon \
    --writepid "$PIDFILE" \
    --log "$LOGFILE" \
    --script-security 2 \
    --connect-retry-max 1

# Чекаємо поки підніметься тунель, потім видаляємо tmpauth
echo -n "Очікування тунелю"
for i in $(seq 1 20); do
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
    if sudo grep -q "AUTH_FAILED\|auth-failure\|fatal error" "$LOGFILE" 2>/dev/null; then
        echo ""
        echo "Помилка підключення:"
        sudo grep -E "AUTH_FAILED|auth-failure|fatal error|ERROR" "$LOGFILE" | tail -3
        exit 1
    fi
done

echo ""
echo "Тунель не піднявся за 20 секунд. Перевір лог:"
echo "  sudo tail -30 $LOGFILE"
