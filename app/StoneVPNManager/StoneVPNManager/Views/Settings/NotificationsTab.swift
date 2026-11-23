import SwiftUI
import StoneVPNCore

struct NotificationsTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Show") {
                Toggle("Tunnel Connected", isOn: $model.prefs.notifyConnected)
                Toggle("Tunnel Disconnected", isOn: $model.prefs.notifyDisconnected)
                Toggle("Tunnel Dropped Unexpectedly", isOn: $model.prefs.notifyDropped)
                Toggle("DNS Not Responding", isOn: $model.prefs.notifyDNS)
                Toggle("A Foreign VPN Took Over the Route", isOn: $model.prefs.notifyForeign)
            }
        }
        .formStyle(.grouped)
    }
}
