#!/bin/bash
# Керування профілями/сертифікатами OpenVPN
# Використання:
#   ./vpn-cert.sh                        — інтерактивне меню
#   ./vpn-cert.sh /path/to/new.ovpn      — додати/замінити профіль
#   ./vpn-cert.sh --delete               — видалити профіль (меню)

PROFILES="$HOME/Library/Application Support/OpenVPN Connect/profiles"

# ─── Допоміжні функції ──────────────────────────────────────────────────────

list_profiles() {
    echo ""
    echo "Існуючі профілі:"
    local i=1
    for f in "$PROFILES"/*.ovpn; do
        [ -f "$f" ] || continue
        local remote
        remote=$(grep "^remote " "$f" | awk '{print $2":"$3}')
        printf "  %d) %-45s %s\n" "$i" "$(basename "$f")" "$remote"
        i=$((i + 1))
    done
    echo ""
}

pick_profile() {
    list_profiles
    read -rp "Номер профілю: " NUM
    local i=1
    for f in "$PROFILES"/*.ovpn; do
        [ -f "$f" ] || continue
        if [ "$i" -eq "$NUM" ]; then
            echo "$f"
            return 0
        fi
        i=$((i + 1))
    done
    echo ""
    return 1
}

# ─── Додати / замінити профіль ──────────────────────────────────────────────

import_profile() {
    local src="$1"

    if [ ! -f "$src" ]; then
        echo "Файл не знайдено: $src"
        exit 1
    fi

    if [[ "$src" != *.ovpn ]]; then
        echo "Очікується .ovpn файл."
        exit 1
    fi

    # Перевіримо чи вже є профіль з таким же remote
    local new_remote
    new_remote=$(grep "^remote " "$src" | awk '{print $2":"$3}')

    local existing=""
    for f in "$PROFILES"/*.ovpn; do
        [ -f "$f" ] || continue
        local r
        r=$(grep "^remote " "$f" | awk '{print $2":"$3}')
        if [ "$r" = "$new_remote" ]; then
            existing="$f"
            break
        fi
    done

    if [ -n "$existing" ]; then
        echo "Вже є профіль з remote $new_remote:"
        echo "  $(basename "$existing")"
        read -rp "Замінити існуючий? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            cp "$src" "$existing"
            echo "Замінено: $(basename "$existing")"
            return
        fi
        read -rp "Додати як новий окремий профіль? [y/N]: " ADD_NEW
        [[ "$ADD_NEW" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }
    fi

    # Генеруємо числове ім'я як у OpenVPN Connect
    local ts
    ts=$(date +%s%3N)
    local dest="$PROFILES/${ts}.ovpn"
    cp "$src" "$dest"
    echo "Додано: $(basename "$dest")"
    echo "Remote: $new_remote"
}

# ─── Видалити профіль ───────────────────────────────────────────────────────

delete_profile() {
    local target
    target=$(pick_profile)

    if [ -z "$target" ]; then
        echo "Невірний вибір."
        exit 1
    fi

    local remote
    remote=$(grep "^remote " "$target" | awk '{print $2":"$3}')
    echo ""
    echo "Видалити профіль?"
    echo "  Файл:   $(basename "$target")"
    echo "  Remote: $remote"
    read -rp "[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Скасовано."; exit 0; }

    rm -f "$target"
    echo "Видалено."
}

# ─── Замінити сертифікат у існуючому профілі ────────────────────────────────

replace_cert() {
    echo "Оберіть профіль для заміни сертифіката:"
    local target
    target=$(pick_profile)

    if [ -z "$target" ]; then
        echo "Невірний вибір."
        exit 1
    fi

    echo ""
    echo "Що замінити?"
    echo "  1) <cert> (клієнтський сертифікат)"
    echo "  2) <key>  (приватний ключ)"
    echo "  3) <ca>   (CA сертифікат)"
    echo "  4) Весь профіль (.ovpn файл)"
    echo ""
    read -rp "Номер [1-4]: " BLOCK_CHOICE

    case "$BLOCK_CHOICE" in
        1) TAG="cert" ;;
        2) TAG="key" ;;
        3) TAG="ca" ;;
        4)
            read -rp "Шлях до нового .ovpn: " NEW_PATH
            import_profile "$NEW_PATH"
            return
            ;;
        *) echo "Невірний вибір."; exit 1 ;;
    esac

    read -rp "Шлях до PEM файлу (.pem/.crt/.key): " PEM_PATH
    if [ ! -f "$PEM_PATH" ]; then
        echo "Файл не знайдено: $PEM_PATH"
        exit 1
    fi

    local PEM_CONTENT
    PEM_CONTENT=$(cat "$PEM_PATH")

    # Замінюємо блок <TAG>...</TAG> у профілі
    local BACKUP="${target}.bak"
    cp "$target" "$BACKUP"

    python3 - "$target" "$TAG" <<EOF
import sys, re

path = sys.argv[1]
tag  = sys.argv[2]
new_content = """$PEM_CONTENT"""

with open(path, 'r') as f:
    data = f.read()

pattern = rf'<{tag}>.*?</{tag}>'
replacement = f'<{tag}>\n{new_content.strip()}\n</{tag}>'
updated = re.sub(pattern, replacement, data, flags=re.DOTALL)

with open(path, 'w') as f:
    f.write(updated)

print(f"Блок <{tag}> оновлено.")
EOF

    echo "Резервна копія: $(basename "$BACKUP")"
}

# ─── Головне меню ───────────────────────────────────────────────────────────

if [ -n "$1" ]; then
    if [ "$1" = "--delete" ]; then
        delete_profile
    elif [ -f "$1" ]; then
        import_profile "$1"
    else
        echo "Файл не знайдено: $1"
        exit 1
    fi
    exit 0
fi

echo ""
echo "Керування профілями VPN:"
echo "  1) Показати всі профілі"
echo "  2) Додати новий профіль (.ovpn)"
echo "  3) Замінити сертифікат у профілі"
echo "  4) Видалити профіль"
echo ""
read -rp "Дія [1-4]: " ACTION

case "$ACTION" in
    1) list_profiles ;;
    2)
        read -rp "Шлях до .ovpn файлу: " PATH_INPUT
        import_profile "$PATH_INPUT"
        ;;
    3) replace_cert ;;
    4) delete_profile ;;
    *) echo "Невірний вибір." ;;
esac
