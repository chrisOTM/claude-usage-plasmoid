import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_refreshIntervalSeconds: refreshInterval.value
    property alias cfg_notifyOnReset: notifyCheck.checked
    property alias cfg_soundEnabled: soundCheck.checked
    // ComboBoxes store a string -> use plain cfg_ properties (not aliases) so
    // KConfig binds them; the combos read/write these directly.
    property string cfg_notifyUrgency: "Normal"
    property string cfg_soundName: "bell"

    QQC2.SpinBox {
        id: refreshInterval
        Kirigami.FormData.label: i18n("Refresh interval (seconds):")
        from: 60
        to: 3600
        stepSize: 30
        value: 300
        editable: true
    }

    Item { Kirigami.FormData.isSection: true }

    QQC2.CheckBox {
        id: notifyCheck
        Kirigami.FormData.label: i18n("Notify on reset:")
    }

    QQC2.ComboBox {
        Kirigami.FormData.label: i18n("Urgency:")
        enabled: notifyCheck.checked
        model: ["Low", "Normal", "Critical"]
        currentIndex: Math.max(0, model.indexOf(page.cfg_notifyUrgency))
        onActivated: page.cfg_notifyUrgency = model[currentIndex]
    }

    QQC2.CheckBox {
        id: soundCheck
        Kirigami.FormData.label: i18n("Play sound:")
    }

    QQC2.ComboBox {
        Kirigami.FormData.label: i18n("Sound:")
        enabled: soundCheck.checked
        // display label -> stored freedesktop basename
        property var names: ["bell", "complete", "message", "window-attention"]
        model: [i18n("Bell"), i18n("Complete"), i18n("Message"), i18n("Attention")]
        currentIndex: Math.max(0, names.indexOf(page.cfg_soundName))
        onActivated: page.cfg_soundName = names[currentIndex]
    }
}
