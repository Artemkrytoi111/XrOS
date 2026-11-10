#!/usr/bin/env bash
# XrOS — собственное изолированное окружение сборки (build environment).
#
# Назначение: заменить зависимость от чужого chroot (другого проекта)
# своим механизмом. Скрипт управляет собственным Arch-rootfs проекта:
#   ~/workspace/xros/build-env/root.x86_64/
# и выполняет внутри него Rust-сборки, makepkg и проверки grub.
#
# !! ВАЖНО — ЧТО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ !!
#   * Не трогает другие проекты и вообще ничего вне ~/workspace/xros.
#   * Не собирает ISO (это scripts/build.sh, этап 10) и не публикует
#     пакеты/репозитории.
#   * Не симулирует успех: если инструмент недоступен, скрипт честно
#     завершается ошибкой и говорит, чего не хватает.
#
# Механизм (почему именно так):
#   Хост сборки — НЕ Arch (обычно Ubuntu/Debian): pacstrap, arch-chroot,
#   mkarchiso, cargo, rustc, makepkg на хосте ОТСУТСТВУЮТ. Поэтому rootfs
#   создаётся из официального Arch bootstrap-тарболла
#   (https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst,
#   ~120 МБ, подпись .sig проверяется по GPG), а пакеты внутрь
#   устанавливаются штатным pacman изнутри rootfs. Это тот же подход,
#   что использует Arch Wiki для установки из-под другой системы, только
#   без pacstrap (его на хосте нет) — вместо него `pacman -r <rootfs>`.
#   Команды внутри rootfs выполняются через systemd-nspawn (есть на
#   хосте; изоляция mount/net/pid-неймспейсов, автоочистка монтирований
#   при выходе). Если nspawn недоступен — запасной путь: unshare
#   --mount + chroot с ручным монтированием proc/dev (минимальный,
#   только то, что нужно для запуска команд).
#   На НАСТОЯЩЕМ Arch-хосте тот же скрипт может использовать pacstrap:
#   если `pacstrap` найден, --init вызывает его вместо bootstrap-пути
#   (см. init_via_pacstrap). Логика остальных режимов от пути создания
#   rootfs не зависит.
#
# makepkg — ТОЛЬКО от непривилегированного пользователя:
#   внутри rootfs создаётся пользователь `builder` (uid 1000, как принято
#   в Arch); makepkg и cargo build выполняются от него (nspawn --user
#   или runuser в chroot-режиме). От root makepkg отказывается работать —
#   и правильно делает: PKGBUILD исполняет произвольный код.
#   Кэш cargo: /home/builder/.cargo внутри rootfs (CARGO_HOME).
#   Cargo.lock из src/ фиксирует версии; после сборки он копируется
#   обратно в src/ из копии внутри rootfs (см. do_build_rust).
#
# Первая сборка Rust — ОНЛАЙН: xros-install-gui-rs тянет eframe 0.32
# (~300 крейтов в Cargo.lock). В свежем rootfs кэша cargo нет, поэтому
# первый прогон --build-rust идёт с сетью (cargo fetch), а повторные —
# с --offline. Офлайн без предзагруженного кэша НЕВОЗМОЖЕН, и скрипт
# так и говорит, вместо того чтобы молча падать.
#
# Режимы:
#   --check | --dry-run   только проверка окружения хоста и состояния
#                         rootfs. Ничего не скачивает, ничего не создаёт,
#                         ничего не монтирует. Код выхода 0 — можно идти
#                         к --init, 1 — чего-то не хватает (список в выводе).
#   --init                создать rootfs (скачивает bootstrap ~120 МБ +
#                         устанавливает base-devel, rust, grub, pacman —
#                         итого ~2–3 ГБ на диске; нужен root и сеть).
#                         Повторный запуск безопасен: существующий rootfs
#                         не пересоздаётся, только доустанавливается
#                         недостающее (см. --reinit для полного пересоздания).
#   --reinit              удалить rootfs и создать заново (требует --confirm).
#   --exec -- <cmd...>    выполнить команду внутри rootfs от root.
#   --build-rust [--offline]
#                         cargo build --release для src/xros-cli и
#                         src/xros-install-gui-rs от пользователя builder.
#                         Без --offline — первая (онлайн) сборка с fetch.
#   --makepkg <pkgdir>    makepkg в каталоге пакета от пользователя builder.
#                         <pkgdir> — путь внутри проекта, например
#                         packages/xros-cli. Готовый .pkg.tar.zst остаётся
#                         в том же каталоге на хосте.
#   --grub-check [файлы...]
#                         grub-script-check для файлов grub из профиля
#                         (по умолчанию profile/grub/grub.cfg, если есть).
#   --clean               снять зависшие bind-монтирования и убрать
#                         временные файлы (rootfs НЕ трогает).
#   --destroy             удалить весь build-env/ (требует --confirm).
#   --help                эта справка.
#
# Требования к хосту для --init/--exec (проверяются в --check):
#   * Linux x86_64, root (EUID 0) — для монтирований и nspawn.
#   * curl, tar, gpg — скачивание и проверка подписи bootstrap.
#   * zstd — распаковка .tar.zst (если нет, --init предложит
#     `apt-get install -y zstd`; без него — честная ошибка).
#   * systemd-nspawn (предпочтительно) ИЛИ unshare+chroot (запасной путь).
#   * Свободное место: >= 10 ГБ (bootstrap + пакеты + cargo-кэш + target/).
#   * Сеть до geo.mirror.pkgbuild.com и archlinux.org.
#
# Ограничения и проверенное состояние, честно зафиксированные 2026-11-10
# (см. также docs/final-refinement/build-env.md):
#   * Хост (Ubuntu 24.04, user namespace): НЕТ pacstrap/arch-chroot/
#     mkarchiso/cargo/rustc/makepkg/docker/podman на хосте; zstd 1.5.5
#     установлен через apt-get. systemd-nspawn 255 есть, но НЕ РАБОТАЕТ
#     с реальным rootfs на этом хосте: не может смонтировать sysfs
#     в user namespace (EPERM) — скрипт определяет это пробой
#     nspawn_usable() и использует запасной путь unshare+chroot.
#   * --init ПРОВЕРЕН (2026-11-10, run4): rootfs
#     build-env/root.x86_64, ~2.5 ГБ на момент создания (117 пакетов:
#     rust 1.99.1, grub 2.16, python-pyqt6, qt6-base...), bootstrap
#     проверен по GPG (Pierre Schmitz). Повторный --init безопасен:
#     видит метку init-done и ничего не пересоздаёт (проверено run5).
#   * --build-rust ПРОВЕРЕН: обе Rust-программы собраны онлайн
#     (eframe 0.32, ~300 крейтов), повторный прогон --offline
#     переиспользует кэш (cargo: всё fresh, бинари байт-в-байт те же).
#   * makepkg ПРОВЕРЕН: все 4 PKGBUILD собраны от builder и установлены
#     в rootfs; повторный прогон тоже проходит (--force + исключение
#     *.pkg.tar.zst из копии).
#   * --grub-check ПРОВЕРЕН: profile/grub/grub.cfg и loopback.cfg OK.
#   * --clean ПРОВЕРЕН: висячих монтирований нет (/proc/mounts: 0 xros
#     до и после), rootfs не трогается.
#   * Известные особенности rootfs (учтены в скрипте): /dev изначально
#     пуст — устройства пробрасываются пофайлово + симлинки /dev/fd,
#     /dev/stdin/stdout/stderr (без них makepkg падает на строке 713);
#     CheckSpace отключён в /etc/pacman.conf (в chroot / не является
#     точкой монтирования, pacman не определяет свободное место);
#     /etc/hosts хоста копируется внутрь (иначе прокси резолвится
#     в мёртвый адрес); CA-переменные окружения хоста сбрасываются
#     для chroot (chroot_env), иначе curl даёт ошибку 77.
#   * Egress-TLS хоста: если на хосте есть /run/hatch/egress-tls или
#     /usr/local/share/ca-certificates/hatch-egress-ca.crt, они
#     пробрасываются в rootfs (только если существуют; отсутствие —
#     не ошибка).
set -u
# set -e НЕ ставим глобально: часть проверок должна пережить ошибку
# и честно доложить о ней; критичные места используют die()/проверки.

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ENV="$PROJECT/build-env"
ROOTFS="$BUILD_ENV/root.x86_64"
STATE_DIR="$BUILD_ENV/state"
LOG_DIR="$BUILD_ENV/logs"
BOOTSTRAP_URL="${XROS_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"
BOOTSTRAP_SIG_URL="${XROS_BOOTSTRAP_SIG_URL:-https://archlinux.org/iso/latest/archlinux-bootstrap-x86_64.tar.zst.sig}"
BOOTSTRAP_FILE="$BUILD_ENV/archlinux-bootstrap-x86_64.tar.zst"
BOOTSTRAP_SIG="$BOOTSTRAP_FILE.sig"
BUILD_USER="builder"
BUILD_UID="1000"
LOCK_FILE="$BUILD_ENV/.lock"
# Метки состояния (внутри build-env/, НЕ внутри rootfs):
INIT_MARKER="$STATE_DIR/init-done"
DEPS_MARKER="$STATE_DIR/deps-fetched"

