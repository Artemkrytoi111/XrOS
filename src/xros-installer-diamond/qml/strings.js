// Строки интерфейса XrOS 1.0 Diamond: русский и English.
// Язык интерфейса переключается на экране приветствия и действует
// на весь установщик (боковая панель, кнопки, заголовки экранов).
.pragma library

var strings = {
    "ru": {
        "appName": "XrOS 1.0 Diamond",
        "slogan": "Современная. Быстрая. Удобная.",
        "back": "Назад",
        "next": "Далее",
        "startInstall": "Начать установку",
        "install": "Установить",
        "cancel": "Отмена",
        "finish": "Завершить",
        "close": "Закрыть",
        "stepWelcome": "Приветствие",
        "stepRegion": "Регион и время",
        "stepKeyboard": "Раскладка клавиатуры",
        "stepDisk": "Разметка диска",
        "stepUser": "Пользователь",
        "stepSummary": "Итоговая проверка",
        "stepInstall": "Установка",
        "stepFinish": "Завершение",
        "cancelTitle": "Отменить установку?",
        "cancelText": "Установщик будет закрыт. Система останется в Live-режиме, ничего не будет изменено.",
        "cancelYes": "Да, отменить",
        "cancelNo": "Продолжить установку",
        "language": "Язык интерфейса"
    },
    "en": {
        "appName": "XrOS 1.0 Diamond",
        "slogan": "Modern. Fast. Convenient.",
        "back": "Back",
        "next": "Next",
        "startInstall": "Start installation",
        "install": "Install",
        "cancel": "Cancel",
        "finish": "Finish",
        "close": "Close",
        "stepWelcome": "Welcome",
        "stepRegion": "Region and time",
        "stepKeyboard": "Keyboard layout",
        "stepDisk": "Disk partitioning",
        "stepUser": "User",
        "stepSummary": "Summary",
        "stepInstall": "Installation",
        "stepFinish": "Finish",
        "cancelTitle": "Cancel installation?",
        "cancelText": "The installer will be closed. The system will stay in Live mode, nothing will be changed.",
        "cancelYes": "Yes, cancel",
        "cancelNo": "Continue installation",
        "language": "Interface language"
    }
};

function t(lang, key) {
    var table = strings[lang] || strings["ru"];
    return table[key] !== undefined ? table[key] : (strings["ru"][key] || key);
}
