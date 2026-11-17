#!/usr/bin/env python3
"""XrOS 1.0 Diamond — премиальный графический установщик (PyQt6 + QML).

Мост между QML-интерфейсом и bash-движком src/xros-install.
Контракт с движком — как у старого GUI (xros-install-gui-rs):
  * конфиг: /tmp/xros-install.conf (0600, shell-экранирование)
  * запуск: /usr/local/bin/xros-install, XROS_NONINTERACTIVE=1,
    XROS_INSTALL_CONF=/tmp/xros-install.conf
  * лог: /tmp/xros-install.log (читается построчно)
"""
import json
import os
import shlex
import signal
import stat
import subprocess
import time

from PyQt6.QtCore import QObject, QTimer, pyqtSignal, pyqtSlot

CONF_PATH = "/tmp/xros-install.conf"
LOG_PATH = "/tmp/xros-install.log"
ENGINE = "/usr/local/bin/xros-install"

# Зарезервированные системные имена (A-31, тот же список, что
# в src/xros-install: XROS_RESERVED_USERS).
RESERVED_USERS = frozenset({
    "root", "daemon", "bin", "sys", "sync", "games", "man", "lp",
    "mail", "news", "uucp", "proxy", "www-data", "backup", "list",
    "irc", "gnats", "nobody", "systemd-network", "systemd-timesync",
    "systemd-resolve", "messagebus", "polkitd", "sddm", "dbus",
    "sshd", "avahi", "colord", "rtkit", "git", "http", "ftp",
})

# ФС/типы, блокирующие установку (A-24, A-38 — тот же смысл, что
# в src/xros-install: xros_disk_blocked). R-02: добавлены все типы
# членов RAID/fakeraid, распознаваемые blkid (проверено strings
# libblkid): MD Linux, Intel RST (isw), DDF, Promise FastTrack,
# Adaptec, HighPoint 37x/45x, JMicron, LSI MegaRAID, NVIDIA nForce,
# Silicon Image Medley, VIA; плюс LVM1_member — тот же класс, что и
# LVM2_member (физ. том LVM). zfs_member и VMFS_volume_member здесь
# нет сознательно (см. комментарий в xros-install, R-02).
BLOCKED_FSTYPES = frozenset({
    "LVM1_member", "LVM2_member", "crypto_LUKS",
    "linux_raid_member", "isw_raid_member", "ddf_raid_member",
    "promise_fasttrack_raid_member", "adaptec_raid_member",
    "hpt37x_raid_member", "hpt45x_raid_member", "jmicron_raid_member",
    "lsi_mega_raid_member", "nvidia_raid_member",
    "silicon_medley_raid_member", "via_raid_member",
})
# Точное совпадение — только lvm/crypt; raid* проверяется по префиксу
# (raid, raid0, raid1, raid4, raid5, raid6, raid10 — точное == "raid"
# их не ловит), см. _is_blocked_type.
BLOCKED_TYPES = frozenset({"lvm", "crypt"})


def _is_blocked_type(dev_type: str) -> bool:
    """Тип устройства блокирует установку: lvm/crypt — точно,
    raid* — по префиксу."""
    t = dev_type or ""
    return t in BLOCKED_TYPES or t.startswith("raid")


def _device_blocked(dev: dict) -> bool:
    """Устройство (словарь lsblk -J) заблокировано, если оно само или
    ЛЮБОЙ его потомок (рекурсивно, на всю глубину children) — LVM/LUKS/RAID.
    Вложенное md-устройство под разделом-членом тоже блокирует родителя."""
    if (dev.get("fstype") or "") in BLOCKED_FSTYPES:
        return True
    if _is_blocked_type(dev.get("type") or ""):
        return True
    for ch in dev.get("children") or []:
        if _device_blocked(ch):
            return True
    return False


