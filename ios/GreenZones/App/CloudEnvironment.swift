import CloudKit
import GreenZonesKit
import SwiftUI
import UIKit

/// Der CloudKit-Zugang des Prozesses.
///
/// Warum an dieser Stelle und nicht im `AppModel`: den Share-Accept fuehrt das
/// System aus, bevor irgendeine View existiert — beim Kaltstart ueber einen
/// Einladungs-Link liegt die Metadata schon in den `connectionOptions`. Der
/// `SceneDelegate` braucht denselben Zugang wie das Modell, sonst nimmt der eine
/// an, was der andere nie sieht.
enum GZCloud {
    /// Fixture-Laeufe (Screenshots, UI-Tests) bleiben ohne Cloud: sie duerfen
    /// weder auf echte Konten zugreifen noch auf Netz warten.
    static let gateway: any CloudGateway = {
        #if DEBUG
        if DebugEnvironment.usesFixtures { return NoCloudGateway() }
        #endif
        return CloudKitGateway()
    }()

    /// Feuert, wenn sich der Cloud-Zustand geaendert haben kann: Push oder
    /// Share-Accept. Das Modell laedt daraufhin nach.
    static let changed = Notification.Name("GreenZonesCloudChanged")

    static func postChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Angenommener Share (Kaltstart wie laufend). Fehler bleiben hier stehen:
    /// der folgende Fetch zeigt ohnehin, ob die Zone da ist.
    static func accept(_ metadata: CKShare.Metadata) {
        Task {
            if let cloudKit = gateway as? CloudKitGateway {
                try? await cloudKit.acceptShare(metadata: metadata)
            }
            postChanged()
        }
    }
}

/// Push-Empfang und Szenen-Verdrahtung. SwiftUI braucht beides ueber Adaptoren:
/// Remote-Notifications kennt nur der App-Delegate, den Share-Accept nur der
/// Szenen-Delegate.
final class GZAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              note.notificationType == .database else {
            return .noData
        }
        GZCloud.postChanged()
        return .newData
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = GZSceneDelegate.self
        return configuration
    }
}

final class GZSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Kaltstart ueber den Einladungs-Link: die Metadata liegt bereits an der
    /// Verbindung. Ohne diesen Weg bliebe eine Einladung unbeantwortet, bis der
    /// Nutzer sie ein zweites Mal antippt.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            GZCloud.accept(metadata)
        }
    }

    /// Laufende App: der Nutzer tippt den Link an, waehrend GreenZones offen ist.
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        GZCloud.accept(cloudKitShareMetadata)
    }
}
