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
#      после установки). В конце шага — сверка хешей пакет→airootfs
#      (A-37): бинари в живой системе обязаны совпадать с пакетами.
#   9а. Нормализация прав профиля (A-02): каталоги 755, файлы 644,
#      исполняемые 755, /root 750 — до mkarchiso; гейт
#      scripts/check-rootfs-perms.sh --profile.
#   9б. Снимок репозитория [xros] в build-env rootfs
#      ($ROOTFS/usr/share/xros/repo/): pacman при pacstrap резолвит
#      file://-сервер относительно хоста (build-env rootfs), а не
#      нового корня (см. шаг 4б в build-rootfs-pacstrap.sh).
#  10. Запуск mkarchiso ВНУТРИ build-env rootfs (штатный archiso 92,
#      bootmodes=('uefi.grub')): work/ и out/ пересоздаются.
#  11. Постобработка BIOS-GRUB (scripts/postprocess-bios-grub.sh):
#      гибридный ISO с суффиксом -hybrid (исходник от mkarchiso
#      сохраняется).
#  12. SHA256SUMS для итоговых ISO (исходный + гибридный) — ДО проверки.
#  13. Финальная проверка гибридного ISO (scripts/check-iso.sh
#      --archiso --require-sha256): оба El Torito, гибридный MBR,
#      структура, SHA256. Отсутствие SHA256SUMS/записи — FAIL.
#  14. Итог и логи в out/.
#
# Режимы:
#   --confirm — штатная (dev) сборка: GPG не настроен — предупреждение,
#     SigLevel=Optional, ключ не копируется. Релизный ISO так не собрать.
#   --release — релизная сборка: сначала жёсткий гейт (release_gate):
#     FPR задан, публичный ключ проверен, [xros] SigLevel=Required
#     в обоих pacman.conf, подписи пакетов и БД проверены. Шаги 4/6/7
#     (сборка Rust, makepkg, repo-add) пропускаются — пересборка
#     аннулировала бы подписи; вместо этого проверяется свежесть
#     исходников (ни один файл src//branding/ не новее пакетов).
#     Подписание — только офлайн у владельца (scripts/sign-repo-offline.sh).
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

# umask 022 (A-02): в среде сборки umask 0007 — без этого cp/mkdir
# дают каталоги 2770 и файлы 660, которые mkarchiso уносит в живую
# систему (дефект чёрного экрана 10.11.2026). Права профиля
# дополнительно нормализуются явно перед шагом mkarchiso (шаг 9а).
umask 022

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
RELEASE=0

