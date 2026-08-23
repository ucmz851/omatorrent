import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "ucmz851.omatorrent"
  ipcTarget: "ucmz851.omatorrent"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // State
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

  function triggerSearch() {
    root.providerDropdownOpen = false
    root.sortDropdownOpen = false
    var q = searchInput.text ? searchInput.text.trim() : ""
    if (!q) return
    root.lastQuery = q
    root.isSearching = true
    root.noticeMessage = ""

    var scriptPath = Qt.resolvedUrl("scripts/torrent_engine.py").toString().replace(/^file:\/\//, "")
    searchProc.command = [
      "python3",
      scriptPath,
      "--query",
      q,
      "--category",
      root.activeCategory,
      "--provider",
      root.activeProvider,
      "--sort",
      root.activeSort
    ]
    searchProc.running = true
  }

  function copyMagnet(magnetLink, title) {
    if (!magnetLink) return
    Quickshell.execDetached(["wl-copy", "--", magnetLink])
    root.noticeMessage = "Copied magnet link for: " + (title || "Torrent")
    noticeTimer.restart()
  }

  function launchTorrent(magnetLink, title) {
    if (!magnetLink) return
    Quickshell.execDetached(["xdg-open", magnetLink])
    root.noticeMessage = "Launched in torrent client: " + (title || "Torrent")
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

  Timer {
    id: noticeTimer
    interval: 3500
    running: false
    repeat: false
    onTriggered: root.noticeMessage = ""
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isSearching = false
        if (!text || text.trim() === "") return
        try {
          var data = JSON.parse(text)
          root.searchResults = data.results || []
          root.searchDurationMs = data.time_ms || 0
        } catch (e) {
          console.log("OmaTorrent parse error:", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          console.log("OmaTorrent stderr:", text)
        }
      }
    }
    onExited: function(c) { root.isSearching = false }
  }

  onOpenedChanged: {
    if (opened) {
      root.providerDropdownOpen = false
      root.sortDropdownOpen = false
      Qt.callLater(function() {
        if (searchInput) {
          searchInput.forceActiveFocus()
          searchInput.selectAll()
        }
      })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: searchInput

    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: {
        if (root.providerDropdownOpen || root.sortDropdownOpen) {
          root.providerDropdownOpen = false
          root.sortDropdownOpen = false
        } else {
          root.close()
        }
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

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
            font.family: root.fontFamily
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
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              BorderSurface {
                implicitWidth: badgeText.implicitWidth + Style.space(8)
                implicitHeight: badgeText.implicitHeight + Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
                radius: Style.cornerRadius

                Text {
                  id: badgeText
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.resultsCount > 0 ? (root.resultsCount + " Torrents · " + root.searchDurationMs + "ms") : "Multi-Indexer"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "TPB · LimeTorrents · YTS · EZTV · FitGirl · Nyaa"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelActionButton {
            id: closeBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "✕"
            tooltipText: "Close (Esc)"
            onClicked: root.close()
          }
        }

        // ------------------ NOTICE BANNER ------------------
        BorderSurface {
          visible: root.noticeMessage !== ""
          width: parent.width
          implicitHeight: noticeText.implicitHeight + Style.space(8)
          color: "transparent"
          borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)
          radius: Style.cornerRadius

          Text {
            id: noticeText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.noticeMessage
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideMiddle
          }
        }

        // ------------------ SEARCH INPUT BAR ------------------
        BorderSurface {
          width: parent.width
          implicitHeight: Style.space(38)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.foreground, root.foreground)
          borderSpec: searchInput.activeFocus
            ? Border.controlSpec("selected", Color.accent, Color.accent)
            : Border.controlSpec("normal", root.dim, Color.accent)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: ""
              color: root.isSearching ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            TextInput {
              id: searchInput
              Layout.fillWidth: true
              text: root.searchQuery
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              clip: true

              Text {
                textFormat: Text.PlainText
                anchors.fill: parent
                text: "Search movies, shows, games, anime, ISOs..."
                color: Qt.darker(root.dim, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                visible: !searchInput.text && !searchInput.activeFocus
              }

              onAccepted: root.triggerSearch()
            }

            PanelActionButton {
              visible: searchInput.text !== ""
              iconText: "✕"
              tooltipText: "Clear query"
              onClicked: {
                searchInput.text = ""
                searchInput.forceActiveFocus()
              }
            }

            PanelActionButton {
              iconText: root.isSearching ? "" : "󰑕"
              tooltipText: "Search (Enter)"
              foreground: Color.accent
              rotation: 0
              onClicked: root.triggerSearch()

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
                running: root.isSearching
              }
            }
          }
        }

        // ------------------ CATEGORY PILLS ------------------
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
              model: root.categoryList
              delegate: BorderSurface {
                readonly property bool isSelected: root.activeCategory === modelData.id
                implicitWidth: catText.implicitWidth + Style.space(12)
                implicitHeight: Style.space(26)
                radius: Style.cornerRadius
                color: isSelected ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
                borderSpec: isSelected
                  ? Border.controlSpec("selected", Color.accent, Color.accent)
                  : Border.controlSpec("normal", root.dim, Color.accent)

                Text {
                  id: catText
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: modelData.label
                  color: isSelected ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: isSelected
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activeCategory = modelData.id
                    if (searchInput.text.trim()) root.triggerSearch()
                  }
                }
              }
            }
          }
        }

        // ------------------ PROVIDER & SORT DROPDOWN TRIGGERS ------------------
        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          // Provider Dropdown Button
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(28)
            radius: Style.cornerRadius
            color: root.providerDropdownOpen ? Style.selectedFillFor(root.foreground, root.foreground) : Style.hoverFillFor(root.foreground, root.foreground)
            borderSpec: root.providerDropdownOpen
              ? Border.controlSpec("selected", Color.accent, Color.accent)
              : Border.controlSpec("normal", root.dim, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "󰚌"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: {
                  for (var i = 0; i < root.providerList.length; i++) {
                    if (root.providerList[i].id === root.activeProvider) return root.providerList[i].label
                  }
                  return "All Indexers"
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: root.providerDropdownOpen ? "▲" : "▼"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.sortDropdownOpen = false
                root.providerDropdownOpen = !root.providerDropdownOpen
              }
            }
          }

          // Sort Dropdown Button
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(28)
            radius: Style.cornerRadius
            color: root.sortDropdownOpen ? Style.selectedFillFor(root.foreground, root.foreground) : Style.hoverFillFor(root.foreground, root.foreground)
            borderSpec: root.sortDropdownOpen
              ? Border.controlSpec("selected", Color.accent, Color.accent)
              : Border.controlSpec("normal", root.dim, Color.accent)

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "󰒺"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: {
                  for (var j = 0; j < root.sortList.length; j++) {
                    if (root.sortList[j].id === root.activeSort) return root.sortList[j].label
                  }
                  return "Most Seeds"
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: root.sortDropdownOpen ? "▲" : "▼"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.providerDropdownOpen = false
                root.sortDropdownOpen = !root.sortDropdownOpen
              }
            }
          }
        }

        // ------------------ PROVIDER DROPDOWN MENU ------------------
        BorderSurface {
          visible: root.providerDropdownOpen
          width: parent.width
          implicitHeight: provListCol.implicitHeight + Style.space(8)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.foreground, root.foreground)
          borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)

          Column {
            id: provListCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(4)
            spacing: Style.space(2)

            Repeater {
              model: root.providerList
              delegate: BorderSurface {
                readonly property bool isSelected: root.activeProvider === modelData.id
                width: parent.width
                implicitHeight: Style.space(28)
                radius: Style.cornerRadius
                color: isSelected ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
                borderSpec: Border.controlSpec("normal", isSelected ? Color.accent : "transparent", Color.accent)

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: isSelected ? "" : "  "
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: isSelected ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: isSelected
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "· " + modelData.desc
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activeProvider = modelData.id
                    root.providerDropdownOpen = false
                    if (searchInput.text.trim()) root.triggerSearch()
                  }
                }
              }
            }
          }
        }

        // ------------------ SORT DROPDOWN MENU ------------------
        BorderSurface {
          visible: root.sortDropdownOpen
          width: parent.width
          implicitHeight: sortListCol.implicitHeight + Style.space(8)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.foreground, root.foreground)
          borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)

          Column {
            id: sortListCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(4)
            spacing: Style.space(2)

            Repeater {
              model: root.sortList
              delegate: BorderSurface {
                readonly property bool isSelected: root.activeSort === modelData.id
                width: parent.width
                implicitHeight: Style.space(28)
                radius: Style.cornerRadius
                color: isSelected ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
                borderSpec: Border.controlSpec("normal", isSelected ? Color.accent : "transparent", Color.accent)

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: isSelected ? "" : "  "
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.icon + "  " + modelData.label
                    color: isSelected ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: isSelected
                  }

                  Item { Layout.fillWidth: true }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activeSort = modelData.id
                    root.sortDropdownOpen = false
                    if (searchInput.text.trim()) root.triggerSearch()
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
        }

        // ------------------ RESULTS LIST / EMPTY STATE ------------------
        Item {
          width: parent.width
          implicitHeight: Style.space(380)

          // State 1: Searching Spinner
          Column {
            visible: root.isSearching && root.resultsCount === 0
            anchors.centerIn: parent
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: ""
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              rotation: 0

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
                running: root.isSearching
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Querying multi-indexers..."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // State 2: No Search Query Yet (Welcome / Hints)
          Column {
            visible: !root.isSearching && root.resultsCount === 0 && !root.lastQuery
            anchors.centerIn: parent
            spacing: Style.space(8)
            width: parent.width * 0.85

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰚌"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Text {
              textFormat: Text.PlainText
              text: "Instant Torrent Search & Magnet Dispatcher"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "Type a title above and press Enter to search across ThePirateBay, LimeTorrents, YTS, EZTV, FitGirl, and Nyaa."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              width: parent.width
            }
          }

          // State 3: No Results Found for Query
          Column {
            visible: !root.isSearching && root.resultsCount === 0 && root.lastQuery !== ""
            anchors.centerIn: parent
            spacing: Style.space(6)
            width: parent.width * 0.85

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰛵"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              textFormat: Text.PlainText
              text: "No torrents found for '" + root.lastQuery + "'"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "Try different keywords, switch to 'All' category, or select 'All Indexers'."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              width: parent.width
            }
          }

          // State 4: Results List
          ListView {
            id: resultListView
            visible: root.resultsCount > 0
            anchors.fill: parent
            clip: true
            spacing: Style.space(6)
            model: root.searchResults

            delegate: BorderSurface {
              width: resultListView.width
              implicitHeight: itemCol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, root.foreground)
              borderSpec: Border.controlSpec("normal", root.dim, Color.accent)

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

                  // Provider badge
                  BorderSurface {
                    implicitWidth: provBadge.implicitWidth + Style.space(8)
                    implicitHeight: provBadge.implicitHeight + Style.space(3)
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", root.getProviderColor(modelData.provider_badge), Color.accent)
                    radius: Style.cornerRadius

                    Text {
                      id: provBadge
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: modelData.provider_badge
                      color: root.getProviderColor(modelData.provider_badge)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  // Category badge
                  BorderSurface {
                    implicitWidth: catBadge.implicitWidth + Style.space(8)
                    implicitHeight: catBadge.implicitHeight + Style.space(3)
                    color: "transparent"
                    borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
                    radius: Style.cornerRadius

                    Text {
                      id: catBadge
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: modelData.category || "General"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Item { Layout.fillWidth: true }

                  // Action 1: Copy Magnet
                  PanelActionButton {
                    iconText: "󰆏"
                    tooltipText: "Copy Magnet Link"
                    foreground: Color.accent
                    onClicked: root.copyMagnet(modelData.magnet, modelData.title)
                  }

                  // Action 2: Launch in Client
                  PanelActionButton {
                    iconText: "󰚌"
                    tooltipText: "Launch in Default Torrent Client"
                    foreground: "#87c095"
                    onClicked: root.launchTorrent(modelData.magnet, modelData.title)
                  }
                }

                // Row 2: Torrent Title
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }

                // Row 3: Metadata (Size, Seeds, Leechers, Date)
                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)

                  // Size
                  Row {
                    spacing: Style.space(3)
                    Text { textFormat: Text.PlainText; text: "󰉉"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Text { textFormat: Text.PlainText; text: modelData.size; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }

                  // Seeds
                  Row {
                    spacing: Style.space(3)
                    Text { textFormat: Text.PlainText; text: "󰜮"; color: "#87c095"; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Text { textFormat: Text.PlainText; text: modelData.seeds.toString(); color: "#87c095"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }

                  // Leechers
                  Row {
                    spacing: Style.space(3)
                    Text { textFormat: Text.PlainText; text: "󰜵"; color: "#e06c75"; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    Text { textFormat: Text.PlainText; text: modelData.leechers.toString(); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  }

                  Item { Layout.fillWidth: true }

                  // Date
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.date || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
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
          text: "Click 󰚌 to open in client · Click 󰆏 to copy magnet · Esc to close"
          color: Qt.darker(root.dim, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
