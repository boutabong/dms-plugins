import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Popout dimensions
    popoutWidth: 280
    popoutHeight: 340

    // Icons
    readonly property string iconBar: "commit"
    readonly property string iconRefresh: "refresh"
    readonly property string iconError: "error"
    readonly property string iconOpen: "open_in_browser"
    readonly property string iconSuccess: "check_circle"

    // Settings from pluginData
    property string githubUsername: (pluginData && pluginData.username) ? pluginData.username : ""
    property int refreshInterval: (pluginData && pluginData.refreshInterval) ? pluginData.refreshInterval : 300

    // State - Always 7 items for fixed width
    property var contributions: []
    property var gridData: []  // 4 weeks of data for calendar grid
    property string totalContributions: "0"
    property bool isError: false
    property bool isLoading: false
    property string errorMessage: ""
    property var lastRefreshTime: null
    property bool isManualRefresh: false

    // Initialize with 7 placeholder items
    Component.onCompleted: {
        initializePlaceholders()

        // Start timer if credentials present
        Qt.callLater(function() {
            if (githubUsername) {
                refreshTimer.start()
            }
        })
    }

    // Watch for credential changes
    onGithubUsernameChanged: checkAndStartTimer()
    onRefreshIntervalChanged: {
        if (refreshTimer.running) {
            refreshTimer.restart()
        }
    }

    function checkAndStartTimer() {
        if (githubUsername) {
            if (!refreshTimer.running) {
                refreshTimer.start()
            }
        } else {
            refreshTimer.stop()
            initializePlaceholders()
        }
    }

    // Initialize 7 placeholder squares
    function initializePlaceholders() {
        const placeholders = []
        const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        for (let i = 0; i < 7; i++) {
            placeholders.push({
                weekday: days[i],
                date: "--/--",
                count: 0,
                color: Theme.surfaceContainer
            })
        }

        contributions = placeholders
        totalContributions = "0"
        isError = false

        // Initialize grid placeholders (8 weeks × 7 days)
        const gridPlaceholders = []
        for (let week = 0; week < 8; week++) {
            const weekData = []
            for (let day = 0; day < 7; day++) {
                weekData.push({
                    weekday: day,
                    weekdayName: days[day],
                    date: "--/--",
                    count: 0,
                    color: Theme.surfaceContainer
                })
            }
            gridPlaceholders.push(weekData)
        }
        gridData = gridPlaceholders
    }

    // Shell escape function for security
    function escapeShellString(str) {
        if (!str) return ""
        return str.replace(/\\/g, "\\\\")
                  .replace(/"/g, "\\\"")
                  .replace(/\$/g, "\\$")
                  .replace(/`/g, "\\`")
    }

    // Auto-refresh timer
    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        repeat: true
        running: false
        triggeredOnStart: true
        onTriggered: {
            if (root.githubUsername) {
                root.isManualRefresh = false  // Automatic refresh
                root.refreshHeatmap()
            } else {
                root.isError = true
                root.errorMessage = "Configure GitHub username in settings"
            }
        }
    }

    // Refresh function
    function refreshHeatmap() {
        if (!githubUsername) {
            isError = true
            errorMessage = "Configure GitHub username in settings"
            return
        }

        // Cooldown: prevent refreshes within 30 seconds of last refresh
        const now = Date.now()
        if (lastRefreshTime && (now - lastRefreshTime) < 30000) {
            console.log("GitHub: Skipping refresh (cooldown active)")
            return
        }

        console.log("GitHub: Fetching contributions for", githubUsername)
        lastRefreshTime = now
        isLoading = true
        githubProcess.running = true
    }

    // Build the embedded Bash script
    function buildScript() {
        const escapedUsername = escapeShellString(githubUsername)

        // NOTE: We must escape ${} as \${} to prevent JS interpolation
        return `
# GitHub Heatmap Fetcher (Bash + Public API)
GITHUB_USERNAME="${escapedUsername}"

# GitHub contribution color scheme (dark theme)
COLOR_0="#202329"
COLOR_1="#0e4429"
COLOR_2="#006d32"
COLOR_3="#26a641"
COLOR_4="#39d353"

# 1. Calculate date range
today=$(date +%Y-%m-%d)
today_dow=$(date -d "$today" +%u)

if [ "$today_dow" = "7" ]; then
    current_sunday="$today"
else
    current_sunday=$(date -d "$today -$today_dow days" +%Y-%m-%d)
fi

start_date=$(date -d "$current_sunday -49 days" +%Y-%m-%d)
today_timestamp=$(date -d "$today" +%s)

# 2. Fetch Data (Public API)
url="https://github-contributions-api.jogruber.de/v4/$GITHUB_USERNAME?y=last"

temp_response=$(mktemp)
http_code=$(curl -s -w "%{http_code}" -o "$temp_response" "$url")
body=$(cat "$temp_response")
rm -f "$temp_response"

# 3. Validation
if [ "$http_code" != "200" ]; then
    printf '{"contributions":[],"total":0,"error":true,"errorMessage":"User not found or API error (HTTP %s)"}\n' "$http_code"
    exit 1
fi

# 4. Process Data
# We use jq to filter relevant days (>= start_date)
relevant_days=$(echo "$body" | jq -c --arg start "$start_date" '.contributions[] | select(.date >= $start)')

total_contributions=0
all_days=()

# Read filtered JSON lines
while read -r day_json; do
    if [ -z "$day_json" ]; then continue; fi
    
    date=$(echo "$day_json" | jq -r '.date')
    count=$(echo "$day_json" | jq -r '.count')
    level=$(echo "$day_json" | jq -r '.level')
    
    day_timestamp=$(date -d "$date" +%s)
    
    if [ "$day_timestamp" -le "$today_timestamp" ]; then
        
        case "$level" in
            0) color="$COLOR_0" ;;
            1) color="$COLOR_1" ;;
            2) color="$COLOR_2" ;;
            3) color="$COLOR_3" ;;
            4) color="$COLOR_4" ;;
            *) color="$COLOR_0" ;;
        esac

        total_contributions=$((total_contributions + count))

        weekday=$(date -d "$date" +%w)
        formatted_date=$(date -d "$date" +%m/%d)
        
        weekday_names=("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat")
        # Fix: Escape \${} to prevent JS interpolation
        weekday_name="\${weekday_names[$weekday]}"

        all_days+=("$date|$weekday|$count|$color|$formatted_date|$weekday_name")
    fi
done <<< "$relevant_days"

# 5. Build Grid
# Fix: Escape \${} to prevent JS interpolation
IFS=$'\\n' sorted_days=($(sort <<<"\${all_days[*]}"))
unset IFS

grid_json="["
current_week="["
current_week_day=-1
first_week=1
first_day_in_week=1

# Fix: Escape \${} to prevent JS interpolation
for day_data in "\${sorted_days[@]}"; do
    IFS='|' read -r date weekday count color formatted_date weekday_name <<< "$day_data"
    
    if [ "$weekday" == "0" ] && [ "$first_day_in_week" == "0" ]; then
        current_week="$current_week]"
        if [ "$first_week" == "1" ]; then
            grid_json="$grid_json$current_week"
            first_week=0
        else
            grid_json="$grid_json,$current_week"
        fi
        current_week="["
        first_day_in_week=1
    fi

    day_obj="{\\\"weekday\\\":$weekday,\\\"weekdayName\\\":\\\"$weekday_name\\\",\\\"date\\\":\\\"$formatted_date\\\",\\\"count\\\":$count,\\\"color\\\":\\\"$color\\\"}"

    if [ "$first_day_in_week" == "1" ]; then
        current_week="$current_week$day_obj"
        first_day_in_week=0
    else
        current_week="$current_week,$day_obj"
    fi
done

current_week="$current_week]"
if [ "$first_week" == "1" ]; then
    grid_json="$grid_json$current_week"
else
    grid_json="$grid_json,$current_week"
fi
grid_json="$grid_json]"

# 6. Build Pill Data
# Fix: Escape \${} to prevent JS interpolation
day_count=\${#sorted_days[@]}
pill_start=$((day_count - 7))
if [ $pill_start -lt 0 ]; then pill_start=0; fi

pill_json="["
pill_count=0

for (( i=pill_start; i<day_count; i++ )); do
    # Fix: Escape \${} to prevent JS interpolation
    day_data="\${sorted_days[$i]}"
    IFS='|' read -r date weekday count color formatted_date weekday_name <<< "$day_data"

    if [ $pill_count -gt 0 ]; then
        pill_json="$pill_json,"
    fi
    pill_json="$pill_json{\\\"weekday\\\":\\\"$weekday_name\\\",\\\"date\\\":\\\"$formatted_date\\\",\\\"count\\\":$count,\\\"color\\\":\\\"$color\\\"}"
    pill_count=$((pill_count + 1))
done
pill_json="$pill_json]"

printf '{"contributions":%s,"gridData":%s,"total":%d,"error":false}\\n' "$pill_json" "$grid_json" "$total_contributions"
exit 0
`
    }

    // Bash process
    Process {
        id: githubProcess
        command: ["/usr/bin/env", "bash", "-c", buildScript()]
        running: false

        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data.trim())

                    if (result.error) {
                        console.error("GitHub: API error -", result.errorMessage)
                        root.isError = true
                        root.errorMessage = result.errorMessage || "Unknown error"
                        root.initializePlaceholders()
                        root.isLoading = false
                        if (root.isManualRefresh) {
                            notifyFail.running = true
                        }
                        return
                    }

                    console.log("GitHub: Successfully fetched", result.contributions.length, "days for pill,", result.gridData.length, "weeks for grid")

                    root.isError = false
                    root.isLoading = false

                    // Ensure we always have exactly 7 items for pill
                    let newContributions = result.contributions || []

                    // Pad with placeholders if less than 7
                    while (newContributions.length < 7) {
                        newContributions.push({
                            weekday: "---",
                            date: "--/--",
                            count: 0,
                            color: Theme.surfaceContainer
                        })
                    }

                    // Trim if more than 7
                    newContributions = newContributions.slice(0, 7)

                    root.contributions = newContributions
                    root.totalContributions = result.total.toString()

                    // Process grid data - ensure 4 weeks with 7 days each
                    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                    let newGridData = result.gridData || []

                    // Pad to 8 weeks if needed
                    while (newGridData.length < 8) {
                        const emptyWeek = []
                        for (let d = 0; d < 7; d++) {
                            emptyWeek.push({
                                weekday: d,
                                weekdayName: days[d],
                                date: "--/--",
                                count: 0,
                                color: Theme.surfaceContainer
                            })
                        }
                        newGridData.unshift(emptyWeek)
                    }

                    // Ensure each week has 7 days
                    for (let w = 0; w < newGridData.length; w++) {
                        while (newGridData[w].length < 7) {
                            const missingDay = newGridData[w].length
                            newGridData[w].push({
                                weekday: missingDay,
                                weekdayName: days[missingDay],
                                date: "--/--",
                                count: 0,
                                color: Theme.surfaceContainer
                            })
                        }
                    }

                    // Take only last 8 weeks
                    newGridData = newGridData.slice(-8)

                    root.gridData = newGridData

                    if (root.isManualRefresh) {
                        notifySuccess.running = true
                    }

                } catch (e) {
                    console.error("GitHub: Failed to parse response -", e, "Data:", data)
                    root.isError = true
                    root.errorMessage = "Failed to parse GitHub response"
                    root.initializePlaceholders()
                    root.isLoading = false
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.isLoading = false
            if (exitCode !== 0 && !root.isError) {
                console.error("GitHub: Script failed with exit code", exitCode)
                root.isError = true
                root.errorMessage = "Script failed with exit code: " + exitCode
                if (root.isManualRefresh) {
                    notifyFail.running = true
                }
            }
        }
    }

    // Notification processes
    Process {
        id: notifySuccess
        command: ["notify-send", "-t", "3000", "GitHub Synced", "Contributions refreshed successfully"]
        running: false
    }

    Process {
        id: notifyFail
        command: ["notify-send", "-u", "critical", "-t", "5000", "GitHub Sync Failed", root.errorMessage]
        running: false
    }

    Process {
        id: openProfileProcess
        command: ["xdg-open", "https://github.com/" + root.githubUsername]
        running: false
    }

    // Horizontal bar pill - ALWAYS 7 squares
    horizontalBarPill: Component {
        Row {
            spacing: 2

            Repeater {
                model: 7  // ALWAYS 7 - prevents width changes

                Rectangle {
                    width: 8
                    height: 16
                    radius: 2
                    color: index < root.contributions.length
                           ? root.contributions[index].color
                           : Theme.surfaceContainer
                    border.color: Qt.darker(color, 1.2)
                    border.width: 1

                    // Subtle loading animation
                    opacity: root.isLoading ? 0.6 : 1.0

                    Behavior on opacity {
                        NumberAnimation { duration: 200 }
                    }

                    Behavior on color {
                        ColorAnimation { duration: 300 }
                    }
                }
            }
        }
    }

    // Vertical bar pill - ALWAYS 7 squares
    verticalBarPill: Component {
        Column {
            spacing: 2

            Repeater {
                model: 7  // ALWAYS 7 - prevents height changes

                Rectangle {
                    width: 16
                    height: 8
                    radius: 2
                    color: index < root.contributions.length
                           ? root.contributions[index].color
                           : Theme.surfaceContainer
                    border.color: Qt.darker(color, 1.2)
                    border.width: 1

                    // Subtle loading animation
                    opacity: root.isLoading ? 0.6 : 1.0

                    Behavior on opacity {
                        NumberAnimation { duration: 200 }
                    }

                    Behavior on color {
                        ColorAnimation { duration: 300 }
                    }
                }
            }
        }
    }

    // Popout position persistence
    property int popoutX: (pluginData && pluginData.popoutX) ? pluginData.popoutX : -1
    property int popoutY: (pluginData && pluginData.popoutY) ? pluginData.popoutY : -1

    function savePopoutPosition(x, y) {
        PluginService.savePluginData("githubHeatmap", "popoutX", x)
        PluginService.savePluginData("githubHeatmap", "popoutY", y)
        PluginService.setGlobalVar("githubHeatmap", "popoutX", x)
        PluginService.setGlobalVar("githubHeatmap", "popoutY", y)
    }

    // Popout content
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Restore saved position
            x: root.popoutX >= 0 ? root.popoutX : x
            y: root.popoutY >= 0 ? root.popoutY : y

            // Save position when moved
            onXChanged: if (visible) Qt.callLater(() => root.savePopoutPosition(x, y))
            onYChanged: if (visible) Qt.callLater(() => root.savePopoutPosition(x, y))

            headerText: "GitHub Contributions"
            detailsText: {
                if (root.isError) return root.errorMessage
                if (root.isLoading) return "Loading..."
                return root.totalContributions + " contributions (8 weeks)"
            }
            showCloseButton: false

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // Action buttons row
                Row {
                    anchors.right: parent.right
                    spacing: Theme.spacingS

                    // Refresh button
                    Rectangle {
                        width: Theme.iconSize * 1.5
                        height: Theme.iconSize * 1.5
                        radius: Theme.iconSize * 0.75
                        color: refreshArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconRefresh
                            size: Theme.iconSize * 0.8
                            color: refreshArea.containsMouse ? Theme.primary : Theme.surfaceText

                            NumberAnimation on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.isLoading
                            }
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.isManualRefresh = true
                                root.refreshHeatmap()
                            }
                        }
                    }

                    // Open profile button
                    Rectangle {
                        width: Theme.iconSize * 1.5
                        height: Theme.iconSize * 1.5
                        radius: Theme.iconSize * 0.75
                        color: openArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconOpen
                            size: Theme.iconSize * 0.8
                            color: openArea.containsMouse ? Theme.primary : Theme.surfaceText
                        }

                        MouseArea {
                            id: openArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.githubUsername) {
                                    openProfileProcess.running = true
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.outlineVariant
                }

                // Error state
                StyledRect {
                    visible: root.isError
                    width: parent.width
                    height: 100
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: root.iconError
                            color: Theme.error
                            size: Theme.iconSize * 1.5
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: "Failed to load contributions"
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                // Calendar grid view
                Row {
                    visible: !root.isError
                    spacing: 6
                    anchors.horizontalCenter: parent.horizontalCenter

                    // Day labels column
                    Column {
                        spacing: 3
                        topPadding: 2

                        Repeater {
                            model: ["S", "M", "T", "W", "T", "F", "S"]

                            StyledText {
                                text: modelData
                                font.pixelSize: 10
                                color: Theme.surfaceVariantText
                                width: 14
                                height: 26
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    // Grid of contribution squares (8 weeks × 7 days)
                    Row {
                        spacing: 3

                        Repeater {
                            model: root.gridData  // 8 weeks

                            Column {
                                spacing: 3
                                required property var modelData
                                required property int index

                                Repeater {
                                    model: modelData  // 7 days per week

                                    Rectangle {
                                        width: 26
                                        height: 26
                                        radius: 4
                                        color: modelData.color || Theme.surfaceContainer
                                        border.color: Qt.darker(color, 1.15)
                                        border.width: 1

                                        required property var modelData

                                        opacity: root.isLoading ? 0.6 : 1.0

                                        Behavior on opacity {
                                            NumberAnimation { duration: 200 }
                                        }

                                        Behavior on color {
                                            ColorAnimation { duration: 300 }
                                        }

                                        // Tooltip on hover
                                        MouseArea {
                                            id: cellMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                        }

                                        // Tooltip popup
                                        Rectangle {
                                            visible: cellMouse.containsMouse && modelData.date !== "--/--"
                                            x: -25
                                            y: -30
                                            width: tooltipText.implicitWidth + 12
                                            height: tooltipText.implicitHeight + 8
                                            color: Theme.surfaceContainerHighest
                                            radius: 4
                                            z: 100

                                            StyledText {
                                                id: tooltipText
                                                anchors.centerIn: parent
                                                text: modelData.date + ": " + modelData.count
                                                font.pixelSize: 11
                                                color: Theme.surfaceText
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Empty state
                StyledRect {
                    visible: !root.isError && root.totalContributions === "0"
                    width: parent.width
                    height: 50
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    StyledText {
                        anchors.centerIn: parent
                        text: "No contributions yet"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }
        }
    }
}