# Релизный гейт (A-40): релизный ISO нельзя произвести, пока production
# GPG не готов полностью. Проверяется ДО любых долгих шагов (--release).
# Условия: FPR задан и валиден; публичный ключ существует и его
# отпечаток совпадает (xros-gpg-check); [xros] SigLevel=Required
# в обоих pacman.conf; подписи всех пакетов и БД проверяются
# production-ключом (verify-repo-signatures.sh). Любой провал — die.
release_gate() {
    echo "Релизный гейт (--release): проверка готовности production GPG..."
    # shellcheck disable=SC1091
    . "$PROFILE/airootfs/usr/share/xros/xros-gpg.conf"
    [[ -n "${XROS_GPG_PROD_FPR:-}" ]] \
        || die "релизный гейт: production GPG не настроен (XROS_GPG_PROD_FPR пуст) — сначала владелец создаёт ключ офлайн (см. xros-gpg-prod/README.md)"
    [[ "${XROS_GPG_PROD_FPR}" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || die "релизный гейт: XROS_GPG_PROD_FPR не 40 hex: ${XROS_GPG_PROD_FPR}"
    local _key="$ROOT/${XROS_GPG_PROD_KEY:-xros-gpg-prod/xros-public.key}"
    [[ -f "$_key" ]] || die "релизный гейт: нет файла production-ключа: $_key"
    "$ROOT/profile/airootfs/usr/local/bin/xros-gpg-check" "$_key" "$XROS_GPG_PROD_FPR" \
        || die "релизный гейт: публичный ключ не прошёл проверку отпечатка"
    # R-01: проверка SigLevel — отдельным helper'ом (scripts/check-siglevel-
    # required.sh): прежний awk находил SigLevel = Required внутри
    # комментария (profile/pacman.conf:41) и пропускал активный Optional.
    # Helper требует ровно одну активную директиву SigLevel = Required
    # в секции [xros] в обоих файлах; комментарии и глобальная секция
    # не учитываются.
    "$ROOT/scripts/check-siglevel-required.sh" "$PROFILE/pacman.conf" "$PROFILE/airootfs/etc/pacman.conf" \
        || die "релизный гейт: в pacman.conf [xros] SigLevel не Required — верните Required только после полного подписания (см. docs/REPO-PUBLISHING.md)"
    "$ROOT/scripts/verify-repo-signatures.sh" "$ROOT/repo/xros/os/x86_64" "$_key" "$XROS_GPG_PROD_FPR" \
        || die "релизный гейт: подписи пакетов/БД не прошли проверку (см. вывод выше)"
    echo "Релизный гейт: production GPG готов (FPR $XROS_GPG_PROD_FPR, подписи проверены)"
}

usage() {
    sed -n '2,45p' "$0"
    echo "Использование:"
    echo "  $0 --help        справка (этот текст)"
    echo "  $0 --dry-run     только печать шагов, ничего не выполняет"
    echo "  $0 --confirm     ПОЛНАЯ сборка ISO (требует root и разрешения Мии)"
    echo "  $0 --release     РЕЛИЗНАЯ сборка ISO: --confirm + жёсткий GPG-гейт (требует production-ключ, подписи пакетов/БД и SigLevel=Required)"
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
    "Бинари в profile/airootfs/usr/local/bin/ (5 файлов) + сверка хешей пакет→airootfs (A-37)"
    "Нормализация прав profile/airootfs + гейт check-rootfs-perms.sh --profile (A-02)"
    "Снимок репозитория [xros] в build-env rootfs (A-12)"
    "rm -rf work, старые ISO и устаревший SHA256SUMS в out/ (A-39); mkarchiso -v -w work -o out profile (ВНУТРИ rootfs)"
    "Постобработка BIOS-GRUB -> <имя>-hybrid.iso"
    "SHA256SUMS для итоговых ISO (исходный + гибридный) — ДО проверки (A-39)"
    "Финальная проверка check-iso.sh --archiso --require-sha256 гибридного ISO"
    "Итог и логи в out/"
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
    --release) RELEASE=1 ;;
    *)
        echo "Это скрипт сборки ISO. Без --confirm/--release ничего не делает."
        echo "Использование: $0 --confirm | --release | --dry-run | --help"
        exit 2
        ;;
esac

# --- релизный гейт (только --release, до любых проверок окружения) ------------
# Проверка конфигурации GPG не зависит от build-env/root — поэтому гейт
# стоит здесь, а не перед шагом 1: ошибка конфигурации видна сразу.
if [[ "$RELEASE" -eq 1 ]]; then
    release_gate
fi

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
# mkarchiso выполняется ВНУТРИ build-env rootfs — проверяем его там
# (пакет archiso ставится в rootfs на --init, A-03), а не на хосте.
# R-11 RESUME (13.11.2026): --exec не запускает shell, поэтому
# 'command -v' (shell builtin) падает с 'exec: command: not found'
# (exit 127) даже при установленном mkarchiso. Проверка идёт через
# 'bash -c', что сохраняет исходную семантику (поиск в PATH).
"$BUILD_ENV" --exec -- bash -c 'command -v mkarchiso' >/dev/null 2>&1 \
    || die "в build-env rootfs нет mkarchiso (пакет archiso): сначала $BUILD_ENV --init"
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
# Защита от rm -rf по неожиданному пути: удаляем ТОЛЬКО строго
# внутри build-env rootfs, ожидаемое имя каталога — фиксировано.
case "$PROFILE_MIRROR" in
  "$ROOTFS"/home/builder/profile) ;;
  *) die "внутренняя ошибка: отказ удалять зеркало профиля по неожиданному пути: $PROFILE_MIRROR" ;;
esac
rm -rf -- "$PROFILE_MIRROR"
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
if [[ "$RELEASE" -eq 1 ]]; then
    echo "Релиз: сборка Rust пропущена — используются уже собранные и подписанные пакеты"
