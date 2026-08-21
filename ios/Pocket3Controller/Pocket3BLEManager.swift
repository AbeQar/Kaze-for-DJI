import Foundation
import CoreBluetooth
import Combine

final class Pocket3BLEManager: NSObject, ObservableObject {
    var onCredentialsReady: ((String, String) -> Void)?
    private static let serviceFFF0 = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private static let charFFF4 = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    private static let charFFF5 = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")

    @Published private(set) var status = "Disconnected"
    @Published private(set) var logText = ""
    @Published private(set) var ssid = ""
    @Published private(set) var password = ""
    @Published private(set) var credentialsReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false

    private lazy var central = CBCentralManager(delegate: self, queue: .main)

    private var pocketPeripheral: CBPeripheral?
    private var fff4: CBCharacteristic?
    private var fff5: CBCharacteristic?

    private var fff4NotifyReady = false
    private var fff5NotifyReady = false
    private var armWriteIssued = false

    private var connectRequested = false
    private var generation = 0

    private var pairingStarted = false
    private var pairedFlowStarted = false
    private var lastPairStatus: Int? = nil

    private var keepaliveTimer: Timer?
    private var queuedWrites: [Data] = []

    // Keep the on-screen log bounded. The Pocket 3 emits a lot of BLE telemetry;
    // publishing every packet to SwiftUI makes the debug build visibly laggy.
    private var logLines: [String] = []
    private let maxLogLines = 1200

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func connect() {
        generation += 1
        if let previousPeripheral = pocketPeripheral {
            previousPeripheral.delegate = nil
            central.cancelPeripheralConnection(previousPeripheral)
        }
        resetSessionState(keepLog: false)
        connectRequested = true
        isBusy = true
        status = "Starting Bluetooth…"
        log("Pocket3Controller v0.1 BLE credential test")
        log("BLE: using exact frozen Android v0.14.3 wake/pair/credential ordering")

        _ = central

        if central.state == .poweredOn {
            startScanning()
        } else {
            log("BLE: waiting for CoreBluetooth state; current=\(centralStateName(central.state))")
        }
    }

    func disconnect() {
        generation += 1
        connectRequested = false
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        central.stopScan()

        if let peripheral = pocketPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }

