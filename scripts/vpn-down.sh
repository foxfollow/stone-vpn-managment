#!/bin/bash
# OpenVPN: відключення. Підтримує кілька одночасних тунелів.
# Використання:
#   vpn-down.sh            — один запущений → опустити; кілька → меню
#   vpn-down.sh all        — опустити всі
#   vpn-down.sh <id|PID>   — опустити конкретний (id = ім'я профілю без .ovpn)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$REPO_ROOT/config.env" ] && . "$REPO_ROOT/config.env"
PROFILES="${OVPN_PROFILES_DIR:-$HOME/Library/Application Support/OpenVPN Connect/profiles}"

# Запущені openvpn: "PID<TAB>id" (id беремо з --config у командному рядку процесу).
ovpn_instances() {
    local pid cfg
    for pid in $(pgrep -x openvpn 2>/dev/null); do
        cfg=$(ps -p "$pid" -o command= 2>/dev/null | sed -n 's/.*--config \(.*\.ovpn\).*/\1/p')
        printf '%s\t%s\n' "$pid" "$(basename "${cfg:-?}" .ovpn)"
    done
}

ovpn_remote() {
    grep -E '^[[:space:]]*remote ' "$PROFILES/$1.ovpn" 2>/dev/null | head -1 | awk '{print $2":"$3}'
}

stop_one() {
    local pid="$1" id="$2" f
    echo "Відключення OpenVPN $id (PID $pid)..."
    sudo kill "$pid" 2>/dev/null
    for _ in $(seq 1 10); do
        sleep 1
        ps -p "$pid" >/dev/null 2>&1 || break
    done
    if ps -p "$pid" >/dev/null 2>&1; then
        echo "  не завершився за 10с — kill -9"
        sudo kill -9 "$pid" 2>/dev/null
    fi
    # Прибрати PID/лог саме цього екземпляра (і legacy /tmp/openvpn.pid, якщо він його).
    for f in /tmp/openvpn.pid /tmp/openvpn-*.pid; do
        [ -f "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" = "$pid" ]; then
            sudo rm -f "$f" "${f%.pid}.log"
        fi
    done
    echo "  відключено."
}

PIDS=(); IDS=()
while IFS=$'\t' read -r _pid _id; do
    [ -n "$_pid" ] || continue
    PIDS+=("$_pid"); IDS+=("$_id")
done < <(ovpn_instances)

if [ "${#PIDS[@]}" -eq 0 ]; then
    echo "OpenVPN не запущено."
    # Прибрати осиротілі PID-файли.
    sudo rm -f /tmp/openvpn.pid /tmp/openvpn-*.pid 2>/dev/null
    exit 0
fi

ARG="${1:-}"
TARGETS=()
if [ "$ARG" = all ]; then
    TARGETS=("${!PIDS[@]}")
elif [ -n "$ARG" ]; then
    for i in "${!PIDS[@]}"; do
        [ "${PIDS[$i]}" = "$ARG" ] || [ "${IDS[$i]}" = "$ARG" ] && TARGETS+=("$i")
    done
    [ "${#TARGETS[@]}" -gt 0 ] || { echo "Запущеного OpenVPN '$ARG' не знайдено."; exit 1; }
elif [ "${#PIDS[@]}" -eq 1 ]; then
    TARGETS=(0)
else
    echo "Запущені OpenVPN-тунелі:"
    for i in "${!PIDS[@]}"; do
        printf "  %2d) %-15s %-32s (PID %s)\n" "$((i + 1))" "${IDS[$i]}" "$(ovpn_remote "${IDS[$i]}")" "${PIDS[$i]}"
    done
    read -rp "Номери через кому / all / Enter=скасувати: " PICK
    case "$PICK" in
        "")       echo "Скасовано."; exit 0 ;;
        all|ALL)  TARGETS=("${!PIDS[@]}") ;;
        *)
            IFS=',' read -ra _idxs <<< "$PICK"
            for idx in "${_idxs[@]}"; do
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#PIDS[@]}" ]; then
                    TARGETS+=("$((idx - 1))")
                else
                    echo "Пропускаю невірний номер: $idx"
                fi
            done
            ;;
    esac
fi

for i in "${TARGETS[@]}"; do
    stop_one "${PIDS[$i]}" "${IDS[$i]}"
done
