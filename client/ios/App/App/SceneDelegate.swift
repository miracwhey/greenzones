import UIKit
import Capacitor
import CloudKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        // BridgeViewController statt CAPBridgeViewController: dort hängt die Plugin-Registrierung.
        window?.rootViewController = BridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)

        // Kaltstart-Weg für Share-Links: läuft die App nicht, ruft iOS
        // `userDidAcceptCloudKitShareWith` NICHT — die Metadaten kommen dann ausschließlich hier an.
        // Genau der Fall „frisch installiert, Link getippt".
        if let metadata = connectionOptions.cloudKitShareMetadata {
            CloudKitService.shared.handleAcceptedShare(metadata)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }

    /// Weg für Share-Links bei laufender App (Vordergrund oder Hintergrund mit lebender Scene);
    /// iOS reicht die Metadaten durch, annehmen muss die App selbst.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        CloudKitService.shared.handleAcceptedShare(cloudKitShareMetadata)
    }
}
