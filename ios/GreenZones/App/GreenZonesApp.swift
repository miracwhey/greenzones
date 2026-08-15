import SwiftUI

@main
struct GreenZonesApp: App {
    // Push und Share-Accept laufen ueber UIKit-Delegates — SwiftUI erreicht
    // beides nur ueber diesen Adaptor (SPEC 11).
    @UIApplicationDelegateAdaptor(GZAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