# --- защита от перекрёстных путей: этот скрипт работает ТОЛЬКО внутри
# --- проекта XrOS (каталог должен называться `xros` и содержать
# --- profile/ и этот самый скрипт) и никогда не обращается наружу.
case "$PROJECT" in
  */xros) ;;
  *) echo "ОШИБКА: скрипт запущен вне проекта XrOS: $PROJECT" >&2; exit 2;;
esac
[[ -d "$PROJECT/profile" && -f "$PROJECT/scripts/xros-build-env.sh" ]] \
  || { echo "ОШИБКА: $PROJECT не похож на проект XrOS (нет profile/ или scripts/xros-build-env.sh)" >&2; exit 2; }

log()  { printf '[xros-build-env] %s\n' "$*"; }
warn() { printf '[xros-build-env] ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2; }
die()  { printf '[xros-build-env] ОШИБКА: %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "нужен root (EUID 0): монтирования и nspawn требуют привилегий. Запустите через sudo."
}

# Блокировка от параллельных запусков; снимается trap'ом.
acquire_lock() {
  mkdir -p "$BUILD_ENV"
  exec 9>"$LOCK_FILE" || die "не могу открыть lock-файл $LOCK_FILE"
  flock -n 9 || die "другой экземпляр xros-build-env.sh уже работает (lock $LOCK_FILE)"
}

# --- очистка временных ресурсов -------------------------------------------
# nspawn сам чистит свои монтирования при выходе. В chroot-режиме мы
# монтируем proc/dev вручную — их и снимаем здесь. Список ведётся в файле.
MOUNTS_FILE="$BUILD_ENV/.mounts"
cleanup() {
  if [[ -f "$MOUNTS_FILE" ]]; then
    # Снимать в обратном порядке создания.
    tac "$MOUNTS_FILE" 2>/dev/null | while read -r mp; do
      [[ -n "$mp" ]] && umount "$mp" 2>/dev/null || true
    done
    rm -f "$MOUNTS_FILE"
  fi
  # .inner.*.sh — временные скрипты chroot-пути; у каждого вызова свой
  # файл (mktemp), иначе параллельные вызовы (tar-поток в copy_to_builder)
  # перетирали бы один общий .inner.sh друг другу.
  rm -f "$BUILD_ENV"/.inner.*.sh 2>/dev/null || true
}
trap cleanup EXIT

# --- проверки окружения -----------------------------------------------------
# check_host: только чтение, без скачиваний и без записей (кроме stdout).
# Возвращает 0, если хост готов к --init; 1 — если чего-то не хватает.
# check_rootfs: состояние собственного rootfs (без хоста).
check_host() {
  local missing=0
  echo "== Хост: проверка окружения для XrOS build-env =="
  echo "Проект:        $PROJECT"
  echo "Build-env:     $BUILD_ENV"
  echo "ОС хоста:      $(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
  echo "Ядро/арх:      $(uname -r) / $(uname -m)"
  echo "EUID:          ${EUID:-$(id -u)} $( [[ "${EUID:-$(id -u)}" -eq 0 ]] && echo '(root — ok)' || echo '(НЕ root — для --init нужен root)' )"
  echo "Свободно в $PROJECT: $(df -h "$PROJECT" | awk 'NR==2 {print $4}') (нужно >= 10 ГБ)"
  echo
  echo "-- Инструменты хоста --"
  local t
  for t in curl tar gpg systemd-nspawn unshare chroot runuser flock; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "  $t: $(command -v "$t")"
    else
      echo "  $t: ОТСУТСТВУЕТ"
      case "$t" in curl|tar|gpg) missing=1;; esac
    fi
  done
  if command -v zstd >/dev/null 2>&1; then
    echo "  zstd: $(command -v zstd)"
  else
    echo "  zstd: ОТСУТСТВУЕТ (нужен для распаковки bootstrap .tar.zst; ставится: apt-get install -y zstd)"
    missing=1
  fi
  for t in pacstrap arch-chroot mkarchiso cargo rustc makepkg docker podman; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "  $t: $(command -v "$t") (наличие НЕ требуется, просто к сведению)"
    else
      echo "  $t: отсутствует (ожидаемо на не-Arch хосте)"
    fi
  done
  echo
  echo "-- Исполнитель внутри rootfs --"
  if command -v systemd-nspawn >/dev/null 2>&1; then
    echo "  systemd-nspawn: $(systemd-nspawn --version | head -1) — основной путь"
  elif command -v unshare >/dev/null 2>&1 && command -v chroot >/dev/null 2>&1; then
    echo "  systemd-nspawn отсутствует; запасной путь unshare+chroot доступен"
  else
    echo "  НЕТ ни systemd-nspawn, ни unshare+chroot — выполнять команды внутри rootfs нечем"
    missing=1
  fi
  echo
  echo "-- Сеть (только HEAD, без скачиваний) --"
  if curl -fsSI --max-time 10 https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst >/dev/null 2>&1; then
    echo "  geo.mirror.pkgbuild.com: доступен (bootstrap URL отвечает)"
  else
    echo "  geo.mirror.pkgbuild.com: НЕДОСТУПЕН — --init не сможет скачать bootstrap"
    missing=1
  fi
  if curl -fsSI --max-time 10 https://archlinux.org >/dev/null 2>&1; then
    echo "  archlinux.org: доступен (подпись .sig)"
  else
    echo "  archlinux.org: НЕДОСТУПЕН"
    missing=1
  fi
  echo
  echo "-- Место --"
  local free_kb
  free_kb="$(df -k "$PROJECT" | awk 'NR==2 {print $4}')"
  if [[ "$free_kb" -ge 10485760 ]]; then
    echo "  свободно >= 10 ГБ — ok"
  else
    echo "  свободно МЕНЬШЕ 10 ГБ — для rootfs + cargo-кэша может не хватить"
    missing=1
  fi
  echo
  check_rootfs
  echo
  if [[ "$missing" -eq 0 ]]; then
    echo "ИТОГ --check: хост ГОТОВ к --init (недостаёт только самого rootfs, если его нет)."
    return 0
  else
    echo "ИТОГ --check: хост НЕ ГОТОВ — см. пункты с ОТСУТСТВУЕТ/НЕДОСТУПЕН выше."
    return 1
  fi
}

