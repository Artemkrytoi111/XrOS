#!/usr/bin/env bash
# XrOS — драйвер сборки ISO (этап 2: BIOS-GRUB внедрён, этап 3 — запуск).
#
# !!! НЕ ЗАПУСКАТЬ без явного разрешения Мии (сборка ISO — отдельный этап).
# Использование:
#   ./scripts/build.sh --help        # справка
#   ./scripts/build.sh --dry-run     # только печать шагов, ничего не выполняет
#   ./scripts/build.sh --confirm     # ПОЛНАЯ сборка (требует root)
#
# Что делает --confirm, по порядку (каждый шаг — с проверкой ошибок,
# set -euo pipefail + явные проверки; при ошибке любого шага — СТОП):
#   1. Финальная диагностика scripts/xros-diagnose.sh: FAIL=0, иначе стоп.
#   2. Обновление CA хоста в build-env rootfs (egress-TLS CA хоста
#      меняется при каждой перезагрузке ВМ; без свежего CA pacman
#      внутри rootfs падает с SSL-ошибкой).
#   3. Синхронизация копии профиля в build-env с актуальным profile/
#      (mkarchiso берёт профиль ТОЛЬКО из $ROOT/profile; копия в
#      build-env/root.x86_64/home/builder/profile/ — зеркало, которое
#      --makepkg обновляет при каждой сборке пакетов, а этот шаг
#      страхует от рассинхрона).
#   4. Сборка Rust (cargo build --release --offline в build-env):
#      бинари xros и xros-install-gui попадают в стейджинг пакетов.
#      --offline: кэш cargo уже предзагружен (метка deps-fetched);
#      если офлайн-сборка невозможна — стоп, сначала онлайн-сборка
#      вручную: scripts/xros-build-env.sh --build-rust
#   5. Стейджинг остальных исходников в packages/ (консольный
#      установщик, приветствие, брендинг). Свежесть staged-копий
#      дополнительно проверяет prepare() каждого PKGBUILD — несвежая
#      копия роняет makepkg, а не попадает в ISO молча.
#   6. Сборка 4 пакетов (makepkg от builder внутри rootfs).
#   7. Обновление локального репозитория (repo-add внутри rootfs).
#   8. Снимок репозитория в живую систему
#      (profile/airootfs/usr/share/xros/repo/) — без него file://-
#      источник в pacman.conf указывает в пустоту.
#   9. Бинари в живую систему (profile/airootfs/usr/local/bin/):
#      xros, xros-install-gui, xros-install, xros-welcome,
#      xros-welcome-gui. Пакеты xros-* НЕ входят в
#      profile/packages.x86_64 — в живую систему они попадают
#      именно этими копиями (репозиторий нужен для обновлений
#      после установки).
#  10. Запуск mkarchiso ВНУТРИ build-env rootfs (штатный archiso 92,
#      bootmodes=('uefi.grub')): work/ и out/ пересоздаются.
#  11. Постобработка BIOS-GRUB (scripts/postprocess-bios-grub.sh):
#      гибридный ISO с суффиксом -hybrid (исходник от mkarchiso
#      сохраняется).
#  12. Финальная проверка гибридного ISO (scripts/check-iso.sh
#      --archiso): оба El Torito, гибридный MBR, структура, SHA256.
#  13. SHA256SUMS и логи в out/.
#
# Штатный путь — mkarchiso целиком из профиля, БЕЗ ручного pacstrap
# и БЕЗ маркеров _run_once/base.* (см. ниже про рецепт другого проекта).
#
# РЕЦЕПТ ИЗ ПРАКТИКИ ДРУГОГО ARCH-ДИСТРИБУТИВА — НЕПРОВЕРЕН ДЛЯ XrOS:
# в другом проекте сборки 10–14 падали одинаково (mkarchiso pacstrap:
# десятки тысяч «Write failed» + EPERM при ПОЛНОМ списке пакетов,
# хотя ручной pacstrap того же списка работал всегда, а минимальный
# mkarchiso — тоже; эффект масштаба/порога внутри mkarchiso).
# Обход там был такой: ручной pacstrap полного списка в
# work-директорию → копирование файлов профиля в airootfs →
# customize_airootfs.sh через arch-chroot → файл версии вручную →
# mkarchiso с маркерами _run_once, пропускающими pacstrap
# (только squashfs + сборка ISO). Для XrOS этот рецепт НЕ ПРОВЕРЕН:
# список пакетов другой (KDE Plasma 6.8), версия archiso другая,
# причина падения в другом проекте не установлена. На этапе сборки
# СНАЧАЛА пробовать штатный mkarchiso; обход — только если штатный
# путь воспроизводимо падает так же, и только после разбора причины
# и с явного разрешения. Обход без разбора причины не применять.
#
# ИЗВЕСТНЫЕ РИСКИ этапа 3 (честно, до запуска):
#   * mkarchiso внутри rootfs выполняет pacstrap через вложенный
#     unshare (уже внутри unshare+chroot от xros-build-env.sh):
#     вложенные неймспейсы на этом хосте не проверялись — если
#     mkarchiso упадёт на unshare, это отдельная задача, а не повод
#     молча переходить на ручной pacstrap.
#   * mkarchiso требует сеть (pacstrap) и ~10 ГБ свободного места;
#     CA хоста обновляется шагом 2, но зеркала Arch должны быть
#     доступны через egress-прокси хоста.
#   * Полная GUI-установка на диск в QEMU после сборки — отдельный
#     тест (см. AUDIT-REPORT.md §9.7); этот драйвер только строит ISO.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/profile"
WORK="$ROOT/work"
OUT="$ROOT/out"
BUILD_ENV="$ROOT/scripts/xros-build-env.sh"
DIAGNOSE="$ROOT/scripts/xros-diagnose.sh"
POSTPROCESS="$ROOT/scripts/postprocess-bios-grub.sh"
CHECK_ISO="$ROOT/scripts/check-iso.sh"
ROOTFS="$ROOT/build-env/root.x86_64"
PROFILE_MIRROR="$ROOTFS/home/builder/profile"