        resetSessionState(keepLog: true)
        status = "Disconnected"
        log("BLE: disconnected by user")
    }

    func clearLog() {
        logLines.removeAll(keepingCapacity: true)
        logText = ""
    }

    func beginDiagnosticTest() {
        clearLog()
        log("=== NEW DIAGNOSTIC TEST ===")
    }

    private func resetSessionState(keepLog: Bool) {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil

        pocketPeripheral = nil
        fff4 = nil
        fff5 = nil
        fff4NotifyReady = false
        fff5NotifyReady = false
        armWriteIssued = false

        pairingStarted = false
        pairedFlowStarted = false
        lastPairStatus = nil

        ssid = ""
        password = ""
        credentialsReady = false
        isBusy = false
        isConnected = false
        queuedWrites.removeAll()

        if !keepLog {
            logLines.removeAll(keepingCapacity: true)
            logText = ""
        }
    }

    private func startScanning() {
        guard connectRequested else { return }
        guard central.state == .poweredOn else {
            fail("Bluetooth is not powered on")
            return
        }

        isBusy = true
        status = "Scanning for Pocket 3…"
        log("BLE: scanning specifically for Osmo Pocket 3")
        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        let thisGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self else { return }
            guard thisGeneration == self.generation else { return }
            guard self.pocketPeripheral == nil else { return }
            self.central.stopScan()
            self.fail("Pocket 3 was not found over Bluetooth within 12 seconds. Make sure it is powered on and nearby.")
        }
    }

    private func isPocket3(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> (Bool, String, String?) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "?"
        let normalizedName = name.lowercased().filter { $0.isLetter || $0.isNumber }

        if normalizedName.contains("pocket3") {
            return (true, name, nil)
        }

        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let bytes = [UInt8](manufacturer)
            // CoreBluetooth manufacturer data includes the 16-bit company identifier.
            if bytes.count >= 4 {
                let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
                let model = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
                if (company == 0x08AA || company == 0xF7AA), model == 0x0020 {
                    return (true, name, String(format: "mfr company=0x%04X model=0x%04X", company, model))
                }
            }
        }

        return (false, name, nil)
    }

    private func beginGattSetup(_ peripheral: CBPeripheral) {
        pocketPeripheral = peripheral
        peripheral.delegate = self
        isBusy = true
        status = "Pocket 3 found — connecting Bluetooth…"
        log("BLE: Pocket 3 found; connecting peripheral \(peripheral.identifier.uuidString)")
        central.connect(peripheral, options: nil)
    }

    private func armPairingIfReady() {
        guard fff4NotifyReady, fff5NotifyReady else { return }
        guard !armWriteIssued else { return }
        guard let peripheral = pocketPeripheral, let fff4 else {
            fail("FFF4 characteristic missing")
            return
        }

        armWriteIssued = true
        log("GATT: writing [01 00] to FFF4 with response (arm pairing)")
        peripheral.writeValue(Data([0x01, 0x00]), for: fff4, type: .withResponse)
    }

    private func handleGattReady() {
        status = "Bluetooth ready — waking/pairing Pocket 3…"

        let wakeOK = writeCommand(Pocket3Commands.sessionPing(Pocket3Commands.sessionWake))
        log("BLE: sent 00/2B [04 00] session wake, ok=\(wakeOK)")

        let thisGeneration = generation

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.120) { [weak self] in
            guard let self else { return }
            guard thisGeneration == self.generation else { return }
            guard !self.pairingStarted else { return }

            self.pairingStarted = true
            let ok = self.writeCommand(Pocket3Commands.setPairingPin("osmo"))
            self.log("BLE: sent SetPairingPIN token=\"osmo\", ok=\(ok)")
        }

        for delay in [2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard thisGeneration == self.generation else { return }
                guard !self.pairedFlowStarted, self.lastPairStatus == nil else { return }

                let ok = self.writeCommand(Pocket3Commands.setPairingPin("osmo"))
                self.log("BLE: no pairing reply yet — retry SetPairingPIN, ok=\(ok)")
            }
        }
    }

    @discardableResult
    private func writeCommand(_ data: Data) -> Bool {
        guard let peripheral = pocketPeripheral, let fff5 else {
            log("GATT: FFF5 missing, cannot write")
            return false
        }

        let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard data.count <= maxLength else {
            log("GATT ERROR: DUML frame is \(data.count) bytes but CoreBluetooth max write-without-response is \(maxLength). Do not fragment yet; MTU behavior needs investigation.")
            return false
        }

        if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: fff5, type: .withoutResponse)
            return true
        }

        queuedWrites.append(data)
        log("GATT: write-without-response backpressured; queued \(data.count)-byte DUML frame")
        return true
    }

    private func drainQueuedWrites() {
        guard let peripheral = pocketPeripheral, let fff5 else { return }

        while peripheral.canSendWriteWithoutResponse, !queuedWrites.isEmpty {
            let data = queuedWrites.removeFirst()
            let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
            guard data.count <= maxLength else {
                log("GATT ERROR: queued frame \(data.count) > max write \(maxLength)")
                continue
            }
            peripheral.writeValue(data, for: fff5, type: .withoutResponse)
        }
    }

    private func handleNotification(_ data: Data, source: CBUUID) {
        let parsed: DumlMessage
        do {
            parsed = try DumlMessage(data: data)
        } catch {
            log("BLE RX \(short(source)): unparsed \(data.hexString) (\(error))")
            return
        }

        // Do NOT publish every Pocket 3 notification to SwiftUI. FFF4 carries
        // high-rate 04/05 gimbal telemetry plus several routine status streams.
        // Logging each one caused the first iPhone build to become slow/laggy.
        //
        // Keep raw logs only for requests, responses, pairing/Wi-Fi commands,
        // and the 53/10 wake transaction. Routine notify traffic is still parsed.
        if shouldLogRawFrame(parsed) {
            log(
                String(
                    format: "BLE RX %@: flags=%02X set=%02X cmd=%02X id=%04X payload=%@",
                    short(source),
                    parsed.flags,
                    parsed.cmdSet,
                    parsed.cmdId,
                    parsed.id,
                    parsed.payload.hexString
                )
            )
        }

        // DJI requests must be answered. Mirror the request as a response, swap target bytes,
        // and substitute APP_DEVICE_INFO for 00/81 exactly as in the frozen Android build.
        if parsed.flags == 0x40 {
            let responseTarget =
                ((parsed.target & 0x00FF) << 8) |
                ((parsed.target & 0xFF00) >> 8)

            let responseType =
                (parsed.type & 0x00FFFF00) |
                UInt32(0xC0)

            let responsePayload: Data
            if parsed.cmdSet == 0x00, parsed.cmdId == 0x81 {
                responsePayload = Pocket3Commands.appDeviceInfo
            } else {
                responsePayload = parsed.payload
            }

            let response = DumlMessage(
                target: responseTarget,
                id: parsed.id,
                type: responseType,
                payload: responsePayload
            ).encode()

            let ok = writeCommand(response)
            log(String(format: "BLE: request %02X/%02X -> response ok=%@", parsed.cmdSet, parsed.cmdId, String(ok)))

            if parsed.cmdSet == 0x07, parsed.cmdId == 0x46 {
                log("BLE: pairing approved by Pocket 3")
                onPaired()
            }
            return
        }

        if parsed.cmdSet == 0x07 {
            switch parsed.cmdId {
            case 0x45:
                let bytes = [UInt8](parsed.payload)
                let pairStatus = bytes.count > 1 ? Int(bytes[1]) : -1
                lastPairStatus = pairStatus

                switch pairStatus {
                case 0x01:
                    log("BLE: Pocket 3 says ALREADY PAIRED")
                    onPaired()

                case 0x02:
                    status = "Approve pairing on the Pocket 3 screen"
                    log("BLE: Pocket 3 requires pairing approval on its screen")

                default:
                    log(String(format: "BLE: pairing status=0x%02X", pairStatus))
                }

            case 0x46:
                log("BLE: pairing approved")
                onPaired()

            case 0x07:
                if let value = parseStatusPackString(parsed.payload), !value.isEmpty {
                    ssid = value
                    log("BLE: Wi-Fi SSID retrieved: \"\(value)\"")
                    maybeCredentialsReady()
                }

            case 0x0E:
                if let value = parseStatusPackString(parsed.payload), !value.isEmpty {
                    password = value
                    log("BLE: Wi-Fi password retrieved (\(value.count) characters)")
                    maybeCredentialsReady()
                } else {
                    log("BLE: password query returned no password")
                }

            default:
                log(String(format: "BLE: 07/%02X reply payload=%@", parsed.cmdId, parsed.payload.hexString))
            }

            return
        }

        if parsed.cmdSet == 0x53, parsed.cmdId == 0x10 {
            log("BLE: 53/10 wake reply \(parsed.payload.hexString)")
        }
    }

    private func onPaired() {
        guard !pairedFlowStarted else { return }
        pairedFlowStarted = true

        status = "Paired — waking Pocket 3 Wi-Fi…"
        log("BLE: starting Osmosis/Mimo post-pair wake + credential sequence")
        startKeepalive()

        let thisGeneration = generation

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.100) { [weak self] in
            guard let self, thisGeneration == self.generation else { return }
            let ok = self.writeCommand(Pocket3Commands.session5310())
            self.log("BLE: sent 53/10 Wi-Fi wake, ok=\(ok)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.900) { [weak self] in
            guard let self, thisGeneration == self.generation else { return }
            let ok = self.writeCommand(Pocket3Commands.wifiQuery(cmdId: 0x07, id: 0x8007))
            self.log("BLE: requested Pocket 3 Wi-Fi SSID, ok=\(ok)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.400) { [weak self] in
            guard let self, thisGeneration == self.generation else { return }
            let ok = self.writeCommand(Pocket3Commands.wifiQuery(cmdId: 0x0E, id: 0x800E))
            self.log("BLE: requested Pocket 3 Wi-Fi password, ok=\(ok)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.500) { [weak self] in
            guard let self, thisGeneration == self.generation else { return }
            if self.ssid.isEmpty || self.password.isEmpty {
                self.fail("Pocket 3 paired, but its Wi-Fi credentials were not received over Bluetooth")
            }
        }
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        log("BLE: 00/2B [01 01] keepalive started at 1 Hz")
        let thisGeneration = generation

        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard thisGeneration == self.generation, self.connectRequested else { return }
            _ = self.writeCommand(Pocket3Commands.sessionPing(Pocket3Commands.sessionKeepalive))
        }
    }

    private func callbackIsCurrent(_ peripheral: CBPeripheral, event: String) -> Bool {
        guard connectRequested, pocketPeripheral === peripheral else {
            log("BLE: ignored stale \(event) callback peripheral=\(peripheral.identifier.uuidString)")
            return false
        }
        return true
    }

    private func maybeCredentialsReady() {
        guard !ssid.isEmpty, !password.isEmpty else { return }
        guard !credentialsReady else { return }
        credentialsReady = true
        isBusy = false
        status = "BLE passed — Pocket 3 Wi-Fi credentials retrieved"
        log("BLE TEST PASS: credentials complete")
        log("NEXT: app-managed Wi-Fi association for \(ssid)")
        onCredentialsReady?(ssid, password)
    }

    private func parseStatusPackString(_ payload: Data) -> String? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }

        let length = Int(bytes[1])
        guard 2 + length <= bytes.count else { return nil }

        return String(bytes: bytes[2..<(2 + length)], encoding: .ascii)
    }

    private func shouldLogRawFrame(_ message: DumlMessage) -> Bool {
        // Requests must remain visible because we answer them.
        if message.flags == 0x40 {
            return true
        }

        // Replies are useful during connection bring-up.
        if message.flags == 0xC0 {
            return true
        }

        // Pairing / Wi-Fi and the post-pair wake transaction.
        if message.cmdSet == 0x07 || message.cmdSet == 0x53 {
            return true
        }

        return false
    }

    private func fail(_ message: String) {
        isBusy = false
        status = "Connection failed"
        log("CONNECTION ERROR: \(message)")
    }

    private func log(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date()))  \(message)"

        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }

        // One bounded @Published value instead of an ever-growing string.
        logText = logLines.joined(separator: "\n")
        print(line)
    }

    private func short(_ uuid: CBUUID) -> String {
        let text = uuid.uuidString.uppercased()
        if text.count == 4 { return text }
        if let range = text.range(of: "FFF4") { return String(text[range]) }
        if let range = text.range(of: "FFF5") { return String(text[range]) }
        return text
    }

    private func centralStateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "future"
        }
    }
}

