import Foundation
import Capacitor

/// Bridge zwischen dem TS-Sync-Layer und `CloudKitService`.
/// Jede Methode rejected mit einem Code aus dem Contract; `fetchAll` rejected NIE wegen
/// fehlendem Account, sondern liefert einen leeren Snapshot mit Status.
@objc(CloudKitSyncPlugin)
public class CloudKitSyncPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CloudKitSyncPlugin"
    public let jsName = "CloudKitSync"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getAccountStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "fetchAll", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createFriendInvite", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "acceptShare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDisplayName", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createSpotShare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "offerSpotToFriends", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteSpot", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveInvitation", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveReply", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "registerSubscriptions", returnType: CAPPluginReturnPromise)
    ]

    private var changeObserver: NSObjectProtocol?

    override public func load() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: CloudKitService.cloudChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyListeners("cloudChanged", data: nil)
        }
    }

    deinit {
        if let changeObserver = changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    // MARK: - Methoden

    @objc func getAccountStatus(_ call: CAPPluginCall) {
        run(call) {
            ["status": try await CloudKitService.shared.accountStatusName()]
        }
    }

    @objc func fetchAll(_ call: CAPPluginCall) {
        run(call) {
            try await CloudKitService.shared.fetchSnapshot()
        }
    }

    @objc func createFriendInvite(_ call: CAPPluginCall) {
        let displayName = call.getString("displayName") ?? ""
        run(call) {
            ["url": try await CloudKitService.shared.createFriendInvite(displayName: displayName)]
        }
    }

    @objc func acceptShare(_ call: CAPPluginCall) {
        guard let url = call.getString("url"), !url.isEmpty else {
            return reject(call, SyncError(.notFound, "Dieser Einladungslink ist unvollständig."))
        }
        let displayName = call.getString("displayName") ?? ""
        run(call) {
            try await CloudKitService.shared.acceptShare(urlString: url, displayName: displayName)
            return [:]
        }
    }

    @objc func setDisplayName(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        run(call) {
            try await CloudKitService.shared.setDisplayName(name)
            return [:]
        }
    }

    @objc func createSpotShare(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty else {
            return reject(call, SyncError(.internalFailure, "Der Spot hat keine Kennung."))
        }
        let name = call.getString("name") ?? ""
        let emoji = call.getString("emoji") ?? ""
        let lng = call.getDouble("lng") ?? 0
        let lat = call.getDouble("lat") ?? 0
        let createdAt = call.getDouble("createdAt") ?? Date().millisSince1970

        run(call) {
            let result = try await CloudKitService.shared.createSpotShare(
                id: id, name: name, emoji: emoji, lng: lng, lat: lat, createdAt: createdAt
            )
            return ["zoneName": result.zoneName, "shareURL": result.shareURL]
        }
    }

    @objc func offerSpotToFriends(_ call: CAPPluginCall) {
        guard let zoneName = call.getString("zoneName"), !zoneName.isEmpty,
              let shareURL = call.getString("shareURL"), !shareURL.isEmpty else {
            return reject(call, SyncError(.internalFailure, "Zu diesem Spot fehlt die Freigabe."))
        }
        let spotName = call.getString("spotName") ?? ""
        let spotEmoji = call.getString("spotEmoji") ?? ""
        let friendshipZones = call.getArray("friendshipZones", String.self) ?? []

        run(call) {
            try await CloudKitService.shared.offerSpotToFriends(
                zoneName: zoneName, shareURL: shareURL, spotName: spotName,
                spotEmoji: spotEmoji, friendshipZones: friendshipZones
            )
            return [:]
        }
    }

    @objc func deleteSpot(_ call: CAPPluginCall) {
        guard let zoneName = call.getString("zoneName"), !zoneName.isEmpty else {
            return reject(call, SyncError(.notFound, "Diesen Spot gibt es in iCloud nicht mehr."))
        }
        run(call) {
            try await CloudKitService.shared.deleteSpot(zoneName: zoneName)
            return [:]
        }
    }

    @objc func saveInvitation(_ call: CAPPluginCall) {
        guard let spotZone = call.getString("spotZone"), !spotZone.isEmpty,
              let id = call.getString("id"), !id.isEmpty else {
            return reject(call, SyncError(.internalFailure, "Zur Einladung fehlen Spot oder Kennung."))
        }
        let time = call.getDouble("time") ?? 0
        let createdAt = call.getDouble("createdAt") ?? Date().millisSince1970
        let cancelled = call.getBool("cancelled") ?? false

        run(call) {
            try await CloudKitService.shared.saveInvitation(
                spotZone: spotZone, id: id, time: time, createdAt: createdAt, cancelled: cancelled
            )
            return [:]
        }
    }

    @objc func saveReply(_ call: CAPPluginCall) {
        guard let spotZone = call.getString("spotZone"), !spotZone.isEmpty,
              let invitationId = call.getString("invitationId"), !invitationId.isEmpty else {
            return reject(call, SyncError(.internalFailure, "Zur Antwort fehlen Spot oder Einladung."))
        }
        let status = call.getString("status") ?? "out"
        let arrivalTime = call.getDouble("arrivalTime")

        run(call) {
            try await CloudKitService.shared.saveReply(
                spotZone: spotZone, invitationId: invitationId, status: status, arrivalTime: arrivalTime
            )
            return [:]
        }
    }

    @objc func registerSubscriptions(_ call: CAPPluginCall) {
        run(call) {
            try await CloudKitService.shared.registerSubscriptions()
            return [:]
        }
    }

    // MARK: - Ausführung

    private func run(_ call: CAPPluginCall, _ body: @escaping () async throws -> PluginCallResultData) {
        Task {
            do {
                call.resolve(try await body())
            } catch {
                self.reject(call, error)
            }
        }
    }

    private func reject(_ call: CAPPluginCall, _ error: Error) {
        call.reject(CKErrorMapper.message(for: error), CKErrorMapper.code(for: error).rawValue, error)
    }
}
