import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 7 — Установка XrOS 1.0 Diamond.
// НИКАКОГО ОБЩЕГО ПРОГРЕССА: только текущая операция, реальный
// статус и журнал движка. Движок запускается при входе на экран
// (writeConf + startInstall). Отмена — реальная остановка движка.
Item {
    id: screen
    property var installer
    property string currentOp: ""
    property string statusText: ""
    property bool running: false
    property bool doneOk: false
    property bool doneFail: false
    property var logModel: []

    function validate() { return doneOk }

    Component.onCompleted: {
        // Запуск движка при входе на экран.
        var settings = installer.settings
        if (!bridge.writeConf(JSON.stringify(settings))) {
            statusText = installer.uiLang === "en"
                ? "Error: could not write the settings file."
                : "Ошибка: не удалось записать файл настроек."
            doneFail = true
            return
        }
        running = true
        statusText = installer.uiLang === "en" ? "Starting installation…" : "Запуск установки…"
        bridge.logLine.connect(onLogLine)
        bridge.installFinished.connect(onInstallFinished)
        if (!bridge.startInstall()) {
            statusText = installer.uiLang === "en"
                ? "Error: could not start the installer engine."
                : "Ошибка: не удалось запустить движок установки."
            doneFail = true
            running = false
        }
    }

    function onLogLine(line) {
        logModel.push(line)
        if (logModel.length > 500) logModel.shift()
        logView.positionViewAtEnd()
        // Текущая операция — из строк вида «==> Этап: ...» или «[...]».
        if (line.indexOf("==>") === 0 || line.indexOf("Этап") !== -1)
            currentOp = line.replace(/^==>\s*/, "")
        statusText = line
    }
    function onInstallFinished(ok, message) {
        running = false
        if (ok) {
            doneOk = true
            currentOp = installer.uiLang === "en" ? "Installation complete" : "Установка завершена"
            statusText = message
            installer.markCompleted(6)
            // Автопереход на экран завершения.
            installer.currentStep = 7
            installer.stackReplace(7)
        } else {
            doneFail = true
            currentOp = installer.uiLang === "en" ? "Installation failed" : "Установка не удалась"
            statusText = message
        }
    }

    function cancelInstall() {
        bridge.cancelInstall()
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 16

        Text {
            text: installer.uiLang === "en" ? "Installing XrOS 1.0 Diamond" : "Установка XrOS 1.0 Diamond"
            color: Theme.text; font { pixelSize: 26; bold: true }
        }

        // Текущая операция (без общего прогресса).
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 76
            radius: Theme.radius
            color: Theme.card
            border { color: Theme.border; width: 1 }
            RowLayout {
                anchors { fill: parent; margins: 16 }
                spacing: 16
                // Индикатор текущей операции (крутится, пока идёт).
                BusyIndicator {
                    running: screen.running
                    Layout.preferredWidth: 32; Layout.preferredHeight: 32
                    contentItem: Item {
                        implicitWidth: 32; implicitHeight: 32
                        Rectangle {
                            anchors.centerIn: parent
                            width: 28; height: 28; radius: 14
                            color: "transparent"
                            border { color: Theme.accent; width: 3 }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 10; height: 10; radius: 5
                                color: screen.doneFail ? Theme.danger : Theme.accent2
                            }
                        }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: currentOp === "" ? (installer.uiLang === "en" ? "Preparing…" : "Подготовка…") : currentOp
                        color: Theme.text; font { pixelSize: 16; bold: true }
                        elide: Text.ElideRight
                    }
                    Text {
                        text: statusText
                        color: Theme.textSecondary; font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // Журнал установки (реальный, построчно).
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.radius
            color: "#000000"
            border { color: Theme.border; width: 1 }
            clip: true
            ListView {
                id: logView
                anchors { fill: parent; margins: 12 }
                model: logModel
                delegate: Text {
                    text: modelData
                    color: Theme.textSecondary
                    font { pixelSize: 13; family: "Monospace" }
                    wrapMode: Text.Wrap
                    width: logView.width
                }
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            }
        }

        // Отмена (только пока идёт установка).
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button {
                text: installer.uiLang === "en" ? "Cancel installation" : "Отменить установку"
                visible: screen.running
                onClicked: cancelDialog.open()
                Layout.preferredHeight: 44
                background: Rectangle {
                    radius: Theme.radiusSmall
                    color: parent.hovered ? Theme.card : "transparent"
                    border { color: Theme.border; width: 1 }
                }
                contentItem: Text {
                    text: parent.text; color: Theme.textSecondary
                    font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }

    Dialog {
        id: cancelDialog
        anchors.centerIn: parent
        width: 460
        modal: true
        title: installer.uiLang === "en" ? "Cancel installation?" : "Отменить установку?"
        background: Rectangle { color: Theme.bgAlt; radius: Theme.radius; border { color: Theme.border; width: 1 } }
        header: Text {
            text: cancelDialog.title; color: Theme.text
            font { pixelSize: 18; bold: true }
            padding: 20; leftPadding: 24
        }
        contentItem: Text {
            text: installer.uiLang === "en"
                  ? "The engine will be stopped. The disk may be left in a partial state."
                  : "Движок будет остановлен. Диск может остаться в частичном состоянии."
            color: Theme.textSecondary; font.pixelSize: 15; wrapMode: Text.WordWrap
            padding: 24; topPadding: 0
        }
        footer: DialogButtonBox {
            Button {
                text: installer.uiLang === "en" ? "Yes, cancel" : "Да, отменить"
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
                background: Rectangle { radius: Theme.radiusSmall; color: Theme.danger }
                contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
            }
            Button {
                text: installer.uiLang === "en" ? "Keep installing" : "Продолжить установку"
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
                background: Rectangle { radius: Theme.radiusSmall; color: "transparent"; border { color: Theme.border; width: 1 } }
                contentItem: Text { text: parent.text; color: Theme.text; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
            }
        }
        onAccepted: screen.cancelInstall()
    }
}