def _device_readable(path: str) -> bool:
    """R-18: первый сектор устройства читается? lsblk -J не различает
    «сигнатуры нет» и «устройство не читается» (I/O, исчезло, нет
    прав): пустое fstype в обоих случаях. А blkid-ноги у bridge нет
    вовсе — только lsblk. Поэтому нечитаемое устройство нельзя
    считать свободным: disksJson помечает его blocked (движок
    перепроверит его сам перед разрушительными операциями).
    Проба — чтение 512 байт, только чтение. Путь обязан быть
    блочным устройством (как [[ -b ]] в Bash-пробе)."""
    if not path:
        return False
    try:
        if not stat.S_ISBLK(os.stat(path).st_mode):
            return False
        fd = os.open(path, os.O_RDONLY)
        try:
            os.read(fd, 512)
        finally:
            os.close(fd)
        return True
    except Exception:
        return False


def _secure_create(path: str):
    """Безопасное создание файла (A-13): O_CREAT|O_EXCL, 0o600.
    Существующий файл/symlink сначала удаляется — иначе конфиг/лог
    можно подменить symlink'ом на чужой файл. O_EXCL не следует
    по symlink'ам, поэтому создание после unlink безопасно.
    Возвращает fd или None при неудаче."""
    for _attempt in range(2):
        try:
            return os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            try:
                os.unlink(path)
            except Exception:
                return None
        except Exception:
            return None
    return None


def _shell_quote(value: str) -> str:
    """Экранирование как в Rust GUI: одинарные кавычки, ' -> '\\''."""
    return "'" + str(value).replace("'", "'\\''") + "'"


def _human_size(nbytes: int) -> str:
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if nbytes < 1024 or unit == "ТБ":
            return f"{nbytes:.0f} {unit}" if unit == "Б" else f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} ТБ"


