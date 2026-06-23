import Foundation
import PushKit

/// VoIP push `link` values — must match `Links` in notification_linksz.dart.
private enum VoipPushLink {
    static let incomingCall = "core/incoming-call"
    static let callDeclined = "core/call-declined"
    static let callCancelled = "core/call-cancelled"
}

/// Handles PushKit VoIP push registration and token management.
///
/// ## Key Design Decision
///
/// PushKit is handled INSIDE the plugin, not in AppDelegate.
/// This eliminates the requirement for app developers to write
/// PushKit boilerplate in their AppDelegate.
///
/// ## Important iOS Requirements
///
/// - PushKit tokens MUST be registered on every app launch.
/// - When a VoIP push arrives, `reportNewIncomingCall` MUST be called
///   synchronously before the completion handler returns, or iOS will
///   terminate the app.
class PushKitHandler: NSObject {

    // MARK: - Properties

    private weak var plugin: CallBundlePlugin?
    private var voipRegistry: PKPushRegistry?

    /// The current VoIP push token as a hex string.
    private(set) var currentVoipToken: String?

    // MARK: - Init

    init(plugin: CallBundlePlugin) {
        self.plugin = plugin
        super.init()
    }

    // MARK: - Registration

    /// Registers for VoIP push notifications.
    ///
    /// Must be called after `configure()` to ensure CallKit is ready.
    func registerForVoipPush() {
        let registry = PKPushRegistry(queue: DispatchQueue.main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.voipRegistry = registry
    }
}

// MARK: - PKPushRegistryDelegate

extension PushKitHandler: PKPushRegistryDelegate {

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }

        let token = pushCredentials.token
            .map { String(format: "%02x", $0) }
            .joined()

        currentVoipToken = token
        NSLog("[CallBundle] VoIP token updated: \(token.prefix(8))...")

        plugin?.sendVoipTokenUpdate(token: token)
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let data = payload.dictionaryPayload
        let link = data["link"] as? String
        NSLog("[CallBundle] VoIP push received link=\(link ?? "nil")")

        // Cancel/decline VoIP pushes must dismiss the active CallKit call — not
        // report a new incoming call (which would flash "Unknown" caller name).
        if link == VoipPushLink.callCancelled || link == VoipPushLink.callDeclined {
            if let callId = extractCallId(from: data) {
                dismissCall(callId: callId, link: link!)
            } else {
                NSLog("[CallBundle] VoIP dismiss: missing callId for link=\(link!)")
            }
            completion()
            return
        }

        // Extract call data from push payload
        let callId = extractCallId(from: data) ?? UUID().uuidString
        let pushExtra = buildPushExtra(from: data, callId: callId)
        let callerName = pushExtra["callerName"] as? String ?? "Unknown"
        let handle = pushExtra["handle"] as? String ?? ""
        let hasVideo = pushExtra["hasVideo"] as? Bool ?? false
        let callerAvatar = pushExtra["userImage"] as? String
            ?? pushExtra["callerAvatar"] as? String

        // CRITICAL: Must report incoming call SYNCHRONOUSLY here.
        // iOS will terminate the app if reportNewIncomingCall is not
        // called before this completion handler returns.
        guard let callKitController = (CallBundlePlugin.shared as? CallBundlePlugin)?.callKitControllerForPush else {
            // Fallback: report via the plugin's controller
            plugin?.sendCallEvent(
                type: "incoming",
                callId: callId,
                isUserInitiated: false,
                extra: pushExtra
            )
            completion()
            return
        }

        let uuid = uuidFromString(callId)

        // Store call data in callStore BEFORE reporting to CallKit.
        // This ensures the data is available if the user answers immediately
        // (CXAnswerCallAction can fire before Dart's handleShowIncomingCall runs).
        (CallBundlePlugin.shared as? CallBundlePlugin)?.callStoreForPush?.addCall(
            callId: callId, callerName: callerName, handle: handle, callerAvatar: callerAvatar, extra: pushExtra
        )

        callKitController.reportIncomingCall(
            uuid: uuid,
            callId: callId,
            handle: handle,
            handleType: .generic,
            callerName: callerName,
            hasVideo: hasVideo
        ) { [weak self] error in
            if error == nil {
                self?.plugin?.sendCallEvent(
                    type: "incoming",
                    callId: callId,
                    isUserInitiated: false,
                    extra: pushExtra
                )
            }
            completion()
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        NSLog("[CallBundle] VoIP token invalidated")
        currentVoipToken = nil
    }

    // MARK: - Utilities

