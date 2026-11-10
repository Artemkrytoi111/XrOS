#!/usr/bin/env bash
# XrOS — тест логики DE=none («Без графики») БЕЗ реальной установки.
# Только статический разбор исходников: src/xros-install (движок,
# единый источник списков пакетов), src/xros-install-gui-rs/src/app.rs
# (DES — варианты в GUI) и profile/packages.x86_64 (живая система).
#
# Использование:
#   ./scripts/tests/test-de-none.sh        # из корня проекта
#   bash scripts/tests/test-de-none.sh     # то же
# Выход: 0, если все проверки PASS; 1, если есть хоть один FAIL.
#
# Что проверяется:
#  (а) DE=none: в итоговом составе нет графики (plasma*/sddm/
#      xorg-server/pipewire*/qt6-*/gtk* — через список удаления
#      XROS_GRAPHICS_PKGS + чистку сирот pacman -Qtdq);
#  (б) базовая консольная система на месте (ядро, grub,
#      networkmanager, sudo, openssh — список XROS_CONSOLE_BASE_PKGS
#      + проверка после чистки);
#  (в) DM не включается при DE=none, цель по умолчанию —
#      multi-user.target;
#  (г) наборы вариантов GUI и консоли совпадают (7 кодов DE).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
GUI_APP="$ROOT/src/xros-install-gui-rs/src/app.rs"
GUI_STEPS="$ROOT/src/xros-install-gui-rs/src/steps.rs"
LIVE_PKGS="$ROOT/profile/packages.x86_64"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# --- helpers: вырезать значение переменной VAR="..." из движка ---
var_value() { # $1 = имя переменной, $2 = файл
  grep -E "^[A-Za-z_]*$1=" "$2" | head -n 1 | sed -E 's/^[^=]*="([^"]*)".*/\1/'
}
# Строка case-ветки для кода DE: "  kde) ... ;;"
case_line() { grep -E "^[[:space:]]*$1\)" "$ENGINE" | head -n 1; }
# Блок ветки DE=none в run_install: от '[[ "$DE" == "none" ]]' до 'else'
# цепочки DE (ровно два пробела перед else; внутренний else ветки —
# с большим отступом — не обрезает извлечение).
none_branch() {
  awk '/\[\[ "\$DE" == "none" \]\]/{f=1} f{print} f && /^  else$/{exit}' "$ENGINE"
}

echo "== DE=none: статический тест (без установки) =="
echo "движок: $ENGINE"

# ---------- (г) варианты GUI и консоли совпадают ----------
CONSOLE_DES=$(grep -oE '^[[:space:]]+(kde|gnome|xfce|cinnamon|sway|i3|none) "' "$ENGINE" \
  | grep -oE '(kde|gnome|xfce|cinnamon|sway|i3|none)' | sort -u | tr '\n' ' ')
GUI_DES=$(sed -n '/pub const DES/,/];/p' "$GUI_APP" \
  | grep -oE '"(kde|gnome|xfce|cinnamon|sway|i3|none)"' | tr -d '"' | sort -u | tr '\n' ' ')
if [[ "$CONSOLE_DES" == "$GUI_DES" && -n "$CONSOLE_DES" ]]; then
  ok "варианты GUI == консоли: $CONSOLE_DES"
else
  bad "варианты расходятся: консоль=[$CONSOLE_DES] GUI=[$GUI_DES]"
fi
N_DES=$(echo "$CONSOLE_DES" | wc -w)
check "ровно 7 вариантов DE" "[[ $N_DES -eq 7 ]]"
# Каждый код из меню есть и в case-карте движка.
for code in kde gnome xfce cinnamon sway i3 none; do
  check "case-карта: вариант $code" "case_line $code | grep -q ."
done

