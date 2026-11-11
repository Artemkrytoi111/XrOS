#!/usr/bin/env bash
# XrOS — ручная подготовка rootfs живой системы (ОБХОДНОЙ ПУТЬ, не штатный).
#
# ЗАЧЕМ ЭТОТ СКРИПТ
#   Штатный mkarchiso 92 трижды упал на одном и том же месте:
#     mkarchiso -> pacstrap -> chroot_setup -> свежий mount sysfs ->
#     "mount: .../sys: fsmount() failed: VFS: Mount too revealing."
#     -> "ERROR: failed to setup chroot".
#   Причина — песочница: хост сборки работает в user namespace, не
#   владеющем хостовым net ns; свежий mount sysfs (и devtmpfs) запрещён
#   ядром для такого неймспейса. Это ограничение СРЕДЫ, а не профиля
#   XrOS и не списка пакетов: минимальный mkarchiso и ручной pacstrap
#   маленького набора пакетов ведут себя так же. Подробности и логи:
#   out/mkarchiso.log, out/build-stage3-*.log.
#   Разрешение Мии (10.11.2026): ручной pacstrap по проверенной схеме
#   разрешён ТОЛЬКО для подготовки rootfs и упаковки в ISO.
#   НЕ разрешает: реальные диски, чужие chroot, отключение проверки
#   подписей, публикацию ISO.
#
# ЧТО ДЕЛАЕТ ОБХОД (проверенная схема ручного pacstrap, 07.11.2026 — работает)
#   Тот же результат, что штатный mkarchiso, но по шагам вручную:
#     1. rm -rf work (чистый старт; старые ISO в out/ удаляются,
#        логи сохраняются в out/prev-logs-<дата>/).
#     2. Генерация work/iso.pacman.conf — ТОЧНО как _make_pacman_conf
#        в mkarchiso (pacman-conf + sed: CacheDir/HookDir).
#     3. Копирование profile/airootfs/. в work/x86_64/airootfs ДО
#        pacstrap — ТОЧНО как штатный порядок mkarchiso
#        (_make_custom_airootfs идёт ДО _make_packages). Поэтому:
#        - /etc/mkinitcpio.conf.d/archiso.conf уже на месте, когда
#          устанавливается linux, и initramfs сразу собирается
#          С archiso-хуками (известная ловушка: mkinitcpio
#          надо прогонять ПОСЛЕ копирования профиля — здесь это
#          выполнено порядком шагов + контрольным прогоном mkinitcpio -P);
#        - снимок репозитория [xros] (file:///usr/share/xros/repo)
#          уже на месте, когда pacman синхронизирует базы.
#     4. Ручной pacstrap ПОЛНОГО списка profile/packages.x86_64
#        с ТЕМИ ЖЕ опциями, что у mkarchiso:
#        pacstrap -C work/iso.pacman.conf -c -G -M -- <airootfs> <пакеты>
#        Без --needed, без SigLevel-поблажек, без лишних пакетов.
#     5. arch-chroot customize_airootfs.sh (как _make_customize_airootfs),
#        затем удаление скрипта из airootfs.
#     6. Контрольный mkinitcpio -P в chroot + проверка archiso-хуков
#        в initramfs (lsinitcpio).
#     7. Файлы версии — ТОЧНО как _make_version в mkarchiso:
#        airootfs/version, work/iso/xros/version, IMAGE_ID/IMAGE_VERSION
#        в os-release, /usr/lib/clock-epoch, work/build_date.
#     8. Шесть маркеров _run_once в work/: base._make_work_dir,
#        base._make_pacman_conf, base._make_custom_airootfs,
#        base._make_packages, base._make_version,
#        base._make_customize_airootfs — чтобы последующий запуск
#        mkarchiso ПРОПУСТИЛ уже выполненные шаги и сделал только
#        squashfs + сборку ISO.
#   Скрипт НЕ запускает mkarchiso сам: упаковка — отдельный шаг
#   (mkarchiso -v -w work -o out profile внутри build-env).
#
# ЧТО ДЕЛАЕТ PACSTRAP (для протокола)
#   pacstrap создаёт каталог rootfs, монтирует API-файловые системы
#   (proc, sys, dev, devpts, shm, run, tmp), копирует/инициирует
#   keyring, запускает pacman -Sy <пакеты> с --config и
#   --disable-sandbox в новый корень. Проверка подписей пакетов
#   НЕ отключается (SigLevel из профиля: Required DatabaseOptional).
#
# ПАТЧ build-env (завершён и проверен 10.11.2026, см. PACSTRAP-BUILD-REPORT.md)
#   В копии build-env/root.x86_64/usr/bin/{pacstrap,arch-chroot}
#   функция chroot_setup() изменена ровно в 2 строках: свежие mount
#   sysfs и devtmpfs заменены на --rbind хостовых /sys и /dev через
#   штатный chroot_add_mount_lazy — тот же приём, что уже использует
#   штатный unshare_setup() в тех же файлах. Оригиналы сохранены как
#   pacstrap.orig / arch-chroot.orig. Штатный путь pacstrap -N
#   (вложенный unshare --map-root-user) в этой песочнице ЗАВИСАЕТ
#   (проверено: >10 мин без вывода, процесс убит) и НЕ используется.
#   Ручной pacstrap и arch-chroot вызываются ОБЫЧНЫМ путём (без -N)
#   через scripts/xros-build-env.sh --exec (unshare+chroot).
#
# ОТЛИЧИЯ ОТ ЭТАЛОННОЙ СХЕМЫ (честно)
#   * Каталоги и метка — свои: XROS_202611, install_dir xros.
#   * Список пакетов — profile/packages.x86_64 XrOS (Plasma 6.8
#     Wayland, без syslinux/systemd-boot, без xfce4/lightdm).
#   * Профиль копируется ДО pacstrap (штатный порядок mkarchiso),
#     а не после — поэтому отдельный повторный mkinitcpio здесь
#     контрольный, а не восстановительный.
#   * bootmodes=('uefi.grub'): BIOS-GRUB добавляется ПОСЛЕ mkarchiso
#     отдельным скриптом postprocess-bios-grub.sh (не входит сюда).
#   * В эталонном проекте исходников/сценария ручной сборки нет
#     в открытом виде (только build-chroot.sh и профиль); рецепт восстановлен
#     по датированному логу ~/memory/2026-11-07.md (строка 132)
#     и сверен с файлами эталонного профиля.
#
# ОГРАНИЧЕНИЯ ОБХОДА (честно)
#   * Результат НЕ идентичен штатному побайтово: rootfs собран тем же
#     pacstrap и тем же списком, но порядок операций и маркеры —
#     ручные; воспроизводимость — повторным прогоном этого скрипта
#     с тем же профилем и тем же зеркалом (версии пакетов зависят
#     от состояния репозиториев Arch на момент запуска).
#   * Патч chroot_setup() — локальное изменение копий
#     arch-install-scripts ВНУТРИ build-env (не в системе, не в
#     профиле); при --reinit build-env патч надо применить заново
#     (скрипт проверяет его наличие и останавливается, если патча нет).
#   * QEMU-тесты готового ISO — отдельный этап, сюда не входят.
#
# Использование:
#   ./scripts/build-rootfs-pacstrap.sh --confirm   # выполнить
#   ./scripts/build-rootfs-pacstrap.sh --help      # справка
# Требует root. Логи: out/pacstrap-build.log (и stdout через tee).
set -euo pipefail
# Umask 0022 (дефект 10.11.2026: хост работает с umask 0007 —
# файлы, созданные при сборке, получались 660, каталоги 770/2770,
# и не-root в живой системе не мог их читать; см. FIX-REPORT.md).
# Наследуется всеми дочерними процессами, включая arch-chroot и
# customize_airootfs.sh. Права файлов профиля дополнительно
# нормализуются явно на шаге 4 (umask сам по себе режимы 660/2770
# из профиля не чинит: cp --no-preserve=mode их сохраняет).
umask 0022

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/profile"
WORK="$ROOT/work"
OUT="$ROOT/out"
BUILD_ENV="$ROOT/scripts/xros-build-env.sh"
DIAGNOSE="$ROOT/scripts/xros-diagnose.sh"
ROOTFS="$ROOT/build-env/root.x86_64"
AIROOTFS="$WORK/x86_64/airootfs"
LOG="$OUT/pacstrap-build.log"

