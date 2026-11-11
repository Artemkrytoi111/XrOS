import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 8 — Завершение «XrOS 1.0 Diamond успешно установлена!».
// Чекбокс «Перезагрузить компьютер сейчас» включён по умолчанию.
// «Завершить»: с чекбоксом — перезагрузка (bridge.rebootSystem),
// без — просто закрыть установщик, остаться в Live.
Item {
    id: screen
    property var installer
    property bool rebootNow: true

    function validate() { return true }

    function finish() {
        if (rebootNow) {
            bridge.rebootSystem()
        }
        Qt.quit()
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 0

        Item { Layout.fillHeight: true }

        // Галочка успеха (фиолетовая, в палитре).
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width: 110; height: 110; radius: 55
            color: Theme.accentSoft
            border { color: Theme.accent; width: 2 }
            Text {
                anchors.centerIn: parent
                text: "✓"
                color: Theme.accent2
                font { pixelSize: 56; bold: true }
            }
        }
        Item { Layout.preferredHeight: 24 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: installer.uiLang === "en"
                  ? "XrOS 1.0 Diamond installed successfully!"
                  : "XrOS 1.0 Diamond успешно установлена!"
            color: Theme.text
            font { pixelSize: 28; bold: true }
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
        Item { Layout.preferredHeight: 12 }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: installer.uiLang === "en"
                  ? "Thank you for choosing XrOS. Your system is ready to use."
                  : "Спасибо, что выбрали XrOS. Ваша система готова к работе."
            color: Theme.textSecondary
            font.pixelSize: 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
        Item { Layout.preferredHeight: 32 }

        // Чекбокс перезагрузки (включён по умолчанию).
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 420
            Layout.preferredHeight: 64
            radius: Theme.radius
            color: Theme.card
            border { color: rebootNow ? Theme.accent : Theme.border; width: 1 }
            RowLayout {
                anchors { fill: parent; margins: 12 }
                spacing: 12
                Rectangle {
                    width: 26; height: 26; radius: 7
                    color: rebootNow ? Theme.accent : "transparent"
                    border { color: Theme.accent; width: 2 }
                    Text {
                        anchors.centerIn: parent
                        text: rebootNow ? "✓" : ""
                        color: Theme.text; font.pixelSize: 15
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: rebootNow = !rebootNow
                    }
                }
                Text {
                    text: installer.uiLang === "en"
                          ? "Restart the computer now"
                          : "Перезагрузить компьютер сейчас"
                    color: Theme.text; font.pixelSize: 16
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: rebootNow = !rebootNow
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
