import SwiftUI
import StoneVPNCore

struct NotificationsTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Show") {
                Toggle("Tunnel Connected", isOn: $model.prefs.notifyConnected).settingsAnchor("notify.connected")
                Toggle("Tunnel Disconnected", isOn: $model.prefs.notifyDisconnected).settingsAnchor("notify.disconnected")
                Toggle("Tunnel Dropped Unexpectedly", isOn: $model.prefs.notifyDropped).settingsAnchor("notify.dropped")
                Toggle("DNS Not Responding", isOn: $model.prefs.notifyDNS).settingsAnchor("notify.dns")
                Toggle("A Foreign VPN Took Over the Route", isOn: $model.prefs.notifyForeign).settingsAnchor("notify.foreign")
                Toggle("A VPN Server Goes Through Another Tunnel", isOn: $model.prefs.notifyRoutes).settingsAnchor("notify.routes")
            }
        }
        .formStyle(.grouped)
    }
}
