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
                        Label("云台控制", systemImage: "dot.scope")
                    }

                    DevicesScreen(
                        ble: ble,
                        wifi: wifi,
                        gimbal: gimbal,
                        gamepad: gamepad,
                        headTracking: headTracking,
                        onConnectPocket: connectPocket,
                        onDisconnectPocket: disconnectPocket,
                        onContinueManual: continueManualConnection
                    )
                    .tabItem {
                        Label("设备", systemImage: "gamecontroller")
                    }

                    SettingsScreen(
                        preferences: preferences,
                        gamepad: gamepad,
                        gimbal: gimbal
                    )
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }

                    DiagnosticsScreen(
                        ble: ble,
                        wifi: wifi,
                        gimbal: gimbal,
                        gamepad: gamepad,
                        headTracking: headTracking
                    )
                    .tabItem {
                        Label("诊断", systemImage: "waveform.path.ecg")
                    }
                }

                Button {
                    showControlPanel = false
                } label: {
                    Label("关闭", systemImage: "xmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.trailing, 10)
                .accessibilityLabel("关闭控制面板")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if wifi.needsManualJoin && !showControlPanel {
                ManualWiFiConnectionView(wifi: wifi, onContinue: continueManualConnection, onCancel: disconnectPocket)
                    .padding().background(.regularMaterial)
            }
        }
        .onChange(of: gimbal.isConnected) { connected in
            if connected { wifi.confirmManualControlConnection() }
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
            if wifi.needsManualJoin && pocketWorkflowActive {
                continueManualConnection()
            } else {
                gimbal.resumeFromBackground()
            }

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
                if wifi.needsManualJoin { return }
                pocketWorkflowActive = false
                return
            }
            gimbal.connect()
        }
    }

    private func continueManualConnection() {
        guard pocketWorkflowActive, ble.credentialsReady,
              !gimbal.isBusy, !gimbal.isConnected else { return }
        wifi.beginManualControlConnection()
        gimbal.connect()
    }

    private func recoverAssociationAfterDatalinkFailure(
        ble: Pocket3BLEManager,
        wifi: Pocket3WiFiManager,
        gimbal: Pocket3GimbalSession,
        message: String
    ) {
        guard pocketWorkflowActive else { return }
        let token = pocketWorkflowGeneration
        if wifi.isUsingManualNetwork {
            wifi.note("Manual Wi-Fi control connection failed: \(message)")
            wifi.waitForManualJoin(ssid: ble.ssid, password: ble.password)
            return
        }

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
            headTracking.invalidateControlCenter(reason: "Pocket 3 已断开")
            gimbal.disconnect {
                DispatchQueue.main.async(execute: leaveWiFi)
            }
        } else {
            leaveWiFi()
        }
    }
}

