import Flutter
import UIKit
import CallKit
import PushKit
import AVFoundation
import Security

/// Main entry point for the CallBundle iOS plugin.
///
/// Handles all MethodChannel communication between Dart and native iOS.
/// Coordinates CallKit, PushKit, audio session, and notification managers.
///
/// ## Key Architecture Decisions
///
/// - **PushKit handled IN the plugin** — eliminates AppDelegate code.
/// - **MethodChannel for ALL native→Dart events** — no EventChannel/WeakReference.
/// - **isUserInitiated** on events — eliminates _isEndingCallKitProgrammatically flag.
/// - **PendingCallStore** for cold-start — eliminates 3-second hardcoded delay.
/// - **AudioSessionManager** with `.mixWithOthers` — prevents HMS audio kill.
public class CallBundlePlugin: NSObject, FlutterPlugin {

    // MARK: - Properties

    private var channel: FlutterMethodChannel?
    private var callKitController: CallKitController?
    private var pushKitHandler: PushKitHandler?
    private var audioSessionManager: AudioSessionManager?
    private var callStore: CallStore?
    private var missedCallManager: MissedCallNotificationManager?
    private var isReady = false

    /// Monotonically increasing event ID for Dart-side deduplication.
    private var eventIdCounter: Int = 0

    /// Singleton for access from PushKit callbacks (which fire before Flutter engine is ready).
    static var shared: CallBundlePlugin?

    /// Exposes the CallKit controller for PushKit handler access.
    var callKitControllerForPush: CallKitController? {
        return callKitController
    }

    /// Exposes the call store for PushKit handler access.
    var callStoreForPush: CallStore? {
        return callStore
    }