check_rootfs() {
  echo "-- Собственный rootfs ($ROOTFS) --"
  if [[ -d "$ROOTFS/usr/bin" ]]; then
    echo "  rootfs: существует"
    local tool
    for tool in pacman cargo rustc makepkg grub-script-check; do
      if [[ -x "$ROOTFS/usr/bin/$tool" ]]; then
        echo "  $tool: есть внутри rootfs"
      else
        echo "  $tool: НЕТ внутри rootfs (нужен --init / доустановка)"
      fi
    done
    if grep -q "^$BUILD_USER:" "$ROOTFS/etc/passwd" 2>/dev/null; then
      echo "  пользователь $BUILD_USER: есть (uid $(grep "^$BUILD_USER:" "$ROOTFS/etc/passwd" | cut -d: -f3))"
    else
      echo "  пользователь $BUILD_USER: НЕТ (создаётся при --init)"
    fi
    [[ -f "$INIT_MARKER" ]] && echo "  метка init-done: есть" || echo "  метка init-done: нет"
    [[ -f "$DEPS_MARKER" ]] && echo "  метка deps-fetched: есть (первая онлайн-сборка Rust уже была)" || echo "  метка deps-fetched: нет (первая сборка Rust должна быть онлайн)"
  else
    echo "  rootfs: НЕ СОЗДАН — нужен --init (скачает bootstrap ~120 МБ и установит пакеты ~2–3 ГБ)"
  fi
}

# --- создание rootfs ---------------------------------------------------------
ensure_zstd() {
  if command -v zstd >/dev/null 2>&1; then return 0; fi
  warn "zstd не найден. Пробую установить через apt (только если хост Debian/Ubuntu и есть apt)..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq zstd \
      || die "не удалось установить zstd через apt. Установите вручную: apt-get install -y zstd"
  else
    die "zstd отсутствует, а apt недоступен. Установите zstd вручную — без него нельзя распаковать bootstrap .tar.zst."
  fi
}

download_bootstrap() {
  mkdir -p "$BUILD_ENV" "$LOG_DIR"
  if [[ -s "$BOOTSTRAP_FILE" ]]; then
    log "bootstrap уже скачан: $BOOTSTRAP_FILE — повторная загрузка не нужна"
  else
    log "скачиваю bootstrap (~120 МБ): $BOOTSTRAP_URL"
    curl -fL --progress-bar -o "$BOOTSTRAP_FILE" "$BOOTSTRAP_URL" \
      || die "не удалось скачать bootstrap. Проверьте сеть и URL: $BOOTSTRAP_URL"
    log "скачано: $(du -h "$BOOTSTRAP_FILE" | cut -f1)"
  fi
  log "скачиваю подпись: $BOOTSTRAP_SIG_URL"
  curl -fL -s -o "$BOOTSTRAP_SIG" "$BOOTSTRAP_SIG_URL" \
    || warn "подпись .sig не скачалась — проверка GPG будет пропущена (НЕ рекомендуется, см. вывод)"
  if [[ -s "$BOOTSTRAP_SIG" ]]; then
    log "проверяю подпись GPG (ключ Arch берётся с keyserver.ubuntu.com)..."
    if ! gpg --keyserver keyserver.ubuntu.com --keyserver-options auto-key-retrieve \
        --verify "$BOOTSTRAP_SIG" "$BOOTSTRAP_FILE" 2>/tmp/xros-gpg-verify.log; then
      # Запасной путь (2026-11-10, проверено на хосте): dirmngr НЕ ходит
      # через egress-прокси хоста — ни hkp:// (порт 11371), ни hkps://
      # (keyserver receive failed). А curl через тот же прокси работает.
      # Поэтому тянем ключ по HTTPS с keyserver.ubuntu.com/pks/lookup
      # и импортируем его, после чего повторяем проверку. Ключ берём не
      # из воздуха, а из самой подписи: fingerprint в строке
      # "using ... key <40-hex>"; последние 16 hex — keyid.
      warn "авто-получение ключа с keyserver не сработало — пробую запасной путь (curl + HTTPS)..."
      local fp keyid keyfile
      fp="$(grep -oE '[0-9A-F]{40}' /tmp/xros-gpg-verify.log | tail -1)"
      keyid="${fp:24:16}"
      keyfile="$BUILD_ENV/.bootstrap-signing-key.asc"
      if [[ -n "$keyid" ]] && curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${keyid}" -o "$keyfile" \
          && gpg --import "$keyfile" >/dev/null 2>&1; then
        log "ключ $keyid импортирован через curl; повторяю проверку подписи..."
        gpg --verify "$BOOTSTRAP_SIG" "$BOOTSTRAP_FILE" \
          || die "подпись bootstrap НЕ СОВПАЛА. Файл не используется — удалите $BOOTSTRAP_FILE и разберитесь, прежде чем продолжать."
      else
        cat /tmp/xros-gpg-verify.log >&2
        die "подпись bootstrap НЕ ПРОВЕРЕНА (ключ получить не удалось). Файл не используется — удалите $BOOTSTRAP_FILE и разберитесь, прежде чем продолжать."
      fi
    fi
    log "подпись bootstrap: OK"
  fi
}

