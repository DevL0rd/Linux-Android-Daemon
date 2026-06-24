/*
 * Phone Screen — a desktop widget that keeps the REAL scrcpy mirror pinned over
 * itself, always connected and ready.
 *
 * It is not a frame feed: phonescreenctl runs the actual interactive scrcpy (touch
 * + control) and a scoped KWin rule forces it borderless/kept-below to this
 * widget's screen area. The widget ALWAYS claims the mirror (no on/off toggle):
 *   • pins it whenever the phone is reachable (auto USB/Wi-Fi),
 *   • keeps retrying while it is not (showing "waiting"),
 *   • starts it HIDDEN + locked if the phone is locked — it never auto-unlocks;
 *     double-click (or the lock button) unlocks it,
 *   • steps aside if scrcpy is opened elsewhere (popped-out window, other widget,
 *     desktop shortcut) — and brings the pinned mirror back when that closes.
 * The pop-out button tears the pinned mirror down and hands you a movable window.
 *
 * Lives directly on the desktop (full representation only — no panel popup).
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    readonly property string ctlBin: "$HOME/.local/bin/phonescreenctl"
    readonly property color accent: Plasmoid.configuration.accentColor !== ""
        ? Plasmoid.configuration.accentColor : Kirigami.Theme.highlightColor
    readonly property string serial: (Plasmoid.configuration.deviceSerial || "").trim()
    // "hide" keeps scrcpy running + connected but forces the window hidden (private)
    readonly property bool forceHide: Plasmoid.configuration.hide
    onForceHideChanged: claimMirror()
    // does THIS widget currently hold the mirror, or has the popup taken it?
    readonly property bool mirrorMine: feed.owner === "" || feed.owner === "desktop"

    // optimistic lock state: flips instantly on click, then the real detected
    // state (feed.locked) takes over once it agrees (or after a timeout).
    property var pendingLock: null
    readonly property bool displayLocked: pendingLock !== null ? pendingLock : feed.locked
    Connections {
        target: feed
        function onLockedChanged() {
            if (root.pendingLock !== null && feed.locked === root.pendingLock)
                root.pendingLock = null
        }
    }
    Timer { id: pendingClear; interval: 10000; onTriggered: root.pendingLock = null }

    Plasmoid.title: i18n("Phone Screen")
    Plasmoid.icon: "smartphone"
    preferredRepresentation: fullRepresentation

    ScreenData { id: feed }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function ctl(args) { runner.connectSource(root.ctlBin + " " + args) }

    // ---- pin geometry: the global rect of the screen area + the config nudge ----
    property var _pinTarget: null
    function screenRect() {
        var p = _pinTarget.mapToGlobal(0, 0)
        return {
            x: Math.round(p.x) + Plasmoid.configuration.offsetX,
            y: Math.round(p.y) + Plasmoid.configuration.offsetY,
            w: Math.round(_pinTarget.width),
            h: Math.round(_pinTarget.height)
        }
    }

    // Claim the one shared mirror for this widget (priority 1, kept below). The
    // daemon points scrcpy at the highest-priority live claim and moves it here —
    // heartbeated so it stays claimed and follows the widget if it's dragged.
    function claimMirror() {
        if (!_pinTarget) return
        var r = screenRect()
        var a = "claim desktop 1 " + r.x + " " + r.y + " " + r.w + " " + r.h
        if (root.serial !== "") a += " " + root.serial
        a += " --above " + (Plasmoid.configuration.keepBelow ? 0 : 1)
        a += " --borderless " + (Plasmoid.configuration.borderless ? 1 : 0)
        a += " --min " + (root.forceHide ? 1 : 0)
        var extra = (Plasmoid.configuration.extraArgs || "").replace(/'/g, "").trim()
        if (extra !== "") a += " --extra '" + extra + "'"
        ctl(a)
    }
    function popOut() { ctl("window" + (root.serial !== "" ? " " + root.serial : "")) }
    function lockPhone() { ctl("lock" + (root.serial !== "" ? " " + root.serial : "")) }
    function unlockPhone() { ctl("unlock" + (root.serial !== "" ? " " + root.serial : "")) }
    function toggleLock() {
        if (root.displayLocked) { root.pendingLock = false; pendingClear.restart(); unlockPhone() }
        else { root.pendingLock = true; pendingClear.restart(); lockPhone() }
    }
    function volUp()   { ctl("volume up"   + (root.serial !== "" ? " " + root.serial : "")) }
    function volDown() { ctl("volume down" + (root.serial !== "" ? " " + root.serial : "")) }
    function navKey(w) { ctl("nav " + w    + (root.serial !== "" ? " " + root.serial : "")) }

    // always heartbeat the claim (follows the widget if it's moved); the daemon keeps
    // scrcpy alive + connected and shows/hides it per the real lock state.
    Timer {
        interval: 1000; repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.claimMirror()
    }

    // ===================== desktop widget =================================
    fullRepresentation: Item {
        id: rep
        Layout.minimumWidth: Kirigami.Units.gridUnit * 11
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        implicitWidth: Kirigami.Units.gridUnit * 15
        implicitHeight: Kirigami.Units.gridUnit * 27

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            // ---------------- top bar ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "smartphone"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 0
                    PlasmaComponents.Label {
                        text: feed.activeName || (feed.ready ? i18n("No phone found") : i18n("Daemon not running"))
                        font.weight: Font.Bold; elide: Text.ElideRight; Layout.fillWidth: true
                    }
                    PlasmaComponents.Label {
                        text: !feed.reachable ? i18n("Offline")
                            : feed.transport === "usb" ? i18n("USB")
                            : feed.transport === "wifi" ? i18n("Wi-Fi") : i18n("Ready")
                        font: Kirigami.Theme.smallFont; opacity: 0.7
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
                // volume controls
                PlasmaComponents.ToolButton {
                    icon.name: "audio-volume-low"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: feed.ready && feed.reachable
                    onClicked: root.volDown()
                    QQC2.ToolTip.text: i18n("Volume down")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
                PlasmaComponents.ToolButton {
                    icon.name: "audio-volume-high"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: feed.ready && feed.reachable
                    onClicked: root.volUp()
                    QQC2.ToolTip.text: i18n("Volume up")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
                // single lock/unlock toggle — its state reflects the REAL phone lock
                // state (which the supervisor detects), not whatever was last pressed.
                PlasmaComponents.ToolButton {
                    icon.name: root.displayLocked ? "object-locked" : "object-unlocked"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: feed.ready && feed.reachable
                    onClicked: root.toggleLock()
                    QQC2.ToolTip.text: root.displayLocked ? i18n("Unlock phone") : i18n("Lock phone")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
                // pop out into a movable window
                PlasmaComponents.ToolButton {
                    icon.name: "window-new"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: feed.ready && feed.reachable && feed.status !== "external"
                    onClicked: root.popOut()
                    QQC2.ToolTip.text: i18n("Open as a movable window")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
                // hide: keep scrcpy running + connected, but force the window hidden
                PlasmaComponents.ToolButton {
                    icon.name: root.forceHide ? "view-hidden" : "view-visible"
                    display: QQC2.AbstractButton.IconOnly
                    checkable: true
                    checked: root.forceHide
                    onToggled: Plasmoid.configuration.hide = checked
                    QQC2.ToolTip.text: root.forceHide ? i18n("Show the mirror")
                                                      : i18n("Hide the mirror (keeps it running, for privacy)")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
            }

            // ---------------- screen area (scrcpy pins over this) ----------------
            Rectangle {
                id: screenArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Kirigami.Units.smallSpacing * 1.5
                // translucent themed panel, matching the System Monitor cards
                color: Qt.alpha(Kirigami.Theme.textColor, 0.04)
                border.width: 1
                border.color: Qt.alpha(Kirigami.Theme.textColor, 0.06)

                Component.onCompleted: { root._pinTarget = screenArea; root.claimMirror() }
                // re-pin instantly when the widget is resized, not on the next heartbeat
                onWidthChanged: root.claimMirror()
                onHeightChanged: root.claimMirror()

                // while locked the mirror is hidden and this panel shows — double
                // click it to unlock (only active then, so it never eats normal clicks)
                MouseArea {
                    anchors.fill: parent
                    enabled: root.displayLocked
                    acceptedButtons: Qt.LeftButton
                    onDoubleClicked: root.toggleLock()
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.BusyIndicator {
                        running: root.mirrorMine && feed.status === "connecting"
                        visible: running
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Kirigami.Icon {
                        visible: !(root.mirrorMine && feed.status === "connecting")
                        source: !feed.ready ? "dialog-error"
                              : !root.mirrorMine ? "window-duplicate"
                              : root.forceHide ? "view-hidden"
                              : feed.status === "external" ? "window"
                              : feed.status === "fullscreen" ? "view-fullscreen"
                              : feed.status === "offline" ? "network-disconnect"
                              : root.displayLocked ? "object-locked"
                              : feed.status === "connected" ? "video-display"
                              : "smartphone"
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: Kirigami.Units.iconSizes.large
                        Layout.preferredHeight: Kirigami.Units.iconSizes.large
                        opacity: 0.5
                    }
                    PlasmaComponents.Label {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.maximumWidth: screenArea.width - Kirigami.Units.largeSpacing * 2
                        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        color: Kirigami.Theme.textColor; opacity: 0.8; font: Kirigami.Theme.smallFont
                        text: !feed.ready ? i18n("Daemon not running")
                            : !root.mirrorMine ? i18n("In use in the dropdown menu")
                            : root.forceHide ? i18n("Hidden — still running, click the eye to show")
                            : feed.status === "external" ? i18n("In use in a separate window — widget paused")
                            : feed.status === "fullscreen" ? i18n("Paused — a fullscreen app is in focus")
                            : feed.status === "offline" ? i18n("Phone not connected\nPlug in USB or connect over Wi-Fi")
                            : root.displayLocked ? i18n("Phone is locked\nDouble-click to unlock")
                            : feed.status === "connected" ? i18n("Live mirror pinned here")
                            : i18n("Connecting…")
                    }
                }
            }

            // ---------------- Android nav bar (back / home / recents) ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                enabled: feed.ready && feed.reachable
                PlasmaComponents.ToolButton {
                    Layout.fillWidth: true
                    icon.name: "draw-arrow-back"
                    onClicked: root.navKey("back")
                    QQC2.ToolTip.text: i18n("Back"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                }
                PlasmaComponents.ToolButton {
                    Layout.fillWidth: true
                    icon.name: "go-home"
                    onClicked: root.navKey("home")
                    QQC2.ToolTip.text: i18n("Home"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                }
                PlasmaComponents.ToolButton {
                    Layout.fillWidth: true
                    icon.name: "window-duplicate"
                    onClicked: root.navKey("recents")
                    QQC2.ToolTip.text: i18n("Recent apps"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                }
            }
        }
    }
}
