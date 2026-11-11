import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "strings.js" as Strings

// XrOS 1.0 Diamond — оболочка установщика.
// Боковая панель (логотип, название, шаги) + центральная область
// + нижняя панель (Назад / основное действие / Отмена).
// ОБЩЕГО ПРОГРЕССА НЕТ: ни полосы, ни процента — только шаги.
ApplicationWindow {
    id: root
    visible: true
    width: 1280
    height: 720
    minimumWidth: 1024
    minimumHeight: 600
    title: "XrOS 1.0 Diamond"
    color: Theme.bg

    property string uiLang: "ru"
    property int currentStep: 0
    property var settings: ({
        "PARTMODE": "erase", "FS": "ext4", "TIMEZONE": "Europe/Samara",
        "KEYMAP": "ru", "AUTOLOGIN": "0", "OFFICE": "none", "DE": "kde",
        "FULLNAME": "", "USERNAME": "", "USERPASS": "", "ROOTPASS": "",
        "DISK": "", "ROOT_PART": "", "HOSTNAME": "xros-os"
    })
    property var completedSteps: []

    function tr(key) { return Strings.t(uiLang, key) }

    property var stepDefs: [
        { "key": "stepWelcome",  "file": "screens/Welcome.qml" },
        { "key": "stepRegion",   "file": "screens/Region.qml" },
        { "key": "stepKeyboard", "file": "screens/Keyboard.qml" },
        { "key": "stepDisk",     "file": "screens/Disk.qml" },
        { "key": "stepUser",     "file": "screens/User.qml" },
        { "key": "stepSummary",  "file": "screens/Summary.qml" },
        { "key": "stepInstall",  "file": "screens/Install.qml" },
        { "key": "stepFinish",   "file": "screens/Finish.qml" }
    ]

    function stepTitle(i) { return tr(stepDefs[i].key) }
    function isCompleted(i) { return completedSteps.indexOf(i) !== -1 }
    function markCompleted(i) {
        if (!isCompleted(i)) completedSteps.push(i)
    }
    function canGoNext() {
        // Каждый экран сам решает, можно ли идти дальше (validate()).
        var item = stack.currentItem
        return item && item.validate ? item.validate() : true
    }
    function goNext() {
        if (currentStep >= stepDefs.length - 1) return
        if (!canGoNext()) return
        markCompleted(currentStep)
        currentStep++
        stack.replace(stepDefs[currentStep].file, {"installer": root})
    }
    function goBack() {
        if (currentStep <= 0) return
        currentStep--
        stack.replace(stepDefs[currentStep].file, {"installer": root})
    }
    function stackReplace(i) {
        currentStep = i
        stack.replace(stepDefs[i].file, {"installer": root})
    }

    // ---------- боковая панель ----------
    Rectangle {
        id: sidebar
        anchors { left: parent.left; top: parent.top; bottom: bottomBar.top }
        width: Theme.sidebarWidth
        color: Theme.bgAlt

        ColumnLayout {
            anchors { fill: parent; margins: 24 }
            spacing: 0

            // Логотип X (векторный, без картинки).
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 84; height: 84; radius: 20
                color: Theme.accentSoft
                border { color: Theme.accent; width: 2 }
                Text {
                    anchors.centerIn: parent
                    text: "X"
                    color: Theme.accent2
                    font { pixelSize: 52; bold: true; family: "Sans" }
                }
            }
            Item { Layout.preferredHeight: 16 }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tr("appName")
                color: Theme.text
                font { pixelSize: 22; bold: true }
            }
            Item { Layout.preferredHeight: 6 }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tr("slogan")
                color: Theme.textSecondary
                font.pixelSize: 13
            }
            Item { Layout.preferredHeight: 28 }

            // Список шагов.
            Repeater {
                model: stepDefs.length
                delegate: Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    radius: Theme.radiusSmall
                    color: index === root.currentStep ? Theme.accentSoft
                          : "transparent"
                    border {
                        color: index === root.currentStep ? Theme.accent : "transparent"
                        width: 1
                    }
                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        spacing: 12
                        Rectangle {
                            width: 26; height: 26; radius: 13
                            color: root.isCompleted(index) ? Theme.accent
                                 : index === root.currentStep ? Theme.accent
                                 : Theme.card
                            border { color: Theme.border; width: 1 }
                            Text {
                                anchors.centerIn: parent
                                text: root.isCompleted(index) ? "✓" : (index + 1)
                                color: Theme.text
                                font { pixelSize: 13; bold: true }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.stepTitle(index)
                            color: index === root.currentStep ? Theme.text
                                 : root.isCompleted(index) ? Theme.text
                                 : Theme.textSecondary
                            font {
                                pixelSize: 14
                                bold: index === root.currentStep
                            }
                            elide: Text.ElideRight
                        }
                    }
                }
            }
            Item { Layout.fillHeight: true }
        }
        Rectangle { // разделитель
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: 1; color: Theme.border
        }
    }

    // ---------- центральная область ----------
    StackView {
        id: stack
        anchors {
            left: sidebar.right; right: parent.right
            top: parent.top; bottom: bottomBar.top
        }
        initialItem: stepDefs[0].file
        Component.onCompleted: {
            if (stack.currentItem) stack.currentItem.installer = root
        }
        // Плавные, сдержанные переходы.
        pushEnter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 } }
        pushExit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 160 } }
        popEnter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 } }
        popExit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 160 } }
    }

    // ---------- нижняя панель ----------
    Rectangle {
        id: bottomBar
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: Theme.bottomBarHeight
        color: Theme.bgAlt
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 1; color: Theme.border
        }
        RowLayout {
            anchors { fill: parent; leftMargin: 24; rightMargin: 24 }
            spacing: 12
            Button {
                text: tr("back")
                enabled: root.currentStep > 0 && root.currentStep < 6
                onClicked: root.goBack()
                background: Rectangle {
                    radius: Theme.radiusSmall
                    color: parent.hovered ? Theme.card : "transparent"
                    border { color: Theme.border; width: 1 }
                }
                contentItem: Text {
                    text: parent.text; color: Theme.text
                    font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter
                }
                Layout.preferredWidth: 140; Layout.preferredHeight: 44
            }
            Item { Layout.fillWidth: true }
            Button {
                text: tr("cancel")
                visible: root.currentStep < 6
                onClicked: cancelDialog.open()
                background: Rectangle {
                    radius: Theme.radiusSmall
                    color: parent.hovered ? Theme.card : "transparent"
                    border { color: Theme.border; width: 1 }
                }
                contentItem: Text {
                    text: parent.text; color: Theme.textSecondary
                    font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter
                }
                Layout.preferredWidth: 140; Layout.preferredHeight: 44
            }
            Button {
                id: nextButton
                text: root.currentStep === 0 ? tr("startInstall")
                    : root.currentStep === 5 ? tr("install")
                    : root.currentStep === 7 ? tr("finish")
                    : tr("next")
                visible: root.currentStep !== 6
                enabled: root.canGoNext()
                onClicked: {
                    if (root.currentStep === 5) {
                        // Итог → экран установки: сам экран запустит движок.
                        root.markCompleted(root.currentStep)
                        root.currentStep = 6
                        stack.replace(stepDefs[6].file, {"installer": root})
                    } else if (root.currentStep === 7) {
                        stack.currentItem.finish()
                    } else {
                        root.goNext()
                    }
                }
                background: Rectangle {
                    radius: Theme.radiusSmall
                    color: parent.enabled
                           ? (parent.hovered ? Theme.accent2 : Theme.accent)
                           : Theme.border
                }
                contentItem: Text {
                    text: parent.text; color: Theme.text
                    font { pixelSize: 15; bold: true }
                    horizontalAlignment: Text.AlignHCenter
                }
                Layout.preferredWidth: 200; Layout.preferredHeight: 44
            }
        }
    }

    // ---------- диалог отмены ----------
    Dialog {
        id: cancelDialog
        anchors.centerIn: parent
        width: 460
        title: tr("cancelTitle")
        modal: true
        background: Rectangle { color: Theme.bgAlt; radius: Theme.radius; border { color: Theme.border; width: 1 } }
        header: Text {
            text: cancelDialog.title; color: Theme.text
            font { pixelSize: 18; bold: true }
            padding: 20; leftPadding: 24
        }
        contentItem: Text {
            text: tr("cancelText"); color: Theme.textSecondary
            font.pixelSize: 15; wrapMode: Text.WordWrap
            padding: 24; topPadding: 0
        }
        footer: DialogButtonBox {
            Button {
                text: tr("cancelYes")
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
                onClicked: cancelDialog.accept()
                background: Rectangle { radius: Theme.radiusSmall; color: Theme.danger }
                contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
            }
            Button {
                text: tr("cancelNo")
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
                background: Rectangle { radius: Theme.radiusSmall; color: "transparent"; border { color: Theme.border; width: 1 } }
                contentItem: Text { text: parent.text; color: Theme.text; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
            }
        }
        onAccepted: Qt.quit()
    }
}
