import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_refreshIntervalSeconds: refreshInterval.value

    QQC2.SpinBox {
        id: refreshInterval
        Kirigami.FormData.label: i18n("Refresh interval (seconds):")
        from: 60
        to: 3600
        stepSize: 30
        value: 300
        editable: true
    }
}
