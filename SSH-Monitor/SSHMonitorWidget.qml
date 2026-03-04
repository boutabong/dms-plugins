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
    property int refreshInterval: (pluginData.refreshInterval || 2) * 1000

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
        command: ["/bin/bash", "-c", bashScript]
        running: false

        property string bashScript: `
# Get all SSH/SFTP/FTP connection processes in one call
mapfile -t all_procs < <(pgrep -af '^(ssh|sftp|ftp) ' 2>/dev/null)

# Parse SSH config into an associative array for O(1) lookup
declare -A config_map
current_host=""
if [[ -f ~/.ssh/config ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^Host[[:space:]]+([^*[:space:]]+) ]]; then
            current_host="\${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*HostName[[:space:]]+([^[:space:]]+) ]] && [[ -n "$current_host" ]]; then
            host_addr="\${BASH_REMATCH[1]}"
            config_map["$host_addr"]="$current_host"
            config_map["$current_host"]="$current_host"
        fi
    done < ~/.ssh/config
fi

# Check if a value exists in an array
contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Extract connection target from command args into globals:
#   _ext_user  — user part from user@host (empty if not given)
#   _ext_host  — hostname or IP
#   _ext_port  — explicit port value (empty if not given)
# Skips flags that consume the next argument; captures -p/-P port values.
_ext_user="" _ext_host="" _ext_port=""
extract_target() {
    _ext_user="" _ext_host="" _ext_port=""
    local flags_with_args="b B c D E e F I i J L l m O o P p Q R S s W w"
    local skip_next=false
    local next_is_port=false
    local arg
    for arg in "$@"; do
        if $skip_next; then
            skip_next=false
            if $next_is_port; then
                _ext_port="$arg"
                next_is_port=false
            fi
            continue
        fi
        if [[ "$arg" == -* ]]; then
            if [[ "$arg" =~ ^-[pP]([0-9]+)$ ]]; then
                _ext_port="\${BASH_REMATCH[1]}"
            elif [[ "$arg" =~ ^-[a-zA-Z]$ ]]; then
                local flag_char="\${arg:1:1}"
                if [[ " $flags_with_args " == *" $flag_char "* ]]; then
                    skip_next=true
                    if [[ "$flag_char" == "p" || "$flag_char" == "P" ]]; then
                        next_is_port=true
                    fi
                fi
            fi
            continue
        fi
        if [[ "$arg" == *@* ]]; then
            _ext_user="\${arg%%@*}"
            _ext_host="\${arg#*@}"
        else
            _ext_host="$arg"
        fi
        return
    done
}

# Collect active sftp-sync processes up front (pid → profile).
# Used both to build REMOTE entries and to know when to suppress
# the underlying sshfs SSH child from appearing as a duplicate SFTP entry.
declare -A sftp_sync_pids
while IFS= read -r proc; do
    [[ -z "$proc" ]] && continue
    read -ra f <<< "$proc"
    if [[ "\${#f[@]}" -ge 4 && "\${f[1]}" == *sftp-sync ]]; then
        sftp_sync_pids["\${f[0]}"]="\${f[3]}"
    fi
done < <(pgrep -af 'sftp-sync' 2>/dev/null)

# When sftp-sync is active, read /proc/mounts to find all sshfs-mounted hosts.
# Any SSH connection whose resolved host matches an sshfs mount is the
# underlying FUSE connection — already represented by the REMOTE entry below,
# so it should not appear as a duplicate SFTP entry.
# NOTE: PPID-based detection is unreliable here because sshfs forks to
# daemonize *after* spawning its SSH child, reparenting that child to PID 1.
declare -A sshfs_hosts
if [[ "\${#sftp_sync_pids[@]}" -gt 0 ]]; then
    while IFS= read -r line; do
        if [[ "$line" == *" fuse.sshfs "* ]]; then
            src="\${line%% *}"
            host="\${src##*@}"
            host="\${host%%:*}"
            [[ -n "$host" ]] && sshfs_hosts["\${config_map[$host]:-$host}"]=1
        fi
    done < /proc/mounts
fi

# Build connection list
connections=()
declare -A conn_counts
for proc in "\${all_procs[@]}"; do
    read -ra fields <<< "$proc"
    if [[ "\${#fields[@]}" -lt 3 ]]; then
        continue
    fi
    cmd="\${fields[1]}"
    conn_type="SSH"
    if [[ "$cmd" == "ssh" ]]; then
        if [[ "$proc" == *"rsync --server"* ]]; then
            conn_type="RSYNC"
        elif [[ "$proc" == *"-s"*"sftp"* ]]; then
            conn_type="SFTP"
        fi
    elif [[ "$cmd" == "sftp" ]]; then
        conn_type="SFTP"
    elif [[ "$cmd" == "ftp" ]]; then
        conn_type="FTP"
    fi
    extract_target "\${fields[@]:2}"
    [[ -z "$_ext_host" ]] && continue
    # Known SSH config host → use clean alias; unknown host → show user@host:port
    if [[ -n "\${config_map[$_ext_host]+x}" ]]; then
        resolved="\${config_map[$_ext_host]}"
        display_host="$resolved"
    else
        resolved="$_ext_host"
        display_host="$_ext_host"
        [[ -n "$_ext_user" ]] && display_host="$_ext_user@$display_host"
        [[ -n "$_ext_port" && "$_ext_port" != "22" ]] && display_host="$display_host:$_ext_port"
    fi
    [[ -n "\${sshfs_hosts[$resolved]+x}" ]] && continue
    conn_string="$conn_type → $display_host"
    if [[ "$conn_type" == "SSH" || "$conn_type" == "SFTP" || "$conn_type" == "FTP" ]]; then
        if [[ -n "\${conn_counts[$conn_string]+x}" ]]; then
            conn_counts["\${conn_string}"]=\$(( \${conn_counts[$conn_string]} + 1 ))
        else
            conn_counts["$conn_string"]=1
            connections+=("$conn_string")
        fi
    else
        if ! contains "$conn_string" "\${connections[@]}"; then
            connections+=("$conn_string")
        fi
    fi
done

# Add REMOTE entries from the already-collected sftp-sync data
for pid in "\${!sftp_sync_pids[@]}"; do
    profile="\${sftp_sync_pids[$pid]}"
    if [[ -n "$profile" ]]; then
        conn_string="REMOTE → $profile"
        if ! contains "$conn_string" "\${connections[@]}"; then
            connections+=("$conn_string")
        fi
    fi
done

# Check for Yazi VFS SFTP connections
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    while IFS= read -r remote_ip; do
        [[ -z "$remote_ip" ]] && continue
        resolved="\${config_map[$remote_ip]:-$remote_ip}"
        conn_string="YAZI → $resolved"
        if ! contains "$conn_string" "\${connections[@]}"; then
            connections+=("$conn_string")
        fi
    done < <(ss -tnp 2>/dev/null | awk -v pid="pid=$pid," '$1=="ESTAB" && $0 ~ pid && $5 ~ /:22$/ {sub(/:22$/,"",$5); print $5}')
done < <(pgrep yazi 2>/dev/null)

# Output
if [[ "\${#connections[@]}" -eq 0 ]]; then
    echo "DISCONNECTED"
else
    for conn in "\${connections[@]}"; do
        if [[ -n "\${conn_counts[$conn]+x}" && "\${conn_counts[$conn]}" -gt 1 ]]; then
            echo "$conn ×\${conn_counts[$conn]}"
        else
            echo "$conn"
        fi
    done
fi
`

        stdout: SplitParser {
            onRead: data => {
                root.processOutput += data + '\n';
            }
        }

        onExited: (exitCode, exitStatus) => {
            var lines = root.processOutput.trim().split('\n');
            var newConnections = [];
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                if (line === "" || line === "DISCONNECTED") continue;
                newConnections.push(line);
            }
            root.connections = newConnections;
            root.processOutput = "";
        }
    }

    // Timer to trigger checks
    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!connectionChecker.running)
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
            detailsText: {
                if (!root.hasConnections) return "No active connections";
                var total = 0;
                for (var i = 0; i < root.connections.length; i++) {
                    var m = root.connections[i].match(/×(\d+)$/);
                    total += m ? parseInt(m[1]) : 1;
                }
                return total + " active connection" + (total !== 1 ? "s" : "");
            }
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
