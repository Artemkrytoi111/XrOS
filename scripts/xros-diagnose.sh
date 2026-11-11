#!/usr/bin/env bash
# XrOS — диагностика проекта (этап E, аудит 10.11.2026).
# Запуск: ./scripts/xros-diagnose.sh
# Проверяет только то, что можно проверить без сборки ISO и без QEMU.
# Результат честный: PASS / FAIL / SKIP (не проверяется — так и пишется).
# При любом FAIL скрипт завершается с кодом 1.
# Проверки, требующие chroot (cargo, makepkg, grub-script-check),
# на хосте без этих инструментов дают SKIP; их результаты — в AUDIT-REPORT.md.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
FAILED=()

ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
skip() { echo "SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

cd "$ROOT"

# ---------------------------------------------------------------- 1. bash -n
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n ${f#$ROOT/}"; else bad "bash -n ${f#$ROOT/}"; fi
# xros-welcome-gui — Python, а не bash: его проверяет py_compile ниже,
# поэтому из bash-проверки он исключён.
done < <(find profile src packages scripts -type f \( -name '*.sh' -o -name 'xros-install' -o -name 'xros-welcome' -o -name 'PKGBUILD' -o -name 'profiledef.sh' -o -name 'customize_airootfs.sh' \) -print0)

# ---------------------------------------------------------------- 2. shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  sc_fail=0
  while IFS= read -r -d '' f; do
    shellcheck -S warning "$f" >/dev/null 2>&1 || sc_fail=1
  done < <(find profile src packages scripts -type f \( -name '*.sh' -o -name 'xros-install' -o -name 'xros-welcome' -o -name 'PKGBUILD' -o -name 'profiledef.sh' -o -name 'customize_airootfs.sh' \) -print0)
  if [[ $sc_fail -eq 0 ]]; then ok "shellcheck всех bash-файлов"; else bad "shellcheck: есть предупреждения/ошибки"; fi
else
  skip "shellcheck" "shellcheck не установлен на этом хосте"
fi

# ---------------------------------------------------------------- 3. Python
for f in src/xros-welcome-gui scripts/make-branding.py; do
  if [[ -f "$f" ]] && python3 -m py_compile "$f" 2>/dev/null; then ok "py_compile $f"; else bad "py_compile $f"; fi
done

# ---------------------------------------------------------------- 4. Rust
if command -v cargo >/dev/null 2>&1; then
  if (cd src/xros-install-gui-rs && cargo check --offline 2>/dev/null); then
    ok "cargo check xros-install-gui"
  else
    bad "cargo check xros-install-gui"
  fi
  if (cd src/xros-cli && cargo check --offline 2>/dev/null); then
    ok "cargo check xros-cli"
  else
    bad "cargo check xros-cli"
  fi
  if cargo clippy --version >/dev/null 2>&1; then
    if (cd src/xros-cli && cargo clippy --offline -- -D warnings 2>/dev/null); then
      ok "cargo clippy xros-cli (-D warnings)"
    else
      bad "cargo clippy xros-cli (-D warnings)"
    fi
    if (cd src/xros-install-gui-rs && cargo clippy --offline -- -D warnings 2>/dev/null); then
      ok "cargo clippy xros-install-gui (-D warnings)"
    else
      bad "cargo clippy xros-install-gui (-D warnings)"
    fi
  else
    skip "cargo clippy xros-cli" "clippy не установлен"
    skip "cargo clippy xros-install-gui" "clippy не установлен"
  fi
else
  skip "cargo check xros-install-gui" "cargo не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot)"
  skip "cargo check xros-cli" "cargo не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot)"
  skip "cargo clippy xros-cli" "cargo не установлен на этом хосте"
  skip "cargo clippy xros-install-gui" "cargo не установлен на этом хосте"
fi

# ---------------------------------------------------------------- 5. PKGBUILD
if command -v makepkg >/dev/null 2>&1; then
  for p in xros-cli xros-installer xros-welcome xros-branding; do
    if (cd "packages/$p" && makepkg --printsrcinfo >/dev/null 2>&1); then
      ok "makepkg --printsrcinfo $p"
    else
      bad "makepkg --printsrcinfo $p"
    fi
  done
else
  for p in xros-cli xros-installer xros-welcome xros-branding; do
    skip "makepkg --printsrcinfo $p" "makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot)"
  done
fi

# ---------------------------------------------------------------- 6. Следы другого проекта
# Исключения: ARCHITECTURE.md (там происхождение рецепта сборки
# задокументировано намеренно) и сам этот скрипт (в нём — паттерн grep).
# scripts/build.sh с 10.11.2026 чист: строка с путём к chroot другого
# проекта удалена вместе с заменой зависимости на собственный build-env,
# поэтому исключения для build.sh больше нет.
if grep -rI --exclude-dir=.git --exclude=ARCHITECTURE.md --exclude=xros-diagnose.sh -E 'akvt|АКВТ|Территория успеха' profile src packages scripts branding repo preview 2>/dev/null | grep .; then
  bad "посторонние упоминания другого проекта вне ARCHITECTURE.md"
else
  ok "нет следов другого проекта (кроме ARCHITECTURE.md §2)"
fi

# ---------------------------------------------------------------- 7. Загрузчик
# 7а. bootmodes — только uefi.grub (bios.grub в archiso не существует).
if grep -qF "bootmodes=('uefi.grub')" profile/profiledef.sh; then
  ok "profiledef: bootmodes=('uefi.grub')"
else
  bad "profiledef: bootmodes не равен ('uefi.grub')"
fi
if grep -qE "^bootmodes=.*(syslinux|systemd-boot)" profile/profiledef.sh; then
  bad "profiledef: в bootmodes остались syslinux/systemd-boot"
else
  ok "profiledef: в bootmodes нет syslinux/systemd-boot"
fi
# 7б. syslinux/efiboot удалены из профиля.
if [[ ! -e profile/syslinux && ! -e profile/efiboot ]]; then
  ok "profile/syslinux и profile/efiboot отсутствуют (удалены)"
else
  bad "profile/syslinux или profile/efiboot всё ещё на месте"
fi
# 7в. Файлы GRUB на месте.
for f in profile/grub/grub.cfg profile/grub/loopback.cfg profile/grub/theme/theme.txt \
         profile/grub/theme/grub-bg.jpg profile/grub/theme/DejaVuSans-12.pf2 \
         profile/grub/theme/DejaVuSans-14.pf2 profile/grub/theme/DejaVuSans-Bold-16.pf2; do
  if [[ -f "$f" ]]; then ok "есть $f"; else bad "нет $f"; fi
done
# 7г. theme.txt ссылается только на существующие файлы.
theme_img=$(grep -oP 'desktop-image:\s*"\K[^"]+' profile/grub/theme/theme.txt || true)
if [[ -n "$theme_img" && -f "profile/grub/theme/$theme_img" ]]; then
  ok "theme.txt: desktop-image $theme_img существует"
else
  bad "theme.txt: desktop-image $theme_img не найден"
fi
# 7д. grub-script-check, если доступен.
if command -v grub-script-check >/dev/null 2>&1; then
  if grub-script-check profile/grub/grub.cfg 2>/dev/null; then ok "grub-script-check grub.cfg"; else bad "grub-script-check grub.cfg"; fi
  if grub-script-check profile/grub/loopback.cfg 2>/dev/null; then ok "grub-script-check loopback.cfg"; else bad "grub-script-check loopback.cfg"; fi
else
  skip "grub-script-check grub.cfg" "grub-script-check нет на хосте (см. AUDIT-REPORT.md: проверено в chroot)"
  skip "grub-script-check loopback.cfg" "grub-script-check нет на хосте (см. AUDIT-REPORT.md: проверено в chroot)"
fi
# 7е. В grub.cfg/loopback.cfg нет невалидных имён цветов GRUB
# (допустимы только 16 стандартных; 'indigo' там был — исправлено 10.11.2026).
if grep -qi 'indigo' profile/grub/grub.cfg profile/grub/loopback.cfg; then
  bad "grub.cfg/loopback.cfg: невалидный цвет 'indigo'"
else
  ok "grub.cfg/loopback.cfg: нет невалидного цвета 'indigo'"
fi
# 7ж. Пункты memtest/UEFI Shell: целевое состояние — их НЕТ вообще
# (параллельный агент по загрузчику убрал их из меню 10.11.2026:
# пакеты memtest86+-efi/edk2-shell не входят в профиль, пункты
# намеренно отсутствуют — см. комментарий в grub.cfg). Если пункт
# когда-нибудь вернётся, он обязан быть защищён проверкой наличия
# файла через search --file --set= (модуль search есть в образе).
# Проверки -f НЕ годятся: модуля test нет в UEFI-образе mkarchiso,
# [ -f ... ] там всегда ложна (см. experiments/uefi-test-module/).
if grep -qiE "menuentry.*memtest" profile/grub/grub.cfg; then
  # Проверка стража: в 5 строках выше пункта должен быть search --file.
  mem_line=$(grep -n -iE "menuentry.*memtest" profile/grub/grub.cfg | head -1 | cut -d: -f1)
  start=$(( mem_line > 5 ? mem_line - 5 : 1 ))
  if sed -n "${start},$((mem_line-1))p" profile/grub/grub.cfg | grep -q 'search --file --set='; then
    ok "grub.cfg: пункт Memtest86+ защищён search --file"
  else
    bad "grub.cfg: пункт Memtest86+ без search-стража (проверки -f не работают на UEFI)"
  fi
else
  ok "grub.cfg: пункта Memtest86+ нет (намеренно отсутствует)"
fi
if grep -qiE "menuentry.*UEFI Shell" profile/grub/grub.cfg; then
  shell_line=$(grep -n -iE "menuentry.*UEFI Shell" profile/grub/grub.cfg | head -1 | cut -d: -f1)
  start=$(( shell_line > 5 ? shell_line - 5 : 1 ))
  if sed -n "${start},$((shell_line-1))p" profile/grub/grub.cfg | grep -q 'search --file --set='; then
    ok "grub.cfg: пункт UEFI Shell защищён search --file"
  else
    bad "grub.cfg: пункт UEFI Shell без search-стража (проверки -f не работают на UEFI)"
  fi
else
  ok "grub.cfg: пункта UEFI Shell нет (намеренно отсутствует)"
fi
# 7з. Меню GRUB (дефект 10.11.2026, fixed3/fixed6): @TIMEOUT@ GRUB
# подставляет ТОЛЬКО в progress_bar с id "__timeout__" (в label — никогда;
# доказано установленной системой: fixed5-label показывал литерал).
# Поэтому: @TIMEOUT@ — только в progress_bar, ни в одном label его нет;
# id "__timeout__" ровно один; пункт меню не длиннее ~30 символов, иначе
# pixmap выделения (50% ширины) обрезает текст («с экранным диктором
# (speaking)» обрезался до «(s», fixed3).
if awk '/\+ progress_bar \{/{f=1} f&&/^\}/{f=0} f&&/@TIMEOUT@/{bad=1} END{exit bad?0:1}' profile/grub/theme/theme.txt; then
  ok "theme.txt: @TIMEOUT@ в progress_bar (GRUB подставит число)"
else
  bad "theme.txt: нет @TIMEOUT@ в progress_bar (обратный отсчёт не покажется)"
fi
if awk '/\+ label \{/{f=1} f&&/^\}/{f=0} f&&/@TIMEOUT@/{bad=1} END{exit bad?0:1}' profile/grub/theme/theme.txt; then
  bad "theme.txt: @TIMEOUT@ в label (GRUB не подставляет, будет литерал)"
else
  ok "theme.txt: в label нет @TIMEOUT@"
fi
# fixed6 (11.11.2026): id "__timeout__" должен быть РОВНО ОДИН на весь
# theme.txt и именно на progress_bar. В fixed4 их было два (progress_bar +
# label) — GRUB обновлял только первый; в fixed5 остался только label —
# GRUB не подставил ничего, и был литерал.
if [ "$(grep -c 'id = "__timeout__"' profile/grub/theme/theme.txt)" -eq 1 ] && awk '/\+ progress_bar \{/{f=1} f&&/^\}/{f=0} f&&/id = "__timeout__"/{ok=1} END{exit ok?0:1}' profile/grub/theme/theme.txt; then
  ok "theme.txt: id __timeout__ ровно один, на progress_bar"
else
  bad "theme.txt: id __timeout__ не один или не на progress_bar (найдено: $(grep -c 'id = "__timeout__"' profile/grub/theme/theme.txt))"
fi
if grep -oP 'menuentry "\K[^"]+' profile/grub/grub.cfg | sed 's/%ARCH%/x86_64/g; s/${archiso_platform}/UEFI/g' | while IFS= read -r _l; do [ "$(printf '%s' "$_l" | LC_ALL=C.UTF-8 wc -m)" -gt 30 ] && echo "$_l"; done | grep -q .; then
  bad "grub.cfg: есть пункт меню длиннее 30 символов (обрежется pixmap)"
else
  ok "grub.cfg: пункты меню короткие (не обрежутся)"
fi

# ---------------------------------------------------------------- 8. Пакеты live-системы
# 8а. Нет syslinux и plasma-x11-session среди реальных пакетов
# (строки без '#', не комментарии).
pkgs=$(grep -v '^\s*#' profile/packages.x86_64 | grep -v '^\s*$' || true)
if echo "$pkgs" | grep -qx 'syslinux'; then bad "packages.x86_64: syslinux в списке"; else ok "packages.x86_64: нет syslinux"; fi
if echo "$pkgs" | grep -qx 'plasma-x11-session'; then bad "packages.x86_64: plasma-x11-session в списке"; else ok "packages.x86_64: нет plasma-x11-session"; fi
if echo "$pkgs" | grep -qx 'memtest86+-efi'; then ok "packages.x86_64: memtest86+-efi есть"; else skip "packages.x86_64: memtest86+-efi" "пакета нет — пункт меню Memtest86+ скроется (см. AUDIT-REPORT.md)"; fi
if echo "$pkgs" | grep -qx 'edk2-shell'; then ok "packages.x86_64: edk2-shell есть"; else skip "packages.x86_64: edk2-shell" "пакета нет — пункт меню UEFI Shell скроется (см. AUDIT-REPORT.md)"; fi
# 8б. Нет дублей.
if [[ -z "$(echo "$pkgs" | sort | uniq -d)" ]]; then ok "packages.x86_64: дублей нет"; else bad "packages.x86_64: есть дубли"; fi
# 8в. Обязательные пакеты на месте.
for p in linux-firmware pipewire pipewire-pulse wireplumber ntfs-3g kscreen grub linux; do
  if echo "$pkgs" | grep -qx "$p"; then ok "packages.x86_64: есть $p"; else bad "packages.x86_64: нет $p"; fi
done

# ---------------------------------------------------------------- 9. Профиль: обязательные файлы
for f in profile/profiledef.sh profile/packages.x86_64 profile/pacman.conf \
         profile/airootfs/root/customize_airootfs.sh \
         profile/airootfs/etc/hostname profile/airootfs/etc/locale.conf; do
  if [[ -f "$f" ]]; then ok "есть $f"; else bad "нет $f"; fi
done
if [[ -x profile/airootfs/root/customize_airootfs.sh ]]; then
  ok "customize_airootfs.sh +x"
else
  bad "customize_airootfs.sh НЕ +x"
fi
if cmp -s profile/pacman.conf profile/airootfs/etc/pacman.conf; then
  ok "profile/pacman.conf == profile/airootfs/etc/pacman.conf"
else
  bad "profile/pacman.conf != profile/airootfs/etc/pacman.conf"
fi

# ---------------------------------------------------------------- 10. Брендинг
for f in branding/xros-logo.png branding/xros-logo-small.png \
         branding/wallpaper.png branding/wallpaper.jpg \
         branding/grub-bg.jpg branding/grub-bg.png; do
  if [[ -f "$f" ]]; then ok "есть $f"; else bad "нет $f"; fi
done
# 10а. Синхронность копий (канон: branding/).
for f in xros-logo.png xros-logo-small.png wallpaper.png wallpaper.jpg grub-bg.jpg grub-bg.png; do
  if cmp -s "branding/$f" "profile/airootfs/usr/share/xros/$f" && cmp -s "branding/$f" "packages/xros-branding/$f"; then
    ok "синхронно branding/$f (airootfs + пакет)"
  else
    bad "рассинхрон branding/$f"
  fi
done
for f in grub-bg.jpg grub-bg.png; do
  if cmp -s "branding/$f" "profile/grub/theme/$f" && cmp -s "branding/$f" "profile/grub/splash.${f##*.}"; then
    ok "синхронно branding/$f (тема GRUB + splash)"
  else
    bad "рассинхрон branding/$f (тема GRUB / splash)"
  fi
done
# 10б. Прозрачность логотипа и размер обоев (PIL).
if python3 -c 'import PIL' 2>/dev/null; then
  if python3 - <<'PY' 2>/dev/null
from PIL import Image
im = Image.open('branding/xros-logo.png')
assert im.mode == 'RGBA', 'нет альфа-канала'
a = im.getchannel('A')
w, h = im.size
assert a.getpixel((0, 0)) == 0 and a.getpixel((w-1, 0)) == 0
assert a.getpixel((0, h-1)) == 0 and a.getpixel((w-1, h-1)) == 0
assert a.histogram()[0] > 0, 'нет прозрачных пикселей'
wp = Image.open('branding/wallpaper.png')
assert wp.size == (1920, 1080), f'обои {wp.size}'
wj = Image.open('branding/wallpaper.jpg')
assert wj.size == (1920, 1080), f'обои jpg {wj.size}'
PY
  then
    ok "логотип: RGBA, углы alpha=0; обои 1920x1080"
  else
    bad "логотип/обои: проверка PIL не пройдена"
  fi
else
  skip "логотип: прозрачность / обои 1920x1080" "PIL не установлен"
fi
# 10в. Тема GRUB: обязательные ключи и контраст выбранного пункта.
for key in 'title-text:' 'desktop-image:' 'item_font' '+ boot_menu'; do
  if grep -qF "$key" profile/grub/theme/theme.txt; then ok "theme.txt: $key"; else bad "theme.txt: нет $key"; fi
done
if grep -q 'selected_item_color = "#f5f3fa"' profile/grub/theme/theme.txt \
   && grep -q 'selected_item_color = "#f5f3fa"' profile/airootfs/usr/share/xros/grub-theme/theme.txt; then
  ok "theme.txt: selected_item_color #f5f3fa (контраст 5,39:1) в обеих копиях"
else
  bad "theme.txt: selected_item_color не #f5f3fa"
fi
if diff -q profile/grub/theme/theme.txt profile/airootfs/usr/share/xros/grub-theme/theme.txt >/dev/null; then
  ok "theme.txt синхронен (профиль == airootfs)"
else
  bad "theme.txt расходится (профиль != airootfs)"
fi

# ---------------------------------------------------------------- 11. Старые цвета
# Исключения: AUDIT-REPORT.md (там они упомянуты как удалённые)
# и сам этот скрипт (в нём — паттерн grep).
if grep -rIi --exclude-dir=.git --exclude=AUDIT-REPORT.md --exclude=xros-diagnose.sh \
     -E '6C5CE7|22D3EE|9333EA|A855F7|6B21A8|108;92;231' profile src packages scripts branding repo preview README.md ARCHITECTURE.md 2>/dev/null | grep .; then
  bad "остались старые цвета (6C5CE7/22D3EE/9333EA/A855F7/6B21A8/ANSI 108;92;231)"
else
  ok "старых цветов нет (кроме AUDIT-REPORT.md)"
fi

# ---------------------------------------------------------------- 12. Превью
if [[ -f preview/index.html ]]; then ok "есть preview/index.html"; else bad "нет preview/index.html"; fi
preview_missing=0
while IFS= read -r ref; do
  # ref вида ../branding/xros-logo.png — относительно preview/
  target="preview/$ref"
  if [[ ! -e "$target" ]]; then echo "  нет файла превью: $ref"; preview_missing=1; fi
done < <(grep -oE '(src|href)="[^"]+"|url\("[^"]+"\)' preview/index.html | sed -E 's/^(src|href)="([^"]+)"/\2/; s/^url\("([^"]+)"\)/\1/' | sort -u)
if [[ $preview_missing -eq 0 ]]; then ok "preview: все пути к ресурсам существуют"; else bad "preview: есть несуществующие пути"; fi
if grep -q 'XrOS успешно установлена' preview/index.html; then ok "preview: блок экрана завершения"; else bad "preview: нет блока экрана завершения"; fi
if grep -q 'design-tokens.css' preview/index.html; then ok "preview: design-tokens.css подключён"; else bad "preview: design-tokens.css не подключён"; fi

# ---------------------------------------------------------------- 13. Репозиторий и автообновления
# 13а. Автообновления выключены: нигде нет включения таймера.
if grep -rI --exclude-dir=.git -E 'systemctl (enable|--global enable).*xros-update\.timer|systemctl enable xros-update' src profile packages 2>/dev/null | grep .; then
  bad "найдено включение xros-update.timer"
else
  ok "xros-update.timer нигде не включается"
fi
# 13б. БД репозитория: 4 пакета.
if [[ -f repo/xros/os/x86_64/xros.db.tar.gz ]]; then
  n=$(tar tzf repo/xros/os/x86_64/xros.db.tar.gz 2>/dev/null | grep -c '/$' || true)
  if [[ "$n" -eq 4 ]]; then ok "repo DB: 4 пакета"; else bad "repo DB: пакетов $n, ожидалось 4"; fi
else
  bad "нет repo/xros/os/x86_64/xros.db.tar.gz"
fi
if [[ -f repo/xros/os/x86_64/xros.files.tar.gz ]]; then ok "есть repo xros.files.tar.gz"; else bad "нет repo xros.files.tar.gz"; fi
# 13в. Снимок репозитория в airootfs синхронен с repo/.
if diff -r repo/xros/os/x86_64 profile/airootfs/usr/share/xros/repo/xros/os/x86_64 >/dev/null 2>&1; then
  ok "снимок репозитория в airootfs == repo/"
else
  bad "снимок репозитория в airootfs != repo/"
fi
# 13г. Каждое упоминание xros.example сопровождается PLACEHOLDER.
placeholder_bad=0
while IFS= read -r -d '' f; do
  if grep -q 'xros.example' "$f" && ! grep -q 'PLACEHOLDER' "$f"; then
    echo "  xros.example без PLACEHOLDER: $f"; placeholder_bad=1
  fi
done < <(grep -rIl --exclude-dir=.git --exclude=AUDIT-REPORT.md 'xros.example' profile src packages scripts branding repo preview README.md ARCHITECTURE.md 2>/dev/null | tr '\n' '\0')
if [[ $placeholder_bad -eq 0 ]]; then ok "xros.example везде помечен PLACEHOLDER"; else bad "xros.example без пометки PLACEHOLDER"; fi

# ---------------------------------------------------------------- 14. Cargo.lock
for p in src/xros-cli src/xros-install-gui-rs; do
  if [[ -f "$p/Cargo.lock" ]]; then ok "есть $p/Cargo.lock"; else bad "нет $p/Cargo.lock"; fi
done

# ---------------------------------------------------------------- 15. Синхронность staged-копий (канон: src/ и branding/)
if cmp -s src/xros-install profile/airootfs/usr/local/bin/xros-install && cmp -s src/xros-install packages/xros-installer/xros-install; then
  ok "xros-install синхронен (src == airootfs == пакет)"
else
  bad "xros-install расходится"
fi
if cmp -s src/xros-welcome profile/airootfs/usr/local/bin/xros-welcome; then
  ok "xros-welcome синхронен (src == airootfs)"
else
  bad "xros-welcome расходится"
fi
if cmp -s src/xros-welcome-gui profile/airootfs/usr/local/bin/xros-welcome-gui && cmp -s src/xros-welcome-gui packages/xros-welcome/xros-welcome-gui; then
  ok "xros-welcome-gui синхронен (src == airootfs == пакет)"
else
  bad "xros-welcome-gui расходится"
fi
if cmp -s packages/xros-cli/xros profile/airootfs/usr/local/bin/xros; then
  ok "xros (CLI) синхронен (пакет == airootfs)"
else
  bad "xros (CLI) расходится (пакет != airootfs)"
fi
if cmp -s packages/xros-installer/xros-install-gui profile/airootfs/usr/local/bin/xros-install-gui; then
  ok "xros-install-gui синхронен (пакет == airootfs)"
else
  bad "xros-install-gui расходится (пакет != airootfs)"
fi
# fixed7 (11.11.2026): фокус клавиатуры в диалогах установщика —
# при открытии диалога фокус ставится на главную кнопку (request_focus),
# иначе Tab циклит виджеты главного окна и до кнопок диалога не доходит
# (INSTALLER-VALIDATION.md: подтверждение стирания — FAIL).
if grep -q 'request_focus' src/xros-install-gui-rs/src/app.rs && [[ packages/xros-installer/xros-install-gui -nt src/xros-install-gui-rs/src/app.rs ]]; then
  ok "xros-install-gui: фокус диалога (request_focus), бинарь свежее исходников"
else
  bad "xros-install-gui: нет request_focus в app.rs или бинарь старше исходников"
fi
# fixed7 (11.11.2026): надёжное ожидание ActivityManager перед
# запуском plasmashell — After= для Type=simple гарантирует только
# порядок fork'а, а не готовность bus-name (разрыв до 27 с под TCG,
# установленная система fixed5: plasmashell сдавался без ретрая).
# Drop-in должен ссылаться на скрипт ожидания, скрипт — быть
# исполняемым, а стартовый таймаут — покрывать ожидание (~60 с).
DROPIN="profile/airootfs/etc/systemd/user/plasma-plasmashell.service.d/10-kactivitymanagerd.conf"
WAITBIN="profile/airootfs/usr/local/bin/xros-wait-kactivitymanagerd"
if grep -q 'ExecStartPre=/usr/local/bin/xros-wait-kactivitymanagerd' "$DROPIN" \
   && grep -q 'TimeoutStartSec=120s' "$DROPIN" \
   && [[ -x "$WAITBIN" ]] && grep -q 'org.kde.ActivityManager' "$WAITBIN"; then
  ok "plasma-plasmashell drop-in: ExecStartPre (wait ActivityManager) + TimeoutStartSec=120s, скрипт исполняемый"
else
  bad "plasma-plasmashell drop-in: нет ExecStartPre/TimeoutStartSec или скрипт xros-wait-kactivitymanagerd не исполняемый/без проверки шины"
fi
if cmp -s packages/xros-branding/banner.txt profile/airootfs/usr/share/xros/banner.txt; then
  ok "banner.txt синхронен (пакет == airootfs)"
else
  bad "banner.txt расходится (пакет != airootfs)"
fi
# Модель запуска приветствия — autostart-only
# (docs/final-refinement/welcome-wayland.md, задача 4):
# systemd user service xros-welcome.service УДАЛЁН из пакета и из
# airootfs — единственный механизм автозапуска это
# /etc/xdg/autostart/xros-welcome.desktop. Проверка учитывает оба
# состояния: если сервис где-то ещё есть, он обязан быть синхронным
# в обеих копиях и без X11-переменных (это ловит и §19в); если его
# нет нигде — это целевое состояние, и тогда проверяются оба
# .desktop-файла (autostart + пункт меню).
if [[ ! -e packages/xros-welcome/xros-welcome.service && ! -e profile/airootfs/etc/systemd/user/xros-welcome.service ]]; then
  ok "welcome service отсутствует (модель autostart-only)"
  if cmp -s packages/xros-welcome/xros-welcome-menu.desktop profile/airootfs/usr/share/applications/xros-welcome.desktop; then
    ok "xros-welcome.desktop (пункт меню) синхронен (пакет == airootfs)"
  else
    bad "xros-welcome.desktop (пункт меню) расходится (пакет != airootfs)"
  fi
elif [[ -e packages/xros-welcome/xros-welcome.service && -e profile/airootfs/etc/systemd/user/xros-welcome.service ]]; then
  if cmp -s packages/xros-welcome/xros-welcome.service profile/airootfs/etc/systemd/user/xros-welcome.service; then
    ok "xros-welcome.service синхронен (пакет == airootfs)"
  else
    bad "xros-welcome.service расходится"
  fi
else
  bad "xros-welcome.service есть только в одном месте (пакет/airootfs рассинхрон)"
fi
if cmp -s packages/xros-welcome/xros-welcome.desktop profile/airootfs/etc/xdg/autostart/xros-welcome.desktop; then
  ok "xros-welcome.desktop синхронен (пакет == airootfs)"
else
  bad "xros-welcome.desktop расходится"
fi

# ---------------------------------------------------------------- 16. Установщик: движок
for marker in 'mkfs_root' 'FS:=ext4' 'grub-install --target=x86_64-efi' 'grub-install --target=i386-pc' 'INSTALL_DONE' 'INSTALL_FAILED' 'GRUB_THEME='; do
  if grep -qF "$marker" src/xros-install; then ok "xros-install: $marker"; else bad "xros-install: нет $marker"; fi
done
# 16а. Безопасность движка (аудит установщика, этапы B–C).
if grep -q 'printf -v .*_Q %q' src/xros-install; then ok "xros-install: %q-экранирование пароля/ФИО"; else bad "xros-install: нет %q-экранирования"; fi
if grep -q 'нельзя ставить на диск с ISO' src/xros-install; then ok "xros-install: защита от установки на диск с ISO"; else bad "xros-install: нет защиты от диска с ISO"; fi
if grep -q '\[\[ -b "${DISK:-}" \]\]' src/xros-install && grep -q 'lsblk -d -n -o TYPE "$DISK"' src/xros-install; then ok "xros-install: проверка диска (-b, TYPE=disk)"; else bad "xros-install: нет проверки диска"; fi
if grep -q 'sudo --preserve-env=XROS_NONINTERACTIVE,XROS_INSTALL_CONF' src/xros-install; then ok "xros-install: sudo --preserve-env"; else bad "xros-install: нет sudo --preserve-env"; fi
if grep -q 'umask 077' src/xros-install; then ok "xros-install: umask 077"; else bad "xros-install: нет umask 077"; fi
if grep -q 'rm -f "$TARGET/etc/machine-id"' src/xros-install && grep -q 'systemd-machine-id-setup' src/xros-install; then ok "xros-install: machine-id удаляется + пересоздаётся"; else bad "xros-install: нет обработки machine-id"; fi
if grep -q 'rm -f "$TARGET/etc/resolv.conf"' src/xros-install; then ok "xros-install: resolv.conf удаляется"; else bad "xros-install: нет удаления resolv.conf"; fi
if grep -q 'systemctl disable sddm.service' src/xros-install && grep -q 'systemctl disable lightdm.service' src/xros-install && grep -q 'systemctl disable gdm.service' src/xros-install; then ok "xros-install: все DM отключаются перед включением выбранного"; else bad "xros-install: не все DM отключаются"; fi
if grep -q 'autologin-user=' src/xros-install && grep -q 'AutomaticLoginEnable=True' src/xros-install; then ok "xros-install: автовход GDM/LightDM/SDDM по выбранному DE"; else bad "xros-install: нет автовхода GDM/LightDM"; fi
if grep -q '\[\[ -s "$TARGET/etc/fstab" \]\]' src/xros-install && grep -q 'пользователь $USERNAME не создан' src/xros-install && grep -q 'hostname не записан' src/xros-install && grep -q 'display-manager.service' src/xros-install; then ok "xros-install: расширенная финальная проверка (fstab, пользователь, hostname, DM)"; else bad "xros-install: финальная проверка неполная"; fi
if grep -q 'systemctl --global enable xros-welcome.service' profile/airootfs/root/customize_airootfs.sh; then
  bad "customize: welcome service включается (модель autostart-only запрещает)"
else
  ok "customize: welcome service НЕ включается (модель autostart-only)"
fi
if grep -q 'xros-welcome.desktop' profile/airootfs/root/customize_airootfs.sh && grep -q 'cat > .*xros-welcome.desktop' profile/airootfs/root/customize_airootfs.sh; then
  bad "customize: .desktop приветствия перезаписывается heredoc-ом (дубль профиля)"
else
  ok "customize: .desktop приветствия берётся из профиля, дублей нет"
fi
if grep -q 'Hidden=true' src/xros-welcome-gui; then ok "welcome-gui: Hidden=true toggle «Запускать при старте»"; else bad "welcome-gui: нет Hidden=true toggle"; fi

# ---------------------------------------------------------------- 17. Установщик: GUI
for marker in '"Desktop"' '"Finish"' 'reboot_now' 'XrOS успешно установлена' 'Перезагрузить компьютер сейчас'; do
  if grep -qF "$marker" src/xros-install-gui-rs/src/steps.rs src/xros-install-gui-rs/src/app.rs; then
    ok "gui: $marker"
  else
    bad "gui: нет $marker"
  fi
done
if grep -q 'CancelClose' src/xros-install-gui-rs/src/app.rs; then ok "gui: запрет закрытия окна во время установки (CancelClose)"; else bad "gui: нет CancelClose"; fi
if grep -q 'start_step.min(STEPS.len() - 2)' src/xros-install-gui-rs/src/app.rs; then ok "gui: --step ограничен шагом 8 (Finish недоступен напрямую)"; else bad "gui: --step не ограничен"; fi
# fixed5 (10.11.2026): окно установщика открывается развёрнутым —
# без этого KWin ставил 960x600 со смещением (x≈475 при 1280x800),
# и кнопки «Назад»/«Продолжить» оказывались за экраном.
if grep -q 'with_maximized(true)' src/xros-install-gui-rs/src/main.rs; then ok "gui: окно открывается развёрнутым (with_maximized)"; else bad "gui: нет with_maximized — окно может открыться за экраном"; fi
if grep -q 'mode(0o600)' src/xros-install-gui-rs/src/install.rs; then ok "gui: конфиг установки 0600 с момента создания"; else bad "gui: конфиг установки не 0600"; fi
if grep -q 'add_enabled(!self.installing' src/xros-install-gui-rs/src/app.rs; then ok "gui: кнопки навигации блокируются во время установки"; else bad "gui: навигация не блокируется во время установки"; fi

# ---------------------------------------------------------------- 18. profiledef
for kv in 'iso_name="xros"' 'iso_label="XROS_202611"' 'install_dir="xros"'; do
  if grep -qF "$kv" profile/profiledef.sh; then ok "profiledef: $kv"; else bad "profiledef: нет $kv"; fi
done

# ---------------------------------------------------------------- 19. Финальная доработка (10.11.2026, задача 8)
# Проверки добавлены по ТЗ финальной доработки; каждая реально
# выполняется (grep/test/cmp/sha256sum/awk), а не ищет маркер.
# SKIP здесь не используется: отсутствие механизма — это FAIL.

# 19а. Нет неработающих пунктов GRUB: целевое состояние — пунктов
# Memtest86+/UEFI Shell нет вообще (пакеты memtest86+-efi/edk2-shell
# не входят в профиль, пункты намеренно убраны из меню). Если пункт
# есть, он обязан стоять под search-стражем (search --file --set=):
# проверки -f НЕ годятся — модуля test нет в UEFI-образе mkarchiso,
# [ -f ... ] там всегда ложна (см. experiments/uefi-test-module/).
# Комментарии не считаются: ссылка на edk2-shell ищется только
# в кодовых (не `#`) строках.
for cfg in profile/grub/grub.cfg profile/grub/loopback.cfg; do
  n_entries=$(grep -cE "menuentry.*(Memtest|memtest|UEFI Shell)" "$cfg" || true)
  if [[ "$n_entries" -eq 0 ]]; then
    ok "$cfg: пунктов Memtest/Shell нет (намеренно отсутствуют)"
  else
    guard_bad=0
    while IFS=: read -r ln _; do
      start=$(( ln > 5 ? ln - 5 : 1 ))
      if ! sed -n "${start},$((ln-1))p" "$cfg" | grep -q 'search --file --set='; then
        echo "  $cfg:$ln: пункт меню без search-стража"; guard_bad=1
      fi
    done < <(grep -nE "menuentry.*(Memtest|memtest|UEFI Shell)" "$cfg")
    if [[ $guard_bad -eq 0 ]]; then ok "$cfg: пункты Memtest/Shell защищены search --file"; else bad "$cfg: пункты Memtest/Shell без search-стража (-f не работает на UEFI)"; fi
  fi
  if grep -vE '^\s*#' "$cfg" | grep -qiE 'edk2-shell'; then
    bad "$cfg: есть кодовая ссылка на edk2-shell"
  else
    ok "$cfg: нет кодовых ссылок на edk2-shell"
  fi
done

# 19б. Загрузочная архитектура: наборы пунктов меню grub.cfg и
# loopback.cfg совпадают (--id), нигде нет syslinux/systemd-boot/
# efiboot, loopback несёт img_dev/img_loop, а живой grub.cfg —
# archisobasedir без img_dev (параметры loopback только для
# загрузки ISO-файла с диска).
ids_grub=$(grep -oE " --id '[^']+'" profile/grub/grub.cfg | sort)
ids_loop=$(grep -oE " --id '[^']+'" profile/grub/loopback.cfg | sort)
if [[ "$ids_grub" == "$ids_loop" ]]; then ok "grub.cfg/loopback.cfg: наборы --id совпадают"; else bad "grub.cfg/loopback.cfg: наборы --id различаются"; fi
if grep -qiE 'syslinux|systemd-boot|efiboot' profile/grub/grub.cfg profile/grub/loopback.cfg; then
  bad "grub.cfg/loopback.cfg: есть syslinux/systemd-boot/efiboot"
else
  ok "grub.cfg/loopback.cfg: нет syslinux/systemd-boot/efiboot"
fi
if grep -q 'img_dev=' profile/grub/loopback.cfg && grep -q 'img_loop=' profile/grub/loopback.cfg; then
  ok "loopback.cfg: есть img_dev= и img_loop="
else
  bad "loopback.cfg: нет img_dev=/img_loop="
fi
if grep -q 'archisobasedir=' profile/grub/grub.cfg && ! grep -q 'img_dev=' profile/grub/grub.cfg; then
  ok "grub.cfg: archisobasedir есть, img_dev нет (живая загрузка)"
else
  bad "grub.cfg: archisobasedir/img_dev не в порядке"
fi

# 19в. Сервисы приветствия (модель autostart-only,
# docs/final-refinement/welcome-wayland.md): если service-файлы
# где-то ещё есть — в них не должно быть DISPLAY=:0/XAUTHORITY,
# обязателен After=graphical-session.target; если их нет нигде —
# это целевое состояние. Плюс flock в GUI и защитные удаления
# в движке, плюс отсутствие .xprofile.
svc_pkg=packages/xros-welcome/xros-welcome.service
svc_ai=profile/airootfs/etc/systemd/user/xros-welcome.service
if [[ -e "$svc_pkg" || -e "$svc_ai" ]]; then
  if grep -qE 'DISPLAY=:0|XAUTHORITY' "$svc_pkg" "$svc_ai" 2>/dev/null; then
    bad "xros-welcome.service: есть DISPLAY=:0/XAUTHORITY (X11-наследие)"
  else
    ok "xros-welcome.service: нет DISPLAY=:0/XAUTHORITY"
  fi
  if grep -q 'After=graphical-session.target' "$svc_pkg" "$svc_ai" 2>/dev/null; then
    ok "xros-welcome.service: есть After=graphical-session.target"
  else
    bad "xros-welcome.service: нет After=graphical-session.target"
  fi
else
  ok "xros-welcome.service отсутствует (модель autostart-only)"
fi
if [[ -f profile/airootfs/etc/xdg/autostart/xros-welcome.desktop && -f packages/xros-welcome/xros-welcome.desktop ]]; then
  ok "autostart .desktop приветствия есть (airootfs + пакет)"
else
  bad "autostart .desktop приветствия отсутствует"
fi
flock_bad=0
for f in src/xros-welcome-gui packages/xros-welcome/xros-welcome-gui profile/airootfs/usr/local/bin/xros-welcome-gui; do
  grep -q 'flock' "$f" 2>/dev/null || { echo "  нет flock: $f"; flock_bad=1; }
done
if [[ $flock_bad -eq 0 ]]; then ok "xros-welcome-gui: flock во всех копиях"; else bad "xros-welcome-gui: нет flock"; fi
if grep -qF 'rm -f "$TARGET/etc/xdg/autostart/xros-welcome.desktop"' src/xros-install \
   && grep -qF 'rm -rf "$TARGET/etc/systemd/user/xros-welcome.service"' src/xros-install; then
  ok "движок: защитные удаления приветствия из целевой системы"
else
  bad "движок: нет защитных удалений приветствия"
fi
if [[ ! -e profile/airootfs/home/xros/.xprofile && ! -e profile/airootfs/etc/skel/.xprofile ]]; then
  ok ".xprofile отсутствует (мёртв под Wayland)"
else
  bad ".xprofile всё ещё на месте"
fi

# 19г. Зависимость от чужого chroot: правило — в scripts/ упоминаний
# akvt/АКВТ быть не должно вообще (исключение для build.sh УДАЛЕНО
# 10.11.2026: строка с путём к chroot другого проекта убрана вместе
# с заменой зависимости на собственный build-env). В ARCHITECTURE.md/
# AUDIT-REPORT.md упоминания допустимы как история (этот скрипт их
# там не проверяет, см. §6).
akvt_rest=$(grep -rIn --exclude-dir=.git --exclude=xros-diagnose.sh -E 'akvt|АКВТ' scripts/ 2>/dev/null || true)
if [[ -z "$akvt_rest" ]]; then
  ok "scripts/: нет упоминаний другого проекта"
else
  echo "$akvt_rest"; bad "scripts/: есть упоминания другого проекта"
fi

# 19д. Синхронность брендинга по SHA256 (канон: branding/),
# включая banner.txt (см. AUDIT-REPORT.md E10 — исходник заведён).
if [[ -f branding/banner.txt ]]; then ok "есть branding/banner.txt"; else bad "нет branding/banner.txt"; fi
for f in xros-logo.png xros-logo-small.png wallpaper.png wallpaper.jpg grub-bg.jpg grub-bg.png banner.txt; do
  s1=$(sha256sum "branding/$f" 2>/dev/null | cut -d' ' -f1)
  s2=$(sha256sum "profile/airootfs/usr/share/xros/$f" 2>/dev/null | cut -d' ' -f1)
  s3=$(sha256sum "packages/xros-branding/$f" 2>/dev/null | cut -d' ' -f1)
  if [[ -n "$s1" && "$s1" == "$s2" && "$s2" == "$s3" ]]; then
    ok "sha256 $f: branding == airootfs == пакет"
  else
    bad "sha256 $f расходится (branding/airootfs/пакет)"
  fi
done

# 19е. DE=none в движке: графических пакетов нет (DE_PKGS="",
# DE_DM=""), в ветке установки нет включения DM — только disable
# всех трёх; GUI предлагает «Без графики».
none_line=$(sed -n '/^case "\$DE" in/,/^esac/p' src/xros-install | grep 'none)' || true)
if [[ "$none_line" == *'DE_PKGS=""'* && "$none_line" == *'DE_DM=""'* ]]; then
  ok "движок: DE=none → DE_PKGS=\"\" и DE_DM=\"\""
else
  bad "движок: DE=none — DE_PKGS/DE_DM не пустые"
fi
none_branch=$(sed -n '/elif \[\[ "\$DE" == "none" \]\]/,/^  else/p' src/xros-install)
if echo "$none_branch" | grep -q 'systemctl disable sddm.service' \
   && echo "$none_branch" | grep -q 'systemctl disable lightdm.service' \
   && echo "$none_branch" | grep -q 'systemctl disable gdm.service' \
   && ! echo "$none_branch" | grep -q 'systemctl enable'; then
  ok "движок: DE=none отключает все DM и не включает ни один"
else
  bad "движок: ветка DE=none — DM обрабатывается неверно"
fi
if grep -q '"none"' src/xros-install-gui-rs/src/app.rs; then
  ok "GUI: предлагает «Без графики» (DE=none)"
else
  bad "GUI: нет варианта DE=none"
fi

# 19ж. Старых цветов нет в docs/ (индиго/циан из старой концепции).
# Исключение — docs/final-refinement/branding.md: там старые цвета
# упомянуты только как ЗАПРЕЩЁННЫЕ (историческая запись о бане,
# та же категория, что и AUDIT-REPORT.md в §11); сам скрипт
# из проверки исключён, как в §11.
if grep -rIi --exclude-dir=.git --exclude=branding.md -E '6C5CE7|22D3EE|9333EA|A855F7|6B21A8' docs/ 2>/dev/null | grep .; then
  bad "docs/: остались старые цвета"
else
  ok "docs/: старых цветов нет (кроме исторической записи в branding.md)"
fi

# 19з. Ложные URL: каждое упоминание xros.example обязано иметь
# PLACEHOLDER на той же строке, либо в пределах 15 строк выше
# или 2 строк ниже (комментарий-заголовок секции); AUDIT-REPORT.md
# исключён (там заглушка обсуждается как решение), сам этот
# скрипт — тоже (в нём паттерн grep).
ph_bad=0
while IFS= read -r -d '' f; do
  mapfile -t ph_lines < <(grep -n 'PLACEHOLDER' "$f" | cut -d: -f1)
  while IFS=: read -r ln _; do
    sed -n "${ln}p" "$f" | grep -q 'PLACEHOLDER' && continue
    near=0
    for pl in "${ph_lines[@]}"; do
      if (( pl >= ln - 15 && pl <= ln + 2 )); then near=1; break; fi
    done
    if (( near == 0 )); then echo "  xros.example без PLACEHOLDER рядом: $f:$ln"; ph_bad=1; fi
  done < <(grep -n 'xros.example' "$f")
done < <(grep -rIl --exclude-dir=.git --exclude=AUDIT-REPORT.md --exclude=xros-diagnose.sh 'xros.example' profile src packages scripts branding repo preview docs README.md ARCHITECTURE.md 2>/dev/null | tr '\n' '\0')
if [[ $ph_bad -eq 0 ]]; then ok "xros.example везде с PLACEHOLDER рядом"; else bad "xros.example без PLACEHOLDER рядом"; fi

# 19и. Фиктивные функции: маркеры-заглушки TODO/FIXME/not implemented/
# unimplemented в src/, scripts/, packages/, profile/. Протокол
# dialog-gauge «XXX» — не заглушка и в паттерн не входит.
# Известные на 10.11.2026: build.sh:88 (сборка ISO — этап 10, скрипт
# намеренно завершается exit 3) и TODO в mkinitcpio.conf.d/archiso.conf
# (сверить с пакетом mkinitcpio-archiso) — оба задокументированы,
# но пока не закрыты, поэтому проверка даёт FAIL, а не SKIP.
if grep -rniE --exclude-dir=.git --exclude=xros-diagnose.sh 'TODO|FIXME|not implemented|unimplemented' src scripts packages profile 2>/dev/null | grep .; then
  bad "маркеры-заглушки TODO/FIXME/not implemented (см. список выше)"
else
  ok "маркеров-заглушек нет"
fi

# 19й. Синхронность исходников, пакетов и airootfs:
# (а) каждый файл из source= каждого PKGBUILD лежит рядом с ним;
# (б) набор файлов в собранном пакете (по xros.files.tar.gz)
# совпадает с тем, что ставит package() текущего PKGBUILD, —
# расхождение означает, что пакет в repo/ устарел и нужна
# пересборка (makepkg + repo-add).
for p in xros-cli xros-installer xros-welcome xros-branding; do
  if (cd "packages/$p" && source ./PKGBUILD >/dev/null 2>&1 && for s in "${source[@]}"; do [[ -f "$s" ]] || exit 1; done); then
    ok "PKGBUILD $p: все source-файлы на месте"
  else
    bad "PKGBUILD $p: не хватает source-файлов"
  fi
done
files_tmp=$(mktemp -d)
tar xzf repo/xros/os/x86_64/xros.files.tar.gz -C "$files_tmp" 2>/dev/null
for p in xros-cli xros-installer xros-welcome xros-branding; do
  db_files=$(ls -d "$files_tmp/$p"-*/files 2>/dev/null | head -1)
  if [[ -z "$db_files" ]]; then bad "repo DB: нет списка файлов $p"; continue; fi
  db_list=$(grep -v '^%FILES%$' "$db_files" | grep -v '/$' | sort)
  pkg_list=$(awk '/^package\(\)/,/^}/' "packages/$p/PKGBUILD" | grep -o '\$pkgdir/[^ "]*' | sed 's|\$pkgdir/||' | sort -u)
  if [[ "$db_list" == "$pkg_list" ]]; then
    ok "repo: файлы пакета $p совпадают с package()"
  else
    echo "  $p: в БД есть, а в package() нет: $(comm -23 <(echo "$db_list") <(echo "$pkg_list") | tr '\n' ' ')"
    echo "  $p: в package() есть, а в БД нет: $(comm -13 <(echo "$db_list") <(echo "$pkg_list") | tr '\n' ' ')"
    bad "repo: пакет $p устарел относительно PKGBUILD — нужна пересборка"
  fi
done
rm -rf "$files_tmp"

# 19к. Завершение GUI: PDEATHSIG + pre_exec + setsid в install.rs,
# InstallHandle с отменой группе и Drop-страховкой, использование
# ручки в app.rs. Зависит от работы параллельного агента по GUI.
if grep -q 'PR_SET_PDEATHSIG' src/xros-install-gui-rs/src/install.rs \
   && grep -q 'pre_exec' src/xros-install-gui-rs/src/install.rs \
   && grep -q 'setsid' src/xros-install-gui-rs/src/install.rs \
   && grep -q 'impl Drop for InstallHandle' src/xros-install-gui-rs/src/install.rs \
   && grep -q 'InstallHandle' src/xros-install-gui-rs/src/app.rs \
   && grep -q '\.cancel()' src/xros-install-gui-rs/src/app.rs; then
  ok "GUI: PDEATHSIG + process group + отмена (InstallHandle)"
else
  bad "GUI: нет PDEATHSIG/pre_exec/process-group (см. install.rs)"
fi

# 19л. Завершение GUI, вторая половина: движок обязан ловить SIGTERM
# ловушкой trap (cleanup + выход 143) — комментарий в install.rs
# это предполагает. Отсутствие ловушки — FAIL, а не SKIP.
# Формы записи: trap '...' TERM (краткая) и trap '...' SIGTERM (полная),
# плюс EXIT-ловушка сторожа — подходят обе.
if grep -qE "^trap '[^']*' (HUP|INT|TERM|EXIT)|^trap '[^']*' (SIGHUP|SIGINT|SIGTERM|EXIT)" src/xros-install; then
  ok "движок: есть trap на SIGTERM/EXIT"
else
  bad "движок: нет trap на SIGTERM/EXIT (GUI предполагает ловушку)"
fi

# 19м. install.rs: нет дублей pub const (повторное определение
# роняет cargo check с E0428; ловится grep, а не сборкой).
dup_const=0
for c in INSTALLER CONF LOGFILE; do
  n=$(grep -c "pub const $c" src/xros-install-gui-rs/src/install.rs || true)
  if [[ "$n" -ne 1 ]]; then echo "  pub const $c встречается $n раз"; dup_const=1; fi
done
if [[ $dup_const -eq 0 ]]; then ok "install.rs: pub const без дублей"; else bad "install.rs: дубли pub const"; fi

# ---------------------------------------------------------------- 20. Финальный этап подготовки к первой сборке ISO (10.11.2026)
# Проверки добавлены по ТЗ финальной консолидации; каждая реально
# выполняется (ls/cmp/sha256sum/grep/запуск тестов/--exec в build-env),
# а не ищет маркер. Тесты установщика ЗАПУСКАЮТСЯ (а не проверяются
# на наличие): их PASS/FAIL — настоящий результат прогона.
# Время: тесты занимают ~70 с (child-process 28 с + extended 38 с).

# 20а. Build environment: rootfs, маркеры init, builder, версии инструментов.
if [[ -d build-env/root.x86_64/usr/bin ]]; then ok "build-env: rootfs существует"; else bad "build-env: нет rootfs (нужен scripts/xros-build-env.sh --init)"; fi
if [[ -f build-env/state/init-done ]]; then ok "build-env: маркер state/init-done"; else bad "build-env: нет state/init-done"; fi
if [[ -f build-env/state/deps-fetched ]]; then ok "build-env: маркер state/deps-fetched"; else bad "build-env: нет state/deps-fetched"; fi
if grep -q '^builder:x:1000:1000:' build-env/root.x86_64/etc/passwd 2>/dev/null; then ok "build-env: builder uid 1000 в rootfs"; else bad "build-env: нет builder uid 1000"; fi
if [[ -f build-env/archlinux-bootstrap-x86_64.tar.zst && -f build-env/archlinux-bootstrap-x86_64.tar.zst.sig ]]; then
  ok "build-env: bootstrap-тарбол + подпись на месте"
else
  bad "build-env: нет bootstrap-тарбола/подписи"
fi
rootfs_size=$(du -sb build-env/root.x86_64 2>/dev/null | cut -f1)
if [[ "${rootfs_size:-0}" -ge 1000000000 ]]; then ok "build-env: rootfs >= 1 ГБ ($((rootfs_size/1024/1024)) МБ)"; else bad "build-env: rootfs подозрительно мал ($((rootfs_size/1024/1024)) МБ)"; fi
if benv_ver=$(./scripts/xros-build-env.sh --exec -- bash -c 'rustc --version; cargo --version; grub-install --version | head -1; pacman --version | head -2 | tail -1' 2>/dev/null); then
  echo "$benv_ver" | grep -q 'rustc 1.99.1' && ok "build-env: rustc 1.99.1 в rootfs" || bad "build-env: rustc не 1.99.1"
  echo "$benv_ver" | grep -q 'cargo 1.99.1' && ok "build-env: cargo 1.99.1 в rootfs" || bad "build-env: cargo не 1.99.1"
  echo "$benv_ver" | grep -q 'GRUB. 2:2.16' && ok "build-env: GRUB 2.16 в rootfs" || bad "build-env: GRUB не 2.16"
  echo "$benv_ver" | grep -q 'Pacman v7.1.0' && ok "build-env: pacman 7.1.0 в rootfs" || bad "build-env: pacman не 7.1.0"
else
  bad "build-env: --exec не работает (нельзя проверить версии инструментов)"
fi

# 20б. Независимость от чужих проектов: ссылки на другой проект
# в скриптах сборки и в build-env (кроме самого rootfs).
if [[ -z "$(grep -rIn --exclude-dir=.git --exclude=xros-diagnose.sh -E 'akvt-os|/workspace/akvt' scripts/ build-env/ --exclude-dir=root.x86_64 2>/dev/null || true)" ]]; then
  ok "независимость: нет ссылок на akvt-os в scripts/ и build-env/"
else
  bad "независимость: есть ссылки на akvt-os в scripts/ или build-env/"
fi

# 20в. BIOS-GRUB: экспериментальный образ и логи QEMU на месте,
# profiledef по-прежнему без bios.syslinux (вариант Б НЕ внедрён).
bios_iso="experiments/bios-grub-test/out/xros-bios-test.iso"
if [[ -f "$bios_iso" ]]; then
  bios_sha=$(sha256sum "$bios_iso" | cut -d' ' -f1)
  if [[ "$bios_sha" == "1e29fe9909c673d81a9e42d8312e08454c9ac433b4ff64a8b12da42ad281399d" ]]; then
    ok "BIOS-GRUB: тестовый ISO на месте, sha256 1e29fe99… совпадает"
  else
    bad "BIOS-GRUB: sha256 тестового ISO не совпадает (файл изменён после QEMU-тестов)"
  fi
else
  bad "BIOS-GRUB: нет тестового ISO experiments/bios-grub-test/out/xros-bios-test.iso"
fi
bios_logs_ok=1
for f in bios-serial.log uefi-serial.log usb-serial.log bios-menu.png uefi-menu.png usb-menu.png; do
  [[ -f "experiments/bios-grub-test/logs/$f" ]] || { echo "  нет лога BIOS-теста: $f"; bios_logs_ok=0; }
done
if [[ $bios_logs_ok -eq 1 ]]; then ok "BIOS-GRUB: все 3 serial-лога и 3 скриншота меню на месте"; else bad "BIOS-GRUB: не хватает логов/скриншотов QEMU-тестов"; fi
if grep -E "^bootmodes=" profile/profiledef.sh | grep -q 'bios.syslinux'; then
  bad "profiledef: bios.syslinux в bootmodes (вариант Б не должен внедряться без решения)"
else
  ok "profiledef: в bootmodes нет bios.syslinux (вариант Б не внедрён)"
fi

# 20г. UEFI GRUB: дефект test-модуля исправлен (10.11.2026).
# В UEFI-образе mkarchiso 92 нет модуля test: любая проверка [ ... ]
# там ложна. Исправление: тема/фон — безусловно, платформа — regexp.
# Доказательство — эксперимент experiments/uefi-test-module/ (QEMU):
# логи ДО исправления содержат ошибки test.mod, ПОСЛЕ — ноль.
for cfg in profile/grub/grub.cfg profile/grub/loopback.cfg; do
  if grep -vE '^\s*#' "$cfg" | grep -q '\['; then
    bad "$cfg: есть [ ... ] в коде (модуля test нет на UEFI)"
  else
    ok "$cfg: нет [ ... ] в коде"
  fi
  if grep -q "regexp '\^efi\$'" "$cfg" && grep -q "regexp '\^pc\$'" "$cfg"; then
    ok "$cfg: платформа определяется через regexp"
  else
    bad "$cfg: нет regexp-проверок платформы"
  fi
  if grep -q '^set theme=/boot/grub/theme/theme.txt' "$cfg" && grep -q '^background_image /boot/grub/grub-bg.jpg' "$cfg"; then
    ok "$cfg: тема/фон грузятся безусловно"
  else
    bad "$cfg: тема/фон не грузятся безусловно"
  fi
done
uefi_after="experiments/uefi-test-module/logs/after/uefi-serial.log"
uefi_before="experiments/uefi-test-module/logs/before/uefi-serial.log"
if [[ -f "experiments/uefi-test-module/out/xros-uefi-test.iso" ]]; then
  ok "UEFI-тест: тестовый ISO на месте"
else
  bad "UEFI-тест: нет тестового ISO experiments/uefi-test-module/out/xros-uefi-test.iso"
fi
if [[ -f "$uefi_before" ]] && grep -q 'test.mod' "$uefi_before"; then
  ok "UEFI-тест: ДО исправления ошибки test.mod зафиксированы (дефект доказан)"
else
  bad "UEFI-тест: нет доказательства дефекта (before-лог без ошибок test.mod)"
fi
if [[ -f "$uefi_after" ]]; then
  if grep -q 'test.mod' "$uefi_after"; then
    bad "UEFI-тест: ПОСЛЕ исправления всё ещё есть ошибки test.mod"
  else
    ok "UEFI-тест: ПОСЛЕ исправления 0 ошибок test.mod"
  fi
  if grep -q 'XrOS 1.0 (%ARCH%, UEFI)' "$uefi_after"; then
    ok "UEFI-тест: заголовок меню — UEFI (regexp работает)"
  else
    bad "UEFI-тест: в after-логе нет заголовка с UEFI"
  fi
else
  bad "UEFI-тест: нет after-лога experiments/uefi-test-module/logs/after/uefi-serial.log"
fi

# 20д. Процессы установщика / отмена: тесты ЗАПУСКАЮТСЯ, их итог —
# настоящий результат прогона (не захардкоженный PASS).
for t in test-child-process.sh test-child-process-extended.sh; do
  if [[ -x "scripts/tests/$t" ]]; then
    if tout=$(./scripts/tests/$t 2>&1); then
      tsum=$(echo "$tout" | grep -oE 'PASS=[0-9]+ FAIL=0( SKIP=[0-9]+)?' | head -1)
      ok "тест $t пройден ($tsum)"
    else
      echo "$tout" | tail -5; bad "тест $t НЕ пройден"
    fi
  else
    bad "тест $t отсутствует или не исполняемый"
  fi
done

# 20е. Wayland autostart: нет DISPLAY/XAUTHORITY в сервисах приветствия,
# .desktop автозапуска на месте с правильным Exec.
# Проверяются только кодовые (не `#`) строки: в комментариях .desktop
# и xros-welcome-gui эти переменные упомянуты как УДАЛЁННЫЕ.
display_legacy=0
for f in packages/xros-welcome/xros-welcome.desktop packages/xros-welcome/xros-welcome-gui profile/airootfs/etc/systemd/user/xros-welcome.service; do
  [[ -f "$f" ]] || continue
  grep -vE '^\s*#' "$f" 2>/dev/null | grep -qE 'DISPLAY=:0|XAUTHORITY' && { echo "  DISPLAY/XAUTHORITY в коде: $f"; display_legacy=1; }
done
if [[ $display_legacy -eq 0 ]]; then
  ok "приветствие: нет DISPLAY=:0/XAUTHORITY в коде"
else
  bad "приветствие: есть DISPLAY=:0/XAUTHORITY (X11-наследие)"
fi
if grep -q '^Exec=/usr/local/bin/xros-welcome-gui' profile/airootfs/etc/xdg/autostart/xros-welcome.desktop; then
  ok "autostart .desktop: Exec=/usr/local/bin/xros-welcome-gui"
else
  bad "autostart .desktop: нет Exec=xros-welcome-gui"
fi

# 20ж. X11-наследие: в не-комментарных строках конфигов airootfs нет
# DISPLAY, нет .xprofile, нет startx/xinit в автозапуске.
display_code=0
while IFS= read -r -d '' f; do
  grep -vE '^\s*#' "$f" 2>/dev/null | grep -q 'DISPLAY' && { echo "  DISPLAY в коде: $f"; display_code=1; }
done < <(find profile/airootfs/etc -type f -print0 2>/dev/null)
if [[ $display_code -eq 0 ]]; then
  ok "airootfs/etc: нет DISPLAY в коде (только в комментариях)"
else
  bad "airootfs/etc: есть DISPLAY в коде (не в комментариях)"
fi
if grep -rIl 'startx\|xinit' profile/airootfs/etc/xdg/ 2>/dev/null | grep .; then
  bad "autostart: есть startx/xinit"
else
  ok "autostart: нет startx/xinit"
fi

# 20з. DE=none: отчёт с реальными цифрами + список графики + тест.
if [[ -s docs/de-none-package-lists.md ]]; then
  if grep -q '644' docs/de-none-package-lists.md && grep -q '211' docs/de-none-package-lists.md && grep -q '433' docs/de-none-package-lists.md; then
    ok "DE=none: отчёт docs/de-none-package-lists.md с цифрами 644/211/433"
  else
    bad "DE=none: в отчёте нет цифр 644/211/433"
  fi
else
  bad "DE=none: нет отчёта docs/de-none-package-lists.md"
fi
gfx_list=$(sed -n 's/^XROS_GRAPHICS_PKGS="\(.*\)"/\1/p' src/xros-install | head -1)
gfx_n=$(echo "$gfx_list" | wc -w)
if [[ "$gfx_n" -eq 15 ]]; then ok "XROS_GRAPHICS_PKGS: 15 пакетов"; else bad "XROS_GRAPHICS_PKGS: пакетов $gfx_n, ожидалось 15"; fi
if [[ -x scripts/tests/test-de-none.sh ]]; then
  if tout=$(./scripts/tests/test-de-none.sh 2>&1); then
    tsum=$(echo "$tout" | grep -oE 'PASS=[0-9]+ FAIL=0' | head -1)
    ok "тест test-de-none.sh пройден ($tsum)"
  else
    echo "$tout" | tail -5; bad "тест test-de-none.sh НЕ пройден"
  fi
else
  bad "тест test-de-none.sh отсутствует или не исполняемый"
fi

# 20и. Пакетные списки: 46 пакетов живой системы; все 16 графических
# пакетов из XROS_GRAPHICS_PKGS входят в packages.x86_64.
pkgs_now=$(grep -v '^\s*#' profile/packages.x86_64 | grep -v '^\s*$' || true)
pkg_n=$(echo "$pkgs_now" | wc -l)
if [[ "$pkg_n" -eq 46 ]]; then ok "packages.x86_64: 46 пакетов"; else bad "packages.x86_64: пакетов $pkg_n, ожидалось 46"; fi
gfx_missing=""
for p in $gfx_list; do
  echo "$pkgs_now" | grep -qx "$p" || gfx_missing="$gfx_missing $p"
done
if [[ -z "$gfx_missing" ]]; then
  ok "XROS_GRAPHICS_PKGS: все 15 пакетов есть в packages.x86_64"
else
  bad "XROS_GRAPHICS_PKGS: нет в packages.x86_64:$gfx_missing"
fi

# 20й. Репозиторий: 4 собранных пакета в repo/ (плюс БД — см. §13).
n_repo_pkg=$(ls repo/xros/os/x86_64/*.pkg.tar.zst 2>/dev/null | wc -l)
if [[ "$n_repo_pkg" -eq 4 ]]; then ok "repo: 4 .pkg.tar.zst"; else bad "repo: пакетов $n_repo_pkg, ожидалось 4"; fi

# 20к. Безопасность: тест ЗАПУСКАЕТСЯ; пароли не попадают в логи.
if [[ -x scripts/tests/test-installer-security.sh ]]; then
  if tout=$(./scripts/tests/test-installer-security.sh 2>&1); then
    tsum=$(echo "$tout" | grep -oE 'PASS=[0-9]+ FAIL=0( SKIP=[0-9]+)?' | head -1)
    ok "тест test-installer-security.sh пройден ($tsum)"
  else
    echo "$tout" | tail -5; bad "тест test-installer-security.sh НЕ пройден"
  fi
else
  bad "тест test-installer-security.sh отсутствует или не исполняемый"
fi
if [[ -f docs/final-refinement/security-audit-2.md ]]; then ok "есть docs/final-refinement/security-audit-2.md"; else bad "нет docs/final-refinement/security-audit-2.md"; fi
if grep -rIiE 'password[[:space:]]*=' build-env/logs/ 2>/dev/null | grep .; then
  bad "в логах build-env есть password="
else
  ok "в логах build-env нет password="
fi
if grep -q 'set -x' src/xros-install; then
  bad "движок: есть set -x (команды с паролями попали бы в лог)"
else
  ok "движок: нет set -x"
fi
if grep -qE 'say .*(USERPASS|ROOTPASS)' src/xros-install; then
  bad "движок: пароль передаётся в say (пишется в лог)"
else
  ok "движок: пароль не передаётся в say"
fi

# 20л. Брендинг (дополнительно к §19д): исходники логотипа/обоев
# сохранены, бинари зафиксированы по sha256 (обновлять при пересборке).
for f in xros-logo-real.png wallpaper-real.png; do
  if [[ -f "branding/$f" ]]; then ok "есть branding/$f (исходник)"; else bad "нет branding/$f (исходник)"; fi
done
gui_sha=$(sha256sum packages/xros-installer/xros-install-gui 2>/dev/null | cut -d' ' -f1)
# fixed5 (10.11.2026): бинарь пересобран (with_maximized) — sha256 обновлён
# с f81a1b18… (fixed4) на e7350755…
# fixed7 (11.11.2026): бинарь пересобран (фокус диалога, request_focus) —
# sha256 обновлён с e7350755… (fixed5) на b533b9ff…
if [[ "$gui_sha" == "b533b9ffa2179e955f6dfcd398715c734b15949cf616e6a88794777ca394f18a" ]]; then
  ok "xros-install-gui (пакет): sha256 b533b9ff… (fixed7, 11.11.2026)"
else
  bad "xros-install-gui (пакет): sha256 не совпадает с зафиксированным e7350755…"
fi
cli_sha=$(sha256sum packages/xros-cli/xros 2>/dev/null | cut -d' ' -f1)
if [[ "$cli_sha" == "9c67cfdcc1b50998e05be1d0c9efd6d1325473731b8b7de6971ebe049954e1aa" ]]; then
  ok "xros (CLI, пакет): sha256 9c67cfdc… (зафиксирован 10.11.2026)"
else
  bad "xros (CLI, пакет): sha256 не совпадает с зафиксированным 9c67cfdc…"
fi

# ---------------------------------------------------------------- 21. Права профиля (дефект 10.11.2026, чёрный экран)
# Первопричина чёрного экрана: каталоги профиля 2770 + файлы 660
# (хост: setgid-каталоги 2770 + umask 0007) копировались в живую
# систему как есть, и не-root процессы получали EACCES на /usr и /etc:
# systemd 203/EXEC, нет D-Bus, SDDM в цикле перезапусков. Проверяется
# ИСТОЧНИК (profile/airootfs), а не собранный rootfs: проверка rootfs
# живёт в scripts/build-rootfs-pacstrap.sh (шаги 4а и 11б), потому что
# на момент шага 0 этого скрипта в work/ ещё лежит СТАРЫЙ rootfs.
# Допустимые режимы в профиле: каталоги 755, /root 750; файлы 644/755.
# Файл, которому правда нужен ограниченный режим, должен быть внесён
# в file_permissions в profiledef.sh (тогда его задаёт сборка, а не
# исходный режим в профиле) — иначе эта проверка его отклонит.
bad_dirs=$(find profile/airootfs -type d ! -perm 755 ! -path 'profile/airootfs/root' 2>/dev/null)
if [[ -z "$bad_dirs" ]]; then
  ok "профиль: все каталоги 755 (кроме /root)"
else
  echo "$bad_dirs" | head -5
  bad "профиль: есть каталоги не 755 (кроме /root): $(echo "$bad_dirs" | wc -l) шт."
fi
if [[ "$(stat -c %a profile/airootfs/root)" == "750" ]]; then
  ok "профиль: /root 750"
else
  bad "профиль: /root не 750 (сейчас $(stat -c %a profile/airootfs/root))"
fi
if [[ "$(stat -c %a profile/airootfs)" == "755" ]]; then
  ok "профиль: сам profile/airootfs 755"
else
  bad "профиль: сам profile/airootfs не 755 (сейчас $(stat -c %a profile/airootfs))"
fi
bad_files=$(find profile/airootfs -type f ! -perm 644 ! -perm 755 2>/dev/null)
if [[ -z "$bad_files" ]]; then
  ok "профиль: все файлы 644/755 (нет 660/770/640)"
else
  echo "$bad_files" | head -5
  bad "профиль: есть файлы не 644/755: $(echo "$bad_files" | wc -l) шт."
fi
if [[ -z "$(find profile/airootfs -type d -perm 2770 2>/dev/null)" ]]; then
  ok "профиль: каталогов 2770 нет"
else
  bad "профиль: есть каталоги 2770 (дефект чёрного экрана)"
fi
if [[ -z "$(find profile/airootfs -type f -perm 660 2>/dev/null)" ]]; then
  ok "профиль: файлов 660 нет"
else
  bad "профиль: есть файлы 660 (не читаются не-root)"
fi

# ---------------------------------------------------------------- 22. Раскладка рабочего стола (дефект 10.11.2026, ошибка виджета "" + зависание)
# История: минимальный appletsrc давал полноэкранную ошибку
# «error when loading applet ""» и отсутствие панели (fixed1).
# Полный appletsrc (сгенерированный Plasma + обои XrOS) Plasma 6.8
# МИГРИРУЕТ при загрузке: новый activityId, папки [1]/[2] → [21]/[22],
# коллизия с ID виджетов трея (battery=21, brightness=22) —
# plasmashell крутит 65–100% CPU, KWin зависает, рабочий стол
# не рисуется (fixed2 и fixed3 — с ПУСТЫМ и с НАСТОЯЩИМ activityId,
# миграция происходит в обоих случаях). Доказано в QEMU 10.11.2026:
# без appletsrc Plasma генерирует раскладку сама — рабочий стол,
# панель, иконка установщика работают (см. PLASMA-SESSION-REPORT.md).
# Поэтому: appletsrc НЕ поставляется нигде; обои XrOS ставит
# скрипт xros-set-wallpaper из автозапуска живого пользователя.
APPLETSRC="profile/airootfs/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
if [[ -f "$APPLETSRC" ]]; then
  bad "appletsrc: файл раскладки есть в skel — Plasma мигрирует его и зависает (см. PLASMA-SESSION-REPORT.md)"
else
  ok "appletsrc: нет файла раскладки в skel (Plasma сгенерирует сама)"
fi
if grep -rE "plasma-org\.kde\.plasma\.desktop-appletsrc" profile/airootfs/ 2>/dev/null | grep -vE "^\s*#" | grep -v "rm -f" | grep -qE "(cp|cat >|>)"; then
  bad "appletsrc: в профиле есть создание/копирование раскладки"
else
  ok "appletsrc: нет создания/копирования раскладки в профиле (комментарии и rm -f — не в счёт)"
fi
if [[ -f "profile/airootfs/usr/share/xros/wallpaper.png" ]]; then
  ok "обои: /usr/share/xros/wallpaper.png есть в профиле"
else
  bad "обои: нет /usr/share/xros/wallpaper.png в профиле"
fi
if [[ -x "profile/airootfs/usr/local/bin/xros-set-wallpaper" ]]; then
  ok "обои: скрипт xros-set-wallpaper есть и исполняемый"
else
  bad "обои: нет исполняемого скрипта xros-set-wallpaper"
fi
# Профиль копируется без сохранения режима (cp --no-preserve=mode),
# поэтому исполняемость скрипта должна быть задана в file_permissions
# profiledef.sh — иначе в rootfs он станет 644 и автозапуск не сработает
# (дефект найден при сборке fixed4, 10.11.2026).
if grep -q '"/usr/local/bin/xros-set-wallpaper"\]="0:0:755"' profile/profiledef.sh; then
  ok "обои: xros-set-wallpaper есть в file_permissions (0:0:755)"
else
  bad "обои: xros-set-wallpaper нет в file_permissions profiledef.sh (в rootfs будет 644)"
fi
if grep -q "plasma-apply-wallpaperimage" profile/airootfs/usr/local/bin/xros-set-wallpaper 2>/dev/null; then
  ok "обои: скрипт вызывает plasma-apply-wallpaperimage"
else
  bad "обои: скрипт не вызывает plasma-apply-wallpaperimage"
fi
if grep -q "xros-wallpaper.desktop" profile/airootfs/root/customize_airootfs.sh && grep -q "xros-set-wallpaper" profile/airootfs/root/customize_airootfs.sh; then
  ok "customize: автозапуск обоев для живого пользователя"
else
  bad "customize: нет автозапуска обоев для живого пользователя"
fi
if grep -q "PLASMA_EOF" profile/airootfs/root/customize_airootfs.sh; then
  bad "customize: есть отдельный heredoc appletsrc (PLASMA_EOF) — две копии расходятся"
else
  ok "customize: нет отдельного heredoc appletsrc"
fi
if [[ -f "profile/airootfs/etc/skel/.config/autostart/xros-wallpaper.desktop" ]]; then
  bad "обои: автозапуск в skel — попадёт в установленную систему и перепишет обои пользователя"
else
  ok "обои: автозапуска нет в skel (только живой пользователь)"
fi
if grep -q "Autolock=false" profile/airootfs/root/customize_airootfs.sh && grep -q "kscreenlockerrc" profile/airootfs/root/customize_airootfs.sh; then
  ok "customize: автоблокировка отключена для живого пользователя (xros без пароля)"
else
  bad "customize: нет отключения автоблокировки для живого пользователя"
fi
if grep -q "kscreenlockerrc" profile/airootfs/etc/skel/.config/* 2>/dev/null; then
  bad "skel: kscreenlockerrc не должен попадать в /etc/skel (блокировка в установленной системе — штатная)"
else
  ok "skel: kscreenlockerrc не в skel (только живой пользователь)"
fi

echo
echo "Итого: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ $FAIL -gt 0 ]]; then
  echo "Не пройдено:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
echo "Диагностика пройдена."