extract_bootstrap() {
  ensure_zstd
  log "распаковываю bootstrap в $ROOTFS ..."
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  # tar из .tar.zst: zstd -d в конвейер (без промежуточного .tar на диске).
  # --no-same-owner (2026-11-10, проверено на хосте): rootfs лежит на
  # overlayfs в user namespace, и chown на произвольные uid/gid там
  # падает с EPERM (tar: «Cannot change ownership to uid 971» — всего
  # 2 файла, но tar из-за них завершается с ошибкой и скрипт умирает).
  # Без --same-owner все файлы остаются за root — для сборочного
  # chroot это нормально (пакеты при установке выставят своих
  # владельцев там, где это возможно; см. также create_builder_user).
  zstd -dc -- "$BOOTSTRAP_FILE" | tar -x -C "$BUILD_ENV" --numeric-owner --no-same-owner \
    || die "распаковка bootstrap не удалась"
  # tar создаёт $BUILD_ENV/root.x86_64 — это и есть наш rootfs.
  [[ -d "$ROOTFS/usr/bin" ]] || die "после распаковки нет $ROOTFS/usr/bin — архив не тот, что ожидался"
  log "bootstrap распакован."
}

# chroot_env: запуск команды внутри rootfs с ОЧИЩЕННЫМ от хостовых
# CA-переменных окружением. На хосте заданы SSL_CERT_FILE, CURL_CA_BUNDLE,
# GIT_SSL_CAINFO и др., указывающие на /run/hatch/egress-tls/*.pem —
# внутри chroot этих путей НЕТ, и curl/pacman падают с
# «error adding trust anchors» (код 77). Без этих переменных инструменты
# берут штатный бандл rootfs /etc/ssl/certs/ca-certificates.crt, куда
# prepare_rootfs_for_pacman уже внёс CA хоста через update-ca-trust.
chroot_env() {
  env -u CURL_CA_BUNDLE -u SSL_CERT_FILE -u GIT_SSL_CAINFO \
      -u REQUESTS_CA_BUNDLE -u NODE_EXTRA_CA_CERTS -u AWS_CA_BUNDLE \
      chroot "$ROOTFS" "$@"
}

# Подготовка rootfs к установке пакетов: bind самого себя (требуется для
# pacman -r), resolv.conf, зеркало, инициализация ключей pacman.
prepare_rootfs_for_pacman() {
  # Пакет filesystem ставит на / права 555 (штатно для Arch) — после
  # каждой установки пакетов корень rootfs снова read-only для записи;
  # перед работой внутри rootfs возвращаем 755 (см. также run_in_rootfs).
  chmod 755 "$ROOTFS" 2>/dev/null || true
  mount --bind "$ROOTFS" "$ROOTFS" 2>/dev/null || warn "bind rootfs не удался (возможно, уже смонтирован)"
  echo "$ROOTFS" >> "$MOUNTS_FILE"
  mkdir -p "$ROOTFS/etc/pacman.d"
  printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > "$ROOTFS/etc/pacman.d/mirrorlist"
  cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
  # /etc/hosts ХОСТА — обязательно: без него имя hatch-egress-proxy
  # внутри chroot резолвится через DNS шлюза в мёртвый 198.18.137.129,
  # и прокси рвёт соединение (Connection reset by peer); в /etc/hosts
  # хоста — правильные 198.19.0.1 и fd8b:4f84:7d32:99::1 (2026-11-10).
  cp -L /etc/hosts "$ROOTFS/etc/hosts" 2>/dev/null || true
  # /dev: в распакованном bootstrap /dev ПУСТ и имеет права 555.
  # Bind ВСЕГО /dev с хоста невозможен (user namespace: bind чужого
  # tmpfs падает с EPERM), mknod тоже запрещён — поэтому устройства
  # пробрасываются ПОФАЙЛОВО: пустые файлы-цели + mount --bind каждого
  # устройства (null, zero, full, random, urandom, tty). Проверено:
  # после этого внутри chroot /dev/null — настоящее символьное
  # устройство, /dev/urandom отдаёт энтропию.
  chmod 755 "$ROOTFS/dev" 2>/dev/null || true
  mkdir -p "$ROOTFS/dev/pts" "$ROOTFS/dev/shm" "$ROOTFS/proc"
  local dev
  for dev in null zero full random urandom tty; do
    touch "$ROOTFS/dev/$dev" 2>/dev/null || true
    if mount --bind "/dev/$dev" "$ROOTFS/dev/$dev" 2>/dev/null; then
      echo "$ROOTFS/dev/$dev" >> "$MOUNTS_FILE"
    else
      warn "bind /dev/$dev в rootfs не удался — команды внутри chroot могут не работать без этого устройства"
    fi
  done
  # /dev/fd, /dev/stdin, /dev/stdout, /dev/stderr — ОБЯЗАТЕЛЬНЫ для makepkg
  # (и для bash process substitution вообще): без них create_package()
  # в /usr/sbin/makepkg (строка 713, `[[ -n ${!orig} ]]` после
  # `read ... < <(printf ...)`) падает с «orig: invalid indirect
  # expansion», упаковка прерывается, а процесс makepkg продолжает main
  # flow как будто INFAKEROOT=0 — второй «Making package» и повторный
  # enter_fakeroot → «nested operation not yet supported» (доказано
  # 2026-11-10 по /tmp/inner-x.log:12554). Симлинки на /proc/self/fd
  # (proc монтируется ниже) создаются хостом через ln -sf, mknod не
  # нужен, переживают перезапуски rootfs.
  ln -sf /proc/self/fd "$ROOTFS/dev/fd" 2>/dev/null || true
  ln -sf /proc/self/fd/0 "$ROOTFS/dev/stdin" 2>/dev/null || true
  ln -sf /proc/self/fd/1 "$ROOTFS/dev/stdout" 2>/dev/null || true
  ln -sf /proc/self/fd/2 "$ROOTFS/dev/stderr" 2>/dev/null || true
  # CheckSpace — ОТКЛЮЧИТЬ в rootfs: / внутри chroot не является точкой
  # монтирования в /proc/mounts (chroot — это каталог, а не mount),
  # поэтому pacman -U/-S падает с «could not determine root mount point
  # /» + «not enough free disk space» (проверено 2026-11-10). Место на
  # хосте контролируется отдельно (133 ГБ свободно); для build-chroot
  # проверка места не нужна.
  sed -i 's/^CheckSpace$/# CheckSpace — отключено для build-chroot (см. комментарий выше)/' \
    "$ROOTFS/etc/pacman.conf" 2>/dev/null || true
  mount -t proc proc "$ROOTFS/proc" 2>/dev/null \
    && echo "$ROOTFS/proc" >> "$MOUNTS_FILE" \
    || warn "монтирование proc в rootfs не удалось"
  mount -t tmpfs tmpfs "$ROOTFS/dev/shm" 2>/dev/null \
    && echo "$ROOTFS/dev/shm" >> "$MOUNTS_FILE" || true
  # devpts — по возможности (не критично для неинтерактивных сборок).
  mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null \
    && echo "$ROOTFS/dev/pts" >> "$MOUNTS_FILE" || true
  # Egress-TLS хоста: пробросить, только если существует на хосте.
  if [[ -f /usr/local/share/ca-certificates/hatch-egress-ca.crt ]]; then
    mkdir -p "$ROOTFS/etc/ca-certificates/trust-source/anchors"
    cp -L /usr/local/share/ca-certificates/hatch-egress-ca.crt \
      "$ROOTFS/etc/ca-certificates/trust-source/anchors/" 2>/dev/null || true
  fi
  log "инициализирую ключи pacman внутри rootfs (может занять минуту)..."
  if [[ ! -d "$ROOTFS/etc/pacman.d/gnupg" ]]; then
    chroot_env pacman-key --init >/dev/null 2>&1 \
      || warn "pacman-key --init завершился с ошибкой — проверьте вручную"
  else
    log "ключи pacman уже инициализированы (gnupg существует) — пропускаю --init"
  fi
  chroot_env pacman-key --populate archlinux >/dev/null 2>&1 \
    || warn "pacman-key --populate завершился с ошибкой"
  chroot_env update-ca-trust extract 2>/dev/null || true
}

