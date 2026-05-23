/**
 * Copyright (C) 2026 Jaroslav Reznik
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami
import org.kde.plasma.extras as PlasmaExtras
import org.kde.networkmanager as NM
import org.kde.plasma.networkmanagement as PlasmaNM

PlasmoidItem {
    id: root

    Plasmoid.icon: ""


    toolTipMainText: i18n("Gemini Usage Monitor")
    toolTipSubText: {
        if (root.status === "success") {
            var resetLabel5h = root.fiveHourResetEpoch > 0 ? ("\nResets at: " + root.formatResetTime(root.fiveHourResetEpoch)) : ""
            var resetLabelWk = root.weeklyResetEpoch > 0 ? ("\nWeekly resets: " + root.formatResetTime(root.weeklyResetEpoch)) : ""
            return i18n("Rolling 5-Hour: %1%\nWeekly: %2%", root.fiveHourPct, root.weeklyPct) + resetLabel5h + resetLabelWk + "\n(Scroll to toggle view)"
        } else if (root.status === "auth_error") {
            return i18n("Authentication Required\nUpdate cookies in widget settings.")
        } else {
            return i18n("Loading or Offline\n%1", root.errorMessage)
        }
    }

    // Default widget dimensions (used when placed on the desktop)
    width: Kirigami.Units.gridUnit * 20
    height: Kirigami.Units.gridUnit * 16

    // State Variables
    property int fiveHourPct: 0
    property int weeklyPct: 0
    property string countdown: "Active"
    property string status: "loading" // loading, success, auth_error, error
    property string errorMessage: ""
    property bool isSyncing: false
    property string lastUpdated: "--:--"
    property bool isUpdatingConfigFromLogin: false

    // Reset time fields (epoch seconds, 0 = unknown)
    property real fiveHourResetEpoch: 0
    property real weeklyResetEpoch: 0

    // Compact view scroll state
    property bool compactShowWeekly: false

    // Resolved icon source properties to avoid QML icon loader binding loops
    readonly property string compactIconSource: root.status === "auth_error" ? "dialog-warning" : (root.status === "error" ? "network-disconnect" : Qt.resolvedUrl("../icons/gemini.svg"))
    readonly property string errorIconSource: root.status === "auth_error" ? "dialog-warning" : "network-disconnect"

    // Configuration binding
    readonly property string cookie: plasmoid.configuration.cookie || ""
    readonly property string userAgent: plasmoid.configuration.userAgent || ""
    readonly property int updateInterval: plasmoid.configuration.updateInterval || 900

    // Scraper Script Path resolved dynamically (compatible with store installations)
    readonly property string scraperPath: Qt.resolvedUrl("../../get_usage.js").toString().replace("file://", "")

    // Listen to changes to sync the python scraper config
    onCookieChanged: syncConfig()
    onUserAgentChanged: syncConfig()
    onUpdateIntervalChanged: syncConfig()

    // Adaptive representation: use full view on desktop (Planar = 0), compact on panels (Horizontal = 1, Vertical = 2)
    preferredRepresentation: plasmoid.formFactor !== 0
        ? root.compactRepresentation
        : root.fullRepresentation

    Component.onCompleted: {
        syncConfig()
    }

    // Watchdog timer to prevent the widget from freezing if a fetch process hangs
    Timer {
        id: watchdogTimer
        interval: 120000 // 2 minutes (standard scrape)
        running: false
        repeat: false
        onTriggered: {
            console.warn("Gemini Usage Watcher: Fetch process timed out!");
            root.isSyncing = false;
            root.status = "error";
            root.errorMessage = i18n("Connection timed out. Retrying later.");
            // Disconnect active sources to clean up
            executable.connectedSources.forEach(function(src) {
                executable.disconnectSource(src);
            });
        }
    }

    // Timer for periodic polling
    Timer {
        id: pollTimer
        interval: Math.max(300, root.updateInterval) * 1000 // Minimum 5 mins
        running: true
        repeat: true
        onTriggered: triggerFetch()
    }

    // Watch for network availability changes (e.g. waking up from suspend or connecting to Wi-Fi)
    PlasmaNM.NetworkStatus {
        id: networkStatus

        // Trigger an immediate refresh when the network becomes fully connected/available
        onConnectivityChanged: {
            if (networkStatus.connectivity === NM.NetworkManager.Full) {
                root.triggerFetch();
            }
        }
    }

    // Executable engine to run the python script
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            watchdogTimer.stop()
            // Reset interval back to standard 2 minutes
            watchdogTimer.interval = 120000

            var exitCode = data["exit code"]
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""

            disconnectSource(sourceName)

            // Robust checks to detect missing system dependencies gracefully
            var nodeMissing = (exitCode === 127 || 
                               stderr.indexOf("node: command not found") !== -1 || 
                               stderr.indexOf("node: not found") !== -1 ||
                               stderr.indexOf("executable not found") !== -1 ||
                               (exitCode !== 0 && stdout.trim() === "" && stderr.trim() === ""));

            var depsMissing = (stderr.indexOf("Cannot find module 'puppeteer-core'") !== -1 || 
                               stderr.indexOf("Cannot find module") !== -1);

            var chromeMissing = (stderr.indexOf("Could not find Chrome") !== -1 || 
                                 stderr.indexOf("executablePath") !== -1 || 
                                 stderr.indexOf("Failed to launch the browser process") !== -1);

            if (nodeMissing) {
                root.isSyncing = false
                root.status = "error"
                root.errorMessage = i18n("Node.js is not installed. Please install 'nodejs' and 'npm' via your system package manager (e.g. 'sudo dnf install nodejs' on Fedora) to run the scraper.")
                return
            }

            if (depsMissing) {
                root.isSyncing = false
                root.status = "error"
                var widgetFolder = Qt.resolvedUrl("../../").toString().replace("file://", "")
                root.errorMessage = i18n("Missing dependencies. Please run 'npm install' in the widget folder to install Puppeteer:\n%1", widgetFolder)
                return
            }

            if (chromeMissing) {
                root.isSyncing = false
                root.status = "error"
                root.errorMessage = i18n("Google Chrome/Chromium could not be launched. Please install Google Chrome or Chromium via your system package manager.")
                return
            }

            if (exitCode !== 0 && sourceName.indexOf("--save-config") === -1) {
                root.isSyncing = false
                root.status = "error"
                root.errorMessage = i18n("Execution error (Exit code: %1). Details: %2", exitCode, stderr.trim() || i18n("Unknown error"))
                return
            }

            if (sourceName.indexOf("--save-config") !== -1) {
                // Config synced successfully, trigger initial fetch
                triggerFetch()
                return
            }

            if (sourceName.indexOf("--login") !== -1) {
                root.isSyncing = false
                try {
                    var cleaned = stdout.trim()
                    var res = JSON.parse(cleaned)

                    if (res.status === "success") {
                        root.status = "loading"
                        root.errorMessage = i18n("Sign-in successful! Fetching usage...")
                        
                        root.isUpdatingConfigFromLogin = true
                        plasmoid.configuration.cookie = res.cookie
                        plasmoid.configuration.userAgent = res.user_agent
                        root.isUpdatingConfigFromLogin = false
                        
                        triggerFetch()
                    } else {
                        root.status = "auth_error"
                        root.errorMessage = res.message || i18n("Sign-in cancelled or failed.")
                    }
                } catch (e) {
                    root.status = "error"
                    root.errorMessage = i18n("Failed to process interactive sign-in response.")
                    console.warn("Raw stdout:", stdout)
                    console.warn("Raw stderr:", stderr)
                }
                return
            }

            root.isSyncing = false
            try {
                var cleaned = stdout.trim()
                var res = JSON.parse(cleaned)

                if (res.status === "success") {
                    root.fiveHourPct = res.five_hour_pct
                    root.weeklyPct = res.weekly_pct
                    root.countdown = res.countdown
                    root.fiveHourResetEpoch = res.five_hour_reset_epoch || 0
                    root.weeklyResetEpoch = res.weekly_reset_epoch || 0
                    root.status = "success"
                    root.errorMessage = ""

                    var d = new Date()
                    root.lastUpdated = d.getHours().toString().padStart(2, '0') + ":" +
                                  d.getMinutes().toString().padStart(2, '0')
                } else if (res.status === "auth_error") {
                    root.status = "auth_error"
                    root.errorMessage = res.message
                } else {
                    root.status = "error"
                    root.errorMessage = res.message || i18n("Scraping error occurred.")
                }
            } catch (e) {
                root.status = "error"
                root.errorMessage = i18n("Failed to parse scraping response.")
                console.warn("Raw stdout:", stdout)
                console.warn("Raw stderr:", stderr)
            }
        }
    }

    // Sync QML config to Python script config.json
    function syncConfig() {
        if (root.isUpdatingConfigFromLogin) return
        var c = root.cookie || ""
        var ua = root.userAgent || ""
        var exp = root.updateInterval || 900
        var escapedCookie = c.toString().replace(/'/g, "'\\''")
        var escapedUA = ua.toString().replace(/'/g, "'\\''")
        var cmd = "node " + root.scraperPath + " --save-config --cookie '" + escapedCookie + "' --user-agent '" + escapedUA + "' --expiry " + exp
        executable.connectSource(cmd)
    }

    // Trigger interactive sign-in flow
    function triggerLogin() {
        if (root.isSyncing) return
        root.isSyncing = true
        // For interactive login, the user might take longer, so let's allow 6 minutes
        watchdogTimer.interval = 360000
        watchdogTimer.start()
        root.status = "loading"
        root.errorMessage = i18n("Interactive browser opened. Please sign in to Google Chrome.")
        var cmd = "node " + root.scraperPath + " --login"
        executable.connectSource(cmd)
    }

    // Fetch fresh stats via get_usage.js
    function triggerFetch() {
        if (root.isSyncing) return
        root.isSyncing = true
        watchdogTimer.interval = 120000
        watchdogTimer.start()
        var cmd = "node " + root.scraperPath
        executable.connectSource(cmd)
    }

    // Format an epoch timestamp as a human-readable reset time string
    function formatResetTime(epochSec) {
        if (!epochSec || epochSec <= 0) return i18n("Unknown")
        var now = Date.now() / 1000
        var diff = epochSec - now
        if (diff <= 0) return i18n("Imminent")

        var totalMins = Math.round(diff / 60)
        var hours = Math.floor(totalMins / 60)
        var mins = totalMins % 60

        // Also build the clock time string
        var resetDate = new Date(epochSec * 1000)
        var hh = resetDate.getHours().toString().padStart(2, '0')
        var mm = resetDate.getMinutes().toString().padStart(2, '0')
        var timeStr = hh + ":" + mm

        // If more than 23 hours away, show date too
        if (diff > 23 * 3600) {
            var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
            var dateStr = resetDate.getDate() + " " + months[resetDate.getMonth()]
            return i18n("%1 at %2", dateStr, timeStr)
        }
        return timeStr
    }

    // Remaining time label (e.g. "in 3h 20m")
    function formatRemaining(epochSec) {
        if (!epochSec || epochSec <= 0) return ""
        var now = Date.now() / 1000
        var diff = epochSec - now
        if (diff <= 0) return i18n("now")
        var totalMins = Math.round(diff / 60)
        var hours = Math.floor(totalMins / 60)
        var mins = totalMins % 60
        if (hours > 0 && mins > 0) return i18n("in %1h %2m", hours, mins)
        if (hours > 0) return i18n("in %1h", hours)
        return i18n("in %1m", mins)
    }

    // ==========================================
    // COMPACT REPRESENTATION (Panel Mode)
    // ==========================================
    compactRepresentation: MouseArea {
        id: compactMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        property int wheelDelta: 0

        // Scroll wheel switches between 5-hour and weekly display
        onWheel: wheel => {
            // Magic number 120 for common "one click" scroll step
            // Accumulate delta and switch view based on scroll direction to prevent rapid toggling/blinking
            wheelDelta += (wheel.inverted ? -1 : 1) * (wheel.angleDelta.y ? wheel.angleDelta.y : wheel.angleDelta.x);
            if (wheelDelta >= 120) {
                wheelDelta = 0;
                root.compactShowWeekly = true;
            } else if (wheelDelta <= -120) {
                wheelDelta = 0;
                root.compactShowWeekly = false;
            }
        }

        // Compact layout wrapper
        Item {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height) - Kirigami.Units.smallSpacing
            height: width

            // Circular visual progress arc
            Canvas {
                id: ringCanvas
                anchors.fill: parent
                rotation: -90 // Arc starts from 12 o'clock

                property real value: root.compactShowWeekly ? (root.weeklyPct / 100.0) : (root.fiveHourPct / 100.0)

                onValueChanged: requestPaint()

                Behavior on value {
                    NumberAnimation { duration: 400; easing.type: Easing.OutQuad }
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)

                    var cx = width / 2
                    var cy = height / 2
                    var radius = (width / 2) - 3

                    // Background circle
                    ctx.beginPath()
                    ctx.arc(cx, cy, radius, 0, 2 * Math.PI)
                    ctx.strokeStyle = Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
                    ctx.lineWidth = 3
                    ctx.stroke()

                    // Current usage arc
                    if (root.status === "success" && value > 0) {
                        ctx.beginPath()
                        ctx.arc(cx, cy, radius, 0, 2 * Math.PI * value)

                        var activeColor = root.compactShowWeekly 
                            ? Qt.color("#b388ff") // Distinct Purple for Weekly
                            : (value < 0.5 ? Kirigami.Theme.positiveTextColor : (value < 0.8 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.negativeTextColor))

                        var grad = ctx.createLinearGradient(0, 0, width, height)
                        grad.addColorStop(0, activeColor.toString())
                        grad.addColorStop(1, root.compactShowWeekly 
                            ? Qt.color("#8c52ff").toString() // Gradient to deeper violet
                            : Qt.rgba(activeColor.r * 0.8, activeColor.g * 0.8, activeColor.b * 0.8, 1.0).toString())

                        ctx.strokeStyle = grad
                        ctx.lineWidth = 3
                        ctx.lineCap = "round"
                        ctx.stroke()
                    }
                }
            }

            // Center Icon/Text depending on state
            Kirigami.Icon {
                id: compactIcon
                anchors.centerIn: parent
                width: parent.width * 0.5
                height: parent.width * 0.5
                visible: root.status !== "success"
                source: root.compactIconSource
            }

            // Animated number display
            Item {
                anchors.centerIn: parent
                visible: root.status === "success"
                width: parent.width
                height: parent.height

                PlasmaComponents.Label {
                    id: compactValueText
                    anchors.centerIn: parent
                    text: root.compactShowWeekly ? (root.weeklyPct + "%") : (root.fiveHourPct + "%")
                    font.pixelSize: Math.max(10, parent.width * 0.28)
                    font.bold: true
                    color: {
                        if (root.compactShowWeekly) return Qt.color("#b388ff") // Distinct Purple
                        if (root.fiveHourPct < 50) return Kirigami.Theme.positiveTextColor
                        if (root.fiveHourPct < 80) return Kirigami.Theme.neutralTextColor
                        return Kirigami.Theme.negativeTextColor
                    }

                    Behavior on text {
                        SequentialAnimation {
                            NumberAnimation { target: compactValueText; property: "opacity"; to: 0; duration: 120 }
                            PropertyAction {}
                            NumberAnimation { target: compactValueText; property: "opacity"; to: 1; duration: 120 }
                        }
                    }
                }

                // Tiny label below the number: "5H" or "7D"
                PlasmaComponents.Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: parent.height * 0.1
                    text: root.compactShowWeekly ? i18n("7D") : i18n("5H")
                    font.pixelSize: Math.max(6, parent.width * 0.16)
                    font.bold: true
                    color: root.compactShowWeekly ? Qt.color("#b388ff") : Kirigami.Theme.disabledTextColor
                }
            }
        }
    }

    // ==========================================
    // FULL REPRESENTATION (Desktop / Popup Mode)
    // ==========================================
    fullRepresentation: PlasmaExtras.Representation {
        id: fullView
        implicitWidth: Kirigami.Units.gridUnit * 20
        implicitHeight: Kirigami.Units.gridUnit * 16

        // Native System Header
        header: PlasmaExtras.PlasmoidHeading {
            contentItem: RowLayout {
                spacing: Kirigami.Units.smallSpacing

                // Title Text
                PlasmaExtras.Heading {
                    text: i18n("Gemini Usage Watcher")
                    level: 1
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    Layout.fillWidth: true
                }

                // Refresh Button
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    ToolTip.text: i18n("Check Usage Now")
                    onClicked: root.triggerFetch()
                    enabled: !root.isSyncing

                    RotationAnimator on rotation {
                        running: root.isSyncing
                        loops: Animation.Infinite
                        from: 0
                        to: 360
                        duration: 1000
                    }
                }

                // Configure Button
                PlasmaComponents.ToolButton {
                    icon.name: "configure"
                    ToolTip.text: i18n("Configure Settings...")
                    onClicked: Plasmoid.internalAction("configure").trigger()
                }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit * 0.8
            spacing: Kirigami.Units.mediumSpacing

            // 1. STATUS SUMMARY
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: root.isSyncing ? i18n("Syncing limits...") : i18n("Stealth Mode Active")
                    font: Kirigami.Theme.smallFont
                    color: root.isSyncing ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                    Layout.fillWidth: true
                }
            }

            // 2. ERROR/BANNER SECTION (if auth_error or error)
            Rectangle {
                Layout.fillWidth: true
                // Dynamic height matching content size to support long troubleshooting instructions perfectly
                implicitHeight: errorLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
                visible: root.status === "auth_error" || root.status === "error"
                color: root.status === "auth_error" 
                    ? Qt.rgba(Kirigami.Theme.negativeTextColor.r, Kirigami.Theme.negativeTextColor.g, Kirigami.Theme.negativeTextColor.b, 0.15) 
                    : Qt.rgba(Kirigami.Theme.neutralTextColor.r, Kirigami.Theme.neutralTextColor.g, Kirigami.Theme.neutralTextColor.b, 0.15)
                border.color: root.status === "auth_error" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor
                border.width: 1
                radius: 6

                RowLayout {
                    id: errorLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.mediumSpacing

                    Kirigami.Icon {
                        id: errorIcon
                        source: root.errorIconSource
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        Layout.alignment: Qt.AlignTop
                    }

                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: root.errorMessage
                        font: Kirigami.Theme.smallFont
                        wrapMode: Text.WordWrap
                    }

                    ColumnLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Layout.alignment: Qt.AlignVCenter

                        Button {
                            text: i18n("Sign In...")
                            visible: root.status === "auth_error"
                            enabled: !root.isSyncing
                            onClicked: root.triggerLogin()
                        }

                        Button {
                            text: i18n("Configure")
                            onClicked: Plasmoid.internalAction("configure").trigger()
                        }
                    }
                }
            }

            // 3. STATS SECTION (Progress bars)
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.mediumSpacing
                visible: root.status === "success" || root.status === "loading"

                // ---- Progress bar 1: Rolling 5-Hour Limit ----
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents.Label {
                            text: i18n("Rolling 5-Hour Limit")
                            font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        PlasmaComponents.Label {
                            text: root.fiveHourPct + "%"
                            font.bold: true
                            color: {
                                if (root.fiveHourPct < 50) return Kirigami.Theme.positiveTextColor
                                if (root.fiveHourPct < 80) return Kirigami.Theme.neutralTextColor
                                return Kirigami.Theme.negativeTextColor
                            }
                        }
                    }

                    // Emerald/Amber/Red Gradient Progress Bar
                    Rectangle {
                        id: fiveHourBarBg
                        Layout.fillWidth: true
                        height: 10
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                        radius: 5
                        clip: true

                        Rectangle {
                            width: parent.width * (root.fiveHourPct / 100.0)
                            height: parent.height
                            radius: parent.radius

                            Behavior on width {
                                NumberAnimation { duration: 600; easing.type: Easing.OutQuad }
                            }

                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop {
                                    position: 0.0
                                    color: root.fiveHourPct < 50 ? Kirigami.Theme.positiveTextColor : (root.fiveHourPct < 80 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.negativeTextColor)
                                }
                                GradientStop {
                                    position: 1.0
                                    color: {
                                        var c = root.fiveHourPct < 50 ? Kirigami.Theme.positiveTextColor : (root.fiveHourPct < 80 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.negativeTextColor)
                                        return Qt.rgba(c.r * 0.8, c.g * 0.8, c.b * 0.8, 1.0)
                                    }
                                }
                            }
                        }
                    }

                    // Reset time row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Kirigami.Icon {
                            source: "clock"
                            width: 12
                            height: 12
                            color: Kirigami.Theme.disabledTextColor
                        }
                        PlasmaComponents.Label {
                            text: root.fiveHourResetEpoch > 0
                                ? i18n("Resets at %1  ·  %2", root.formatResetTime(root.fiveHourResetEpoch), root.formatRemaining(root.fiveHourResetEpoch))
                                : ((root.countdown && root.countdown.indexOf("Active") !== -1) ? i18n("Capacity: Full Speed") : i18n("Refreshes in: %1", root.countdown))
                            font: Kirigami.Theme.smallFont
                            color: Kirigami.Theme.disabledTextColor
                        }
                    }
                }

                // Spacer
                Item { Layout.preferredHeight: 4 }

                // ---- Progress bar 2: Weekly Limit ----
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaComponents.Label {
                            text: i18n("Weekly Limit / Budget")
                            font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        PlasmaComponents.Label {
                            text: root.weeklyPct + "%"
                            font.bold: true
                            color: Kirigami.Theme.highlightColor
                        }
                    }

                    // Blue Gradient Progress Bar
                    Rectangle {
                        id: weeklyBarBg
                        Layout.fillWidth: true
                        height: 10
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                        radius: 5
                        clip: true

                        Rectangle {
                            width: parent.width * (root.weeklyPct / 100.0)
                            height: parent.height
                            radius: parent.radius

                            Behavior on width {
                                NumberAnimation { duration: 600; easing.type: Easing.OutQuad }
                            }

                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: Kirigami.Theme.highlightColor }
                                GradientStop {
                                    position: 1.0
                                    color: Qt.rgba(Kirigami.Theme.highlightColor.r * 0.8, Kirigami.Theme.highlightColor.g * 0.8, Kirigami.Theme.highlightColor.b * 0.8, 1.0)
                                }
                            }
                        }
                    }

                    // Weekly reset time row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Kirigami.Icon {
                            source: "view-calendar"
                            width: 12
                            height: 12
                            color: Kirigami.Theme.highlightColor
                            opacity: 0.7
                        }
                        PlasmaComponents.Label {
                            text: root.weeklyResetEpoch > 0
                                ? i18n("Resets %1  ·  %2", root.formatResetTime(root.weeklyResetEpoch), root.formatRemaining(root.weeklyResetEpoch))
                                : i18n("Resets weekly")
                            font: Kirigami.Theme.smallFont
                            color: Kirigami.Theme.disabledTextColor
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            // 4. FOOTER INFO
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    id: lastUpdatedText
                    text: i18n("Last updated: %1", root.lastUpdated)
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.disabledTextColor
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                PlasmaComponents.Label {
                    text: "Scroll ring to switch view"
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.disabledTextColor
                    opacity: 0.75
                    visible: root.status === "success"
                }

                PlasmaComponents.Label {
                    text: "v1.1"
                    font: Kirigami.Theme.smallFont
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }
    }
}
