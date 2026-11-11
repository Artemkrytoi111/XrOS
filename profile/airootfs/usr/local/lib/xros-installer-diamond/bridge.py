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
import subprocess
import time

from PyQt6.QtCore import QObject, QTimer, pyqtSignal, pyqtSlot

CONF_PATH = "/tmp/xros-install.conf"
LOG_PATH = "/tmp/xros-install.log"
ENGINE = "/usr/local/bin/xros-install"


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
                parts.append({
                    "path": ch.get("path", ""),
                    "fs": ch.get("fstype") or "",
                    "size": int(ch.get("size") or 0),
                    "sizeHuman": _human_size(int(ch.get("size") or 0)),
                    "mountpoint": ch.get("mountpoint") or "",
                })
            disks.append({
                "path": dev.get("path", ""),
                "name": dev.get("name", ""),
                "model": (dev.get("model") or "").strip() or "Диск",
                "size": int(dev.get("size") or 0),
                "sizeHuman": _human_size(int(dev.get("size") or 0)),
                "removable": bool(dev.get("rm")),
                "isIsoDisk": dev.get("name") == self._iso_disk,
                "partitions": parts,
            })
        return json.dumps({"disks": disks})

    @pyqtSlot(result=str)
    def isoDiskName(self) -> str:
        return self._iso_disk

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
        allowed = {"PARTMODE", "FS", "TIMEZONE", "KEYMAP", "AUTOLOGIN",
                   "OFFICE", "DE", "FULLNAME", "USERNAME", "USERPASS",
                   "ROOTPASS", "DISK", "ROOT_PART", "HOSTNAME"}
        lines = []
        for key in sorted(allowed):
            if key in settings and settings[key] != "":
                lines.append(f"{key}={_shell_quote(str(settings[key]))}")
        try:
            with open(CONF_PATH, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            os.chmod(CONF_PATH, 0o600)
            return True
        except Exception:
            return False

    @pyqtSlot(result=bool)
    def startInstall(self) -> bool:
        if self._proc is not None and self._proc.poll() is None:
            return False
        if not os.path.exists(CONF_PATH):
            return False
        try:
            open(LOG_PATH, "w").close()
        except Exception:
            pass
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
        self._log_timer.stop()
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
