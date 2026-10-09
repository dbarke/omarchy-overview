import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "layout.js" as Layout
import "match.js" as Match

// Mission Control-style overview: live thumbnails of every open window.
//
// Opening reads the windows and monitors from hyprctl in one go, groups the
// windows by workspace and lays them out as justified rows (layout.js) on the
// focused monitor. Windows on the workspace you are looking at zoom out from
// where they really are. Summoning again while open (Super+Tab), or Tab,
// switches between all workspaces and just this one. Typing filters on title,
// app and workspace (match.js). Enter or a click focuses the window wherever
// it is; Shift brings it to this workspace first; a middle click closes it.
//
// Hyprland only captures windows that are drawn or on a hidden workspace, so
// a window scrolled off-screen on a visible workspace has no live picture.
// For those the overview shows the last snapshot that the plugin's service
// (Snapshots.qml) took; every live thumbnail refreshes its window's snapshot.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null        // Snapshots.qml

  property bool opened: false
  property string mode: "all"       // "all" | "here"
  property string monitorName: ""
  property var monitor: null        // focused monitor from hyprctl
  property int here: 0              // active workspace id on the focused monitor
  property int special: 0           // special workspace shown on it, or 0
  property bool multiMonitor: false
  property var all: []              // every window, grouped order
  property string query: ""
  property string selectedAddress: ""

  // Opening animation: thumbnails start where their windows are and glide
  // into the grid once `shown` flips; layout changes animate the same way.
  property bool animate: false
  property bool shown: false

  readonly property var visibleWindows: {
    var list = root.all
    if (root.mode === "here")
      list = list.filter(function(w) { return w.workspaceId === root.here || (root.special && w.workspaceId === root.special) })
    if (!root.query.trim()) return list
    var hits = Match.filter(list, root.query)
    var keep = {}
    for (var i = 0; i < hits.length; i++) keep[hits[i].address] = true
    return list.filter(function(w) { return keep[w.address] })
  }

  readonly property var groups: {
    var out = [], byWs = {}
    for (var i = 0; i < root.visibleWindows.length; i++) {
      var w = root.visibleWindows[i]
      if (!byWs[w.workspaceId]) {
        byWs[w.workspaceId] = { label: w.workspaceTitle, current: w.workspaceId === root.here, items: [] }
        out.push(byWs[w.workspaceId])
      }
      byWs[w.workspaceId].items.push(w)
    }
    return out
  }

  // Windows in the order the layout places them.
  readonly property var flat: {
    var out = []
    for (var g = 0; g < root.groups.length; g++) out = out.concat(root.groups[g].items)
    return out
  }

  readonly property int selected: {
    for (var i = 0; i < root.flat.length; i++) if (root.flat[i].address === root.selectedAddress) return i
    return root.flat.length ? 0 : -1
  }

  property color foreground: Color.menu.text
  property color accent: Color.menu.selectedText
  property color background: Color.menu.background
  property string fontFamily: Style.font.menuFamily

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  onOpenedChanged: if (root.service) root.service.paused = root.opened

  onQueryChanged: {
    // Typing selects the best match.
    if (!root.query.trim()) return
    var hits = Match.filter(root.visibleWindows, root.query)
    if (hits.length) root.selectedAddress = hits[0].address
  }

  // ------------------------------------------------------------ shell hooks

  function open(payloadJson) {
    if (root.opened) {
      root.toggleMode()
      return
    }
    root.query = ""
    root.mode = "all"
    if (!probeProc.running) probeProc.running = true
  }

  function close() {
    root.opened = false
    root.shown = false
    root.animate = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "dbarke.overview")
  }

  function toggleMode() {
    var keep = root.selectedAddress
    root.mode = root.mode === "all" ? "here" : "all"
    // Keep the selection when it is still shown, else take the most recent.
    var found = root.flat.some(function(w) { return w.address === keep })
    if (!found) root.selectedAddress = root.mostRecent(root.flat, true)
  }

  // ---------------------------------------------------------------- windows

  // Edge and Chrome web apps are classed msedge-<site>__<path>-<profile>.
  function webAppSite(cls) {
    var m = /^(?:msedge|chrome|chromium|brave)-([^_]+)__/.exec(cls)
    return m ? m[1].replace(/^www\./, "") : ""
  }

  function appFor(cls) {
    var entry = cls ? DesktopEntries.heuristicLookup(cls) : null
    var site = root.webAppSite(cls)
    var name = entry && entry.name ? entry.name : (site || cls || "Window")
    var icon = entry && entry.icon ? entry.icon : cls
    var lib = root.shell ? root.shell.appLibrary : null
    var src = lib && typeof lib.iconSource === "function" ? lib.iconSource(icon) : Quickshell.iconPath(icon, true)
    return { name: name, icon: src || Quickshell.iconPath("application-x-executable", true) }
  }

  function workspaceLabel(ws) {
    var name = String((ws && ws.name) || "")
    if (name.indexOf("special:") === 0) return name.slice(8) || "special"
    return name || String(ws ? ws.id : "")
  }

  function workspaceTitle(ws, monName) {
    var label = root.workspaceLabel(ws)
    var title = /^\d+$/.test(label) ? "Workspace " + label : label.charAt(0).toUpperCase() + label.slice(1)
    return root.multiMonitor && monName ? title + "  ·  " + monName : title
  }

  // Address of the most recently used window in list, skipping the focused one
  // when asked, so opening and pressing Enter flips back like Alt+Tab.
  function mostRecent(list, skipCurrent) {
    var best = null
    for (var i = 0; i < list.length; i++) {
      var w = list[i]
      if (skipCurrent && w.focus === 0 && list.length > 1) continue
      if (!best || w.focus < best.focus) best = w
    }
    return best ? best.address : ""
  }

  function wsOrder(w) {
    // Regular workspaces by number, special ones after them.
    return w.workspaceId > 0 ? w.workspaceId : 100000 - w.workspaceId
  }

  function probed(text) {
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    if (!data) return
    var mons = data.mons || []
    var focused = null
    for (var i = 0; i < mons.length; i++) if (mons[i].focused) focused = mons[i]
    if (!focused && mons.length) focused = mons[0]
    // Name screens by where they are ("left", "right") rather than by port.
    var monNames = {}
    var byX = mons.slice().sort(function(a, b) { return a.x - b.x || a.y - b.y })
    var places = byX.length === 2 ? ["left screen", "right screen"]
      : byX.length === 3 ? ["left screen", "middle screen", "right screen"] : []
    for (var m = 0; m < byX.length; m++) monNames[byX[m].id] = places[m] || byX[m].name
    root.monitor = focused
    root.monitorName = focused ? focused.name : ""
    root.multiMonitor = mons.length > 1
    root.here = focused && focused.activeWorkspace ? focused.activeWorkspace.id : 0
    root.special = focused && focused.specialWorkspace ? focused.specialWorkspace.id : 0

    // Workspaces currently on screen somewhere, to know which windows can
    // zoom out from their real position.
    var onScreen = {}
    for (var s = 0; s < mons.length; s++) {
      if (mons[s].activeWorkspace) onScreen[mons[s].activeWorkspace.id] = mons[s]
      if (mons[s].specialWorkspace && mons[s].specialWorkspace.id) onScreen[mons[s].specialWorkspace.id] = mons[s]
    }

    var list = []
    var clients = data.clients || []
    for (var j = 0; j < clients.length; j++) {
      var c = clients[j]
      if (!c.mapped || !c.address || !c.workspace || c.workspace.id === -1) continue
      var app = root.appFor(c.class || c.initialClass)
      var size = c.size || [16, 9]
      var at = c.at || [0, 0]
      var mon = onScreen[c.workspace.id]
      list.push({
        address: c.address,
        title: c.title || c.initialTitle || app.name,
        app: app.name,
        icon: app.icon,
        workspace: root.workspaceLabel(c.workspace),
        workspaceTitle: root.workspaceTitle(c.workspace, monNames[c.monitor]),
        workspaceId: c.workspace.id,
        aspect: Math.max(0.2, Math.min(5, size[0] / Math.max(1, size[1]))),
        // Real rectangle on the focused monitor, or null when not shown there.
        origin: mon && focused && mon.id === focused.id && root.onMonitor(at, size, mon)
          ? { x: at[0] - mon.x, y: at[1] - mon.y, w: size[0], h: size[1] } : null,
        x: at[0], y: at[1],
        focus: typeof c.focusHistoryID === "number" && c.focusHistoryID >= 0 ? c.focusHistoryID : 9999
      })
    }
    list.sort(function(a, b) {
      return root.wsOrder(a) - root.wsOrder(b) || a.x - b.x || a.y - b.y
    })

    if (root.service) root.service.prune(list.map(function(w) { return w.address }))

    root.animate = false
    root.shown = false
    root.all = list
    root.selectedAddress = root.mostRecent(list, true)
    root.opened = true
    showTimer.restart()
  }

  // Whether a window is mostly on its monitor, not scrolled off to the side.
  function onMonitor(at, size, mon) {
    var w = Math.min(at[0] + size[0], mon.x + mon.width) - Math.max(at[0], mon.x)
    var h = Math.min(at[1] + size[1], mon.y + mon.height) - Math.max(at[1], mon.y)
    return w > size[0] / 2 && h > size[1] / 2
  }

  function keepThumb(address, result) {
    if (root.service) root.service.keep(address, result)
  }

  function thumbUrl(address) {
    var t = root.service ? root.service.thumbs[address] : null
    return t ? t.url : ""
  }

  // Thumbnail capture source for a window, from Quickshell's Hyprland toplevels.
  function toplevel(address) {
    var a = String(address).replace(/^0x/, "")
    var tops = Hyprland.toplevels.values
    for (var i = 0; i < tops.length; i++) if (tops[i].address === a) return tops[i].wayland
    return null
  }

  function select(index) {
    var w = root.flat[index]
    if (w) root.selectedAddress = w.address
  }

  function activate(index, bringHere) {
    var w = root.flat[index]
    if (!w) return
    var target = "address:" + w.address
    var code = ""
    if (bringHere && root.here > 0 && w.workspaceId !== root.here)
      code += "hl.dispatch(hl.dsp.window.move({ workspace = " + root.here + ", follow = false, window = '" + target + "' })); "
    code += "hl.dispatch(hl.dsp.focus({ window = '" + target + "' }))"
    root.dismiss()
    runProc.command = ["hyprctl", "eval", code]
    runProc.running = true
  }

  function closeWindow(index) {
    var w = root.flat[index]
    if (!w) return
    var addr = w.address
    root.all = root.all.filter(function(x) { return x.address !== addr })
    runProc.command = ["hyprctl", "eval", "hl.dispatch(hl.dsp.window.close({ window = 'address:" + addr + "' }))"]
    runProc.running = true
  }

  Timer {
    id: showTimer
    interval: 16
    onTriggered: { root.animate = true; root.shown = true }
  }

  Process {
    id: probeProc
    command: ["sh", "-c",
      "printf '{\"mons\":'; hyprctl -j monitors; printf ',\"clients\":'; hyprctl -j clients; printf '}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.probed(text)
    }
  }

  Process { id: runProc }

  // One window per monitor, each bound to its own screen for good; it shows
  // on the focused one. A screen binding that follows the focused monitor
  // re-evaluates against destroyed screens at shutdown and crashes Quickshell.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      screen: modelData
      visible: root.opened && root.monitorName === modelData.name
      onVisibleChanged: if (visible) Qt.callLater(function() { search.forceActiveFocus() })
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "dbarke-overview"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      readonly property int margin: Style.space(40)
      readonly property int captionH: Style.space(26)
      readonly property int headerH: root.mode === "all" ? Style.space(26) : 0
      readonly property var lay: Layout.layout(root.groups.map(function(g) {
        return { label: g.label, items: g.items.map(function(w) { return { aspect: w.aspect } }) }
      }), {
        width: grid.width, height: grid.height,
        gap: Style.space(18), groupGap: Style.space(56),
        caption: panel.captionH, header: panel.headerH,
        maxHeight: grid.height * (root.mode === "all" ? 0.42 : 0.62)
      })

      function nav(dir) {
        var next = Layout.neighbour(panel.lay, root.selected, dir)
        if (next >= 0) root.select(next)
      }

      Rectangle {
        anchors.fill: parent
        color: root.tint(root.background, 0.94)
        opacity: root.shown ? 1 : 0
        Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 160 } }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.dismiss()
      }

      // ------------------------------------------------------- top bar

      Column {
        id: top
        anchors.horizontalCenter: parent.horizontalCenter
        y: panel.margin
        spacing: Style.spacing.lg
        opacity: root.shown ? 1 : 0
        Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 160 } }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.sm

          Repeater {
            model: [{ key: "all", label: "All workspaces" }, { key: "here", label: "This workspace" }]

            Rectangle {
              id: pill
              required property var modelData
              readonly property bool active: root.mode === modelData.key
              width: pillText.implicitWidth + Style.space(28)
              height: pillText.implicitHeight + Style.space(12)
              radius: height / 2
              color: active ? root.tint(root.accent, 0.22) : root.tint(root.foreground, pillHover.containsMouse ? 0.1 : 0.05)
              border.width: active ? 1 : 0
              border.color: root.tint(root.accent, 0.7)

              Text {
                id: pillText
                anchors.centerIn: parent
                text: pill.modelData.label
                color: pill.active ? root.accent : root.tint(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: pillHover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: if (!pill.active) root.toggleMode()
              }
            }
          }
        }

        TextField {
          id: search
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(420)
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: "Type to filter windows"
          text: root.query
          onTextEdited: root.query = text

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            var k = event.key
            var shift = event.modifiers & Qt.ShiftModifier
            if (k === Qt.Key_Escape) {
              if (root.query) root.query = ""
              else root.dismiss()
            }
            else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) root.toggleMode()
            else if (k === Qt.Key_Left) panel.nav("left")
            else if (k === Qt.Key_Right) panel.nav("right")
            else if (k === Qt.Key_Up) panel.nav("up")
            else if (k === Qt.Key_Down) panel.nav("down")
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.activate(root.selected, shift)
            else if (k === Qt.Key_Delete && !root.query) root.closeWindow(root.selected)
            else return
            event.accepted = true
          }
        }
      }

      // --------------------------------------------------- thumbnails

      Item {
        id: grid
        x: panel.margin
        y: top.y + top.height + Style.space(24)
        width: panel.width - 2 * panel.margin
        height: hints.y - y - Style.space(16)

        Text {
          anchors.centerIn: parent
          visible: root.flat.length === 0
          text: root.all.length ? (root.query ? "No window matches" : "No windows on this workspace") : "No open windows"
          color: root.tint(root.foreground, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Repeater {
          model: panel.lay.headers

          Text {
            required property var modelData
            readonly property bool current: root.groups[modelData.group] && root.groups[modelData.group].current
            x: modelData.x
            y: modelData.y
            width: Math.max(modelData.w, Style.space(160))
            height: panel.headerH
            verticalAlignment: Text.AlignVCenter
            text: modelData.label + (modelData.cont ? " (continued)" : "")
            elide: Text.ElideRight
            color: current ? root.accent : root.tint(root.foreground, 0.65)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: current
            opacity: root.shown ? 1 : 0
            Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 200 } }
          }
        }

        Repeater {
          model: root.flat

          Item {
            id: tile
            required property var modelData
            required property int index
            readonly property var cell: panel.lay.items[index] || { x: 0, y: 0, w: 1, h: 1 }
            readonly property var origin: modelData.origin
            readonly property bool current: index === root.selected
            readonly property bool zooming: !root.shown && origin !== null

            // Grid cell, or the window's real place (in grid coordinates)
            // before the opening animation runs.
            x: zooming ? origin.x - grid.x : cell.x
            y: zooming ? origin.y - grid.y : cell.y
            width: zooming ? origin.w : cell.w
            height: (zooming ? origin.h : cell.h) + panel.captionH
            opacity: root.shown || origin !== null ? 1 : 0
            scale: root.shown || origin !== null ? 1 : 0.92
            z: current ? 2 : 1

            Behavior on x { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on width { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on height { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 200 } }
            Behavior on scale { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            Rectangle {
              id: frame
              x: -border.width
              y: -border.width
              width: tile.width + 2 * border.width
              height: tile.height - panel.captionH + 2 * border.width
              radius: Math.max(Style.cornerRadius, Style.space(6))
              color: root.tint(root.foreground, 0.06)
              border.width: Style.space(3)
              border.color: tile.current ? root.accent : (hover.containsMouse ? root.tint(root.foreground, 0.35) : "transparent")
            }

            // Last snapshot while there is no live picture.
            Image {
              width: tile.width
              height: tile.height - panel.captionH
              visible: !shot.hasContent && status === Image.Ready
              source: root.opened ? root.thumbUrl(tile.modelData.address) : ""
              fillMode: Image.Stretch
              smooth: true
              cache: false
            }

            // Placeholder until there is any picture.
            Image {
              anchors.centerIn: frame
              visible: !shot.hasContent && !root.thumbUrl(tile.modelData.address)
              width: Math.min(Style.space(64), frame.width / 2, frame.height / 2)
              height: width
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: tile.modelData.icon
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }

            ScreencopyView {
              id: shot
              width: tile.width
              height: tile.height - panel.captionH
              // Only the panel on screen captures.
              captureSource: panel.visible ? root.toplevel(tile.modelData.address) : null
              live: panel.visible
              // A live picture refreshes the snapshot for next time.
              onHasContentChanged: if (hasContent) refreshThumb.restart()

              Timer {
                id: refreshThumb
                interval: 300
                onTriggered: {
                  var addr = tile.modelData.address
                  if (panel.visible && shot.hasContent && shot.width > 4)
                    shot.grabToImage(function(result) { root.keepThumb(addr, result) },
                      Qt.size(Math.round(shot.width), Math.round(shot.height)))
                }
              }
            }

            Row {
              y: tile.height - panel.captionH + Style.spacing.md
              width: tile.width
              spacing: Style.spacing.md

              Image {
                id: capIcon
                width: Style.space(16)
                height: width
                anchors.verticalCenter: parent.verticalCenter
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                source: tile.modelData.icon
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }

              Text {
                width: parent.width - capIcon.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                text: tile.modelData.title
                elide: Text.ElideRight
                color: tile.current ? root.accent : root.tint(root.foreground, 0.85)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onPositionChanged: root.select(tile.index)
              onClicked: function(mouse) {
                if (mouse.button === Qt.MiddleButton) root.closeWindow(tile.index)
                else root.activate(tile.index, mouse.modifiers & Qt.ShiftModifier)
              }
            }
          }
        }
      }

      Text {
        id: hints
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - panel.margin - height
        width: Math.min(implicitWidth, parent.width - 2 * panel.margin)
        text: "Click / Enter  go to   ·   Shift  bring here   ·   Tab  all ⇄ this workspace   ·   Middle-click / Del  close window   ·   Esc  close"
        color: root.tint(root.foreground, 0.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        opacity: root.shown ? 1 : 0
        Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 160 } }
      }
    }
  }
}