else
    # RECOVERY-01 Phase C (13.11.2026): изоляция Rust build target.
    # Отдельный target-каталог target-r11-dev-iso — повреждённый target/
    # (objcopy-инцидент R-20 E) не используется. No-stage режим: сборка
    # только проверяет, что код компилируется офлайн; официальные
    # GUI (cf3cdd2e…, 1.1, 14.11.2026) и CLI (9c67cfdc…) уже восстановлены
    # из проверенных источников и НЕ перезаписываются. После сборки —
    # fail-closed SHA-гейты: staging обязан содержать официальные бинари.
    XROS_CARGO_TARGET_DIR="target-r11-dev-iso" XROS_BUILD_NO_STAGE=1 \
        "$BUILD_ENV" --build-rust --offline \
        || die "сборка Rust --offline не удалась (если кэш пуст — сначала онлайн: $BUILD_ENV --build-rust)"
    GUI_SHA="$(sha256sum "$ROOT/packages/xros-installer/xros-install-gui" | cut -d' ' -f1)"
    [[ "$GUI_SHA" == "cf3cdd2e729580b318b6e0a6511f5eb700e76395dcf7aa073315de140545cb8c" ]] \
        || die "RECOVERY-01: GUI в staging изменён после Rust-сборки ($GUI_SHA) — ожидается официальный 1.1 cf3cdd2e…"
    CLI_SHA="$(sha256sum "$ROOT/packages/xros-cli/xros" | cut -d' ' -f1)"
    [[ "$CLI_SHA" == "9c67cfdcc1b50998e05be1d0c9efd6d1325473731b8b7de6971ebe049954e1aa" ]] \
        || die "RECOVERY-01: CLI в staging изменён после Rust-сборки ($CLI_SHA) — ожидается 9c67cfdc…"
    echo "RECOVERY-01: staging после Rust-сборки — GUI cf3cdd2e… ✓, CLI 9c67cfdc… ✓ (официальные, не перезаписаны)"
fi

# --- шаг 5: стейджинг исходников в packages/ ------------------------------------
step "Стейджинг исходников в packages/"
cp "$ROOT/src/xros-install" "$ROOT/packages/xros-installer/xros-install"
cp "$ROOT/src/xros-welcome-gui" "$ROOT/packages/xros-welcome/xros-welcome-gui"
# Diamond: staged-копия приложения для пакета xros-installer.
DIAMOND_STAGE="$ROOT/packages/xros-installer/xros-installer-diamond"
case "$DIAMOND_STAGE" in
  "$ROOT"/packages/xros-installer/xros-installer-diamond) ;;
  *) die "внутренняя ошибка: отказ удалять staged-каталог по неожиданному пути: $DIAMOND_STAGE" ;;
esac
rm -rf -- "$DIAMOND_STAGE"
cp -r "$ROOT/src/xros-installer-diamond" "$ROOT/packages/xros-installer/xros-installer-diamond"
rm -rf "$ROOT/packages/xros-installer/xros-installer-diamond/__pycache__"
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
if [[ "$RELEASE" -eq 1 ]]; then
    # Релиз: пакеты НЕ пересобираются — пересборка аннулировала бы
    # офлайн-подписи. Вместо прежней mtime-проверки (R-10: свежий
    # git clone делал исходники новее пакетов и ронял релиз всегда)
    # — manifest с хешами исходников, подписанный production-ключом
    # при офлайн-подписании (sign-repo-offline.sh, шаг 5).
    # Проверяется: подпись manifest production-ключом и побайтовое
    # совпадение текущих исходников с manifest. Mtime не используется.
    # NOTE: это верхнеуровневый код скрипта (не функция) — 'local'
    # здесь недопустим (bash: ошибка выполнения, которую bash -n
    # не ловит). Используется обычная переменная.
    _key="$ROOT/${XROS_GPG_PROD_KEY:-xros-gpg-prod/xros-public.key}"
    "$ROOT/scripts/verify-sources-manifest.sh" "$ROOT" "$ROOT/repo/xros/os/x86_64" "$_key" "$XROS_GPG_PROD_FPR" \
        || die "релиз: исходники не соответствуют подписанному manifest — пересоберите с --confirm и подпишите офлайн заново (см. docs/REPO-PUBLISHING.md)"
    echo "Релиз: пакеты не пересобираются (подписи сохранены), исходники соответствуют подписанному manifest"