extension Pocket3BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BLE: CoreBluetooth state=\(centralStateName(central.state))")

        guard connectRequested else { return }

        switch central.state {
        case .poweredOn:
            startScanning()

        case .unauthorized:
            fail("Bluetooth permission is not authorized")

        case .unsupported:
            fail("Bluetooth LE is not supported on this device")

        case .poweredOff:
            fail("Bluetooth is off. Turn it on and press CONNECT again.")

        case .unknown, .resetting:
            status = "Waiting for Bluetooth…"

        @unknown default:
            fail("Unknown CoreBluetooth state")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard connectRequested else { return }
        let match = isPocket3(peripheral: peripheral, advertisementData: advertisementData)
        guard match.0 else { return }
        guard pocketPeripheral == nil else { return }

        central.stopScan()
        let extra = match.2.map { " \($0)" } ?? ""
        log("BLE: Pocket 3 advertisement name=\(match.1), RSSI=\(RSSI)\(extra)")
        beginGattSetup(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard callbackIsCurrent(peripheral, event: "didConnect") else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        isConnected = true
        status = "Bluetooth connected — discovering FFF0…"
        log("GATT: connected; discovering service FFF0")
        peripheral.discoverServices([Self.serviceFFF0])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard callbackIsCurrent(peripheral, event: "didFailToConnect") else { return }
        isConnected = false
        fail("Bluetooth connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard callbackIsCurrent(peripheral, event: "didDisconnect") else { return }
        isConnected = false
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil

        if credentialsReady {
            status = "BLE disconnected after credentials were retrieved"
            log("GATT: disconnected after credential retrieval (not treated as BLE test failure)")
        } else if connectRequested {
            fail("Bluetooth link disconnected before credential retrieval: \(error?.localizedDescription ?? "no error detail")")
        } else {
            status = "Disconnected"
        }
    }
}

extension Pocket3BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard callbackIsCurrent(peripheral, event: "didDiscoverServices") else { return }
        if let error {
            fail("Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceFFF0 }) else {
            let present = peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "none"
            fail("FFF0 service not found. Present: \(present)")
            return
        }

        log("GATT: FFF0 found; discovering FFF4 + FFF5")
        peripheral.discoverCharacteristics([Self.charFFF4, Self.charFFF5], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard callbackIsCurrent(peripheral, event: "didDiscoverCharacteristics") else { return }
        if let error {
            fail("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        fff4 = service.characteristics?.first(where: { $0.uuid == Self.charFFF4 })
        fff5 = service.characteristics?.first(where: { $0.uuid == Self.charFFF5 })

        guard let fff4, let fff5 else {
            let present = service.characteristics?.map(\.uuid.uuidString).joined(separator: ", ") ?? "none"
            fail("FFF4/FFF5 missing. Present: \(present)")
            return
        }

        let withResponseMax = peripheral.maximumWriteValueLength(for: .withResponse)
        let withoutResponseMax = peripheral.maximumWriteValueLength(for: .withoutResponse)
        log("GATT: FFF4 + FFF5 found; CoreBluetooth maxWrite withResponse=\(withResponseMax), withoutResponse=\(withoutResponseMax)")
        log("GATT: enabling notifications on FFF4 + FFF5")

        peripheral.setNotifyValue(true, for: fff4)
        peripheral.setNotifyValue(true, for: fff5)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard callbackIsCurrent(peripheral, event: "didUpdateNotificationState") else { return }
        if let error {
            fail("Notify enable failed on \(short(characteristic.uuid)): \(error.localizedDescription)")
            return
        }

        log("GATT: notify state \(short(characteristic.uuid)) = \(characteristic.isNotifying)")

        if characteristic.uuid == Self.charFFF4 {
            fff4NotifyReady = characteristic.isNotifying
        } else if characteristic.uuid == Self.charFFF5 {
            fff5NotifyReady = characteristic.isNotifying
        }

        armPairingIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard callbackIsCurrent(peripheral, event: "didWriteValue") else { return }
        guard characteristic.uuid == Self.charFFF4 else { return }

        if let error {
            fail("FFF4 arm write failed: \(error.localizedDescription)")
            return
        }

        log("GATT: FFF4 arm write complete")
        handleGattReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard callbackIsCurrent(peripheral, event: "didUpdateValue") else { return }
        if let error {
            log("GATT RX ERROR \(short(characteristic.uuid)): \(error.localizedDescription)")
            return
        }

        guard let value = characteristic.value else { return }
        handleNotification(value, source: characteristic.uuid)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard callbackIsCurrent(peripheral, event: "readyToWrite") else { return }
        if !queuedWrites.isEmpty {
            log("GATT: write-without-response ready; draining \(queuedWrites.count) queued frame(s)")
        }
        drainQueuedWrites()
    }
}