install_build_tools() {
  log "устанавливаю base-devel, rust, grub, pacman-contrib (pacman внутри rootfs; ~1–2 ГБ)..."
  # ВАЖНО (2026-11-10): pacman вызывается ВНУТРИ rootfs через chroot,
  # а не `pacman --root` с хоста — на не-Arch хосте pacman ОТСУТСТВУЕТ
  # (старый код падал бы с «pacman: command not found»). Внутри chroot
  # сеть — сеть хоста, зеркало и resolv.conf подготовлены в
  # prepare_rootfs_for_pacman; кэш — штатный /var/cache/pacman/pkg
  # внутри rootfs (bind pkgcache — в run_in_rootfs для nspawn-режима).
  # Пакеты: base-devel (gcc/makepkg/fakeroot), rust (cargo+rustc),
  # grub (grub-script-check), git (для PKGBUILD с git-источниками).
  # Плюс ВНЕШНИЕ зависимости всех 4 PKGBUILD проекта (dialog, rsync,
  # parted, dosfstools, e2fsprogs, btrfs-progs, xfsprogs, gptfdisk,
  # efibootmgr, os-prober, libxkbcommon-x11, python-pyqt6): они нужны,
  # чтобы `makepkg --syncdeps` от builder'а находил всё уже
  # установленным и не пытался ставить через sudo (которого у builder'а
  # нет). Собственная зависимость xros-branding ставится отдельно:
  # сначала собирается и устанавливается пакет xros-branding
  # (pacman -U внутри rootfs), и только потом остальные три пакета.
  chroot_env pacman -Sy --noconfirm base-devel rust grub git pacman-contrib \
    dialog rsync parted dosfstools e2fsprogs btrfs-progs xfsprogs gptfdisk \
    efibootmgr os-prober libxkbcommon-x11 python-pyqt6 \
    || die "установка пакетов в rootfs не удалась"
  log "пакеты установлены."
}

create_builder_user() {
  if grep -q "^$BUILD_USER:" "$ROOTFS/etc/passwd" 2>/dev/null; then
    log "пользователь $BUILD_USER уже есть внутри rootfs"
    return 0
  fi
  log "создаю пользователя $BUILD_USER (uid $BUILD_UID) внутри rootfs..."
  chroot_env useradd -m -u "$BUILD_UID" -s /bin/bash "$BUILD_USER" \
    || die "не удалось создать пользователя $BUILD_USER"
  # chown домашнего каталога на overlay-хосте падает с EPERM
  # (user namespace + overlayfs: chown на произвольные uid/gid
  # запрещён) — поэтому chown НЕ фатален: если он не сработал,
  # домашний каталог делается доступным для записи builder'у через
  # chmod, а .cargo/.cache создаются ОТ builder'а (runuser): созданные
  # им файлы сразу принадлежат ему, chown не нужен. Безопасность
  # makepkg от этого не страдает: PKGBUILD по-прежнему исполняется
  # НЕ от root. 777 на домашнем каталоге — осознанный компромисс
  # одноразового сборочного chroot (в ISO build-env не попадает).
  mkdir -p "$ROOTFS/home/$BUILD_USER/.cargo" "$ROOTFS/home/$BUILD_USER/.cache"
  if chroot_env chown -R "$BUILD_USER:$BUILD_USER" "/home/$BUILD_USER" 2>/dev/null; then
    log "домашний каталог $BUILD_USER выдан владельцу (chown сработал)"
  else
    warn "chown /home/$BUILD_USER не сработал (overlay/userns) — делаю каталог записываемым для builder'а"
    rm -rf "$ROOTFS/home/$BUILD_USER/.cargo" "$ROOTFS/home/$BUILD_USER/.cache"
    chmod 777 "$ROOTFS/home/$BUILD_USER"
    chroot_env runuser -u "$BUILD_USER" -- mkdir -p "/home/$BUILD_USER/.cargo" "/home/$BUILD_USER/.cache" \
      || die "не удалось создать .cargo/.cache от пользователя $BUILD_USER"
  fi
  # Проверка: builder реально может писать в свой домашний каталог.
  chroot_env runuser -u "$BUILD_USER" -- touch "/home/$BUILD_USER/.cargo/.write-test" \
    || die "пользователь $BUILD_USER не может писать в /home/$BUILD_USER — сборка от builder'а невозможна"
  rm -f "$ROOTFS/home/$BUILD_USER/.cargo/.write-test"
  log "пользователь $BUILD_USER создан; CARGO_HOME=/home/$BUILD_USER/.cargo"
}

init_via_pacstrap() {
  # Только на настоящем Arch-хосте: pacstrap делает ровно то же, что
  # bootstrap+pacman -r, но штатным образом.
  log "на хосте есть pacstrap — использую штатный путь (Arch-хост)"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  pacstrap -c -d "$ROOTFS" base base-devel rust grub git pacman-contrib \
    || die "pacstrap не удался"
  create_builder_user
}

do_init() {
  need_root
  acquire_lock
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  if [[ -f "$INIT_MARKER" && -d "$ROOTFS/usr/bin" ]]; then
    log "rootfs уже инициализирован (метка $INIT_MARKER). Проверяю недостающее..."
    create_builder_user
    log "готово. Для полного пересоздания: $0 --reinit --confirm"
    return 0
  fi
  if [[ -d "$ROOTFS/usr/bin" ]]; then
    # Возобновление после обрыва (например, сеть упала посреди установки
    # пакетов): bootstrap уже распакован — НЕ пересоздаём rootfs, а
    # продолжаем с подготовки и установки пакетов. pacman -Sy идемпотентен.
    log "rootfs уже распакован, но init не завершён — возобновляю с установки пакетов..."
    prepare_rootfs_for_pacman
    install_build_tools
    create_builder_user
    touch "$INIT_MARKER"
    log "init ГОТОВ: rootfs $ROOTFS"
    log "следующий шаг: первая ОНЛАЙН-сборка Rust: $0 --build-rust"
    log "(она скачает ~300 крейтов eframe; повторные сборки — с --offline)"
    return 0
  fi
  if command -v pacstrap >/dev/null 2>&1; then
    init_via_pacstrap
  else
    download_bootstrap
    extract_bootstrap
    prepare_rootfs_for_pacman
    install_build_tools
    create_builder_user
  fi
  touch "$INIT_MARKER"
  log "init ГОТОВ: rootfs $ROOTFS"
  log "следующий шаг: первая ОНЛАЙН-сборка Rust: $0 --build-rust"
  log "(она скачает ~300 крейтов eframe; повторные сборки — с --offline)"
}