    // MARK: - Plugin Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.callbundle/main",
            binaryMessenger: registrar.messenger()
        )
        let instance = CallBundlePlugin()
        instance.channel = channel
        instance.callStore = CallStore()
        instance.audioSessionManager = AudioSessionManager()
        instance.missedCallManager = MissedCallNotificationManager()

        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)

        // Initialize CallKit
        instance.callKitController = CallKitController(plugin: instance)

        // Initialize PushKit
        instance.pushKitHandler = PushKitHandler(plugin: instance)

        CallBundlePlugin.shared = instance

        // Register PushKit AFTER all initialization is complete
        instance.pushKitHandler?.registerForVoipPush()
    }

    // MARK: - MethodChannel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            handleConfigure(call, result: result)
        case "showIncomingCall":
            handleShowIncomingCall(call, result: result)
        case "showOutgoingCall":
            handleShowOutgoingCall(call, result: result)
        case "endCall":
            handleEndCall(call, result: result)
        case "endAllCalls":
            handleEndAllCalls(result: result)
        case "setCallConnected":
            handleSetCallConnected(call, result: result)
        case "getActiveCalls":
            handleGetActiveCalls(result: result)
        case "checkPermissions":
            handleCheckPermissions(result: result)
        case "requestPermissions":
            handleRequestPermissions(result: result)
        case "requestBatteryOptimizationExemption":
            // Battery optimization is an Android concept — always exempt on iOS
            result(true)
        case "getVoipToken":
            handleGetVoipToken(result: result)
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Implementations

    private func handleConfigure(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected map arguments", details: nil))
            return
        }

        let iosConfig = args["ios"] as? [String: Any]
        let appName = iosConfig?["appName"] as? String ?? "CallBundle"
        let iconTemplateImageName = iosConfig?["iconTemplateImageName"] as? String
        let ringtoneSound = iosConfig?["ringtoneSound"] as? String
        let supportsVideo = iosConfig?["supportsVideo"] as? Bool ?? false
        let maximumCallGroups = iosConfig?["maximumCallGroups"] as? Int ?? 1
        let maximumCallsPerCallGroup = iosConfig?["maximumCallsPerCallGroup"] as? Int ?? 1
        let includesCallsInRecents = iosConfig?["includesCallsInRecents"] as? Bool ?? true

        callKitController?.configure(
            appName: appName,
            iconTemplateImageName: iconTemplateImageName,
            ringtoneSound: ringtoneSound,
            supportsVideo: supportsVideo,
            maximumCallGroups: maximumCallGroups,
            maximumCallsPerCallGroup: maximumCallsPerCallGroup,
            includesCallsInRecents: includesCallsInRecents
        )

        if let backgroundReject = args["backgroundReject"] as? [String: Any] {
            BackgroundCallRejectHelper.storeConfig(backgroundReject)
        }

        // Send ready signal
        isReady = true
        sendReadySignal()

        // Deliver pending events from cold-start
        deliverPendingEvents()

        result(nil)
    }

    private func handleShowIncomingCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected map arguments", details: nil))
            return
        }

        let callId = args["callId"] as? String ?? UUID().uuidString
        let callerName = args["callerName"] as? String ?? "Unknown"
        let handle = args["handle"] as? String ?? ""
        let callType = (args["callType"] as? Int) ?? 0
        let callerAvatar = args["callerAvatar"] as? String
        let iosParams = args["ios"] as? [String: Any]

        // Read handleType from nested ios params
        let handleTypeStr = iosParams?["handleType"] as? String ?? "generic"
        // Determine hasVideo from callType (1 = video) or ios.supportsVideo
        let hasVideo = callType == 1 || (iosParams?["supportsVideo"] as? Bool ?? false)

        let cxHandleType: CXHandle.HandleType
        switch handleTypeStr {
        case "phone":
            cxHandleType = .phoneNumber
        case "email":
            cxHandleType = .emailAddress
        default:
            cxHandleType = .generic
        }

        // Store call data BEFORE reporting to CallKit so it's available
        // immediately when the user answers (CXAnswerCallAction can fire
        // very quickly after reportNewIncomingCall).
        let extra = args["extra"] as? [String: Any]
        // Use addOrUpdateCall so that if PushKit already stored a basic entry,
        // the richer extra from Dart is merged in rather than creating a duplicate.
        callStore?.addOrUpdateCall(callId: callId, callerName: callerName, handle: handle, callerAvatar: callerAvatar, extra: extra)

        callKitController?.reportIncomingCall(
            uuid: uuidFromString(callId),
            callId: callId,
            handle: handle,
            handleType: cxHandleType,
            callerName: callerName,
            hasVideo: hasVideo
        ) { error in
            if let error = error {
                // PushKit may have already reported this call. Extra was merged above;
                // treat duplicate UUID as success so Dart does not surface an error.
                if CallKitController.isCallUUIDAlreadyExists(error) {
                    result(nil)
                    return
                }

                result(FlutterError(
                    code: "INCOMING_CALL_ERROR",
                    message: error.localizedDescription,
                    details: nil
                ))
            } else {
                result(nil)
            }
        }
    }

    private func handleShowOutgoingCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected map arguments", details: nil))
            return
        }

        let callId = args["callId"] as? String ?? UUID().uuidString
        let callerName = args["callerName"] as? String ?? "Unknown"
        let handle = args["handle"] as? String ?? ""
        let callType = (args["callType"] as? Int) ?? 0
        let callerAvatar = args["callerAvatar"] as? String
        let iosParams = args["ios"] as? [String: Any]

        // Read handleType from nested ios params
        let handleTypeStr = iosParams?["handleType"] as? String ?? "generic"
        // Determine hasVideo from callType (1 = video) or ios.supportsVideo
        let hasVideo = callType == 1 || (iosParams?["supportsVideo"] as? Bool ?? false)

        let cxHandleType: CXHandle.HandleType
        switch handleTypeStr {
        case "phone":
            cxHandleType = .phoneNumber
        case "email":
            cxHandleType = .emailAddress
        default:
            cxHandleType = .generic
        }

        callKitController?.startOutgoingCall(
            uuid: uuidFromString(callId),
            callId: callId,
            handle: handle,
            handleType: cxHandleType,
            callerName: callerName,
            hasVideo: hasVideo
        )

        callStore?.addCall(callId: callId, callerName: callerName, handle: handle, callerAvatar: callerAvatar, extra: args["extra"] as? [String: Any])
        result(nil)
    }

    private func handleEndCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Dart sends callId as a plain string, not a map
        guard let callId = call.arguments as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing callId", details: nil))
            return
        }

        callKitController?.endCall(uuid: uuidFromString(callId))
        result(nil)
    }

    private func handleEndAllCalls(result: @escaping FlutterResult) {
        callKitController?.endAllCalls()
        result(nil)
    }

    private func handleSetCallConnected(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Dart sends callId as a plain string, not a map
        guard let callId = call.arguments as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing callId", details: nil))
            return
        }

        callKitController?.reportCallConnected(uuid: uuidFromString(callId))
        callStore?.updateCallState(callId: callId, state: "active")
        result(nil)
    }

    private func handleGetActiveCalls(result: @escaping FlutterResult) {
        let calls = callStore?.getAllCalls() ?? []
        result(calls)
    }

    /// Checks current permission status without prompting.
    private func handleCheckPermissions(result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let notifStatus: String
            switch settings.authorizationStatus {
            case .authorized:
                notifStatus = "granted"
            case .denied:
                notifStatus = "permanentlyDenied"
            case .notDetermined:
                notifStatus = "notDetermined"
            case .provisional:
                notifStatus = "granted"
            case .ephemeral:
                notifStatus = "granted"
            @unknown default:
                notifStatus = "notDetermined"
            }

            let device = UIDevice.current
            let permissionInfo: [String: Any] = [
                "notificationPermission": notifStatus,
                "fullScreenIntentPermission": "granted",
                "phoneAccountEnabled": true,
                "batteryOptimizationExempt": true,
                "manufacturer": "apple",
                "model": device.model,
                "osVersion": device.systemVersion,
            ]
            DispatchQueue.main.async {
                result(permissionInfo)
            }
        }
    }

    /// Requests permissions (triggers system dialogs) and returns updated status.
    private func handleRequestPermissions(result: @escaping FlutterResult) {
        missedCallManager?.requestNotificationPermission { [weak self] granted in
            // After requesting, get actual status for accurate mapping
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let notifStatus: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    notifStatus = "granted"
                case .denied:
                    notifStatus = "permanentlyDenied"
                case .notDetermined:
                    notifStatus = "denied"
                @unknown default:
                    notifStatus = "denied"
                }

                let device = UIDevice.current
                let permissionInfo: [String: Any] = [
                    "notificationPermission": notifStatus,
                    "fullScreenIntentPermission": "granted",
                    "phoneAccountEnabled": true,
                    "batteryOptimizationExempt": true,
                    "manufacturer": "apple",
                    "model": device.model,
                    "osVersion": device.systemVersion,
                ]
                DispatchQueue.main.async {
                    result(permissionInfo)
                }
            }
        }
    }

    private func handleGetVoipToken(result: @escaping FlutterResult) {
        result(pushKitHandler?.currentVoipToken)
    }

    private func handleDispose(result: @escaping FlutterResult) {
        isReady = false
        result(nil)
    }

    // MARK: - Native → Dart Communication

    /// Sends a call event to Dart via MethodChannel.
    ///
    /// Uses `isUserInitiated` to distinguish user actions from programmatic
    /// actions, eliminating the `_isEndingCallKitProgrammatically` flag.
    func sendCallEvent(type: String, callId: String, isUserInitiated: Bool, extra: [String: Any]? = nil) {
        // Resolve extra: use provided extra, or fall back to callStore's stored extra
        let resolvedExtra: [String: Any]?
        if let extra = extra, !extra.isEmpty {
            resolvedExtra = extra
        } else {
            resolvedExtra = callStore?.getCall(callId: callId)?.extra
        }

        NSLog("[CallBundle] sendCallEvent: type=\(type), callId=\(callId), extraKeys=\(resolvedExtra?.keys.sorted() ?? []), isReady=\(isReady)")

        guard isReady else {
            if type == "accepted" {
                callStore?.savePendingAccept(callId: callId, extra: resolvedExtra)
            } else if type == "declined" {
                callStore?.savePendingDecline(callId: callId, extra: resolvedExtra)
            }
            return
        }

        var event: [String: Any] = [
            "type": type,
            "callId": callId,
            "isUserInitiated": isUserInitiated,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "eventId": nextEventId(),
        ]

        if let resolvedExtra = resolvedExtra, !resolvedExtra.isEmpty {
            event["extra"] = resolvedExtra
        }

        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("onCallEvent", arguments: event)
        }
    }

    /// Sends the VoIP token update to Dart.
    func sendVoipTokenUpdate(token: String) {
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("onVoipTokenUpdated", arguments: token)
        }
    }

    /// Sends the ready signal to Dart.
    private func sendReadySignal() {
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("onReady", arguments: nil)
        }
    }

    /// Delivers pending events stored during cold-start.
    private func deliverPendingEvents() {
        if let pending = callStore?.consumePendingAccept() {
            sendCallEvent(type: "accepted", callId: pending.callId, isUserInitiated: true, extra: pending.extra)
        }
        if let pending = callStore?.consumePendingDecline() {
            sendCallEvent(type: "declined", callId: pending.callId, isUserInitiated: true, extra: pending.extra)
        }
    }

    /// Maps incoming-ring decline to `declined` + native HTTP when Dart is not ready.
    func handleCallEnded(callId: String, isUserInitiated: Bool) {
        let callInfo = callStore?.getCall(callId: callId)
        let resolvedExtra = callInfo?.extra ?? [:]
        let isIncomingDecline = isUserInitiated && (callInfo?.state == "incoming")

        if isIncomingDecline {
            let callData = callDataForReject(callId: callId, extra: resolvedExtra)
            if isReady {
                sendCallEvent(
                    type: "declined",
                    callId: callId,
                    isUserInitiated: true,
                    extra: resolvedExtra
                )
            } else {
                BackgroundCallRejectHelper.rejectCall(callData: callData)
                callStore?.savePendingDecline(callId: callId, extra: resolvedExtra)
            }
        } else {
            sendCallEvent(
                type: "ended",
                callId: callId,
                isUserInitiated: isUserInitiated,
                extra: resolvedExtra
            )
        }

        callStore?.removeCall(callId: callId)
    }

    func markCallAccepted(callId: String) {
        callStore?.updateCallState(callId: callId, state: "active")
    }

    private func callDataForReject(callId: String, extra: [String: Any]) -> [String: String] {
        var callData: [String: String] = [:]
        for (key, value) in extra {
            callData[key] = "\(value)"
        }
        callData["id"] = (extra["id"] as? String) ?? callId
        callData["callId"] = callId
        if callData["roleSegment"] == nil {
            let isServant: Bool
            if let boolValue = extra["isReceiverServant"] as? Bool {
                isServant = boolValue
            } else {
                isServant = "\(extra["isReceiverServant"] ?? false)" == "true"
            }
            callData["roleSegment"] = isServant ? "servant" : "client"
        }
        return callData
    }

    // MARK: - Audio Session

    /// Configures the audio session for a call.
    func configureAudioSession(active: Bool) {
        if active {
            audioSessionManager?.activateForCall()
        } else {
            audioSessionManager?.deactivate()
        }
    }

    // MARK: - Event ID

    /// Returns the next monotonically increasing event ID.
    /// Thread-safe via OSAtomicIncrement (called from multiple queues).
    private func nextEventId() -> Int {
        eventIdCounter += 1
        return eventIdCounter
    }

    // MARK: - Utilities

    /// Converts a string callId to a deterministic UUID.
    ///
    /// Uses UUID v5-like hashing so the same callId always maps to the same UUID.
    private func uuidFromString(_ string: String) -> UUID {
        if let uuid = UUID(uuidString: string) {
            return uuid
        }
        // Create deterministic UUID from arbitrary string
        guard let data = string.data(using: .utf8) else {
            return UUID() // Fallback: random UUID if encoding somehow fails
        }
        var hash = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { bytes in
            for (i, byte) in bytes.enumerated() {
                hash[i % 16] ^= byte
            }
        }
        // Set version (4) and variant (RFC 4122)
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80

        let uuid = NSUUID(uuidBytes: hash) as UUID
        return uuid
    }
}

