pragma Singleton
import QtQuick

// XrOS 1.0 Diamond — утверждённая палитра системы.
// Никаких других акцентов: только эти цвета.
QtObject {
    property color bg: "#08080D"          // фон
    property color bgAlt: "#111018"       // дополнительный фон
    property color card: "#14121C"        // карточки (производный от bgAlt)
    property color accent: "#8B00FF"      // акцент, фиолетовый неон
    property color accent2: "#B66AFF"     // второй акцент
    property color accentSoft: "#2A1245"  // мягкая подложка акцента
    property color text: "#F5F3FA"        // основной текст
    property color textSecondary: "#A6A0B3" // вторичный текст
    property color border: "#30283B"      // границы
    property color borderLight: "#453A55" // светлая граница (hover)
    property color danger: "#E5484D"      // ошибки (сдержанный красный)
    property color warning: "#E8A33D"     // предупреждения
    property color success: "#8B00FF"     // успех — фиолетовый, как акцент

    property int radius: 14               // скругление карточек
    property int radiusSmall: 10
    property int sidebarWidth: 300
    property int bottomBarHeight: 76
}
