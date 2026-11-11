import ".."
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Экран 5 — Пользователь и пароль.
// Проверки — реальные: имя только [a-z0-9_], пароль непустой,
// совпадение пароля и подтверждения, сила пароля по длине и составу.
// Имя компьютера по умолчанию xros-os (как в движке).
Item {
    id: screen
    property var installer
    property string username: ""
    property string fullname: ""
    property string hostname: "xros-os"
    property string pass1: ""
    property string pass2: ""
    property bool showPass: false
    property bool autologin: false
    // fixed10, D11: отдельный пароль root — необязательно.
    // Выключено = root = пароль пользователя (текущее поведение).
    property bool separateRoot: false
    property string rootPass1: ""
    property string rootPass2: ""

    function passStrength(p) {
        var score = 0
        if (p.length >= 8) score++
        if (p.length >= 12) score++
        if (/[a-z]/.test(p) && /[A-Z]/.test(p)) score++
        if (/[0-9]/.test(p)) score++
        if (/[^a-zA-Z0-9]/.test(p)) score++
        return score // 0..5
    }
    function strengthText(s) {
        if (installer.uiLang === "en")
            return ["Very weak", "Weak", "Fair", "Good", "Strong", "Very strong"][s]
        return ["Очень слабый", "Слабый", "Средний", "Хороший", "Сильный", "Очень сильный"][s]
    }
    function usernameOk() {
        return /^[a-z_][a-z0-9_]*$/.test(username) && username.length >= 2
    }
    function validate() {
        var rootOk = !separateRoot || (rootPass1.length >= 4 && rootPass1 === rootPass2)
        return usernameOk() && pass1.length >= 4 && pass1 === pass2 &&
               hostname.length > 0 && rootOk
    }

    function applyAll() {
        installer.settings["USERNAME"] = username
        installer.settings["FULLNAME"] = fullname === "" ? username : fullname
        installer.settings["USERPASS"] = pass1
        // Отдельный пароль root — только если включён и заполнен верно;
        // иначе root = пароль пользователя (поведение fixed9 сохранено).
        installer.settings["ROOTPASS"] =
            (separateRoot && rootPass1.length >= 4 && rootPass1 === rootPass2) ? rootPass1 : pass1
        installer.settings["HOSTNAME"] = hostname
        installer.settings["AUTOLOGIN"] = autologin ? "1" : "0"
    }

    Component.onCompleted: {
        username = installer.settings["USERNAME"] || ""
        fullname = installer.settings["FULLNAME"] || ""
        hostname = installer.settings["HOSTNAME"] || "xros-os"
        autologin = installer.settings["AUTOLOGIN"] === "1"
    }

    ColumnLayout {
        anchors { fill: parent; margins: 40 }
        spacing: 14

        Text {
            text: installer.uiLang === "en" ? "User and password" : "Пользователь и пароль"
            color: Theme.text; font { pixelSize: 26; bold: true }
        }
        Text {
            text: installer.uiLang === "en"
                  ? "Create the main user of the system. By default the same password is used for administrator (root) tasks; you can set a separate root password below."
                  : "Создайте основного пользователя системы. По умолчанию этот же пароль используется для задач администратора (root); при желании задайте отдельный пароль root ниже."
            color: Theme.textSecondary; font.pixelSize: 15; wrapMode: Text.WordWrap
            Layout.maximumWidth: 700
        }

        GridLayout {
            columns: 2
            columnSpacing: 24
            rowSpacing: 14
            Layout.fillWidth: true

            // Имя пользователя.
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Username" : "Имя пользователя"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    text: username
                    placeholderText: "mia"
                    font.pixelSize: 15; color: Theme.text
                    placeholderTextColor: Theme.textSecondary
                    onTextChanged: { username = text.toLowerCase().replace(/[^a-z0-9_]/g, ""); applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : (username !== "" && !usernameOk() ? Theme.danger : Theme.border); width: 1 }
                    }
                }
                Text {
                    text: username !== "" && !usernameOk()
                          ? (installer.uiLang === "en" ? "Only lowercase latin letters, digits and _" : "Только латиница в нижнем регистре, цифры и _")
                          : " "
                    color: Theme.danger; font.pixelSize: 12
                }
            }
            // Полное имя.
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Full name" : "Полное имя"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    text: fullname
                    placeholderText: "Mia"
                    font.pixelSize: 15; color: Theme.text
                    placeholderTextColor: Theme.textSecondary
                    onTextChanged: { fullname = text; applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : Theme.border; width: 1 }
                    }
                }
                Text { text: " "; color: Theme.danger; font.pixelSize: 12 }
            }
            // Имя компьютера.
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Computer name" : "Имя компьютера"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    text: hostname
                    font.pixelSize: 15; color: Theme.text
                    onTextChanged: { hostname = text.replace(/[^a-zA-Z0-9.-]/g, ""); applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : Theme.border; width: 1 }
                    }
                }
                Text { text: " "; color: Theme.danger; font.pixelSize: 12 }
            }
            // Автовход.
            ColumnLayout {
                spacing: 6
                Text { text: " "; color: Theme.text; font.pixelSize: 14 }
                CheckBox {
                    checked: autologin
                    text: installer.uiLang === "en" ? "Log in automatically" : "Входить автоматически"
                    onCheckedChanged: { autologin = checked; applyAll() }
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
                        Text { anchors.centerIn: parent; text: parent.parent.checked ? "✓" : ""; color: Theme.text; font.pixelSize: 13 }
                    }
                }
                Text { text: " "; color: Theme.danger; font.pixelSize: 12 }
            }
            // Пароль.
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Password" : "Пароль"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    id: passField1
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    echoMode: showPass ? TextInput.Normal : TextInput.Password
                    font.pixelSize: 15; color: Theme.text
                    onTextChanged: { pass1 = text; applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : Theme.border; width: 1 }
                    }
                }
                // Индикатор силы пароля.
                RowLayout {
                    spacing: 4
                    Repeater {
                        model: 5
                        Rectangle {
                            width: 60; height: 6; radius: 3
                            color: index < passStrength(pass1) ? Theme.accent : Theme.border
                        }
                    }
                    Text {
                        text: pass1 === "" ? " " : strengthText(passStrength(pass1))
                        color: Theme.textSecondary; font.pixelSize: 12
                    }
                }
            }
            // Подтверждение пароля.
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Confirm password" : "Подтвердите пароль"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    echoMode: showPass ? TextInput.Normal : TextInput.Password
                    font.pixelSize: 15; color: Theme.text
                    onTextChanged: { pass2 = text; applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : (pass2 !== "" && pass1 !== pass2 ? Theme.danger : Theme.border); width: 1 }
                    }
                }
                Text {
                    text: pass2 !== "" && pass1 !== pass2
                          ? (installer.uiLang === "en" ? "Passwords do not match" : "Пароли не совпадают")
                          : " "
                    color: Theme.danger; font.pixelSize: 12
                }
            }
        }

        // Отдельный пароль root (fixed10, D11) — необязательно.
        CheckBox {
            checked: separateRoot
            text: installer.uiLang === "en" ? "Set a separate root password" : "Задать отдельный пароль администратора (root)"
            onCheckedChanged: { separateRoot = checked; rootPass1 = ""; rootPass2 = ""; applyAll() }
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
                Text { anchors.centerIn: parent; text: parent.parent.checked ? "✓" : ""; color: Theme.text; font.pixelSize: 13 }
            }
        }
        GridLayout {
            columns: 2
            columnSpacing: 24
            rowSpacing: 14
            visible: separateRoot
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Root password" : "Пароль root"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    echoMode: showPass ? TextInput.Normal : TextInput.Password
                    font.pixelSize: 15; color: Theme.text
                    onTextChanged: { rootPass1 = text; applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : Theme.border; width: 1 }
                    }
                }
                Text { text: " "; color: Theme.danger; font.pixelSize: 12 }
            }
            ColumnLayout {
                spacing: 6
                Text { text: installer.uiLang === "en" ? "Confirm root password" : "Подтвердите пароль root"; color: Theme.text; font.pixelSize: 14 }
                TextField {
                    Layout.preferredWidth: 340; Layout.preferredHeight: 44
                    echoMode: showPass ? TextInput.Normal : TextInput.Password
                    font.pixelSize: 15; color: Theme.text
                    onTextChanged: { rootPass2 = text; applyAll() }
                    background: Rectangle {
                        radius: Theme.radiusSmall; color: Theme.card
                        border { color: parent.activeFocus ? Theme.accent : (rootPass2 !== "" && rootPass1 !== rootPass2 ? Theme.danger : Theme.border); width: 1 }
                    }
                }
                Text {
                    text: rootPass2 !== "" && rootPass1 !== rootPass2
                          ? (installer.uiLang === "en" ? "Passwords do not match" : "Пароли не совпадают")
                          : " "
                    color: Theme.danger; font.pixelSize: 12
                }
            }
        }

        CheckBox {
            checked: showPass
            text: installer.uiLang === "en" ? "Show password" : "Показать пароль"
            onCheckedChanged: showPass = checked
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
                Text { anchors.centerIn: parent; text: parent.parent.checked ? "✓" : ""; color: Theme.text; font.pixelSize: 13 }
            }
        }
        Item { Layout.fillHeight: true }
    }
}
