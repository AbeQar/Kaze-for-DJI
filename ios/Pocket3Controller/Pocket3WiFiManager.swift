import Combine
import Foundation
import NetworkExtension

/// Coordinates automatic association when provisioned, or a manual Settings join.
/// ContentView establishes the UDP session separately; user-managed networks are
/// never removed by the app.
final class Pocket3WiFiManager: ObservableObject {
    @Published private(set) var status = "未加入网络"
    @Published private(set) var logText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isJoined = false

    @Published private(set) var needsManualJoin = false
    @Published private(set) var isUsingManualNetwork = false
    @Published private(set) var manualSSID = ""
    @Published private(set) var manualPassword = ""
    private var ownsConfiguration = false

    // Read the profile actually embedded by the sideload signer, not the source entitlements.
    static var profileAllowsHotspotConfiguration: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        return entitlements["com.apple.developer.networking.HotspotConfiguration"] as? Bool == true
    }

    func waitForManualJoin(ssid: String, password: String) {
        generation &+= 1
        isBusy = false
        isJoined = false
        isUsingManualNetwork = true
        manualSSID = ssid
        manualPassword = password
        needsManualJoin = true
        status = "请在系统设置中连接相机 Wi-Fi，然后返回继续"
        log("Wi-Fi: waiting for manual association; SSID reading is not required")
    }

    func beginManualControlConnection() {
        needsManualJoin = false
        isBusy = false
        isJoined = false
        status = "正在验证相机控制连接…"
    }

    func confirmManualControlConnection() {
        guard isUsingManualNetwork else { return }
        isJoined = true
        needsManualJoin = false
        status = "已建立相机控制连接（手动 Wi-Fi）"
    }

    private let manager = NEHotspotConfigurationManager.shared
    private var generation = 0
    private var associatedSSID = ""
    private var logLines: [String] = []
    private let maxLogLines = 120

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func join(ssid: String, passphrase: String, completion: @escaping (Bool) -> Void) {
        guard !ssid.isEmpty, !passphrase.isEmpty else {
            finishJoinFailure("Pocket 3 Wi-Fi 连接信息不完整", completion: completion)
            return
        }

        manualSSID = ssid
        manualPassword = passphrase
        if !Self.profileAllowsHotspotConfiguration || isUsingManualNetwork {
            log("Wi-Fi: embedded profile HotspotConfiguration=\(Self.profileAllowsHotspotConfiguration)")
            waitForManualJoin(ssid: ssid, password: passphrase)
            completion(false)
            return
        }
        needsManualJoin = false
        generation &+= 1
        let token = generation
        isBusy = true
        isJoined = false
        status = "正在加入 \(ssid)…"
        log("Wi-Fi: applying app-managed configuration for \(ssid)")

        manager.getConfiguredSSIDs { [weak self] configuredSSIDs in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                let wasManaged = configuredSSIDs.contains(ssid)
                self.applyConfiguration(
                    ssid: ssid,
                    passphrase: passphrase,
                    wasManaged: wasManaged,
                    token: token,
                    completion: completion
                )
            }
        }
    }

    func disconnect(ssid: String? = nil, completion: (() -> Void)? = nil) {
        generation &+= 1
        let token = generation
        let target = (ssid?.isEmpty == false ? ssid : nil) ?? associatedSSID

        needsManualJoin = false
        manualPassword = ""
        if isUsingManualNetwork || !ownsConfiguration {
            isUsingManualNetwork = false
            associatedSSID = ""
            isBusy = false
            isJoined = false
            status = "控制连接已断开；手动 Wi-Fi 请在系统设置中管理"
            completion?()
            return
        }
        guard !target.isEmpty else {
            isBusy = false
            isJoined = false
            status = "未加入网络"
            completion?()
            return
        }

        isBusy = true
        status = "正在断开 \(target)…"
        log("Wi-Fi disconnect stage: removing app-managed configuration for \(target)")
        manager.removeConfiguration(forSSID: target)
        waitForDisassociation(ssid: target, token: token, attempt: 0, completion: completion)
    }

    func note(_ message: String) {
        log(message)
    }

    func clearLog() {
        logLines.removeAll(keepingCapacity: true)
        logText = ""
    }

    static func isAlreadyAssociated(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NEHotspotConfigurationErrorDomain
            && value.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
    }

    private func applyConfiguration(
        ssid: String,
        passphrase: String,
        wasManaged: Bool,
        token: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let configuration = NEHotspotConfiguration(
            ssid: ssid,
            passphrase: passphrase,
            isWEP: false
        )

        // A persistent app-owned configuration keeps the Pocket link alive for
        // the existing PiP/background behavior. It is explicitly removed by the
        // user-disconnect path to force the association break seen in Mimo.
        configuration.joinOnce = false

        manager.apply(configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }

                if let error, !Self.isAlreadyAssociated(error) {
                    self.log("Wi-Fi automatic join failed: \(error as NSError)")
                    self.waitForManualJoin(ssid: ssid, password: passphrase)
                    completion(false)
                    return
                }

                self.ownsConfiguration = error == nil || wasManaged
                self.isUsingManualNetwork = !self.ownsConfiguration
                self.associatedSSID = ssid
                self.isBusy = false
                self.isJoined = true
                self.status = "已加入 \(ssid)"

                if let error, Self.isAlreadyAssociated(error) {
                    self.log("Wi-Fi: app-managed \(ssid) configuration already associated")
                } else {
                    self.log("Wi-Fi: app-managed \(ssid) association complete")
                }

                self.logCurrentNetwork(expectedSSID: ssid)
                completion(true)
            }
        }
    }

    private func waitForDisassociation(
        ssid: String,
        token: Int,
        attempt: Int,
        completion: (() -> Void)?
    ) {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }

                if network?.ssid != ssid {
                    self.finishDisconnect(ssid: ssid, confirmed: true, completion: completion)
                    return
                }

                guard attempt < 20 else {
                    self.log("Wi-Fi: removal submitted but iOS still reports \(ssid) after 5 seconds")
                    self.finishDisconnect(ssid: ssid, confirmed: false, completion: completion)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForDisassociation(
                        ssid: ssid,
                        token: token,
                        attempt: attempt + 1,
                        completion: completion
                    )
                }
            }
        }
    }

    private func finishDisconnect(
        ssid: String,
        confirmed: Bool,
        completion: (() -> Void)?
    ) {
        associatedSSID = ""
        ownsConfiguration = false
        isBusy = false
        isJoined = false
        status = "未加入网络"
        if confirmed {
            log("Wi-Fi disconnect stage: \(ssid) no longer reported after configuration removal")
        } else {
            log("Wi-Fi disconnect stage: continuing after bounded configuration-removal wait")
        }
        completion?()
    }

    private func finishJoinFailure(_ message: String, completion: (Bool) -> Void) {
        isBusy = false
        isJoined = false
        status = message
        log("WI-FI ERROR: \(message)")
        completion(false)
    }

    private func logCurrentNetwork(expectedSSID: String) {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self else { return }
                let current = network?.ssid ?? "unavailable"
                self.log("Wi-Fi: current SSID=\(current) expected=\(expectedSSID)")
            }
        }
    }

    private func log(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date()))  \(message)"
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        logText = logLines.joined(separator: "\n")
        print(line)
    }
}