STEP=0
step() { STEP=$((STEP+1)); echo; echo "=== шаг $STEP: $* ==="; }
die() { echo "build.sh: ОШИБКА: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "нет команды на хосте: $1"; }

usage() {
    sed -n '2,45p' "$0"
    echo "Использование:"
    echo "  $0 --help        справка (этот текст)"
    echo "  $0 --dry-run     только печать шагов, ничего не выполняет"
    echo "  $0 --confirm     ПОЛНАЯ сборка ISO (требует root и разрешения Мии)"
}

# --- шаги для --dry-run (только печать, без выполнения) -----------------------
DRY_STEPS=(
    "Финальная диагностика (xros-diagnose.sh): FAIL=0, иначе стоп"
    "Обновление egress-CA хоста в build-env rootfs"
    "Синхронизация копии профиля в build-env с актуальным profile/"
    "Сборка Rust --offline в build-env (xros, xros-install-gui)"
    "Стейджинг исходников в packages/ (xros-install, xros-welcome-gui, брендинг)"
    "Сборка 4 пакетов makepkg в build-env"
    "Обновление локального репозитория repo-add в build-env"
    "Снимок репозитория в profile/airootfs/usr/share/xros/repo/"
    "Бинари в profile/airootfs/usr/local/bin/ (5 файлов)"
    "rm -rf work, старые ISO в out/; mkarchiso -v -w work -o out profile (ВНУТРИ rootfs)"
    "Постобработка BIOS-GRUB -> <имя>-hybrid.iso"
    "Финальная проверка check-iso.sh --archiso гибридного ISO"
    "SHA256SUMS и логи в out/"
)

MODE="${1:-}"
case "$MODE" in
    --help|-h) usage; exit 0 ;;
    --dry-run)
        echo "build.sh --dry-run: шаги полной сборки (НИЧЕГО не выполняется):"
        i=0
        for s in "${DRY_STEPS[@]}"; do i=$((i+1)); echo "  $i. $s"; done
        echo "Для запуска: $0 --confirm (только с явного разрешения Мии)"
        exit 0
        ;;
    --confirm) ;;
    *)
        echo "Это скрипт сборки ISO. Без --confirm ничего не делает."
        echo "Использование: $0 --confirm | --dry-run | --help"
        exit 2
        ;;
