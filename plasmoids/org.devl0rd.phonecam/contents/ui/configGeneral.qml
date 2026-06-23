import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_accentColor: accentField.text
    property alias cfg_pollInterval: pollSpin.value
    property alias cfg_maxZoom: zoomSpin.value

    RowLayout {
        Kirigami.FormData.label: i18n("Accent color:")
        QQC2.TextField { id: accentField; placeholderText: i18n("#3daee9 (blank = theme)") }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Status poll:")
        QQC2.SpinBox { id: pollSpin; from: 250; to: 5000; stepSize: 250 }
        QQC2.Label { text: i18n("ms"); opacity: 0.6 }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Max zoom (slider):")
        QQC2.SpinBox { id: zoomSpin; from: 2; to: 30 }
        QQC2.Label { text: i18n("×"); opacity: 0.6 }
    }
}
