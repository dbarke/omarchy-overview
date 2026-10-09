import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

// Last known picture of every window, for the overview.
//
// Hyprland only captures windows that are drawn or on a hidden workspace, so
// a window scrolled off-screen on a visible workspace has no live picture.
// Whenever a window gets focus it is on screen, so this takes a snapshot of it
// then, and again every half minute while it keeps focus. Captures run in a
// hidden 1x1 surface and copy only the window itself, never what is on top of
// it. Snapshots stay in memory.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property var thumbs: ({})         // "0x..." address -> grab result
  property bool paused: false       // the overview is open and refreshes them itself
  property var target: null         // HyprlandToplevel being captured
  property bool busy: false

  function keep(address, result) {
    var next = {}
    for (var k in root.thumbs) next[k] = root.thumbs[k]
    next[address] = result
    root.thumbs = next
  }

  // Forget windows that are gone.
  function prune(addresses) {
    var next = {}
    for (var i = 0; i < addresses.length; i++)
      if (root.thumbs[addresses[i]]) next[addresses[i]] = root.thumbs[addresses[i]]
    root.thumbs = next
  }

  function snapActive() {
    var t = Hyprland.activeToplevel
    if (root.paused || root.busy || !t || !t.wayland) return
    root.target = t
    root.busy = true
    giveUp.restart()
  }

  function finish() {
    giveUp.stop()
    root.busy = false
    root.target = null
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { settle.restart() }
  }

  // Let the scrolling layout bring the window into view first.
  Timer { id: settle; interval: 700; onTriggered: root.snapActive() }
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.snapActive() }
  Timer { id: giveUp; interval: 2000; onTriggered: root.finish() }

  PanelWindow {
    anchors { top: true; left: true }
    implicitWidth: 1
    implicitHeight: 1
    color: "transparent"
    mask: Region {}
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "dbarke-overview-snap"
    WlrLayershell.layer: WlrLayer.Background

    ScreencopyView {
      id: view
      readonly property string address: root.target ? "0x" + root.target.address : ""
      width: 640
      height: sourceSize.width > 0 ? Math.round(640 * sourceSize.height / sourceSize.width) : 360
      live: false
      captureSource: root.busy && root.target ? root.target.wayland : null
      onHasContentChanged: {
        if (!hasContent || !root.busy) return
        var addr = address
        Qt.callLater(function() {
          view.grabToImage(function(result) {
            root.keep(addr, result)
            root.finish()
          }, Qt.size(view.width, view.height))
        })
      }
    }
  }
}