esac

# --- предусловия ---------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "сборка требует root (монтирования и chroot в build-env)"
[[ -d "$ROOTFS/usr/bin" ]] || die "нет build-env rootfs: сначала scripts/xros-build-env.sh --init"
[[ -x "$BUILD_ENV" ]] || die "нет $BUILD_ENV"
[[ -f "$PROFILE/profiledef.sh" ]] || die "нет профиля: $PROFILE/profiledef.sh"
[[ -x "$DIAGNOSE" ]] || die "нет $DIAGNOSE"
[[ -x "$POSTPROCESS" ]] || die "нет $POSTPROCESS"
[[ -x "$CHECK_ISO" ]] || die "нет $CHECK_ISO"
need_cmd rsync
grep -q "bootmodes=('uefi.grub')" "$PROFILE/profiledef.sh" \
    || die "profiledef.sh: bootmodes изменился — ожидалось ('uefi.grub'); syslinux возвращать НЕЛЬЗЯ"
mkdir -p "$OUT"

# --- шаг 1: финальная диагностика ---------------------------------------------
step "Финальная диагностика (FAIL=0, иначе стоп)"
DIAG_LOG="$OUT/diagnose.log"
"$DIAGNOSE" >"$DIAG_LOG" 2>&1 || { tail -5 "$DIAG_LOG" >&2; die "диагностика завершилась с ошибкой (лог: $DIAG_LOG)"; }
DIAG_SUM="$(grep -E '^Итого: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' "$DIAG_LOG" | tail -1)"
echo "Диагностика: ${DIAG_SUM:-<нет строки итога>}"
case "$DIAG_SUM" in
    *" FAIL=0 "*) echo "Диагностика: FAIL=0 — идём дальше" ;;
    *) die "диагностика: FAIL != 0 (лог: $DIAG_LOG) — сборка остановлена" ;;
esac

# --- шаг 2: свежий egress-CA в rootfs ------------------------------------------
step "Обновление egress-CA хоста в build-env rootfs"
HOST_CA="/usr/local/share/ca-certificates/hatch-egress-ca.crt"
if [[ -f "$HOST_CA" ]]; then
    mkdir -p "$ROOTFS/etc/ca-certificates/trust-source/anchors"
    cp -L "$HOST_CA" "$ROOTFS/etc/ca-certificates/trust-source/anchors/hatch-egress-ca.crt"
    "$BUILD_ENV" --exec -- update-ca-trust extract \
        || die "update-ca-trust в rootfs не удался"
    echo "CA обновлён из $HOST_CA"
else
    echo "Файла $HOST_CA нет на хосте — пропускаю (если pacman в rootfs упадёт с SSL, проверьте CA вручную)"
fi

# --- шаг 3: синхронизация копии профиля в build-env ----------------------------
step "Синхронизация копии профиля в build-env"
[[ "$PROFILE_MIRROR" == "$ROOTFS/home/builder/profile" ]] \
    || die "внутренняя ошибка: неожиданный путь зеркала профиля"
rm -rf "$PROFILE_MIRROR"
cp -a "$PROFILE" "$PROFILE_MIRROR"
# ВАЖНО: cp -a сохраняет root-владельца файлов профиля. Но шаг 6
# (do_makepkg) чистит /home/builder/profile командой rm -rf ОТ
# пользователя builder (uid 1000, не в группе nogroup) — root-owned
# каталог 2770 он удалить не может: «Permission denied», и вся сборка
# падает на первом же пакете. Поэтому сразу отдаём зеркало builder'у
# (числовой uid:gid 1000:1000 — BUILD_UID в xros-build-env.sh).
# mkarchiso зеркало не использует (берёт /xros/profile), а
# copy_to_builder на шаге 6 всё равно перекопирует profile поверх.
chown -R 1000:1000 "$PROFILE_MIRROR"
diff -rq "$PROFILE_MIRROR" "$PROFILE" \
    || die "зеркало профиля расходится с profile/ после копирования"
echo "Зеркало профиля: 0 отличий от profile/"

# --- шаг 4: Rust ----------------------------------------------------------------
step "Сборка Rust --offline в build-env"
"$BUILD_ENV" --build-rust --offline \
    || die "сборка Rust --offline не удалась (если кэш пуст — сначала онлайн: $BUILD_ENV --build-rust)"

