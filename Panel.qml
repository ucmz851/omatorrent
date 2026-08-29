import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: panelRoot

  moduleName: "ucmz851.omatorrent-client"
  ipcTarget: "ucmz851.omatorrent-client"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: (bar && bar.foreground !== undefined) ? bar.foreground : Color.foreground
  readonly property color urgent: (bar && bar.urgent !== undefined) ? bar.urgent : Color.urgent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.70)
  readonly property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Main Tab Navigation: "search" | "transfers"
  property string activeViewTab: "search"

  // Search State
  property string searchQuery: ""
  property string lastQuery: ""
  property string activeCategory: "all"
  property string activeProvider: "all"
  property string activeSort: "seeds"
  property bool isSearching: false
  property var searchResults: []
  property int resultsCount: searchResults ? searchResults.length : 0
  property int searchDurationMs: 0
  property string noticeMessage: ""

  // Dropdown states
  property bool providerDropdownOpen: false
  property bool sortDropdownOpen: false

  // qBittorrent Live State & Advanced Controls
  property bool qbConnected: false
  property string qbVersion: ""
  property string qbPortStr: "8080"
  property var qbGlobal: ({ dl_speed: 0, dl_speed_str: "0 B/s", up_speed: 0, up_speed_str: "0 B/s", active_downloads: 0, active_uploads: 0, total_torrents: 0, dht_nodes: 0, save_path: (Quickshell.env("HOME") || "") + "/Downloads", dl_limit: 0, dl_limit_str: "Unlimited", up_limit: 0, up_limit_str: "Unlimited", alt_mode: false, alt_dl_limit_str: "10 KB/s", alt_up_limit_str: "10 KB/s" })
  property var qbTorrents: []
  property bool isPollingQb: false
  property string expandedTorrentHash: ""
  property bool showGlobalLimitsMenu: false
  property bool showSavePathEdit: false
  property string customPathInputText: ""

  readonly property var globalSpeedPresets: [
    { label: "Unlimited", val: "0" },
    { label: "1 MB/s", val: "1048576" },
    { label: "5 MB/s", val: "5242880" },
    { label: "10 MB/s", val: "10485760" },
    { label: "25 MB/s", val: "26214400" },
    { label: "50 MB/s", val: "52428800" }
  ]

  readonly property var globalUpPresets: [
    { label: "Unlimited", val: "0" },
    { label: "250 KB/s", val: "256000" },
    { label: "500 KB/s", val: "512000" },
    { label: "1 MB/s", val: "1048576" },
    { label: "2 MB/s", val: "2097152" },
    { label: "5 MB/s", val: "5242880" }
  ]

  readonly property var categoryList: [
    { id: "all", label: "All" },
    { id: "movies", label: "Movies" },
    { id: "tv", label: "TV Shows" },
    { id: "games", label: "Games" },
    { id: "anime", label: "Anime" },
    { id: "software", label: "Software" },
    { id: "music", label: "Music" }
  ]

  readonly property var providerList: [
    { id: "all", label: "All Indexers (Aggregated)", badge: "ALL", desc: "Simultaneous multi-threaded query" },
    { id: "tpb", label: "The Pirate Bay", badge: "TPB", desc: "General, Movies, Games, Software" },
    { id: "lime", label: "LimeTorrents", badge: "Lime", desc: "General, Media, Apps, Repacks" },
    { id: "yts", label: "YTS", badge: "YTS", desc: "HD & 4K Movie Releases" },
    { id: "eztv", label: "EZTV", badge: "EZTV", desc: "TV Shows & Episodes" },
    { id: "fitgirl", label: "FitGirl Repacks", badge: "FitGirl", desc: "Verified PC Game Repacks" },
    { id: "nyaa", label: "Nyaa", badge: "Nyaa", desc: "Anime, Manga & Japanese Media" }
  ]

  readonly property var sortList: [
    { id: "seeds", label: "Most Seeds", icon: "󰜮" },
    { id: "size_desc", label: "Largest Size", icon: "󰉉" },
    { id: "size_asc", label: "Smallest Size", icon: "󰉋" },
    { id: "date", label: "Newest Date", icon: "󰸗" }
  ]

  function clearSearch() {
    if (searchInput) searchInput.text = ""
    panelRoot.searchQuery = ""
    panelRoot.lastQuery = ""
    panelRoot.searchResults = []
    panelRoot.noticeMessage = ""
    panelRoot.isSearching = false
    panelRoot.providerDropdownOpen = false
    panelRoot.sortDropdownOpen = false
    if (searchInput) searchInput.forceActiveFocus()
  }

  function triggerSearch() {
    panelRoot.providerDropdownOpen = false
    panelRoot.sortDropdownOpen = false
    var q = searchInput.text ? searchInput.text.trim() : ""
    if (!q) return
    panelRoot.lastQuery = q
    panelRoot.isSearching = true
    panelRoot.noticeMessage = ""

    var scriptPath = Qt.resolvedUrl("scripts/torrent_engine.py").toString().replace(/^file:\/\//, "")
    searchProc.command = [
      "python3",
      scriptPath,
      "--query",
      q,
      "--category",
      panelRoot.activeCategory,
      "--provider",
      panelRoot.activeProvider,
      "--sort",
      panelRoot.activeSort
    ]
    searchProc.running = true
  }

  function pollQBittorrent(customPort) {
    if (qbPollProc.running) return
    panelRoot.isPollingQb = true
    var scriptPath = Qt.resolvedUrl("scripts/torrent_engine.py").toString().replace(/^file:\/\//, "")
    var p = (customPort && customPort !== "auto") ? customPort : panelRoot.qbPortStr
    if (customPort === "auto") p = "0"
    qbPollProc.command = ["python3", scriptPath, "--qbittorrent", (p || "8080")]
    qbPollProc.running = true
  }

  function sendQbAction(action, targetHash, extraArg) {
    var scriptPath = Qt.resolvedUrl("scripts/torrent_engine.py").toString().replace(/^file:\/\//, "")
    var p = panelRoot.qbPortStr || "8080"
    var target = (targetHash !== undefined && targetHash !== null) ? targetHash.toString() : "-"
    var extra = (extraArg !== undefined && extraArg !== null) ? extraArg.toString() : "-"
    qbActionProc.command = ["python3", scriptPath, "--qb-action", action, target, extra, p]
    qbActionProc.running = true
  }

  function copyMagnet(magnetLink, title) {
    if (!magnetLink) return
    Quickshell.execDetached(["wl-copy", "--", magnetLink])
    panelRoot.noticeMessage = "Copied magnet link for: " + (title || "Torrent")
    noticeTimer.restart()
  }

  function launchTorrent(magnetLink, title) {
    if (!magnetLink) return
    if (panelRoot.qbConnected) {
      panelRoot.sendQbAction("add", magnetLink)
      panelRoot.noticeMessage = "Added directly to qBittorrent: " + (title || "Torrent")
    } else {
      Quickshell.execDetached(["xdg-open", magnetLink])
      panelRoot.noticeMessage = "Dispatched magnet to desktop client: " + (title || "Torrent")
    }
    noticeTimer.restart()
  }

  function getProviderColor(badge) {
    switch (badge) {
      case "TPB": return "#e5c07b"
      case "Lime": return "#87c095"
      case "YTS": return "#6aa6b2"
      case "EZTV": return "#d19a66"
      case "FitGirl": return "#c678dd"
      case "Nyaa": return "#61afef"
      default: return Color.accent
    }
  }

  function getStateColor(stateLabel) {
    switch (stateLabel) {
      case "Downloading": return "#87c095"
      case "Seeding": return "#6aa6b2"
      case "Paused": return panelRoot.dim
      case "Completed": return Color.accent
      case "Error": return panelRoot.urgent
      default: return panelRoot.foreground
    }
  }

  Timer {
    id: noticeTimer
    interval: 3500
    running: false
    repeat: false
    onTriggered: panelRoot.noticeMessage = ""
  }

  Timer {
    id: qbAutoTimer
    interval: 2500
    running: panelRoot.opened
    repeat: true
    onTriggered: panelRoot.pollQBittorrent()
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        panelRoot.isSearching = false
        if (!text || text.trim() === "") return
        // Enforce 256KB maximum byte ceiling on helper search output to prevent memory exhaustion
        if (text.length > 256 * 1024) {
          console.log("OmaTorrent: search output exceeded byte ceiling")
          return
        }
        try {
          var data = JSON.parse(text)
          panelRoot.searchResults = (data.results || []).slice(0, 50)
          panelRoot.searchDurationMs = data.time_ms || 0
        } catch (e) {
          console.log("OmaTorrent parse error:", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          if (text.length <= 16 * 1024) {
            console.log("OmaTorrent stderr:", text)
          }
        }
      }
    }
    onExited: function(c) { panelRoot.isSearching = false }
  }

  Process {
    id: qbPollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        panelRoot.isPollingQb = false
        if (!text || text.trim() === "") return
        // Enforce 512KB maximum byte ceiling on qBittorrent payload to prevent memory exhaustion
        if (text.length > 512 * 1024) {
          console.log("OmaTorrent: qBittorrent output exceeded byte ceiling")
          return
        }
        try {
          var data = JSON.parse(text)
          panelRoot.qbConnected = (data.status === "connected")
          panelRoot.qbVersion = data.version || ""
          if (data.port) panelRoot.qbPortStr = data.port.toString()
          panelRoot.qbGlobal = data.global || ({ dl_speed: 0, dl_speed_str: "0 B/s", up_speed: 0, up_speed_str: "0 B/s", active_downloads: 0, active_uploads: 0, total_torrents: 0, dht_nodes: 0 })
          panelRoot.qbTorrents = (data.torrents || []).slice(0, 100)
        } catch (e) {
          console.log("qBittorrent parse error:", e)
        }
      }
    }
    onExited: function(c) { panelRoot.isPollingQb = false }
  }

  Process {
    id: qbActionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.length > 32 * 1024) return
        panelRoot.pollQBittorrent()
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      panelRoot.providerDropdownOpen = false
      panelRoot.sortDropdownOpen = false
      panelRoot.pollQBittorrent()
      if (panelRoot.activeViewTab === "search") {
        Qt.callLater(function() {
          if (searchInput) {
            searchInput.forceActiveFocus()
            searchInput.selectAll()
          }
        })
      }
    }
  }

  Component.onCompleted: panelRoot.pollQBittorrent()

  KeyboardPanel {
    id: panel
    anchorItem: panelRoot.anchorItem
    owner: root
    bar: panelRoot.bar
    open: panelRoot.opened
    focusTarget: searchInput

    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: {
        if (panelRoot.providerDropdownOpen || panelRoot.sortDropdownOpen) {
          panelRoot.providerDropdownOpen = false
          panelRoot.sortDropdownOpen = false
        } else if (searchInput && searchInput.text !== "") {
          panelRoot.clearSearch()
        } else {
          panelRoot.close()
        }
      }
      onTabRequested: function(direction) { panelRoot.switchPanel(direction) }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(8)

        // ------------------ HEADER ------------------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerIcon.implicitHeight, headerTextCol.implicitHeight)

          Text {
            id: headerIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰚌"
            color: Color.accent
            font.family: panelRoot.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: headerTextCol
            anchors.left: headerIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: closeBtn.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Row {
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                text: "OmaTorrent"
                color: panelRoot.foreground
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              BorderSurface {
                implicitWidth: badgeText.implicitWidth + Style.space(8)
                implicitHeight: badgeText.implicitHeight + Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                borderSpec: Border.controlSpec("normal", panelRoot.qbConnected ? "#87c095" : panelRoot.dim, Color.accent)
                radius: Style.cornerRadius

                Text {
                  id: badgeText
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: panelRoot.qbConnected
                    ? (panelRoot.qbGlobal.active_downloads > 0 ? (panelRoot.qbGlobal.active_downloads + " Downloading · " + panelRoot.qbGlobal.dl_speed_str) : "qBittorrent Connected")
                    : (panelRoot.resultsCount > 0 ? (panelRoot.resultsCount + " Torrents · " + panelRoot.searchDurationMs + "ms") : "Multi-Indexer")
                  color: panelRoot.qbConnected ? "#87c095" : Color.accent
                  font.family: panelRoot.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Search · Magnets · Live qBittorrent Transfers"
              color: panelRoot.dim
              font.family: panelRoot.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelActionButton {
            id: closeBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "✕"
            tooltipText: "Close (Esc)"
            onClicked: panelRoot.close()
          }
        }

        // ------------------ TOP VIEW SELECTOR TABS ------------------
        Row {
          width: parent.width
          spacing: Style.space(6)

          // Tab 1: Search Engine
          BorderSurface {
            id: searchTabSurface
            readonly property bool isSelected: panelRoot.activeViewTab === "search"
            width: (parent.width - Style.space(6)) / 2
            implicitHeight: Style.space(32)
            radius: Style.cornerRadius
            color: searchTabSurface.isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
            borderSpec: searchTabSurface.isSelected
              ? Border.controlSpec("selected", Color.accent, Color.accent)
              : Border.controlSpec("normal", panelRoot.dim, Color.accent)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                text: "Search Indexers"
                color: searchTabSurface.isSelected ? Color.accent : panelRoot.foreground
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                panelRoot.activeViewTab = "search"
                if (searchInput) searchInput.forceActiveFocus()
              }
            }
          }

          // Tab 2: qBittorrent Transfers
          BorderSurface {
            id: qbTabSurface
            readonly property bool isSelected: panelRoot.activeViewTab === "transfers"
            width: (parent.width - Style.space(6)) / 2
            implicitHeight: Style.space(32)
            radius: Style.cornerRadius
            color: qbTabSurface.isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
            borderSpec: qbTabSurface.isSelected
              ? Border.controlSpec("selected", Color.accent, Color.accent)
              : Border.controlSpec("normal", panelRoot.dim, Color.accent)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text {
                textFormat: Text.PlainText
                text: "󰚌"
                color: panelRoot.qbConnected ? "#87c095" : Color.accent
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                text: panelRoot.qbConnected && panelRoot.qbGlobal.active_downloads > 0
                  ? "Transfers (" + panelRoot.qbGlobal.active_downloads + " 󰜮)"
                  : "qBittorrent Transfers"
                color: qbTabSurface.isSelected ? (panelRoot.qbConnected ? "#87c095" : Color.accent) : panelRoot.foreground
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                panelRoot.activeViewTab = "transfers"
                panelRoot.pollQBittorrent()
              }
            }
          }
        }

        // ------------------ NOTICE BANNER ------------------
        BorderSurface {
          visible: panelRoot.noticeMessage !== ""
          width: parent.width
          implicitHeight: noticeText.implicitHeight + Style.space(8)
          color: "transparent"
          borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)
          radius: Style.cornerRadius

          Text {
            id: noticeText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: panelRoot.noticeMessage
            color: Color.accent
            font.family: panelRoot.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideMiddle
          }
        }

        // =========================================================================
        // VIEW 1: SEARCH & DISCOVERY
        // =========================================================================
        Column {
          visible: panelRoot.activeViewTab === "search"
          width: parent.width
          spacing: Style.space(8)

          // Search Input Bar
          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(38)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
            borderSpec: searchInput.activeFocus
              ? Border.controlSpec("selected", Color.accent, Color.accent)
              : Border.controlSpec("normal", panelRoot.dim, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: panelRoot.isSearching ? Color.accent : panelRoot.dim
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.body
              }

              TextInput {
                id: searchInput
                Layout.fillWidth: true
                text: panelRoot.searchQuery
                color: panelRoot.foreground
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.body
                selectByMouse: true
                clip: true

                Text {
                  textFormat: Text.PlainText
                  anchors.fill: parent
                  text: "Search movies, shows, games, anime, ISOs..."
                  color: panelRoot.subtle
                  font.family: panelRoot.fontFamily
                  font.pixelSize: Style.font.body
                  visible: !searchInput.text && !searchInput.activeFocus
                }

                onAccepted: panelRoot.triggerSearch()
              }

              PanelActionButton {
                visible: searchInput.text !== "" || panelRoot.resultsCount > 0
                iconText: "✕"
                tooltipText: "Clear search"
                onClicked: panelRoot.clearSearch()
              }

              PanelActionButton {
                iconText: panelRoot.isSearching ? "" : "󰑕"
                tooltipText: "Search (Enter)"
                foreground: Color.accent
                rotation: 0
                onClicked: panelRoot.triggerSearch()

                RotationAnimation on rotation {
                  from: 0
                  to: 360
                  duration: 800
                  loops: Animation.Infinite
                  running: panelRoot.isSearching
                }
              }
            }
          }

          // Category Pills
          ScrollView {
            width: parent.width
            implicitHeight: Style.space(28)
            contentWidth: catRow.implicitWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy: ScrollBar.AlwaysOff

            Row {
              id: catRow
              spacing: Style.space(5)

              Repeater {
                model: panelRoot.categoryList
                delegate: BorderSurface {
                  readonly property bool isSelected: panelRoot.activeCategory === modelData.id
                  implicitWidth: catText.implicitWidth + Style.space(12)
                  implicitHeight: Style.space(26)
                  radius: Style.cornerRadius
                  color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                  borderSpec: isSelected
                    ? Border.controlSpec("selected", Color.accent, Color.accent)
                    : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                  Text {
                    id: catText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: modelData.label
                    color: isSelected ? Color.accent : panelRoot.foreground
                    font.family: panelRoot.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: isSelected
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      panelRoot.activeCategory = modelData.id
                      if (searchInput.text.trim()) panelRoot.triggerSearch()
                    }
                  }
                }
              }
            }
          }

          // Provider & Sort Triggers
          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            // Provider Dropdown Trigger
            BorderSurface {
              Layout.fillWidth: true
              implicitHeight: Style.space(28)
              radius: Style.cornerRadius
              color: panelRoot.providerDropdownOpen ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
              borderSpec: panelRoot.providerDropdownOpen
                ? Border.controlSpec("selected", Color.accent, Color.accent)
                : Border.controlSpec("normal", panelRoot.dim, Color.accent)

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(6)

                Text { textFormat: Text.PlainText; text: "󰚌"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: {
                    for (var i = 0; i < panelRoot.providerList.length; i++) {
                      if (panelRoot.providerList[i].id === panelRoot.activeProvider) return panelRoot.providerList[i].label
                    }
                    return "All Indexers"
                  }
                  color: panelRoot.foreground
                  font.family: panelRoot.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text { textFormat: Text.PlainText; text: panelRoot.providerDropdownOpen ? "▲" : "▼"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  panelRoot.sortDropdownOpen = false
                  panelRoot.providerDropdownOpen = !panelRoot.providerDropdownOpen
                }
              }
            }

            // Sort Dropdown Trigger
            BorderSurface {
              Layout.fillWidth: true
              implicitHeight: Style.space(28)
              radius: Style.cornerRadius
              color: panelRoot.sortDropdownOpen ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
              borderSpec: panelRoot.sortDropdownOpen
                ? Border.controlSpec("selected", Color.accent, Color.accent)
                : Border.controlSpec("normal", panelRoot.dim, Color.accent)

              RowLayout {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(6)

                Text { textFormat: Text.PlainText; text: "󰒺"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: {
                    for (var j = 0; j < panelRoot.sortList.length; j++) {
                      if (panelRoot.sortList[j].id === panelRoot.activeSort) return panelRoot.sortList[j].label
                    }
                    return "Most Seeds"
                  }
                  color: panelRoot.foreground
                  font.family: panelRoot.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text { textFormat: Text.PlainText; text: panelRoot.sortDropdownOpen ? "▲" : "▼"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  panelRoot.providerDropdownOpen = false
                  panelRoot.sortDropdownOpen = !panelRoot.sortDropdownOpen
                }
              }
            }
          }

          // Provider Dropdown Menu
          BorderSurface {
            visible: panelRoot.providerDropdownOpen
            width: parent.width
            implicitHeight: provListCol.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
            borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)

            Column {
              id: provListCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(4)
              spacing: Style.space(2)

              Repeater {
                model: panelRoot.providerList
                delegate: BorderSurface {
                  readonly property bool isSelected: panelRoot.activeProvider === modelData.id
                  width: parent.width
                  implicitHeight: Style.space(28)
                  radius: Style.cornerRadius
                  color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                  borderSpec: Border.controlSpec("normal", isSelected ? Color.accent : "transparent", Color.accent)

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)

                    Text { textFormat: Text.PlainText; text: isSelected ? "" : "  "; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Text { textFormat: Text.PlainText; text: modelData.label; color: isSelected ? Color.accent : panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: isSelected }
                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: "· " + modelData.desc; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      panelRoot.activeProvider = modelData.id
                      panelRoot.providerDropdownOpen = false
                      if (searchInput.text.trim()) panelRoot.triggerSearch()
                    }
                  }
                }
              }
            }
          }

          // Sort Dropdown Menu
          BorderSurface {
            visible: panelRoot.sortDropdownOpen
            width: parent.width
            implicitHeight: sortListCol.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
            borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)

            Column {
              id: sortListCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(4)
              spacing: Style.space(2)

              Repeater {
                model: panelRoot.sortList
                delegate: BorderSurface {
                  readonly property bool isSelected: panelRoot.activeSort === modelData.id
                  width: parent.width
                  implicitHeight: Style.space(28)
                  radius: Style.cornerRadius
                  color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                  borderSpec: Border.controlSpec("normal", isSelected ? Color.accent : "transparent", Color.accent)

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)

                    Text { textFormat: Text.PlainText; text: isSelected ? "" : "  "; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Text { textFormat: Text.PlainText; text: modelData.icon + "  " + modelData.label; color: isSelected ? Color.accent : panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: isSelected }
                    Item { Layout.fillWidth: true }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      panelRoot.activeSort = modelData.id
                      panelRoot.sortDropdownOpen = false
                      if (searchInput.text.trim()) panelRoot.triggerSearch()
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width }

          // Search Results View
          Item {
            width: parent.width
            implicitHeight: Style.space(380)

            // State 1: Searching Spinner
            Column {
              visible: panelRoot.isSearching && panelRoot.resultsCount === 0
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: ""
                color: Color.accent
                font.family: panelRoot.fontFamily
                font.pixelSize: Style.font.display
                rotation: 0

                RotationAnimation on rotation {
                  from: 0
                  to: 360
                  duration: 800
                  loops: Animation.Infinite
                  running: panelRoot.isSearching
                }
              }

              Text { textFormat: Text.PlainText; text: "Querying multi-indexers..."; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body }
            }

            // State 2: Welcome Prompt
            Column {
              visible: !panelRoot.isSearching && panelRoot.resultsCount === 0 && !panelRoot.lastQuery
              anchors.centerIn: parent
              spacing: Style.space(8)
              width: parent.width * 0.85

              Text { textFormat: Text.PlainText; anchors.horizontalCenter: parent.horizontalCenter; text: "󰚌"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.display }
              Text { textFormat: Text.PlainText; text: "Instant Torrent Search & Magnet Dispatcher"; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body; font.bold: true; horizontalAlignment: Text.AlignHCenter; width: parent.width }
              Text { textFormat: Text.PlainText; text: "Type a title above to search across ThePirateBay, LimeTorrents, YTS, EZTV, FitGirl, and Nyaa."; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; width: parent.width }
            }

            // State 3: No Results
            Column {
              visible: !panelRoot.isSearching && panelRoot.resultsCount === 0 && panelRoot.lastQuery !== ""
              anchors.centerIn: parent
              spacing: Style.space(6)
              width: parent.width * 0.85

              Text { textFormat: Text.PlainText; anchors.horizontalCenter: parent.horizontalCenter; text: "󰛵"; color: panelRoot.urgent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.title }
              Text { textFormat: Text.PlainText; text: "No torrents found for '" + panelRoot.lastQuery + "'"; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body; font.bold: true; horizontalAlignment: Text.AlignHCenter; width: parent.width }
              Text { textFormat: Text.PlainText; text: "Try different keywords, switch to 'All' category, or select 'All Indexers'."; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; width: parent.width }
            }

            // State 4: Results List
            ListView {
              id: resultListView
              visible: panelRoot.resultsCount > 0
              anchors.fill: parent
              clip: true
              spacing: Style.space(6)
              model: panelRoot.searchResults

              delegate: BorderSurface {
                width: resultListView.width
                implicitHeight: itemCol.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
                borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)

                Column {
                  id: itemCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(8)
                  spacing: Style.space(4)

                  // Row 1: Badges + Action Buttons
                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    BorderSurface {
                      implicitWidth: provBadge.implicitWidth + Style.space(8)
                      implicitHeight: provBadge.implicitHeight + Style.space(3)
                      color: "transparent"
                      borderSpec: Border.controlSpec("normal", panelRoot.getProviderColor(modelData.provider_badge), Color.accent)
                      radius: Style.cornerRadius

                      Text { id: provBadge; textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData.provider_badge; color: panelRoot.getProviderColor(modelData.provider_badge); font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    }

                    BorderSurface {
                      implicitWidth: catBadge.implicitWidth + Style.space(8)
                      implicitHeight: catBadge.implicitHeight + Style.space(3)
                      color: "transparent"
                      borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)
                      radius: Style.cornerRadius

                      Text { id: catBadge; textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData.category || "General"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    }

                    Item { Layout.fillWidth: true }

                    PanelActionButton {
                      iconText: "󰆏"
                      tooltipText: "Copy Magnet Link"
                      foreground: Color.accent
                      onClicked: panelRoot.copyMagnet(modelData.magnet, modelData.title)
                    }

                    PanelActionButton {
                      iconText: "󰚌"
                      tooltipText: panelRoot.qbConnected ? "Add directly to qBittorrent" : "Launch Magnet in Desktop Client"
                      foreground: "#87c095"
                      onClicked: panelRoot.launchTorrent(modelData.magnet, modelData.title)
                    }
                  }

                  // Row 2: Title
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.title
                    color: panelRoot.foreground
                    font.family: panelRoot.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }

                  // Row 3: Metadata
                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    Row {
                      spacing: Style.space(3)
                      Text { textFormat: Text.PlainText; text: "󰉉"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: modelData.size; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    }

                    Row {
                      spacing: Style.space(3)
                      Text { textFormat: Text.PlainText; text: "󰜮"; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: modelData.seeds.toString(); color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    }

                    Row {
                      spacing: Style.space(3)
                      Text { textFormat: Text.PlainText; text: "󰜵"; color: "#e06c75"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: modelData.leechers.toString(); color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    }

                    Item { Layout.fillWidth: true }

                    Text { textFormat: Text.PlainText; text: modelData.date || ""; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                  }
                }
              }
            }
          }
        }

        // =========================================================================
        // VIEW 2: QBITTORRENT LIVE TRANSFERS & CONTROLLER
        // =========================================================================
        Column {
          visible: panelRoot.activeViewTab === "transfers"
          width: parent.width
          spacing: Style.space(8)

          // State A: Connected to qBittorrent
          Column {
            visible: panelRoot.qbConnected
            width: parent.width
            spacing: Style.space(8)

            // Global Speeds & Settings Card
            BorderSurface {
              width: parent.width
              implicitHeight: globalHeaderCol.implicitHeight + Style.space(16)
              color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
              borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)
              radius: Style.cornerRadius

              Column {
                id: globalHeaderCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(8)

                // Row 1: Speeds & Quick Toggles
                RowLayout {
                  width: parent.width
                  spacing: Style.space(10)

                  // Download Stat
                  Column {
                    Layout.fillWidth: true
                    spacing: Style.space(2)
                    Row {
                      spacing: Style.space(4)
                      Text { textFormat: Text.PlainText; text: "󰜮"; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: "Download Speed"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    }
                    Text { textFormat: Text.PlainText; text: panelRoot.qbGlobal.dl_speed_str; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
                  }

                  // Upload Stat
                  Column {
                    Layout.fillWidth: true
                    spacing: Style.space(2)
                    Row {
                      spacing: Style.space(4)
                      Text { textFormat: Text.PlainText; text: "󰜵"; color: "#6aa6b2"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: "Upload Speed"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    }
                    Text { textFormat: Text.PlainText; text: panelRoot.qbGlobal.up_speed_str; color: "#6aa6b2"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
                  }

                  // Alt Speed Toggle (Turtle Mode)
                  BorderSurface {
                    implicitWidth: altSpeedRow.implicitWidth + Style.space(10)
                    implicitHeight: Style.space(28)
                    radius: Style.cornerRadius
                    color: panelRoot.qbGlobal.alt_mode ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                    borderSpec: panelRoot.qbGlobal.alt_mode
                      ? Border.controlSpec("selected", Color.accent, Color.accent)
                      : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                    Row {
                      id: altSpeedRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text { textFormat: Text.PlainText; text: panelRoot.qbGlobal.alt_mode ? "󱥸" : "󰓅"; color: panelRoot.qbGlobal.alt_mode ? Color.accent : panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: panelRoot.qbGlobal.alt_mode ? "Alt Limit ON" : "Full Speed"; color: panelRoot.qbGlobal.alt_mode ? Color.accent : panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: panelRoot.qbGlobal.alt_mode }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: panelRoot.sendQbAction("toggle_alt_speed")
                    }
                  }

                  // Refresh Action
                  PanelActionButton {
                    iconText: ""
                    tooltipText: "Refresh Transfers"
                    foreground: Color.accent
                    onClicked: panelRoot.pollQBittorrent()
                  }
                }

                // Row 2: Default Save Path & Global Limit Toggles
                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)

                  // Save Path Display Pill
                  BorderSurface {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(26)
                    radius: Style.cornerRadius
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", panelRoot.subtle, Color.accent)

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(4)
                      spacing: Style.space(4)

                      Text { textFormat: Text.PlainText; text: "󰉋"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: panelRoot.qbGlobal.save_path || "/home/Downloads"
                        color: panelRoot.foreground
                        font.family: panelRoot.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }

                      PanelActionButton {
                        iconText: "󰉋"
                        tooltipText: "Open in File Manager"
                        onClicked: Quickshell.execDetached(["xdg-open", panelRoot.qbGlobal.save_path || ((Quickshell.env("HOME") || "") + "/Downloads")])
                      }

                      PanelActionButton {
                        iconText: "󰏫"
                        tooltipText: "Change Default Download Directory"
                        onClicked: {
                          panelRoot.customPathInputText = panelRoot.qbGlobal.save_path || ((Quickshell.env("HOME") || "") + "/Downloads")
                          panelRoot.showSavePathEdit = !panelRoot.showSavePathEdit
                        }
                      }
                    }
                  }

                  // Global Limits Dropdown Toggle Button
                  BorderSurface {
                    implicitWidth: limitsBtnRow.implicitWidth + Style.space(10)
                    implicitHeight: Style.space(26)
                    radius: Style.cornerRadius
                    color: panelRoot.showGlobalLimitsMenu ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                    borderSpec: panelRoot.showGlobalLimitsMenu
                      ? Border.controlSpec("selected", Color.accent, Color.accent)
                      : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                    Row {
                      id: limitsBtnRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text { textFormat: Text.PlainText; text: "󰛳"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text {
                        textFormat: Text.PlainText
                        text: "Limits (DL: " + panelRoot.qbGlobal.dl_limit_str + " · UP: " + panelRoot.qbGlobal.up_limit_str + ")"
                        color: panelRoot.showGlobalLimitsMenu ? Color.accent : panelRoot.foreground
                        font.family: panelRoot.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text { textFormat: Text.PlainText; text: panelRoot.showGlobalLimitsMenu ? "▲" : "▼"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: panelRoot.showGlobalLimitsMenu = !panelRoot.showGlobalLimitsMenu
                    }
                  }
                }

                // Expandable Section A: Save Path Editor
                BorderSurface {
                  visible: panelRoot.showSavePathEdit
                  width: parent.width
                  implicitHeight: Style.space(32)
                  radius: Style.cornerRadius
                  color: Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground)
                  borderSpec: Border.controlSpec("selected", Color.accent, Color.accent)

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    spacing: Style.space(6)

                    Text { textFormat: Text.PlainText; text: "New Path:"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

                    TextInput {
                      id: defaultPathInput
                      Layout.fillWidth: true
                      text: panelRoot.customPathInputText
                      color: panelRoot.foreground
                      font.family: panelRoot.fontFamily
                      font.pixelSize: Style.font.caption
                      selectByMouse: true
                      clip: true
                      onTextChanged: panelRoot.customPathInputText = defaultPathInput.text.trim()
                      onAccepted: {
                        if (panelRoot.customPathInputText) {
                          panelRoot.sendQbAction("set_global_save_path", panelRoot.customPathInputText)
                          panelRoot.showSavePathEdit = false
                        }
                      }
                    }

                    PanelActionButton {
                      iconText: ""
                      tooltipText: "Save Default Path"
                      foreground: Color.accent
                      onClicked: {
                        if (panelRoot.customPathInputText) {
                          panelRoot.sendQbAction("set_global_save_path", panelRoot.customPathInputText)
                          panelRoot.showSavePathEdit = false
                        }
                      }
                    }

                    PanelActionButton {
                      iconText: "✕"
                      tooltipText: "Cancel"
                      onClicked: panelRoot.showSavePathEdit = false
                    }
                  }
                }

                // Expandable Section B: Global Speed Limit Menu
                BorderSurface {
                  visible: panelRoot.showGlobalLimitsMenu
                  width: parent.width
                  implicitHeight: globalLimitsCol.implicitHeight + Style.space(12)
                  radius: Style.cornerRadius
                  color: Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground)
                  borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)

                  Column {
                    id: globalLimitsCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(6)
                    spacing: Style.space(6)

                    // Global Download Limit Row
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      Text { textFormat: Text.PlainText; text: "󰜮 Global DL Limit:"; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      Item { Layout.fillWidth: true }

                      Flow {
                        spacing: Style.space(4)
                        Repeater {
                          model: panelRoot.globalSpeedPresets
                          delegate: BorderSurface {
                            readonly property bool isSelected: (panelRoot.qbGlobal.dl_limit || 0).toString() === modelData.val
                            implicitWidth: dlPresetText.implicitWidth + Style.space(8)
                            implicitHeight: Style.space(22)
                            radius: Style.cornerRadius
                            color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                            borderSpec: isSelected
                              ? Border.controlSpec("selected", Color.accent, Color.accent)
                              : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                            Text {
                              id: dlPresetText
                              textFormat: Text.PlainText
                              anchors.centerIn: parent
                              text: modelData.label
                              color: isSelected ? Color.accent : panelRoot.foreground
                              font.family: panelRoot.fontFamily
                              font.pixelSize: Style.font.caption
                              font.bold: isSelected
                            }

                            MouseArea {
                              anchors.fill: parent
                              cursorShape: Qt.PointingHandCursor
                              onClicked: panelRoot.sendQbAction("set_global_dl_limit", modelData.val)
                            }
                          }
                        }
                      }
                    }

                    // Global Upload Limit Row
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      Text { textFormat: Text.PlainText; text: "󰜵 Global UP Limit:"; color: "#6aa6b2"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      Item { Layout.fillWidth: true }

                      Flow {
                        spacing: Style.space(4)
                        Repeater {
                          model: panelRoot.globalUpPresets
                          delegate: BorderSurface {
                            readonly property bool isSelected: (panelRoot.qbGlobal.up_limit || 0).toString() === modelData.val
                            implicitWidth: upPresetText.implicitWidth + Style.space(8)
                            implicitHeight: Style.space(22)
                            radius: Style.cornerRadius
                            color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                            borderSpec: isSelected
                              ? Border.controlSpec("selected", Color.accent, Color.accent)
                              : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                            Text {
                              id: upPresetText
                              textFormat: Text.PlainText
                              anchors.centerIn: parent
                              text: modelData.label
                              color: isSelected ? Color.accent : panelRoot.foreground
                              font.family: panelRoot.fontFamily
                              font.pixelSize: Style.font.caption
                              font.bold: isSelected
                            }

                            MouseArea {
                              anchors.fill: parent
                              cursorShape: Qt.PointingHandCursor
                              onClicked: panelRoot.sendQbAction("set_global_up_limit", modelData.val)
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // Torrents List
            Item {
              width: parent.width
              implicitHeight: Style.space(380)

              // Empty transfers state
              Column {
                visible: panelRoot.qbTorrents.length === 0
                anchors.centerIn: parent
                spacing: Style.space(6)
                width: parent.width * 0.85

                Text { textFormat: Text.PlainText; anchors.horizontalCenter: parent.horizontalCenter; text: "󰚌"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.display }
                Text { textFormat: Text.PlainText; text: "No Active Torrents"; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body; font.bold: true; horizontalAlignment: Text.AlignHCenter; width: parent.width }
                Text { textFormat: Text.PlainText; text: "Use the Search tab above to find movies, games, or shows and send them directly to qBittorrent."; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; width: parent.width }
              }

              ListView {
                id: qbListView
                visible: panelRoot.qbTorrents.length > 0
                anchors.fill: parent
                clip: true
                spacing: Style.space(6)
                model: panelRoot.qbTorrents

                delegate: BorderSurface {
                  width: qbListView.width
                  implicitHeight: qbItemCol.implicitHeight + Style.space(12)
                  radius: Style.cornerRadius
                  color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
                  borderSpec: (panelRoot.expandedTorrentHash === modelData.hash)
                    ? Border.controlSpec("selected", Color.accent, Color.accent)
                    : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                  Column {
                    id: qbItemCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    spacing: Style.space(5)

                    // Row 1: State Badge, Progress %, Ratio, Limits, and Action Buttons
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      BorderSurface {
                        implicitWidth: qbStateBadge.implicitWidth + Style.space(8)
                        implicitHeight: qbStateBadge.implicitHeight + Style.space(3)
                        color: "transparent"
                        borderSpec: Border.controlSpec("normal", panelRoot.getStateColor(modelData.state_label), Color.accent)
                        radius: Style.cornerRadius

                        Text {
                          id: qbStateBadge
                          textFormat: Text.PlainText
                          anchors.centerIn: parent
                          text: modelData.state_label
                          color: panelRoot.getStateColor(modelData.state_label)
                          font.family: panelRoot.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: modelData.progress_pct + "%"
                        color: modelData.progress >= 1.0 ? Color.accent : panelRoot.foreground
                        font.family: panelRoot.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      // Ratio
                      Text {
                        textFormat: Text.PlainText
                        text: "Ratio: " + modelData.ratio
                        color: panelRoot.dim
                        font.family: panelRoot.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      // DL Limit badge if active
                      BorderSurface {
                        visible: modelData.dl_limit > 0
                        implicitWidth: dlLimBadgeText.implicitWidth + Style.space(6)
                        implicitHeight: dlLimBadgeText.implicitHeight + Style.space(2)
                        radius: Style.cornerRadius
                        color: "transparent"
                        borderSpec: Border.controlSpec("normal", "#87c095", Color.accent)
                        Text {
                          id: dlLimBadgeText
                          textFormat: Text.PlainText
                          anchors.centerIn: parent
                          text: "󰜮 " + modelData.dl_limit_str
                          color: "#87c095"
                          font.family: panelRoot.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Item { Layout.fillWidth: true }

                      // Pause / Resume Button
                      PanelActionButton {
                        iconText: modelData.state.indexOf("paused") !== -1 || modelData.state.indexOf("stopped") !== -1 ? "󰐊" : "󰏤"
                        tooltipText: modelData.state.indexOf("paused") !== -1 || modelData.state.indexOf("stopped") !== -1 ? "Resume Torrent" : "Pause Torrent"
                        foreground: Color.accent
                        onClicked: {
                          if (modelData.state.indexOf("paused") !== -1 || modelData.state.indexOf("stopped") !== -1) {
                            panelRoot.sendQbAction("resume", modelData.hash)
                          } else {
                            panelRoot.sendQbAction("pause", modelData.hash)
                          }
                        }
                      }

                      // Detailed Limiter & Path Settings Button
                      PanelActionButton {
                        iconText: ""
                        tooltipText: panelRoot.expandedTorrentHash === modelData.hash ? "Close Torrent Controls" : "Speed Limits & Torrent Settings"
                        foreground: panelRoot.expandedTorrentHash === modelData.hash ? Color.accent : panelRoot.foreground
                        onClicked: {
                          panelRoot.expandedTorrentHash = (panelRoot.expandedTorrentHash === modelData.hash) ? "" : modelData.hash
                        }
                      }

                      // Delete Torrent Button
                      PanelActionButton {
                        iconText: "󰆴"
                        tooltipText: "Remove from qBittorrent"
                        foreground: panelRoot.urgent
                        onClicked: panelRoot.sendQbAction("delete", modelData.hash, "0")
                      }
                    }

                    // Row 2: Torrent Title
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: modelData.name
                      color: panelRoot.foreground
                      font.family: panelRoot.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      wrapMode: Text.Wrap
                      maximumLineCount: 2
                      elide: Text.ElideRight
                    }

                    // Row 3: Progress Bar
                    Rectangle {
                      width: parent.width
                      height: Style.space(6)
                      radius: Style.cornerRadius
                      color: Qt.darker(panelRoot.dim, 2.0)

                      Rectangle {
                        width: parent.width * Math.min(1.0, Math.max(0.0, modelData.progress))
                        height: parent.height
                        radius: Style.cornerRadius
                        color: modelData.progress >= 1.0 ? Color.accent : "#87c095"
                      }
                    }

                    // Row 4: Speed & ETA Metas
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(8)

                      Row {
                        spacing: Style.space(3)
                        Text { textFormat: Text.PlainText; text: "󰜮"; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                        Text { textFormat: Text.PlainText; text: modelData.dlspeed_str; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      }

                      Row {
                        spacing: Style.space(3)
                        Text { textFormat: Text.PlainText; text: "󰜵"; color: "#6aa6b2"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                        Text { textFormat: Text.PlainText; text: modelData.upspeed_str; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      }

                      Row {
                        spacing: Style.space(3)
                        Text { textFormat: Text.PlainText; text: "󰉉"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                        Text { textFormat: Text.PlainText; text: modelData.completed_str + " / " + modelData.size_str; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      }

                      Item { Layout.fillWidth: true }

                      Text {
                        textFormat: Text.PlainText
                        text: "ETA: " + modelData.eta_str
                        color: panelRoot.dim
                        font.family: panelRoot.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    // =========================================================
                    // ROW 5: EXPANDABLE PER-TORRENT CONTROLLER & LIMITER DRAWER
                    // =========================================================
                    Column {
                      visible: panelRoot.expandedTorrentHash === modelData.hash
                      width: parent.width
                      spacing: Style.space(6)

                      PanelSeparator { width: parent.width }

                      // Location & Open Folder Row
                      RowLayout {
                        width: parent.width
                        spacing: Style.space(6)

                        Text { textFormat: Text.PlainText; text: "󰉋 Path:"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: modelData.save_path
                          color: panelRoot.foreground
                          font.family: panelRoot.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideMiddle
                        }

                        BorderSurface {
                          implicitWidth: openFolderText.implicitWidth + Style.space(8)
                          implicitHeight: Style.space(22)
                          radius: Style.cornerRadius
                          color: "transparent"
                          borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)

                          Text {
                            id: openFolderText
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: "Open Folder"
                            color: Color.accent
                            font.family: panelRoot.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Quickshell.execDetached(["xdg-open", modelData.save_path])
                          }
                        }
                      }

                      // Per-Torrent Download Speed Limit Selector
                      RowLayout {
                        width: parent.width
                        spacing: Style.space(4)

                        Text { textFormat: Text.PlainText; text: "󰜮 DL Limit:"; color: "#87c095"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        Item { Layout.fillWidth: true }

                        Flow {
                          spacing: Style.space(3)
                          Repeater {
                            model: [
                              { label: "∞", val: "0" },
                              { label: "1M", val: "1048576" },
                              { label: "5M", val: "5242880" },
                              { label: "10M", val: "10485760" },
                              { label: "25M", val: "26214400" }
                            ]
                            delegate: BorderSurface {
                              readonly property bool isSelected: (modelData.dl_limit || 0).toString() === modelData.val
                              implicitWidth: tDlText.implicitWidth + Style.space(8)
                              implicitHeight: Style.space(20)
                              radius: Style.cornerRadius
                              color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                              borderSpec: isSelected
                                ? Border.controlSpec("selected", "#87c095", Color.accent)
                                : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                              Text {
                                id: tDlText
                                textFormat: Text.PlainText
                                anchors.centerIn: parent
                                text: modelData.label
                                color: isSelected ? "#87c095" : panelRoot.foreground
                                font.family: panelRoot.fontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: isSelected
                              }

                              MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: panelRoot.sendQbAction("set_torrent_dl_limit", modelData.hash, modelData.val)
                              }
                            }
                          }
                        }
                      }

                      // Per-Torrent Upload Speed Limit Selector
                      RowLayout {
                        width: parent.width
                        spacing: Style.space(4)

                        Text { textFormat: Text.PlainText; text: "󰜵 UP Limit:"; color: "#6aa6b2"; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                        Item { Layout.fillWidth: true }

                        Flow {
                          spacing: Style.space(3)
                          Repeater {
                            model: [
                              { label: "∞", val: "0" },
                              { label: "250K", val: "256000" },
                              { label: "500K", val: "512000" },
                              { label: "1M", val: "1048576" },
                              { label: "5M", val: "5242880" }
                            ]
                            delegate: BorderSurface {
                              readonly property bool isSelected: (modelData.up_limit || 0).toString() === modelData.val
                              implicitWidth: tUpText.implicitWidth + Style.space(8)
                              implicitHeight: Style.space(20)
                              radius: Style.cornerRadius
                              color: isSelected ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                              borderSpec: isSelected
                                ? Border.controlSpec("selected", "#6aa6b2", Color.accent)
                                : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                              Text {
                                id: tUpText
                                textFormat: Text.PlainText
                                anchors.centerIn: parent
                                text: modelData.label
                                color: isSelected ? "#6aa6b2" : panelRoot.foreground
                                font.family: panelRoot.fontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: isSelected
                              }

                              MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: panelRoot.sendQbAction("set_torrent_up_limit", modelData.hash, modelData.val)
                              }
                            }
                          }
                        }
                      }

                      // Quick Action Buttons (Force, Recheck, Delete Options)
                      RowLayout {
                        width: parent.width
                        spacing: Style.space(6)

                        // Force Start Toggle
                        BorderSurface {
                          implicitWidth: forceBtnText.implicitWidth + Style.space(8)
                          implicitHeight: Style.space(24)
                          radius: Style.cornerRadius
                          color: modelData.forced ? Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground) : "transparent"
                          borderSpec: modelData.forced
                            ? Border.controlSpec("selected", Color.accent, Color.accent)
                            : Border.controlSpec("normal", panelRoot.dim, Color.accent)

                          Text {
                            id: forceBtnText
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: modelData.forced ? "󰐊 Forced: ON" : "󰐊 Force Start"
                            color: modelData.forced ? Color.accent : panelRoot.foreground
                            font.family: panelRoot.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: modelData.forced
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panelRoot.sendQbAction("toggle_force", modelData.hash, !modelData.forced)
                          }
                        }

                        // Recheck
                        BorderSurface {
                          implicitWidth: recheckBtnText.implicitWidth + Style.space(8)
                          implicitHeight: Style.space(24)
                          radius: Style.cornerRadius
                          color: "transparent"
                          borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)

                          Text {
                            id: recheckBtnText
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: " Recheck"
                            color: panelRoot.foreground
                            font.family: panelRoot.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panelRoot.sendQbAction("recheck", modelData.hash)
                          }
                        }

                        Item { Layout.fillWidth: true }

                        // Delete with Files
                        BorderSurface {
                          implicitWidth: delFilesText.implicitWidth + Style.space(8)
                          implicitHeight: Style.space(24)
                          radius: Style.cornerRadius
                          color: "transparent"
                          borderSpec: Border.controlSpec("normal", panelRoot.urgent, Color.accent)

                          Text {
                            id: delFilesText
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: "󰆴 Delete with Files"
                            color: panelRoot.urgent
                            font.family: panelRoot.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panelRoot.sendQbAction("delete", modelData.hash, "1")
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // State B: Disconnected / WebUI Not Configured
          Column {
            visible: !panelRoot.qbConnected
            width: parent.width
            spacing: Style.space(10)

            BorderSurface {
              width: parent.width
              implicitHeight: setupCol.implicitHeight + Style.space(16)
              color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
              borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)
              radius: Style.cornerRadius

              Column {
                id: setupCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                Row {
                  spacing: Style.space(8)
                  Text { textFormat: Text.PlainText; text: "󰚌"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.title }
                  Column {
                    spacing: Style.space(1)
                    Text { textFormat: Text.PlainText; text: "Enable qBittorrent Web UI"; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                    Text { textFormat: Text.PlainText; text: "To view live download progress in OmaTorrent, enable Web UI:"; color: panelRoot.dim; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                  }
                }

                // Instructions Card
                BorderSurface {
                  width: parent.width
                  implicitHeight: stepsCol.implicitHeight + Style.space(12)
                  color: "transparent"
                  borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)
                  radius: Style.cornerRadius

                  Column {
                    id: stepsCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    spacing: Style.space(6)

                    Text { textFormat: Text.PlainText; text: "󰌷 Recommended Client: qBittorrent"; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Text { textFormat: Text.PlainText; text: "1. Open qBittorrent on your desktop."; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    Text { textFormat: Text.PlainText; text: "2. Go to Tools ➔ Preferences (Alt+O) ➔ Web UI."; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    Text { textFormat: Text.PlainText; text: "3. Check 'Web User Interface (Remote control)'."; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                    Text { textFormat: Text.PlainText; text: "4. Check 'Bypass authentication for clients on localhost'."; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                }

                // Port Configuration Row
                BorderSurface {
                  width: parent.width
                  implicitHeight: Style.space(34)
                  radius: Style.cornerRadius
                  color: Style.hoverFillFor(panelRoot.foreground, panelRoot.foreground)
                  borderSpec: Border.controlSpec("normal", panelRoot.dim, Color.accent)

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(6)
                    spacing: Style.space(6)

                    Text { textFormat: Text.PlainText; text: "Port:"; color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

                    TextInput {
                      id: portInputField
                      Layout.fillWidth: true
                      text: panelRoot.qbPortStr
                      color: Color.accent
                      font.family: panelRoot.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      selectByMouse: true
                      clip: true
                      onTextChanged: panelRoot.qbPortStr = portInputField.text.trim()
                      onAccepted: panelRoot.pollQBittorrent(portInputField.text.trim())
                    }

                    BorderSurface {
                      implicitWidth: autoPortLabel.implicitWidth + Style.space(10)
                      implicitHeight: Style.space(22)
                      radius: Style.cornerRadius
                      color: "transparent"
                      borderSpec: Border.controlSpec("normal", Color.accent, Color.accent)

                      Text {
                        id: autoPortLabel
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: "Auto-Detect"
                        color: Color.accent
                        font.family: panelRoot.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panelRoot.pollQBittorrent("auto")
                      }
                    }
                  }
                }

                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)

                  BorderSurface {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(30)
                    radius: Style.cornerRadius
                    color: Style.selectedFillFor(panelRoot.foreground, panelRoot.foreground)
                    borderSpec: Border.controlSpec("selected", Color.accent, Color.accent)

                    Row {
                      anchors.centerIn: parent
                      spacing: Style.space(6)
                      Text { textFormat: Text.PlainText; text: ""; color: Color.accent; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: "Connect to Port " + (panelRoot.qbPortStr || "8080"); color: panelRoot.foreground; font.family: panelRoot.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: panelRoot.pollQBittorrent(panelRoot.qbPortStr)
                    }
                  }
                }
              }
            }
          }
        }

        // ------------------ FOOTER ------------------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: panelRoot.activeViewTab === "search"
            ? "Click 󰚌 to send to qBittorrent · Click 󰆏 to copy magnet · Esc to close"
            : "Live qBittorrent Controller · Polling active transfers · Esc to close"
          color: panelRoot.subtle
          font.family: panelRoot.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
