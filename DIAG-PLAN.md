# FIXED9 post-install diagnostics — план (делаю сама, 11.11.2026)
VM: fixed9-diag, UEFI diskboot диска fixed9-uefi.qcow2 (установка fixed9, завершена 07:15 UTC).
Пароль пользователя mia: xros1234. Вход в Konsole: Ctrl+Alt+T. Ввод: typeq.py, кадры: shot.sh fixed9-diag <имя>.

## Порядок (по ТЗ Мии 12:02)
1. Стол после загрузки + разблокировка (чёрный экран после разблокировки? 1 из 2 — ждать ≥10 мин, не объявлять раньше).
2. Konsole, по одной команде, кадр после каждой группы:
   - `uname -a; cat /etc/os-release; date; whoami`
   - `hostnamectl status; cat /etc/hostname; ls -l /etc/hostname`
   - `which hostname hostnamectl; pacman -Qo /usr/bin/hostname 2>&1; pacman -Qo /usr/bin/hostnamectl 2>&1`
   - `stat -c '%a %U:%G %n' / /usr /etc /var /home /boot`
   - `getfacl /usr; getfacl /etc`
   - `findmnt; lsblk -f`
   - `systemctl --failed; systemctl status sddm --no-pager | head -20`
   - `journalctl -b -p err --no-pager | head -40`
   - `systemctl status plasma-plasmashell --user --no-pager | head -15; ps aux | grep -E 'plasmashell|kactivity| sddm' | grep -v grep`
   - `ls -l /usr/share/xros/wallpaper.png; ls ~/.config/plasma-org.kde.plasma.desktop-appletsrc; grep -i wallpaper ~/.config/plasma-org.kde.plasma.desktop-appletsrc | head`
   - `cat /etc/default/grub | grep -E 'TIMEOUT|CMDLINE|DEFAULT'`
   - `ls /etc/ca-certificates/trust-source/anchors/; find /etc -name '*hatch*'`
3. Проверка обоев mia: открыть Настройки → Обои / или `qdbus`? Нет — визуально: стол после загрузки (фиолетовые волны или штатные?).
4. ACPI: ТОЛЬКО если система стабильна и всё собрано; QMP system_powerdown, ждать 60 с. (Агент уже зафиксировал FAIL — повторять только если нужен свой кадр.)
5. НИЧЕГО НЕ ИСПРАВЛЯТЬ без подтверждения Мии. Диагностика → отчёт → подтверждение → исправления.

## Уже известно (от агента, коммит e7b5756)
- Первая загрузка PASS (стол, панель, часы; Timezone=Europe/Samara; разблокировка xros1234 PASS).
- GRUB «Автозагрузка через 8 с» PASS в установленной системе; %d-шаблон работает.
- /usr и /etc = 2755 (setgid), дефект 2770 НЕ воспроизводится.
- hostname: бинаря нет, /etc/hostname нет (из моего кадра fb-c13).
- Обои для mia НЕ применяются (FAIL, брендинг) — xros-set-wallpaper только для Live-пользователя.
- Чёрный экран после разблокировки на 2-й загрузке (1 из 2), сессия жива (plasmashell PID 666, kactivitymanagerd PID 670), причина не установлена.
- ACPI-выключение FAIL (Live + установленная).
- CA песочницы: в ISO и в установленной системе НЕТ (ложная тревога, исправлена).
- UEFI-VM остановлена агентом 08:12 UTC; BIOS-диск пуст; BIOS — за Мией.

## Отчёты к написанию (после диагностики)
- FIXED9-POSTINSTALL-DIAGNOSTIC.md (статусы только PASS/FAIL/NOT TESTED)
- KDE-PLASMA-VALIDATION.md
- FINAL-SECURITY-REPORT.md (S1 CA — закрыта как ложная тревога)
- XROS-1.0-FINAL-STATUS.md (BIOS: NOT TESTED — делает Мия)
