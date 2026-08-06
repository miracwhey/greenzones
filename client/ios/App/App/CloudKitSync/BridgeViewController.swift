import UIKit
import Capacitor

/// Capacitor registriert seit 6 keine lokalen Plugins mehr automatisch — Plugins, die nicht als
/// npm-Paket vorliegen, hängen an dieser Subclass. Storyboard und SceneDelegate zeigen deshalb
/// auf `BridgeViewController`, nicht mehr auf `CAPBridgeViewController`.
class BridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(CloudKitSyncPlugin())
        NSLog("[GreenZones] CloudKitSync registered")
        CAPLog.print("[GreenZones] CloudKitSync registered")
    }
}
