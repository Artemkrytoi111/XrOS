import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 2 — Регион и часовой пояс.
// Часовые пояса — реальные, из /usr/share/zoneinfo (bridge).
// Автоопределение — через timedatectl / /etc/localtime.
Item {
    id: screen
    property var installer
    property var zones: []
    property string selectedZone: ""
    property string detectedZone: ""
    property string nowText: ""

    function validate() { return selectedZone !== "" }

    Component.onCompleted: {
        zones = JSON.parse(bridge.timezonesJson())
        detectedZone = bridge.detectTimezone()
        selectedZone = installer.settings["TIMEZONE"] || detectedZone
        zoneField.text = selectedZone
        nowText = bridge.currentTime()
        timeTimer.start()
    }

    Timer {
        id: timeTimer
        interval: 1000; repeat: true
        onTriggered: nowText = bridge.currentTime()
    }

    function applyZone() {
        installer.settings["TIMEZONE"] = selectedZone
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 16

        Text {
            text: installer.uiLang === "en" ? "Region and time zone" : "Регион и часовой пояс"
            color: Theme.text; font { pixelSize: 26; bold: true }
        }
        Text {
            text: installer.uiLang === "en"
                  ? "Choose your time zone. It will be set on the installed system."
                  : "Выберите часовой пояс. Он будет установлен в системе после установки."
            color: Theme.textSecondary; font.pixelSize: 15; wrapMode: Text.WordWrap
            Layout.maximumWidth: 700
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            // Поиск + список.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: zoneField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    placeholderText: installer.uiLang === "en" ? "Search time zone…" : "Поиск часового пояса…"
                    font.pixelSize: 15
                    color: Theme.text
                    placeholderTextColor: Theme.textSecondary
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: Theme.card
                        border { color: zoneField.activeFocus ? Theme.accent : Theme.border; width: 1 }
                    }
                    onTextChanged: {
                        selectedZone = text
                        applyZone()
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 280
                    radius: Theme.radius
                    color: Theme.card
                    border { color: Theme.border; width: 1 }
                    clip: true
                    ListView {
                        id: zoneList
                        anchors { fill: parent; margins: 6 }
                        model: zones.filter(function(z) {
                            return zoneField.text === "" ||
                                   z.toLowerCase().indexOf(zoneField.text.toLowerCase()) !== -1
                        })
                        delegate: ItemDelegate {
                            width: zoneList.width
                            height: 40
                            highlighted: modelData === selectedZone
                            onClicked: {
                                selectedZone = modelData
                                zoneField.text = modelData
                                applyZone()
                            }
                            contentItem: Text {
                                text: modelData
                                color: modelData === selectedZone ? Theme.accent2 : Theme.text
                                font { pixelSize: 15; bold: modelData === selectedZone }
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
            // Правая карточка: автоопределение и текущее время.
            ColumnLayout {
                Layout.preferredWidth: 280
                spacing: 12
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 150
                    radius: Theme.radius
                    color: Theme.card
                    border { color: Theme.border; width: 1 }
                    ColumnLayout {
                        anchors { fill: parent; margins: 16 }
                        spacing: 6
                        Text {
                            text: installer.uiLang === "en" ? "Detected automatically" : "Определено автоматически"
                            color: Theme.textSecondary; font.pixelSize: 13
                        }
                        Text {
                            text: detectedZone
                            color: Theme.text; font { pixelSize: 18; bold: true }
                            wrapMode: Text.WordWrap
                        }
                        Button {
                            text: installer.uiLang === "en" ? "Use detected" : "Использовать его"
                            onClicked: {
                                selectedZone = detectedZone
                                zoneField.text = detectedZone
                                applyZone()
                            }
                            background: Rectangle {
                                radius: Theme.radiusSmall
                                color: parent.hovered ? Theme.accent2 : Theme.accent
                            }
                            contentItem: Text {
                                text: parent.text; color: Theme.text
                                font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter
                            }
                            Layout.preferredHeight: 38
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96
                    radius: Theme.radius
                    color: Theme.card
                    border { color: Theme.border; width: 1 }
                    ColumnLayout {
                        anchors { fill: parent; margins: 16 }
                        spacing: 4
                        Text {
                            text: installer.uiLang === "en" ? "Current time" : "Текущее время"
                            color: Theme.textSecondary; font.pixelSize: 13
                        }
                        Text {
                            text: nowText
                            color: Theme.text; font { pixelSize: 18; bold: true }
                        }
                        Text {
                            text: selectedZone
                            color: Theme.accent2; font.pixelSize: 14
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