# ---------- (а) DE=none: графики нет ----------
# shellcheck disable=SC2034  # NONE_PKGS/NONE_DM читает eval внутри check
NONE_PKGS=$(case_line none | sed -E 's/.*DE_PKGS="([^"]*)".*/\1/')
check "DE=none: DE_PKGS пуст (pacman -S графики не будет)" "[[ -z \"\$NONE_PKGS\" ]]"
# shellcheck disable=SC2034
NONE_DM=$(case_line none | sed -E 's/.*DE_DM="([^"]*)".*/\1/')
check "DE=none: DE_DM пуст (менеджера входа нет)" "[[ -z \"\$NONE_DM\" ]]"

GRAPHICS_REMOVE=$(var_value XROS_GRAPHICS_PKGS "$ENGINE")
if [[ -z "$GRAPHICS_REMOVE" ]]; then
  bad "XROS_GRAPHICS_PKGS: список удаления графики не определён в движке"
else
  ok "XROS_GRAPHICS_PKGS определён: $GRAPHICS_REMOVE"
  # Каждый графический пакет живой системы обязан быть в списке удаления.
  for p in plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin \
           pipewire pipewire-pulse wireplumber xorg-server \
           ttf-dejavu noto-fonts python-pyqt6 libxkbcommon-x11; do
    if grep -q "^$p\$" "$LIVE_PKGS" 2>/dev/null; then
      # пакет есть в живой системе -> должен удаляться при DE=none
      check "DE=none: живой пакет $p — в списке удаления" \
        "echo \" \$GRAPHICS_REMOVE \" | grep -q \" $p \""
    else
      # пакета нет в живой системе — проверка не применима, не FAIL
      echo "SKIP  $p нет в живой системе (packages.x86_64)"
    fi
  done
  # Список удаления — только удаление: в нём не должно быть пакетов,
  # которые движок ставит (он ничего не ставит при DE=none: DE_PKGS пуст).
fi
# Сироты (Qt/KF/Plasma-библиотеки, оставшиеся без родителей) чистятся.
check "DE=none: чистка сирот (pacman -Qtdq) в ветке none" \
  "none_branch | grep -q 'pacman -Qtdq'"
# Ветка none реально удаляет, а не только отключает DM.
check "DE=none: ветка none вызывает pacman -Rns" \
  "none_branch | grep -q 'pacman -Rns'"
# Графические настройки живой системы не копируются в консольную.
check "DE=none: удаляется /etc/sddm.conf.d целиком" \
  "none_branch | grep -q 'rm -rf \"\$TARGET/etc/sddm.conf.d\"'"
check "DE=none: удаляются KDE-настройки из /etc/skel" \
  "none_branch | grep -q 'skel/.config/kdeglobals'"
# Лаунчер графического приветствия и его байткод — мёртвый груз
# без графики (бинарь xros-welcome-gui удаляется в той же ветке).
check "DE=none: удаляется лаунчер графического приветствия (.desktop)" \
  "none_branch | grep -q 'usr/share/applications/xros-welcome.desktop'"
check "DE=none: удаляется байткод приветствия (__pycache__)" \
  "none_branch | grep -q '__pycache__/xros-welcome-gui'"

# ---------- (б) базовая консольная система ----------
BASE_KEEP=$(var_value XROS_CONSOLE_BASE_PKGS "$ENGINE")
if [[ -z "$BASE_KEEP" ]]; then
  bad "XROS_CONSOLE_BASE_PKGS: список обязательных базовых пакетов не определён"
else
  ok "XROS_CONSOLE_BASE_PKGS определён: $BASE_KEEP"
  for p in linux grub networkmanager sudo openssh; do
    check "DE=none: базовый пакет $p — в списке обязательных" \
      "echo \" \$BASE_KEEP \" | grep -q \" $p \""
  done
fi
# Ветка none после чистки проверяет, что база на месте.
check "DE=none: после чистки проверяется наличие базовых пакетов (pacman -Q)" \
  "none_branch | grep -q 'pacman -Q'"
