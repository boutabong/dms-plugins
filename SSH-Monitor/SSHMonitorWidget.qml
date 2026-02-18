import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "ssh-monitor"

    // State - array of connection strings
    property var connections: []
    property bool hasConnections: connections.length > 0

    // Settings from pluginData (convert seconds to milliseconds)
    property int refreshInterval: (pluginData.refreshInterval || 5) * 1000

    // Icons
    readonly property string iconDisconnected: "cloud_off"
    readonly property string iconConnected: "cloud_done"

    // Popout dimensions
    popoutWidth: 400
    popoutHeight: 300

    // Accumulator for process output
    property string processOutput: ""

    Process {
        id: connectionChecker
        command: ["/usr/bin/env", "fish", "-c", fishScript]
        running: false

        property string fishScript: `
#!/usr/bin/env fish
# Get all connection processes
set ssh_procs (pgrep -af '^ssh ' 2>/dev/null)
set sftp_procs (pgrep -af '^sftp ' 2>/dev/null)
set ftp_procs (pgrep -af '^ftp ' 2>/dev/null)

# Combine all processes
set all_procs $ssh_procs $sftp_procs $ftp_procs

# Parse SSH config
set -l config_map
if test -f ~/.ssh/config
    set current_host ""
    for line in (cat ~/.ssh/config)
        if string match -qr '^Host\\s+(\\S+)' $line
            set host (string match -r '^Host\\s+(\\S+)' $line)[2]
            if test "$host" != "*"
                set current_host $host
            end
        else if string match -qr '^\\s*HostName\\s+(\\S+)' $line
            if test -n "$current_host"
                set host_addr (string match -r '^\\s*HostName\\s+(\\S+)' $line)[2]
                set -a config_map "$host_addr|$current_host"
                set -a config_map "$current_host|$current_host"
            end
        end
    end
end

# Resolve target
function resolve_target
    set target $argv[1]
    set config_map $argv[2..]
    for mapping in $config_map
        set parts (string split '|' $mapping)
        if test "$parts[1]" = "$target"
            echo $parts[2]
            return
        end
    end
    echo $target
end

# Extract target hostname from command args
# Properly skips flags that take separate arguments
function extract_target
    set cmd_name $argv[1]
    set args $argv[2..]

    # Flags that take a separate argument (superset of ssh/sftp/ftp)
    set flags_with_args b B c D E e F I i J L l m O o P p Q R S s W w

    set skip_next false
    for arg in $args
        if $skip_next
            set skip_next false
            continue
        end

        # Skip the command name itself
        if test "$arg" = "$cmd_name"; or test "$arg" = "$cmd_name:"
            continue
        end

        if string match -q -- '-*' $arg
            # Single-char flag that takes a separate argument (e.g. -p 22)
            # Combined flags like -p22 are already skipped since they start with -
            if string match -qr -- '^-[a-zA-Z]$' $arg
                set flag_char (string sub -s 2 -- $arg)
                if contains $flag_char $flags_with_args
                    set skip_next true
                end
            end
            continue
        end

        # First non-flag, non-command arg is the target
        if string match -q '*@*' $arg
            echo (string split '@' $arg)[2]
        else
            echo $arg
        end
        return
    end
end

# Build connection list
set connections
for proc in $all_procs
    set fields (string split -n ' ' $proc)
    if test (count $fields) -lt 2
        continue
    end
    
    set cmd_and_args $fields[2..]
    set cmd $fields[2]
    
    set conn_type SSH
    set target ""

    # SSH process
    if string match -q ssh $cmd
        if string match -q '*rsync --server*' $proc
            set conn_type RSYNC
        else if string match -q '*-s*sftp' $proc
            set conn_type SFTP
        else
            set conn_type SSH
        end
        set target (extract_target ssh $cmd_and_args)
    # SFTP command
    else if string match -q sftp $cmd
        set conn_type SFTP
        set target (extract_target sftp $cmd_and_args)
    # FTP command
    else if string match -q ftp $cmd
        set conn_type FTP
        set target (extract_target ftp $cmd_and_args)
    end
    
    # Skip if no valid target
    if test -z "$target"
        continue
    end
    
    # Resolve target
    set resolved (resolve_target $target $config_map)
    
    # Add to connections (avoid duplicates)
    set conn_string "$conn_type → $resolved"
    if not contains $conn_string $connections
        set -a connections $conn_string
    end
end

# Check for running sftp-sync processes
set sftp_sync_procs (pgrep -af 'sftp-sync' 2>/dev/null)
for proc in $sftp_sync_procs
    set fields (string split -n ' ' $proc)
    if test (count $fields) -ge 4
        set cmd_path $fields[2]
        # Check if it's the sftp-sync binary
        if string match -q '*sftp-sync' $cmd_path
            set profile $fields[4]
            if test -n "$profile"
                set conn_string "REMOTE → $profile"
                if not contains $conn_string $connections
                    set -a connections $conn_string
                end
            end
        end
    end
end

# Check for Yazi VFS SFTP connections
set yazi_pids (pgrep yazi 2>/dev/null)
for pid in $yazi_pids
    # Get remote IPs from ESTABLISHED connections to port 22
    for remote_ip in (ss -tnp 2>/dev/null | awk -v pid="pid=$pid," '$1=="ESTAB" && $0 ~ pid && $5 ~ /:22$/ {sub(/:22$/,"",$5); print $5}')
        if test -n "$remote_ip"
            # Resolve IP using SSH config mapping
            set resolved (resolve_target $remote_ip $config_map)
            set conn_string "YAZI → $resolved"
            if not contains $conn_string $connections
                set -a connections $conn_string
            end
        end
    end
end

# Output
if test (count $connections) -eq 0
    echo "DISCONNECTED"
else
    for conn in $connections
        echo $conn
    end
end
`
        
        stdout: SplitParser {
            onRead: data => {
                // Accumulate output - don't update connections yet
                root.processOutput += data + '\n';
            }
        }

        onExited: (exitCode, exitStatus) => {
            // Now process all accumulated output
            var lines = root.processOutput.trim().split('\n');
            var newConnections = [];

            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                if (line === "" || line === "DISCONNECTED") {
                    continue;
                }
                newConnections.push(line);
            }

            root.connections = newConnections;
            root.processOutput = ""; // Reset for next run
        }
    }

    // Timer to trigger checks
    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            connectionChecker.running = true
        }
    }

    // Horizontal bar - ICON ONLY
    horizontalBarPill: Component {
        DankIcon {
            name: root.hasConnections ? root.iconConnected : root.iconDisconnected
            size: root.iconSize
            color: root.hasConnections ? Theme.primary : Theme.surfaceVariantText
        }
    }

    // Vertical bar - ICON ONLY
    verticalBarPill: Component {
        DankIcon {
            name: root.hasConnections ? root.iconConnected : root.iconDisconnected
            size: root.iconSize
            color: root.hasConnections ? Theme.primary : Theme.surfaceVariantText
        }
    }

    // Popout with connection list
    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn
            headerText: "SSH Monitor"
            detailsText: root.hasConnections
                ? root.connections.length + " active connection" + (root.connections.length !== 1 ? "s" : "")
                : "No active connections"
            showCloseButton: true

            ListView {
                width: parent.width
                height: Math.min(contentHeight, root.popoutHeight - popoutColumn.headerHeight - popoutColumn.detailsHeight - Theme.spacingXL)
                spacing: Theme.spacingS
                model: root.connections
                clip: true

                delegate: StyledRect {
                    required property string modelData
                    required property int index

                    width: ListView.view.width
                    height: 40
                    radius: Theme.cornerRadiusSmall
                    color: Theme.surfaceContainerHigh

                    property string connectionText: modelData

                    Row {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        DankIcon {
                            name: {
                                var text = parent.parent.connectionText;
                                if (text.indexOf("SSH") === 0) return "terminal";
                                if (text.indexOf("SFTP") === 0) return "folder";
                                if (text.indexOf("FTP") === 0) return "storage";
                                if (text.indexOf("RSYNC") === 0) return "sync";
                                if (text.indexOf("YAZI") === 0) return "sync";
                                if (text.indexOf("REMOTE") === 0) return "sync";
                                return "cloud_sync";
                            }
                            size: root.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: parent.parent.connectionText
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }

        }
    }
}
