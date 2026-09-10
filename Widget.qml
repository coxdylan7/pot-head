import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PotHead.js" as Pot

BarWidget {
  id: root
  moduleName: "djc.pot-head"

  readonly property var service: {
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return null
    return bar.shell.serviceFor("djc.pot-head")
  }
  readonly property bool serviceReady: service !== null
  readonly property var closest: serviceReady ? service.closest : null
  readonly property bool hasLocation: serviceReady ? service.hasLocation : false

  property bool popupOpen: false

  readonly property string displayName: {
    if (!serviceReady) return "pot-head"
    if (!hasLocation) {
      if (service.locationStatus === "locating") return "Locating…"
      if (service.locationStatus === "error") return "No location"
      return "No location"
    }
    if (!closest) return "No dispensary"
    var n = String(closest.name || closest.entity || "Dispensary")
    if (n.length > 28) n = n.slice(0, 27) + "…"
    return n
  }

  implicitWidth: row.implicitWidth + Style.space(8) * 2
  implicitHeight: bar ? bar.barSize : 28

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      text: "🌿"
      color: bar ? bar.foreground : Color.foreground
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: label
      text: root.displayName
      color: bar ? bar.foreground : Color.foreground
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
      property int maxW: 220
      width: Math.min(implicitWidth, maxW)
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: root.popupOpen = !root.popupOpen
    onEntered: if (bar) bar.showTooltip(root, closest ? (Pot.buildAddress(closest) + " — " + (closest.distance || "") + " " + (service ? service.units : "mi")) : displayName)
    onExited: if (bar) bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.popupOpen
    contentWidth: Math.min(420, Math.max(360, popup.fittedContentWidth(Style.space(380))))
    contentHeight: popup.fittedContentHeight(col.implicitHeight + Style.space(16), Style.space(520))
    onVisibleChanged: if (!visible) root.popupOpen = false

    Column {
      id: col
      width: parent.width - Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(12)
      spacing: Style.space(10)

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.closest !== null
        Text {
          text: "Closest"
          color: Util.alpha(Color.foreground, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(Color.foreground, 0.1)
        }
        Column {
          width: parent.width
          spacing: 2
          Text {
            width: parent.width
            text: root.closest ? (root.closest.name || "") : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: root.closest ? Pot.buildAddress(root.closest) : ""
            color: Util.alpha(Color.foreground, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            wrapMode: Text.Wrap
          }
        }
      }

      Text {
        text: "Next 5 closest"
        color: Util.alpha(Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        visible: service && service.next5 && service.next5.length > 0
      }

      Repeater {
        model: service ? service.next5 : []
        delegate: Rectangle {
          id: rowDelegate
          required property var modelData
          required property int index
          width: col.width
          height: delegateCol.implicitHeight + Style.space(10) * 2
          radius: 10
          color: Util.alpha(Color.foreground, 0.04)
          border.width: 1
          border.color: Util.alpha(Color.foreground, 0.08)
          property var hoursInfo: Pot.parseHoursForToday(modelData.hours || "")
          property string distanceText: (modelData.distance || Pot.formatDistance(modelData.distanceMi, service ? service.units : "mi")) + " " + (service ? service.units : "mi")
          property string etaText: (modelData.etaMin && modelData.etaMin > 0) ? (modelData.etaMin + " min") : ""
          Column {
            id: delegateCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(4)
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: (index + 2) + ". " + (rowDelegate.modelData.name || "")
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
                width: parent.width - distanceBadge.width - 8
              }
              Rectangle {
                id: distanceBadge
                height: Style.space(18)
                width: distanceText.implicitWidth + 10
                radius: 8
                color: Util.alpha(Color.accent, 0.18)
                border.color: Util.alpha(Color.accent, 0.3)
                border.width: 1
                Text {
                  id: distanceText
                  anchors.centerIn: parent
                  text: rowDelegate.distanceText + (rowDelegate.etaText ? " • " + rowDelegate.etaText : "")
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: 10
                }
              }
            }
            Text {
              width: parent.width
              text: Pot.buildAddress(rowDelegate.modelData)
              color: Util.alpha(Color.foreground, 0.65)
              font.family: Style.font.family
              font.pixelSize: 11
              elide: Text.ElideRight
            }
            Row {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: rowDelegate.hoursInfo.today ? rowDelegate.hoursInfo.today : (rowDelegate.modelData.hours ? rowDelegate.modelData.hours.slice(0, 40) : "Hours unknown")
                color: rowDelegate.hoursInfo.openNow === true ? Color.accent : rowDelegate.hoursInfo.openNow === false ? Color.urgent : Util.alpha(Color.foreground, 0.6)
                font.family: Style.font.family
                font.pixelSize: 11
                elide: Text.ElideRight
                width: parent.width - openBadge.width - navBtn.width - siteBtn.width - 18
              }
              Rectangle {
                id: openBadge
                visible: rowDelegate.hoursInfo.openNow !== null
                height: 18
                width: 44
                radius: 8
                color: rowDelegate.hoursInfo.openNow ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.urgent, 0.18)
                border.color: rowDelegate.hoursInfo.openNow ? Util.alpha(Color.accent, 0.3) : Util.alpha(Color.urgent, 0.3)
                border.width: 1
                Text {
                  anchors.centerIn: parent
                  text: rowDelegate.hoursInfo.openNow ? "Open" : "Closed"
                  color: rowDelegate.hoursInfo.openNow ? Color.accent : Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: 10
                  font.bold: true
                }
              }
              Item { width: 4; height: 1 }
            }
            Row {
              width: parent.width
              spacing: Style.space(6)
              Button {
                id: navBtn
                text: "Navigate"
                iconText: ""
                foreground: Color.foreground
                horizontalPadding: 8
                verticalPadding: 4
                fontSize: 11
                iconSize: 11
                onClicked: {
                  if (service && service.openNavigation) service.openNavigation(rowDelegate.modelData)
                  root.popupOpen = false
                }
              }
              Button {
                id: siteBtn
                visible: rowDelegate.modelData.website && String(rowDelegate.modelData.website).trim().length > 0
                text: "Site"
                iconText: ""
                foreground: Color.foreground
                horizontalPadding: 8
                verticalPadding: 4
                fontSize: 11
                iconSize: 11
                onClicked: {
                  if (service && service.openSite) service.openSite(rowDelegate.modelData)
                }
              }
              Item { width: 1; height: 1 }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Tap row to navigate"
                color: Util.alpha(Color.foreground, 0.35)
                font.family: Style.font.family
                font.pixelSize: 10
                visible: !siteBtn.visible
              }
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (service && service.openNavigation) service.openNavigation(rowDelegate.modelData)
              root.popupOpen = false
            }
          }
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: !service || !service.hasLocation
        text: {
          if (!service) return "Loading pot-head…"
          if (service.locationStatus === "locating") return "Locating… allow Geoclue or check IP"
          if (service.locationStatus === "error") return "Location error: " + (service.locationError || "unknown") + "\nAdd locationOverrideLat/Lon in shell.json for testing"
          if (!service.hasLocation) return "No location yet"
          if (!service.dispensaries || service.dispensaries.length === 0) return "No dispensaries loaded — check NY API or cache"
          return ""
        }
        color: Util.alpha(Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: service && service.hasLocation && service.next5 && service.next5.length === 0 && service.closest !== null
        text: "Only one dispensary found nearby"
        color: Util.alpha(Color.foreground, 0.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        Text {
          text: service && service.lastFetchTime ? "Updated: " + service.lastFetchTime.slice(0,19).replace("T"," ") : "Never fetched"
          color: Util.alpha(Color.foreground, 0.4)
          font.family: Style.font.family
          font.pixelSize: 10
          elide: Text.ElideRight
          width: parent.width - refreshBtn.width - 8
        }
        Button {
          id: refreshBtn
          text: "Refresh"
          iconText: ""
          foreground: Color.foreground
          horizontalPadding: 8
          verticalPadding: 4
          fontSize: 10
          iconSize: 10
          onClicked: {
            if (service) {
              service.fetchDispensaries()
              service.fetchLocation()
            }
          }
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "Data: NYS OCM via data.ny.gov • tap Navigate for Google Maps, Site for dispensary website"
        color: Util.alpha(Color.foreground, 0.35)
        font.family: Style.font.family
        font.pixelSize: 9
        wrapMode: Text.Wrap
        visible: service && service.dispensaries.length > 0
      }
    }
  }
}
