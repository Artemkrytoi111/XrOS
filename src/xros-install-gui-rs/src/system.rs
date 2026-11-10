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

// диск, с которого загружена живая система (или пусто)
pub fn iso_disk() -> String {
    let src = run(&["findmnt", "-n", "-o", "SOURCE", "/run/archiso/bootmnt"]);
    if src.is_empty() {
        return String::new();
    }
    run(&["lsblk", "-n", "-o", "PKNAME", &src])
}

pub fn list_disks() -> Vec<(String, String)> {
    let iso = iso_disk();
    let out = run(&["lsblk", "-d", "-n", "-o", "NAME,SIZE,TYPE"]);
    let mut disks = Vec::new();
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
        disks.push((dev, size.to_string()));
    }
    disks
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

pub fn list_partitions(disk: &str) -> Vec<(String, String, String)> {
    let out = run(&["lsblk", "-n", "-o", "NAME,SIZE,FSTYPE", disk]);
    let mut parts = Vec::new();
    for line in out.lines() {
        let mut cols = line.split_whitespace();
        let Some(name) = cols.next() else { continue };
        if format!("/dev/{name}") == disk {
            continue;
        }
        let size = cols.next().unwrap_or("").to_string();
        let fstype = cols.next().unwrap_or("").to_string();
        parts.push((format!("/dev/{name}"), size, fstype));
    }
    parts
}

pub fn is_uefi() -> bool {
    std::path::Path::new("/sys/firmware/efi").is_dir()
}
