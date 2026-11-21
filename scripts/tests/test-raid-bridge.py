#!/usr/bin/env python3
"""Тесты RAID-блокировки Diamond bridge.py (A-38).

Без PyQt6: модули PyQt6 подменяются заглушками в sys.modules, затем
импортируется настоящий bridge.py из src/ и проверяются:
  * _device_blocked на матрице словарей lsblk -J (рекурсия, raid*);
  * disksJson целиком (с подменой subprocess.check_output на
    поддельный lsblk -J).
Без доступа к дискам. Выход 0 — все PASS, иначе 1.
"""
import json
import os
import sys
import types

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "src", "xros-installer-diamond")

# --- заглушки PyQt6 (bridge.py импортирует только QObject/QTimer/сигналы) ---
pyqt6 = types.ModuleType("PyQt6")
qtcore = types.ModuleType("PyQt6.QtCore")


class QObject:
    def __init__(self, *a, **k):
        pass


class _Signal:
    def connect(self, fn):
        pass

    def emit(self, *a):
        pass


class QTimer:
    def __init__(self, *a, **k):
        pass

    def setInterval(self, ms):
        pass

    @property
    def timeout(self):
        return _Signal()

    def start(self):
        pass

    def stop(self):
        pass


def pyqtSignal(*a, **k):
    return _Signal()


def pyqtSlot(*a, **k):
    def deco(fn):
        return fn
    return deco


qtcore.QObject = QObject
qtcore.QTimer = QTimer
qtcore.pyqtSignal = pyqtSignal
qtcore.pyqtSlot = pyqtSlot
pyqt6.QtCore = qtcore
sys.modules["PyQt6"] = pyqt6
sys.modules["PyQt6.QtCore"] = qtcore

sys.path.insert(0, SRC)
import bridge  # noqa: E402

PASS = 0
FAIL = 0
FAILED = []


def ok(name):
    global PASS
    PASS += 1
    print(f"PASS  {name}")


def bad(name):
    global FAIL
    FAIL += 1
    FAILED.append(name)
    print(f"FAIL  {name}")


def check(name, got, want):
    if got == want:
        ok(f"{name} (want={want}, got={got})")
    else:
        bad(f"{name} (want={want}, got={got})")


# ---------- _device_blocked: матрица ----------
def dev(name, dtype, fstype=None, children=None):
    d = {"name": name, "type": dtype}
    if fstype is not None:
        d["fstype"] = fstype
    if children is not None:
        d["children"] = children
    return d


check("member part linux_raid_member",
      bridge._device_blocked(dev("sda1", "part", "linux_raid_member")), True)
check("member whole disk linux_raid_member",
      bridge._device_blocked(dev("sda", "disk", "linux_raid_member")), True)
check("assembled raid1",
      bridge._device_blocked(dev("md0", "raid1", "ext4")), True)
for raid_type in ("raid", "raid0", "raid4", "raid5", "raid6", "raid10"):
    check(f"assembled {raid_type}",
          bridge._device_blocked(dev("md0", raid_type, "ext4")), True)
check("nested md under part",
      bridge._device_blocked(dev("sda", "disk", None, [
          dev("sda1", "part", "ext4", [dev("md0", "raid1", "ext4")])])), True)
check("member inside parent disk",
      bridge._device_blocked(dev("sda", "disk", None, [
          dev("sda1", "part", "linux_raid_member")])), True)
check("clean disk",
      bridge._device_blocked(dev("sda", "disk", None, [
          dev("sda1", "part", "ext4")])), False)
check("plain ext4 part",
      bridge._device_blocked(dev("sda1", "part", "ext4")), False)
check("LVM member",
      bridge._device_blocked(dev("sda1", "part", "LVM2_member")), True)
check("LVM1 member",
      bridge._device_blocked(dev("sda1", "part", "LVM1_member")), True)
check("LUKS",
      bridge._device_blocked(dev("sda1", "part", "crypto_LUKS")), True)
# R-02: все типы членов RAID/fakeraid из libblkid.
for ft in ("isw_raid_member", "ddf_raid_member",
           "promise_fasttrack_raid_member", "adaptec_raid_member",
           "hpt37x_raid_member", "hpt45x_raid_member",
           "jmicron_raid_member", "lsi_mega_raid_member",
           "nvidia_raid_member", "silicon_medley_raid_member",
           "via_raid_member"):
    check(f"fakeraid {ft}",
          bridge._device_blocked(dev("sda1", "part", ft)), True)
check("fakeraid isw_raid_member у потомка диска",
      bridge._device_blocked(dev("sda", "disk", None, [
          dev("sda1", "part", "isw_raid_member")])), True)
check("empty dict",
      bridge._device_blocked({}), False)
check("children None",
      bridge._device_blocked(dev("sda", "disk", None, None)), False)
check("deeply nested md (3 levels)",
      bridge._device_blocked(dev("sda", "disk", None, [
          dev("sda1", "part", "ext4", [
              dev("md0", "raid1", None, [
                  dev("md0p1", "part", "ext4")])])])), True)

