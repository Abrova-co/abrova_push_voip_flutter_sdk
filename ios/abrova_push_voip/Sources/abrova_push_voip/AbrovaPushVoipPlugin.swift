/**
 * AbrovaPush VoIP Flutter Plugin — Self-Contained
 *
 * Handles PushKit + CallKit independently from the main Push SDK.
 * Works when app is killed: PushKit wakes app → CallKit shows → user accepts → Flutter starts
 *
 * Architecture:
 * - Registers for PushKit VoIP pushes directly (no dependency on main Push SDK for VoIP)
 * - Shows CallKit natively when VoIP push arrives
 * - Sends VoIP token to Abrova server using the API key
 * - When Flutter is running: forwards events via method channel
 * - When app is killed: stores accepted call → Flutter reads via getInitialCall()
 */
import Flutter
import UIKit
import PushKit
import AbrovaPushVoip

public class AbrovaPushVoipPlugin: NSObject, FlutterPlugin {
    private static var instance: AbrovaPushVoipPlugin?
    private var channel: FlutterMethodChannel?
    private static var voipRegistry: PKPushRegistry?

    // Config persistence keys
    private static let configKey = "abrova_push_voip_config"
    private static let apiKeyKey = "abrova_push_voip_api_key"
    private static let deviceIdKey = "abrova_push_voip_device_id"
    private static let serverUrlKey = "abrova_push_voip_server_url"

    // Push SDK device ID key (to match token with correct device record)
    private static let pushSdkDeviceIdKey = "ir.abrova.push.deviceId"

    // Server URL
    private static let defaultServerUrl = "https://push-api.abrova.ir"

