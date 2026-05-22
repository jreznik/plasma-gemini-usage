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
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

Kirigami.FormLayout {
    id: page

    property alias cfg_cookie: cookieField.text
    property alias cfg_userAgent: userAgentField.text
    property alias cfg_updateInterval: updateIntervalField.value

    // Default values and properties to avoid initial setup warnings in Plasma
    property string cfg_cookieDefault: ""
    property string cfg_userAgentDefault: ""
    property int cfg_updateIntervalDefault: 900
    property string title: ""

    // Scraper Script Path resolved dynamically (compatible with store installations)
    readonly property string scraperPath: Qt.resolvedUrl("../../get_usage.js").toString().replace("file://", "")

    Plasma5Support.DataSource {
        id: settingsExecutable
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            var exitCode = data["exit code"]
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""

            disconnectSource(sourceName)

            if (sourceName.indexOf("--login") !== -1) {
                signInButton.enabled = true

                // Robust dependency checks inside the settings panel
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
                    signInStatusLabel.text = i18n("Node.js is not installed. Please install 'nodejs' and 'npm'.")
                    return
                }

                if (depsMissing) {
                    signInStatusLabel.text = i18n("Missing dependencies. Run 'npm install' in the widget folder.")
                    return
                }

                if (chromeMissing) {
                    signInStatusLabel.text = i18n("Google Chrome/Chromium could not be launched.")
                    return
                }

                if (exitCode === 0) {
                    try {
                        var cleaned = stdout.trim()
                        var res = JSON.parse(cleaned)
                        if (res.status === "success") {
                            cookieField.text = res.cookie
                            userAgentField.text = res.user_agent
                            signInStatusLabel.text = i18n("Sign-in successful! Fields populated.")
                        } else {
                            signInStatusLabel.text = res.message || i18n("Sign-in failed.")
                        }
                    } catch (e) {
                        signInStatusLabel.text = i18n("Error parsing credentials.")
                    }
                } else {
                    signInStatusLabel.text = i18n("Interactive browser closed or timed out (Exit: %1).", exitCode)
                }
            }
        }
    }

    Kirigami.PasswordField {
        id: cookieField
        Kirigami.FormData.label: i18n("Gemini Cookie Header:")
        placeholderText: i18n("Paste __Secure-1PSID=... or entire Cookie string")
        Layout.fillWidth: true
        
        // standard ToolTip attached property
        ToolTip.text: i18n("Open gemini.google.com in your browser, press F12, go to the Network tab, refresh the page, find any request, copy the entire 'Cookie' request header, and paste it here.")
        ToolTip.visible: cookieField.hovered
    }

    TextField {
        id: userAgentField
        Kirigami.FormData.label: i18n("User Agent:")
        placeholderText: i18n("User-Agent matching your browser")
        Layout.fillWidth: true
        
        ToolTip.text: i18n("Must match the User-Agent of the browser where you copied the cookies from to ensure stealth.")
        ToolTip.visible: userAgentField.hovered
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Interactive Sign-in:")
        spacing: Kirigami.Units.smallSpacing
        Layout.fillWidth: true

        Button {
            id: signInButton
            text: i18n("Launch Sign-in Browser")
            icon.name: "system-users-symbolic"
            onClicked: {
                signInButton.enabled = false
                signInStatusLabel.text = i18n("Opening browser... Check your desktop.")
                settingsExecutable.connectSource("node " + page.scraperPath + " --login")
            }
        }

        Label {
            id: signInStatusLabel
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.neutralTextColor
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
    }

    SpinBox {
        id: updateIntervalField
        Kirigami.FormData.label: i18n("Cache Expiry / Poll (seconds):")
        from: 300     // 5 minutes minimum for stealth
        to: 86400    // 24 hours max
        stepSize: 300  // step by 5 minutes
        editable: true
        
        ToolTip.text: i18n("Default: 900s (15 minutes). Higher values are safer for stealth.")
        ToolTip.visible: updateIntervalField.hovered
    }
}