# Проверка, работает ли systemd-nspawn на этом хосте (кэшируется в
# NSPAWN_USABLE на время одного запуска скрипта). На хосте в user
# namespace монтирование sysfs запрещено (EPERM), а nspawn всегда
# пытается смонтировать sysfs и падает — тогда единственный рабочий
# путь это unshare+chroot. Проба: монтирование sysfs в scratch-каталоге
# в приватном mount namespace.
nspawn_usable() {
  if [[ -n "${NSPAWN_USABLE:-}" ]]; then
    [[ "$NSPAWN_USABLE" -eq 1 ]]
    return $?
  fi
  local d
  d="$(mktemp -d /tmp/xros-nspawn-probe.XXXXXX 2>/dev/null)" || { NSPAWN_USABLE=0; return 1; }
  if unshare --mount -- sh -c 'mount -t sysfs sysfs "$1" 2>/dev/null' _ "$d" 2>/dev/null; then
    NSPAWN_USABLE=1
  else
    NSPAWN_USABLE=0
  fi
  rmdir "$d" 2>/dev/null || true
  [[ "$NSPAWN_USABLE" -eq 1 ]]
}

# copy_to_builder <src-в-/xros> <dest-в-home-builder> <strip> [exclude...]
# Копирование дерева из bind-монтированного проекта (/xros) в домашний
# каталог builder'а через tar-поток: root читает /xros и пишет tar в
# stdout, builder распаковывает его у себя. Нужно, потому что builder
# НЕ МОЖЕТ читать /xros напрямую: проект на хосте имеет права 2770
# root:nogroup, а builder не состоит в этой группе (права проекта на
# хосте менять нельзя); chown копий от root к builder'у тоже невозможен
# (overlay/userns, EPERM). Файлы, распакованные builder'ом, сразу
# принадлежат ему; tar сохраняет mtime (важно для инкрементной сборки
# cargo) и права. tar НЕ удаляет файлы, которых уже нет в источнике,
# поэтому для makepkg старые копии предварительно удаляются (см.
# do_makepkg), а для Rust target/ намеренно сохраняется между запусками
# (прерванная сборка продолжается инкрементно).
#   strip — сколько ведущих компонентов пути отбросить при распаковке
#   (для "src/xros-cli" — 2, для "branding" — 1).
#   exclude — относительные пути внутри src, исключаемые из архива
#   (например, "src/xros-cli/target").
copy_to_builder() {
  local src="$1" dest="$2" strip="$3"; shift 3
  local tar_args=()
  local ex
  for ex in "$@"; do tar_args+=(--exclude="$ex"); done
  run_in_rootfs builder -- mkdir -p "/home/$BUILD_USER/$dest" \
    || die "не удалось создать /home/$BUILD_USER/$dest"
  set -o pipefail
  run_in_rootfs root -- tar "${tar_args[@]}" -cf - -C /xros "$src" \
    | run_in_rootfs builder -- tar -xf - -C "/home/$BUILD_USER/$dest" --strip-components="$strip"
  local rc=$?
  set +o pipefail
  [[ "$rc" -eq 0 ]] || die "не удалось скопировать $src в /home/$BUILD_USER/$dest"
}

# --- выполнение команд внутри rootfs ----------------------------------------
# run_in_rootfs <user> -- <cmd...>
# user: root | builder. Основной путь — systemd-nspawn, запасной — chroot.
run_in_rootfs() {
  local user="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  [[ -d "$ROOTFS/usr/bin" ]] || die "rootfs не создан. Сначала: $0 --init"
  # Точка монтирования /xros внутри rootfs: пакет filesystem держит
  # корень rootfs в режиме 555, поэтому перед созданием каталога
  # возвращаем 755 (иначе mkdir падает с Permission denied).
  chmod 755 "$ROOTFS" 2>/dev/null || true
  mkdir -p "$ROOTFS/xros"
  # Проект bind-монтируется в /xros внутри rootfs (чтение исходников и
  # возврат готовых артефактов). ВАЖНО: от пользователя builder напрямую
  # в /xros писать НЕЛЬЗЯ (файлы проекта на хосте принадлежат root) —
  # поэтому сборки идут во временной копии внутри rootfs
  # (/home/builder/xros-build), а готовые бинари/пакеты/Cargo.lock
  # копируются обратно от root (см. do_build_rust/do_makepkg).
  mkdir -p "$BUILD_ENV/pkgcache" "$ROOTFS/var/cache/pacman/pkg"
  local nspawn_args=(
    --quiet --as-pid2
    --directory="$ROOTFS"
    --bind="$PROJECT:/xros"
    --bind="$BUILD_ENV/pkgcache:/var/cache/pacman/pkg"
  )
  # Рабочий каталог: root — /xros, builder — свой home. Builder НЕ МОЖЕТ
  # зайти в /xros (права 2770 root:nogroup на хосте), поэтому --chdir=/xros
  # для него ронял бы любую команду ещё до её запуска.
  if [[ "$user" == "builder" ]]; then
    nspawn_args+=(--user="$BUILD_USER" --chdir="/home/$BUILD_USER")
  else
    nspawn_args+=(--chdir=/xros)
  fi
  # Egress-TLS хоста — только если существует.
  [[ -d /run/hatch/egress-tls ]] && nspawn_args+=(--bind=/run/hatch/egress-tls:/run/hatch/egress-tls)
  # Прокси окружения хоста (если заданы) — внутрь.
  local v
  for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
    [[ -n "${!v:-}" ]] && nspawn_args+=(--setenv="$v=${!v}")
  done
  nspawn_args+=(--setenv="CARGO_HOME=/home/$BUILD_USER/.cargo")
  if command -v systemd-nspawn >/dev/null 2>&1 && nspawn_usable; then
    systemd-nspawn "${nspawn_args[@]}" "$@"
    return $?
  fi
  warn "systemd-nspawn недоступен или не работает на этом хосте (нет sysfs в user namespace) — путь unshare+chroot"
  run_in_rootfs_chroot "$user" -- "$@"
}

