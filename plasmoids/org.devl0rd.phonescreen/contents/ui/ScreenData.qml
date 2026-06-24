/*
 * Phone Screen :: status reader.
 *
 * Reads two tmpfs snapshots in-process via XMLHttpRequest (file://), exactly like
 * the sibling widgets (needs QML_XHR_ALLOW_FILE_READ=1, set by install.sh):
 *   • phonecam.json     — written by the daemon: device list + connection state
 *   • phonescreen.json  — written by the daemon: pinned-mirror status/owner/lock
 *
 * No process is spawned per poll; control actions (claim/lock/unlock) go through
 * phonescreenctl separately.
 */
import QtQuick
import org.kde.plasma.plasma5support as P5Support

Item {
    id: root

    property bool ready: false
    property var devices: []
    property string activeSerial: ""
    property string activeName: ""
    property string error: ""
    // pinned-mirror state, written by the daemon:
    //   status: "connected" | "connecting" | "offline" | "external" | "off"
    property string status: "off"
    property bool running: false      // our pinned scrcpy is actually up
    property bool locked: false       // the phone is locked (mirror hidden while so)
    property string owner: ""         // which claim currently has the mirror (desktop/popup/…)
    signal updated()

    property string dir: ""

    // derive the active device's reachability/transport from the device list
    readonly property var activeDev: {
        var devs = devices || []
        for (var i = 0; i < devs.length; i++)
            if (devs[i].serial === activeSerial) return devs[i]
        // no explicit active serial yet: fall back to the first (daemon's auto pick)
        return devs.length ? devs[0] : null
    }
    readonly property bool onUsb: activeDev ? activeDev.usb === true : false
    readonly property bool hasWifi: activeDev ? (activeDev.last_ip || "") !== "" : false
    readonly property bool reachable: onUsb || hasWifi
    readonly property string transport: onUsb ? "usb" : (hasWifi ? "wifi" : "")

    P5Support.DataSource {
        id: pathHelper
        engine: "executable"
        onNewData: function(source, d) {
            root.dir = (d.stdout || "").trim()
            disconnectSource(source)
            root.read()
        }
    }

    function _get(file, cb) {
        if (!root.dir) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.dir + "/" + file)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            cb(xhr.responseText)
        }
        xhr.send()
    }

    function read() {
        _get("phonecam.json", function(txt) {
            if (!txt) { root.ready = false; root.updated(); return }
            try {
                var p = JSON.parse(txt)
                root.devices = p.devices || []
                root.activeSerial = p.active_serial || ""
                root.activeName = p.active_name || ""
                root.error = p.error || ""
                root.ready = true
            } catch (e) {}
            root.updated()
        })
        _get("phonescreen.json", function(txt) {
            if (!txt) { root.status = "off"; root.running = false; return }
            try {
                var p = JSON.parse(txt)
                root.status = p.status || "off"
                root.running = p.running === true
                root.locked = p.locked === true
                root.owner = p.owner || ""
            } catch (e) {}
        })
    }

    // Event-driven via FileWatcher (no polling): re-read whenever the daemon rewrites
    // either snapshot it depends on.
    FileWatcher { path: root.dir ? root.dir + "/phonecam.json" : ""; onChanged: root.read() }
    FileWatcher { path: root.dir ? root.dir + "/phonescreen.json" : ""; onChanged: root.read() }

    Component.onCompleted: pathHelper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon\"")
}
