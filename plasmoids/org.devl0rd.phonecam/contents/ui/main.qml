/*
 * Phone Manager — system-tray control for an Android phone.
 *
 *   • View Phone : launch the scrcpy screen mirror.
 *   • Webcam     : collapsible — live preview + every scrcpy camera option.
 *   • Settings   : collapsible — the per-device daemon settings (so config.json
 *     never needs editing by hand).
 *
 * The whole popup is in a ScrollView so it can never clip; the collapsible
 * sections keep it compact until you open one. Each control initialises from
 * the daemon's saved values when its section opens (the Loader recreates the
 * content), then the user drives it — no timer re-reads, so nothing fights the
 * user's input.
 */
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    readonly property string ctlBin: "$HOME/.local/bin/phonecamctl"
    readonly property color accent: Plasmoid.configuration.accentColor !== ""
        ? Plasmoid.configuration.accentColor : Kirigami.Theme.highlightColor
    readonly property real maxZoom: Plasmoid.configuration.maxZoom

    // Screen height read HERE (the panel applet is always on a screen) — the popup's
    // own Screen.height is 0 until it's placed, which mis-sized everything.
    readonly property int screenH: Screen.height > 0 ? Screen.height : 1080

    // Phone-area height (px). Seeded from config; the drag handle writes it live and
    // commits it back to config on release so the size is remembered.
    property int phoneH: Plasmoid.configuration.phoneHeight

    // Phone aspect (w/h), CACHED in config so the popup is the right size the moment
    // it opens. Updated whenever the daemon reports a real phone size.
    readonly property real phoneAspect: Plasmoid.configuration.cachedAspect > 0
        ? Plasmoid.configuration.cachedAspect : (9 / 16)
    Connections {
        target: mirror
        function onPhoneWChanged() { root._cacheAspect() }
        function onPhoneHChanged() { root._cacheAspect() }
    }
    function _cacheAspect() {
        if (mirror.phoneW > 0 && mirror.phoneH > 0) {
            var a = mirror.phoneW / mirror.phoneH
            if (Math.abs(a - Plasmoid.configuration.cachedAspect) > 0.001)
                Plasmoid.configuration.cachedAspect = a
        }
    }

    readonly property var s: feed.settings
    readonly property bool reachable: mirror.link !== ""
    readonly property bool connecting: feed.ready && root.expanded && root.currentTab === 1 && reachable && !feed.streaming && !feed.error

    Plasmoid.title: i18n("Phone Manager")
    Plasmoid.icon: "smartphone"
    toolTipMainText: i18n("Phone Manager")
    toolTipSubText: !feed.ready ? i18n("daemon not running")
                  : feed.activeName ? i18n("%1 · %2", feed.activeName,
                        mirror.link ? mirror.link.toUpperCase() : i18n("offline"))
                  : i18n("no phone")

    preferredRepresentation: compactRepresentation

    PhoneCamData {
        id: feed
        interval: root.previewPaused ? 300 : Plasmoid.configuration.pollInterval
        onUpdated: {
            // resume the preview the moment the daemon's re-pin lands
            if (root.previewPaused && feed.pinGen !== root.pausedPinGen) {
                root.previewPaused = false
                root.syncPreviewWish()
            }
        }
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function ctl(args) { runner.connectSource(root.ctlBin + " " + args) }
    function setting(key, val) { ctl("set " + key + " " + val) }
    function optIndex(model, val) {
        for (var i = 0; i < model.length; i++)
            if (String(model[i].value) === String(val)) return i
        return 0
    }
    // per-device daemon settings (with fallback to defaults), read + write
    function devCfg() {
        var devs = feed.devices || []
        for (var i = 0; i < devs.length; i++)
            if (devs[i].serial === feed.activeSerial) return devs[i].config || ({})
        return ({})
    }
    function devVal(key, dflt) {
        var c = devCfg()
        if (c[key] !== undefined) return c[key]
        if (feed.defaults[key] !== undefined) return feed.defaults[key]
        return dflt
    }
    function devSet(key, val) { ctl("devset " + (feed.activeSerial || "auto") + " " + key + " " + val) }

    // --- live preview (a JPEG the daemon's ffmpeg writes; shown as an Image) --
    // An Image renders each JPEG at its OWN dimensions, so it can never go
    // stale/stretched on a size change, and it does no in-process video decode
    // (so it can't crash plasmashell like QtMultimedia did).
    property bool previewPaused: false   // released briefly so a size change can re-pin
    property int pausedPinGen: 0
    property string previewDir: ""
    property int previewTick: 0
    readonly property bool previewShowing: root.expanded && root.currentTab === 1 && !root.previewPaused
    // a real app (not our preview) is reading the camera → can't preview (single reader)
    readonly property bool appUsing: feed.consumers && feed.consumers.length > 0
    // camera active: our webcam feed is streaming, or some app holds the camera
    readonly property bool cameraInUse: feed.streaming || appUsing

    P5Support.DataSource {
        id: pathResolver
        engine: "executable"
        onNewData: function(source, d) { root.previewDir = (d.stdout || "").trim(); disconnectSource(source) }
    }
    Component.onCompleted: pathResolver.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon\"")

    function syncPreviewWish() {
        if (root.previewShowing) ctl("preview on")
        else ctl("preview off")
    }
    onExpandedChanged: syncPreviewWish()
    // heartbeat: keep the daemon's feed + preview ffmpeg alive while showing
    Timer {
        interval: 2000; repeat: true; running: root.previewShowing
        triggeredOnStart: true
        onTriggered: root.ctl("preview on")
    }
    // refresh the preview Image at the selected fps while it's streaming
    Timer {
        interval: Math.max(16, Math.round(1000 / (feed.settings.fps || 15)))
        repeat: true; running: root.previewShowing && feed.streaming
        onTriggered: root.previewTick++
    }
    // On a size change, release the preview so the daemon can re-pin (size only
    // moves while idle); onUpdated brings it back when pin_gen ticks.
    function applyGeom() {
        if (!root.previewShowing) return
        root.pausedPinGen = feed.pinGen
        root.previewPaused = true
        ctl("preview off")
        geomFallback.restart()
    }
    Timer {
        id: geomFallback; interval: 4000
        onTriggered: if (root.previewPaused) { root.previewPaused = false; root.syncPreviewWish() }
    }

    // ===================== phone-mirror control (shared daemon mirror) =====
    // The Phone tab pins the SAME scrcpy mirror the desktop widget uses, via a
    // priority-2 claim. Open the popup -> claim + unlock; close -> release (the
    // daemon hands the mirror back to the desktop widget, or locks + kills it).
    readonly property string psBin: "$HOME/.local/bin/phonescreenctl"
    property bool pinned: false
    property bool resizing: false
    property bool popupFocused: false   // does the dropdown window currently have focus
    property int currentTab: 0
    readonly property bool phoneTab: root.currentTab === 0
    readonly property bool mirrorWanted: root.expanded
    property var _phoneTarget: null
    property var pendingLock: null
    readonly property bool displayLocked: pendingLock !== null ? pendingLock : mirror.locked

    MirrorData { id: mirror; interval: 800 }

    P5Support.DataSource {
        id: psRunner; engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function ps(args) { psRunner.connectSource(root.psBin + " " + args) }
    function phoneSerial() { return feed.activeSerial || "" }

    function claimMirror() {
        if (!_phoneTarget || !root.mirrorWanted) return
        var p = _phoneTarget.mapToGlobal(0, 0)
        var a = "claim popup 2 " + Math.round(p.x) + " " + Math.round(p.y)
              + " " + Math.round(_phoneTarget.width) + " " + Math.round(_phoneTarget.height)
        if (phoneSerial() !== "") a += " " + phoneSerial()
        var show = root.phoneTab && !root.resizing
        a += " --above 1 --borderless 1 --min " + (show ? 0 : 1)
        ps(a)
        // Raise the mirror over the popup ONLY while the popup itself is focused.
        // kdotool's raise activates the mirror, so raising after focus has left the
        // popup makes the focus-guard's active-window probe see the mirror instead of
        // the app you actually clicked — and the menu fails to auto-close.
        if (show && root.popupFocused) ps("raise")
    }
    function releaseMirror() { ps("release popup") }
    function lockPhone()   { ps("lock"   + (phoneSerial() ? " " + phoneSerial() : "")) }
    function unlockPhone() { ps("unlock" + (phoneSerial() ? " " + phoneSerial() : "")) }
    function toggleLock() {
        if (root.displayLocked) { root.pendingLock = false; pendingClear.restart(); unlockPhone() }
        else { root.pendingLock = true; pendingClear.restart(); lockPhone() }
    }
    // any click in the menu raises the popup over the mirror — re-raise it (the pane's
    // TapHandler fires this on every press, so it snaps back instantly).
    function _raise() { if (root.phoneTab && root.mirrorWanted) ps("raise") }
    function volUp()   { ps("volume up"   + (phoneSerial() ? " " + phoneSerial() : "")) }
    function volDown() { ps("volume down" + (phoneSerial() ? " " + phoneSerial() : "")) }
    function navKey(k) { ps("nav " + k    + (phoneSerial() ? " " + phoneSerial() : "")) }
    Timer { id: pendingClear; interval: 10000; onTriggered: root.pendingLock = null }
    Connections {
        target: mirror
        function onLockedChanged() {
            if (root.pendingLock !== null && mirror.locked === root.pendingLock) root.pendingLock = null
        }
    }

    // open -> claim + auto-unlock. close -> just DROP our claim; the daemon then
    // either hands the mirror to the desktop widget (if present, no lock) or, when
    // there's no other claim, locks and closes scrcpy. We never lock here ourselves.
    onMirrorWantedChanged: {
        if (root.mirrorWanted) { claimMirror(); if (root.phoneTab) unlockPhone() }
        else { releaseMirror() }
    }
    // claim with the right min flag; the daemon minimizes (other tab/resize) or shows
    // (phone tab) the mirror. Only unlock+show when actually ON the phone tab, so
    // opening on Settings/Camera leaves the (already-minimized) mirror hidden.
    onCurrentTabChanged: {
        syncPreviewWish()
        if (!root.mirrorWanted) return
        claimMirror()
        if (root.phoneTab) unlockPhone()
    }
    Timer {
        // also the re-raise cadence: a click on the menu raises the popup over the
        // mirror, and this puts the mirror back on top. 500ms so it snaps back fast.
        interval: 500; repeat: true; running: root.mirrorWanted
        triggeredOnStart: true
        onTriggered: root.claimMirror()
    }
    // Don't let Plasma auto-close on deactivate — the pane's focusGuard decides,
    // closing only when focus left to a window that's neither the popup nor mirror.
    hideOnWindowDeactivate: false

    // option models
    readonly property var lensOptions: [
        { label: i18n("Back"), value: "back" }, { label: i18n("Front"), value: "front" },
        { label: i18n("External"), value: "external" }
    ]
    readonly property var resOptions: [
        { label: "2160p · 4K", value: "2160" }, { label: "1440p", value: "1440" },
        { label: "1080p", value: "1080" }, { label: "720p", value: "720" },
        { label: "480p", value: "480" }
    ]
    readonly property var arOptions: [
        { label: "16:9", value: "16:9" }, { label: "4:3", value: "4:3" },
        { label: "3:2", value: "3:2" }, { label: "1:1", value: "1:1" }
    ]
    readonly property var fpsOptions: [
        { label: "60", value: 60 }, { label: "30", value: 30 },
        { label: "24", value: 24 }, { label: "15", value: 15 }
    ]
    readonly property var rotOptions: [
        { label: i18n("Landscape"), value: "@0" },
        { label: i18n("Portrait (90°)"), value: "@90" },
        { label: i18n("Upside-down"), value: "@180" },
        { label: i18n("Portrait (270°)"), value: "@270" },
        { label: i18n("Mirror"), value: "flip0" }
    ]
    readonly property var modeOptions: [
        { label: i18n("Clone screen"), value: "clone" }, { label: i18n("Extended display"), value: "extended" }
    ]
    readonly property var orientOptions: [
        { label: i18n("Portrait"), value: "portrait" }, { label: i18n("Landscape"), value: "landscape" },
        { label: i18n("Auto-rotate"), value: "auto" }
    ]
    readonly property var tetherOptions: [
        { label: "RNDIS", value: "rndis" }, { label: "NCM", value: "ncm" }
    ]

    // ===================== compact (tray button) =========================
    compactRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.iconSizes.medium
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Kirigami.Icon { anchors.fill: parent; source: "smartphone"; active: mouse.containsMouse }
        // status badge: camera-in-use, Wi-Fi or USB link — red error emblem
        // when the phone is offline (none of the above) or the daemon errored.
        Rectangle {
            id: badge
            width: Math.round(parent.width * 0.5); height: width; radius: width / 2
            anchors.right: parent.right; anchors.bottom: parent.bottom
            visible: feed.ready
            color: Kirigami.Theme.backgroundColor
            Kirigami.Icon {
                anchors.fill: parent
                anchors.margins: Math.round(parent.width * 0.08)
                source: root.cameraInUse ? "camera-web"
                      : mirror.link === "wifi" ? "network-wireless"
                      : mirror.link === "usb" ? "drive-removable-media-usb"
                      : "network-disconnect"
            }
        }
        MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.expanded = !root.expanded }
    }

    // ===================== full (drop-down menu) =========================
    fullRepresentation: Item {
        id: pane
        readonly property real phoneAspect: root.phoneAspect
        // The non-phone vertical chrome (tab bar + control row + nav row + the outer
        // margins/spacings), measured from the real controls.
        // everything except the phone area: 3 control rows + the drag grip + spacings
        readonly property real chromeH: tabRow.implicitHeight + ctrlRow.implicitHeight
            + navRow.implicitHeight + Kirigami.Units.gridUnit + Kirigami.Units.smallSpacing * 7
        // Phone-area height from config (drag-resizable). WIDTH = phoneH × aspect, so
        // dragging shorter/taller changes the width in step (aspect preserved).
        readonly property real phoneH: root.phoneH
        readonly property int wantW: Math.round(phoneH * phoneAspect) + Kirigami.Units.smallSpacing * 2

        implicitWidth: wantW
        Layout.minimumWidth: wantW
        Layout.maximumWidth: wantW
        // BOTH min and max, exactly like the width — otherwise a tall tab's content
        // pushes the popup past the floor (measured: 842 wanted, 1145 actual).
        implicitHeight: phoneH + chromeH
        Layout.minimumHeight: phoneH + chromeH
        Layout.maximumHeight: phoneH + chromeH

        // Event-based close: when the popup loses focus, check WHICH window got it and
        // close only if it's neither the popup nor the mirror (so clicking the mirror
        // keeps it open, clicking another app closes it). Never closes on a failed probe.
        readonly property bool winActive: Window.active
        onWinActiveChanged: {
            root.popupFocused = winActive
            if (!winActive && root.expanded && !root.pinned) focusGuard.restart()
        }
        Component.onCompleted: root.popupFocused = Window.active
        Timer {
            id: focusGuard
            interval: 150   // let focus settle on the clicked window
            onTriggered: if (!pane.winActive && root.expanded && !root.pinned)
                             activeProbe.connectSource("kdotool getactivewindow getwindowname")
        }
        P5Support.DataSource {
            id: activeProbe
            engine: "executable"
            onNewData: function(src, d) {
                disconnectSource(src)
                if (pane.winActive || !root.expanded || root.pinned) return   // refocused / pinned
                var name = (d.stdout || "").trim()
                if (name !== "" && name.indexOf("PhoneScreenPinned") === -1)
                    root.expanded = false
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---------------- tab bar + pin ----------------
            RowLayout {
                id: tabRow
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.TabBar {
                    id: tabBar
                    Layout.fillWidth: true
                    onCurrentIndexChanged: root.currentTab = currentIndex
                    // icon-only so the tab bar stays narrow enough to let the popup
                    // shrink to a tall phone's width (no side bars)
                    QQC2.TabButton {
                        icon.name: "smartphone"; display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: i18n("Phone"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                    }
                    QQC2.TabButton {
                        icon.name: "camera-web"; display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: i18n("Camera"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                    }
                    QQC2.TabButton {
                        icon.name: "configure"; display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: i18n("Settings"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                    }
                }
                // pin = disable auto-close: when pinned the menu stays open even when
                // it loses focus; unpinned it closes once focus leaves it and the mirror.
                PlasmaComponents.ToolButton {
                    checkable: true
                    checked: root.pinned
                    icon.name: root.pinned ? "window-pin" : "window-unpin"
                    onToggled: root.pinned = checked
                    QQC2.ToolTip.text: root.pinned ? i18n("Pinned — stays open (auto-close off)")
                                                   : i18n("Auto-closes when it loses focus — click to pin open")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: tabBar.currentIndex

                // ===== Phone tab — the live mirror (same as the desktop widget) =====
                Item {
                    ColumnLayout {
                        id: phoneCol
                        anchors.fill: parent
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            id: ctrlRow
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: "smartphone"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            }
                            ColumnLayout {
                                // preferredWidth 0 so the (long) device name can't widen
                                // the whole dropdown past the phone's width
                                Layout.fillWidth: true; Layout.preferredWidth: 0; spacing: 0
                                PlasmaComponents.Label {
                                    text: feed.activeName || (feed.ready ? i18n("No phone found") : i18n("Daemon not running"))
                                    font.weight: Font.Bold; elide: Text.ElideRight; Layout.fillWidth: true
                                }
                                PlasmaComponents.Label {
                                    text: mirror.link === "usb" ? i18n("USB")
                                        : mirror.link === "wifi" ? i18n("Wi-Fi") : i18n("Offline")
                                    font: Kirigami.Theme.smallFont; opacity: 0.7
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "audio-volume-low"; display: QQC2.AbstractButton.IconOnly
                                enabled: root.reachable; onClicked: root.volDown()
                                QQC2.ToolTip.text: i18n("Volume down"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "audio-volume-high"; display: QQC2.AbstractButton.IconOnly
                                enabled: root.reachable; onClicked: root.volUp()
                                QQC2.ToolTip.text: i18n("Volume up"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: root.displayLocked ? "object-locked" : "object-unlocked"
                                display: QQC2.AbstractButton.IconOnly
                                enabled: root.reachable; onClicked: root.toggleLock()
                                QQC2.ToolTip.text: root.displayLocked ? i18n("Unlock phone") : i18n("Lock phone")
                                QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "window-new"; display: QQC2.AbstractButton.IconOnly
                                enabled: root.reachable && mirror.status !== "external"
                                onClicked: root.ps("window" + (root.phoneSerial() ? " " + root.phoneSerial() : ""))
                                QQC2.ToolTip.text: i18n("Open as a movable window")
                                QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                        }

                        Rectangle {
                            id: phoneArea
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: Kirigami.Units.smallSpacing * 1.5
                            color: Qt.alpha(Kirigami.Theme.textColor, 0.04)
                            border.width: 1; border.color: Qt.alpha(Kirigami.Theme.textColor, 0.06)
                            Component.onCompleted: { root._phoneTarget = phoneArea; root.claimMirror() }

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
                                    running: mirror.status === "connecting"; visible: running
                                    Layout.alignment: Qt.AlignHCenter
                                }
                                Kirigami.Icon {
                                    visible: mirror.status !== "connecting"
                                    source: root.resizing ? "transform-scale"
                                          : !feed.ready ? "dialog-error"
                                          : mirror.status === "external" ? "window"
                                          : mirror.status === "fullscreen" ? "view-fullscreen"
                                          : root.displayLocked ? "object-locked"
                                          : mirror.status === "connected" ? "video-display"
                                          : !root.reachable ? "network-disconnect"
                                          : "smartphone"
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.large
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.large
                                    opacity: 0.5
                                }
                                PlasmaComponents.Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.maximumWidth: phoneArea.width - Kirigami.Units.largeSpacing * 2
                                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                                    color: Kirigami.Theme.textColor; opacity: 0.8; font: Kirigami.Theme.smallFont
                                    text: root.resizing ? i18n("Resizing…")
                                        : !feed.ready ? i18n("Daemon not running")
                                        : mirror.status === "external" ? i18n("In use in a separate window")
                                        : mirror.status === "fullscreen" ? i18n("Paused — a fullscreen app is in focus")
                                        : root.displayLocked ? i18n("Phone is locked\nDouble-click to unlock")
                                        : mirror.status === "connected" ? i18n("Live")
                                        : mirror.status === "connecting" ? i18n("Connecting…")
                                        : !root.reachable ? i18n("Phone not connected — waiting…")
                                        : i18n("Connecting…")
                                }
                            }
                        }

                        RowLayout {
                            id: navRow
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            enabled: root.reachable
                            PlasmaComponents.ToolButton {
                                Layout.fillWidth: true; icon.name: "draw-arrow-back"
                                onClicked: root.navKey("back")
                                QQC2.ToolTip.text: i18n("Back"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                            PlasmaComponents.ToolButton {
                                Layout.fillWidth: true; icon.name: "go-home"
                                onClicked: root.navKey("home")
                                QQC2.ToolTip.text: i18n("Home"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                            PlasmaComponents.ToolButton {
                                Layout.fillWidth: true; icon.name: "window-duplicate"
                                onClicked: root.navKey("recents")
                                QQC2.ToolTip.text: i18n("Recent apps"); QQC2.ToolTip.visible: hovered; QQC2.ToolTip.delay: 600
                            }
                        }
                    }
                }

                // ===== Camera tab =====
                Flickable {
                    id: camFlick
                    clip: true
                    contentWidth: width; contentHeight: camCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    QQC2.ScrollBar.vertical: QQC2.ScrollBar { policy: QQC2.ScrollBar.AsNeeded }
                    ColumnLayout {
                        id: camCol; width: camFlick.width
                        // lazy: only build the camera UI when its tab is shown (so the
                        // popup opens instantly instead of loading all three tabs)
                        Loader { id: loaderCam; Layout.fillWidth: true; active: root.currentTab === 1; sourceComponent: webcamContent }
                    }
                }

                // ===== Settings tab =====
                Flickable {
                    id: setFlick
                    clip: true
                    contentWidth: width; contentHeight: setCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    QQC2.ScrollBar.vertical: QQC2.ScrollBar { policy: QQC2.ScrollBar.AsNeeded }
                    ColumnLayout {
                        id: setCol; width: setFlick.width
                        Loader { id: loaderSet; Layout.fillWidth: true; active: root.currentTab === 2; sourceComponent: settingsContent }
                    }
                }
            }

            // bottom drag grip — drag to resize the phone height (width follows aspect)
            MouseArea {
                id: dragHandle
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit
                cursorShape: Qt.SizeVerCursor
                hoverEnabled: true
                property int startH: 0
                property real startGY: 0
                onPressed: function(mouse) {
                    startH = root.phoneH
                    startGY = mapToGlobal(mouse.x, mouse.y).y
                    root.resizing = true
                    root.claimMirror()                    // park off-screen while dragging
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return   // hover must NOT resize — only an active drag
                    var dy = mapToGlobal(mouse.x, mouse.y).y - startGY
                    root.phoneH = Math.max(240, Math.min(2000, startH + dy))
                }
                onReleased: {
                    Plasmoid.configuration.phoneHeight = root.phoneH
                    root.resizing = false
                    root.claimMirror()                    // back on-screen at the new size
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: Kirigami.Units.gridUnit * 3
                    height: 4; radius: 2
                    color: Qt.alpha(Kirigami.Theme.textColor,
                                    dragHandle.pressed || dragHandle.containsMouse ? 0.6 : 0.25)
                }
            }
        }
    }

    // ===================== webcam content =================================
    Component {
        id: webcamContent
        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: width * 9 / 16
                radius: Kirigami.Units.smallSpacing * 1.5
                color: "#0a0a0a"; clip: true
                border.width: feed.streaming ? 1 : 0
                border.color: root.accent

                // double-buffered preview: load the hidden image, swap when ready
                // (no blank flash between frames)
                Item {
                    id: previewArea
                    anchors.fill: parent
                    anchors.margins: 1
                    visible: feed.streaming && !root.appUsing
                    property bool useA: true
                    Image {
                        id: imgA; anchors.fill: parent; fillMode: Image.PreserveAspectFit
                        cache: false; asynchronous: true; smooth: true
                        opacity: previewArea.useA ? 1 : 0
                        onStatusChanged: if (status === Image.Ready && !previewArea.useA) previewArea.useA = true
                    }
                    Image {
                        id: imgB; anchors.fill: parent; fillMode: Image.PreserveAspectFit
                        cache: false; asynchronous: true; smooth: true
                        opacity: previewArea.useA ? 0 : 1
                        onStatusChanged: if (status === Image.Ready && previewArea.useA) previewArea.useA = false
                    }
                    Connections {
                        target: root
                        function onPreviewTickChanged() {
                            if (root.previewDir === "") return
                            var src = "file://" + root.previewDir + "/preview.jpg?t=" + root.previewTick
                            if (previewArea.useA) imgB.source = src
                            else imgA.source = src
                        }
                    }
                }
                ColumnLayout {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.largeSpacing * 2
                    visible: !feed.streaming || root.appUsing
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.BusyIndicator {
                        running: root.connecting; visible: root.connecting
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Kirigami.Icon {
                        visible: !root.connecting
                        source: !feed.loopback ? "dialog-error"
                              : root.appUsing ? "camera-web"
                              : root.reachable ? "camera-web" : "network-disconnect"
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        opacity: 0.7
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        color: "white"; opacity: 0.85; font: Kirigami.Theme.smallFont
                        text: !feed.ready ? i18n("Daemon not running")
                            : !feed.loopback ? i18n("Loopback missing — run install.sh")
                            : root.appUsing ? i18n("In use by %1\n(preview unavailable while an app has the camera)",
                                                   feed.consumers.map(function(c){return c.name}).join(", "))
                            : root.connecting ? i18n("Connecting…")
                            : root.reachable ? i18n("Connecting preview…")
                            : i18n("Phone not reachable\nPlug in USB or connect over Wi-Fi")
                    }
                }
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true

                QQC2.ComboBox {
                    id: deviceCombo
                    Kirigami.FormData.label: i18n("Device:")
                    Layout.fillWidth: true
                    visible: count > 1
                    textRole: "label"
                    property var items: {
                        var arr = []
                        var devs = feed.devices || []
                        for (var i = 0; i < devs.length; i++)
                            arr.push({ label: devs[i].name + (devs[i].usb ? " · USB" : (devs[i].last_ip ? " · Wi-Fi" : "")),
                                       serial: devs[i].serial })
                        return arr
                    }
                    model: items
                    onActivated: function(i) { root.ctl("select " + (items[i].serial || "auto")) }
                    Component.onCompleted: {
                        var want = root.s.active_serial || ""
                        for (var i = 0; i < items.length; i++)
                            if (items[i].serial === want) { currentIndex = i; return }
                        currentIndex = 0
                    }
                }
                QQC2.ComboBox {
                    Kirigami.FormData.label: i18n("Lens:")
                    Layout.fillWidth: true
                    textRole: "label"; model: root.lensOptions
                    onActivated: function(i) { root.setting("facing", root.lensOptions[i].value); root.applyGeom() }
                    Component.onCompleted: currentIndex = root.optIndex(root.lensOptions, root.s.facing || "back")
                }
                QQC2.ComboBox {
                    Kirigami.FormData.label: i18n("Resolution:")
                    Layout.fillWidth: true
                    textRole: "label"; model: root.resOptions
                    onActivated: function(i) { root.setting("resolution", "'" + root.resOptions[i].value + "'"); root.applyGeom() }
                    Component.onCompleted: currentIndex = root.optIndex(root.resOptions, root.s.resolution || "")
                }
                QQC2.ComboBox {
                    Kirigami.FormData.label: i18n("Aspect:")
                    Layout.fillWidth: true
                    textRole: "label"; model: root.arOptions
                    onActivated: function(i) { root.setting("aspect_ratio", "'" + root.arOptions[i].value + "'"); root.applyGeom() }
                    Component.onCompleted: currentIndex = root.optIndex(root.arOptions, root.s.aspect_ratio || "16:9")
                }
                QQC2.ComboBox {
                    Kirigami.FormData.label: i18n("Frame rate:")
                    Layout.fillWidth: true
                    textRole: "label"; model: root.fpsOptions
                    onActivated: function(i) { root.setting("fps", root.fpsOptions[i].value) }
                    Component.onCompleted: currentIndex = root.optIndex(root.fpsOptions, root.s.fps || 0)
                }
                QQC2.ComboBox {
                    Kirigami.FormData.label: i18n("Rotation:")
                    Layout.fillWidth: true
                    textRole: "label"; model: root.rotOptions
                    onActivated: function(i) { root.setting("rotation", "'" + root.rotOptions[i].value + "'"); root.applyGeom() }
                    Component.onCompleted: currentIndex = root.optIndex(root.rotOptions, root.s.rotation || "@0")
                }
                RowLayout {
                    Kirigami.FormData.label: i18n("Zoom:")
                    Layout.fillWidth: true
                    QQC2.Slider {
                        id: zoomSlider
                        Layout.fillWidth: true
                        from: 1.0; to: root.maxZoom; stepSize: 0.1
                        Component.onCompleted: value = root.s.zoom || 1.0
                        onPressedChanged: if (!pressed) root.setting("zoom", value.toFixed(1))
                    }
                    PlasmaComponents.Label {
                        text: zoomSlider.value.toFixed(1) + "×"
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }
                RowLayout {
                    Kirigami.FormData.label: i18n("Torch / Hi-speed:")
                    spacing: Kirigami.Units.largeSpacing
                    QQC2.Switch {
                        id: torchSwitch; text: i18n("Torch")
                        Component.onCompleted: checked = root.s.torch === true
                        onToggled: root.setting("torch", checked ? "on" : "off")
                    }
                    QQC2.Switch {
                        id: hsSwitch; text: i18n("Hi-speed")
                        Component.onCompleted: checked = root.s.high_speed === true
                        onToggled: root.setting("high_speed", checked ? "on" : "off")
                    }
                }
            }
        }
    }

    // ===================== settings content (per-device daemon) ===========
    Component {
        id: settingsContent
        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.TextField {
                Kirigami.FormData.label: i18n("Name:")
                Layout.fillWidth: true
                Component.onCompleted: text = root.devVal("name", "")
                onEditingFinished: root.devSet("name", "'" + text + "'")
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("Manage this phone:")
                Component.onCompleted: checked = root.devVal("enabled", true) === true
                onToggled: root.devSet("enabled", checked ? "on" : "off")
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("Wireless ADB on plug:")
                Component.onCompleted: checked = root.devVal("enable_tcpip", true) === true
                onToggled: root.devSet("enable_tcpip", checked ? "on" : "off")
            }
            QQC2.SpinBox {
                Kirigami.FormData.label: i18n("Wireless ADB port:")
                from: 1024; to: 65535
                Component.onCompleted: value = root.devVal("tcpip_port", 5555)
                onValueModified: root.devSet("tcpip_port", value)
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("Auto-unlock:")
                Component.onCompleted: checked = root.devVal("unlock", true) === true
                onToggled: root.devSet("unlock", checked ? "on" : "off")
            }
            QQC2.TextField {
                Kirigami.FormData.label: i18n("Lock PIN:")
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: i18n("for auto-unlock")
                Component.onCompleted: text = root.devVal("lock_pin", "")
                onEditingFinished: root.devSet("lock_pin", "'" + text + "'")
            }
            QQC2.ComboBox {
                Kirigami.FormData.label: i18n("Mirror mode:")
                Layout.fillWidth: true
                textRole: "label"; model: root.modeOptions
                onActivated: function(i) { root.devSet("mode", root.modeOptions[i].value) }
                Component.onCompleted: currentIndex = root.optIndex(root.modeOptions, root.devVal("mode", "clone"))
            }
            QQC2.ComboBox {
                Kirigami.FormData.label: i18n("Mirror rotation:")
                Layout.fillWidth: true
                textRole: "label"; model: root.orientOptions
                onActivated: function(i) { root.devSet("orientation", root.orientOptions[i].value) }
                Component.onCompleted: currentIndex = root.optIndex(root.orientOptions, root.devVal("orientation", "portrait"))
            }
            QQC2.TextField {
                Kirigami.FormData.label: i18n("Extended launcher:")
                Layout.fillWidth: true
                placeholderText: i18n("launcher package (optional)")
                Component.onCompleted: text = root.devVal("display_launcher", "")
                onEditingFinished: root.devSet("display_launcher", "'" + text + "'")
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("Samsung DeX on external:")
                Component.onCompleted: checked = root.devVal("dex_desktop_mode", false) === true
                onToggled: root.devSet("dex_desktop_mode", checked ? "on" : "off")
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("USB tether failover:")
                Component.onCompleted: checked = root.devVal("tether_failover", false) === true
                onToggled: root.devSet("tether_failover", checked ? "on" : "off")
            }
            QQC2.ComboBox {
                Kirigami.FormData.label: i18n("Tether mode:")
                Layout.fillWidth: true
                textRole: "label"; model: root.tetherOptions
                onActivated: function(i) { root.devSet("tether_function", root.tetherOptions[i].value) }
                Component.onCompleted: currentIndex = root.optIndex(root.tetherOptions, root.devVal("tether_function", "rndis"))
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("Notifications:")
                Component.onCompleted: checked = root.devVal("notify", false) === true
                onToggled: root.devSet("notify", checked ? "on" : "off")
            }
            QQC2.Switch {
                Kirigami.FormData.label: i18n("KDE Connect notify:")
                Component.onCompleted: checked = root.devVal("kdeconnect_notify", false) === true
                onToggled: root.devSet("kdeconnect_notify", checked ? "on" : "off")
            }
            QQC2.TextField {
                Kirigami.FormData.label: i18n("Mirror scrcpy args:")
                Layout.fillWidth: true
                placeholderText: i18n("e.g. --turn-screen-off")
                Component.onCompleted: text = (root.devVal("scrcpy_args", []) || []).join(" ")
                onEditingFinished: root.devSet("scrcpy_args", "'" + text + "'")
            }
        }
    }
}
