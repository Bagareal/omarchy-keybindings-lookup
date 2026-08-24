import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Read-only keybindings reference. Click opens a popup with the same
// keybinding list `omarchy menu keybindings` (SUPER+K) uses, with a search
// box that filters as you type and a 6-row scrollable list. Two tabs split
// the list into starred Favorites (in a user-defined, reorderable order)
// and the full Defaults list. The star on each row toggles it in/out of
// Favorites; the up/down buttons (Favorites tab only) reorder it. Rows are
// for lookup only — clicking the text does not execute the binding.
BarWidget {
  id: root
  moduleName: "bagareal.keybindings"

  property var allBindings: []
  property string filterText: ""
  property string activeTab: "Favorites"
  property var favoriteIds: []

  // Caps enforced on the producer side, before either input is fully
  // materialized in memory — both are unbounded-size inputs (a hand-edited
  // or corrupted favorites file; a keybindings list that grows with
  // configs). The favorites file is read through a descriptor-bound
  // no-follow helper rather than FileView (see favoritesReaderScript
  // below for why). The `--print` output is consumed line-by-line via
  // SplitParser and the process is killed as soon as a cap is hit, instead
  // of being buffered to completion via StdioCollector first.
  readonly property int maxFavoritesBytes: 65536
  readonly property int maxFavoritesItems: 500
  readonly property int maxFavoriteStringLen: 300

  readonly property int maxBindingsBytes: 262144
  readonly property int maxBindingsItems: 2000
  readonly property int maxBindingLineLen: 300

  // Defaults tab keeps the priority order from `omarchy menu keybindings`.
  // Favorites tab uses favoriteIds' own order, which moveFavorite() rewrites
  // — that's what makes the list user-reorderable. Stale ids (a favorited
  // binding whose key was later removed/changed) are filtered out here
  // rather than at write time, so the file only ever needs a plain array.
  readonly property var sourceList: root.activeTab === "Favorites"
    ? root.favoriteIds.filter(function (id) { return root.allBindings.indexOf(id) !== -1 })
    : root.allBindings

  readonly property var filteredBindings: computeFiltered(root.filterText, root.sourceList)

  function computeFiltered(text, list) {
    var q = (text || "").trim().toLowerCase()
    if (q === "") return list
    var tokens = q.split(/\s+/).filter(function (t) { return t.length > 0 })
    return list.filter(function (line) {
      var l = line.toLowerCase()
      for (var i = 0; i < tokens.length; i++) {
        if (l.indexOf(tokens[i]) === -1) return false
      }
      return true
    })
  }

  function isFavorite(line) {
    return root.favoriteIds.indexOf(line) !== -1
  }

  function toggleFavorite(line) {
    var idx = root.favoriteIds.indexOf(line)
    var next = root.favoriteIds.slice()
    if (idx === -1) next.push(line)
    else next.splice(idx, 1)
    root.favoriteIds = next
    favoritesFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function moveFavorite(line, direction) {
    var idx = root.favoriteIds.indexOf(line)
    if (idx === -1) return
    var newIdx = idx + direction
    if (newIdx < 0 || newIdx >= root.favoriteIds.length) return
    var next = root.favoriteIds.slice()
    var tmp = next[idx]
    next[idx] = next[newIdx]
    next[newIdx] = tmp
    root.favoriteIds = next
    favoritesFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function parseFavorites(text) {
    // Reject oversized files before they're handed to JSON.parse, so an
    // adversarial or corrupted favorites file can't force an expensive
    // parse of an arbitrarily large blob.
    if (typeof text !== "string" || text.length > root.maxFavoritesBytes) return []
    try {
      var parsed = JSON.parse(text)
      if (!Array.isArray(parsed)) return []
      return parsed
        .filter(function (v) { return typeof v === "string" })
        .slice(0, root.maxFavoritesItems)
        .map(function (v) { return v.length > root.maxFavoriteStringLen ? v.slice(0, root.maxFavoriteStringLen) : v })
    } catch (e) {}
    return []
  }

  readonly property string favoritesPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/bagareal-keybindings-favorites.json"

  // A stat-then-open check is still a race: whatever stat looked at can be
  // swapped (e.g. for a symlink) before FileView performs its own,
  // separate, path-based open. FileView also has no way to refuse
  // following a symlink or reject a non-regular file (FIFO, socket,
  // device), and opening a FIFO with no writer would hang the read.
  //
  // So favorites are never read through FileView at all. This Perl
  // one-shot does a single syscall-level open with O_NOFOLLOW (a
  // symlinked path is refused, not followed) and O_NONBLOCK (a FIFO with
  // no writer returns immediately instead of hanging), then fstats *that
  // file descriptor* — not the path again — to confirm it's a regular
  // file, and reads at most maxFavoritesBytes+1 bytes from the same
  // descriptor. Check and read are bound to one fd, so nothing can be
  // substituted in between. Exit codes: 0 ok (stdout has the content, or
  // nothing if the file doesn't exist yet), 1 open refused, 2 not a
  // regular file, 3 over the byte cap.
  //
  // FileView is only used to *write* favorites (content we generate
  // ourselves, already bounded by maxFavoritesItems/maxFavoriteStringLen);
  // preload is off so it never performs a read of its own.
  readonly property string favoritesReaderScript: `
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK);
use Errno qw(ENOENT);
my ($path, $cap) = @ARGV;
my $fh;
unless (sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) {
  exit($! == ENOENT ? 0 : 1);
}
unless (-f $fh) {
  exit(2);
}
my $data = "";
while (length($data) <= $cap) {
  my $n = sysread($fh, $data, $cap + 1 - length($data), length($data));
  last unless $n;
}
exit(3) if length($data) > $cap;
print $data;
`

  function loadFavorites() {
    if (!favoritesReadProc.running) favoritesReadProc.running = true
  }

  Process {
    id: favoritesReadProc
    command: ["perl", "-e", root.favoritesReaderScript, "--", root.favoritesPath, String(root.maxFavoritesBytes)]
    stdout: StdioCollector {
      id: favoritesCollector
      waitForEnd: true
    }
    onExited: function (exitCode, exitStatus) {
      if (exitCode === 0) {
        root.favoriteIds = root.parseFavorites(favoritesCollector.text)
        return
      }
      var reasons = {1: "open refused (permission denied or symlink)", 2: "not a regular file", 3: "exceeds " + root.maxFavoritesBytes + " bytes"}
      console.warn("bagareal.keybindings: refusing to load favorites file (" + (reasons[exitCode] || ("exit " + exitCode)) + ")")
      root.favoriteIds = []
    }
  }

  FileView {
    id: favoritesFile
    path: root.favoritesPath
    preload: false
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.loadFavorites()
  }

  // open()/close()/opened is the contract Bar.qml's findPanelWidget() looks
  // for on a live bar-widget instance — it's what makes `omarchy-shell shell
  // toggle <id>` (and therefore a Hyprland keybinding) able to summon this
  // popup, the same mechanism first-party panels like clock/weather use.
  property bool opened: false
  function open() { opened = true }
  function close() { opened = false }

  onOpenedChanged: {
    if (opened) {
      refresh()
      filterText = ""
      activeTab = "Favorites"
      Qt.callLater(function () { searchField.text = "" })
    }
  }

  property var _bindingsLines: []
  property int _bindingsBytes: 0

  function refresh() {
    if (!bindingsProc.running) {
      root._bindingsLines = []
      root._bindingsBytes = 0
      bindingsProc.running = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: bindingsProc
    command: ["omarchy", "menu", "keybindings", "--print"]
    stdout: SplitParser {
      splitMarker: "\n"
      // Consumed line-by-line as the process produces it, rather than
      // buffered whole via StdioCollector — an unexpectedly huge `--print`
      // output gets its process killed the moment a cap is hit instead of
      // being fully read into memory first.
      onRead: function (line) {
        if (!bindingsProc.running) return
        var trimmed = line.trim()
        if (trimmed === "") return
        if (root._bindingsLines.length >= root.maxBindingsItems
            || root._bindingsBytes + trimmed.length > root.maxBindingsBytes) {
          bindingsProc.running = false
          return
        }
        var capped = trimmed.length > root.maxBindingLineLen ? trimmed.slice(0, root.maxBindingLineLen) : trimmed
        root._bindingsBytes += capped.length
        root._bindingsLines.push(capped)
      }
    }
    onExited: {
      root.allBindings = root._bindingsLines
    }
  }

  Component.onCompleted: {
    root.loadFavorites()
    refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "Keybindings (click to search)"
    onPressed: root.opened = !root.opened
  }

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: searchField
    contentWidth: popup.fittedContentWidth(Style.space(440))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(8)

      ButtonGroup {
        id: tabGroup
        width: column.width
        options: ["Favorites", "Defaults"]
        value: root.activeTab
        foreground: root.bar.foreground
        accent: Color.accent
        fontFamily: root.bar.fontFamily
        focusable: false
        onChanged: function (v) { root.activeTab = v }
      }

      TextField {
        id: searchField
        width: column.width
        placeholderText: "Search keybindings…"
        foreground: root.bar.foreground
        accent: Color.accent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        focus: true
        onTextChanged: root.filterText = text
        Keys.onEscapePressed: root.opened = false
        Keys.onTabPressed: function (event) {
          root.activeTab = root.activeTab === "Favorites" ? "Defaults" : "Favorites"
          event.accepted = true
        }
        Keys.onBacktabPressed: function (event) {
          root.activeTab = root.activeTab === "Favorites" ? "Defaults" : "Favorites"
          event.accepted = true
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      ListView {
        id: listView
        width: column.width
        height: Style.space(28) * 6
        clip: true
        model: root.filteredBindings
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}

        // Default wheel step is a fraction of a row per notch, which reads
        // as sluggish once results exceed the 6-row window. A WheelHandler
        // (rather than an overlay MouseArea) steps by ~3 rows per notch
        // without sitting in front of the delegates' own click targets.
        WheelHandler {
          onWheel: function (event) {
            var step = Style.space(28) * 3
            var delta = event.angleDelta.y > 0 ? -step : step
            var maxY = Math.max(0, listView.contentHeight - listView.height)
            listView.contentY = Math.max(0, Math.min(maxY, listView.contentY + delta))
          }
        }

        delegate: Item {
          id: row
          required property string modelData
          width: listView.width
          height: Style.space(28)

          readonly property var parts: modelData.split("→")
          readonly property string keyCombo: parts.length > 0 ? parts[0].trim() : modelData
          readonly property string action: parts.length > 1 ? parts[1].trim() : ""
          readonly property bool favorited: root.isFavorite(row.modelData)
          readonly property int favIndex: root.favoriteIds.indexOf(row.modelData)

          PanelActionButton {
            id: starBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            size: Style.space(20)
            fontSize: Style.font.bodySmall
            iconText: row.favorited ? "󰓎" : "󰓏"
            foreground: row.favorited ? Color.accent : Qt.darker(root.bar.foreground, 1.6)
            tooltipText: row.favorited ? "Remove from Favorites" : "Add to Favorites"
            fontFamily: root.bar.fontFamily
            onClicked: root.toggleFavorite(row.modelData)
          }

          Row {
            id: reorderRow
            anchors.left: starBtn.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.activeTab === "Favorites"
            spacing: Style.space(1)

            PanelActionButton {
              size: Style.space(20)
              fontSize: Style.font.caption
              iconText: "▲"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: row.favIndex > 0
              tooltipText: "Move up"
              onClicked: root.moveFavorite(row.modelData, -1)
            }
            PanelActionButton {
              size: Style.space(20)
              fontSize: Style.font.caption
              iconText: "▼"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: row.favIndex >= 0 && row.favIndex < root.favoriteIds.length - 1
              tooltipText: "Move down"
              onClicked: root.moveFavorite(row.modelData, 1)
            }
          }

          Text {
            id: keyText
            anchors.left: reorderRow.visible ? reorderRow.right : starBtn.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: row.keyCombo
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
            width: Style.space(150)
          }
          Text {
            anchors.left: keyText.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: row.action
            color: Qt.darker(root.bar.foreground, 1.25)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }

      Text {
        visible: root.filteredBindings.length === 0 && root.activeTab === "Favorites" && root.filterText === ""
        text: "No favorites yet — tap the star next to a keybinding in Defaults to add it here."
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        width: column.width
        wrapMode: Text.WordWrap
      }

      Text {
        visible: root.filteredBindings.length === 0 && !(root.activeTab === "Favorites" && root.filterText === "")
        text: "No matches"
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
