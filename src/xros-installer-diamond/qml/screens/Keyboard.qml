import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 3 — Раскладка клавиатуры.
// Основная раскладка — реальная: KEYMAP для движка (vconsole.conf).
// Поле проверки — реальное: setxkbmap переключает Live-сессию,
// поэтому набранный текст действительно идёт выбранной раскладкой.
// Дополнительные раскладки: работают в Live-сессии (setxkbmap
// "ru,us") и показываются в итоге; в установленной системе
// применяется основная раскладка (ограничение движка v1 — см. отчёт).
Item {
    id: screen
    property var installer
    property var layouts: [
        { "code": "ru", "name": "Русская" },
        { "code": "us", "name": "Английская (US)" },
        { "code": "ua", "name": "Украинская" },
        { "code": "de", "name": "Немецкая" },
        { "code": "fr", "name": "Французская" },
        { "code": "es", "name": "Испанская" },
        { "code": "it", "name": "Итальянская" },
        { "code": "tr", "name": "Турецкая" },
        { "code": "kz", "name": "Казахская" }
    ]
    property string primary: "ru"
    property var extra: []

    function validate() { return primary !== "" }

    Component.onCompleted: {
        primary = installer.settings["KEYMAP"] || "ru"
        bridge.setLiveKeymap(primary)
    }

    function applyLive() {
        var all = [primary].concat(extra)
        bridge.setLiveKeymap(all.join(","))
        installer.settings["KEYMAP"] = primary
        installer.settings["KEYMAPS"] = all.join(",")
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 16

        Text {
            text: installer.uiLang === "en" ? "Keyboard layout" : "Раскладка клавиатуры"
            color: Theme.text; font { pixelSize: 26; bold: true }
        }
        Text {
            text: installer.uiLang === "en"
                  ? "Choose the main layout. It will be set on the installed system. The test field below uses the selected layout right now."
                  : "Выберите основную раскладку. Она будет установлена в системе. Поле проверки ниже уже работает на выбранной раскладке."
            color: Theme.textSecondary; font.pixelSize: 15; wrapMode: Text.WordWrap
            Layout.maximumWidth: 700
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            // Список раскладок.
            // ВАЖНО (fixed10, 11.11.2026): голый Rectangle с fillWidth
            // напрямую в RowLayout схлопывается в 0 px ширины — список
            // не виден (поймано в Live BIOS: правая колонка заняла всю
            // ширину). Та же обёртка, что на экране Region (там работает):
            // ColumnLayout с fillWidth + minimumWidth у Rectangle.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 320
                Layout.minimumHeight: 300
                radius: Theme.radius
                color: Theme.card
                border { color: Theme.border; width: 1 }
                clip: true
                ListView {
                    anchors { fill: parent; margins: 6 }
                    model: layouts
                    delegate: ItemDelegate {
                        width: parent.width
                        height: 48
                        highlighted: modelData.code === primary
                        onClicked: { primary = modelData.code; applyLive() }
                        contentItem: RowLayout {
                            spacing: 12
                            Rectangle {
                                width: 22; height: 22; radius: 11
                                color: modelData.code === primary ? Theme.accent : "transparent"
                                border { color: Theme.accent; width: 2 }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.code === primary ? "✓" : ""
                                    color: Theme.text; font.pixelSize: 13
                                }
                            }
                            Text {
                                text: modelData.name
                                color: Theme.text; font.pixelSize: 15
                                Layout.fillWidth: true
                            }
                            Text {
                                text: modelData.code
                                color: Theme.textSecondary; font.pixelSize: 13
                            }
                        }
                        background: Rectangle {
                            radius: Theme.radiusSmall
                            color: highlighted ? Theme.accentSoft : "transparent"
                        }
                    }
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                }
            }
            }
            // Правая колонка: доп. раскладки + поле проверки.
            ColumnLayout {
                Layout.preferredWidth: 320
                spacing: 12
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 170
                    radius: Theme.radius
                    color: Theme.card
                    border { color: Theme.border; width: 1 }
                    ColumnLayout {
                        anchors { fill: parent; margins: 16 }
                        spacing: 8
                        Text {
                            text: installer.uiLang === "en" ? "Additional layouts" : "Дополнительные раскладки"
                            color: Theme.text; font { pixelSize: 15; bold: true }
                        }
                        Repeater {
                            model: ["us", "ru"]
                            delegate: CheckBox {
                                visible: modelData !== primary
                                checked: extra.indexOf(modelData) !== -1
                                text: modelData === "us" ? "Английская (US)" : "Русская"
                                onCheckedChanged: {
                                    if (checked && extra.indexOf(modelData) === -1)
                                        extra.push(modelData)
                                    else if (!checked)
                                        extra = extra.filter(function(x) { return x !== modelData })
                                    applyLive()
                                }
                                contentItem: Text {
                                    text: parent.text; color: Theme.text
                                    font.pixelSize: 14; leftPadding: parent.indicator.width + 8
                                }
                                indicator: Rectangle {
                                    implicitWidth: 22; implicitHeight: 22
                                    x: parent.leftPadding; y: parent.height / 2 - 11
                                    radius: 6
                                    color: parent.checked ? Theme.accent : "transparent"
                                    border { color: Theme.accent; width: 2 }
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.parent.checked ? "✓" : ""
                                        color: Theme.text; font.pixelSize: 13
                                    }
                                }
                            }
                        }
                        Text {
                            text: installer.uiLang === "en"
                                  ? "They work in the Live session now."
                                  : "Работают в Live-сессии уже сейчас."
                            color: Theme.textSecondary; font.pixelSize: 12
                            wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 120
                    radius: Theme.radius
                    color: Theme.card
                    border { color: Theme.border; width: 1 }
                    ColumnLayout {
                        anchors { fill: parent; margins: 16 }
                        spacing: 8
                        Text {
                            text: installer.uiLang === "en" ? "Test field" : "Поле проверки"
                            color: Theme.text; font { pixelSize: 15; bold: true }
                        }
                        TextField {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 44
                            placeholderText: installer.uiLang === "en" ? "Type here…" : "Печатайте здесь…"
                            font.pixelSize: 15
                            color: Theme.text
                            placeholderTextColor: Theme.textSecondary
                            background: Rectangle {
                                radius: Theme.radiusSmall
                                color: Theme.bg
                                border { color: activeFocus ? Theme.accent : Theme.border; width: 1 }
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
