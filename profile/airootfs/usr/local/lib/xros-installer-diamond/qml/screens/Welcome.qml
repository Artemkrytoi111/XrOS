import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 1 — Приветствие «Добро пожаловать в XrOS 1.0 Diamond».
Item {
    id: screen
    property var installer

    function validate() { return true }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 0

        Item { Layout.fillHeight: true }

        // Логотип X.
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width: 120; height: 120; radius: 28
            color: Theme.accentSoft
            border { color: Theme.accent; width: 2 }
            Text {
                anchors.centerIn: parent
                text: "X"
                color: Theme.accent2
                font { pixelSize: 72; bold: true }
            }
        }
        Item { Layout.preferredHeight: 24 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: installer.uiLang === "en"
                  ? "Welcome to XrOS 1.0 Diamond"
                  : "Добро пожаловать в XrOS 1.0 Diamond"
            color: Theme.text
            font { pixelSize: 30; bold: true }
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
        Item { Layout.preferredHeight: 12 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: 640
            text: installer.uiLang === "en"
                  ? "A modern, fast and convenient system based on Arch Linux. This installer will guide you through the setup in a few steps."
                  : "Современная, быстрая и удобная система на базе Arch Linux. Установщик проведёт вас через настройку за несколько шагов."
            color: Theme.textSecondary
            font.pixelSize: 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
        Item { Layout.preferredHeight: 28 }

        // Версия и выбор языка интерфейса.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 24
            Rectangle {
                Layout.preferredWidth: 220; Layout.preferredHeight: 56
                radius: Theme.radiusSmall
                color: Theme.card
                border { color: Theme.border; width: 1 }
                ColumnLayout {
                    anchors { fill: parent; margins: 10 }
                    spacing: 2
                    Text {
                        text: installer.uiLang === "en" ? "Edition" : "Выпуск"
                        color: Theme.textSecondary; font.pixelSize: 12
                    }
                    Text { text: "XrOS 1.0 Diamond"; color: Theme.text; font { pixelSize: 15; bold: true } }
                }
            }
            ColumnLayout {
                spacing: 4
                Text { text: installer.tr("language"); color: Theme.textSecondary; font.pixelSize: 12 }
                ComboBox {
                    id: langBox
                    Layout.preferredWidth: 180; Layout.preferredHeight: 40
                    model: ["Русский", "English"]
                    currentIndex: installer.uiLang === "en" ? 1 : 0
                    onCurrentIndexChanged: {
                        // При создании ComboBox currentIndex меняется ДО
                        // присвоения свойства installer экрану — без guard'а
                        // здесь TypeError (поймано в Live fixed10, 11.11.2026).
                        if (installer) installer.uiLang = currentIndex === 1 ? "en" : "ru"
                    }
                    background: Rectangle {
                        radius: Theme.radiusSmall
                        color: Theme.card
                        border { color: Theme.border; width: 1 }
                    }
                    contentItem: Text {
                        text: parent.displayText; color: Theme.text
                        font.pixelSize: 15; verticalAlignment: Text.AlignVCenter
                        leftPadding: 12
                    }
                    delegate: ItemDelegate {
                        width: langBox.width
                        contentItem: Text { text: modelData; color: Theme.text; font.pixelSize: 15 }
                        background: Rectangle { color: highlighted ? Theme.accentSoft : Theme.bgAlt }
                    }
                    popup.background: Rectangle {
                        color: Theme.bgAlt; radius: Theme.radiusSmall
                        border { color: Theme.border; width: 1 }
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