    /// SDK identity sent with the VoIP token registration.
    /// Keep `sdkVersion` in sync with pubspec.yaml and abrova_push_voip.podspec.
    static let sdkName = "flutter-voip"
    static let sdkVersion = "0.1.3"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ir.abrova.push/voip", binaryMessenger: registrar.messenger())
        let instance = AbrovaPushVoipPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)

        AbrovaPushVoipPlugin.instance = instance

        // Auto-initialize VoIP SDK if previously configured (for cold start)
        if let savedConfig = UserDefaults.standard.dictionary(forKey: configKey) {
            instance.autoInitialize(savedConfig: savedConfig)
        }

        print("[AbrovaPushVoipPlugin] Plugin registered")
    }

    // MARK: - Auto-Initialize (Cold Start)

    private func autoInitialize(savedConfig: [String: Any]) {
        let appName = savedConfig["appName"] as? String ?? "App"
        guard !appName.isEmpty else { return }

        let config = VoipConfig(
            appName: appName,
            callTimeout: savedConfig["callTimeout"] as? Int ?? savedConfig["timeoutSeconds"] as? Int ?? 30,
            supportsVideo: savedConfig["supportsVideo"] as? Bool ?? true
        )

        AbrovaPushVoip.shared.initialize(config: config)
        AbrovaPushVoip.shared.delegate = self
        registerPushKit()

        print("[AbrovaPushVoipPlugin] Auto-initialized for cold start: \(appName)")
    }

    // MARK: - PushKit Registration

    private func registerPushKit() {
        if AbrovaPushVoipPlugin.voipRegistry == nil {
            AbrovaPushVoipPlugin.voipRegistry = PKPushRegistry(queue: .main)
            AbrovaPushVoipPlugin.voipRegistry?.delegate = self
            AbrovaPushVoipPlugin.voipRegistry?.desiredPushTypes = [.voIP]
            print("[AbrovaPushVoipPlugin] PushKit registered for VoIP")
        }
    }

    /// Resolve the device ID: check VoIP-specific key, then Push SDK key, then system fallback
    private func resolveDeviceId() -> String {
        if let id = UserDefaults.standard.string(forKey: AbrovaPushVoipPlugin.deviceIdKey), !id.isEmpty {
            return id
        }
        if let id = UserDefaults.standard.string(forKey: AbrovaPushVoipPlugin.pushSdkDeviceIdKey), !id.isEmpty {
            return id
        }
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }

    private func sendVoipTokenToServer(_ token: String) {
        guard let apiKey = UserDefaults.standard.string(forKey: AbrovaPushVoipPlugin.apiKeyKey), !apiKey.isEmpty else {
            print("[AbrovaPushVoipPlugin] No API key saved, skipping token registration")
            return
        }

        let deviceId = resolveDeviceId()
        let serverUrl = UserDefaults.standard.string(forKey: AbrovaPushVoipPlugin.serverUrlKey) ?? AbrovaPushVoipPlugin.defaultServerUrl
        let appIdentifier = Bundle.main.bundleIdentifier ?? "unknown"

        guard let url = URL(string: "\(serverUrl)/devices/register") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("\(AbrovaPushVoipPlugin.sdkName)/\(AbrovaPushVoipPlugin.sdkVersion)", forHTTPHeaderField: "X-Abrova-SDK")

        let body: [String: Any] = [
            "deviceId": deviceId,
            "platform": "ios",
            "pushToken": token,
            "appIdentifier": appIdentifier,
            "sdkName": AbrovaPushVoipPlugin.sdkName,
            "sdkVersion": AbrovaPushVoipPlugin.sdkVersion,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                print("[AbrovaPushVoipPlugin] VoIP token sent: \(http.statusCode)")
            }
        }.resume()
    }

    // MARK: - Flutter Method Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isConfigured":
            let hasConfig = UserDefaults.standard.dictionary(forKey: AbrovaPushVoipPlugin.configKey) != nil
            result(hasConfig)

        case "init":
            if let args = call.arguments as? [String: Any] {
                initVoip(config: args)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Config is required", details: nil))
            }

        case "getInitialCall":
            if let initialCall = AbrovaPushVoip.shared.getInitialCall() {
                AbrovaPushVoip.shared.clearInitialCall()
                result(initialCall.toDictionary())
            } else {
                result(nil)
            }

        case "endCall":
            if let args = call.arguments as? [String: Any],
               let callId = args["callId"] as? String {
                AbrovaPushVoip.shared.endCall(callId: callId)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "callId is required", details: nil))
            }

        case "reportCallConnected":
            if let args = call.arguments as? [String: Any],
               let callId = args["callId"] as? String {
                AbrovaPushVoip.shared.reportCallConnected(callId: callId)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "callId is required", details: nil))
            }

        case "showIncomingCall":
            if let args = call.arguments as? [String: Any] {
                let callData = mapToCallData(args)
                AbrovaPushVoip.shared.showIncomingCall(callData: callData)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "callData is required", details: nil))
            }

        case "setApiKey":
            if let args = call.arguments as? [String: Any] {
                let apiKey = args["apiKey"] as? String ?? ""
                let deviceId = args["deviceId"] as? String ?? ""
                let serverUrl = args["serverUrl"] as? String ?? AbrovaPushVoipPlugin.defaultServerUrl
                UserDefaults.standard.set(apiKey, forKey: AbrovaPushVoipPlugin.apiKeyKey)
                UserDefaults.standard.set(deviceId, forKey: AbrovaPushVoipPlugin.deviceIdKey)
                UserDefaults.standard.set(serverUrl, forKey: AbrovaPushVoipPlugin.serverUrlKey)
                print("[AbrovaPushVoipPlugin] API key saved for VoIP token registration")

                // Re-send VoIP token now that we have the API key + device ID
                if let token = AbrovaPushVoipPlugin.voipRegistry?.pushToken(for: .voIP) {
                    let tokenStr = token.map { String(format: "%02x", $0) }.joined()
                    sendVoipTokenToServer(tokenStr)
                }

                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "apiKey is required", details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initVoip(config: [String: Any]) {
        let voipConfig = VoipConfig(
            appName: config["appName"] as? String ?? "App",
            vibrate: config["vibrate"] as? Bool ?? true,
            callTimeout: config["callTimeout"] as? Int ?? config["timeoutSeconds"] as? Int ?? 30,
            supportsVideo: config["supportsVideo"] as? Bool ?? true,
            ringtoneName: config["ringtoneSound"] as? String,
            callIdKey: config["callIdKey"] as? String ?? "call_id",
            callerNameKey: config["callerNameKey"] as? String ?? "callerName",
            callerIdKey: config["callerIdKey"] as? String ?? "callerId",
            callerAvatarKey: config["callerAvatarKey"] as? String ?? "callerAvatar",
            callTypeKey: config["callTypeKey"] as? String ?? "callType"
        )

        AbrovaPushVoip.shared.initialize(config: voipConfig)
        AbrovaPushVoip.shared.delegate = self

        // Save config for cold start auto-initialization
        let safeConfig = config.compactMapValues { $0 is NSNull ? nil : $0 }
        UserDefaults.standard.set(safeConfig, forKey: AbrovaPushVoipPlugin.configKey)

        // Register PushKit for VoIP pushes
        registerPushKit()

        // Deliver pending initial call
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let pendingCall = AbrovaPushVoip.shared.getInitialCall() {
                print("[AbrovaPushVoipPlugin] Delivering pending call: \(pendingCall.callId)")
                self?.invokeFlutterMethod("onCallAccepted", arguments: pendingCall.toDictionary())
            }
        }

        print("[AbrovaPushVoipPlugin] Initialized with config: \(voipConfig.appName)")
    }

    private func invokeFlutterMethod(_ method: String, arguments: Any?) {
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod(method, arguments: arguments)
        }
    }

    private func mapToCallData(_ map: [String: Any]) -> VoipCallData {
        return VoipCallData(
            callId: map["callId"] as? String ?? "",
            callerName: map["callerName"] as? String ?? "Unknown",
            callerId: map["callerId"] as? String,
            callerAvatar: map["callerAvatar"] as? String,
            callType: map["mediaType"] as? String ?? "audio",
            payload: map["extra"] as? [String: Any],
            timestamp: map["receivedAt"] as? TimeInterval ?? Date().timeIntervalSince1970 * 1000
        )
    }
}

