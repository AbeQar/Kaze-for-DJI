import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var ble = Pocket3BLEManager()
    @StateObject private var wifi = Pocket3WiFiManager()
    @StateObject private var gimbal = Pocket3GimbalSession()
    @StateObject private var preferences = ControllerPreferences()
    @StateObject private var gamepad = GameControllerManager()
    @StateObject private var headTracking = HeadTrackingManager()
    @State private var showControlPanel = false
    @State private var pocketWorkflowGeneration = 0
    @State private var pocketWorkflowActive = false
    @State private var associationRecoveryUsed = false

    var body: some View {
        CameraControlScreen(
            gimbal: gimbal,
            preferences: preferences,
            gamepad: gamepad,
            headTracking: headTracking,
            connectedCameraDisplayName: gimbal.isConnected ? "Pocket 3" : nil,
            onConnectCamera: connectPocket,
            onDisconnectCamera: disconnectPocket,
            onOpenLegacyDebug: { showControlPanel = true }
        )
        .fullScreenCover(isPresented: $showControlPanel) {
            ZStack(alignment: .topTrailing) {
                TabView {
                    ControlScreen(
                        gimbal: gimbal,
                        preferences: preferences,
                        gamepad: gamepad,
                        headTracking: headTracking
                    )
                    .tabItem {
                        Label("Legacy Control", systemImage: "dot.scope")
                    }

                    DevicesScreen(
                        ble: ble,
                        wifi: wifi,
                        gimbal: gimbal,
                        gamepad: gamepad,
                        headTracking: headTracking,
                        onConnectPocket: connectPocket,
                        onDisconnectPocket: disconnectPocket
                    )
                    .tabItem {
                        Label("Devices", systemImage: "gamecontroller")
                    }

                    SettingsScreen(
                        preferences: preferences,
                        gamepad: gamepad,
                        gimbal: gimbal
                    )
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }

                    DiagnosticsScreen(
                        ble: ble,
                        wifi: wifi,
                        gimbal: gimbal,
                        gamepad: gamepad,
                        headTracking: headTracking
                    )
                    .tabItem {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                    }
                }

                Button {
                    showControlPanel = false
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.trailing, 10)
                .accessibilityLabel("Close control panel")
            }
        }
        .onAppear {
            wireHeadTracking()
            wireGameController()
            wirePocketConnectionLifecycle()
            gamepad.start()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
        .onChange(of: preferences.stickLayout) { _ in
            gamepad.settingsDidChange()
        }
        .onChange(of: preferences.invertPitch) { _ in
            gamepad.settingsDidChange()
        }
        .onChange(of: preferences.invertYaw) { _ in
            gamepad.settingsDidChange()
        }
        .onChange(of: preferences.responseMode) { newMode in
            gamepad.settingsDidChange()
            gimbal.noteJoystickProfile(newMode)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // If the user explicitly reopens the app while automatic PiP is
            // active, stop PiP so the inline preview can reclaim presentation.
            gimbal.videoOutput.stopPictureInPictureForForegroundReturn()

            // Mimo-like quick return: first give the existing UDP session a
            // chance to resume. If it does not produce fresh Pocket traffic
            // promptly, Pocket3GimbalSession tears it down and opens a new one.
            gimbal.resumeFromBackground()

        case .inactive:
            // Never leave a motion command latched while the app is no longer
            // interactive. Head tracking is deliberately disarmed as well; the
            // user must Set Head Center again after returning.
            if gimbal.isConnected {
                headTracking.invalidateControlCenter(reason: "App became inactive")
                gimbal.neutral()
            }

        case .background:
            if gimbal.isConnected || gimbal.isBusy {
                headTracking.invalidateControlCenter(reason: "App entered background")
                gimbal.prepareForBackground()
            }

        @unknown default:
            break
        }
    }

    private func wireHeadTracking() {
        headTracking.telemetryProvider = { [weak gimbal] in
            gimbal?.latestTelemetrySnapshot(maxAgeMs: 350)
        }

        headTracking.onControlCommand = { [weak gimbal] pitch, yaw in
            gimbal?.setJoystick(pitch: pitch, yaw: yaw)
        }

        headTracking.onControlRelease = { [weak gimbal] in
            gimbal?.releaseJoystick()
        }

        headTracking.onSafetyNeutral = { [weak gimbal] in
            gimbal?.neutral()
        }
    }

    private func wireGameController() {
        gamepad.settingsProvider = { [weak preferences] in
            preferences?.snapshot ?? .default
        }

        gamepad.onManualActivityChanged = { [weak headTracking] active in
            headTracking?.setManualOverride(.gamepad, active: active)
        }

        gamepad.onMappedInput = { [weak gimbal] mapped in
            guard let gimbal else { return }
            if mapped.active {
                gimbal.setJoystick(pitch: mapped.pitch, yaw: mapped.yaw)
            } else {
                gimbal.releaseJoystick()
            }
        }

        gamepad.onRecenter = { [weak gimbal, weak headTracking] in
            headTracking?.prepareForRecenterAutoResume(reason: "Gamepad recenter")
            gimbal?.recenter()
        }

        gamepad.onStopNeutral = { [weak gimbal, weak headTracking] in
            headTracking?.invalidateControlCenter(reason: "Gamepad STOP")
            gimbal?.neutral()
        }

        gamepad.onCaptureCenter = { [weak gimbal] in
            _ = gimbal?.captureCenter()
        }

        gamepad.onSmoothRecenter = { [weak gimbal, weak headTracking] in
            headTracking?.invalidateControlCenter(reason: "Gamepad smooth recenter")
            gimbal?.smoothRecenterToCapturedCenter()
        }
    }

    private func wirePocketConnectionLifecycle() {
        ble.onCredentialsReady = { [weak wifi, weak gimbal] ssid, password in
            guard let wifi, let gimbal else { return }
            guard pocketWorkflowActive else { return }
            let token = pocketWorkflowGeneration
            joinPocketWiFiAndConnect(
                wifi: wifi,
                gimbal: gimbal,
                ssid: ssid,
                password: password,
                token: token
            )
        }

        gimbal.onTerminalConnectionFailure = { [weak ble, weak wifi, weak gimbal] message in
            guard let ble, let wifi, let gimbal else { return }
            recoverAssociationAfterDatalinkFailure(
                ble: ble,
                wifi: wifi,
                gimbal: gimbal,
                message: message
            )
        }
    }

    private func connectPocket() {
        guard !gimbal.isConnected, !gimbal.isBusy, !wifi.isBusy else { return }
        pocketWorkflowGeneration &+= 1
        pocketWorkflowActive = true
        associationRecoveryUsed = false

        if ble.credentialsReady {
            joinPocketWiFiAndConnect(
                wifi: wifi,
                gimbal: gimbal,
                ssid: ble.ssid,
                password: ble.password,
                token: pocketWorkflowGeneration
            )
        } else {
            ble.connect()
        }
    }

    private func joinPocketWiFiAndConnect(
        wifi: Pocket3WiFiManager,
        gimbal: Pocket3GimbalSession,
        ssid: String,
        password: String,
        token: Int
    ) {
        wifi.join(ssid: ssid, passphrase: password) { joined in
            guard token == pocketWorkflowGeneration, pocketWorkflowActive else { return }
            guard joined else {
                pocketWorkflowActive = false
                return
            }
            gimbal.connect()
        }
    }

    private func recoverAssociationAfterDatalinkFailure(
        ble: Pocket3BLEManager,
        wifi: Pocket3WiFiManager,
        gimbal: Pocket3GimbalSession,
        message: String
    ) {
        guard pocketWorkflowActive else { return }
        let token = pocketWorkflowGeneration

        guard !associationRecoveryUsed else {
            pocketWorkflowActive = false
            wifi.note("Wi-Fi recovery: fresh association also failed; cleaning up (\(message))")
            wifi.disconnect(ssid: ble.ssid) {
                ble.disconnect()
            }
            return
        }

        associationRecoveryUsed = true
        wifi.note("Wi-Fi recovery: both fresh UDP attempts failed; resetting association once")
        wifi.disconnect(ssid: ble.ssid) {
            guard token == pocketWorkflowGeneration, pocketWorkflowActive else { return }
            joinPocketWiFiAndConnect(
                wifi: wifi,
                gimbal: gimbal,
                ssid: ble.ssid,
                password: ble.password,
                token: token
            )
        }
    }

    private func disconnectPocket() {
        pocketWorkflowGeneration &+= 1
        pocketWorkflowActive = false
        associationRecoveryUsed = false
        let ssid = ble.ssid

        let leaveWiFi = {
            wifi.disconnect(ssid: ssid) {
                ble.disconnect()
            }
        }

        if gimbal.isConnected || gimbal.isBusy {
            headTracking.invalidateControlCenter(reason: "Pocket 3 disconnected")
            gimbal.disconnect {
                DispatchQueue.main.async(execute: leaveWiFi)
            }
        } else {
            leaveWiFi()
        }
    }
}