// MARK: - BackgroundCallRejectHelper

enum BackgroundCallRejectHelper {
    private static let prefsSuite = "com.callbundle.bg_reject"
    private static let keyUrlPattern = "url_pattern"
    private static let keyHttpMethod = "http_method"
    private static let keyAuthStorageKey = "auth_storage_key"
    private static let keyAuthKeyPrefix = "auth_key_prefix"
    private static let keyAuthTokenCache = "auth_token_cache_json"
    private static let keyHeaders = "headers_json"
    private static let keyBody = "body"
    private static let defaultKeyPrefix =
        "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: "\\{(\\w+)\\}",
        options: []
    )

    static func storeConfig(_ configMap: [String: Any]) {
        guard let urlPattern = configMap["urlPattern"] as? String else { return }
        let defaults = UserDefaults(suiteName: prefsSuite) ?? UserDefaults.standard
        defaults.set(urlPattern, forKey: keyUrlPattern)
        defaults.set((configMap["httpMethod"] as? String) ?? "POST", forKey: keyHttpMethod)
        defaults.set(configMap["authStorageKey"] as? String, forKey: keyAuthStorageKey)
        defaults.set(configMap["authKeyPrefix"] as? String, forKey: keyAuthKeyPrefix)
        if let cache = configMap["authTokenCache"] as? [String: Any] {
            defaults.set(cache, forKey: keyAuthTokenCache)
        }
        if let headers = configMap["headers"] as? [String: Any] {
            defaults.set(headers, forKey: keyHeaders)
        }
        defaults.set(configMap["body"] as? String, forKey: keyBody)
        defaults.synchronize()
    }

    static func rejectCall(callData: [String: String]) {
        let callId = callData["callId"] ?? callData["id"]
        guard let callId, !callId.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let defaults = UserDefaults(suiteName: prefsSuite) ?? UserDefaults.standard
            guard let urlPattern = defaults.string(forKey: keyUrlPattern), !urlPattern.isEmpty else {
                NSLog("[CallBundle] BackgroundReject: no urlPattern configured")
                return
            }

            var enriched = callData
            enriched["uuid"] = UUID().uuidString
            if enriched["id"] == nil { enriched["id"] = callId }

            let resolvedUrl = resolvePlaceholders(urlPattern, data: enriched)
            let authKey = defaults.string(forKey: keyAuthStorageKey)
            let authToken = readAuthToken(
                key: authKey,
                customPrefix: defaults.string(forKey: keyAuthKeyPrefix),
                defaults: defaults
            )
            let httpMethod = defaults.string(forKey: keyHttpMethod) ?? "POST"
            let bodyTemplate = defaults.string(forKey: keyBody)
            let headers = headersMap(from: defaults)

            NSLog("[CallBundle] BackgroundReject: \(httpMethod) \(resolvedUrl) callId=\(callId)")

            let status = executeRequest(
                urlString: resolvedUrl,
                method: httpMethod,
                authToken: authToken,
                headers: headers,
                bodyTemplate: bodyTemplate,
                data: enriched
            )

            NSLog("[CallBundle] BackgroundReject: HTTP \(status) callId=\(callId)")
        }
    }

    private static func headersMap(from defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.dictionary(forKey: keyHeaders) else { return [:] }
        return raw.reduce(into: [String: String]()) { $0[$1.key] = "\($1.value)" }
    }

    private static func resolvePlaceholders(_ template: String, data: [String: String]) -> String {
        let nsTemplate = template as NSString
        let matches = placeholderRegex.matches(
            in: template, options: [], range: NSRange(location: 0, length: nsTemplate.length)
        )
        var result = template
        for match in matches.reversed() {
            let key = nsTemplate.substring(with: match.range(at: 1))
            let replacement = data[key] ?? nsTemplate.substring(with: match.range(at: 0))
            result = (result as NSString).replacingCharacters(in: match.range(at: 0), with: replacement)
        }
        return result
    }

    private static func readAuthToken(key: String?, customPrefix: String?, defaults: UserDefaults) -> String? {
        guard let key, !key.isEmpty else { return nil }
        if let fromKeychain = readAuthTokenFromKeychain(key: key, customPrefix: customPrefix) {
            return fromKeychain
        }
        if let cache = defaults.dictionary(forKey: keyAuthTokenCache),
           let cached = cache[key] as? String, !cached.isEmpty {
            return cached
        }
        return nil
    }

    private static func readAuthTokenFromKeychain(key: String, customPrefix: String?) -> String? {
        let account = "\(customPrefix ?? defaultKeyPrefix)_\(key)"
        let service = Bundle.main.bundleIdentifier ?? ""
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne],
            [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne],
        ]
        for query in queries {
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let token = String(data: data, encoding: .utf8), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func executeRequest(
        urlString: String, method: String, authToken: String?,
        headers: [String: String], bodyTemplate: String?, data: [String: String]
    ) -> Int {
        guard let url = URL(string: urlString) else { return -1 }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(resolvePlaceholders(value, data: data), forHTTPHeaderField: key)
        }
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        if let bodyTemplate {
            request.httpBody = resolvePlaceholders(bodyTemplate, data: data).data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = -1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return statusCode
    }
}
