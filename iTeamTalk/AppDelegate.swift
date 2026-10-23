import UIKit
import TeamTalkKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TeamTalkClient.shared.start(licenseName: REGISTRATION_NAME, licenseKey: REGISTRATION_KEY)
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        TeamTalkClient.shared.close()
    }
}