die() { echo "build-rootfs-pacstrap: ОШИБКА: $*" >&2; exit 1; }
log() { echo "[pacstrap-build] $*"; }

usage() { sed -n '2,80p' "$0"; echo "Использование: $0 --confirm | --help"; }

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --confirm) ;;
    *) echo "Без --confirm ничего не делает." >&2; usage >&2; exit 2 ;;
esac

mkdir -p "$OUT"
# Лог пишется с самого начала (tee — и в файл, и на экран).
exec > >(tee -a "$LOG") 2>&1
log "=== XrOS: ручная подготовка rootfs (обходной путь), $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
log "Лог: $LOG"

# --- предусловия ---------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "требуется root"
[[ -d "$ROOTFS/usr/bin" ]] || die "нет build-env rootfs: сначала scripts/xros-build-env.sh --init"
[[ -x "$BUILD_ENV" ]] || die "нет $BUILD_ENV"
[[ -f "$PROFILE/profiledef.sh" ]] || die "нет профиля: $PROFILE/profiledef.sh"
[[ -f "$PROFILE/packages.x86_64" ]] || die "нет списка пакетов: $PROFILE/packages.x86_64"
[[ -f "$PROFILE/pacman.conf" ]] || die "нет profile/pacman.conf"
[[ -x "$DIAGNOSE" ]] || die "нет $DIAGNOSE"
[[ -x "$PROFILE/airootfs/root/customize_airootfs.sh" ]] || die "customize_airootfs.sh не +x (должен быть исполняемым)"
grep -q "bootmodes=('uefi.grub')" "$PROFILE/profiledef.sh" \
    || die "profiledef.sh: bootmodes изменился — ожидалось ('uefi.grub'); syslinux возвращать НЕЛЬЗЯ"
[[ -d "$ROOT/../xros-backups/xros-20261110-stage10-prep" ]] \
    || die "нет резервной копии xros-20261110-stage10-prep"
# Свободное место: нужно ~10 ГБ запаса.
FREE_GB="$(df --output=avail -BG "$ROOT" | tail -1 | tr -dc '0-9')"
[[ "$FREE_GB" -ge 10 ]] || die "свободно ${FREE_GB} ГБ — нужно >= 10 ГБ"
log "Предусловия: root, профиль, customize +x, резервная копия, свободно ${FREE_GB} ГБ — OK"
# Архитектура и версии инструментов внутри build-env.
"$BUILD_ENV" --exec -- bash -c '[[ "$(uname -m)" == "x86_64" ]] && pacman -Q pacman archiso grub >/dev/null' \
    || die "build-env: не x86_64 или нет pacman/archiso/grub"
