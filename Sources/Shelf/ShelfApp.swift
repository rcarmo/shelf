import SwiftUI

@main
struct ShelfApp: App {
    @StateObject private var monitor = ContextMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 500, minHeight: 320)
                .task {
                    await monitor.start()
                }
        }
        .windowStyle(.titleBar)

        Settings {
            PermissionsView()
                .environmentObject(monitor)
                .frame(width: 460)
                .padding()
        }
    }
}
