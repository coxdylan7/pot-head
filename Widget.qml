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
  property var selectedDetail: null
  property bool detailOpen: false

  function openDetail(d) { selectedDetail = d; detailOpen = true }
  function closeDetail() { detailOpen = false }

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

  implicitWidth: Math.max(row.implicitWidth + Style.space(12) * 2, Style.bar.statusSlot + Style.space(8))
  implicitHeight: bar ? bar.barSize : 28

  property var icons: ["🌿", "🔥", "💨", "✨"]
  property int iconIndex: 0
  Timer {
    id: iconCycle
    interval: 1800
    running: true
    repeat: true
    onTriggered: root.iconIndex = (root.iconIndex + 1) % root.icons.length
  }

  // Background hit area to make click reliable across full slot
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    radius: 6
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: iconText
      text: root.icons[root.iconIndex]
      color: bar ? bar.foreground : Color.foreground
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
      Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
      onTextChanged: {
        opacity = 0
        iconFade.restart()
      }
    }

    Timer {
      id: iconFade
      interval: 50
      onTriggered: iconText.opacity = 1
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

  // Hover to show — no click needed
  HoverHandler {
    id: hoverHandler
    onHoveredChanged: {
      if (hovered) root.popupOpen = true
      else if (!popup.containsMouse) root.popupOpen = false
    }
  }
  MouseArea {
    anchors.fill: parent
    z: 10
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.NoButton
    propagateComposedEvents: true
    onEntered: {
      root.popupOpen = true
      if (bar) bar.showTooltip(root, closest ? (Pot.buildAddress(closest) + " — " + (closest.distance || "") + " " + (service ? service.units : "mi")) : displayName)
    }
    onExited: {
      if (!popup.containsMouse) root.popupOpen = false
      if (bar) bar.hideTooltip(root)
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.popupOpen
    triggerMode: "hover"
    contentWidth: Math.min(460, Math.max(380, popup.fittedContentWidth(Style.space(420))))
    contentHeight: popup.fittedContentHeight(flick.contentHeight + Style.space(24), Style.space(860))
    onVisibleChanged: if (!visible) root.popupOpen = false
    onContainsMouseChanged: {
      if (containsMouse) root.popupOpen = true
      else if (!hoverHandler.hovered) root.popupOpen = false
    }

    Flickable {
      id: flick
      width: parent.width - Style.space(16)
      height: Math.min(col.implicitHeight, Style.space(820))
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(12)
      contentHeight: col.implicitHeight
      clip: true
      flickableDirection: Flickable.VerticalFlick
      interactive: col.implicitHeight > height
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: col
        width: parent.width
        spacing: Style.space(10)

        // Closest - same format as Next 5 (hours, badges, Navigate/Site)
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
          Rectangle {
            id: closestRect
            width: parent.width
            height: closestCol.implicitHeight + Style.space(10) * 2
            radius: 10
            color: Util.alpha(Color.accent, 0.07)
            border.width: 1
            border.color: Util.alpha(Color.accent, 0.22)
            property var hoursInfo: Pot.parseHoursForToday(root.closest ? (root.closest.hours || "") : "")
            property string distanceText: root.closest ? ((root.closest.distance || Pot.formatDistance(root.closest.distanceMi, service ? service.units : "mi")) + " " + (service ? service.units : "mi")) : ""
            property string etaText: (root.closest && root.closest.etaMin && root.closest.etaMin > 0) ? (root.closest.etaMin + " min") : ""
            Column {
              id: closestCol
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
                  text: "1. " + (root.closest ? (root.closest.name || "") : "")
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width - closestBadge.width - 8
                }
                Rectangle {
                  id: closestBadge
                  height: Style.space(18)
                  width: closestDistanceText.implicitWidth + 10
                  radius: 8
                  color: Util.alpha(Color.accent, 0.18)
                  border.color: Util.alpha(Color.accent, 0.3)
                  border.width: 1
                  Text {
                    id: closestDistanceText
                    anchors.centerIn: parent
                    text: closestRect.distanceText + (closestRect.etaText ? " • " + closestRect.etaText : "")
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: 10
                  }
                }
              }
              Text {
                width: parent.width
                text: root.closest ? Pot.buildAddress(root.closest) : ""
                color: Util.alpha(Color.foreground, 0.65)
                font.family: Style.font.family
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Row {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  text: closestRect.hoursInfo.today ? closestRect.hoursInfo.today : (root.closest && root.closest.hours ? root.closest.hours.slice(0, 44) : "Hours unknown")
                  color: closestRect.hoursInfo.openNow === true ? Color.accent : closestRect.hoursInfo.openNow === false ? Color.urgent : Util.alpha(Color.foreground, 0.6)
                  font.family: Style.font.family
                  font.pixelSize: 11
                  elide: Text.ElideRight
                  width: parent.width - closestOpenBadge.width - Style.space(12)
                }
                Rectangle {
                  id: closestOpenBadge
                  visible: closestRect.hoursInfo.openNow !== null
                  height: 18
                  width: 44
                  radius: 8
                  color: closestRect.hoursInfo.openNow ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.urgent, 0.18)
                  border.color: closestRect.hoursInfo.openNow ? Util.alpha(Color.accent, 0.3) : Util.alpha(Color.urgent, 0.3)
                  border.width: 1
                  Text {
                    anchors.centerIn: parent
                    text: closestRect.hoursInfo.openNow ? "Open" : "Closed"
                    color: closestRect.hoursInfo.openNow ? Color.accent : Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: 10
                    font.bold: true
                  }
                }
              }
              Row {
                width: parent.width
                spacing: Style.space(6)
                Button {
                  text: "Navigate"
                  iconText: ""
                  foreground: Color.foreground
                  horizontalPadding: 8
                  verticalPadding: 4
                  fontSize: 11
                  iconSize: 11
                  onClicked: { if (service && service.openNavigation) service.openNavigation(root.closest); root.popupOpen = false }
                }
                Button {
                  visible: root.closest && root.closest.website && String(root.closest.website).trim().length > 0
                  text: "Site"
                  iconText: ""
                  foreground: Color.foreground
                  horizontalPadding: 8
                  verticalPadding: 4
                  fontSize: 11
                  iconSize: 11
                  onClicked: { if (service && service.openSite) service.openSite(root.closest) }
                }
                Button {
                  text: "Details"
                  iconText: ""
                  foreground: Color.foreground
                  horizontalPadding: 8
                  verticalPadding: 4
                  fontSize: 11
                  iconSize: 11
                  onClicked: root.openDetail(root.closest)
                }
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openDetail(root.closest)
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
                  text: rowDelegate.hoursInfo.today ? rowDelegate.hoursInfo.today : (rowDelegate.modelData.hours ? rowDelegate.modelData.hours.slice(0, 44) : "Hours unknown")
                  color: rowDelegate.hoursInfo.openNow === true ? Color.accent : rowDelegate.hoursInfo.openNow === false ? Color.urgent : Util.alpha(Color.foreground, 0.6)
                  font.family: Style.font.family
                  font.pixelSize: 11
                  elide: Text.ElideRight
                  width: parent.width - openBadge.width - Style.space(6)
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
                Button {
                  text: "Details"
                  iconText: ""
                  foreground: Color.foreground
                  horizontalPadding: 8
                  verticalPadding: 4
                  fontSize: 11
                  iconSize: 11
                  onClicked: root.openDetail(rowDelegate.modelData)
                }
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openDetail(rowDelegate.modelData)
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
            if (service.locationStatus === "locating") return "Locating… install geoclue for precise GPS or set locationOverrideLat/Lon in shell.json"
            if (service.locationStatus === "error") return "Location error: " + (service.locationError || "unknown") + "\nSet locationOverrideLat/Lon in shell.json or install geoclue (IP fallback accuracy ~5km)"
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

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(Color.foreground, 0.08)
          visible: service && service.dispensaries.length > 0
        }

        // Fixed footer: Updated time - shortened to avoid cutoff, with source+accuracy
        Column {
          width: parent.width
          spacing: Style.space(4)
          Row {
            width: parent.width
            spacing: Style.space(8)
            anchors.verticalCenter: undefined
            Text {
              width: parent.width - refreshBtn.width - Style.space(8)
              text: {
                if (!service || !service.lastFetchTime) return "Never fetched"
                var t = String(service.lastFetchTime)
                // shorten: MM-DD HH:MM instead of full ISO
                var s = t.slice(0,16).replace("T"," ")
                if (s.length>16) s = t.slice(5,16).replace("T"," ")
                var src = service && service.accuracy ? (" • " + service.accuracy.toFixed(0) + "m via " + (service.locationStatus==="found" && service.accuracy ? (service.locationStatus) : "")) : ""
                // show source if available
                var locSrc = ""
                if (service && service.accuracy) locSrc = " • " + Math.round(service.accuracy) + "m"
                return "Updated: " + s + locSrc
              }
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: 10
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
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
            text: service && service.accuracy ? ("Location: " + (service.closest ? Pot.buildAddress(service.closest).split(",").slice(-2).join(",") : "") + " • source: " + (service.locationStatus==="found" ? "GPS/IP" : service.locationStatus) + (service.accuracy ? " ±" + Math.round(service.accuracy) + "m" : "")) : ""
            color: Util.alpha(Color.foreground, 0.32)
            font.family: Style.font.family
            font.pixelSize: 9
            elide: Text.ElideRight
            visible: service && service.hasLocation && service.accuracy
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Data: NYS OCM via data.ny.gov • tap row for full details • Navigate → Google Maps"
          color: Util.alpha(Color.foreground, 0.35)
          font.family: Style.font.family
          font.pixelSize: 9
          wrapMode: Text.Wrap
          visible: service && service.dispensaries.length > 0
        }
      }
    }
  }

  // Expanded detail window - full dataset on selection
  PopupCard {
    id: detailPopup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.detailOpen
    contentWidth: Math.min(520, Math.max(420, detailPopup.fittedContentWidth(Style.space(460))))
    contentHeight: detailPopup.fittedContentHeight(detailFlick.contentHeight + Style.space(16), Style.space(580))
    onVisibleChanged: if (!visible) root.detailOpen = false

    Flickable {
      id: detailFlick
      width: parent.width - Style.space(16)
      height: Math.min(detailCol.implicitHeight, Style.space(556))
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(12)
      contentHeight: detailCol.implicitHeight
      clip: true
      flickableDirection: Flickable.VerticalFlick
      interactive: detailCol.implicitHeight > height
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: detailCol
        width: parent.width
        spacing: Style.space(10)
        visible: root.selectedDetail !== null

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: root.selectedDetail ? (root.selectedDetail.name || "Dispensary") : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.titleSmall || 15
            font.bold: true
            elide: Text.ElideRight
            width: parent.width - closeDetailBtn.width - Style.space(8)
          }
          Button {
            id: closeDetailBtn
            text: "Close"
            iconText: ""
            foreground: Color.foreground
            horizontalPadding: 8
            verticalPadding: 4
            fontSize: 11
            iconSize: 11
            onClicked: root.closeDetail()
          }
        }

        Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.foreground, 0.1) }

        // Address + distance
        Column {
          width: parent.width
          spacing: Style.space(4)
          Text {
            width: parent.width
            text: root.selectedDetail ? Pot.buildAddress(root.selectedDetail) : ""
            color: Util.alpha(Color.foreground, 0.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.selectedDetail && root.selectedDetail.distance
            Rectangle {
              height: Style.space(18)
              width: dDist.implicitWidth + 12
              radius: 8
              color: Util.alpha(Color.accent, 0.18)
              border.color: Util.alpha(Color.accent, 0.3)
              border.width: 1
              Text { id: dDist; anchors.centerIn: parent; text: root.selectedDetail ? ((root.selectedDetail.distance || Pot.formatDistance(root.selectedDetail.distanceMi, service ? service.units : "mi")) + " " + (service ? service.units : "mi") + (root.selectedDetail.etaMin ? " • " + root.selectedDetail.etaMin + " min" : "")) : ""; color: Color.accent; font.family: Style.font.family; font.pixelSize: 10 }
            }
            Text {
              text: root.selectedDetail && root.selectedDetail.county ? root.selectedDetail.county + " • " + (root.selectedDetail.region || "") : ""
              color: Util.alpha(Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: 10
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Text {
            width: parent.width
            text: root.selectedDetail && root.selectedDetail.raw && root.selectedDetail.raw.georeference ? (root.selectedDetail.lat.toFixed(5) + ", " + root.selectedDetail.lon.toFixed(5)) : ""
            color: Util.alpha(Color.foreground, 0.35)
            font.family: Style.font.family
            font.pixelSize: 10
          }
        }

        // Hours — readable weekly table
        Column {
          width: parent.width
          spacing: Style.space(6)
          Row {
            width: parent.width
            spacing: Style.space(8)
            Text { text: "Hours"; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
            Rectangle {
              visible: root.selectedDetail && Pot.parseHoursForToday(root.selectedDetail.hours || "").openNow !== null
              height: 18
              width: 72
              radius: 8
              color: Pot.parseHoursForToday(root.selectedDetail ? (root.selectedDetail.hours || "") : "").openNow ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.urgent, 0.18)
              border.color: Pot.parseHoursForToday(root.selectedDetail ? (root.selectedDetail.hours || "") : "").openNow ? Util.alpha(Color.accent, 0.3) : Util.alpha(Color.urgent, 0.3)
              border.width: 1
              Text { anchors.centerIn: parent; text: Pot.parseHoursForToday(root.selectedDetail ? (root.selectedDetail.hours || "") : "").openNow ? "Open now" : "Closed now"; color: Pot.parseHoursForToday(root.selectedDetail ? (root.selectedDetail.hours || "") : "").openNow ? Color.accent : Color.urgent; font.family: Style.font.family; font.pixelSize: 10; font.bold: true }
            }
            Text {
              visible: root.selectedDetail && Pot.parseHoursForToday(root.selectedDetail.hours || "").today
              text: Pot.parseHoursForToday(root.selectedDetail ? (root.selectedDetail.hours || "") : "").today
              color: Util.alpha(Color.foreground, 0.55)
              font.family: Style.font.family
              font.pixelSize: 10
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 80 - 72 - Style.space(16)
            }
          }
          Rectangle {
            width: parent.width
            radius: 8
            color: Util.alpha(Color.foreground, 0.04)
            border.color: Util.alpha(Color.foreground, 0.08)
            border.width: 1
            visible: root.selectedDetail && root.selectedDetail.hours && String(root.selectedDetail.hours).trim().length > 0
            height: weeklyCol.implicitHeight + Style.space(10)
            Column {
              id: weeklyCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.topMargin: Style.space(6)
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: 2
              Repeater {
                model: root.selectedDetail ? Pot.parseWeeklyHours(root.selectedDetail.hours || "") : []
                delegate: Rectangle {
                  required property var modelData
                  width: weeklyCol.width - Style.space(20)
                  height: 22
                  radius: 6
                  color: modelData.isToday ? Util.alpha(Color.accent, 0.12) : "transparent"
                  border.color: modelData.isToday ? Util.alpha(Color.accent, 0.22) : "transparent"
                  border.width: modelData.isToday ? 1 : 0
                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)
                    Text {
                      text: modelData.day
                      color: modelData.isToday ? Color.accent : Util.alpha(Color.foreground, 0.85)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      font.bold: modelData.isToday
                      width: 36
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: modelData.hours
                      color: modelData.isToday ? Color.foreground : Util.alpha(Color.foreground, 0.65)
                      font.family: Style.font.family
                      font.pixelSize: 11
                      elide: Text.ElideRight
                      width: parent.width - 44
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }
          }
          Text {
            visible: !root.selectedDetail || !root.selectedDetail.hours || String(root.selectedDetail.hours).trim().length === 0
            text: "Hours unknown"
            color: Util.alpha(Color.foreground, 0.5)
            font.family: Style.font.family
            font.pixelSize: 11
          }
        }

        // Contact / Website
        Column {
          width: parent.width
          spacing: 2
          visible: root.selectedDetail && (root.selectedDetail.website || (root.selectedDetail.raw && root.selectedDetail.raw.primary_contact_name))
          Text { text: "Contact"; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
          Text {
            width: parent.width
            text: root.selectedDetail && root.selectedDetail.website ? root.selectedDetail.website : ""
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: 11
            elide: Text.ElideRight
            visible: root.selectedDetail && root.selectedDetail.website
          }
          Text {
            width: parent.width
            text: root.selectedDetail && root.selectedDetail.raw ? ("Contact: " + (root.selectedDetail.raw.primary_contact_name || "")) : ""
            color: Util.alpha(Color.foreground, 0.6)
            font.family: Style.font.family
            font.pixelSize: 11
            elide: Text.ElideRight
            visible: root.selectedDetail && root.selectedDetail.raw && root.selectedDetail.raw.primary_contact_name
          }
          Text {
            width: parent.width
            text: root.selectedDetail && root.selectedDetail.raw && root.selectedDetail.raw.see_category ? ("Category: " + root.selectedDetail.raw.see_category) : ""
            color: Util.alpha(Color.foreground, 0.5)
            font.family: Style.font.family
            font.pixelSize: 10
            wrapMode: Text.Wrap
          }
        }

        // License details - full dataset
        Column {
          width: parent.width
          spacing: 2
          Text { text: "License / Status"; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: 2
            Text { Layout.fillWidth: true; text: root.selectedDetail && root.selectedDetail.raw ? ("License: " + (root.selectedDetail.raw.license_number || root.selectedDetail.license || "")) : ""; color: Util.alpha(Color.foreground, 0.7); font.family: Style.font.family; font.pixelSize: 10; elide: Text.ElideRight }
            Text { Layout.fillWidth: true; text: root.selectedDetail && root.selectedDetail.raw ? ("Type: " + (root.selectedDetail.raw.license_type || "")) : ""; color: Util.alpha(Color.foreground, 0.7); font.family: Style.font.family; font.pixelSize: 10; elide: Text.ElideRight }
            Text { Layout.fillWidth: true; text: root.selectedDetail && root.selectedDetail.raw ? ("Status: " + (root.selectedDetail.raw.license_status || "") + " / " + (root.selectedDetail.raw.operational_status || "")) : ""; color: Util.alpha(Color.foreground, 0.7); font.family: Style.font.family; font.pixelSize: 10; elide: Text.ElideRight }
            Text { Layout.fillWidth: true; text: root.selectedDetail && root.selectedDetail.raw ? ("Issued: " + (root.selectedDetail.raw.issued_date ? String(root.selectedDetail.raw.issued_date).slice(0,10) : "")) : ""; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: 10; elide: Text.ElideRight }
            Text { Layout.fillWidth: true; text: root.selectedDetail && root.selectedDetail.raw ? ("Expires: " + (root.selectedDetail.raw.expiration_date ? String(root.selectedDetail.raw.expiration_date).slice(0,10) : "")) : ""; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: 10; elide: Text.ElideRight }
            Text { Layout.fillWidth: true; text: root.selectedDetail && root.selectedDetail.raw ? ("Opened: " + (root.selectedDetail.raw.retail_date_opened_to_public ? String(root.selectedDetail.raw.retail_date_opened_to_public).slice(0,10) : "")) : ""; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: 10; elide: Text.ElideRight }
          }
          Text {
            width: parent.width
            text: root.selectedDetail && root.selectedDetail.raw ? ("ID: " + (root.selectedDetail.raw.location_id || root.selectedDetail.id || "")) : ""
            color: Util.alpha(Color.foreground, 0.35)
            font.family: Style.font.family
            font.pixelSize: 9
            elide: Text.ElideRight
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: {
                var r = root.selectedDetail && root.selectedDetail.raw ? root.selectedDetail.raw : null
                if (!r) return []
                var tags=[]
                if (r.retail_activities_sales_with==="1") tags.push("Sales w/ cannabis")
                if (r.retail_activities_non_cannabis==="1") tags.push("Non-cannabis")
                if (r.retail_activities_drive_thru==="1") tags.push("Drive-thru")
                return tags
              }
              delegate: Rectangle {
                required property string modelData
                height: 16
                width: tagTxt.implicitWidth + 8
                radius: 6
                color: Util.alpha(Color.foreground, 0.06)
                border.color: Util.alpha(Color.foreground, 0.08)
                border.width: 1
                Text { id: tagTxt; anchors.centerIn: parent; text: parent.modelData; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: 9 }
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Button {
            text: "Navigate"
            iconText: ""
            foreground: Color.foreground
            horizontalPadding: 10
            verticalPadding: 6
            fontSize: 11
            iconSize: 11
            onClicked: { if (root.selectedDetail && service && service.openNavigation) service.openNavigation(root.selectedDetail) }
          }
          Button {
            visible: root.selectedDetail && root.selectedDetail.website && String(root.selectedDetail.website).trim().length>0
            text: "Visit Site"
            iconText: ""
            foreground: Color.foreground
            horizontalPadding: 10
            verticalPadding: 6
            fontSize: 11
            iconSize: 11
            onClicked: { if (root.selectedDetail && service && service.openSite) service.openSite(root.selectedDetail) }
          }
          Button {
            text: "Copy Address"
            iconText: ""
            foreground: Color.foreground
            horizontalPadding: 10
            verticalPadding: 6
            fontSize: 11
            iconSize: 11
            onClicked: {
              if (root.selectedDetail) {
                var addr = Pot.buildAddress(root.selectedDetail)
                // use clipboard via xdg? simple: copy via process
                // fallback: open with xclip if available
                Quickshell.execDetached(["bash","-c","echo -n '" + addr.replace(/'/g,"'\\''") + "' | xclip -selection clipboard 2>/dev/null || echo -n '" + addr.replace(/'/g,"'\\''") + "' | wl-copy 2>/dev/null || true"])
              }
            }
          }
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Full dataset from NYS OCM • license " + (root.selectedDetail && root.selectedDetail.license ? root.selectedDetail.license : "")
          color: Util.alpha(Color.foreground, 0.3)
          font.family: Style.font.family
          font.pixelSize: 9
        }
      }
    }
  }
}