"$BUILD_ENV" --exec -- bash -c 'pacman -Q pacman archiso grub squashfs-tools libisoburn' \
    || die "не удалось прочитать версии в build-env"
# Патч chroot_setup() в build-env: обе строки --rbind должны быть на месте,
# оригиналы — сохранены. Без патча ручной pacstrap упадёт как штатный.
for tool in pacstrap arch-chroot; do
    f="$ROOTFS/usr/bin/$tool"
    [[ -f "$f.orig" ]] || die "нет $f.orig — оригинал $tool не сохранён, патч не применяется вслепую"
    grep -q 'chroot_add_mount_lazy /sys "\$1/sys" --rbind' "$f" \
        || die "$tool: нет патча --rbind /sys (см. PACSTRAP-BUILD-REPORT.md)"
    grep -q 'chroot_add_mount_lazy /dev "\$1/dev" --rbind' "$f" \
        || die "$tool: нет патча --rbind /dev (см. PACSTRAP-BUILD-REPORT.md)"
    grep -q 'chroot_add_mount sys "\$1/sys" -t sysfs' "$f" \
        && die "$tool: стоковая строка sysfs на месте — патч применён не полностью"
    grep -q 'chroot_add_mount udev "\$1/dev" -t devtmpfs' "$f" \
        && die "$tool: стоковая строка devtmpfs на месте — патч применён не полностью"
done
log "Патч build-env: pacstrap + arch-chroot (2 строки --rbind в chroot_setup), оригиналы .orig на месте — OK"
# Подписи НЕ отключаем: SigLevel в профиле должен оставаться Required.
grep -q '^SigLevel.*Required' "$PROFILE/pacman.conf" \
    || die "profile/pacman.conf: SigLevel без Required — подписи отключать НЕЛЬЗЯ"

# --- шаг 0: диагностика ---------------------------------------------------------
log "=== шаг 0: финальная диагностика (FAIL=0, иначе стоп) ==="
"$DIAGNOSE" >"$OUT/diagnose.log" 2>&1 || { tail -5 "$OUT/diagnose.log" >&2; die "диагностика завершилась с ошибкой (лог: $OUT/diagnose.log)"; }
DIAG_SUM="$(grep -E '^Итого: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' "$OUT/diagnose.log" | tail -1)"
log "Диагностика: ${DIAG_SUM:-<нет строки итога>}"
case "$DIAG_SUM" in *" FAIL=0 "*) log "Диагностика: FAIL=0 — идём дальше" ;; *) die "диагностика: FAIL != 0 — стоп" ;; esac