# Запасной путь: приватный mount namespace + chroot.
# Минимальный набор монтирований, только чтобы команды работали;
# всё снимается при выходе из namespace (он приватный и живёт только
# время одной команды). /dev пробрасывается ПОФАЙЛОВО (bind всего /dev
# и mknod в user namespace запрещены — см. prepare_rootfs_for_pacman),
# CA-переменные хоста сбрасываются (см. chroot_env): внутри chroot
# /run/hatch/egress-tls не существует, а бандл rootfs уже содержит CA
# хоста (update-ca-trust при --init).
run_in_rootfs_chroot() {
  local user="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  # ВАЖНО: файл внутреннего скрипта — УНИКАЛЬНЫЙ на каждый вызов
  # (mktemp). Общий $BUILD_ENV/.inner.sh приводил к гонке: в tar-потоке
  # copy_to_builder два вызова run_in_rootfs идут параллельно, и
  # builder'овский tar исполнял root'овый скрипт (файлы в копии
  # оказывались root-owned, и cargo падал с Permission denied).
  local inner
  inner="$(mktemp "$BUILD_ENV/.inner.XXXXXX.sh")" || die "не могу создать временный скрипт $BUILD_ENV/.inner.*.sh"
  {
    echo '#!/bin/bash'
    echo 'set -e'
    echo "ROOTFS='$ROOTFS'"
    echo "BUILD_USER='$BUILD_USER'"
    echo "PROJECT='$PROJECT'"
    echo 'chmod 755 "$ROOTFS" "$ROOTFS/dev" 2>/dev/null || true'
    echo 'mkdir -p "$ROOTFS/dev/pts" "$ROOTFS/dev/shm" "$ROOTFS/proc" "$ROOTFS/xros"'
    echo 'for dev in null zero full random urandom tty; do'
    echo '  touch "$ROOTFS/dev/$dev" 2>/dev/null || true'
    echo '  mount --bind "/dev/$dev" "$ROOTFS/dev/$dev" 2>/dev/null || true'
    echo 'done'
    # /dev/fd + stdin/stdout/stderr — защита: если /dev rootfs сброшен,
    # симлинки восстанавливаются при каждом запуске (см. комментарий
    # в prepare_rootfs_for_pacman про makepkg:713).
    echo 'ln -sf /proc/self/fd "$ROOTFS/dev/fd" 2>/dev/null || true'
    echo 'ln -sf /proc/self/fd/0 "$ROOTFS/dev/stdin" 2>/dev/null || true'
    echo 'ln -sf /proc/self/fd/1 "$ROOTFS/dev/stdout" 2>/dev/null || true'
    echo 'ln -sf /proc/self/fd/2 "$ROOTFS/dev/stderr" 2>/dev/null || true'
    echo 'mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true'
    echo 'mount -t tmpfs tmpfs "$ROOTFS/dev/shm" 2>/dev/null || true'
    echo 'mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null || true'
    echo "mount --bind '$PROJECT' \"\$ROOTFS/xros\" 2>/dev/null || true"
    echo "cp -L /etc/resolv.conf \"\$ROOTFS/etc/resolv.conf\" 2>/dev/null || true"
    echo "cp -L /etc/hosts \"\$ROOTFS/etc/hosts\" 2>/dev/null || true"
    echo 'unset CURL_CA_BUNDLE SSL_CERT_FILE GIT_SSL_CAINFO REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS AWS_CA_BUNDLE'
    echo "export CARGO_HOME=/home/$BUILD_USER/.cargo"
    # Рабочий каталог: root — /xros, builder — свой home. Builder НЕ МОЖЕТ
    # зайти в /xros (права 2770 root:nogroup на хосте) — cd ронял бы
    # любую команду builder'а ещё до её запуска (проверено 2026-11-10).
    if [[ "$user" == "builder" ]]; then
      echo 'exec chroot "$ROOTFS" runuser -u builder -- bash -c '\''cd /home/builder; exec "$@"'\'' _ "$@"'
    else
      echo 'exec chroot "$ROOTFS" bash -c '\''cd /xros; exec "$@"'\'' _ "$@"'
    fi
  } > "$inner"
  chmod +x "$inner"
  # Передаём команду через аргументы, без подстановок в текст скрипта.
  unshare --mount --fork "$inner" "$@"
}

# --- Rust --------------------------------------------------------------------
# Сборка идёт НЕ в bind-монтированном проекте, а в копии исходников
# внутри rootfs (/home/builder/xros-build/<crate>, владелец builder):
# файлы проекта на хосте принадлежат root, и builder не смог бы писать
# target/ и Cargo.lock. После сборки бинарь и обновлённый Cargo.lock
# копируются обратно в проект от root.
do_build_rust() {
  local offline=0
  [[ "${1:-}" == "--offline" ]] && offline=1
  need_root
  acquire_lock
  [[ -d "$ROOTFS/usr/bin" ]] || die "rootfs не создан. Сначала: $0 --init"
  [[ -x "$ROOTFS/usr/bin/cargo" ]] || die "cargo нет внутри rootfs. Доустановите: $0 --init (или pacman -r)"
  if [[ "$offline" -eq 1 && ! -f "$DEPS_MARKER" ]]; then
    die "офлайн-сборка невозможна: кэш cargo пуст (нет метки deps-fetched). Сначала выполните ОНЛАЙН-сборку: $0 --build-rust"
  fi
  local crate
  for crate in src/xros-cli src/xros-install-gui-rs; do
    [[ -f "$PROJECT/$crate/Cargo.toml" ]] || die "нет $PROJECT/$crate/Cargo.toml"
    local name="${crate#src/}"
    log "готовлю копию $crate в rootfs (/home/$BUILD_USER/xros-build/$name)..."
    # tar-поток от root к builder'у (см. copy_to_builder): target/
    # исключается из архива, но НЕ удаляется в копии — прерванная
    # сборка продолжается инкрементно.
    copy_to_builder "$crate" "xros-build/$name" 2 "$crate/target"
    log "cargo build --release ${offline:+--offline }($crate, от пользователя $BUILD_USER)..."
    # --jobs: на хосте ~8 ГБ RAM, из которых свободно ~0.5–1.2 ГБ;
    # параллельный rustc для eframe (wgpu/naga) легко упирается в OOM.
    # По умолчанию 1 задание; поднять можно через XROS_CARGO_JOBS.
    local cargo_jobs="${XROS_CARGO_JOBS:-1}"
    if [[ "$offline" -eq 1 ]]; then
      run_in_rootfs builder -- cargo build --release --offline --jobs "$cargo_jobs" --manifest-path "/home/$BUILD_USER/xros-build/$name/Cargo.toml" \
        || die "сборка $crate не удалась"
    else
      run_in_rootfs builder -- cargo build --release --jobs "$cargo_jobs" --manifest-path "/home/$BUILD_USER/xros-build/$name/Cargo.toml" \
        || die "сборка $crate не удалась"
    fi
    local bin stage
    case "$name" in
      xros-cli)           bin="xros";              stage="packages/xros-cli/xros";;
      xros-install-gui-rs) bin="xros-install-gui"; stage="packages/xros-installer/xros-install-gui";;
      *) die "неизвестный крейт: $name (нет правила стейджинга)";;
    esac
    log "возвращаю в проект: Cargo.lock ($crate) и бинарь -> $stage ..."
    run_in_rootfs root -- bash -c 'cp "/home/builder/xros-build/'"$name"'/Cargo.lock" "/xros/'"$crate"'/Cargo.lock" && cp "/home/builder/xros-build/'"$name"'/target/release/'"$bin"'" "/xros/'"$stage"'"' \
      || die "не удалось вернуть артефакты $crate в проект"
    log "готово: $crate -> $PROJECT/$stage"
  done
  touch "$DEPS_MARKER"
  log "Rust-сборка ГОТОВА. Дальше — стейджинг в packages/ (см. scripts/build.sh, этап 2)."
}

