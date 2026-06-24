#!/bin/bash
# Керування WireGuard-тунелями/ключами.
# Використання:
#   ./wg-cert.sh                    — інтерактивне меню
#   ./wg-cert.sh /path/to/x.conf    — імпортувати готовий .conf
#   ./wg-cert.sh --generate         — згенерувати новий тунель (ключі + шаблон)
#   ./wg-cert.sh --list             — показати тунелі
#   ./wg-cert.sh --delete           — видалити тунель
#
# Конфіги пишуться у системну теку WireGuard (потрібен sudo). НЕ змінювати ці шляхи —
# wg-quick шукає саме тут.

WG_DIRS=(/etc/wireguard /usr/local/etc/wireguard /opt/homebrew/etc/wireguard)

valid_name() { [[ "$1" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]]; }

# Тека для нових конфігів: перша з наявними .conf, інакше перша наявна, інакше /etc/wireguard.
wg_target_dir() {
    local d
    for d in "${WG_DIRS[@]}"; do
        if sudo test -d "$d" 2>/dev/null && [ -n "$(sudo sh -c 'ls "$1"/*.conf 2>/dev/null' _ "$d")" ]; then
            echo "$d"; return
        fi
    done
    for d in "${WG_DIRS[@]}"; do
        sudo test -d "$d" 2>/dev/null && { echo "$d"; return; }
    done
    echo "/etc/wireguard"
}

# ─── Список ──────────────────────────────────────────────────────────────────
wg_list() {
    echo ""
    echo "WireGuard-тунелі:"
    local found=0 d f name endpoint
    for d in "${WG_DIRS[@]}"; do
        sudo test -d "$d" 2>/dev/null || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            name=$(basename "$f" .conf)
            endpoint=$(sudo grep -E '^[[:space:]]*Endpoint' "$f" 2>/dev/null | head -1 | awk -F'= *' '{print $2}')
            printf "  %-18s %-24s %s\n" "$name" "${endpoint:-—}" "$d"
            found=1
        done < <(sudo sh -c 'ls "$1"/*.conf 2>/dev/null' _ "$d")
    done
    [ "$found" -eq 1 ] || echo "  (немає)"
    echo ""
}

# ─── Генерація нового тунелю ─────────────────────────────────────────────────
wg_generate() {
    command -v wg >/dev/null 2>&1 || { echo "wg не встановлено (brew install wireguard-tools)."; exit 1; }

    local dir; dir=$(wg_target_dir)
    read -rp "Назва тунелю (напр. home-wg): " NAME
    valid_name "$NAME" || { echo "Невірна назва (1-15: a-z A-Z 0-9 _=+.-)."; exit 1; }
    local dest="$dir/$NAME.conf"
    if sudo test -e "$dest"; then
        read -rp "Тунель '$NAME' вже існує. Перезаписати? [y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }
    fi

    read -rp "Address клієнта (напр. 10.0.0.2/32): " ADDRESS
    read -rp "DNS (опц., Enter — пропустити): " DNS
    read -rp "[Peer] PublicKey сервера: " PEER_PUB
    read -rp "[Peer] Endpoint (host:port): " ENDPOINT
    read -rp "AllowedIPs [0.0.0.0/0, ::/0]: " ALLOWED
    ALLOWED="${ALLOWED:-0.0.0.0/0, ::/0}"
    read -rp "Згенерувати PresharedKey? [y/N]: " USE_PSK

    local PRIV PUB PSK_LINE=""
    PRIV=$(wg genkey)
    PUB=$(printf '%s' "$PRIV" | wg pubkey)
    if [[ "$USE_PSK" =~ ^[Yy]$ ]]; then
        PSK_LINE="PresharedKey = $(wg genpsk)"
    fi

    local tmp; tmp=$(mktemp); chmod 600 "$tmp"
    {
        echo "[Interface]"
        echo "PrivateKey = $PRIV"
        echo "Address = $ADDRESS"
        [ -n "$DNS" ] && echo "DNS = $DNS"
        echo ""
        echo "[Peer]"
        echo "PublicKey = $PEER_PUB"
        [ -n "$PSK_LINE" ] && echo "$PSK_LINE"
        echo "Endpoint = $ENDPOINT"
        echo "AllowedIPs = $ALLOWED"
    } > "$tmp"

    sudo mkdir -p "$dir"
    sudo cp "$tmp" "$dest"
    sudo chmod 600 "$dest"
    rm -f "$tmp"

    echo ""
    echo "Створено: $dest"
    echo "Твій публічний ключ (передай адміну сервера як PublicKey цього клієнта):"
    echo "  $PUB"
    echo ""
    echo "Підняти: ./main-vpn-manager.sh up $NAME"
}

# ─── Імпорт готового .conf ───────────────────────────────────────────────────
wg_import() {
    local src="$1"
    [ -f "$src" ] || { echo "Файл не знайдено: $src"; exit 1; }
    [[ "$src" == *.conf ]] || { echo "Очікується .conf файл."; exit 1; }
    grep -qE '^\[Interface\]' "$src" || { echo "Не схоже на WireGuard-конфіг (немає [Interface])."; exit 1; }

    local name; name=$(basename "$src" .conf)
    valid_name "$name" || { echo "Невірне ім'я файлу '$name' (треба 1-15: a-z A-Z 0-9 _=+.-). Перейменуй .conf."; exit 1; }

    local dir; dir=$(wg_target_dir)
    local dest="$dir/$name.conf"
    if sudo test -e "$dest"; then
        read -rp "Тунель '$name' вже існує. Перезаписати? [y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }
    fi

    sudo mkdir -p "$dir"
    sudo cp "$src" "$dest"
    sudo chmod 600 "$dest"
    echo "Імпортовано: $dest"
    echo "Підняти: ./main-vpn-manager.sh up $name"
}

# ─── Видалення ───────────────────────────────────────────────────────────────
wg_delete() {
    wg_list
    read -rp "Назва тунелю для видалення: " NAME
    [ -n "$NAME" ] || { echo "Скасовано."; exit 0; }
    local d dest=""
    for d in "${WG_DIRS[@]}"; do
        if sudo test -f "$d/$NAME.conf" 2>/dev/null; then dest="$d/$NAME.conf"; break; fi
    done
    [ -n "$dest" ] || { echo "Тунель '$NAME' не знайдено."; exit 1; }
    read -rp "Видалити $dest ? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }
    sudo rm -f "$dest"
    echo "Видалено: $dest"
}

# ─── Диспетчер ───────────────────────────────────────────────────────────────
case "${1:-}" in
    "")                 : ;;  # меню нижче
    --list)             wg_list; exit 0 ;;
    --generate|--new)   wg_generate; exit 0 ;;
    --delete)           wg_delete; exit 0 ;;
    *)
        if [ -f "$1" ]; then wg_import "$1"; exit 0
        else echo "Файл не знайдено: $1"; exit 1; fi ;;
esac

echo ""
echo "Керування WireGuard-тунелями:"
echo "  1) Показати тунелі"
echo "  2) Згенерувати новий (ключі + шаблон .conf)"
echo "  3) Імпортувати готовий .conf"
echo "  4) Видалити тунель"
echo ""
read -rp "Дія [1-4]: " ACTION
case "$ACTION" in
    1) wg_list ;;
    2) wg_generate ;;
    3) read -rp "Шлях до .conf: " P; wg_import "$P" ;;
    4) wg_delete ;;
    *) echo "Невірний вибір." ;;
esac