private struct CompatibleNavigationView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content
            }
        } else {
            NavigationView {
                content
            }
            .navigationViewStyle(.stack)
        }
    }
}

private struct CompatibleLabeledContent: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent(title, value: value)
        } else {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct ControlScreen: View {
    @ObservedObject var gimbal: Pocket3GimbalSession
    @ObservedObject var preferences: ControllerPreferences
    @ObservedObject var gamepad: GameControllerManager
    @ObservedObject var headTracking: HeadTrackingManager

    @State private var touchPitch = JoystickMapper.neutral
    @State private var touchYaw = JoystickMapper.neutral

    var body: some View {
        CompatibleNavigationView {
            GeometryReader { proxy in
                let landscape = proxy.size.width > proxy.size.height

                if landscape {
                    landscapeContent(in: proxy)
                } else {
                    portraitContent
                }
            }
            .navigationTitle("Pocket 3 Controller")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func landscapeContent(in proxy: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            // Keep the joystick fixed and non-scrollable so vertical pitch drags
            // can never be stolen by a parent scroll view.
            joystickSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                statusHeader
                telemetryCard
                inputRow
                actionButtons
                Spacer(minLength: 0)
            }
            .frame(width: min(360, max(300, proxy.size.width * 0.38)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var portraitContent: some View {
        VStack(spacing: 12) {
            statusHeader
            telemetryCard
            inputRow

            joystickSurface
                .frame(maxWidth: .infinity)
                .frame(height: 300)

            actionButtons
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Gimbal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(gimbal.telemetryText)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var inputRow: some View {
        HStack {
            if headTracking.isEnabled && headTracking.isCentered && !headTracking.isManualOverrideActive {
                Label("Input: Head Tracking", systemImage: "airpodspro")
                    .font(.subheadline.weight(.semibold))
            } else {
                Label(
                    "Input: \(gamepad.lastInputSource.rawValue)",
                    systemImage: gamepad.lastInputSource == .gamepad ? "gamecontroller.fill" : "hand.tap.fill"
                )
                .font(.subheadline.weight(.semibold))
            }

            Spacer()

            Text(preferences.responseMode == .linear ? "Linear" : "Progressive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var joystickSurface: some View {
        VirtualJoystickView(
            isEnabled: gimbal.isConnected,
            responseMode: preferences.responseMode
        ) { pitch, yaw, active in
            touchPitch = pitch
            touchYaw = yaw
            gamepad.noteTouchInput(active: active)

            if active {
                headTracking.setManualOverride(.touch, active: true)
                gimbal.setJoystick(pitch: pitch, yaw: yaw)
            } else {
                if gamepad.lastInputSource == .touch {
                    // If the physical controller took ownership while this
                    // finger was still down, releasing the touchscreen must
                    // not neutralize the gamepad's current command.
                    gimbal.releaseJoystick()
                }
                headTracking.setManualOverride(.touch, active: false)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }

    private var actionButtons: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Button("Recenter") {
                    touchPitch = JoystickMapper.neutral
                    touchYaw = JoystickMapper.neutral
                    headTracking.prepareForRecenterAutoResume(reason: "Touchscreen recenter")
                    gimbal.recenter()
                }
                .buttonStyle(.bordered)
                .disabled(!gimbal.isConnected)
                .frame(maxWidth: .infinity)

                Button("Set Center") {
                    _ = gimbal.captureCenter()
                }
                .buttonStyle(.bordered)
                .disabled(!gimbal.canCaptureCenter)
                .frame(maxWidth: .infinity)

                Button("Stop") {
                    touchPitch = JoystickMapper.neutral
                    touchYaw = JoystickMapper.neutral
                    headTracking.invalidateControlCenter(reason: "Touchscreen STOP")
                    gimbal.neutral()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!gimbal.isConnected)
                .frame(maxWidth: .infinity)
            }

            Button(gimbal.smoothRecenterRunning ? "Returning to Center…" : "Return to Center") {
                touchPitch = JoystickMapper.neutral
                touchYaw = JoystickMapper.neutral
                headTracking.invalidateControlCenter(reason: "Touchscreen smooth recenter")
                gimbal.smoothRecenterToCapturedCenter()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!gimbal.canSmoothRecenter || gimbal.smoothRecenterRunning)
            .frame(maxWidth: .infinity)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(gimbal.isConnected ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)

            Text(gimbal.isConnected ? "Pocket 3 Connected" : "Pocket 3 Disconnected")
                .font(.subheadline.weight(.semibold))

            Spacer()

            if gamepad.isConnected {
                Label("Controller", systemImage: "gamecontroller.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DevicesScreen: View {
    @ObservedObject var ble: Pocket3BLEManager
    @ObservedObject var wifi: Pocket3WiFiManager
    @ObservedObject var gimbal: Pocket3GimbalSession
    @ObservedObject var gamepad: GameControllerManager
    @ObservedObject var headTracking: HeadTrackingManager
    let onConnectPocket: () -> Void
    let onDisconnectPocket: () -> Void

    var body: some View {
        CompatibleNavigationView {
            List {
                Section("Pocket 3") {
                    CompatibleLabeledContent("Bluetooth", value: ble.status)
                    CompatibleLabeledContent("Wi-Fi", value: wifi.status)
                    CompatibleLabeledContent("Control link", value: gimbal.isConnected ? "Connected" : "Disconnected")

                    Button(
                        (ble.isBusy || wifi.isBusy || gimbal.isBusy)
                            ? "Connecting Pocket 3…"
                            : "Connect Pocket 3"
                    ) {
                        onConnectPocket()
                    }
                    .disabled(ble.isBusy || wifi.isBusy || gimbal.isBusy || gimbal.isConnected)

                    if ble.credentialsReady {
                        CompatibleLabeledContent("Pocket SSID", value: ble.ssid)
                        Text("The app now manages this temporary accessory network. The first join requires the iOS confirmation prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if ble.isConnected || ble.isBusy || wifi.isJoined || wifi.isBusy || gimbal.isConnected || gimbal.isBusy {
                        Button("Disconnect Pocket 3", role: .destructive) {
                            onDisconnectPocket()
                        }
                    }
                }

                Section("Head Tracking — LIVE v0.6.3 SYMMETRIC YAW") {
                    Toggle(
                        "Head Tracking",
                        isOn: Binding(
                            get: { headTracking.isEnabled },
                            set: { enabled in
                                if enabled {
                                    headTracking.enable()
                                } else {
                                    headTracking.disable()
                                }
                            }
                        )
                    )

                    CompatibleLabeledContent("Status", value: headTracking.statusText)
                    CompatibleLabeledContent("Authorization", value: headTracking.authorizationText)

                    if headTracking.isEnabled {
                        Button(headTracking.isCentered ? "Set Head Center Again" : "Set Head Center — ARM LIVE CONTROL") {
                            _ = headTracking.captureCenter()
                        }
                        .disabled(!headTracking.hasMotion || !gimbal.isConnected)

                        CompatibleLabeledContent("Control", value: headTracking.controlText)
                        CompatibleLabeledContent("Command", value: headTracking.commandText)
                        CompatibleLabeledContent("Manual override", value: headTracking.isManualOverrideActive ? "Active" : "None")

                        if headTracking.isCentered {
                            CompatibleLabeledContent("Relative Pitch", value: headTracking.relativePitchText)
                            CompatibleLabeledContent("Relative Yaw", value: headTracking.relativeYawText)
                            CompatibleLabeledContent("Relative Roll", value: headTracking.relativeRollText)
                        }

                        DisclosureGroup("Raw AirPods Attitude") {
                            CompatibleLabeledContent("Raw Pitch", value: headTracking.pitchText)
                            CompatibleLabeledContent("Raw Yaw", value: headTracking.yawText)
                            CompatibleLabeledContent("Raw Roll", value: headTracking.rollText)
                            CompatibleLabeledContent("Continuous Yaw", value: headTracking.continuousYawText)
                        }

                        CompatibleLabeledContent("Samples", value: "\(headTracking.sampleCount)")
                    }

                    Text("Head Tracking still starts disarmed and requires Set Head Center. v0.6.3 keeps the full ±550 04/01 command authority and unrestricted pitch target from v0.6.2, but head-tracking yaw is now capped symmetrically at ±45° around the current head-control baseline. This keeps the long/right side from rotating much farther than the Pocket 3 can rotate on its short/left side. Touch and gamepad remain unrestricted by this head-only yaw limit. Manual override/rebase and RECENTER auto-resume are unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Game Controller") {
                    CompatibleLabeledContent("Status", value: gamepad.isConnected ? "Connected" : "Not Connected")
                    if gamepad.isConnected {
                        CompatibleLabeledContent("Controller", value: gamepad.controllerName)
                        if !gamepad.controllerCategory.isEmpty {
                            CompatibleLabeledContent("Profile", value: gamepad.controllerCategory)
                        }
                    }
                    Text(gamepad.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(gamepad.isDiscovering ? "Looking for Controllers…" : "Find Controllers") {
                        gamepad.discoverControllers()
                    }
                    .disabled(gamepad.isDiscovering)

                    Text("The controller must expose Apple's Extended Gamepad profile. Pair Bluetooth controllers with the iPhone normally; this app then receives them through Game Controller.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Devices")
        }
    }
}

private struct SettingsScreen: View {
    @ObservedObject var preferences: ControllerPreferences
    @ObservedObject var gamepad: GameControllerManager
    @ObservedObject var gimbal: Pocket3GimbalSession

    var body: some View {
        CompatibleNavigationView {
            Form {
                Section("Stick Layout") {
                    ForEach(GamepadStickLayout.allCases) { layout in
                        Button {
                            preferences.stickLayout = layout
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(layout.title)
                                        .foregroundStyle(.primary)
                                    Text(layout.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if preferences.stickLayout == layout {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Section("Axes") {
                    Toggle("Invert Pitch", isOn: $preferences.invertPitch)
                    Toggle("Invert Yaw", isOn: $preferences.invertYaw)
                }

                Section("Response") {
                    Picker("Response", selection: $preferences.responseMode) {
                        Text("Linear").tag(JoystickResponseMode.linear)
                        Text("Progressive").tag(JoystickResponseMode.progressive)
                    }
                    .pickerStyle(.segmented)
                    Text("The same response setting is used by both the touchscreen joystick and the physical controller.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Controller Buttons") {
                    CompatibleLabeledContent("A / Cross", value: "Recenter")
                    CompatibleLabeledContent("B / Circle", value: "Stop / Neutral")
                    CompatibleLabeledContent("X / Square", value: "Set Center")
                    CompatibleLabeledContent("Y / Triangle", value: "Return to Center")
                }

                Section {
                    Text(preferences.stickLayout.subtitle)
                    if gamepad.isConnected {
                        Text("Connected: \(gamepad.controllerName)")
                    }
                } footer: {
                    Text("Settings are saved automatically and restored on the next launch.")
                }
            }
            .navigationTitle("Controller Settings")
        }
    }
}

private struct DiagnosticsScreen: View {
    @ObservedObject var ble: Pocket3BLEManager
    @ObservedObject var wifi: Pocket3WiFiManager
    @ObservedObject var gimbal: Pocket3GimbalSession
    @ObservedObject var gamepad: GameControllerManager
    @ObservedObject var headTracking: HeadTrackingManager

    var body: some View {
        CompatibleNavigationView {
            List {
                Section("Status") {
                    CompatibleLabeledContent("Datalink", value: gimbal.status)
                    CompatibleLabeledContent("Pocket Wi-Fi", value: wifi.status)
                    CompatibleLabeledContent("Game Controller", value: gamepad.statusText)
                    CompatibleLabeledContent("Head Tracking", value: headTracking.statusText)
                    if headTracking.isEnabled {
                        Text("Head control: \(headTracking.controlText)  cmd=\(headTracking.commandText) override=\(headTracking.isManualOverrideActive ? "yes" : "no")")
                            .font(.system(.caption, design: .monospaced))
                        Text("AirPods raw: P=\(headTracking.pitchText) Y=\(headTracking.yawText) R=\(headTracking.rollText) Ycont=\(headTracking.continuousYawText) samples=\(headTracking.sampleCount)")
                            .font(.system(.caption, design: .monospaced))
                        if headTracking.isCentered {
                            Text("AirPods relative: P=\(headTracking.relativePitchText) Y=\(headTracking.relativeYawText) R=\(headTracking.relativeRollText)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    Text(gimbal.telemetryText)
                        .font(.system(.caption, design: .monospaced))
                    Text(gimbal.centerText)
                        .font(.system(.caption, design: .monospaced))
                }

                Section {
                    Button("New Test") {
                        gimbal.beginDiagnosticTest()
                        ble.beginDiagnosticTest()
                        wifi.clearLog()
                        wifi.note("=== NEW DIAGNOSTIC TEST ===")
                    }
                    Button("Clear All Logs", role: .destructive) {
                        gimbal.clearLog()
                        ble.clearLog()
                        wifi.clearLog()
                    }
                } header: {
                    Text("Log Controls")
                } footer: {
                    Text("New Test clears all three logs and inserts a fresh test marker without disconnecting the Pocket 3.")
                }

                Section("Datalink Log") {
                    Button("Copy Datalink Log") {
                        UIPasteboard.general.string = gimbal.logText
                    }
                    Button("Clear Datalink Log", role: .destructive) {
                        gimbal.clearLog()
                    }
                    Text(gimbal.logText.isEmpty ? "No datalink log yet." : gimbal.logText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("Bluetooth Log") {
                    Button("Copy Bluetooth Log") {
                        UIPasteboard.general.string = ble.logText
                    }
                    Button("Clear Bluetooth Log", role: .destructive) {
                        ble.clearLog()
                    }
                    Text(ble.logText.isEmpty ? "No Bluetooth log yet." : ble.logText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("Wi-Fi Log") {
                    Button("Copy Wi-Fi Log") {
                        UIPasteboard.general.string = wifi.logText
                    }
                    Button("Clear Wi-Fi Log", role: .destructive) {
                        wifi.clearLog()
                    }
                    Text(wifi.logText.isEmpty ? "No Wi-Fi log yet." : wifi.logText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}

#Preview {
    ContentView()
}