# --- makepkg -------------------------------------------------------------------
do_makepkg() {
  local pkgdir="${1:-}"
  [[ -n "$pkgdir" ]] || die "использование: $0 --makepkg <каталог пакета>, например packages/xros-cli"
  need_root
  acquire_lock
  [[ -d "$ROOTFS/usr/bin" ]] || die "rootfs не создан. Сначала: $0 --init"
  [[ -x "$ROOTFS/usr/bin/makepkg" ]] || die "makepkg нет внутри rootfs. Доустановите: $0 --init"
  case "$pkgdir" in /*) ;; *) pkgdir="$PROJECT/$pkgdir";; esac
  [[ -f "$pkgdir/PKGBUILD" ]] || die "нет PKGBUILD в $pkgdir"
  local pkgname="${pkgdir##*/}"
  log "makepkg в $pkgdir (от пользователя $BUILD_USER, НЕ root)..."
  # Сборка — в копии каталога внутри rootfs (/home/builder/pkgbuild/<имя>).
  # ВАЖНО: prepare() в PKGBUILD сверяется с ../../branding, ../../src
  # и ../../profile (относительно каталога пакета) — поэтому рядом
  # с копией пакета копируются и эти три дерева (тоже через tar-поток
  # от root к builder'у, см. copy_to_builder), иначе prepare() падает
  # с «нет такого файла». Старые копии перед этим удаляются, чтобы не
  # осталось несвежих файлов.
  local relpkgdir="${pkgdir#$PROJECT/}"
  run_in_rootfs builder -- bash -c 'rm -rf /home/builder/pkgbuild /home/builder/branding /home/builder/src /home/builder/profile && mkdir -p /home/builder/pkgbuild' \
    || die "не удалось очистить старые копии в rootfs"
  copy_to_builder "$relpkgdir" "pkgbuild/$pkgname" 2 '*.pkg.tar.zst'
  copy_to_builder "branding" "branding" 1
  copy_to_builder "src" "src" 1
  copy_to_builder "profile" "profile" 1
  # --syncdeps: доустановить зависимости пакета; --clean: убрать остатки.
  # --force: повторный прогон без -f падает с «A package has already
  # been built», если в каталоге остался .pkg.tar.zst от прошлого прогона
  # (копия с хоста приносит его обратно); --force перезаписывает.
  # Дополнительно *.pkg.tar.zst исключён из копии выше (это выход,
  # а не вход сборки) — двойная защита от несвежего пакета.
  run_in_rootfs builder -- bash -c 'cd "/home/builder/pkgbuild/'"$pkgname"'" && makepkg --syncdeps --noconfirm --clean --force' \
    || die "makepkg в $pkgdir не удался"
  # Возврат пакета на хост: /xros внутри chroot — это bind проекта.
  # Было: "$pkgdir#$PROJECT/" — опечатка: # вместо ${pkgdir#$PROJECT/},
  # из-за неё путь склеивался в мусор с # («/xros//home/.../packages/...
  # #/home/...») и cp падал, хотя сам пакет уже был собран (2026-11-10).
  # Используем уже вычисленный relpkgdir (относительный путь).
  run_in_rootfs root -- bash -c 'cp /home/builder/pkgbuild/'"$pkgname"'/*.pkg.tar.zst "/xros/'"$relpkgdir"'"' \
    || die "не удалось вернуть готовый пакет в $pkgdir"
  log "makepkg ГОТОВ: смотрите .pkg.tar.zst в $pkgdir"
}

# --- grub-script-check ---------------------------------------------------------
do_grub_check() {
  need_root
  acquire_lock
  [[ -d "$ROOTFS/usr/bin" ]] || die "rootfs не создан. Сначала: $0 --init"
  [[ -x "$ROOTFS/usr/bin/grub-script-check" ]] || die "grub-script-check нет внутри rootfs. Доустановите: $0 --init"
  local files=()
  if [[ $# -gt 0 ]]; then
    files=("$@")
  else
    [[ -f "$PROJECT/profile/grub/grub.cfg" ]] && files+=("profile/grub/grub.cfg")
    # Дополнительно: все *.cfg из профиля.
    local f
    while IFS= read -r -d '' f; do files+=("${f#$PROJECT/}"); done < <(find "$PROJECT/profile" -name '*.cfg' -print0 2>/dev/null)
    [[ ${#files[@]} -gt 0 ]] || die "файлов grub для проверки не найдено (нет profile/grub/grub.cfg и *.cfg в profile/)"
  fi
  local f rc=0
  for f in "${files[@]}"; do
    [[ -f "$PROJECT/$f" ]] || { warn "нет файла: $f — пропускаю"; rc=1; continue; }
    log "grub-script-check: $f"
    run_in_rootfs root -- grub-script-check "/xros/$f" \
      || { warn "grub-script-check НЕ ПРОШЁЛ для $f"; rc=1; }
  done
  [[ "$rc" -eq 0 ]] && log "grub-script-check: все файлы OK" || die "grub-script-check: есть ошибки (см. выше)"
}

# --- очистка / удаление --------------------------------------------------------
do_clean() {
  acquire_lock
  cleanup
  log "временные монтирования сняты, временные файлы убраны. rootfs не тронут."
}

do_destroy() {
  [[ "${1:-}" == "--confirm" ]] || die "опасная операция: добавьте --confirm: $0 --destroy --confirm"
  acquire_lock
  cleanup
  log "удаляю весь build-env: $BUILD_ENV"
  rm -rf "$BUILD_ENV"
  log "build-env удалён. Для пересоздания: $0 --init"
}

do_reinit() {
  [[ "${1:-}" == "--confirm" ]] || die "опасная операция: добавьте --confirm: $0 --reinit --confirm"
  acquire_lock
  cleanup
  log "удаляю rootfs и пересоздаю заново..."
  rm -rf "$ROOTFS" "$INIT_MARKER" "$DEPS_MARKER"
  # Снимаем lock перед do_init (он сам берёт lock) — проще: отпускаем fd.
  exec 9>&-
  do_init
}

usage() {
  sed -n '2,101p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

# --- main -----------------------------------------------------------------------
main() {
  case "${1:-}" in
    --check|--dry-run) check_host; exit $?;;
    --init)            do_init;;
    --reinit)          do_reinit "${2:-}";;
    --exec)            shift; [[ $# -gt 0 ]] || die "использование: $0 --exec -- <команда...>"; need_root; acquire_lock; run_in_rootfs root -- "$@";;    --build-rust)      shift; do_build_rust "${1:-}";;
    --makepkg)         shift; do_makepkg "${1:-}";;
    --grub-check)      shift; do_grub_check "$@";;
    --clean)           do_clean;;
    --destroy)         do_destroy "${2:-}";;
    --help|-h|"")      usage 0;;
    *)                 echo "Неизвестный режим: $1" >&2; usage 2;;
  esac
}

main "$@"
