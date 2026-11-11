# FINAL-SECURITY-REPORT.md — XrOS 1.0 (fixed9)

- **Дата:** 11 ноября 2026
- **Объект:** установленная система fixed9, диск
  `experiments/qemu-stage10/disks/fixed9-uefi.qcow2` (UEFI); проверки выполнены
  в живой VM fixed9-diag3 (14:26–14:28 +04) + по конфигурации проекта
- **Статусы — только PASS / FAIL / NOT TESTED**
- **Доказательства:** кадры `experiments/qemu-stage10/screenshots/fixed9-diag3-diag3-sec*.png`

## 1. Сводка

| # | Проверка | Статус | Комментарий |
|---|---|---|---|
| S1 | CA песочницы в ISO/установленной системе | PASS (ложная тревога закрыта) | Якоря пусты, `find /etc -name '*hatch*'` — ничего |
| S2 | Права /usr, /etc (2755 setgid) | FAIL → исправлено в VM | Нужен фикс на этапе сборки |
| S3 | /etc/shadow, /etc/gshadow | PASS | 600 root:root |
| S4 | SSH (openssh установлен) | PASS | sshd disabled + inactive |
| S5 | sudo NOPASSWD | PASS | Строка NOPASSWD закомментирована; sudo требует пароль |
| S6 | Фаервол | PASS | ufw 0.36.2-7 установлен, enabled, active |
| S7 | Пароль root = пароль пользователя | FAIL (по дизайну движка) | ROOTPASS=USERPASS по умолчанию; менять — отдельным решением |
| S8 | Подпись репозитория XrOS (GPG) | FAIL | SigLevel Optional TrustAll; подпись не настроена |
| S9 | Автообновления | PASS (выключены) | xros-update.timer не включён — правильно до GPG |
| S10 | Синхронизация pacman-БД в установленной системе | FAIL (косметика) | БД core/extra/multilib/xros отсутствуют (`-Sy` не запускался) |

## 2. Детали

### S1. CA песочницы — PASS (ложная тревога закрыта окончательно)

- Скрипты сборки (`scripts/build.sh` шаг 2; `scripts/build-rootfs-pacstrap.sh:207-212`)
  ставят CA песочницы (`hatch-egress-ca.crt`) в **build rootfs**
  (`build-env/root.x86_64` — chroot, в котором запускается mkarchiso), а НЕ в airootfs.
  ROOTFS и AIROOTFS — разные каталоги (build-rootfs-pacstrap.sh:121-122).
- Проверено в живой системе И в установленной системе:
  `/etc/ca-certificates/trust-source/anchors/` пусто; `find /etc -name '*hatch*'` — ничего;
  в profile/airootfs каталога anchors нет вообще.
- **CA в ISO и в установленной системе нет. Исправлений не требуется.**

### S2. Права /usr и /etc 2755 (setgid), / 555 — FAIL → исправлено в VM

- В установленной системе: /usr и /etc = 2755 (только бит setgid, расширенных ACL нет),
  / = 555, /var /home /boot = 755.
- Дефект 2770 из чёрного экрана НЕ воспроизводится (это другое: 2755 — чтение/исполнение
  для всех разрешены, setgid влияет только на новые файлы/подкаталоги).
- **Исправлено в VM 13:49:** `chmod g-s /usr /etc` + `chmod 755 /` → проверено 755/755/755.
  **Новое 14:17:** после перезагрузки / снова 555 (/usr и /etc остались 755).
  Правил tmpfiles/fstab/юнитов нет — вероятнее всего, потеря записи при жёстком убийстве
  QEMU ребутом хоста №4; повторно `chmod 755 /` + `sync` 14:20, проверено 755/755/755.
- **Требуется фикс на этапе сборки:** выяснить источник setgid (вероятно, наследование
  из Live rootfs через rsync установщика) и добавить проверку прав в сборку
  (регрессионный тест на 2770 уже есть; добавить проверку / на 0755 после установки).

