import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ui state ---------------------------------------------------------------
    property string mode: "session"          // "session" | "weekly"
    property string uiState: "loading"        // loading | ok | stale | error
    property var usage: null                   // last good parsed JSON
    property int failCount: 0

    preferredRepresentation: compactRepresentation

    // ---- derived current block --------------------------------------------
    function block() {
        if (!usage)
            return null;
        var b = (mode === "weekly") ? usage.weekly : usage.session;
        // fall back to the other block if the active one is missing (e.g. Pro = no weekly)
        if (!b)
            b = usage.session || usage.weekly;
        return b;
    }

    // ---- color logic (spec §6) --------------------------------------------
    // light/dark hex pairs picked by panel luminance
    function isDark() {
        var c = Kirigami.Theme.backgroundColor;
        return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) < 0.5;
    }
    function statusColor(pct) {
        var dark = isDark();
        if (pct >= 100) return dark ? "#cc0000" : "#a40000";
        if (pct >= 81)  return dark ? "#ef2929" : "#cc0000";
        if (pct >= 50)  return dark ? "#fce94f" : "#c4a000";
        return dark ? "#8ae234" : "#4e9a06";
    }

    // ---- countdown formatting ---------------------------------------------
    function fmtCountdown(secs) {
        if (secs === null || secs === undefined || secs < 0)
            return "--";
        if (secs >= 86400) {
            var d = Math.floor(secs / 86400);
            var h = Math.floor((secs % 86400) / 3600);
            return d + "d " + h + "h";
        }
        if (secs >= 3600) {
            var hh = Math.floor(secs / 3600);
            var mm = Math.floor((secs % 3600) / 60);
            return hh + "h " + mm + "m";
        }
        if (secs >= 60)
            return Math.floor(secs / 60) + "m";
        return "<1m";
    }
    // live remaining seconds, recomputed from resetAt so the panel ticks down
    function remainingSecs(b) {
        if (!b)
            return null;
        if (b.resetAt) {
            var t = Date.parse(b.resetAt);
            if (!isNaN(t))
                return Math.max(0, Math.floor((t - Date.now()) / 1000));
        }
        return (b.secondsToReset !== undefined) ? b.secondsToReset : null;
    }

    // ---- data fetching -----------------------------------------------------
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            executable.disconnectSource(sourceName);
            handleOutput((data["stdout"] || ""), data["exit code"]);
        }
    }

    function fetchData() {
        var scriptUrl = Qt.resolvedUrl("../code/collect.py");
        var script = scriptUrl.toString().replace(/^file:\/\//, "");
        var cmd = "python3 '" + script.replace(/'/g, "'\\''") + "'";
        executable.connectSource(cmd);
    }

    function handleOutput(stdout, exitCode) {
        var parsed = null;
        try {
            parsed = JSON.parse(stdout);
        } catch (e) {
            parsed = null;
        }

        var ok = parsed && !parsed.error && (parsed.session || parsed.weekly);
        if (ok) {
            usage = parsed;
            failCount = 0;
            uiState = "ok";
        } else {
            failCount += 1;
            if (usage && failCount >= 2)
                uiState = "stale";
            else if (usage)
                uiState = "ok";        // tolerate a single transient miss
            else
                uiState = "error";
        }
    }

    function toggleMode() {
        var next = (mode === "session") ? "weekly" : "session";
        // only switch if the target block actually has data
        if (usage && ((next === "weekly" && usage.weekly) || (next === "session" && usage.session)))
            mode = next;
        else if (usage)
            mode = next;               // allow toggle even if null; block() falls back
    }

    Component.onCompleted: fetchData()

    Timer {
        id: refreshTimer
        interval: Math.max(60, plasmoid.configuration.refreshIntervalSeconds) * 1000
        running: true
        repeat: true
        onTriggered: root.fetchData()
    }

    // ticks the countdown text between fetches
    Timer {
        id: displayTimer
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.tick = !root.tick
    }
    property bool tick: false   // toggled to force countdown re-evaluation

    // ---- compact (panel) representation -----------------------------------
    compactRepresentation: MouseArea {
        id: compact
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleMode()

        readonly property bool loading: root.uiState === "loading"
        readonly property bool error: root.uiState === "error"
        readonly property bool stale: root.uiState === "stale"
        readonly property var b: root.block()
        readonly property real pct: b && b.pct !== undefined ? b.pct : 0
        // depend on root.tick so the binding re-evaluates on the display timer
        readonly property int secs: (root.tick, b ? root.remainingSecs(b) : null)

        implicitWidth: layout.implicitWidth + Kirigami.Units.smallSpacing * 2
        implicitHeight: Math.max(layout.implicitHeight, Kirigami.Units.iconSizes.small)
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth

        function modeIcon() {
            if (loading) return "⏳";
            if (error || stale) return "⚠️";
            return root.mode === "weekly" ? "📅" : "▓";
        }

        RowLayout {
            id: layout
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            // mode / status icon (own label so its tall emoji metrics don't
            // shift the value text's baseline — that misaligned the row)
            PC3.Label {
                Layout.fillHeight: true
                verticalAlignment: Text.AlignVCenter
                text: compact.modeIcon()
                opacity: compact.loading ? 0.5 : 1.0
            }

            PC3.Label {
                id: pctLabel
                Layout.fillHeight: true
                verticalAlignment: Text.AlignVCenter
                text: compact.error ? "N/A"
                      : compact.loading ? "--%"
                      : Math.round(compact.pct) + "%"
                color: (compact.error || compact.loading)
                       ? Kirigami.Theme.textColor
                       : root.statusColor(compact.pct)
                opacity: compact.loading ? 0.5 : 1.0
                font.bold: true

                SequentialAnimation on opacity {
                    running: !compact.loading && !compact.error && compact.pct >= 100
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.4; duration: 1000 }
                    NumberAnimation { from: 0.4; to: 1.0; duration: 1000 }
                }
            }

            PC3.Label {
                Layout.fillHeight: true
                verticalAlignment: Text.AlignVCenter
                text: "⏱"
                opacity: compact.loading ? 0.5 : (compact.stale ? 0.7 : 1.0)
            }

            PC3.Label {
                Layout.fillHeight: true
                verticalAlignment: Text.AlignVCenter
                text: (compact.error || compact.loading ? "--" : root.fmtCountdown(compact.secs))
                      + (compact.stale ? "?" : "")
                color: Kirigami.Theme.textColor
                opacity: compact.loading ? 0.5 : (compact.stale ? 0.7 : 1.0)
            }
        }
    }

    // Expanded view (desktop / plasmawindowed / popup). Panel uses compact only
    // because preferredRepresentation is forced above.
    fullRepresentation: ColumnLayout {
        id: full
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 7
        spacing: Kirigami.Units.smallSpacing

        function pctText(b) {
            if (root.uiState === "loading") return "--%";
            if (!b) return "N/A";
            return Math.round(b.pct) + "%";
        }
        function timeText(b) {
            if (root.uiState === "loading") return "⏱ --";
            if (!b) return "";
            return "⏱ " + root.fmtCountdown(root.remainingSecs(b));
        }
        function rowColor(b) {
            return b ? root.statusColor(b.pct) : Kirigami.Theme.textColor;
        }

        PC3.Label {
            Layout.alignment: Qt.AlignHCenter
            text: i18n("Claude Usage")
            font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
        }

        PC3.Label {
            Layout.alignment: Qt.AlignHCenter
            visible: root.uiState === "error"
            text: "⚠️  " + i18n("No data")
            color: root.statusColor(100)
        }

        GridLayout {
            Layout.alignment: Qt.AlignHCenter
            visible: root.uiState !== "error"
            columns: 3
            rowSpacing: Kirigami.Units.smallSpacing
            columnSpacing: Kirigami.Units.largeSpacing

            // --- session row ---
            PC3.Label {
                text: "▓ " + i18n("Session")
                color: full.rowColor(root.usage ? root.usage.session : null)
            }
            PC3.Label {
                Layout.alignment: Qt.AlignRight
                horizontalAlignment: Text.AlignRight
                text: full.pctText(root.usage ? root.usage.session : null)
                color: full.rowColor(root.usage ? root.usage.session : null)
            }
            PC3.Label {
                text: full.timeText(root.usage ? root.usage.session : null)
                color: Kirigami.Theme.textColor
            }

            // --- weekly row ---
            PC3.Label {
                text: "📅 " + i18n("Weekly")
                color: full.rowColor(root.usage ? root.usage.weekly : null)
            }
            PC3.Label {
                Layout.alignment: Qt.AlignRight
                horizontalAlignment: Text.AlignRight
                text: full.pctText(root.usage ? root.usage.weekly : null)
                color: full.rowColor(root.usage ? root.usage.weekly : null)
            }
            PC3.Label {
                text: full.timeText(root.usage ? root.usage.weekly : null)
                color: Kirigami.Theme.textColor
            }
        }

        PC3.Label {
            Layout.alignment: Qt.AlignHCenter
            opacity: 0.6
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: root.uiState === "stale" ? i18n("data may be stale")
                  : root.uiState === "loading" ? i18n("loading…")
                  : i18n("click the panel icon to toggle")
        }
    }
}