# --- шаг 1: чистый старт --------------------------------------------------------
log "=== шаг 1: чистый старт work/ (логи out/ сохраняются) ==="
PREV="$OUT/prev-logs-$(date -u '+%Y%m%d-%H%M%S')"
mkdir -p "$PREV"
# Сохраняем старые логи и отчёты, не удаляя их молча.
for f in "$OUT"/*.log; do [[ -e "$f" ]] && cp -a "$f" "$PREV/" 2>/dev/null || true; done
log "Старые логи скопированы в $PREV"
rm -rf "$WORK"
rm -f "$OUT"/xros-*.iso "$OUT"/SHA256SUMS
mkdir -p "$WORK" "$OUT"
# build_date — как у mkarchiso: SOURCE_DATE_EPOCH пишется один раз.
SOURCE_DATE_EPOCH="$(date +%s)"
printf '%s\n' "$SOURCE_DATE_EPOCH" >"$WORK/build_date"
log "work/ пересоздан; build_date (SOURCE_DATE_EPOCH) = $SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC'))"

# --- шаг 2: свежий egress-CA в rootfs -------------------------------------------
log "=== шаг 2: обновление egress-CA хоста в build-env rootfs ==="
HOST_CA="/usr/local/share/ca-certificates/hatch-egress-ca.crt"
if [[ -f "$HOST_CA" ]]; then
    mkdir -p "$ROOTFS/etc/ca-certificates/trust-source/anchors"
    cp -L "$HOST_CA" "$ROOTFS/etc/ca-certificates/trust-source/anchors/hatch-egress-ca.crt"
    "$BUILD_ENV" --exec -- update-ca-trust extract \
        || die "update-ca-trust в rootfs не удался"
    log "CA обновлён из $HOST_CA"
else
    log "Файла $HOST_CA нет — пропускаю (если pacman упадёт с SSL, проверить CA вручную)"
fi

# --- шаг 2б: /run в build-env — writable (иначе /run в chroot read-only) --------
# Bootstrap-тарболл поставляет /run с правами 555; arch-chroot/pacstrap
# биндят именно его в новый корень, и /run в chroot оказывается
# read-only. На настоящем Arch-хосте /run — tmpfs (writable). Из-за
# этого в customize падал `ufw default deny incoming` (не может создать
# /run/ufw.lock) — политика при этом уже DROP по умолчанию пакета ufw
# (/etc/default/ufw), т.е. вреда не было, но writable /run ближе
# к штатному поведению. Меняется только наш build-env, не профиль.
chmod 755 "$ROOTFS/run" || die "не удалось chmod 755 $ROOTFS/run"
log "build-env /run: 755 (writable) — как tmpfs на штатном хосте"

# --- шаг 3: work/iso.pacman.conf — как _make_pacman_conf в mkarchiso ----------
log "=== шаг 3: генерация work/iso.pacman.conf (как _make_pacman_conf) ==="
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
_sys="$(pacman-conf CacheDir | tr "\n" " ")"
_prof="$(pacman-conf --config /xros/profile/pacman.conf CacheDir | tr "\n" " ")"
if [[ "$_prof" != "/var/cache/pacman/pkg" ]] && [[ "$_sys" != "$_prof" ]]; then _cache="$_prof"; else _cache="$_sys"; fi
echo "Using pacman CacheDir: $_cache"
pacman-conf --config /xros/profile/pacman.conf \
  | sed "/CacheDir/d;/DBPath/d;/HookDir/d;/LogFile/d;/RootDir/d;/\[options\]/a CacheDir = $_cache
  /\[options\]/a HookDir = /xros/work/x86_64/airootfs/etc/pacman.d/hooks/" > /xros/work/iso.pacman.conf
' || die "генерация iso.pacman.conf не удалась"
grep -q '^CacheDir = ' "$WORK/iso.pacman.conf" || die "в iso.pacman.conf нет CacheDir"
grep -q 'HookDir = /xros/work/x86_64/airootfs/etc/pacman.d/hooks/' "$WORK/iso.pacman.conf" \
    || die "в iso.pacman.conf нет HookDir на airootfs"
log "work/iso.pacman.conf готов"

# --- шаг 4: профиль в airootfs ДО pacstrap (штатный порядок mkarchiso) ---------
log "=== шаг 4: копирование profile/airootfs/. в airootfs (до pacstrap) ==="
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
install -d -m 0755 -o 0 -g 0 -- /xros/work/x86_64/airootfs
cp -af --no-preserve=ownership,mode -- /xros/profile/airootfs/. /xros/work/x86_64/airootfs/
' || die "копирование профиля в airootfs не удалось"
# --- шаг 4а: нормализация прав профиля (дефект 10.11.2026, см. FIX-REPORT.md) ---
# Хост: setgid-каталоги 2770 + umask 0007 → в profile/airootfs
# каталоги 2770 (33 шт.), файлы 660 (50 шт.), customize 770, .pyc 640.
# cp -af --no-preserve=ownership,mode эти режимы СОХРАНЯЕТ, и в живой
# системе любой процесс не от root получал EACCES на execve()/open()
# из /usr и /etc: systemd 203/EXEC, нет D-Bus, SDDM в цикле, чёрный экран.
# В этот момент в airootfs — ТОЛЬКО содержимое профиля (pacstrap ещё
# не запускался), поэтому нормализуем ровно наблюдавшиеся режимы:
# каталоги 2770 -> 755, файлы 660 -> 644, 770 -> 755, 640 -> 644.
# Явные file_permissions из profiledef.sh применяются ДАЛЬШЕ и имеют
# приоритет (/root 750, /etc/shadow 400 и т.д.).
# --- fixed10 (ТЗ 11.11.2026, Этап 2): сначала снять ВСЕ спецбиты ---
# Дефект fixed9: каталоги 2755 (setgid + 755) проходили мимо всех
# нормализаций — они целятся в ТОЧНЫЕ режимы (2770/660/770/640), а 2755
# нигде не проверялся (check-rootfs-perms.sh его даже явно принимал).
# Снимаем биты ДО точной нормализации: 2660 -> 0660 -> 0644 и т.д.
# На этом шаге в airootfs ТОЛЬКО содержимое профиля (pacstrap ещё не
# запускался): легитимных спецбитов здесь быть не должно. Каталогам
# ставим 755 явно (в профиле все каталоги 755, кроме /root 750 — у него
# спецбитов нет, и file_permissions задаёт его позже).
log "Снятие спецбитов (suid/sgid/sticky) в airootfs после копии профиля..."
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
A=/xros/work/x86_64/airootfs
echo "  каталогов со спецбитами: $(find "$A" -type d -perm /6000 | wc -l), файлов: $(find "$A" -type f -perm /6000 | wc -l)"
find "$A" -type d -perm /6000 -exec chmod 755 {} +
find "$A" -type f -perm /6000 -exec chmod a-s {} +
echo "  после снятия: каталогов: $(find "$A" -type d -perm /6000 | wc -l), файлов: $(find "$A" -type f -perm /6000 | wc -l)"
' || die "снятие спецбитов в airootfs не удалось"
log "Нормализация прав профиля в airootfs (2770->755, 660->644, 770->755, 640->644)..."
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
A=/xros/work/x86_64/airootfs
echo "  до: каталогов 2770: $(find "$A" -type d -perm 2770 | wc -l), файлов 660: $(find "$A" -type f -perm 660 | wc -l), 770: $(find "$A" -type f -perm 770 | wc -l), 640: $(find "$A" -type f -perm 640 | wc -l)"
find "$A" -type d -perm 2770 -exec chmod 755 {} +
find "$A" -type f -perm 660 -exec chmod 644 {} +
find "$A" -type f -perm 770 -exec chmod 755 {} +
find "$A" -type f -perm 640 -exec chmod 644 {} +
echo "  после: каталогов 2770: $(find "$A" -type d -perm 2770 | wc -l), файлов 660: $(find "$A" -type f -perm 660 | wc -l), 770: $(find "$A" -type f -perm 770 | wc -l), 640: $(find "$A" -type f -perm 640 | wc -l)"
' || die "нормализация прав профиля не удалась"
# Проверка: после нормализации не должно остаться ни одного 2770/660.
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
A=/xros/work/x86_64/airootfs
D_LEFT="$(find "$A" -type d -perm 2770)"
F_LEFT="$(find "$A" -type f \( -perm 660 -o -perm 770 -o -perm 640 \))"
if [[ -n "$D_LEFT" ]]; then echo "ОСТАЛИСЬ каталоги 2770:"; echo "$D_LEFT"; exit 1; fi
if [[ -n "$F_LEFT" ]]; then echo "ОСТАЛИСЬ файлы 660/770/640:"; echo "$F_LEFT"; exit 1; fi
echo "проверка: 2770/660/770/640 не осталось"
' || die "после нормализации остались каталоги 2770 или файлы 660/770/640"
log "Права профиля нормализованы: 2770/660/770/640 не осталось"
# Права из profiledef.sh (как _make_custom_airootfs; отсутствующие файлы — предупреждение, как у mkarchiso).
log "Применение file_permissions из profiledef.sh (существующие файлы)..."
# ВАЖНО: file_permissions — ассоциативный массив; без declare -A
# bash парсит ["/etc/shadow"]="..." как арифметический индекс
# и source падает с syntax error (проверено 10.11.2026).
declare -A file_permissions
# shellcheck disable=SC1091
source "$PROFILE/profiledef.sh"
[[ "${#file_permissions[@]}" -gt 0 ]] || die "file_permissions пуст после чтения profiledef.sh"
for filename in "${!file_permissions[@]}"; do
    IFS=':' read -r _owner _group _mode <<<"${file_permissions["${filename}"]}"
    target="$AIROOTFS${filename}"
    if [[ ! -e "$target" ]]; then
        log "  ПРЕДУПРЕЖДЕНИЕ (как у mkarchiso): нет $filename — пропуск"
        continue
    fi
    if [[ "${filename: -1}" == "/" ]]; then
        "$BUILD_ENV" --exec -- bash -c "chown -fhR -- '$_owner:$_group' '/xros/work/x86_64/airootfs$filename'; chmod -fR -- '$_mode' '/xros/work/x86_64/airootfs$filename'" \
            || die "не удалось задать права $filename"
    else
        "$BUILD_ENV" --exec -- bash -c "chown -fh -- '$_owner:$_group' '/xros/work/x86_64/airootfs$filename'; chmod -f -- '$_mode' '/xros/work/x86_64/airootfs$filename'" \
            || die "не удалось задать права $filename"
    fi
done
[[ -f "$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf" ]] \
    || die "нет archiso.conf в airootfs после копирования профиля"
[[ -f "$AIROOTFS/usr/share/xros/repo/xros/os/x86_64/xros.db.tar.gz" ]] \
    || die "нет снимка репозитория [xros] в airootfs после копирования профиля"
log "Профиль в airootfs: archiso.conf и снимок [xros] на месте"

# --- шаг 4б: снимок [xros] в build-env (дефект, найден 10.11.2026) ------------
# pacman при pacstrap резолвит file://-сервер ОТНОСИТЕЛЬНО ХОСТА
# (build-env rootfs), а не нового корня: file:///usr/share/xros/repo
# в airootfs ему НЕ виден, и `pacman -Sy` падает с
# "Could not open file /usr/share/xros/repo/xros/os/x86_64/xros.db"
# (проверено: первая попытка полного pacstrap упала именно здесь).
# Штатный mkarchiso упал бы точно так же — это latent-дефект профиля/
# build.sh шагов 1–9: снимок копируется только в profile/airootfs.
# Исправление (не меняет профиль и живую систему): та же копия
# снимка кладётся в build-env по тому же пути /usr/share/xros/repo,
# откуда pacman его читает при pacstrap. В живой системе путь тот же.
log "=== шаг 4б: снимок репозитория [xros] в build-env (/usr/share/xros/repo) ==="
mkdir -p "$ROOTFS/usr/share/xros/repo"
cp -a --no-preserve=ownership "$ROOT/repo/xros" "$ROOTFS/usr/share/xros/repo/"
[[ -f "$ROOTFS/usr/share/xros/repo/xros/os/x86_64/xros.db.tar.gz" ]] \
    || die "нет xros.db.tar.gz в build-env после копирования снимка"
log "Снимок [xros] в build-env: /usr/share/xros/repo/xros/os/x86_64/ — OK"

# --- шаг 5: ручной pacstrap полного списка --------------------------------------
log "=== шаг 5: ручной pacstrap полного списка profile/packages.x86_64 ==="
# Точный список: комментарии и пустые строки — вон, порядок — как в файле.
mapfile -t PKGS < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$PROFILE/packages.x86_64")
[[ "${#PKGS[@]}" -gt 0 ]] || die "пустой список пакетов"
log "Пакетов в списке: ${#PKGS[@]}"
printf '%s\n' "${PKGS[@]}" >"$WORK/pacstrap-pkglist.txt"
# Те же опции, что у mkarchiso _make_packages (root: без -N):
#   -C work/iso.pacman.conf -c -G -M -- <airootfs> <пакеты>
# env -u TMPDIR — как у mkarchiso (обход bugs.archlinux.org/task/70580).
"$BUILD_ENV" --exec -- bash -c "env -u TMPDIR pacstrap -C /xros/work/iso.pacman.conf -c -G -M -- /xros/work/x86_64/airootfs $(printf '%q ' "${PKGS[@]}")" \
    || die "ручной pacstrap не удался (полный вывод выше и в $LOG)"
log "pacstrap завершён без ошибок"

# --- шаг 6: проверка установленных пакетов --------------------------------------
log "=== шаг 6: проверка: все пакеты из списка установлены ==="
# ВАЖНО: внутри arch-chroot корень — сам airootfs, путь /xros/work
# там НЕ существует. Список пакетов кладётся ВНУТРЬ airootfs
# (/root/pacstrap-pkglist.txt), проверка читает его оттуда,
# результат — в /root/missing-pkgs.txt; оба файла потом удаляются,
# чтобы не попасть в образ (свой pkglist mkarchiso пишет сам позже).
cp -a "$WORK/pacstrap-pkglist.txt" "$AIROOTFS/root/pacstrap-pkglist.txt"
"$BUILD_ENV" --exec -- arch-chroot /xros/work/x86_64/airootfs bash -c '
missing=""
while IFS= read -r p; do
  pacman -Q "$p" >/dev/null 2>&1 || missing="$missing $p"
done < /root/pacstrap-pkglist.txt
printf "%s" "$missing" > /root/missing-pkgs.txt
' || die "проверка установленных пакетов не удалась"
MISSING="$(cat "$AIROOTFS/root/missing-pkgs.txt")"
rm -f "$AIROOTFS/root/pacstrap-pkglist.txt" "$AIROOTFS/root/missing-pkgs.txt"
[[ -z "$MISSING" ]] || die "не установлены пакеты из списка:$MISSING"
"$BUILD_ENV" --exec -- arch-chroot /xros/work/x86_64/airootfs pacman -Qq >"$WORK/installed-pkgs.txt" 2>/dev/null \
    || die "не удалось перечислить установленные пакеты"
INSTALLED_N="$(wc -l <"$WORK/installed-pkgs.txt")"
[[ "$INSTALLED_N" -gt 100 ]] || die "установлено подозрительно мало пакетов: $INSTALLED_N"
log "Все ${#PKGS[@]} пакетов из списка установлены; всего пакетов в rootfs: $INSTALLED_N"

# --- шаг 7: customize через arch-chroot -----------------------------------------
log "=== шаг 7: customize_airootfs.sh через arch-chroot ==="
"$BUILD_ENV" --exec -- bash -c 'chmod -f -- +x /xros/work/x86_64/airootfs/root/customize_airootfs.sh; env -u TMPDIR arch-chroot /xros/work/x86_64/airootfs /root/customize_airootfs.sh' \
    || die "customize_airootfs.sh не удался"
"$BUILD_ENV" --exec -- rm -- /xros/work/x86_64/airootfs/root/customize_airootfs.sh \
    || die "не удалось удалить customize_airootfs.sh из airootfs"
log "customize выполнен, скрипт удалён из airootfs"

# --- шаг 8: контрольный mkinitcpio -P + проверка archiso-хуков ------------------
log "=== шаг 8: контрольный mkinitcpio -P в chroot + проверка archiso-хуков ==="
# mkinitcpio -P возвращает 1 из-за отсутствующих helper-бинарей PXE-хуков
# (ipconfig, nbd-client, nfsmount — их нет в живой системе по дизайну
# профиля; та же картина была в эталонном проекте). Образ при этом
# СОЗДАЁТСЯ и содержит все archiso-хуки. Поэтому: exit 0 или 1 —
# допустимо, но образ ОБЯЗАТЕЛЬНО проверяется (существует, непустой,
# archiso-хуки на месте). Любой другой код — ошибка.
set +e
"$BUILD_ENV" --exec -- arch-chroot /xros/work/x86_64/airootfs mkinitcpio -P
MK_RC=$?
set -e
if [[ "$MK_RC" -ne 0 && "$MK_RC" -ne 1 ]]; then die "mkinitcpio -P: неожиданный код $MK_RC"; fi
[[ "$MK_RC" -eq 0 ]] || log "ПРЕДУПРЕЖДЕНИЕ: mkinitcpio -P вернул 1 (нет ipconfig/nbd-client/nfsmount для PXE-хуков; PXE-загрузка недоступна, обычная загрузка с ISO не затронута)"
INITRAMFS="$AIROOTFS/boot/initramfs-linux.img"
[[ -s "$INITRAMFS" ]] || die "нет $INITRAMFS после mkinitcpio -P"
# lsinitcpio — ВНУТРИ chroot: он есть в airootfs (пакет mkinitcpio),
# а в build-env его нет (проверено 10.11.2026: command not found).
"$BUILD_ENV" --exec -- arch-chroot /xros/work/x86_64/airootfs bash -c 'lsinitcpio -a /boot/initramfs-linux.img | grep -q "archiso" && lsinitcpio -a /boot/initramfs-linux.img | grep -o "archiso[a-z_]*" | sort -u' \
    || die "в initramfs нет archiso-хуков"
log "initramfs содержит archiso-хуки (см. список выше)"

# --- шаг 9: файлы версии — как _make_version в mkarchiso ------------------------
log "=== шаг 9: файлы версии (как _make_version) ==="
ISO_VERSION="$(grep -E '^iso_version=' "$PROFILE/profiledef.sh" | cut -d'"' -f2)"
[[ -n "$ISO_VERSION" ]] || die "не удалось прочитать iso_version из profiledef.sh"
ISO_NAME="$(grep -E '^iso_name=' "$PROFILE/profiledef.sh" | cut -d'"' -f2)"
printf '%s\n' "$ISO_VERSION" >"$AIROOTFS/version"
mkdir -p "$WORK/iso/$ISO_NAME"
printf '%s\n' "$ISO_VERSION" >"$WORK/iso/$ISO_NAME/version"
"$BUILD_ENV" --exec -- bash -c "
set -euo pipefail
_os=\"\$(realpath -- /xros/work/x86_64/airootfs/etc/os-release)\"
sed -i -- '/^IMAGE_ID=/d;/^IMAGE_VERSION=/d' \"\$_os\"
printf 'IMAGE_ID=%s\nIMAGE_VERSION=%s\n' '$ISO_NAME' '$ISO_VERSION' | tee -a \"\$_os\" >/dev/null
touch -m -d\"@${SOURCE_DATE_EPOCH}\" -- /xros/work/x86_64/airootfs/usr/lib/clock-epoch
" || die "запись версии/os-release/clock-epoch не удалась"
log "version=$ISO_VERSION, iso/$ISO_NAME/version создан, IMAGE_ID=$ISO_NAME в os-release"

# --- шаг 10: шесть маркеров _run_once --------------------------------------------
log "=== шаг 10: шесть маркеров base.* для mkarchiso ==="
for m in _make_work_dir _make_pacman_conf _make_custom_airootfs _make_packages _make_version _make_customize_airootfs; do
    touch "$WORK/base.$m"
done
ls -la "$WORK"/base.* | awk '{print "  " $NF}'
log "Маркеры готовы: mkarchiso пропустит pacstrap и сделает только squashfs + ISO"

# --- шаг 11: проверки готового rootfs --------------------------------------------
log "=== шаг 11: проверки готового rootfs ==="
"$BUILD_ENV" --exec -- arch-chroot /xros/work/x86_64/airootfs bash -c '
set -euo pipefail
echo "--- версии ---"
pacman -Q linux plasma-desktop grub sddm mkinitcpio-archiso ufw 2>/dev/null
echo "--- пользователь xros ---"
id xros
grep -q "^xros:" /etc/passwd
echo "--- SDDM автовход ---"
grep -q "^User=xros" /etc/sddm.conf.d/autologin.conf && grep -q "^Session=plasma" /etc/sddm.conf.d/autologin.conf
systemctl is-enabled sddm.service NetworkManager.service ufw.service
echo "--- пароли заблокированы, shadow 600 ---"
[[ "$(stat -c %a /etc/shadow)" == "600" ]]
passwd -S root | grep -q " L "
passwd -S xros | grep -q " L "
echo "--- локали ---"
locale -a | grep -q "ru_RU.utf8"
[[ "$(readlink /etc/localtime)" == "/usr/share/zoneinfo/Europe/Astrakhan" ]]
echo "--- фирменная тема ---"
[[ -f /usr/share/xros/wallpaper.png && -f /usr/share/xros/xros-logo.png ]]
grep -q "BreezeDark" /home/xros/.config/kdeglobals
echo "--- файрвол: политика по умолчанию DROP ---"
grep -q "DEFAULT_INPUT_POLICY=\"DROP\"" /etc/default/ufw
echo "--- установщик и приветствие ---"
[[ -x /usr/local/bin/xros-install && -x /usr/local/bin/xros-install-gui && -x /usr/local/bin/xros && -x /usr/local/bin/xros-welcome ]]
echo "--- systemd ---"
[[ -x /usr/lib/systemd/systemd ]]
echo "ВСЕ ПРОВЕРКИ ROOTFS ПРОШЛИ"
' || die "проверки rootfs не прошли (см. вывод выше)"
# DE=none: проверка списка/конфигурации (не установка): каждый графический
# пакет из packages.x86_64 должен быть в XROS_GRAPHICS_PKGS установщика.
log "--- DE=none: графические пакеты из списка покрыты XROS_GRAPHICS_PKGS ---"
GFX_IN_LIST="$(grep -E '^(plasma-|kscreen|sddm|konsole|dolphin|pipewire|wireplumber|xorg-server|ttf-|noto-fonts|python-pyqt6|libxkbcommon-x11)' "$PROFILE/packages.x86_64" | tr '\n' ' ')"
GFX_REMOVE="$(sed -n 's/^XROS_GRAPHICS_PKGS="\(.*\)"/\1/p' "$ROOT/src/xros-install" | head -1)"
GFX_UNCOVERED=""
for g in $GFX_IN_LIST; do
    case " $GFX_REMOVE " in *" $g "*) ;; *) GFX_UNCOVERED="$GFX_UNCOVERED $g" ;; esac
done
log "Графических пакетов в списке: $(echo "$GFX_IN_LIST" | wc -w); в XROS_GRAPHICS_PKGS: $(echo "$GFX_REMOVE" | wc -w)"
[[ -z "$GFX_UNCOVERED" ]] || die "DE=none: не покрыты XROS_GRAPHICS_PKGS:$GFX_UNCOVERED"
log "DE=none: все графические пакеты покрыты списком удаления (15 пакетов)"

# --- шаг 11б: финальная проверка прав готового rootfs -------------------------
# После pacstrap + customize в rootfs не должно остаться ни одного
# каталога 2770 и ни одного файла 660/770 (дефект 10.11.2026: именно
# они давали EACCES не-root процессам и чёрный экран). Umask 0022
# сверху и нормализация на шаге 4а должны были это предотвратить;
# здесь — страховка и жёсткая проверка. Нормализация применяется
# только к заведомо публичным путям (/usr, /etc, /home, /opt, /srv);
# всё остальное с такими режимами — FAIL с явным списком (вдруг это
# легитимно ограниченный файл пакета — разбирать вручную, а не
# открывать его молча всему миру).
log "--- шаг 11б: проверка прав готового rootfs (2770/660/770 быть не должно) ---"
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
A=/xros/work/x86_64/airootfs
# Разрешённые исключения (стандартные режимы Arch, НЕ дефект):
# /var/log/btmp и /var/log/lastlog — 660 root:utmp (учёт входов);
# открывать их всему миру (644) НЕЛЬЗЯ. Найдено при первом прогоне
# шага 11б (10.11.2026): единственный оставшийся файл 660 — btmp.
ALLOW="^$A/var/log/btmp$|^$A/var/log/lastlog$"
echo "  каталогов 2770: $(find "$A" -type d -perm 2770 | tee /tmp/xros-bad-dirs.txt | wc -l)"
echo "  файлов 660/770: $(find "$A" -type f \( -perm 660 -o -perm 770 \) | tee /tmp/xros-bad-files.txt | wc -l)"
find "$A" -type d -perm 2770 -exec chmod 755 {} +
for p in usr etc home opt srv; do
  find "$A/$p" -type f -perm 660 -exec chmod 644 {} + 2>/dev/null || true
  find "$A/$p" -type f -perm 770 -exec chmod 755 {} + 2>/dev/null || true
done
D_LEFT="$(find "$A" -type d -perm 2770)"
F_LEFT="$(find "$A" -type f \( -perm 660 -o -perm 770 \) | grep -vE "$ALLOW" || true)"
if [[ -n "$D_LEFT" ]]; then echo "ОСТАЛИСЬ каталоги 2770:"; echo "$D_LEFT"; exit 1; fi
if [[ -n "$F_LEFT" ]]; then echo "ОСТАЛИСЬ файлы 660/770:"; echo "$F_LEFT"; exit 1; fi
echo "  после нормализации: 2770/660/770 не осталось (кроме разрешённых: btmp/lastlog 660 root:utmp)"
' || die "проверка прав rootfs не пройдена (см. список выше)"
# --- fixed10 (ТЗ 11.11.2026, Этап 2): явные режимы корня и защита от 2755 ---
# В fixed9 /usr и /etc оказались 2755, а / — 555 (для / механизм не
# установлен полностью: ctime 09:10:47, во время pacstrap). После pacstrap
# и customize ставим их ЯВНО в 0755 и снимаем setgid с каталогов публичных
# путей (usr/etc/home/opt/srv — там спецбитов быть не должно). Легитимные
# режимы пакетов НЕ трогаем: /var/log/journal (2755 systemd-journal),
# /var/lib/tpm2-tss/*, /run/* (tmpfs, в установку не копируется) — только
# сообщаем их количество для видимости.
log "--- шаг 11б (fixed10): явные режимы / /usr /etc = 0755, снятие setgid с публичных путей ---"
"$BUILD_ENV" --exec -- bash -c '
set -euo pipefail
A=/xros/work/x86_64/airootfs
chmod 755 "$A" "$A/usr" "$A/etc"
for p in usr etc home opt srv; do
  find "$A/$p" -type d -perm /2000 -exec chmod a-s {} + 2>/dev/null || true
done
echo "  режимы: / = $(stat -c %a "$A"), /usr = $(stat -c %a "$A/usr"), /etc = $(stat -c %a "$A/etc")"
echo "  каталогов с setgid в публичных путях после снятия: $(find "$A/usr" "$A/etc" "$A/home" "$A/opt" "$A/srv" -type d -perm /2000 2>/dev/null | wc -l)"
echo "  каталогов с setgid вне публичных путей (legit: journal/tpm2-tss/run, только для сведения): $(find "$A" -type d -perm /2000 2>/dev/null | grep -vE "^$A/(usr|etc|home|opt|srv)(/|$)" | wc -l)"
' || die "явные режимы / /usr /etc не заданы"
# Доступность для живого пользователя xros (uid 1000): то, что раньше
# падало с EACCES, теперь должно читаться/исполняться от xros.
"$BUILD_ENV" --exec -- arch-chroot /xros/work/x86_64/airootfs bash -c '
set -euo pipefail
runuser -u xros -- test -x /usr/bin/plasmashell
runuser -u xros -- test -x /usr/bin/kwin_wayland
runuser -u xros -- test -x /usr/bin/sddm-greeter-qt6
runuser -u xros -- test -r /etc/passwd
runuser -u xros -- test -r /home/xros/.config/kdeglobals
runuser -u xros -- test -r /etc/xdg/autostart/xros-welcome.desktop
runuser -u xros -- test -x /usr/bin/dbus-broker-launch
echo "доступность от пользователя xros: OK (plasmashell, kwin_wayland, sddm-greeter, /etc, /home/xros)"
' || die "проверка доступности от пользователя xros не пройдена"

# --- шаг 11в: автоматический аудит прав (регрессионный контроль) ---------
# Скрипт scripts/check-rootfs-perms.sh — единственный источник истины
# для проверки прав rootfs (дефект 2770 от 10.11.2026). Он НЕ исправляет
# права, а только проверяет и ПАДАЕТ с точной причиной. Вызов здесь —
# gate сборки: при любом нарушении сборка останавливается ДО mkarchiso.
# Регрессионный тест: scripts/test-perms-regression.sh (доказывает,
# что чекер ловит искусственно внесённое нарушение на ОТДЕЛЬНОЙ
# тестовой копии rootfs, не трогая рабочий rootfs).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/check-rootfs-perms.sh" "$AIROOTFS" || die "автоматический аудит прав rootfs не пройден (см. выше); исправьте исходники сборки, а не права вручную"

log "=== ГОТОВО: rootfs подготовлен вручную ==="
log "  airootfs: $AIROOTFS ($(du -sh "$AIROOTFS" | cut -f1), файлов: $(find "$AIROOTFS" | wc -l))"
log "  Следующий шаг (отдельно): mkarchiso -v -w /xros/work -o /xros/out /xros/profile внутри build-env"
log "  Маркеры base.* на месте — mkarchiso пропустит pacstrap"
log "  Лог: $LOG"
