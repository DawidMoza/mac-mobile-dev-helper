import SwiftUI

extension Notification.Name {
    static let checkForAppUpdates = Notification.Name("checkForAppUpdates")
}

@main
struct MobileDevHelperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForAppUpdates, object: nil)
                }
            }
        }
    }
}
