import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Services

PluginSettings {
    id: root
    pluginId: "githubHeatmap"

    PluginGlobalVar {
        id: usernameSetting
        varName: "username"
        defaultValue: ""
    }

    PluginGlobalVar {
        id: refreshIntervalSetting
        varName: "refreshInterval"
        defaultValue: 300
    }

    // Load persisted settings when settings UI opens
    Component.onCompleted: {
        const savedUsername = PluginService.loadPluginData("githubHeatmap", "username", "")
        const savedInterval = PluginService.loadPluginData("githubHeatmap", "refreshInterval", 300)

        console.log("GitHub Heatmap: Settings loaded from disk")

        if (savedUsername) {
            usernameField.text = savedUsername
            PluginService.setGlobalVar("githubHeatmap", "username", savedUsername)
        }

        intervalField.text = savedInterval.toString()
        PluginService.setGlobalVar("githubHeatmap", "refreshInterval", savedInterval)
    }

    Column {
        width: parent.width
        spacing: Theme.spacingL

        // Header
        Column {
            width: parent.width
            spacing: Theme.spacingXS

            StyledText {
                text: "GitHub Heatmap Settings"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                text: "Display your weekly GitHub contribution activity in your status bar"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }

        // GitHub Username
        StyledRect {
            width: parent.width
            height: usernameColumn.implicitHeight + Theme.spacingL * 2
            color: Theme.surfaceContainerHigh
            radius: Theme.cornerRadius

            Column {
                id: usernameColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "person"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "GitHub Username"
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                DankTextField {
                    id: usernameField
                    width: parent.width - Theme.spacingL * 2
                    placeholderText: "your-github-username"
                    text: ""
                }

                StyledText {
                    text: "Your GitHub username (public profile)"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }

        // Refresh Interval
        StyledRect {
            width: parent.width
            height: intervalColumn.implicitHeight + Theme.spacingL * 2
            color: Theme.surfaceContainerHigh
            radius: Theme.cornerRadius

            Column {
                id: intervalColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "schedule"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "Refresh Interval"
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                DankTextField {
                    id: intervalField
                    width: parent.width - Theme.spacingL * 2
                    placeholderText: "300"
                    text: "300"
                    validator: IntValidator { bottom: 60 }
                }

                StyledText {
                    text: "Refresh interval in seconds (minimum: 60)"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // Save Button
        DankButton {
            width: parent.width
            text: "Save Settings"
            iconName: "check"

            onClicked: {
                // Validation
                if (!usernameField.text.trim()) {
                    ToastService.showError("GitHub username is required")
                    return
                }

                var interval = parseInt(intervalField.text) || 300
                if (interval < 60) {
                    ToastService.showError("Refresh interval must be at least 60 seconds")
                    return
                }

                // Save all settings using PluginService.savePluginData (persists to disk)
                PluginService.savePluginData("githubHeatmap", "username", usernameField.text.trim())
                PluginService.savePluginData("githubHeatmap", "refreshInterval", interval)

                // Also set in memory for immediate effect
                PluginService.setGlobalVar("githubHeatmap", "username", usernameField.text.trim())
                PluginService.setGlobalVar("githubHeatmap", "refreshInterval", interval)

                console.log("GitHub Heatmap: Settings saved - username:", usernameField.text.trim())

                // Success feedback
                ToastService.showSuccess("Settings saved successfully!")
            }
        }
    }
}
