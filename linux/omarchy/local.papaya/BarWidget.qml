// local.papaya — PapayaPower in the Quickshell bar of Omarchy 4 (Waybar is gone there).
// Reads the same JSON as the Waybar module (`papaya --waybar`: text, tooltip, class) every
// 30 s; turns red (the bar's « urgent » colour) under 10 % or on UPS battery. A gauge out of
// calibration is said in the tooltip only: on a worn pack it is permanent, and a widget that
// is always red stops saying anything. Click: the PapayaPower window.
// Installed by linux/install.sh into ~/.config/omarchy/plugins/local.papaya/.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "local.papaya"

  property string label: "…"
  property string tip: "PapayaPower"
  property string cls: ""

  function parse(text) {
    try {
      var j = JSON.parse(text)
      root.label = j.text || "?"
      root.cls = j["class"] || ""
      // Waybar tooltips use Pango markup; the bar tooltip is plain text.
      root.tip = (j.tooltip || "").replace(/<[^>]*>/g, "") + "\nClick: PapayaPower"
    } catch (e) {
      root.label = "?"
      root.tip = "papaya --waybar failed: " + text
    }
  }

  Process {
    id: readProc
    command: ["bash", "-lc", "exec \"$HOME/.local/bin/papaya\" --waybar"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!readProc.running) readProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: root.cls === "critical" || root.cls === "ups-battery"
    tooltipText: root.tip
    onPressed: function() { root.bar.run("\"$HOME/.local/bin/papayapower\"") }
  }
}
