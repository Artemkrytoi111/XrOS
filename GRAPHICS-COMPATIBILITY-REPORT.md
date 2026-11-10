# GRAPHICS-COMPATIBILITY-REPORT.md — виртуальная графика QEMU (XrOS 1.0)

Дата: 2026-11-10. Автор: агент автономного восстановления XrOS.
QEMU 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.18), OVMF, SeaBIOS.
Гость: linux 7.2.15.arch1-1, mesa (llvmpipe/zink), kwin 6.8.2,
plasma-desktop 6.8.2-1. ISO `xros-1.0-fixed-x86_64-hybrid.iso`.

## Итог

| Конфигурация | Результат |
|---|---|
| std VGA (bochs-drm), один GPU, загрузка через GRUB (UEFI) | **PASS** — KWin DRM backend, курсор, окна, приветствие |
| virtio-gpu + std VGA (два GPU), direct kernel boot (UEFI) | **PASS с оговорками** — работает, но 2 экрана, software-рендер |
| BIOS (SeaBIOS) GRUB | в работе (см. QEMU-FINAL-TEST-REPORT.md) |
| KMS/DRM | исправны (bochs-drm, simpledrm, fb0) |

## 1. DRM/KMS исправны (не причина чёрного экрана)

Проверено по serial-логам старых и новых прогонов: `bochs-drm`,
`simpledrm`, `fb0` поднимаются; systemd доходит до
`graphical.target`; SDDM стартует; KWin выбирает DRM backend
(`kwin_wayland: Chose DRM backend`). Чёрный экран в старом ISO был
вызван правами 2770/660, а не графикой (см. BLACK-SCREEN-ROOT-CAUSE.md).
После исправления прав тот же графический стек показывает рабочий стол.

## 2. std VGA (один GPU) — эталонная конфигурация

Прогон `fixed-uefi-grub` (UEFI, GRUB, `-vga std`, без virtio-gpu):
- KWin стартует, курсор мыши виден с 4-й минуты, окна (приветствие)
  рисуются корректно, 1280×800.
- Ошибка виджета `""` воспроизводится и здесь — доказательство, что
  она не связана с GPU (см. PLASMA-SESSION-REPORT.md).
- MESA/ZINK-ошибок в этом прогоне в журнале нет (llvmpipe).
- Рекомендуемая конфигурация для финальных тестов: `-vga std`.

## 3. virtio-gpu (+ std VGA по умолчанию) — два GPU

Прогоны `fixed-uefi-diag*` (direct kernel, `run-fixed.sh` virtio):
- `run-fixed.sh` добавляет `-device virtio-gpu-pci` БЕЗ `-vga none`,
  поэтому в госте ДВА GPU: bochs (std VGA, 1234:1111) + virtio-gpu.
  KWin видит два выхода/экрана (screen 0 и screen 1).
- Последствия: Plasma создавала вторую папку на `lastScreen=1`
  (неактивный экран), иконка «Установить XrOS» уходила на отключённый
  экран (`itemsOnDisabledScreens`). После исправления appletsrc
  (один экран) это не влияет на результат.
- MESA/EGL: `ZINK: vkCreateInstance failed (VK_ERROR_INCOMPATIBLE_DRIVER)`,
  `egl: failed to create dri2 screen`, `kwin: EGL setup failed, disabling
  glamor`, `Failed to fetch DRM device` (linux_dmabuf) — virtio-gpu без
  virgl не даёт аппаратного ускорения; KWin падает в software-рендер
  (llvmpipe). На рабочий стол не влияет (только производительность).
- Рекомендация: в `run-fixed.sh` для virtio-режима добавить `-vga none`,
  чтобы был один GPU; для финальных тестов использовать std VGA.

## 4. Переключение VT и EACCESS

- После переключения на tty9 (debug shell) и обратно KWin теряет выходы
  («There are no outputs - creating placeholder screen» у plasmashell
  и powerdevil) — ожидаемо: на неактивном VT у KWin нет выходов.
- При возврате: `kwin_wayland: drmModeListLessees() failed: Отказано
  в доступе`, `Applying output configuration failed: EACCESS` (1130 с,
  diag2). Выходы после этого восстанавливаются (рабочий стол снова
  рисуется). Это артефакт переключения VT под TCG, а не дефект
  системы: в обычном использовании (без переключения VT) не возникает.
- `plasmashell` нельзя рестартовать с неактивного VT: 3× SEGV в
  `libKF6ConfigCore.so.6.31.0` + `start-limit-hit` (см.
  PLASMA-SESSION-REPORT.md §3).

## 5. Производительность под TCG (не дефект)

- `plasma-ksplash.service` и `plasma-plasmashell.service`: 40-секундные
  таймауты старта; plasmashell потребляет ~24 с CPU за 80 с стены
  (первый экземпляр SIGKILL по таймауту, systemd перезапускает).
  `kwin_wayland: The main thread was hanging temporarily!` — TCG.
  На железе и под KVM старт в разы быстрее. Для тестов закладывать
  5–7 мин до готового рабочего стола.
- Разрешение тестов: 1280×800 (QEMU std). На других разрешениях
  раскладка пересчитывается Plasma (ItemGeometries пустые).

## 6. Что не проверялось

- virgl/virtio-gpu с ускорением (`-display gl`, virglrenderer) — не
  требуется для live-системы, software-рендер достаточен.
- Реальное железо (Intel/AMD/NVIDIA) — только QEMU.
- KVM-ускорение (хост без /dev/kvm в песочнице) — только TCG.