# ---------- disksJson целиком (поддельный lsblk -J) ----------
FAKE_LSBLK = {
    "blockdevices": [
        {
            "name": "sda", "path": "/dev/sda", "model": "TestDisk",
            "size": 21474836480, "type": "disk", "rm": False, "ro": False,
            "children": [
                {"name": "sda1", "path": "/dev/sda1", "size": 536870912,
                 "type": "part", "fstype": "ext4", "mountpoint": ""},
                {"name": "sda2", "path": "/dev/sda2", "size": 20937965568,
                 "type": "part", "fstype": "linux_raid_member", "mountpoint": ""},
            ],
        },
        {
            "name": "sdb", "path": "/dev/sdb", "model": "NestedRaid",
            "size": 21474836480, "type": "disk", "rm": False, "ro": False,
            "children": [
                {"name": "sdb1", "path": "/dev/sdb1", "size": 21474836480,
                 "type": "part", "fstype": "ext4", "mountpoint": "",
                 "children": [
                     {"name": "md0", "path": "/dev/md0", "size": 21474836480,
                      "type": "raid1", "fstype": "ext4", "mountpoint": ""},
                 ]},
            ],
        },
        {
            "name": "sdc", "path": "/dev/sdc", "model": "Clean",
            "size": 21474836480, "type": "disk", "rm": False, "ro": False,
            "children": [
                {"name": "sdc1", "path": "/dev/sdc1", "size": 21474836480,
                 "type": "part", "fstype": "ext4", "mountpoint": ""},
            ],
        },
    ]
}

orig_check_output = bridge.subprocess.check_output
orig_readable = bridge._device_readable
# R-18: fake-устройств /dev/sd* в тестовом окружении нет — настоящая
# проба чтения вернула бы False для всех. Для существующих тестов
# disksJson проба подменяется (все читаемы); отдельные R-18-тесты
# ниже задают свою подмену.
bridge.subprocess.check_output = lambda *a, **k: json.dumps(FAKE_LSBLK)
bridge._device_readable = lambda p: True
try:
    b = bridge.InstallerBridge()
    out = json.loads(b.disksJson())
finally:
    bridge.subprocess.check_output = orig_check_output
    bridge._device_readable = orig_readable

by_path = {d["path"]: d for d in out.get("disks", [])}
check("disksJson: 3 диска", len(out.get("disks", [])), 3)
sda = by_path.get("/dev/sda", {})
check("disksJson: sda blocked (член внутри)", sda.get("blocked"), True)
sda_parts = {p["path"]: p for p in sda.get("partitions", [])}
check("disksJson: sda1 не заблокирован",
      sda_parts.get("/dev/sda1", {}).get("blocked"), False)
check("disksJson: sda2 (член RAID) заблокирован",
      sda_parts.get("/dev/sda2", {}).get("blocked"), True)
sdb = by_path.get("/dev/sdb", {})
check("disksJson: sdb blocked (вложенный md)",
      sdb.get("blocked"), True)
sdb_parts = {p["path"]: p for p in sdb.get("partitions", [])}
check("disksJson: sdb1 blocked (под ним md0)",
      sdb_parts.get("/dev/sdb1", {}).get("blocked"), True)
sdc = by_path.get("/dev/sdc", {})
check("disksJson: sdc не заблокирован", sdc.get("blocked"), False)
sdc_parts = {p["path"]: p for p in sdc.get("partitions", [])}
check("disksJson: sdc1 не заблокирован",
      sdc_parts.get("/dev/sdc1", {}).get("blocked"), False)

# ---------- R-18: нечитаемые устройства (реальная _device_readable) ----------
check("_device_readable: несуществующий путь", bridge._device_readable("/dev/nonexistent-xros-test"), False)
check("_device_readable: обычный файл", bridge._device_readable(__file__), False)
check("_device_readable: каталог", bridge._device_readable("/tmp"), False)
check("_device_readable: /dev/null (не блочное)", bridge._device_readable("/dev/null"), False)
check("_device_readable: пустой путь", bridge._device_readable(""), False)

# ---------- R-18: disksJson с нечитаемыми устройствами (подмена пробы) ----------
def _disks_with_readable(unreadable):
    bridge.subprocess.check_output = lambda *a, **k: json.dumps(FAKE_LSBLK)
    bridge._device_readable = lambda p: p not in unreadable
    try:
        return json.loads(bridge.InstallerBridge().disksJson())
    finally:
        bridge.subprocess.check_output = orig_check_output
        bridge._device_readable = orig_readable

out2 = _disks_with_readable({"/dev/sdc"})
by2 = {d["path"]: d for d in out2.get("disks", [])}
check("R-18 disksJson: нечитаемый чистый диск sdc blocked",
      by2.get("/dev/sdc", {}).get("blocked"), True)
check("R-18 disksJson: читаемый sda по-прежнему blocked только из-за RAID",
      by2.get("/dev/sda", {}).get("blocked"), True)
out3 = _disks_with_readable({"/dev/sdc1"})
by3 = {d["path"]: d for d in out3.get("disks", [])}
sdc3 = by3.get("/dev/sdc", {})
sdc3_parts = {p["path"]: p for p in sdc3.get("partitions", [])}
check("R-18 disksJson: нечитаемый раздел sdc1 blocked",
      sdc3_parts.get("/dev/sdc1", {}).get("blocked"), True)
check("R-18 disksJson: диск sdc при нечитаемом разделе не blocked",
      sdc3.get("blocked"), False)

print(f"ИТОГ: PASS={PASS} FAIL={FAIL}")
if FAIL:
    print("Не пройдено:")
    for name in FAILED:
        print(f"  - {name}")
    sys.exit(1)
