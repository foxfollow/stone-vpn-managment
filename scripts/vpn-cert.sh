#!/bin/bash
# Керування профілями/сертифікатами OpenVPN
# Використання:
#   ./vpn-cert.sh                        — інтерактивне меню
#   ./vpn-cert.sh /path/to/new.ovpn      — додати/замінити профіль
#   ./vpn-cert.sh --delete               — видалити профіль (меню)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
# shellcheck disable=SC1091
[ -f "$REPO_ROOT/config.env" ] && . "$REPO_ROOT/config.env"
# Та сама тека, що й у vpn-up.sh та застосунку.
PROFILES="${OVPN_PROFILES_DIR:-$HOME/Library/Application Support/OpenVPN Connect/profiles}"

# ─── Допоміжні функції ──────────────────────────────────────────────────────

# Шлях, введений руками/перетягнутий у Terminal: прибрати пробіли по краях, обгорткові
# лапки ('...' / "...") або екранування (\ , \( ), розгорнути ~.
clean_path() {
    local p="$1"
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    if [[ ${#p} -ge 2 && ( "$p" == \'*\' || "$p" == \"*\" ) ]]; then
        p="${p:1:${#p}-2}"
    else
        p=$(printf '%s' "$p" | sed 's/\\\(.\)/\1/g')
    fi
    [[ "$p" == "~" || "$p" == "~/"* ]] && p="$HOME${p:1}"
    printf '%s' "$p"
}

# Людські назви з config.json OpenVPN Connect (файли названі ms-мітками): рядки "id<TAB>назва".
# Та сама логіка, що Parse.ovpnConnectTitles у застосунку.
profile_titles() {
    python3 - "$PROFILES/../config.json" 2>/dev/null <<'PY'
import json, re, sys
def obj(v):
    if isinstance(v, dict): return v
    try: return json.loads(v)
    except Exception: return None
try:
    root = obj(json.load(open(sys.argv[1])))
    profiles = obj(obj(obj(root["persist:root"])["status"])["profiles"])
except Exception:
    sys.exit()
for pid, p in profiles.items():
    if not isinstance(p, dict): continue
    raw = next((p[k] for k in ("profileDisplayName", "name", "profileName") if isinstance(p.get(k), str) and p[k]), None)
    if not raw: continue
    m = re.search(r"\[(.+)\]\s*$", raw)
    t = re.sub(r"\.ovpn$", "", m.group(1) if m else raw)
    print(f"{pid}\t{t}")
PY
}

TITLES=""
title_of() {
    [ -n "$TITLES" ] || TITLES=$(profile_titles; echo .)
    printf '%s\n' "$TITLES" | awk -F'\t' -v id="$(basename "$1" .ovpn)" '$1 == id { print $2; exit }'
}

# Меню — у stderr: pick_profile викликають через $(...), stdout має містити лише шлях.
# (Раніше меню потрапляло в змінну разом зі шляхом → видалення/заміна ламалися.)
list_profiles() {
    {
    echo ""
    echo "Існуючі профілі:"
    local i=1
    for f in "$PROFILES"/*.ovpn; do
        [ -f "$f" ] || continue
        local remote
        remote=$(grep -m1 "^remote " "$f" | awk '{print $2":"$3}')
        printf "  %2d) %-20s %-32s %s\n" "$i" "$(basename "$f")" "$(title_of "$f")" "$remote"
        i=$((i + 1))
    done
    echo ""
    } >&2
}

pick_profile() {
    list_profiles
    read -rp "Номер профілю: " NUM
    [[ "$NUM" =~ ^[0-9]+$ ]] || return 1
    local i=1
    for f in "$PROFILES"/*.ovpn; do
        [ -f "$f" ] || continue
        if [ "$i" -eq "$NUM" ]; then
            echo "$f"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# ─── Додати / замінити профіль ──────────────────────────────────────────────

import_profile() {
    local src
    src=$(clean_path "$1")

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

    # Один remote часто мають кілька профілів (різні логіни/сертифікати на тому ж сервері).
    # Раніше мовчки замінювався *перший* з них — не той, що мав на увазі користувач.
    local matches=() f r
    for f in "$PROFILES"/*.ovpn; do
        [ -f "$f" ] || continue
        r=$(grep -m1 "^remote " "$f" | awk '{print $2":"$3}')
        [ -n "$new_remote" ] && [ "$r" = "$new_remote" ] && matches+=("$f")
    done

    if [ ${#matches[@]} -gt 0 ]; then
        echo "Вже є профілі з remote $new_remote:"
        local i=1 m
        for m in "${matches[@]}"; do
            printf "  %d) %-20s %s\n" "$i" "$(basename "$m")" "$(title_of "$m")"
            i=$((i + 1))
        done
        echo "  n) додати як новий окремий профіль"
        read -rp "Замінити який? [номер / n, Enter = скасувати]: " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#matches[@]} ]; then
            local existing="${matches[$((CHOICE - 1))]}"
            cp "$existing" "${existing}.bak"
            cp "$src" "$existing"
            echo "Замінено: $(basename "$existing") $(title_of "$existing") (стара версія: $(basename "$existing").bak)"
            return
        fi
        [[ "$CHOICE" =~ ^[Nn]$ ]] || { echo "Скасовано."; exit 0; }
    fi

    # Генеруємо числове ім'я як у OpenVPN Connect
    local ts
    # BSD date не знає %N — мілісекунди через python3 (вже потрібен для replace_cert)
    ts=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo "$(date +%s)000")
    local dest="$PROFILES/${ts}.ovpn"
    cp "$src" "$dest"
    echo "Додано: $(basename "$dest")"
    echo "Remote: $new_remote"
}

# ─── Видалити профіль ───────────────────────────────────────────────────────

delete_profile() {
    local target
    target=$(pick_profile)

    if [ -z "$target" ] || [ ! -f "$target" ]; then
        echo "Невірний вибір."
        exit 1
    fi

    local remote
    remote=$(grep -m1 "^remote " "$target" | awk '{print $2":"$3}')
    echo ""
    echo "Видалити профіль?"
    echo "  Файл:   $(basename "$target") $(title_of "$target")"
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

    if [ -z "$target" ] || [ ! -f "$target" ]; then
        echo "Невірний вибір."
        exit 1
    fi

    echo ""
    echo "Профіль: $(basename "$target") $(title_of "$target")"
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
            # Саме цей файл, а не «перший з таким remote» (import_profile).
            read -rp "Шлях до нового .ovpn: " NEW_PATH
            NEW_PATH=$(clean_path "$NEW_PATH")
            [ -f "$NEW_PATH" ] || { echo "Файл не знайдено: $NEW_PATH"; exit 1; }
            cp "$target" "${target}.bak"
            cp "$NEW_PATH" "$target"
            echo "Замінено: $(basename "$target") (стара версія: $(basename "$target").bak)"
            return
            ;;
        *) echo "Невірний вибір."; exit 1 ;;
    esac

    read -rp "Шлях до PEM файлу (.pem/.crt/.key): " PEM_PATH
    PEM_PATH=$(clean_path "$PEM_PATH")
    if [ ! -f "$PEM_PATH" ]; then
        echo "Файл не знайдено: $PEM_PATH"
        exit 1
    fi


    # Замінюємо блок <TAG>...</TAG> у профілі. PEM передається шляхом, не вставкою в
    # python-код (лапки/бекслеші в ньому ламали скрипт), і без re.sub (той трактує "\" у заміні).
    local BACKUP="${target}.bak"
    cp "$target" "$BACKUP"

    python3 - "$target" "$TAG" "$PEM_PATH" <<'PY' || { mv "$BACKUP" "$target"; exit 1; }
import sys

path, tag, pem_path = sys.argv[1:4]
new_content = open(pem_path).read().strip()
data = open(path).read()

o, c = f"<{tag}>", f"</{tag}>"
i = data.find(o)
j = data.find(c, i + len(o)) if i >= 0 else -1
if i < 0 or j < 0:
    print(f"У профілі немає вбудованого <{tag}> — заміни профіль цілком.")
    sys.exit(1)
open(path, "w").write(data[:i + len(o)] + "\n" + new_content + "\n" + data[j:])
print(f"Блок <{tag}> оновлено.")
PY

    echo "Резервна копія: $(basename "$BACKUP")"
}

# ─── Головне меню ───────────────────────────────────────────────────────────

if [ -n "$1" ]; then
    if [ "$1" = "--delete" ]; then
        delete_profile
    else
        import_profile "$1"
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
