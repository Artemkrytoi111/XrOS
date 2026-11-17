// Диски и разделы — просто обёртки над lsblk и findmnt.
// Показываем только настоящие диски, а тот, с которого загружен ISO, прячем.

use std::process::Command;

fn run(args: &[&str]) -> String {
    Command::new(args[0])
        .args(&args[1..])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

// R-03: то же, но с кодом возврата: None — команда не запустилась
// или завершилась ненулевым кодом. Используется там, где ошибка
// проверки не должна молча превращать устройство в «свободное».
fn run_status(args: &[&str]) -> Option<String> {
    let out = Command::new(args[0]).args(&args[1..]).output().ok()?;
    if out.status.success() {
        Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        None
    }
}

// диск, с которого загружена живая система (или пусто)
pub fn iso_disk() -> String {
    let src = run(&["findmnt", "-n", "-o", "SOURCE", "/run/archiso/bootmnt"]);
    if src.is_empty() {
        return String::new();
    }
    run(&["lsblk", "-n", "-o", "PKNAME", &src])
}

pub fn list_disks() -> (Vec<(String, String)>, Vec<String>) {
    let iso = iso_disk();
    let out = run(&["lsblk", "-d", "-n", "-o", "NAME,SIZE,TYPE"]);
    let mut disks = Vec::new();
    // R-03: ошибки проверки отдельных дисков — не молчаливое
    // исчезновение, а понятное состояние: диск не предлагается,
    // а причина возвращается вызывающему (App показывает её в status).
    let mut errors: Vec<String> = Vec::new();
    for line in out.lines() {
        let mut cols = line.split_whitespace();
        let (Some(name), Some(size), Some(kind)) =
            (cols.next(), cols.next(), cols.next())
        else {
            continue;
        };
        if kind != "disk" {
            continue;
        }
        // fd0, sr0, loop и прочий мусор нам не нужен
        if name.starts_with("fd")
            || name.starts_with("sr")
            || name.starts_with("loop")
            || name.starts_with("ram")
            || name.starts_with("zram")
        {
            continue;
        }
        if name == iso {
            continue;
        }
        // Диск со смонтированными разделами не предлагаем вовсе:
        // движок всё равно откажется его форматировать
        // (см. xros_has_mounts в xros-install), а так пользователь
        // не выберет его по ошибке. Заодно это страховка на случай
        // пустого iso_disk() (нештатная загрузка без bootmnt).
        let dev = format!("/dev/{name}");
        if has_mounts(&dev) {
            continue;
        }
        // A-24: диск с LVM/LUKS/RAID не предлагаем вовсе — движок
        // всё равно откажется (xros_disk_blocked в xros-install),
        // а так пользователь не выберет его по ошибке.
        match disk_check(&dev) {
            Ok(true) => continue, // заблокирован — не предлагаем
            Ok(false) => disks.push((dev, size.to_string())),
            Err(e) => errors.push(e), // ошибка проверки — не предлагаем, сообщаем
        }
    }
    (disks, errors)
}

// A-24/A-38: на диске (или его разделах) LVM/LUKS/RAID?
// Тип MD-массива — raid0/raid1/raid4/raid5/raid6/raid10 (не "raid"),
// поэтому TYPE проверяется по префиксу raid*; FSTYPE члена массива —
// linux_raid_member. Те же правила, что в src/xros-install
// (xros_disk_blocked) и в bridge.py (_device_blocked).
// R-02: добавлены все типы членов RAID/fakeraid из blkid (см.
// комментарий в xros-install) и LVM1_member.
fn is_blocked_fstype(fstype: &str) -> bool {
    matches!(
        fstype,
        "LVM1_member"
            | "LVM2_member"
            | "crypto_LUKS"
            | "linux_raid_member"
            | "isw_raid_member"
            | "ddf_raid_member"
            | "promise_fasttrack_raid_member"
            | "adaptec_raid_member"
            | "hpt37x_raid_member"
            | "hpt45x_raid_member"
            | "jmicron_raid_member"
            | "lsi_mega_raid_member"
            | "nvidia_raid_member"
            | "silicon_medley_raid_member"
            | "via_raid_member"
    )
}

fn is_blocked_kind(kind: &str) -> bool {
    kind == "lvm" || kind == "crypt" || kind.starts_with("raid")
}

// Одна строка вывода `lsblk -o FSTYPE,TYPE` заблокирована?
// Вынесено в чистую функцию ради unit-тестов.
fn line_blocked(line: &str) -> bool {
    let mut cols = line.split_whitespace();
    let fstype = cols.next().unwrap_or("");
    let kind = cols.next().unwrap_or("");
    is_blocked_fstype(fstype) || is_blocked_kind(kind)
}

// R-18: устройство пригодно для проверки сигнатуры, только если
// его первый сектор читается. blkid -p с rc=2 НЕ различает
// «сигнатуры нет» и «устройство не открывается» (проверено на хосте:
// несуществующий путь, каталог, /dev/null — rc=2, stderr пуст;
// Permission denied — rc=2, stderr непуст). Поэтому rc=2 трактуется
// как «нет сигнатуры» ТОЛЬКО после успешной пробы чтения; иначе —
// Err, а не Ok(false). Проба — открытие + чтение 512 байт
// (только чтение). Путь обязан быть блочным устройством.
fn device_readable(dev: &str) -> bool {
    use std::io::Read;
    use std::os::unix::fs::FileTypeExt;
    let md = match std::fs::metadata(dev) {
        Ok(m) => m,
        Err(_) => return false,
    };
    if !md.file_type().is_block_device() {
        return false;
    }
    let mut f = match std::fs::File::open(dev) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let mut buf = [0u8; 512];
    f.read(&mut buf).is_ok()
}

// R-03: независимая проверка через blkid (прямое чтение сигнатуры,
// как вторая нога в Bash). Семантика кодов blkid -p: 0 — сигнатура
// найдена, 2 — сигнатуры нет (норма для чистого устройства),
// остальные — ошибка. Ok(Some(t)) — сигнатура есть, Ok(None) — нет,
// Err — проверка невозможна (не молчим об этом).
// R-18: rc=2 без предварительной пробы чтения неоднозначен, поэтому
// blkid_type сначала вызывает device_readable; непустой stderr blkid
// — тоже Err (Permission denied и т.п.), даже при rc=2.
fn blkid_type(dev: &str) -> Result<Option<String>, String> {
    if !device_readable(dev) {
        return Err(format!(
            "устройство {dev} не читается (нет узла, исчезло, нет прав или ошибка ввода-вывода) — проверка невозможна (R-18)"
        ));
    }
    let output = Command::new("blkid")
        .args(["-p", "-s", "TYPE", "-o", "value", dev])
        .output()
        .map_err(|e| format!("blkid не запустился для {dev}: {e}"))?;
    if output.status.success() {
        let t = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Ok(if t.is_empty() { None } else { Some(t) });
    }
    if !output.stderr.is_empty() {
        return Err(format!(
            "blkid сообщил об ошибке для {dev}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    match output.status.code() {
        // rc=2 при пустом stderr и доказанно читаемом устройстве —
        // это «сигнатуры нет», норма для чистого устройства.
        Some(2) => Ok(None),
        Some(c) => Err(format!("blkid не смог прочитать {dev} (код {c})")),
        None => Err(format!("blkid для {dev} завершён сигналом")),
    }
}

// R-03: blkid-проверка устройства и всех его потомков (потомки —
// из lsblk -o PATH). Ошибка перечисления потомков или чтения любого
// устройства — Err, а не молчаливое «свободно».
fn blkid_blocked(dev: &str) -> Result<bool, String> {
    let paths = run_status(&["lsblk", "-n", "-o", "PATH", dev])
        .ok_or_else(|| format!("lsblk не смог перечислить потомков {dev}"))?;
    let mut targets = vec![dev.to_string()];
    for p in paths.lines() {
        let p = p.trim();
        if !p.is_empty() && p != dev {
            targets.push(p.to_string());
        }
    }
    for t in &targets {
        if let Some(fstype) = blkid_type(t)? {
            if is_blocked_fstype(&fstype) {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

// R-03/R-04: проверка диска. Ok(true) — заблокирован, Ok(false) —
// свободен, Err — проверка невозможна (устройство НЕ показывается
// как свободное). Две независимые ноги, как в Bash: lsblk, затем
// blkid. Чистый диск без сигнатур — Ok(false).
// R-18: проба чтения стоит ПЕРВОЙ: если устройство не читается,
// данные обеих ног недостоверны (lsblk может вернуть пустые строки,
// blkid — неоднозначный rc=2), поэтому возвращаем Err, а не Ok(false).
pub fn disk_check(dev: &str) -> Result<bool, String> {
    if !device_readable(dev) {
        return Err(format!(
            "устройство {dev} не читается — проверка невозможна (R-18)"
        ));
    }
    let out = run_status(&["lsblk", "-n", "-o", "FSTYPE,TYPE", dev])
        .ok_or_else(|| format!("lsblk не смог прочитать {dev}"))?;
    if out.lines().any(line_blocked) {
        return Ok(true);
    }
    blkid_blocked(dev)
}

// Есть ли смонтированные разделы на диске (или на самом разделе)?
// Смонтированный раздел — признак, что носитель используется живой
// системой (в первую очередь сам ISO-носитель: /run/archiso/bootmnt).
// Проверка не зависит от iso_disk(), поэтому защищает и при пустом
// ISODISK (нештатная загрузка).
pub fn has_mounts(dev: &str) -> bool {
    let out = run(&["lsblk", "-n", "-o", "MOUNTPOINT", dev]);
    out.lines().any(|l| !l.trim().is_empty())
}

pub fn list_partitions(disk: &str) -> (Vec<(String, String, String)>, Option<String>) {
    // -l (список, не дерево): без него NAME детей содержит символы
    // ├─/└─, и "/dev/{name}" не совпадает с реальным устройством.
    let out = match run_status(&["lsblk", "-l", "-n", "-o", "NAME,SIZE,FSTYPE,TYPE", disk]) {
        Some(o) => o,
        // R-03: lsblk не сработал — возвращаем пустой список ВМЕСТЕ
        // с понятной ошибкой, а не молчаливое «разделов нет».
        None => {
            return (
                Vec::new(),
                Some(format!("lsblk не смог прочитать разделы {disk}")),
            );
        }
    };
    let mut parts = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    for line in out.lines() {
        let mut cols = line.split_whitespace();
        let Some(name) = cols.next() else { continue };
        if format!("/dev/{name}") == disk {
            continue;
        }
        let size = cols.next().unwrap_or("").to_string();
        let fstype = cols.next().unwrap_or("").to_string();
        let kind = cols.next().unwrap_or("");
        // A-24/A-38: разделы LVM/LUKS/RAID не предлагаем как корень/EFI —
        // движок их всё равно отклонит (xros_disk_blocked). Проверяется
        // и FSTYPE, и TYPE: дочерняя строка md-устройства (FSTYPE=ext4,
        // TYPE=raid1) тоже отсекается.
        if is_blocked_fstype(&fstype) || is_blocked_kind(kind) {
            continue;
        }
        // R-03: вторая нога — blkid для раздела (как в Bash):
        // lsblk мог не показать сигнатуру; ошибка blkid — пропуск
        // раздела с сообщением, а не молчаливое предложение.
        let path = format!("/dev/{name}");
        match blkid_type(&path) {
            Ok(Some(t)) if is_blocked_fstype(&t) => continue,
            Ok(_) => {}
            Err(e) => {
                errors.push(e);
                continue;
            }
        }
        parts.push((path, size, fstype));
    }
    let err = if errors.is_empty() {
        None
    } else {
        Some(errors.join("; "))
    };
    (parts, err)
}

pub fn is_uefi() -> bool {
    std::path::Path::new("/sys/firmware/efi").is_dir()
}

#[cfg(test)]
mod tests {
    use super::*;

    // R-02/R-03: чистые функции решения — без реальных дисков.
    // blkid_type/disk_check требуют настоящих lsblk/blkid и
    // проверяются интеграционно (cargo test со stub-утилитами в PATH);
    // на этом хосте cargo отсутствует, поэтому тесты написаны, но
    // не запускались (см. отчёт R-03).

    #[test]
    fn blocked_fstype_md_and_fakeraid() {
        for t in [
            "linux_raid_member",
            "isw_raid_member",
            "ddf_raid_member",
            "promise_fasttrack_raid_member",
            "adaptec_raid_member",
            "hpt37x_raid_member",
            "hpt45x_raid_member",
            "jmicron_raid_member",
            "lsi_mega_raid_member",
            "nvidia_raid_member",
            "silicon_medley_raid_member",
            "via_raid_member",
        ] {
            assert!(is_blocked_fstype(t), "{t} должен блокироваться");
        }
    }

    #[test]
    fn blocked_fstype_lvm_luks() {
        assert!(is_blocked_fstype("LVM1_member"));
        assert!(is_blocked_fstype("LVM2_member"));
        assert!(is_blocked_fstype("crypto_LUKS"));
    }

    #[test]
    fn free_fstype_not_blocked() {
        for t in ["", "ext4", "vfat", "xfs", "btrfs", "swap", "ntfs"] {
            assert!(!is_blocked_fstype(t), "{t} не должен блокироваться");
        }
    }

    #[test]
    fn blocked_kind_prefix() {
        assert!(is_blocked_kind("lvm"));
        assert!(is_blocked_kind("crypt"));
        assert!(is_blocked_kind("raid"));
        for t in ["raid0", "raid1", "raid4", "raid5", "raid6", "raid10"] {
            assert!(is_blocked_kind(t), "{t} должен блокироваться");
        }
        for t in ["", "disk", "part", "rom", "crypttab"] {
            assert!(!is_blocked_kind(t), "{t} не должен блокироваться");
        }
    }

    #[test]
    fn line_blocked_matrix() {
        assert!(line_blocked("linux_raid_member part"));
        assert!(line_blocked("ext4 raid1"));
        assert!(line_blocked("isw_raid_member part"));
        assert!(line_blocked("LVM2_member part"));
        assert!(line_blocked("crypto_LUKS part"));
        assert!(!line_blocked("ext4 part"));
        assert!(!line_blocked(" part"));
        assert!(!line_blocked(""));
        assert!(!line_blocked("disk"));
    }

    // R-18: device_readable — только негативные кейсы без настоящих
    // блочных устройств (позитивный кейс требует /dev/sd* и проверяется
    // интеграционно, как blkid_type/disk_check; cargo на хосте нет).
    // Проба требует именно блочное устройство: символьное, обычный
    // файл и каталог — не читаются в смысле проверки сигнатуры.
    #[test]
    fn device_readable_negative() {
        assert!(!device_readable("/dev/nonexistent-xros-test"));
        assert!(!device_readable(""));
        assert!(!device_readable("/dev/null"));
        assert!(!device_readable("/tmp"));
    }

    // R-18: disk_check на нечитаемом устройстве — Err, а не Ok(false):
    // неопределённость никогда не становится «свободен».
    #[test]
    fn disk_check_unreadable_is_error() {
        assert!(disk_check("/dev/nonexistent-xros-test").is_err());
        assert!(disk_check("/dev/null").is_err());
    }
}