class InstallerBridge(QObject):
    logLine = pyqtSignal(str)          # новая строка лога движка
    installFinished = pyqtSignal(bool, str)  # успех, итоговое сообщение
    disksChanged = pyqtSignal()

    def __init__(self):
        super().__init__()
        self._proc = None
        self._log_pos = 0
        self._log_timer = QTimer(self)
        self._log_timer.setInterval(400)
        self._log_timer.timeout.connect(self._poll_log)
        self._iso_disk = self._detect_iso_disk()

    # ---------- диски ----------
    def _detect_iso_disk(self) -> str:
        """Диск, с которого загружен ISO (защита от форматирования)."""
        try:
            src = subprocess.check_output(
                ["findmnt", "-n", "-o", "SOURCE", "/run/archiso/bootmnt"],
                text=True, stderr=subprocess.DEVNULL).strip()
            if src:
                pk = subprocess.check_output(
                    ["lsblk", "-n", "-o", "PKNAME", src],
                    text=True, stderr=subprocess.DEVNULL).strip()
                return pk
        except Exception:
            pass
        return ""

    @pyqtSlot(result=str)
    def disksJson(self) -> str:
        """Реальные диски системы (lsblk). ISO-диск помечен isIsoDisk."""
        try:
            out = subprocess.check_output(
                ["lsblk", "-J", "-b", "-o",
                 "NAME,PATH,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINT,RM,RO,PKNAME"],
                text=True, stderr=subprocess.DEVNULL)
            data = json.loads(out)
        except Exception as e:
            return json.dumps({"error": str(e), "disks": []})
        disks = []
        for dev in data.get("blockdevices", []):
            if dev.get("type") != "disk":
                continue
            # Не предлагать как цель установки: флоппи (fd*) и крошечные
            # устройства (< 1 ГБ) — на них нельзя поставить систему.
            # Поймано в Live BIOS fixed10 (11.11.2026): в списке был
            # только /dev/fd0 4.0 КБ при неподключённом диске (nodisk).
            _name = dev.get("name", "")
            _size = int(dev.get("size") or 0)
            if _name.startswith("fd"):
                continue
            if _size < 1024 * 1024 * 1024:
                continue
            parts = []
            for ch in dev.get("children") or []:
                # A-24/A-38: раздел с LVM/LUKS/RAID нельзя выбрать корнем —
                # помечаем, QML скрывает его из выбора корня/EFI.
                # _device_blocked рекурсивен: вложенное md-устройство
                # под разделом тоже блокирует раздел.
                # R-18: нечитаемый раздел — тоже blocked (lsblk мог
                # просто не увидеть его сигнатуру из-за ошибки чтения).
                _blocked = _device_blocked(ch) or not _device_readable(ch.get("path", ""))
                parts.append({
                    "path": ch.get("path", ""),
                    "fs": ch.get("fstype") or "",
                    "size": int(ch.get("size") or 0),
                    "sizeHuman": _human_size(int(ch.get("size") or 0)),
                    "mountpoint": ch.get("mountpoint") or "",
                    "blocked": bool(_blocked),
                })
            # A-24/A-38: диск заблокирован, если он сам или любой его
            # потомок (на любую глубину) — LVM/LUKS/RAID. Движок тоже
            # откажется (xros_disk_blocked), но GUI не предлагает такой
            # диск вовсе.
            # R-18: нечитаемый диск — тоже blocked.
            disk_blocked = _device_blocked(dev) or not _device_readable(dev.get("path", ""))
            disks.append({
                "path": dev.get("path", ""),
                "name": dev.get("name", ""),
                "model": (dev.get("model") or "").strip() or "Диск",
                "size": int(dev.get("size") or 0),
                "sizeHuman": _human_size(int(dev.get("size") or 0)),
                "removable": bool(dev.get("rm")),
                "isIsoDisk": dev.get("name") == self._iso_disk,
                "blocked": bool(disk_blocked),
                "partitions": parts,
            })
        return json.dumps({"disks": disks})

    @pyqtSlot(result=str)
    def isoDiskName(self) -> str:
        return self._iso_disk

    @pyqtSlot(result=bool)
    def isUefi(self) -> bool:
        """Загрузка в режиме UEFI (для ручной разметки: EFI нужен только там)."""
        return os.path.isdir("/sys/firmware/efi")

    @pyqtSlot(str, result=str)
    def checkUsername(self, username: str) -> str:
        """Проверка имени пользователя (A-31): "" — всё в порядке,
        иначе текст ошибки для показа в форме."""
        u = (username or "").strip().lower()
        if not u:
            return "Введите имя пользователя."
        if u in RESERVED_USERS:
            return f"Имя «{u}» зарезервировано системой — выберите другое."
        return ""

    # ---------- часовые пояса и раскладки ----------
    @pyqtSlot(result=str)
    def timezonesJson(self) -> str:
        """Часовые пояса из /usr/share/zoneinfo (без служебных)."""
        base = "/usr/share/zoneinfo"
        zones = []
        try:
            for root, _dirs, files in os.walk(base):
                for f in files:
                    rel = os.path.relpath(os.path.join(root, f), base)
                    if rel.startswith(("posix/", "right/")) or "/" not in rel:
                        continue
                    zones.append(rel)
        except Exception:
            pass
        zones.sort()
        # Частые — первыми.
        common = ["Europe/Moscow", "Europe/Samara", "Europe/Astrakhan",
                  "Europe/Kaliningrad", "Asia/Yekaterinburg", "Asia/Novosibirsk"]
        zones = [z for z in common if z in zones] + [z for z in zones if z not in common]
        return json.dumps(zones)

    @pyqtSlot(result=str)
    def detectTimezone(self) -> str:
        try:
            out = subprocess.check_output(
                ["timedatectl", "show", "-p", "Timezone", "--value"],
                text=True, stderr=subprocess.DEVNULL).strip()
            if out:
                return out
        except Exception:
            pass
        try:
            link = os.readlink("/etc/localtime")
            return link.replace("/usr/share/zoneinfo/", "")
        except Exception:
            return "Europe/Astrakhan"

    @pyqtSlot(result=str)
    def currentTime(self) -> str:
        return time.strftime("%H:%M:%S, %d.%m.%Y")

    @pyqtSlot(str, result=bool)
    def setLiveKeymap(self, keymap: str) -> bool:
        """Переключить раскладку Live-сессии (для поля проверки)."""
        if not keymap.replace("-", "").replace("_", "").isalnum():
            return False
        try:
            subprocess.run(["setxkbmap", keymap],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=5)
            return True
        except Exception:
            return False

    # ---------- конфиг и запуск движка ----------
    @pyqtSlot(str, result=bool)
    def writeConf(self, settingsJson: str) -> bool:
        try:
            settings = json.loads(settingsJson)
        except Exception:
            return False
        # Белый список ключей — движок не должен получить ничего лишнего.
        # A-06: EFI_PART — ручной режим (UEFI).
        allowed = {"PARTMODE", "FS", "TIMEZONE", "KEYMAP", "AUTOLOGIN",
                   "OFFICE", "DE", "FULLNAME", "USERNAME", "USERPASS",
                   "ROOTPASS", "DISK", "ROOT_PART", "EFI_PART", "HOSTNAME"}
        # A-31: зарезервированное имя — отказ писать конфиг (вторая
        # линия после живой проверки в User.qml).
        if "USERNAME" in settings and self.checkUsername(str(settings["USERNAME"])):
            return False
        lines = []
        for key in sorted(allowed):
            if key in settings and settings[key] != "":
                lines.append(f"{key}={_shell_quote(str(settings[key]))}")
        # A-13: безопасное создание (unlink + O_EXCL, 0o600) вместо
        # open("w") + chmod: старый путь следовал по symlink'у.
        fd = _secure_create(CONF_PATH)
        if fd is None:
            return False
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            return True
        except Exception:
            return False

    @pyqtSlot(result=bool)
    def startInstall(self) -> bool:
        if self._proc is not None and self._proc.poll() is None:
            return False
        if not os.path.exists(CONF_PATH):
            return False
        # A-13: лог — тоже через безопасное создание (как конфиг).
        # Неудача — честный отказ запускать движок без журнала.
        fd = _secure_create(LOG_PATH)
        if fd is None:
            return False
        os.close(fd)
        self._log_pos = 0
        env = dict(os.environ)
        env["XROS_NONINTERACTIVE"] = "1"
        env["XROS_INSTALL_CONF"] = CONF_PATH
        try:
            self._proc = subprocess.Popen(
                [ENGINE], env=env, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)
        except Exception:
            try:
                os.remove(CONF_PATH)
            except Exception:
                pass
            return False
        self._log_timer.start()
        return True

    @pyqtSlot()
    def cancelInstall(self):
        """Остановить движок (вся группа процессов)."""
        if self._proc is not None and self._proc.poll() is None:
            try:
                os.killpg(os.getpgid(self._proc.pid), signal.SIGTERM)
            except Exception:
                pass
            try:
                self._proc.wait(timeout=10)
            except Exception:
                try:
                    os.killpg(os.getpgid(self._proc.pid), signal.SIGKILL)
                except Exception:
                    pass
                # A-21: SIGKILL не игнорируется — дожидаемся реального
                # завершения группы, прежде чем сообщать об отмене.
                try:
                    self._proc.wait(timeout=10)
                except Exception:
                    pass
        self._log_timer.stop()
        # «Отменено» — только когда процесса реально нет; если он
        # каким-то чудом ещё жив — честно говорим об этом, а не врём.
        if self._proc is not None and self._proc.poll() is None:
            self.installFinished.emit(
                False, "Остановка не завершена: движок всё ещё работает. Подождите или закройте окно.")
        else:
            self._proc = None
            self.installFinished.emit(False, "Установка отменена пользователем.")

    def _poll_log(self):
        try:
            with open(LOG_PATH, "r", encoding="utf-8", errors="replace") as f:
                f.seek(self._log_pos)
                chunk = f.read()
                self._log_pos = f.tell()
        except Exception:
            chunk = ""
        for line in chunk.splitlines():
            if line.strip():
                self.logLine.emit(line)
        if self._proc is not None and self._proc.poll() is not None:
            self._log_timer.stop()
            code = self._proc.returncode
            self._proc = None
            if code == 0:
                self.installFinished.emit(True, "Установка завершена.")
            else:
                self.installFinished.emit(
                    False, f"Движок завершил работу с кодом {code}. См. журнал.")

    # ---------- завершение ----------
    @pyqtSlot(result=bool)
    def rebootSystem(self) -> bool:
        try:
            subprocess.Popen(["/sbin/reboot"])
            return True
        except Exception:
            return False

    @pyqtSlot(str, result=str)
    def shellQuote(self, value: str) -> str:
        return _shell_quote(value)
