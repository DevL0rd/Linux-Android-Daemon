/*
 * Reads the daemon's pinned-mirror status (phonescreen.json) in-process via XHR,
 * so the Phone tab can show connect / locked / paused state — same mechanism as
 * the rest of the widgets (needs QML_XHR_ALLOW_FILE_READ=1, set by install.sh).
 *
 * Event-driven via FileWatcher (no polling): re-reads the instant the daemon
 * rewrites the file, so a status/size change reaches the widget immediately.
 */
import QtQuick
import org.kde.plasma.plasma5support as P5Support

Item {
    id: root

    property string status: "off"        // connected | connecting | offline | external | fullscreen | off
    property bool running: false
    property bool locked: false
    property string link: ""             // ACTUAL connection: "usb" | "wifi" | "" (none)
    property int phoneW: 9               // phone display size (so the popup can size to it)
    property int phoneH: 19

    property string cachePath: ""

    P5Support.DataSource {
        id: helper
        engine: "executable"
        onNewData: function(source, d) { root.cachePath = (d.stdout || "").trim(); disconnectSource(source); root.read() }
    }

    function read() {
        if (!root.cachePath) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (!xhr.responseText) { root.status = "off"; root.running = false; root.locked = false; root.link = ""; return }
            try {
                var p = JSON.parse(xhr.responseText)
                root.status = p.status || "off"
                root.running = p.running === true
                root.locked = p.locked === true
                root.link = p.link || ""
                if (p.width > 0 && p.height > 0) { root.phoneW = p.width; root.phoneH = p.height }
            } catch (e) {}
        }
        xhr.send()
    }

    FileWatcher { path: root.cachePath; onChanged: root.read() }

    Component.onCompleted: helper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon/phonescreen.json\"")
}
