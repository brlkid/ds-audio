import SwiftUI

@main
struct TTCustomApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LiveKitOnlyRootView()
        }
    }
}
