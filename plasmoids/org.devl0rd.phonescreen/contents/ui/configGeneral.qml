import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrols as KQuickControls

Kirigami.FormLayout {
    property alias cfg_deviceSerial: serialField.text
    property alias cfg_keepBelow: belowCheck.checked
    property alias cfg_borderless: borderlessCheck.checked
    property alias cfg_offsetX: offXSpin.value
    property alias cfg_offsetY: offYSpin.value
    property alias cfg_extraArgs: extraField.text
    property alias cfg_accentColor: accent.text
    property alias cfg_pollInterval: pollSpin.value

    RowLayout {
        Kirigami.FormData.label: i18n("Phone (serial):")
        QQC2.TextField {
            id: serialField
            Layout.fillWidth: true
            placeholderText: i18n("blank = daemon's active phone")
        }
    }

    Item { Kirigami.FormData.isSection: true }

    QQC2.CheckBox {
        id: belowCheck
        Kirigami.FormData.label: i18n("Pinned window:")
        text: i18n("Keep below other windows (desktop element)")
    }
    QQC2.CheckBox { id: borderlessCheck; text: i18n("Borderless") }

    Item { Kirigami.FormData.isSection: true }

    RowLayout {
        Kirigami.FormData.label: i18n("Position nudge:")
        QQC2.SpinBox { id: offXSpin; from: -2000; to: 2000; stepSize: 1 }
        QQC2.Label { text: i18n("x"); opacity: 0.6 }
        QQC2.SpinBox { id: offYSpin; from: -2000; to: 2000; stepSize: 1 }
        QQC2.Label { text: i18n("y (px)"); opacity: 0.6 }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Status poll:")
        QQC2.SpinBox { id: pollSpin; from: 500; to: 10000; stepSize: 250 }
        QQC2.Label { text: i18n("ms"); opacity: 0.6 }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Extra scrcpy args:")
        QQC2.TextField {
            id: extraField
            Layout.fillWidth: true
            placeholderText: i18n("e.g. --max-fps=30 --video-bit-rate=8M")
        }
    }

    Item { Kirigami.FormData.isSection: true }

    RowLayout {
        Kirigami.FormData.label: i18n("Accent colour:")
        QQC2.CheckBox {
            id: useAccent; text: i18n("Custom")
            checked: accent.text !== ""
            onToggled: if (!checked) accent.text = ""
        }
        KQuickControls.ColorButton {
            enabled: useAccent.checked
            color: accent.text !== "" ? accent.text : Kirigami.Theme.highlightColor
            onColorChanged: if (useAccent.checked) accent.text = color
        }
        QQC2.Label { id: accent; visible: false; text: "" }
    }

    QQC2.Label {
        Kirigami.FormData.label: i18n("Note:")
        text: i18n("The mirror is the real scrcpy window pinned over this widget — touch and control work. USB/Wi-Fi is auto-selected by the daemon.")
        opacity: 0.6; wrapMode: Text.Wrap
        Layout.maximumWidth: Kirigami.Units.gridUnit * 20
    }
}