### S3. /etc/shadow, /etc/gshadow — PASS

- `stat`: /etc/shadow 600 root:root; /etc/gshadow 600 root:root; /etc/passwd 644 root:root.
- Пароли хранятся корректно, чтение shadow обычным пользователем невозможно.

### S4. SSH — PASS

- openssh 10.6p1-3 установлен, но `systemctl is-enabled sshd` → **disabled**,
  `systemctl is-active sshd` → **inactive**. Порт 22 не слушается, удалённого доступа нет.
- В отличие от AKVT build 33 (критичный пункт аудита: SSH + известный пароль +
  NOPASSWD sudo), в XrOS SSH выключен по умолчанию.

### S5. sudo NOPASSWD — PASS

- `grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/` (через sudo): единственное совпадение —
  `/etc/sudoers:128:# %wheel ALL=(ALL:ALL) NOPASSWD: ALL` — **строка закомментирована**.
- `sudo -l` для mia: `(ALL : ALL) ALL` без NOPASSWD — sudo требует пароль
  (подтверждено: `echo xros1234 | sudo -S` работает, без пароля — нет).
- /etc/sudoers.d/ недоступен для чтения обычным пользователем (отказано в доступе) — правильно.
- mia в группах: mia wheel audio optical storage video.

### S6. Фаервол — PASS

- ufw 0.36.2-7 установлен; `systemctl is-enabled ufw` → **enabled**;
  `systemctl is-active ufw` → **active**. Фаервол включён из коробки.
- firewalld — не проверялся (не входит в базовый набор; ufw — активный фаервол).

### S7. Пароль root = пароль пользователя — FAIL (по дизайну движка)

- Движок `src/xros-install`: ROOTPASS по умолчанию = USERPASS (контракт конфигурации).
  Установленная система: root и mia имеют один и тот же пароль xros1234.
- Это известное решение движка, а не случайность. Риск: компрометация пароля пользователя
  = полный root-доступ. **Решение — за Мией:** либо оставить (удобство для одного
  пользователя), либо развести пароли в Diamond (поле «пароль root» на экране пользователя).

### S8. Подпись репозитория XrOS (GPG) — FAIL

- Репозиторий обновлений https://artemkrytoi111.github.io/XrOS-Security-Updates/
  (GitHub Pages, HTTPS) работает, пакеты проверяются pacman по контрольным суммам,
  но **GPG-подписи пакетов и БД нет**; в pacman.conf SigLevel Optional TrustAll.
- До настройки GPG-подписи автообновления должны оставаться выключенными (S9).
- **Следующий шаг (нужно решение Мии):** сгенерировать GPG-ключ XrOS, подписать
  пакеты и БД, перевести SigLevel на Required, только потом включать xros-update.timer.

### S9. Автообновления — PASS (выключены)

- xros-update.timer не включён — правильно до S8. Ручное `pacman -Sy`/`-Su` доступно.

### S10. Синхронизация pacman-БД — FAIL (косметика)

- В установленной системе БД core/extra/multilib/xros отсутствуют
  (`database file ... does not exist (use '-Sy' to download)`).
- Причина: установщик не запускает `pacman -Sy` после установки. На `pacman -Syu`
  без отдельного разрешения — запрет по ТЗ. **Предложение:** установщик должен делать
  `pacman -Sy` (только синхронизацию, без обновления) в конце установки.

## 3. Что НЕ проверялось — NOT TESTED

- Сканирование открытых портов установленной системы извне (nmap) — SSH выключен,
  ufw активен, но полного скана не было.
- Проверка контрольных сумм всех системных пакетов (`pacman -Qkk`) — требует БД (см. S10).
- Secure Boot — не поддерживается по дизайну (этап 10).
- LUKS/пароль GRUB — не сделано (нужно отдельное решение Мии).
- BIOS-система — за Мией (диск fixed9-bios.qcow2 пуст).