# --- шаг 5: стейджинг исходников в packages/ ------------------------------------
step "Стейджинг исходников в packages/"
cp "$ROOT/src/xros-install" "$ROOT/packages/xros-installer/xros-install"
cp "$ROOT/src/xros-welcome-gui" "$ROOT/packages/xros-welcome/xros-welcome-gui"
cp "$ROOT/branding/xros-logo.png" "$ROOT/branding/xros-logo-small.png" \
   "$ROOT/branding/wallpaper.png" "$ROOT/branding/wallpaper.jpg" \
   "$ROOT/branding/grub-bg.jpg" "$ROOT/branding/grub-bg.png" \
   "$ROOT/branding/banner.txt" "$ROOT/packages/xros-branding/"
# Свежесть Rust-бинарей в стейджинге проверяет prepare() PKGBUILD на шаге 6.
cmp -s "$ROOT/src/xros-install" "$ROOT/packages/xros-installer/xros-install" \
    || die "стейджинг xros-install не совпал с src/"
echo "Стейджинг готов"

# --- шаг 6: пакеты ----------------------------------------------------------------
step "Сборка 4 пакетов (makepkg в build-env)"
for pkg in xros-cli xros-installer xros-welcome xros-branding; do
    "$BUILD_ENV" --makepkg "packages/$pkg" \
        || die "makepkg packages/$pkg не удался"
