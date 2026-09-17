import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// OmaVikunja bar widget — scaffold.
//
// This is the bar-icon-with-a-pulldown shape from omaipsum's BarWidget.qml,
// cut down to the smallest thing that loads: an icon on the bar, a pulldown
// that opens and closes, and a line saying what is not built yet. The real
// surfaces arrive with their issues (see the 0.1.0 milestone on GitHub).
Panel {
  id: root
  moduleName: "cschaba.omavikunja"
  ipcTarget: "cschaba.omavikunja.widget"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Connection and options live in ~/.config/omavikunja/config.json, not in
  // shell.json (docs/ARCHITECTURE.md, decision 1). Reading it arrives with the
  // connection-setup issue.
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omavikunja/config.json"

  // The bar sizes a slot from its widget's implicit size — a root that does
  // not publish one gets a 0x0 slot and renders nothing at all, silently.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- bar button -----------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // U+F0756 nf-md-format_list_checks, present in JetBrainsMono Nerd Font
    // (`fc-list :charset=f0756`).
    text: "󰝖"
    tooltipText: "Vikunja tasks"
    onPressed: function (b) {
      root.toggle()
    }
  }

  // --- pulldown -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "OmaVikunja"
          color: root.foreground
          font.family: root.fontFamily
          font.bold: true
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          text: "Not connected yet. Server URL and API token will be read from " + root.configPath + "."
        }
      }
    }
  }
}
