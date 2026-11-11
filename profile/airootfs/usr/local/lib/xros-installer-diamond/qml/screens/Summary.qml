import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 6 — Итоговая проверка.
// Сводка всех выбранных настроек + подтверждение перед установкой.
// Кнопка «Назад» — вернуться и исправить; «Установить» — переход
// на экран установки (движок запускается там).
Item {
    id: screen
    property var installer

    function validate() { return true }

    function row(label, value) {
        return { "label": label, "value": value }
    }
    property var summary: []
    Component.onCompleted: {
        var s = installer.settings
        var ru = installer.uiLang !== "en"
        summary = [
            row(ru ? "Часовой пояс" : "Time zone", s["TIMEZONE"] || "—"),
            row(ru ? "Раскладка" : "Keyboard", (s["KEYMAP"] || "—") + (s["KEYMAPS"] ? " (" + s["KEYMAPS"] + ")" : "")),
            row(ru ? "Диск" : "Disk", (s["DISK"] || "—") + (s["PARTMODE"] === "manual" ? " → " + (s["ROOT_PART"] || "") : "")),
            row(ru ? "Разметка" : "Partitioning", s["PARTMODE"] === "manual" ? (ru ? "Вручную" : "Manual") : (ru ? "Очистить диск" : "Erase disk")),
            row(ru ? "Файловая система" : "Filesystem", s["FS"] || "ext4"),
            row(ru ? "Рабочий стол" : "Desktop", "KDE Plasma"),
            row(ru ? "Пользователь" : "User", (s["USERNAME"] || "—") + (s["FULLNAME"] ? " (" + s["FULLNAME"] + ")" : "")),
            row(ru ? "Имя компьютера" : "Computer name", s["HOSTNAME"] || "xros-os"),
            row(ru ? "Автовход" : "Autologin", s["AUTOLOGIN"] === "1" ? (ru ? "Включён" : "On") : (ru ? "Выключен" : "Off"))
        ]
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 16

        Text {
            text: installer.uiLang === "en" ? "Summary" : "Итоговая проверка"
            color: Theme.text; font { pixelSize: 26; bold: true }
        }
        Text {
            text: installer.uiLang === "en"
                  ? "Check everything before installation. Use Back to change anything."
                  : "Проверьте всё перед установкой. Чтобы изменить — вернитесь кнопкой «Назад»."
            color: Theme.textSecondary; font.pixelSize: 15; wrapMode: Text.Wrap
            Layout.maximumWidth: 700
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 300
            radius: Theme.radius
            color: Theme.card
            border { color: Theme.border; width: 1 }
            ListView {
                anchors { fill: parent; margins: 10 }
                model: summary
                delegate: Rectangle {
                    width: parent.width
                    height: 48
                    radius: Theme.radiusSmall
                    color: index % 2 === 0 ? "transparent" : Theme.bgAlt
                    RowLayout {
                        anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
                        Text {
                            text: modelData.label
                            color: Theme.textSecondary; font.pixelSize: 15
                            Layout.preferredWidth: 240
                        }
                        Text {
                            text: modelData.value
                            color: Theme.text; font { pixelSize: 15; bold: true }
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }
                }
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            radius: Theme.radiusSmall
            color: Theme.accentSoft
            border { color: Theme.accent; width: 1 }
            Text {
                anchors { fill: parent; margins: 12 }
                text: installer.uiLang === "en"
                      ? "Press «Install» to start. The disk will be changed only now."
                      : "Нажмите «Установить», чтобы начать. Диск будет изменён только сейчас."
                color: Theme.text; font.pixelSize: 14
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
