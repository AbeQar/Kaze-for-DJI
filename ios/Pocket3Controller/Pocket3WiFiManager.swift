import Combine
import Foundation
import NetworkExtension

/// Owns the app-created Pocket 3 Wi-Fi configuration. The transport session is
/// deliberately kept separate; ContentView coordinates Wi-Fi association before
/// starting TCP/7001 and removes the configuration only after UDP has closed.
final class Pocket3WiFiManager: ObservableObject {
    @Published private(set) var status = "Not joined"
    @Published private(set) var logText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isJoined = false

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
            finishJoinFailure("Pocket 3 Wi-Fi credentials are incomplete", completion: completion)
            return
        }

        generation &+= 1
        let token = generation
        isBusy = true
        isJoined = false
        status = "Joining \(ssid)…"
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

        guard !target.isEmpty else {
            isBusy = false
            isJoined = false
            status = "Not joined"
            completion?()
            return
        }

        isBusy = true
        status = "Leaving \(target)…"
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
                    self.finishJoinFailure(
                        "Could not join \(ssid): \(error.localizedDescription)",
                        completion: completion
                    )
                    return
                }

                if let error, Self.isAlreadyAssociated(error), !wasManaged {
                    self.finishJoinFailure(
                        "\(ssid) is joined from Settings, not owned by this app. Choose Forget This Network once, return here, and press Connect Pocket 3.",
                        completion: completion
                    )
                    return
                }

                self.associatedSSID = ssid
                self.isBusy = false
                self.isJoined = true
                self.status = "Joined \(ssid)"

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
        isBusy = false
        isJoined = false
        status = "Not joined"
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