private struct ManualWiFiConnectionView: View {
    @ObservedObject var wifi: Pocket3WiFiManager
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("手动连接 Pocket 3 Wi-Fi").font(.headline)
            Text("打开 iPhone「设置 → Wi-Fi」，加入以下网络。即使提示无互联网连接，也请保持连接，然后返回 Kaze。")
                .font(.subheadline)
            Text("网络：\(wifi.manualSSID)").textSelection(.enabled)
            Text("密码：\(wifi.manualPassword)").textSelection(.enabled)
            HStack {
                Button("复制密码") { UIPasteboard.general.string = wifi.manualPassword }
                Button("已连接，继续", action: onContinue).buttonStyle(.borderedProminent)
                Button("取消", action: onCancel)
            }
            Text("返回后会尝试控制握手；只有收到相机响应才会显示已连接。失败时可重新检查 Wi-Fi 后继续。")
                .font(.caption).foregroundStyle(.secondary)
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
            .navigationTitle("Pocket 3 控制器")
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
            Text("云台")
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
                Label("输入：头部追踪", systemImage: "airpodspro")
                    .font(.subheadline.weight(.semibold))
            } else {
                Label(
                    "输入：\(gamepad.lastInputSource.rawValue)",
                    systemImage: gamepad.lastInputSource == .gamepad ? "gamecontroller.fill" : "hand.tap.fill"
                )
                .font(.subheadline.weight(.semibold))
            }

            Spacer()

            Text(preferences.responseMode == .linear ? "线性" : "渐进")
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
                Button("回中") {
                    touchPitch = JoystickMapper.neutral
                    touchYaw = JoystickMapper.neutral
                    headTracking.prepareForRecenterAutoResume(reason: "Touchscreen recenter")
                    gimbal.recenter()
                }
                .buttonStyle(.bordered)
                .disabled(!gimbal.isConnected)
                .frame(maxWidth: .infinity)

                Button("设置中心") {
                    _ = gimbal.captureCenter()
                }
                .buttonStyle(.bordered)
                .disabled(!gimbal.canCaptureCenter)
                .frame(maxWidth: .infinity)

                Button("停止") {
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

            Button(gimbal.smoothRecenterRunning ? "正在返回中心…" : "返回中心") {
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

            Text(gimbal.isConnected ? "Pocket 3 已连接" : "Pocket 3 未连接")
                .font(.subheadline.weight(.semibold))

            Spacer()

            if gamepad.isConnected {
                Label("控制器", systemImage: "gamecontroller.fill")
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
    let onContinueManual: () -> Void

    var body: some View {
        CompatibleNavigationView {
            List {
                Section("Pocket 3") {
                    CompatibleLabeledContent("蓝牙", value: ble.status)
                    CompatibleLabeledContent("Wi-Fi", value: wifi.status)
                    CompatibleLabeledContent("控制连接", value: gimbal.isConnected ? "已连接" : "未连接")

                    Button(
                        (ble.isBusy || wifi.isBusy || gimbal.isBusy)
                            ? "正在连接 Pocket 3…"
                            : "连接 Pocket 3"
                    ) {
                        onConnectPocket()
                    }
                    .disabled(ble.isBusy || wifi.isBusy || gimbal.isBusy || gimbal.isConnected)

                    if ble.credentialsReady {
                        CompatibleLabeledContent("相机 Wi-Fi 名称", value: ble.ssid)
                        if wifi.needsManualJoin {
                            ManualWiFiConnectionView(wifi: wifi, onContinue: onContinueManual, onCancel: onDisconnectPocket)
                        }
                        Text("支持自动加入时会请求连接；个人签名可在系统设置中手动加入相机 Wi-Fi，再返回应用继续。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if ble.isConnected || ble.isBusy || wifi.isJoined || wifi.isBusy || gimbal.isConnected || gimbal.isBusy {
                        Button("断开 Pocket 3", role: .destructive) {
                            onDisconnectPocket()
                        }
                    }
                }

                Section("头部追踪 · v0.6.3 · 水平范围 ±45°") {
                    Toggle(
                        "头部追踪",
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

                    CompatibleLabeledContent("状态", value: headTracking.statusText)
                    CompatibleLabeledContent("运动权限", value: headTracking.authorizationText)

                    if headTracking.isEnabled {
                        Button(headTracking.isCentered ? "重新设置头部中心" : "设置头部中心并启动头追") {
                            _ = headTracking.captureCenter()
                        }
                        .disabled(!headTracking.hasMotion || !gimbal.isConnected)

                        CompatibleLabeledContent("控制状态", value: headTracking.controlText)
                        CompatibleLabeledContent("控制指令", value: headTracking.commandText)
                        CompatibleLabeledContent("手动接管", value: headTracking.isManualOverrideActive ? "正在接管" : "无")

                        if headTracking.isCentered {
                            CompatibleLabeledContent("相对俯仰角", value: headTracking.relativePitchText)
                            CompatibleLabeledContent("相对水平角", value: headTracking.relativeYawText)
                            CompatibleLabeledContent("相对横滚角", value: headTracking.relativeRollText)
                        }

                        DisclosureGroup("AirPods 原始姿态") {
                            CompatibleLabeledContent("原始俯仰角", value: headTracking.pitchText)
                            CompatibleLabeledContent("原始水平角", value: headTracking.yawText)
                            CompatibleLabeledContent("原始横滚角", value: headTracking.rollText)
                            CompatibleLabeledContent("连续水平角", value: headTracking.continuousYawText)
                        }

                        CompatibleLabeledContent("采样数", value: "\(headTracking.sampleCount)")
                    }

                    Text("开启后请正视前方，点击“设置头部中心并启动头追”。水平跟随范围为中心左右各 45°，俯仰目标不额外限制。触屏和手柄不受此水平范围限制；手动操作结束或云台回中后，头追会自动重新校准并恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("游戏手柄") {
                    CompatibleLabeledContent("状态", value: gamepad.isConnected ? "已连接" : "未连接")
                    if gamepad.isConnected {
                        CompatibleLabeledContent("控制器", value: gamepad.controllerName)
                        if !gamepad.controllerCategory.isEmpty {
                            CompatibleLabeledContent("配置类型", value: gamepad.controllerCategory)
                        }
                    }
                    Text(gamepad.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(gamepad.isDiscovering ? "正在查找手柄…" : "查找手柄") {
                        gamepad.discoverControllers()
                    }
                    .disabled(gamepad.isDiscovering)

                    Text("请先在 iPhone 蓝牙设置中配对手柄。应用支持符合 Apple 扩展游戏手柄规范的控制器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设备")
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
                Section("摇杆布局") {
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

                Section("控制方向") {
                    Toggle("反转俯仰方向", isOn: $preferences.invertPitch)
                    Toggle("反转水平方向", isOn: $preferences.invertYaw)
                }

                Section("响应曲线") {
                    Picker("响应曲线", selection: $preferences.responseMode) {
                        Text("线性").tag(JoystickResponseMode.linear)
                        Text("渐进").tag(JoystickResponseMode.progressive)
                    }
                    .pickerStyle(.segmented)
                    Text("触屏摇杆和实体手柄共用此响应曲线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("手柄按键") {
                    CompatibleLabeledContent("A / 叉键", value: "回中")
                    CompatibleLabeledContent("B / 圆圈键", value: "停止 / 归零")
                    CompatibleLabeledContent("X / 方块键", value: "设置中心")
                    CompatibleLabeledContent("Y / 三角键", value: "返回中心")
                }

                Section {
                    Text(preferences.stickLayout.subtitle)
                    if gamepad.isConnected {
                        Text("已连接：\(gamepad.controllerName)")
                    }
                } footer: {
                    Text("设置会自动保存，下次打开时恢复。")
                }
            }
            .navigationTitle("控制器设置")
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
                Section("状态") {
                    CompatibleLabeledContent("数据连接", value: gimbal.status)
                    CompatibleLabeledContent("相机 Wi-Fi", value: wifi.status)
                    CompatibleLabeledContent("游戏手柄", value: gamepad.statusText)
                    CompatibleLabeledContent("头部追踪", value: headTracking.statusText)
                    if headTracking.isEnabled {
                        Text("头追：\(headTracking.controlText) 指令=\(headTracking.commandText) 手动接管=\(headTracking.isManualOverrideActive ? "是" : "否")")
                            .font(.system(.caption, design: .monospaced))
                        Text("AirPods 原始姿态：俯仰=\(headTracking.pitchText) Y=\(headTracking.yawText) R=\(headTracking.rollText) Ycont=\(headTracking.continuousYawText) 采样数=\(headTracking.sampleCount)")
                            .font(.system(.caption, design: .monospaced))
                        if headTracking.isCentered {
                            Text("AirPods 相对姿态：俯仰=\(headTracking.relativePitchText) Y=\(headTracking.relativeYawText) R=\(headTracking.relativeRollText)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    Text(gimbal.telemetryText)
                        .font(.system(.caption, design: .monospaced))
                    Text(gimbal.centerText)
                        .font(.system(.caption, design: .monospaced))
                }

                Section {
                    Button("开始新测试") {
                        gimbal.beginDiagnosticTest()
                        ble.beginDiagnosticTest()
                        wifi.clearLog()
                        wifi.note("=== NEW DIAGNOSTIC TEST ===")
                    }
                    Button("清空全部日志", role: .destructive) {
                        gimbal.clearLog()
                        ble.clearLog()
                        wifi.clearLog()
                    }
                } header: {
                    Text("日志操作")
                } footer: {
                    Text("新测试会清空三类日志并插入测试标记，相机保持连接。")
                }

                Section("数据连接日志") {
                    Button("复制数据连接日志") {
                        UIPasteboard.general.string = gimbal.logText
                    }
                    Button("清空数据连接日志", role: .destructive) {
                        gimbal.clearLog()
                    }
                    Text(gimbal.logText.isEmpty ? "暂无数据连接日志。" : gimbal.logText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("蓝牙日志") {
                    Button("复制蓝牙日志") {
                        UIPasteboard.general.string = ble.logText
                    }
                    Button("清空蓝牙日志", role: .destructive) {
                        ble.clearLog()
                    }
                    Text(ble.logText.isEmpty ? "暂无蓝牙日志。" : ble.logText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("Wi-Fi 日志") {
                    Button("复制 Wi-Fi 日志") {
                        UIPasteboard.general.string = wifi.logText
                    }
                    Button("清空 Wi-Fi 日志", role: .destructive) {
                        wifi.clearLog()
                    }
                    Text(wifi.logText.isEmpty ? "暂无 Wi-Fi 日志。" : wifi.logText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("诊断")
        }
    }
}

#Preview {
    ContentView()
}