// MARK: - PKPushRegistryDelegate
extension AbrovaPushVoipPlugin: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("[AbrovaPushVoipPlugin] VoIP token: \(String(token.prefix(20)))...")
        sendVoipTokenToServer(token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }

        print("[AbrovaPushVoipPlugin] VoIP push received!")

        // Let VoIP SDK handle it (shows CallKit synchronously)
        let handled = AbrovaPushVoip.shared.handlePushPayload(payload.dictionaryPayload)

        if !handled {
            // Fallback: must report a call to CallKit (Apple requirement since iOS 13)
            let data = payload.dictionaryPayload
            let nestedData = data["data"] as? [String: Any] ?? [:]
            let effectiveData = nestedData.isEmpty ? data as? [String: Any] ?? [:] : nestedData

            let callData = VoipCallData(
                callId: effectiveData["callId"] as? String ?? UUID().uuidString,
                callerName: effectiveData["callerName"] as? String ?? "Unknown",
                callerId: effectiveData["callerId"] as? String,
                callerAvatar: effectiveData["callerAvatar"] as? String,
                callType: effectiveData["callType"] as? String ?? "audio"
            )
            AbrovaPushVoip.shared.showIncomingCall(callData: callData)
        }

        completion()
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[AbrovaPushVoipPlugin] VoIP token invalidated")
    }
}

// MARK: - AbrovaPushVoipDelegate
extension AbrovaPushVoipPlugin: AbrovaPushVoipDelegate {
    public func voip(_ voip: AbrovaPushVoip, didAcceptCall callData: VoipCallData) {
        print("[AbrovaPushVoipPlugin] Call accepted: \(callData.callId)")
        if channel != nil {
            invokeFlutterMethod("onCallAccepted", arguments: callData.toDictionary())
        } else {
            // Flutter not running — store for later
            AbrovaPushVoip.shared.setInitialCall(callData)
        }
    }

    public func voip(_ voip: AbrovaPushVoip, didDeclineCall callData: VoipCallData) {
        print("[AbrovaPushVoipPlugin] Call declined: \(callData.callId)")
        invokeFlutterMethod("onCallDeclined", arguments: callData.toDictionary())
    }

    public func voip(_ voip: AbrovaPushVoip, didTimeoutCall callData: VoipCallData) {
        print("[AbrovaPushVoipPlugin] Call timeout: \(callData.callId)")
        invokeFlutterMethod("onCallTimeout", arguments: callData.toDictionary())
    }

    public func voip(_ voip: AbrovaPushVoip, didFailWithError error: String) {
        print("[AbrovaPushVoipPlugin] Error: \(error)")
        invokeFlutterMethod("onError", arguments: error)
    }

    public func voip(_ voip: AbrovaPushVoip, didReceiveIncomingCall callData: VoipCallData) {
        print("[AbrovaPushVoipPlugin] Incoming call (no CallKit): \(callData.callId)")
        invokeFlutterMethod("onCallAccepted", arguments: callData.toDictionary())
    }
}