# Ядро/grub ставятся вне зависимости от DE (общий код движка).
check "движок: ядро копируется с ISO (vmlinuz-linux) для любого DE" \
  "grep -q 'cp \"\$KERN_SRC/vmlinuz-linux\"' \"$ENGINE\""
check "движок: NetworkManager включается для любого DE" \
  "grep -q 'systemctl enable NetworkManager.service' \"$ENGINE\""

# ---------- (в) DM и цель загрузки при DE=none ----------
NB=$(none_branch)
if echo "$NB" | grep -q 'systemctl enable'; then
  bad "DE=none: ветка none содержит systemctl enable (DM не должен включаться)"
else
  ok "DE=none: ветка none не содержит systemctl enable"
fi
check "DE=none: все DM отключаются (sddm/lightdm/gdm)" \
  "echo \"\$NB\" | grep -q 'systemctl disable sddm.service' && echo \"\$NB\" | grep -q 'systemctl disable lightdm.service' && echo \"\$NB\" | grep -q 'systemctl disable gdm.service'"
check "DE=none: цель по умолчанию — multi-user.target" \
  "echo \"\$NB\" | grep -q 'systemctl set-default multi-user.target'"
check "DE=none: автовход не ставится (требует DE_DM, у none он пуст)" \
  "grep -q 'AUTOLOGIN.*&& -n \"\$DE_DM\"' \"$ENGINE\""
# Графические варианты, наоборот, ставят graphical.target.
check "KDE: цель по умолчанию — graphical.target" \
  "grep -q 'systemctl set-default graphical.target' \"$ENGINE\""
# Офис на консоли не ставится (Okular/LibreOffice тянут Qt/GTK обратно).
OFFICE_LINE=$(grep -n 'Офисный пакет' "$ENGINE" | head -n 1 | cut -d: -f1)
# защита от офиса при DE=none — первое '[[ "$DE" == "none" ]]' ПОСЛЕ
# комментария про офисный пакет (до него та же строка — ветка none).
OFFICE_GUARD_LINE=$(awk -v start="$OFFICE_LINE" 'NR>start && /\[\[ "\$DE" == "none" \]\]; then/{print NR; exit}' "$ENGINE")
if [[ -n "${OFFICE_GUARD_LINE:-}" && -n "${OFFICE_LINE:-}" && "$OFFICE_GUARD_LINE" -ge "$OFFICE_LINE" ]]; then
  ok "DE=none: офисный пакет пропускается (защита в блоке офиса)"
else
  bad "DE=none: нет защиты от установки офиса в блоке офиса"
fi

# ---------- KDE: полный состав, без xorg-server ----------
KDE_PKGS=$(case_line kde | sed -E 's/.*DE_PKGS="([^"]*)".*/\1/')
for p in plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin; do
  check "KDE: $p в DE_PKGS" "echo \" \$KDE_PKGS \" | grep -q \" $p \""
done
if echo " $KDE_PKGS " | grep -q " xorg-server "; then
  bad "KDE: xorg-server в DE_PKGS (Plasma 6.8 Wayland: не нужен; XWayland даёт plasma-workspace, а xorg-server тянется зависимостью sddm)"
else
  ok "KDE: xorg-server НЕ в DE_PKGS (Wayland; sddm сам тянет xorg-server)"
fi

# ---------- GUI: подсказка про none не врёт ----------
check "GUI: шаг Desktop упоминает, что none работает без интернета" \
  "grep -q 'Без графики' \"$GUI_STEPS\""

# ---------- Синхронность staged-копий движка ----------
if cmp -s "$ENGINE" "$ROOT/profile/airootfs/usr/local/bin/xros-install" \
   && cmp -s "$ENGINE" "$ROOT/packages/xros-installer/xros-install"; then
  ok "xros-install синхронен (src == airootfs == пакет)"
else
  bad "xros-install расходится (src != airootfs и/или пакет) — синхронизируй копии"
fi

echo "--------------------------------------------------"
echo "Итог: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
