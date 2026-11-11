import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 4 — Разметка диска.
// Диски — ТОЛЬКО реальные (lsblk через bridge). Диск с ISO показан,
// но выбрать его нельзя. Авто-выбора физического диска НЕТ:
// пока пользователь сам не выберет диск, validate() == false.
// Подтверждение перед форматированием — обязательный диалог с точным
// именем диска и списком разделов. Форматирует движок на экране
// установки; этот экран только фиксирует выбор в настройках.
Item {
    id: screen
    property var installer
    property var disks: []
    property var selectedDisk: null
    property string selectedPart: ""
    property string partMode: "erase"
    property string fs: "ext4"
    property bool confirmed: false

    function validate() {
        if (!selectedDisk || selectedDisk.isIsoDisk) return false
        if (partMode === "manual" && selectedPart === "") return false
        return confirmed
    }

    Component.onCompleted: {
        var data = JSON.parse(bridge.disksJson())
        disks = data.disks || []
        // Восстановить выбор, если возвращались назад.
        if (installer.settings["DISK"]) {
            for (var i = 0; i < disks.length; i++) {
                if (disks[i].path === installer.settings["DISK"])
                    selectedDisk = disks[i]
            }
        }
        partMode = installer.settings["PARTMODE"] || "erase"
        fs = installer.settings["FS"] || "ext4"
        selectedPart = installer.settings["ROOT_PART"] || ""
    }

    function applyChoice() {
        installer.settings["PARTMODE"] = partMode
        installer.settings["FS"] = fs
        installer.settings["DISK"] = selectedDisk ? selectedDisk.path : ""
        installer.settings["ROOT_PART"] = partMode === "manual" ? selectedPart : ""
    }

    function openConfirm() {
        confirmDialog.diskName = selectedDisk ? selectedDisk.path + " (" + selectedDisk.model + ", " + selectedDisk.sizeHuman + ")" : ""
        confirmDialog.partList = selectedDisk ? selectedDisk.partitions : []
        confirmDialog.open()
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 16

        Text {
            text: installer.uiLang === "en" ? "Disk partitioning" : "Разметка диска"
            color: Theme.text; font { pixelSize: 26; bold: true }
        }
        Text {
            text: installer.uiLang === "en"
                  ? "Choose the disk for XrOS. Nothing is formatted yet — the confirmation below is required before any change."
                  : "Выберите диск для XrOS. Пока ничего не форматируется — перед любыми изменениями нужно подтверждение ниже."
            color: Theme.textSecondary; font.pixelSize: 15; wrapMode: Text.WordWrap
            Layout.maximumWidth: 700
        }

        // Режим разметки.
        RowLayout {
            spacing: 12
            Repeater {
                model: [
                    { "code": "erase", "name": installer.uiLang === "en" ? "Erase disk (automatic)" : "Очистить диск (автоматически)" },
                    { "code": "manual", "name": installer.uiLang === "en" ? "Manual partitioning" : "Разметка вручную" }
                ]
                delegate: Button {
                    text: modelData.name
                    Layout.preferredHeight: 44
                    onClicked: { partMode = modelData.code; applyChoice() }
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: partMode === modelData.code ? Theme.accent : Theme.card
                        border { color: partMode === modelData.code ? Theme.accent : Theme.border; width: 1 }
                    }
                    contentItem: Text {
                        text: parent.text; color: Theme.text
                        font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
            Item { Layout.fillWidth: true }
            // ФС.
            Text { text: "ФС:"; color: Theme.textSecondary; font.pixelSize: 15 }
            ComboBox {
                model: ["ext4", "btrfs", "xfs"]
                currentIndex: ["ext4", "btrfs", "xfs"].indexOf(fs)
                onCurrentIndexChanged: { fs = model[currentIndex]; applyChoice() }
                Layout.preferredWidth: 120; Layout.preferredHeight: 40
                background: Rectangle { radius: Theme.radiusSmall; color: Theme.card; border { color: Theme.border; width: 1 } }
                contentItem: Text { text: parent.displayText; color: Theme.text; font.pixelSize: 15; verticalAlignment: Text.AlignVCenter; leftPadding: 12 }
                delegate: ItemDelegate {
                    width: parent.width
                    contentItem: Text { text: modelData; color: Theme.text; font.pixelSize: 15 }
                    background: Rectangle { color: highlighted ? Theme.accentSoft : Theme.bgAlt }
                }
                popup.background: Rectangle { color: Theme.bgAlt; radius: Theme.radiusSmall; border { color: Theme.border; width: 1 } }
            }
        }

        // Список дисков.
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 220
            radius: Theme.radius
            color: Theme.card
            border { color: Theme.border; width: 1 }
            clip: true
            ListView {
                anchors { fill: parent; margins: 6 }
                model: disks
                delegate: ItemDelegate {
                    width: parent.width
                    height: 76
                    enabled: !modelData.isIsoDisk
                    highlighted: selectedDisk && selectedDisk.path === modelData.path
                    onClicked: {
                        selectedDisk = modelData
                        selectedPart = ""
                        confirmed = false
                        applyChoice()
                    }
                    contentItem: ColumnLayout {
                        spacing: 2
                        RowLayout {
                            Text {
                                text: modelData.model + "  •  " + modelData.path
                                color: modelData.isIsoDisk ? Theme.textSecondary : Theme.text
                                font { pixelSize: 16; bold: true }
                            }
                            Text {
                                text: modelData.sizeHuman
                                color: Theme.accent2; font.pixelSize: 15
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: modelData.isIsoDisk
                                      ? (installer.uiLang === "en" ? "ISO disk — cannot be used" : "Диск с ISO — недоступен")
                                      : (selectedDisk && selectedDisk.path === modelData.path ? "✓" : "")
                                color: modelData.isIsoDisk ? Theme.warning : Theme.accent2
                                font.pixelSize: 14
                            }
                        }
                        Text {
                            text: modelData.partitions.length === 0
                                  ? (installer.uiLang === "en" ? "No partitions" : "Нет разделов")
                                  : modelData.partitions.map(function(p) {
                                        return p.path + " " + (p.fs || "—") + " " + p.sizeHuman
                                    }).join("   •   ")
                            color: Theme.textSecondary; font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                    }
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: highlighted ? Theme.accentSoft : "transparent"
                        border { color: highlighted ? Theme.accent : "transparent"; width: 1 }
                    }
                }
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            }
        }

        // Ручной режим: выбор корневого раздела.
        Rectangle {
            visible: partMode === "manual" && selectedDisk
            Layout.fillWidth: true
            Layout.preferredHeight: 110
            radius: Theme.radius
            color: Theme.card
            border { color: Theme.border; width: 1 }
            ColumnLayout {
                anchors { fill: parent; margins: 16 }
                spacing: 8
                Text {
                    text: installer.uiLang === "en" ? "Root partition (will be formatted)" : "Корневой раздел (будет отформатирован)"
                    color: Theme.text; font { pixelSize: 15; bold: true }
                }
                ComboBox {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    model: selectedDisk ? selectedDisk.partitions.map(function(p) { return p.path + "  " + (p.fs || "") + "  " + p.sizeHuman }) : []
                    onCurrentIndexChanged: {
                        if (selectedDisk && currentIndex >= 0) {
                            selectedPart = selectedDisk.partitions[currentIndex].path
                            applyChoice()
                        }
                    }
                    background: Rectangle { radius: Theme.radiusSmall; color: Theme.bg; border { color: Theme.border; width: 1 } }
                    contentItem: Text { text: parent.displayText; color: Theme.text; font.pixelSize: 15; verticalAlignment: Text.AlignVCenter; leftPadding: 12 }
                }
            }
        }

        // Подтверждение.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            radius: Theme.radius
            color: confirmed ? Theme.accentSoft : Theme.card
            border { color: confirmed ? Theme.accent : Theme.border; width: 1 }
            RowLayout {
                anchors { fill: parent; margins: 12 }
                spacing: 12
                Button {
                    text: confirmed
                          ? (installer.uiLang === "en" ? "Confirmed ✓" : "Подтверждено ✓")
                          : (installer.uiLang === "en" ? "Confirm disk choice…" : "Подтвердить выбор диска…")
                    enabled: selectedDisk && !selectedDisk.isIsoDisk && (partMode === "erase" || selectedPart !== "")
                    onClicked: openConfirm()
                    Layout.preferredHeight: 40
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: confirmed ? Theme.accent : (parent.hovered ? Theme.accent2 : Theme.accent)
                    }
                    contentItem: Text {
                        text: parent.text; color: Theme.text
                        font { pixelSize: 15; bold: true }
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
                Text {
                    text: confirmed
                          ? (installer.uiLang === "en" ? "The disk will be changed only during installation." : "Диск будет изменён только во время установки.")
                          : (installer.uiLang === "en" ? "Formatting needs your explicit confirmation." : "Форматирование требует явного подтверждения.")
                    color: Theme.textSecondary; font.pixelSize: 13
                    wrapMode: Text.WordWrap; Layout.fillWidth: true
                }
            }
        }
    }

    // ---------- диалог подтверждения ----------
    Dialog {
        id: confirmDialog
        anchors.centerIn: parent
        width: 560
        modal: true
        property string diskName: ""
        property var partList: []
        title: installer.uiLang === "en" ? "Confirm disk change" : "Подтверждение изменения диска"
        background: Rectangle { color: Theme.bgAlt; radius: Theme.radius; border { color: Theme.border; width: 1 } }
        header: Text {
            text: confirmDialog.title; color: Theme.text
            font { pixelSize: 18; bold: true }
            padding: 20; leftPadding: 24
        }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: (installer.uiLang === "en" ? "During installation, this disk will be changed:" : "Во время установки будет изменён диск:")
                      + "\n" + confirmDialog.diskName
                color: Theme.text; font.pixelSize: 15; wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Text {
                text: (installer.uiLang === "en" ? "Partitions that will be erased:" : "Разделы, которые будут стёрты:")
                      + "\n" + (confirmDialog.partList.length === 0
                                 ? (installer.uiLang === "en" ? "— none, the disk is empty —" : "— нет, диск пустой —")
                                 : confirmDialog.partList.map(function(p) { return "• " + p.path + " " + (p.fs || "") + " " + p.sizeHuman }).join("\n"))
                color: Theme.danger; font.pixelSize: 15; wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            Text {
                text: installer.uiLang === "en"
                      ? "All data on these partitions will be lost. This cannot be undone."
                      : "Все данные на этих разделах будут потеряны. Это нельзя отменить."
                color: Theme.textSecondary; font.pixelSize: 14; wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
        footer: DialogButtonBox {
            Button {
                text: installer.uiLang === "en" ? "Yes, I confirm" : "Да, подтверждаю"
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
                background: Rectangle { radius: Theme.radiusSmall; color: Theme.danger }
                contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
            }
            Button {
                text: installer.uiLang === "en" ? "Back" : "Назад"
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
                background: Rectangle { radius: Theme.radiusSmall; color: "transparent"; border { color: Theme.border; width: 1 } }
                contentItem: Text { text: parent.text; color: Theme.text; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
            }
        }
        onAccepted: { confirmed = true; applyChoice() }
    }
}