    /// Dismisses an active CallKit call for remote cancel/decline VoIP pushes.
    private func dismissCall(callId: String, link: String) {
        let plugin = CallBundlePlugin.shared as? CallBundlePlugin
        let uuid = uuidFromString(callId)

        NSLog("[CallBundle] VoIP dismiss: link=\(link) callId=\(callId)")

        plugin?.callKitControllerForPush?.endCall(uuid: uuid)
        plugin?.callStoreForPush?.removeCall(callId: callId)
    }

    /// Resolves call ID from flat or nested notification payload.
    private func extractCallId(from data: [AnyHashable: Any]) -> String? {
        if let callId = data["callId"] as? String, !callId.isEmpty { return callId }
        if let id = data["id"] as? String, !id.isEmpty { return id }

        if let nested = data["data"] as? [String: Any] {
            if let callId = nested["callId"] as? String, !callId.isEmpty { return callId }
            if let id = nested["id"] as? String, !id.isEmpty { return id }
        }

        if let payload = data["payload"] as? String,
           let jsonData = payload.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let nested = json["data"] as? [String: Any] {
            if let callId = nested["callId"] as? String, !callId.isEmpty { return callId }
            if let id = nested["id"] as? String, !id.isEmpty { return id }
        }

        return nil
    }

    /// Preserves the full VoIP payload and normalizes keys expected by
    /// `CallData.fromMap` in Dart event listeners.
    private func buildPushExtra(
        from data: [AnyHashable: Any],
        callId: String
    ) -> [String: Any] {
        var pushExtra: [String: Any] = [:]
        for (key, value) in data {
            if let key = key as? String, key != "aps" {
                pushExtra[key] = value
            }
        }

        let callerName = stringValue(from: data, keys: [
            "callerUserDisplayName", "callerName", "caller_name",
        ]) ?? "Unknown"
        let handle = stringValue(from: data, keys: ["handle", "phone"]) ?? ""
        let hasVideo = boolValue(from: data, key: "hasVideo")
            || boolValue(from: data, key: "has_video")
        let isReceiverServant = boolValue(from: data, key: "isReceiverServant")

        pushExtra["id"] = callId
        pushExtra["callId"] = callId
        pushExtra["callerName"] = callerName
        pushExtra["callerUserDisplayName"] = callerName
        pushExtra["handle"] = handle
        pushExtra["hasVideo"] = hasVideo
        pushExtra["isReceiverServant"] = isReceiverServant
        pushExtra["roleSegment"] = isReceiverServant ? "servant" : "client"

        if let tripId = intValue(from: data, key: "tripId") {
            pushExtra["tripId"] = tripId
        }
        if let channelId = stringValue(from: data, keys: ["channelId"]) {
            pushExtra["channelId"] = channelId
        }
        if let callerUserId = stringValue(from: data, keys: ["callerUserId"]) {
            pushExtra["callerUserId"] = callerUserId
        }
        if let receiverUserId = stringValue(from: data, keys: ["receiverUserId"]) {
            pushExtra["receiverUserId"] = receiverUserId
        }
        if let userImage = stringValue(from: data, keys: ["userImage", "callerAvatar", "caller_avatar"]) {
            pushExtra["userImage"] = userImage
        }
        if let timeoutAt = stringValue(from: data, keys: ["timeoutAt"]) {
            pushExtra["timeoutAt"] = timeoutAt
        }
        if let agoraRtcToken = stringValue(from: data, keys: ["agoraRtcToken"]) {
            pushExtra["agoraRtcToken"] = agoraRtcToken
        }

        return pushExtra
    }

    private func stringValue(from data: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = data[key] as? String, !value.isEmpty { return value }
            if let value = data[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func boolValue(from data: [AnyHashable: Any], key: String) -> Bool {
        if let value = data[key] as? Bool { return value }
        if let value = data[key] as? NSNumber { return value.boolValue }
        if let value = data[key] as? String {
            return value == "true" || value == "1"
        }
        return false
    }

    private func intValue(from data: [AnyHashable: Any], key: String) -> Int? {
        if let value = data[key] as? Int { return value }
        if let value = data[key] as? NSNumber { return value.intValue }
        if let value = data[key] as? String { return Int(value) }
        return nil
    }

    private func uuidFromString(_ string: String) -> UUID {
        if let uuid = UUID(uuidString: string) {
            return uuid
        }
        guard let data = string.data(using: .utf8) else {
            return UUID() // Fallback: random UUID if encoding somehow fails
        }
        var hash = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { bytes in
            for (i, byte) in bytes.enumerated() {
                hash[i % 16] ^= byte
            }
        }
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: hash) as UUID
    }
}
