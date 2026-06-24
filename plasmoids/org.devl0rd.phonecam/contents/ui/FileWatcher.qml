/*
 * Fires changed() whenever the watched file is rewritten -- event-driven, no
 * polling. Watches the parent directory (not the file) so it survives the
 * collector's atomic os.replace(tmp, file), which swaps the inode -- a direct file
 * watch goes deaf after the first replace. mtime+size identify a real change.
 */
import QtQuick
import Qt.labs.folderlistmodel

Item {
    id: w
    property string path: ""               // absolute path of the file to watch
    signal changed()

    readonly property string _dir: path.substring(0, path.lastIndexOf("/"))
    readonly property string _name: path.substring(path.lastIndexOf("/") + 1)
    property string _stamp: ""

    FolderListModel {
        id: fm
        folder: w._dir ? "file://" + w._dir : ""
        nameFilters: w._name ? [w._name] : []
        showDirs: false
        sortField: FolderListModel.Unsorted
    }
    function _check() {
        if (fm.count <= 0) return
        var d = fm.get(0, "fileModified")
        var stamp = (d ? d.getTime() : 0) + ":" + fm.get(0, "fileSize")
        if (stamp !== w._stamp) { w._stamp = stamp; w.changed() }
    }
    Connections {
        target: fm
        function onDataChanged() { w._check() }
        function onCountChanged() { w._check() }
        function onRowsInserted() { w._check() }
        function onModelReset() { w._check() }
    }
}