else
for pkg in xros-cli xros-installer xros-welcome xros-branding; do
    "$BUILD_ENV" --makepkg "packages/$pkg" \
        || die "makepkg packages/$pkg не удался"
done
for pkg in xros-cli xros-installer xros-welcome xros-branding; do
    ls "$ROOT/packages/$pkg"/*.pkg.tar.zst >/dev/null 2>&1 \
        || die "нет готового пакета в packages/$pkg"
done
echo "Все 4 пакета собраны"
# fixed10: свежие пакеты — в локальный репозиторий (шаг 7 repo-add берёт
# *.pkg.tar.zst именно оттуда; раньше новый пакет приходилось копировать
# вручную, и репозиторий отставал от ISO на версию). Старые версии того
# же пакета удаляются; режим 644 — makepkg под umask 0007 даёт 640.
for pkg in xros-cli xros-installer xros-welcome xros-branding; do
    rm -f "$ROOT/repo/xros/os/x86_64/$pkg"-*.pkg.tar.zst
    # makepkg оставляет в packages/ ВСЕ ранее собранные версии; копировать
    # надо только свежую (иначе старые 1.0-2/3/4 возвращаются в репозиторий
    # и диагностика падает «пакетов 7, ожидалось 4» — поймано 11.11.2026).
    ls -t "$ROOT/packages/$pkg"/*.pkg.tar.zst 2>/dev/null | tail -n +2 | xargs -r rm -f
    cp "$ROOT/packages/$pkg"/*.pkg.tar.zst "$ROOT/repo/xros/os/x86_64/"
    chmod 644 "$ROOT/repo/xros/os/x86_64/$pkg"-*.pkg.tar.zst
done
echo "Пакеты скопированы в локальный репозиторий"
fi

# --- шаг 7: репозиторий ------------------------------------------------------------
step "Обновление локального репозитория (repo-add в build-env)"
if [[ "$RELEASE" -eq 1 ]]; then
    # Релиз: repo-add пропущен — он пересоздал бы БД без подписи.
    # БД и её подпись уже проверены релизным гейтом.
    [[ -f "$ROOT/repo/xros/os/x86_64/xros.db.tar.gz" ]] \
        || die "релиз: нет БД в repo/xros/os/x86_64"
    [[ -f "$ROOT/repo/xros/os/x86_64/xros.db.tar.gz.sig" ]] \
        || die "релиз: нет подписи БД в repo/xros/os/x86_64"
    echo "Релиз: repo-add пропущен — БД уже подписана офлайн"
else
    "$BUILD_ENV" --exec -- bash -c 'cd /xros/repo/xros/os/x86_64 && repo-add xros.db.tar.gz *.pkg.tar.zst' \
        || die "repo-add не удался"
    ls "$ROOT/repo/xros/os/x86_64/xros.db.tar.gz" >/dev/null \
        || die "нет repo/xros/os/x86_64/xros.db.tar.gz после repo-add"
fi

# --- шаг 8: снимок репозитория в живую систему --------------------------------------
step "Снимок репозитория в profile/airootfs/usr/share/xros/repo/"
REPO_SNAP="$PROFILE/airootfs/usr/share/xros/repo"
case "$REPO_SNAP" in
  "$ROOT"/profile/airootfs/usr/share/xros/repo) ;;
  *) die "внутренняя ошибка: отказ удалять снимок репозитория по неожиданному пути: $REPO_SNAP" ;;
esac
rm -rf -- "$REPO_SNAP"
mkdir -p "$REPO_SNAP"
# Режим снимка — 0755 явно: mkdir -p под umask 0007 даёт 0770,
# а диагностика требует 0755 (fixed10, Этап 2, 11.11.2026).
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
# A-40: production публичный ключ XrOS в живую систему — для импорта
# в customize_airootfs.sh. Тестовый ключ из xros-gpg-test/ сюда НЕ
# копируется: он только для xros-gpg-test/. Источник истины —
# profile/airootfs/usr/share/xros/xros-gpg.conf (XROS_GPG_PROD_FPR,
# XROS_GPG_PROD_KEY). Пока FPR пуст — production GPG не настроен:
# dev-сборка требует явного XROS_DEV_UNSIGNED=1 (SigLevel=Optional),
# релизная сборка (--release) блокируется гейтом на старте.
# shellcheck disable=SC1091
. "$PROFILE/airootfs/usr/share/xros/xros-gpg.conf"
if [[ -z "${XROS_GPG_PROD_FPR:-}" ]]; then
    rm -f "$PROFILE/airootfs/usr/share/xros/xros-public.key"
    # Пустой FPR = сборка с SigLevel=Optional и без проверки [xros].
    # Требуем явное согласие, чтобы пустой конфиг не давал релизный ISO.
    if [[ "${XROS_DEV_UNSIGNED:-}" != "1" ]]; then
        die "production GPG не настроен (XROS_GPG_PROD_FPR пуст в xros-gpg.conf): это dev-сборка с SigLevel=Optional и без проверки подписи [xros]. Если это осознанно — запустите с XROS_DEV_UNSIGNED=1."
    fi
    echo "ПРЕДУПРЕЖДЕНИЕ: production GPG не настроен (XROS_GPG_PROD_FPR пуст в xros-gpg.conf) — dev-режим (XROS_DEV_UNSIGNED=1): ключ XrOS не попадёт в живую систему, SigLevel=Optional; такая сборка НЕ годится для релиза"
elif [[ ! -f "$ROOT/${XROS_GPG_PROD_KEY:-xros-gpg-prod/xros-public.key}" ]]; then
    die "production GPG: XROS_GPG_PROD_FPR задан, но нет файла ключа $ROOT/${XROS_GPG_PROD_KEY:-xros-gpg-prod/xros-public.key} — положите публичный ключ (см. xros-gpg-prod/README.md)"
else
    "$ROOT/profile/airootfs/usr/local/bin/xros-gpg-check" "$ROOT/${XROS_GPG_PROD_KEY}" "$XROS_GPG_PROD_FPR" \
        || die "production GPG: публичный ключ не прошёл проверку отпечатка (см. вывод выше)"
    mkdir -p "$PROFILE/airootfs/usr/share/xros"
    cp "$ROOT/${XROS_GPG_PROD_KEY}" "$PROFILE/airootfs/usr/share/xros/xros-public.key"
    chmod 644 "$PROFILE/airootfs/usr/share/xros/xros-public.key"
    echo "Production публичный ключ XrOS скопирован в живую систему (FPR $XROS_GPG_PROD_FPR)"
fi

# --- шаг 9: бинари в живую систему ---------------------------------------------------
step "Бинари в profile/airootfs/usr/local/bin/"
BIN_DIR="$PROFILE/airootfs/usr/local/bin"
cp "$ROOT/packages/xros-cli/xros" "$BIN_DIR/xros"
cp "$ROOT/packages/xros-installer/xros-install-gui" "$BIN_DIR/xros-install-gui"
cp "$ROOT/packages/xros-installer/xros-installer-launcher" "$BIN_DIR/xros-installer-launcher"
cp "$ROOT/src/xros-install" "$BIN_DIR/xros-install"
cp "$ROOT/src/xros-welcome" "$BIN_DIR/xros-welcome"
cp "$ROOT/src/xros-welcome-gui" "$BIN_DIR/xros-welcome-gui"
# Diamond: приложение (PyQt6 + QML) — в /usr/local/lib, лаунчер — в bin.
DIAMOND_SRC="$ROOT/src/xros-installer-diamond"
DIAMOND_LIB="$PROFILE/airootfs/usr/local/lib/xros-installer-diamond"
rm -rf "$DIAMOND_LIB"
mkdir -p "$DIAMOND_LIB"
cp "$DIAMOND_SRC/main.py" "$DIAMOND_SRC/bridge.py" "$DIAMOND_LIB/"
cp -r "$DIAMOND_SRC/qml" "$DIAMOND_LIB/"
rm -rf "$DIAMOND_LIB/qml/__pycache__"
cp "$DIAMOND_SRC/xros-installer-diamond" "$BIN_DIR/xros-installer-diamond"
# Режимы Diamond — явно: cp под umask 0007 даёт каталоги 0770
# и файлы 0660, а диагностика требует 0755/0644
# (fixed10, Этап 2, 11.11.2026; исходники src/xros-installer-diamond
# тоже нормализованы: каталоги 0755, файлы 0644, лаунчер 0755).
find "$DIAMOND_LIB" -type d -exec chmod 755 {} +
find "$DIAMOND_LIB" -type f -exec chmod 644 {} +
chmod 755 "$PROFILE/airootfs/usr/local/lib"
chmod 755 "$BIN_DIR/xros" "$BIN_DIR/xros-install-gui" "$BIN_DIR/xros-installer-launcher" "$BIN_DIR/xros-install" \
          "$BIN_DIR/xros-welcome" "$BIN_DIR/xros-welcome-gui" \
          "$BIN_DIR/xros-installer-diamond"
for b in xros xros-install-gui xros-installer-launcher xros-install xros-welcome xros-welcome-gui xros-installer-diamond; do
    [[ -x "$BIN_DIR/$b" ]] || die "нет исполняемого $BIN_DIR/$b"
done
[[ -f "$DIAMOND_LIB/main.py" && -f "$DIAMOND_LIB/bridge.py" && -d "$DIAMOND_LIB/qml" ]] \
  || die "Diamond не скопирован в живую систему"
# A-37: сверка хешей пакет→airootfs: бинарь в живой системе обязан
# совпадать с содержимым собранного пакета (иначе в ISO попадёт не
# то, что в репозитории). bsdtar — на хосте (libarchive); если его
# нет — сверка со staged-файлом в packages/ (тоже честная проверка:
# пакет собран из него на шаге 6). Скрипты и Diamond — побайтовым
# сравнением с src/.
for spec in "xros-cli xros usr/local/bin/xros" "xros-installer xros-install-gui usr/local/bin/xros-install-gui" "xros-installer xros-installer-launcher usr/local/bin/xros-installer-launcher"; do
    read -r _pkg _bin _path <<< "$spec"
    _pkgfile="$(ls -t "$ROOT/packages/$_pkg"/"$_pkg"-*.pkg.tar.zst 2>/dev/null | head -1)"
    [[ -n "$_pkgfile" ]] || die "A-37: нет пакета $_pkg для сверки"
    if command -v bsdtar >/dev/null 2>&1; then
        _want="$(bsdtar -xOf "$_pkgfile" "$_path" 2>/dev/null | sha256sum | cut -d' ' -f1)"
        [[ -n "$_want" ]] || die "A-37: в пакете $_pkg нет $_path"
    else
        echo "A-37: bsdtar нет на хосте — сверяю $_bin со staged-файлом в packages/$_pkg"
        _want="$(sha256sum "$ROOT/packages/$_pkg/$_bin" | cut -d' ' -f1)"
    fi
    _got="$(sha256sum "$BIN_DIR/$_bin" | cut -d' ' -f1)"
    [[ "$_got" == "$_want" ]] || die "A-37: $BIN_DIR/$_bin не совпадает с пакетом $_pkg (airootfs $_got, пакет $_want)"
done
cmp -s "$ROOT/src/xros-install" "$BIN_DIR/xros-install" \
    || die "A-37: $BIN_DIR/xros-install не совпадает с src/xros-install"
cmp -s "$ROOT/src/xros-welcome" "$BIN_DIR/xros-welcome" \
    || die "A-37: $BIN_DIR/xros-welcome не совпадает с src/xros-welcome"
cmp -s "$ROOT/src/xros-welcome-gui" "$BIN_DIR/xros-welcome-gui" \
    || die "A-37: $BIN_DIR/xros-welcome-gui не совпадает с src/xros-welcome-gui"
cmp -s "$DIAMOND_SRC/main.py" "$DIAMOND_LIB/main.py" \
    || die "A-37: Diamond main.py в живой системе не совпадает с src/"
cmp -s "$DIAMOND_SRC/bridge.py" "$DIAMOND_LIB/bridge.py" \
    || die "A-37: Diamond bridge.py в живой системе не совпадает с src/"
diff -rq "$DIAMOND_SRC/qml" "$DIAMOND_LIB/qml" >/dev/null \
    || die "A-37: Diamond qml/ в живой системе не совпадает с src/"
echo "A-37: бинари в живой системе совпадают с пакетами и src/"
echo "Бинари в живой системе: 6 файлов + Diamond"

# --- шаг 9а: нормализация прав профиля (A-02) ----------------------------------
# Первопричина дефекта 10.11.2026 (чёрный экран): профиль в git хранит
# только режимы 644/755, но в среде сборки (umask 0007, setgid-каталоги
# 2770) рабочие копии получают 2770/660 — и mkarchiso копирует их в
# живую систему как есть. chmod рабочего дерева в git не попадает,
# поэтому нормализация делается ЗДЕСЬ, перед mkarchiso, при каждой
# сборке. После нормализации — гейт check-rootfs-perms.sh --profile:
# любая ошибка прав останавливает сборку до mkarchiso.
step "Нормализация прав profile/airootfs (A-02) + гейт check-rootfs-perms.sh --profile"
AIROOTFS="$PROFILE/airootfs"
find "$AIROOTFS" -type d -exec chmod 755 {} +
# R-11 RESUME (13.11.2026): на этом хосте (btrfs) числовой 'chmod 755'
# НЕ снимает setgid-бит с каталогов (остаётся 2755) — нужен явный
# 'g-s'. Без этого гейт check-rootfs-perms.sh падает на каталогах
# repo-снимка (шаг 8 копирует их с setgid из repo/). Снимаем setgid
# и setuid явно для всех файлов и каталогов профиля.
find "$AIROOTFS" -exec chmod g-s {} +
find "$AIROOTFS" -type f -exec chmod 644 {} +
# Исполняемые файлы — те, что в git помечены 100755 (канон); если git
# недоступен — известный список (customize + usr/local/bin/*).
# RECOVERY-01 Phase D (13.11.2026): untracked-исполняемые (например,
# xros-gpg-check) не попадают в git ls-files, поэтому дополнительно
# восстанавливаем 755 для всех файлов в usr/local/bin/ и для
# customize_airootfs.sh — иначе нормализация (chmod 644 выше) лишает
# их бита исполнения, и диагностика A-40 падает.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files -s -- "$AIROOTFS" \
        | awk '$1 == "100755" {print $4}' \
        | while IFS= read -r f; do chmod 755 "$ROOT/$f"; done
fi
chmod 755 "$AIROOTFS/root/customize_airootfs.sh" "$AIROOTFS/usr/local/bin/"*
# /root — 750 (как требует check-rootfs-perms.sh; 755 здесь — FAIL).
chmod 750 "$AIROOTFS/root"
"$ROOT/scripts/check-rootfs-perms.sh" --profile "$AIROOTFS" \
    || die "права профиля не в норме (см. вывод выше) — mkarchiso остановлен"
echo "Права профиля нормализованы и проверены"

# --- шаг 9б: снимок репозитория [xros] в build-env rootfs (A-12) ----------------
# pacman при pacstrap резолвит file://-сервер ОТНОСИТЕЛЬНО ХОСТА
# (build-env rootfs), а не нового корня — тот же latent-дефект, что
# в шаге 4б scripts/build-rootfs-pacstrap.sh. Без этой копии mkarchiso
# падает с "Could not open file /usr/share/xros/repo/xros/os/x86_64/xros.db".
step "Снимок репозитория [xros] в build-env rootfs (A-12)"
mkdir -p "$ROOTFS/usr/share/xros/repo"
cp -a --no-preserve=ownership "$ROOT/repo/xros" "$ROOTFS/usr/share/xros/repo/"
[[ -f "$ROOTFS/usr/share/xros/repo/xros/os/x86_64/xros.db.tar.gz" ]] \
    || die "нет xros.db.tar.gz в build-env после копирования снимка"
echo "Снимок [xros] в build-env: /usr/share/xros/repo/xros/os/x86_64/ — OK"

# --- шаг 10: mkarchiso внутри build-env rootfs ---------------------------------------
step "mkarchiso внутри build-env rootfs (штатный archiso 92)"
# A-39: устаревший SHA256SUMS удаляется вместе со старыми ISO —
# иначе пересборка сверялась бы со старым хешем (ложный FAIL на шаге 13).
rm -rf "$WORK" "$OUT"/xros-*.iso "$OUT"/SHA256SUMS
mkdir -p "$OUT"
MK_LOG="$OUT/mkarchiso.log"
# mkarchiso выполняется внутри rootfs (там archiso 92-1, grub 2.16,
# xorriso, mksquashfs); проект смонтирован в /xros. Выход — /xros/out.
"$BUILD_ENV" --exec -- mkarchiso -v -w /xros/work -o /xros/out /xros/profile >"$MK_LOG" 2>&1 \
    || { tail -30 "$MK_LOG" >&2; die "mkarchiso не удался (лог: $MK_LOG). Если падение — на pacstrap полного списка (Write failed + EPERM), СТОП: разобрать причину, ручной pacstrap и маркеры base.* — только с явного разрешения, см. шапку файла."; }
echo "mkarchiso завершён (лог: $MK_LOG)"
ISO=""
for f in "$OUT"/xros-*.iso; do
  [[ -e "$f" ]] || continue
  [[ "$f" == *-hybrid.iso$ ]] && continue
  ISO="$f"
  break
done
[[ -n "$ISO" ]] || die "mkarchiso не создал ISO в $OUT"
count=0
for f in "$OUT"/xros-*.iso; do
  [[ -e "$f" ]] || continue
  [[ "$f" == *-hybrid.iso$ ]] && continue
  count=$((count+1))
done
[[ "$count" -eq 1 ]] \
    || die "в $OUT больше одного ISO от mkarchiso — непонятно, какой обрабатывать"
echo "ISO от mkarchiso: $ISO ($(stat -c%s "$ISO") Б)"

# --- шаг 11: постобработка BIOS-GRUB --------------------------------------------------
step "Постобработка BIOS-GRUB (гибридный ISO)"
"$POSTPROCESS" --iso "$ISO" \
    || die "постобработка BIOS-GRUB не удалась"
HYBRID="${ISO%.iso}-hybrid.iso"
[[ -f "$HYBRID" ]] || die "нет гибридного ISO: $HYBRID"
echo "Гибридный ISO: $HYBRID ($(stat -c%s "$HYBRID") Б)"

# --- шаг 12: SHA256SUMS для итоговых ISO ---------------------------------------
# A-39: SHA256SUMS пишется ДО проверки (шаг 13) и только для
# окончательных файлов (исходный ISO mkarchiso + гибридный после
# постобработки). Раньше было наоборот: проверка шла до создания
# файла (ложный PASS при первой сборке, ложный FAIL при пересборке).
step "SHA256SUMS для итоговых ISO (A-39)"
(cd "$OUT" && sha256sum "$(basename "$ISO")" "$(basename "$HYBRID")" > SHA256SUMS) \
    || die "не удалось создать $OUT/SHA256SUMS"
grep -qF " $(basename "$ISO")" "$OUT/SHA256SUMS" \
    || die "в SHA256SUMS нет записи для $(basename "$ISO")"
grep -qF " $(basename "$HYBRID")" "$OUT/SHA256SUMS" \
    || die "в SHA256SUMS нет записи для $(basename "$HYBRID")"
echo "SHA256SUMS создан: $OUT/SHA256SUMS"

# --- шаг 13: финальная проверка --------------------------------------------------------
step "Финальная проверка гибридного ISO (check-iso.sh --archiso --require-sha256)"
CHECK_LOG="$OUT/check-iso.log"
"$CHECK_ISO" --archiso --require-sha256 "$HYBRID" >"$CHECK_LOG" 2>&1 \
    || { cat "$CHECK_LOG" >&2; die "check-iso.sh: есть FAIL (лог: $CHECK_LOG)"; }
cat "$CHECK_LOG"

# --- шаг 14: итог ----------------------------------------------------------------------
step "Итог"
echo "ГОТОВО:"
echo "  ISO mkarchiso: $ISO"
echo "  Гибридный ISO: $HYBRID"
echo "  SHA256: $(sha256sum "$HYBRID" | awk '{print $1}')"
echo "  Логи: $OUT/mkarchiso.log, $OUT/diagnose.log, $OUT/check-iso.log, $HYBRID.postprocess.log, $OUT/SHA256SUMS"
echo "  Дальше — только QEMU-тесты готового ISO (см. AUDIT-REPORT.md §9.7)."