done
for pkg in xros-cli xros-installer xros-welcome xros-branding; do
    ls "$ROOT/packages/$pkg"/*.pkg.tar.zst >/dev/null 2>&1 \
        || die "нет готового пакета в packages/$pkg"
done
echo "Все 4 пакета собраны"

# --- шаг 7: репозиторий ------------------------------------------------------------
step "Обновление локального репозитория (repo-add в build-env)"
"$BUILD_ENV" --exec -- bash -c 'cd /xros/repo/xros/os/x86_64 && repo-add xros.db.tar.gz *.pkg.tar.zst' \
    || die "repo-add не удался"
ls "$ROOT/repo/xros/os/x86_64/xros.db.tar.gz" >/dev/null \
    || die "нет repo/xros/os/x86_64/xros.db.tar.gz после repo-add"

# --- шаг 8: снимок репозитория в живую систему --------------------------------------
step "Снимок репозитория в profile/airootfs/usr/share/xros/repo/"
REPO_SNAP="$PROFILE/airootfs/usr/share/xros/repo"
rm -rf "$REPO_SNAP"
mkdir -p "$REPO_SNAP"
# Копирование — НЕ cp -a, по двум причинам (обе проверены 2026-11-10):
# 1) cp -a здесь падает с EPERM: на этом хосте (user namespace +
#    btrfs + setgid-родители 2770) chown для сохранения владельца
#    каталогов не проходит — «failed to preserve ownership» для
#    repo, repo/os, repo/os/x86_64, и set -e останавливает сборку.
#    Владение для снимка репозитория неважно (pacman читает его через
#    file://), поэтому --no-preserve=ownership: режим/время/ссылки
#    сохраняются, chown не делается.
# 2) mkdir -p заранее обязателен: без него cp положил бы xros НА МЕСТО
#    repo/ (repo/os/... вместо repo/xros/os/...), и pacman по
#    file:///usr/share/xros/repo/$repo/os/$arch не нашёл бы БД
#    (проверка ниже и §13в диагностики требуют именно repo/xros/...).
cp -a --no-preserve=ownership "$ROOT/repo/xros" "$REPO_SNAP/"
[[ -f "$REPO_SNAP/xros/os/x86_64/xros.db.tar.gz" ]] \
    || die "снимок репозитория не содержит xros.db.tar.gz"

# --- шаг 9: бинари в живую систему ---------------------------------------------------
step "Бинари в profile/airootfs/usr/local/bin/"
BIN_DIR="$PROFILE/airootfs/usr/local/bin"
cp "$ROOT/packages/xros-cli/xros" "$BIN_DIR/xros"
cp "$ROOT/packages/xros-installer/xros-install-gui" "$BIN_DIR/xros-install-gui"
cp "$ROOT/src/xros-install" "$BIN_DIR/xros-install"
cp "$ROOT/src/xros-welcome" "$BIN_DIR/xros-welcome"
cp "$ROOT/src/xros-welcome-gui" "$BIN_DIR/xros-welcome-gui"
chmod 755 "$BIN_DIR/xros" "$BIN_DIR/xros-install-gui" "$BIN_DIR/xros-install" \
          "$BIN_DIR/xros-welcome" "$BIN_DIR/xros-welcome-gui"
for b in xros xros-install-gui xros-install xros-welcome xros-welcome-gui; do
    [[ -x "$BIN_DIR/$b" ]] || die "нет исполняемого $BIN_DIR/$b"
done
echo "Бинари в живой системе: 5 файлов"

# --- шаг 10: mkarchiso внутри build-env rootfs ---------------------------------------
step "mkarchiso внутри build-env rootfs (штатный archiso 92)"
rm -rf "$WORK" "$OUT"/xros-*.iso
mkdir -p "$OUT"
MK_LOG="$OUT/mkarchiso.log"
# mkarchiso выполняется внутри rootfs (там archiso 92-1, grub 2.16,
# xorriso, mksquashfs); проект смонтирован в /xros. Выход — /xros/out.
"$BUILD_ENV" --exec -- mkarchiso -v -w /xros/work -o /xros/out /xros/profile >"$MK_LOG" 2>&1 \
    || { tail -30 "$MK_LOG" >&2; die "mkarchiso не удался (лог: $MK_LOG). Если падение — на pacstrap полного списка (Write failed + EPERM), СТОП: разобрать причину, ручной pacstrap и маркеры base.* — только с явного разрешения, см. шапку файла."; }
echo "mkarchiso завершён (лог: $MK_LOG)"
ISO="$(ls "$OUT"/xros-*.iso 2>/dev/null | grep -v -e '-hybrid\.iso$' | head -1)"
[[ -n "$ISO" ]] || die "mkarchiso не создал ISO в $OUT"
[[ "$(ls "$OUT"/xros-*.iso 2>/dev/null | grep -v -e '-hybrid\.iso$' | wc -l)" -eq 1 ]] \
    || die "в $OUT больше одного ISO от mkarchiso — непонятно, какой обрабатывать"
echo "ISO от mkarchiso: $ISO ($(stat -c%s "$ISO") Б)"

# --- шаг 11: постобработка BIOS-GRUB --------------------------------------------------
step "Постобработка BIOS-GRUB (гибридный ISO)"
"$POSTPROCESS" --iso "$ISO" \
    || die "постобработка BIOS-GRUB не удалась"
HYBRID="${ISO%.iso}-hybrid.iso"
[[ -f "$HYBRID" ]] || die "нет гибридного ISO: $HYBRID"
echo "Гибридный ISO: $HYBRID ($(stat -c%s "$HYBRID") Б)"

# --- шаг 12: финальная проверка --------------------------------------------------------
step "Финальная проверка гибридного ISO (check-iso.sh --archiso)"
CHECK_LOG="$OUT/check-iso.log"
"$CHECK_ISO" --archiso "$HYBRID" >"$CHECK_LOG" 2>&1 \
    || { cat "$CHECK_LOG" >&2; die "check-iso.sh: есть FAIL (лог: $CHECK_LOG)"; }
cat "$CHECK_LOG"

# --- шаг 13: SHA256 и итог ---------------------------------------------------------------
step "SHA256SUMS и итог"
(cd "$OUT" && sha256sum "$(basename "$ISO")" "$(basename "$HYBRID")" > SHA256SUMS)
echo "ГОТОВО:"
echo "  ISO mkarchiso: $ISO"
echo "  Гибридный ISO: $HYBRID"
echo "  SHA256: $(sha256sum "$HYBRID" | awk '{print $1}')"
echo "  Логи: $OUT/mkarchiso.log, $OUT/diagnose.log, $OUT/check-iso.log, $HYBRID.postprocess.log, $OUT/SHA256SUMS"
echo "  Дальше — только QEMU-тесты готового ISO (см. AUDIT-REPORT.md §9.7)."
