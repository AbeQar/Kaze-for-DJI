import SwiftUI
import Foundation

/// Production-facing camera control surface.
///
/// This view intentionally uses only capabilities already proven in the current
/// Pocket3Controller branch:
/// - live Pocket 3 connection state
/// - touchscreen gimbal control through the existing JoystickMapper + session
/// - native recenter
/// - captured-position mark + smooth return
/// - existing game-controller / AirPods manual-override arbitration
///
/// Camera battery percentage and charging state use hardware-confirmed Pocket 3 0D/02 telemetry.
/// Direct H.264 preview uses the capture-confirmed Pocket pktType-0x02 path.
private enum CameraSettingsDestination: Equatable {
    case video
    case whiteBalance
    case exposure
    case focus
    case camera

    var title: String {
        switch self {
        case .video:
            return "Current Mode"
        case .whiteBalance:
            return "White Balance"
        case .exposure:
            return "Exposure Compensation"
        case .focus:
            return "Focus"
        case .camera:
            return "Camera Settings"
        }
    }
}

struct CameraConnectionPresentation: Equatable {
    let topLabel: String
    let title: String
    let deviceName: String?
    let status: String
    let actionTitle: String

    static func make(isConnected: Bool, connectedCameraDisplayName: String?) -> Self {
        guard isConnected, let name = connectedCameraDisplayName else {
            return Self(
                topLabel: "Cameras",
                title: "Cameras",
                deviceName: nil,
                status: "No camera connected",
                actionTitle: "Connect Camera"
            )
        }
        return Self(
            topLabel: name,
            title: "Cameras",
            deviceName: name,
            status: "Connected",
            actionTitle: "Disconnect"
        )
    }
}

struct CameraControlScreen: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var gimbal: Pocket3GimbalSession
    @ObservedObject var preferences: ControllerPreferences
    @ObservedObject var gamepad: GameControllerManager
    @ObservedObject var headTracking: HeadTrackingManager
    let connectedCameraDisplayName: String?
    let onConnectCamera: () -> Void
    let onDisconnectCamera: () -> Void
    let onOpenLegacyDebug: () -> Void

    @AppStorage("touch.joystickLayout") private var joystickLayoutRaw = TouchJoystickLayout.dual.rawValue
    @AppStorage("video.landscapeFull16x9") private var landscapeFull16x9 = false
    @AppStorage("video.automaticPictureInPicture") private var automaticPictureInPictureEnabled = true
    @State private var showLayoutPicker = false
    @State private var showTools = false
    @State private var showCameraConnections = false
    @State private var showCameraSettings = false
    @State private var cameraSettingsDestination: CameraSettingsDestination = .camera
    @State private var gridEnabled = true
    @State private var hasMarkedPosition = false

    // Last-sent values remain as a fallback for controls whose 00/99 readback fields
    // are not decoded yet. Core camera values prefer live Pocket readback whenever present.
    @State private var lastSentVideo = "—"
    @State private var lastSentWhiteBalance = "—"
    @State private var lastSentEV = "—"
    @State private var lastSentFocus = "—"
    @State private var lastSentPro = "—"
    @State private var lastSentCompression = "—"
    @State private var lastSentExposureMode = "—"
    @State private var lastSentISO = "—"
    @State private var lastSentISOMax = "—"
    @State private var lastSentShutter = "—"
    @State private var lastSentColor = "—"
    @State private var lastSentProductShowcase = "—"
    @State private var lastSentLowLight = "—"
    @State private var lastSentSlowMotion = "—"
    @State private var lastSentPhotoFrame = "—"
    @State private var lastSentPhotoFormat = "—"
    @State private var lastSentPhotoCountdown = "—"
    @State private var lastSentTimelapse = "—"
    @State private var lastMotionlapseWaypointAction = "—"
    @State private var lastSentAudioChannel = "—"

    // Draft values are local UI choices. For normal video, an unset draft field can
    // inherit the corresponding live Pocket readback value before Apply.
    @State private var draftVideoResolution: Pocket3CameraSettings.VideoResolution?
    @State private var draftVideoFrameRate: Pocket3CameraSettings.FrameRate?
    @State private var draftLowLightResolution: Pocket3CameraSettings.VideoResolution?
    @State private var draftLowLightFrameRate: Pocket3CameraSettings.FrameRate?
    @State private var draftKelvin = 5600.0
    @State private var draftEVThirdStops = 0.0
    @State private var draftTimelapseIntervalTenths: UInt16?
    @State private var draftTimelapseDurationSeconds: UInt32?
    @State private var draftTimelapseOutput: Pocket3CameraSettings.TimelapseOutput?

    // Normalized touch state. Positive yaw = right. Positive pitch = up.
    @State private var touchYaw = 0.0
    @State private var touchPitch = 0.0
    @State private var yawTouchActive = false
    @State private var pitchTouchActive = false

    private var joystickLayout: TouchJoystickLayout {
        get { TouchJoystickLayout(rawValue: joystickLayoutRaw) ?? .dual }
        nonmutating set { joystickLayoutRaw = newValue.rawValue }
    }

    private var cameraState: Pocket3CameraState { gimbal.cameraState }
    private var cameraReadback: Pocket3CameraReadbackState { cameraState.readback }

    private var currentShootingMode: Pocket3CameraShootingMode? {
        cameraState.shootingMode
    }

    private var currentShootingModeValue: String {
        if let mode = currentShootingMode {
            return mode.shortLabel
        }
        if let raw = cameraState.shootingModeRawValue {
            return String(format: "0x%02X", raw)
        }
        return "—"
    }

    private var currentShootingModeDescription: String {
        if let mode = currentShootingMode {
            return mode.displayName
        }
        if let raw = cameraState.shootingModeRawValue {
            return String(format: "Unknown (0x%02X)", raw)
        }
        return gimbal.isConnected ? "Waiting for mode readback" : "Disconnected"
    }

    private var currentVideoValue: String {
        if let resolution = cameraReadback.videoResolution,
           let frameRate = cameraReadback.videoFrameRate {
            return "\(videoResolutionLabel(resolution))/\(frameRateLabel(frameRate))"
        }
        return lastSentVideo
    }

    private var currentTopFormatDescriptor: String {
        let orientation = cameraReadback.sensorAspectRatio?.displayName.uppercased() ?? "—"

        if currentShootingMode == .video,
           let resolution = cameraReadback.videoResolution,
           let frameRate = cameraReadback.videoFrameRate {
            return "\(videoResolutionLabel(resolution)) \(frameRateLabel(frameRate)) • \(orientation)"
        }

        if let mode = currentShootingMode {
            return "\(mode.shortLabel) • \(orientation)"
        }

        return orientation
    }

    private var currentWhiteBalanceValue: String {
        switch cameraReadback.whiteBalance {
        case .auto?: return "AUTO"
        case .customKelvin(let kelvin)?: return "\(kelvin)K"
        case nil: return lastSentWhiteBalance
        }
    }

    private var currentEVValue: String {
        if let thirdStops = cameraReadback.evThirdStops {
            return evLabel(thirdStops: thirdStops)
        }
        return lastSentEV
    }

    private var currentFocusValue: String {
        switch cameraReadback.focusMode {
        case .single?: return "S-AF"
        case .continuous?: return "C-AF"
        case nil: return lastSentFocus
        }
    }

    private var currentCompressionValue: String {
        switch cameraReadback.videoCompression {
        case .h264Compatibility?: return "H.264"
        case .hevcEfficiency?: return "HEVC"
        case nil: return lastSentCompression
        }
    }

    private var currentColorValue: String {
        switch cameraReadback.colorProfile {
        case .normal?: return "Normal"
        case .hlg?: return "HLG"
        case .dLogM?: return "D-Log M"
        case nil: return lastSentColor
        }
    }

    private var currentExposureModeValue: String {
        switch cameraReadback.exposureMode {
        case .auto?: return "AUTO"
        case .manual?: return "MANUAL"
        case nil: return lastSentExposureMode
        }
    }

    private var currentPhotoFrameValue: String {
        switch cameraReadback.photoFrame {
        case .sixteenByNine?: return "16:9"
        case .oneByOne?: return "1:1"
        case nil: return lastSentPhotoFrame
        }
    }

    private var currentPhotoFormatValue: String {
        switch cameraReadback.photoFormat {
        case .jpeg?: return "JPEG"
        case .jpegAndRaw?: return "JPEG+RAW"
        case nil: return lastSentPhotoFormat
        }
    }

    private var currentPhotoCountdownValue: String {
        switch cameraReadback.photoCountdown {
        case .off?: return "OFF"
        case .seconds3?: return "3s"
        case .seconds5?: return "5s"
        case .seconds7?: return "7s"
        case nil: return lastSentPhotoCountdown
        }
    }

    private var selectedVideoResolution: Pocket3CameraSettings.VideoResolution? {
        draftVideoResolution ?? cameraReadback.videoResolution
    }

    private var selectedVideoFrameRate: Pocket3CameraSettings.FrameRate? {
        draftVideoFrameRate ?? cameraReadback.videoFrameRate
    }

    private var selectedTimelapseIntervalTenths: UInt16? {
        draftTimelapseIntervalTenths ?? cameraReadback.timelapseIntervalTenths
    }

    private var selectedTimelapseDurationSeconds: UInt32? {
        draftTimelapseDurationSeconds ?? cameraReadback.timelapseDurationSeconds
    }

    private var selectedTimelapseOutput: Pocket3CameraSettings.TimelapseOutput? {
        draftTimelapseOutput ?? cameraReadback.timelapseOutput
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height

            ZStack {
                Color.black
                    .ignoresSafeArea()

                // Keep exactly one SwiftUI/UIViewRepresentable host for the live
                // preview across portrait/landscape changes and the landscape
                // 16:9 toggle. Rebuilding this subtree creates a new
                // AVSampleBufferDisplayLayer, which also forces AVKit to replace
                // the PiP content source and makes the new decoder wait for an IDR.
                // Layout changes must only update videoGravity on the existing layer.
                let fitWholeVideoFrame = !landscape || landscapeFull16x9

                CameraLivePreview(
                    output: gimbal.videoOutput,
                    isConnected: gimbal.isConnected,
                    videoReceiving: gimbal.videoReceiving,
                    aspectFill: landscape && !landscapeFull16x9
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

                if gridEnabled {
                    if fitWholeVideoFrame {
                        // When the video is aspect-fitted, constrain the grid to the
                        // actual 16:9 picture instead of drawing through the black bars.
                        CameraGridOverlay()
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    } else {
                        // Full-screen operator mode uses aspect-fill, so the visible
                        // picture occupies the entire display area.
                        CameraGridOverlay()
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }

                VStack(spacing: 0) {
                    CameraTopStatusBar(
                        portrait: !landscape,
                        formatDescriptor: currentTopFormatDescriptor,
                        gimbal: gimbal,
                        preferences: preferences,
                        gamepad: gamepad,
                        headTracking: headTracking,
                        connectedCameraDisplayName: connectedCameraDisplayName,
                        onOpenCameraConnections: {
                            showCameraConnections.toggle()
                            if showCameraConnections {
                                showLayoutPicker = false
                                showTools = false
                                showCameraSettings = false
                            }
                        }
                    )
                    .padding(.horizontal, landscape ? 28 : 14)
                    .padding(.top, landscape ? 8 : 2)

                    Spacer()

                    if !landscape {
                        CameraCaptureButton(
                            enabled: primaryCaptureButtonEnabled,
                            recording: cameraState.recording == true,
                            transitioning: cameraState.recordingTransitionInProgress || cameraState.recordCommandInFlight,
                            photoShutter: currentShootingMode == .photo
                        ) {
                            performPrimaryCaptureAction()
                        }
                            .padding(.bottom, 12)
                    }

                    CameraBottomControlBar(
                        showTools: $showTools,
                        showSettings: $showCameraSettings,
                        settingsDestination: $cameraSettingsDestination,
                        modeValue: currentShootingModeValue,
                        videoValue: currentVideoValue,
                        whiteBalanceValue: currentWhiteBalanceValue,
                        evValue: currentEVValue,
                        focusValue: currentFocusValue
                    )
                        .padding(.horizontal, landscape ? 110 : 18)
                        .padding(.bottom, landscape ? 2 : 6)
                }

                if landscape {
                    landscapeControls(in: proxy)
                } else {
                    portraitControls
                }

                if showLayoutPicker {
                    layoutPickerOverlay(landscape: landscape)
                }

                if showTools {
                    toolsOverlay(landscape: landscape)
                }

                if showCameraConnections {
                    cameraConnectionsOverlay(landscape: landscape)
                }

                if showCameraSettings {
                    cameraSettingsOverlay(landscape: landscape)
                }
            }
            // Keep the entire camera UI inside the GeometryReader's real screen
            // bounds. Transient status text (especially REC elapsed time) must
            // never be allowed to enlarge the root ZStack and move controls that
            // are aligned to its trailing edge.
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .preferredColorScheme(.dark)
            .animation(.easeInOut(duration: 0.22), value: showLayoutPicker)
            .animation(.easeInOut(duration: 0.22), value: showTools)
            .animation(.easeInOut(duration: 0.22), value: showCameraConnections)
            .animation(.easeInOut(duration: 0.22), value: showCameraSettings)
            .onAppear {
                gimbal.videoOutput.setAutomaticPictureInPictureEnabled(
                    automaticPictureInPictureEnabled
                )
            }
            .onDisappear {
                releaseAllTouchControl()
            }
            .onChange(of: automaticPictureInPictureEnabled) { enabled in
                gimbal.videoOutput.setAutomaticPictureInPictureEnabled(enabled)
            }
            .onChange(of: showTools) { visible in
                if visible { showCameraConnections = false }
            }
            .onChange(of: showCameraSettings) { visible in
                if visible { showCameraConnections = false }
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase != .active {
                    releaseAllTouchControl()
                }
            }
            .onChange(of: gimbal.isConnected) { connected in
                if !connected {
                    clearLastSentCameraSettings()
                }
            }
            .onChange(of: cameraReadback.sensorAspectRatio) { _ in
                // Orientation is controlled on the Pocket itself for now.
                // Drop any stale draft resolution when the camera rotates so
                // Apply can never carry a Landscape choice into Portrait, or vice versa.
                draftVideoResolution = nil
            }
        }
    }

    // MARK: - Landscape

    @ViewBuilder
    private func landscapeControls(in proxy: GeometryProxy) -> some View {
        ZStack {
            landscapeGimbalControls

            HStack(spacing: 2) {
                CameraActionButton(
                    title: gimbal.isGimbalLocked ? "Unlock" : "Lock",
                    systemImage: gimbal.isGimbalLocked ? "lock.fill" : "lock.open",
                    enabled: gimbal.isConnected
                ) {
                    releaseAllTouchControl()
                    gimbal.setGimbalLocked(!gimbal.isGimbalLocked)
                }

                CameraActionButton(
                    title: "Recenter",
                    systemImage: "scope",
                    enabled: gimbal.isConnected
                ) {
                    releaseAllTouchControl()
                    headTracking.prepareForRecenterAutoResume(reason: "Camera UI recenter")
                    gimbal.recenter()
                }

                CameraActionButton(
                    title: "Mark",
                    systemImage: hasMarkedPosition ? "bookmark.fill" : "bookmark",
                    enabled: gimbal.canCaptureCenter
                ) {
                    if gimbal.captureCenter() {
                        hasMarkedPosition = true
                    }
                }

                CameraActionButton(
                    title: gimbal.smoothRecenterRunning ? "Returning" : "Return",
                    systemImage: "arrow.uturn.backward",
                    enabled: gimbal.canSmoothRecenter && !gimbal.smoothRecenterRunning
                ) {
                    releaseAllTouchControl()
                    headTracking.invalidateControlCenter(reason: "Camera UI smooth return")
                    gimbal.smoothRecenterToCapturedCenter()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 8)
            .padding(.top, 56)

            // Intentionally aligned to the physical landscape screen center, not
            // merely the safe-area content center, so it tracks the Dynamic Island.
            CameraCaptureButton(
                enabled: primaryCaptureButtonEnabled,
                recording: cameraState.recording == true,
                transitioning: cameraState.recordingTransitionInProgress || cameraState.recordCommandInFlight,
                photoShutter: currentShootingMode == .photo
            ) {
                performPrimaryCaptureAction()
            }
                .position(
                    x: proxy.size.width - 36,
                    y: proxy.size.height / 2
                        + (proxy.safeAreaInsets.bottom - proxy.safeAreaInsets.top) / 2
                )

            layoutButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 9)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var landscapeGimbalControls: some View {
        switch joystickLayout {
        case .left:
            CameraCombinedJoystick(label: "PAN / TILT", enabled: gimbal.isConnected) { yaw, pitch, active in
                updateCombinedTouch(yaw: yaw, pitch: pitch, active: active)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 24)
            .padding(.bottom, 66)

        case .right:
            CameraCombinedJoystick(label: "PAN / TILT", enabled: gimbal.isConnected) { yaw, pitch, active in
                updateCombinedTouch(yaw: yaw, pitch: pitch, active: active)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 92)
            .padding(.bottom, 66)

        case .dual:
            CameraHorizontalAxisJoystick(label: "YAW", enabled: gimbal.isConnected) { value, active in
                updateYawTouch(value: value, active: active)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 22)
            .padding(.bottom, 66)

            CameraVerticalAxisJoystick(label: "PITCH", enabled: gimbal.isConnected) { value, active in
                updatePitchTouch(value: value, active: active)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 118)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Portrait

    private var portraitControls: some View {
        ZStack {
            HStack(spacing: 2) {
                CameraActionButton(
                    title: gimbal.isGimbalLocked ? "Unlock" : "Lock",
                    systemImage: gimbal.isGimbalLocked ? "lock.fill" : "lock.open",
                    enabled: gimbal.isConnected
                ) {
                    releaseAllTouchControl()
                    gimbal.setGimbalLocked(!gimbal.isGimbalLocked)
                }

                CameraActionButton(
                    title: "Recenter",
                    systemImage: "scope",
                    enabled: gimbal.isConnected
                ) {
                    releaseAllTouchControl()
                    headTracking.prepareForRecenterAutoResume(reason: "Camera UI recenter")
                    gimbal.recenter()
                }

                CameraActionButton(
                    title: "Mark",
                    systemImage: hasMarkedPosition ? "bookmark.fill" : "bookmark",
                    enabled: gimbal.canCaptureCenter
                ) {
                    if gimbal.captureCenter() {
                        hasMarkedPosition = true
                    }
                }

                CameraActionButton(
                    title: gimbal.smoothRecenterRunning ? "Returning" : "Return",
                    systemImage: "arrow.uturn.backward",
                    enabled: gimbal.canSmoothRecenter && !gimbal.smoothRecenterRunning
                ) {
                    releaseAllTouchControl()
                    headTracking.invalidateControlCenter(reason: "Camera UI smooth return")
                    gimbal.smoothRecenterToCapturedCenter()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 10)
            .padding(.top, 84)

            portraitGimbalControls

            layoutButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 12)
                .padding(.bottom, 66)
        }
    }

    @ViewBuilder
    private var portraitGimbalControls: some View {
        switch joystickLayout {
        case .left:
            CameraCombinedJoystick(label: "PAN / TILT", enabled: gimbal.isConnected) { yaw, pitch, active in
                updateCombinedTouch(yaw: yaw, pitch: pitch, active: active)
            }
            .scaleEffect(0.90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 10)
            .padding(.bottom, 142)

        case .right:
            CameraCombinedJoystick(label: "PAN / TILT", enabled: gimbal.isConnected) { yaw, pitch, active in
                updateCombinedTouch(yaw: yaw, pitch: pitch, active: active)
            }
            .scaleEffect(0.90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 10)
            .padding(.bottom, 142)

        case .dual:
            CameraHorizontalAxisJoystick(label: "YAW", enabled: gimbal.isConnected) { value, active in
                updateYawTouch(value: value, active: active)
            }
            .scaleEffect(0.90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 4)
            .padding(.bottom, 140)

            CameraVerticalAxisJoystick(label: "PITCH", enabled: gimbal.isConnected) { value, active in
                updatePitchTouch(value: value, active: active)
            }
            .scaleEffect(0.90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 28)
            .padding(.bottom, 102)
        }
    }

    // MARK: - Popovers

    private var layoutButton: some View {
        Button {
            showLayoutPicker.toggle()
            showTools = false
            showCameraSettings = false
            showCameraConnections = false
        } label: {
            Label("Layout", systemImage: "rectangle.split.2x1")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func layoutPickerOverlay(landscape: Bool) -> some View {
        VStack {
            Spacer()
            HStack {
                if landscape {
                    CameraLayoutPicker(selection: Binding(
                        get: { joystickLayout },
                        set: { joystickLayout = $0 }
                    ), show: $showLayoutPicker)
                    .frame(width: 236)
                    .padding(.leading, 28)
                    Spacer()
                } else {
                    Spacer()
                    CameraLayoutPicker(selection: Binding(
                        get: { joystickLayout },
                        set: { joystickLayout = $0 }
                    ), show: $showLayoutPicker)
                    .frame(width: 236)
                    Spacer()
                }
            }
            .padding(.bottom, landscape ? 90 : 140)
        }
    }

    @ViewBuilder
    private func toolsOverlay(landscape: Bool) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Monitoring Tools")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button {
                            showTools = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Toggle("Grid", isOn: $gridEnabled)

                    Toggle("Full 16:9 in landscape", isOn: $landscapeFull16x9)

                    Toggle("Automatic Picture in Picture", isOn: $automaticPictureInPictureEnabled)

                    Divider()

                    Button {
                        showTools = false
                        onOpenLegacyDebug()
                    } label: {
                        Label("Legacy / Debug", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Text("Histogram, waveform, zebras, false color and focus peaking will be enabled only after their real video-analysis pipelines are implemented.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(13)
                .frame(width: landscape ? 330 : 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
                Spacer()
            }
            .padding(.bottom, landscape ? 74 : 90)
        }
    }

    @ViewBuilder
    private func cameraConnectionsOverlay(landscape: Bool) -> some View {
        let presentation = CameraConnectionPresentation.make(
            isConnected: gimbal.isConnected,
            connectedCameraDisplayName: connectedCameraDisplayName
        )

        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(presentation.title)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button {
                            showCameraConnections = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if let deviceName = presentation.deviceName {
                        Text(deviceName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }

                    Text(presentation.status)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(gimbal.isConnected ? Color.green : Color.secondary)

                    Button(presentation.actionTitle) {
                        if gimbal.isConnected {
                            onDisconnectCamera()
                        } else {
                            onConnectCamera()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(gimbal.isBusy)
                    .frame(maxWidth: .infinity)
                }
                .padding(13)
                .frame(width: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
                Spacer()
            }
            .padding(.bottom, landscape ? 74 : 90)
        }
    }

    @ViewBuilder
    private func cameraSettingsOverlay(landscape: Bool) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cameraSettingsDestination.title)
                                .font(.system(size: 14, weight: .semibold))
                            Text(gimbal.isConnected ? "Pocket 3 connected" : "Pocket 3 disconnected")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(gimbal.isConnected ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Button {
                            showCameraSettings = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        Text("MODE")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(currentShootingModeDescription)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        Spacer()
                        if let raw = cameraState.shootingModeRawValue {
                            Text(String(format: "02/80 0x%02X", raw))
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(cameraSettingsDestination == .camera
                         ? "The Pocket 3 shooting mode is read live from 02/80. Timelapse ↔ Motionlapse switching is now capture-confirmed through 02/E1; unrelated shooting-mode switching remains read-only here."
                         : "Quick access follows the Pocket 3's live shooting mode. Supported core values continue to update from camera readback after connection.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            if cameraSettingsDestination == .video {
                                currentModeSettingsSection
                            }

                            if cameraSettingsDestination == .camera {
                                currentModeSettingsSection
                                commonCameraSettingsSections
                            }

                            if cameraSettingsDestination == .whiteBalance {
                                whiteBalanceSettingsSection
                            }

                            if cameraSettingsDestination == .exposure {
                                exposureSettingsSection
                            }

                            if cameraSettingsDestination == .focus {
                                focusSettingsSection
                            }
                        }
                        .padding(.trailing, 2)
                    }
                }
                .padding(13)
                .frame(width: landscape ? 470 : 350)
                .frame(maxHeight: cameraSettingsPanelMaxHeight(landscape: landscape))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
                Spacer()
            }
            .padding(.bottom, landscape ? 66 : 82)
        }
    }

    private func cameraSettingsPanelMaxHeight(landscape: Bool) -> CGFloat {
        switch cameraSettingsDestination {
        case .camera, .video:
            return landscape ? 330 : 520
        case .whiteBalance:
            return landscape ? 230 : 250
        case .exposure:
            return landscape ? 300 : 370
        case .focus:
            return landscape ? 220 : 250
        }
    }

    private func cameraSettingsSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
    }

    private func cameraSettingsNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.25))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var currentModeSettingsSection: some View {
        if !gimbal.isConnected {
            cameraSettingsNote("Connect to the Pocket 3 to load mode-specific controls.")
        } else if let mode = currentShootingMode {
            switch mode {
            case .video:
                normalVideoSettingsSection
                videoCompressionAndColorSection
            case .lowLight:
                lowLightSettingsSection
                videoCompressionAndColorSection
            case .slowMotion:
                slowMotionSettingsSection
                videoCompressionAndColorSection
            case .photo:
                photoSettingsSection
            case .timelapse:
                timelapseSettingsSection
            case .hyperlapse:
                hyperlapseSettingsSection
            case .panorama:
                panoramaSettingsSection
            case .motionlapse:
                motionlapseSettingsSection
            }
        } else if let raw = cameraState.shootingModeRawValue {
            cameraSettingsNote(String(format: "Unsupported shooting-mode readback 0x%02X. No mode-specific writer controls are shown.", raw))
        } else {
            cameraSettingsNote("Waiting for the Pocket 3 shooting-mode status push …")
        }
    }

    @ViewBuilder
    private var commonCameraSettingsSections: some View {
        cameraSettingsSectionTitle("Common Camera Controls")
        cameraSettingsNote("These controls are kept separate from the active shooting-mode block. Their command mappings are capture-derived; readback is used where decoded.")
        whiteBalanceSettingsSection
        exposureSettingsSection
        focusSettingsSection
        proSettingsSection
        audioSettingsSection
        cameraFacingAndRecenterSection
        withheldSettingsSection
    }

    @ViewBuilder
    private var normalVideoSettingsSection: some View {
        cameraSettingsSectionTitle("Normal Video Format")
        cameraSettingsNote("Video mode confirmed from live 02/80 readback. Kaze follows the Pocket's effective orientation; change Landscape / Portrait on the camera itself and the available format choices update from live readback.")

        if let aspect = cameraReadback.sensorAspectRatio {
            cameraSettingsNote("Effective orientation: \(aspect.displayName). Remote orientation switching is deferred; these controls only change recording format within the camera's current orientation.")

            switch aspect {
            case .landscape:
                Text("Landscape / 1:1 Resolution")
                    .font(.system(size: 10, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 7)], spacing: 7) {
                    videoResolutionButton("1080p", .p1080)
                    videoResolutionButton("2.7K", .p2_7K)
                    videoResolutionButton("4K", .p4K)
                    videoResolutionButton("1:1 1080", .square1080)
                    videoResolutionButton("1:1 2160", .square2160)
                    videoResolutionButton("1:1 3K", .square3K)
                }

            case .portrait:
                Text("Portrait / 9:16 Resolution")
                    .font(.system(size: 10, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 7)], spacing: 7) {
                    videoResolutionButton("9:16 1080", .portrait1080)
                    videoResolutionButton("9:16 2.7K", .portrait2_7K)
                    videoResolutionButton("9:16 3K", .portrait3K)
                }
            }
        } else {
            cameraSettingsNote("Waiting for orientation readback before enabling resolution changes.")
        }

        Text("Frame Rate")
            .font(.system(size: 10, weight: .semibold))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 7)], spacing: 7) {
            videoFrameRateButton("24", .fps24)
            videoFrameRateButton("25", .fps25)
            videoFrameRateButton("30", .fps30)
            videoFrameRateButton("48", .fps48)
            videoFrameRateButton("50", .fps50)
            videoFrameRateButton("60", .fps60)
        }

        CameraSettingChoiceButton(
            title: draftVideoFormatApplyTitle,
            selected: false,
            enabled: canApplySelectedVideoFormat
        ) {
            applyDraftVideoFormat()
        }

        if cameraReadback.videoResolution != nil, cameraReadback.videoFrameRate != nil {
            cameraSettingsNote("Camera readback: \(currentVideoValue)")
        } else if lastSentVideo != "—" {
            cameraSettingsNote("Last sent: \(lastSentVideo)")
        }
    }

    @ViewBuilder
    private var videoCompressionAndColorSection: some View {
        cameraSettingsSectionTitle("Compression")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "H.264",
                selected: currentCompressionValue == "H.264",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setVideoCompression(.h264Compatibility)
                lastSentCompression = "H.264"
            }
            CameraSettingChoiceButton(
                title: "HEVC",
                selected: currentCompressionValue == "HEVC",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setVideoCompression(.hevcEfficiency)
                lastSentCompression = "HEVC"
            }
        }

        cameraSettingsSectionTitle("Color Profile")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Normal",
                selected: currentColorValue == "Normal",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setColorProfile(.normal)
                lastSentColor = "Normal"
            }
            CameraSettingChoiceButton(
                title: "HLG",
                selected: currentColorValue == "HLG",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setColorProfile(.hlg)
                lastSentColor = "HLG"
            }
            CameraSettingChoiceButton(
                title: "D-Log M",
                selected: currentColorValue == "D-Log M",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setColorProfile(.dLogM)
                lastSentColor = "D-Log M"
            }
        }
    }

    @ViewBuilder
    private var lowLightSettingsSection: some View {
        cameraSettingsSectionTitle("Low-Light Video")
        cameraSettingsNote("Low-Light mode confirmed from live 02/80 readback. Choose both fields, then Apply.")

        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "1080p",
                selected: draftLowLightResolution == .p1080,
                enabled: gimbal.isConnected
            ) {
                draftLowLightResolution = .p1080
            }
            CameraSettingChoiceButton(
                title: "4K",
                selected: draftLowLightResolution == .p4K,
                enabled: gimbal.isConnected
            ) {
                draftLowLightResolution = .p4K
            }
        }

        HStack(spacing: 7) {
            lowLightFrameRateButton("24", .fps24)
            lowLightFrameRateButton("25", .fps25)
            lowLightFrameRateButton("30", .fps30)
        }

        CameraSettingChoiceButton(
            title: draftLowLightApplyTitle,
            selected: false,
            enabled: gimbal.isConnected && draftLowLightResolution != nil && draftLowLightFrameRate != nil
        ) {
            applyDraftLowLightFormat()
        }

        if lastSentLowLight != "—" {
            cameraSettingsNote("Last sent: \(lastSentLowLight)")
        }
    }

    @ViewBuilder
    private var slowMotionSettingsSection: some View {
        cameraSettingsSectionTitle("Slow Motion")
        cameraSettingsNote("Slow Motion mode confirmed from live 02/80 readback. Exact captured presets only.")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 7)], spacing: 7) {
            slowMotionPresetButton("4K / 120 / 4×", .p4K, .fps120, .x4, "4K/120/4x")
            slowMotionPresetButton("2.7K / 120 / 4×", .p2_7K, .fps120, .x4, "2.7K/120/4x")
            slowMotionPresetButton("1080 / 120 / 4×", .p1080, .fps120, .x4, "1080/120/4x")
            slowMotionPresetButton("1080 / 240 / 8×", .p1080, .fps240, .x8, "1080/240/8x")
        }
    }

    @ViewBuilder
    private var whiteBalanceSettingsSection: some View {
        cameraSettingsSectionTitle("White Balance")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Auto",
                selected: currentWhiteBalanceValue == "AUTO",
                enabled: gimbal.isConnected
            ) {
                sendWhiteBalance(.auto, label: "AUTO")
            }
            CameraSettingChoiceButton(
                title: "5600 K",
                selected: currentWhiteBalanceValue == "5600K",
                enabled: gimbal.isConnected
            ) {
                draftKelvin = 5600
                sendWhiteBalance(.customKelvin(5600), label: "5600K")
            }
        }

        HStack {
            Text("Custom")
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            Text("\(Int(draftKelvin)) K")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        Slider(value: $draftKelvin, in: 2000...10_000, step: 100)
            .disabled(!gimbal.isConnected)
        CameraSettingChoiceButton(
            title: "Send \(Int(draftKelvin)) K",
            selected: currentWhiteBalanceValue == "\(Int(draftKelvin))K",
            enabled: gimbal.isConnected
        ) {
            let kelvin = Int(draftKelvin)
            sendWhiteBalance(.customKelvin(kelvin), label: "\(kelvin)K")
        }
    }

    @ViewBuilder
    private var exposureSettingsSection: some View {
        cameraSettingsSectionTitle("Exposure Mode")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Auto",
                selected: currentExposureModeValue == "AUTO",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setExposureMode(.auto)
                lastSentExposureMode = "AUTO"
            }
            CameraSettingChoiceButton(
                title: "Manual",
                selected: currentExposureModeValue == "MANUAL",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setExposureMode(.manual)
                lastSentExposureMode = "MANUAL"
            }
        }

        cameraSettingsSectionTitle("Manual ISO")
        cameraSettingsNote("Complete Pocket 3 Mimo ISO menu captured in C3-ISO-full.")
        if let effectiveISO = cameraReadback.effectiveISO {
            cameraSettingsNote("Camera effective ISO: \(effectiveISO)")
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 7)], spacing: 7) {
            ForEach(Pocket3CameraSettings.ManualISO.allCases, id: \.rawValue) { iso in
                isoButton(iso.displayName, iso, iso == .auto ? "AUTO" : iso.displayName)
            }
        }

        if currentExposureModeValue == "MANUAL" {
            if let shutters = availableManualShutters {
                cameraSettingsSectionTitle("Manual Shutter")
                if currentShootingMode == .video,
                   let fps = cameraReadback.videoFrameRate {
                    cameraSettingsNote(
                        "Video shutter follows Mimo's frame-rate minimum for \(frameRateLabel(fps)) fps. Shutter write readback is not decoded yet."
                    )
                } else {
                    cameraSettingsNote("Complete Photo shutter menu captured in C3-SHUTTER-photo-full. Shutter write readback is not decoded yet.")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 7)], spacing: 7) {
                    ForEach(shutters, id: \.self) { shutter in
                        shutterButton(shutter)
                    }
                }
            } else {
                cameraSettingsNote("Manual shutter is exposed only for capture-confirmed Photo and normal Video menu states.")
            }
        }

        cameraSettingsSectionTitle("Auto EV Compensation")
        HStack {
            Text("-3 EV")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Text(evLabel(thirdStops: Int(draftEVThirdStops)))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Spacer()
            Text("+3 EV")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        Slider(value: $draftEVThirdStops, in: -9...9, step: 1)
            .disabled(!gimbal.isConnected)
        CameraSettingChoiceButton(
            title: "Send \(evLabel(thirdStops: Int(draftEVThirdStops)))",
            selected: currentEVValue == evLabel(thirdStops: Int(draftEVThirdStops)),
            enabled: gimbal.isConnected
        ) {
            let thirdStops = Int(draftEVThirdStops)
            sendEV(thirdStops: thirdStops, label: evLabel(thirdStops: thirdStops))
        }

        cameraSettingsSectionTitle("ISO MAX")
        cameraSettingsNote("Complete Pocket 3 Mimo ISO MAX menu captured in C3-ISO-MAX. Write readback is not decoded yet.")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 7)], spacing: 7) {
            ForEach(Pocket3CameraSettings.ISOMax.allCases, id: \.rawValue) { isoMax in
                isoMaxButton(isoMax)
            }
        }
    }

    @ViewBuilder
    private var focusSettingsSection: some View {
        cameraSettingsSectionTitle("Focus")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Single AF",
                selected: currentFocusValue == "S-AF",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setFocusMode(.single)
                lastSentFocus = "S-AF"
            }
            CameraSettingChoiceButton(
                title: "Continuous AF",
                selected: currentFocusValue == "C-AF",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setFocusMode(.continuous)
                lastSentFocus = "C-AF"
            }
        }

        cameraSettingsSectionTitle("Product Showcase")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Off",
                selected: lastSentProductShowcase == "OFF",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setProductShowcaseEnabled(false)
                lastSentProductShowcase = "OFF"
            }
            CameraSettingChoiceButton(
                title: "On",
                selected: lastSentProductShowcase == "ON",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setProductShowcaseEnabled(true)
                lastSentProductShowcase = "ON"
            }
        }
    }

    @ViewBuilder
    private var proSettingsSection: some View {
        cameraSettingsSectionTitle("Pro")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Off",
                selected: lastSentPro == "OFF",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setProEnabled(false)
                lastSentPro = "OFF"
            }
            CameraSettingChoiceButton(
                title: "On",
                selected: lastSentPro == "ON",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setProEnabled(true)
                lastSentPro = "ON"
            }
        }
    }

    @ViewBuilder
    private var photoSettingsSection: some View {
        cameraSettingsSectionTitle("Photo")
        cameraSettingsNote("Photo mode confirmed from live 02/80 readback.")

        Text("Frame")
            .font(.system(size: 10, weight: .semibold))
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "16:9",
                selected: currentPhotoFrameValue == "16:9",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPhotoFrame(.sixteenByNine)
                lastSentPhotoFrame = "16:9"
            }
            CameraSettingChoiceButton(
                title: "1:1",
                selected: currentPhotoFrameValue == "1:1",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPhotoFrame(.oneByOne)
                lastSentPhotoFrame = "1:1"
            }
        }

        Text("Format")
            .font(.system(size: 10, weight: .semibold))
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "JPEG",
                selected: currentPhotoFormatValue == "JPEG",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPhotoFormat(.jpeg)
                lastSentPhotoFormat = "JPEG"
            }
            CameraSettingChoiceButton(
                title: "JPEG + RAW",
                selected: currentPhotoFormatValue == "JPEG+RAW",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPhotoFormat(.jpegAndRaw)
                lastSentPhotoFormat = "JPEG+RAW"
            }
        }

        Text("Countdown")
            .font(.system(size: 10, weight: .semibold))
        HStack(spacing: 7) {
            photoCountdownButton("Off", .off, "OFF")
            photoCountdownButton("3s", .seconds3, "3s")
            photoCountdownButton("5s", .seconds5, "5s")
            photoCountdownButton("7s", .seconds7, "7s")
        }
    }

    @ViewBuilder
    private var timelapseSettingsSection: some View {
        cameraSettingsSectionTitle("Timelapse")
        cameraSettingsNote("Stationary Timelapse. Interval/duration/output state use live Pocket readback. C3 captures cover the complete Mimo interval and duration menus.")

        if let interval = cameraReadback.timelapseIntervalTenths,
           let duration = cameraReadback.timelapseDurationSeconds,
           let output = cameraReadback.timelapseOutput {
            cameraSettingsNote(
                "Camera: \(timelapseIntervalLabel(interval)) / \(timelapseDurationLabel(duration)) / \(timelapseOutputLabel(output))"
            )
        }

        Text("Interval")
            .font(.system(size: 10, weight: .semibold))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 7)], spacing: 7) {
            timelapseIntervalButton("0.5s", 5)
            timelapseIntervalButton("1s", 10)
            timelapseIntervalButton("2s", 20)
            timelapseIntervalButton("3s", 30)
            timelapseIntervalButton("4s", 40)
            timelapseIntervalButton("5s", 50)
            timelapseIntervalButton("6s", 60)
            timelapseIntervalButton("8s", 80)
            timelapseIntervalButton("10s", 100)
            timelapseIntervalButton("15s", 150)
            timelapseIntervalButton("20s", 200)
            timelapseIntervalButton("25s", 250)
            timelapseIntervalButton("30s", 300)
            timelapseIntervalButton("40s", 400)
            timelapseIntervalButton("1m", 600)
        }

        Text("Duration")
            .font(.system(size: 10, weight: .semibold))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 7)], spacing: 7) {
            timelapseDurationButton("∞", 0)
            timelapseDurationButton("5m", 300)
            timelapseDurationButton("10m", 600)
            timelapseDurationButton("20m", 1_200)
            timelapseDurationButton("30m", 1_800)
            timelapseDurationButton("1h", 3_600)
            timelapseDurationButton("2h", 7_200)
            timelapseDurationButton("3h", 10_800)
            timelapseDurationButton("5h", 18_000)
        }

        Text("Output")
            .font(.system(size: 10, weight: .semibold))
        HStack(spacing: 7) {
            timelapseOutputButton("Video", .video)
            timelapseOutputButton("JPEG + Video", .jpegAndVideo)
            timelapseOutputButton("RAW + Video", .rawAndVideo)
        }

        CameraSettingChoiceButton(
            title: "Apply Timelapse",
            selected: false,
            enabled: canApplyTimelapse
        ) {
            guard let interval = selectedTimelapseIntervalTenths,
                  let duration = selectedTimelapseDurationSeconds,
                  let output = selectedTimelapseOutput else { return }

            let configuration = Pocket3CameraSettings.TimelapseConfiguration(
                intervalTenths: interval,
                durationSeconds: duration,
                output: output
            )
            gimbal.camera.setTimelapse(configuration)
            lastSentTimelapse = timelapseSelectionSummary

            // Return selection ownership to camera readback after sending.
            // This keeps the UI honest if the Pocket rejects or adjusts a request.
            draftTimelapseIntervalTenths = nil
            draftTimelapseDurationSeconds = nil
            draftTimelapseOutput = nil
        }
        if lastSentTimelapse != "—" {
            cameraSettingsNote("Last sent: \(lastSentTimelapse)")
        }
    }

    @ViewBuilder
    private var motionlapseSettingsSection: some View {
        cameraSettingsSectionTitle("Motionlapse")
        cameraSettingsNote("Moving Motionlapse is mode 0x18. PID 0x0037 selects L → R, R → L, or Custom. Stationary lapse is ordinary Timelapse, not a fourth Motionlapse direction.")

        Text("Motion Path")
            .font(.system(size: 10, weight: .semibold))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 7)], spacing: 7) {
            motionlapseDirectionButton("L → R", .leftToRight)
            motionlapseDirectionButton("R → L", .rightToLeft)
            motionlapseDirectionButton("Custom", .custom)
        }

        CameraSettingChoiceButton(
            title: "Return to Timelapse",
            selected: false,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setShootingMode(.timelapse)
        }

        if let direction = cameraReadback.motionlapseDirection {
            if direction == .custom, let count = cameraReadback.motionlapseWaypointCount {
                cameraSettingsNote(
                    "Camera motion: \(motionlapseDirectionLabel(direction)) • \(count) waypoint\(count == 1 ? "" : "s")"
                )
                motionlapseCustomWaypointSection(savedCount: Int(count))
            } else {
                cameraSettingsNote("Camera motion: \(motionlapseDirectionLabel(direction))")
            }
        }

        if let interval = cameraReadback.timelapseIntervalTenths,
           let duration = cameraReadback.timelapseDurationSeconds,
           let output = cameraReadback.timelapseOutput {
            cameraSettingsNote(
                "Lapse state: \(timelapseIntervalLabel(interval)) / \(timelapseDurationLabel(duration)) / \(timelapseOutputLabel(output))"
            )
        }

        cameraSettingsNote("Custom point writes and reverse-order deletion are hardware-confirmed through 4 points. Preview uses capture-confirmed PID 0x0036 and reports live Preview activity through cam_motionlapse_params.")
    }

    @ViewBuilder
    private func motionlapseCustomWaypointSection(savedCount: Int) -> some View {
        Text("Custom Waypoints")
            .font(.system(size: 10, weight: .semibold))

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 7)], spacing: 7) {
            motionlapseWaypointButton(point: 1, savedCount: savedCount)
            motionlapseWaypointButton(point: 2, savedCount: savedCount)
            motionlapseWaypointButton(point: 3, savedCount: savedCount)
            motionlapseWaypointButton(point: 4, savedCount: savedCount)
        }

        if savedCount >= 2 {
            CameraSettingChoiceButton(
                title: cameraReadback.motionlapsePreviewActive == true ? "Previewing…" : "Preview Path",
                selected: cameraReadback.motionlapsePreviewActive == true,
                enabled: gimbal.isConnected
                    && currentShootingMode == .motionlapse
                    && cameraReadback.motionlapseDirection == .custom
                    && cameraReadback.motionlapsePreviewActive != true
            ) {
                gimbal.camera.previewMotionlapse()
            }
        }

        if savedCount > 0 {
            CameraSettingChoiceButton(
                title: "Delete Point \(savedCount)",
                selected: false,
                enabled: gimbal.isConnected
                    && currentShootingMode == .motionlapse
                    && cameraReadback.motionlapseDirection == .custom
                    && cameraReadback.timelapseIntervalTenths != nil
                    && cameraReadback.timelapseDurationSeconds != nil
                    && cameraReadback.motionlapsePreviewActive != true
            ) {
                deleteLastMotionlapseWaypoint(savedCount: savedCount)
            }
        }

        if lastMotionlapseWaypointAction != "—" {
            cameraSettingsNote(lastMotionlapseWaypointAction)
        }
    }

    @ViewBuilder
    private var hyperlapseSettingsSection: some View {
        cameraSettingsSectionTitle("Hyperlapse Format")
        cameraSettingsNote("Resolution/FPS and speed now follow live Pocket readback. This temporary UI exposes only the exact Hyperlapse format pairs captured in C2-HYP-010.")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 7)], spacing: 7) {
            hyperlapseFormatButton("1080p / 25", .p1080, .fps25)
            hyperlapseFormatButton("2.7K / 30", .p2_7K, .fps30)
            hyperlapseFormatButton("4K / 30", .p4K, .fps30)
        }

        cameraSettingsSectionTitle("Hyperlapse Speed")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 7)], spacing: 7) {
            hyperlapseButton("Auto", .auto)
            hyperlapseButton("2×", .x2)
            hyperlapseButton("5×", .x5)
            hyperlapseButton("10×", .x10)
            hyperlapseButton("15×", .x15)
            hyperlapseButton("30×", .x30)
        }
    }

    @ViewBuilder
    private var panoramaSettingsSection: some View {
        cameraSettingsSectionTitle("Panorama")
        cameraSettingsNote("Panorama type and photo format follow live cam_pano_params readback. Start uses the capture-confirmed 02/01 07 command for both 180° and 3×3.")

        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "180°",
                selected: cameraReadback.panoramaType == .degrees180,
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPanoramaType(.degrees180)
            }
            CameraSettingChoiceButton(
                title: "3×3",
                selected: cameraReadback.panoramaType == .grid3x3,
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPanoramaType(.grid3x3)
            }
        }

        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "JPEG",
                selected: cameraReadback.panoramaPhotoFormat == .jpeg,
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPanoramaPhotoFormat(.jpeg)
            }
            CameraSettingChoiceButton(
                title: "RAW",
                selected: cameraReadback.panoramaPhotoFormat == .raw,
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setPanoramaPhotoFormat(.raw)
            }
        }

        CameraSettingChoiceButton(
            title: "Start Panorama",
            selected: false,
            enabled: gimbal.isConnected
                && currentShootingMode == .panorama
                && cameraReadback.panoramaType != nil
                && cameraReadback.panoramaPhotoFormat != nil
        ) {
            gimbal.camera.shootPanorama()
        }
    }

    @ViewBuilder
    private var audioSettingsSection: some View {
        cameraSettingsSectionTitle("Audio Channel")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Mono",
                selected: lastSentAudioChannel == "MONO",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setAudioChannel(.mono)
                lastSentAudioChannel = "MONO"
            }
            CameraSettingChoiceButton(
                title: "Stereo",
                selected: lastSentAudioChannel == "STEREO",
                enabled: gimbal.isConnected
            ) {
                gimbal.camera.setAudioChannel(.stereo)
                lastSentAudioChannel = "STEREO"
            }
        }
        cameraSettingsNote("Wind Noise Reduction and Directional Audio are withheld pending cleanup captures of the structured 02/9F payload.")
    }

    @ViewBuilder
    private var cameraFacingAndRecenterSection: some View {
        cameraSettingsSectionTitle("Gimbal / Camera")
        HStack(spacing: 7) {
            CameraSettingChoiceButton(
                title: "Recenter",
                selected: false,
                enabled: gimbal.isConnected
            ) {
                releaseAllTouchControl()
                headTracking.prepareForRecenterAutoResume(reason: "Camera settings recenter")
                gimbal.recenter()
            }
            CameraSettingChoiceButton(
                title: "Selfie / Forward",
                selected: false,
                enabled: gimbal.isConnected
            ) {
                releaseAllTouchControl()
                gimbal.toggleSelfieFacing()
            }
        }
    }

    @ViewBuilder
    private var withheldSettingsSection: some View {
        cameraSettingsSectionTitle("Still Withheld")
        cameraSettingsNote("Still withheld: shooting-mode setters outside the confirmed Timelapse/Motionlapse paths, beauty sliders, wind/directional audio, and Follow / Tilt Locked / FPV mode selection. RTMP and media management remain out of this settings UI.")
    }

    private func videoResolutionButton(
        _ title: String,
        _ resolution: Pocket3CameraSettings.VideoResolution
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: selectedVideoResolution == resolution,
            enabled: gimbal.isConnected
        ) {
            draftVideoResolution = resolution
        }
    }

    private func videoFrameRateButton(
        _ title: String,
        _ frameRate: Pocket3CameraSettings.FrameRate
    ) -> some View {
        CameraSettingChoiceButton(
            title: "\(title) fps",
            selected: selectedVideoFrameRate == frameRate,
            enabled: gimbal.isConnected
        ) {
            draftVideoFrameRate = frameRate
        }
    }

    private func lowLightFrameRateButton(
        _ title: String,
        _ frameRate: Pocket3CameraSettings.FrameRate
    ) -> some View {
        CameraSettingChoiceButton(
            title: "\(title) fps",
            selected: draftLowLightFrameRate == frameRate,
            enabled: gimbal.isConnected
        ) {
            draftLowLightFrameRate = frameRate
        }
    }

    private func slowMotionPresetButton(
        _ title: String,
        _ resolution: Pocket3CameraSettings.VideoResolution,
        _ frameRate: Pocket3CameraSettings.FrameRate,
        _ multiplier: Pocket3CameraSettings.SlowMotionMultiplier,
        _ label: String
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: lastSentSlowMotion == label,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setVideoFormat(
                resolution: resolution,
                frameRate: frameRate,
                slowMotionMultiplier: multiplier
            )
            lastSentSlowMotion = label
        }
    }

    private func isoButton(
        _ title: String,
        _ iso: Pocket3CameraSettings.ManualISO,
        _ label: String
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: lastSentISO == label,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setManualISO(iso)
            lastSentISO = label
        }
    }

    private func isoMaxButton(_ isoMax: Pocket3CameraSettings.ISOMax) -> some View {
        CameraSettingChoiceButton(
            title: isoMax.displayName,
            selected: lastSentISOMax == isoMax.displayName,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setISOMax(isoMax)
            lastSentISOMax = isoMax.displayName
        }
    }


    private func shutterButton(_ shutter: Pocket3CameraSettings.ManualShutter) -> some View {
        CameraSettingChoiceButton(
            title: shutter.displayName,
            selected: lastSentShutter == shutter.displayName,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setManualShutter(shutter)
            lastSentShutter = shutter.displayName
        }
    }

    private var availableManualShutters: [Pocket3CameraSettings.ManualShutter]? {
        Pocket3CameraPolicy.manualShutters(
            shootingMode: currentShootingMode,
            videoFrameRate: cameraReadback.videoFrameRate
        )
    }


    private func photoCountdownButton(
        _ title: String,
        _ countdown: Pocket3CameraSettings.PhotoCountdown,
        _ label: String
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: currentPhotoCountdownValue == label,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setPhotoCountdown(countdown)
            lastSentPhotoCountdown = label
        }
    }

    private func motionlapseDirectionButton(
        _ title: String,
        _ direction: Pocket3CameraSettings.MotionlapseDirection
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: currentShootingMode == .motionlapse
                && cameraReadback.motionlapseDirection == direction,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setMotionlapseDirection(direction, currentMode: currentShootingMode)
        }
    }

    private func motionlapseWaypointButton(point: Int, savedCount: Int) -> some View {
        let alreadySaved = savedCount >= point
        let isNextPoint = savedCount == point - 1

        return CameraSettingChoiceButton(
            title: alreadySaved ? "Point \(point) Saved" : "Set Point \(point)",
            selected: alreadySaved,
            enabled: gimbal.isConnected
                && currentShootingMode == .motionlapse
                && cameraReadback.motionlapseDirection == .custom
                && isNextPoint
                && cameraReadback.timelapseIntervalTenths != nil
                && cameraReadback.timelapseDurationSeconds != nil
        ) {
            setCurrentMotionlapseWaypoint(point: point)
        }
    }

    private func setCurrentMotionlapseWaypoint(point: Int) {
        guard let slot = Pocket3CameraSettings.MotionlapseWaypointSlot(pointNumber: point),
              let interval = cameraReadback.timelapseIntervalTenths,
              let duration = cameraReadback.timelapseDurationSeconds else {
            lastMotionlapseWaypointAction = "Waypoint not sent: waiting for live Motionlapse state."
            return
        }

        guard let telemetry = gimbal.latestTelemetrySnapshot(maxAgeMs: 350),
              let pitch = motionlapseTenths(telemetry.pitchDeg),
              let roll = motionlapseTenths(telemetry.rollDeg),
              let yaw = motionlapseTenths(telemetry.yawDeg) else {
            lastMotionlapseWaypointAction = "Waypoint not sent: fresh 04/05 gimbal telemetry is unavailable."
            return
        }

        gimbal.camera.setMotionlapseWaypoint(
            slot: slot,
            intervalTenths: interval,
            durationSeconds: duration,
            pitchTenths: pitch,
            rollTenths: roll,
            yawTenths: yaw
        )

        lastMotionlapseWaypointAction = String(
            format: "Point %d sent: pitch %+.1f° / roll %+.1f° / yaw %+.1f° — waiting for Pocket readback.",
            point,
            telemetry.pitchDeg,
            telemetry.rollDeg,
            telemetry.yawDeg
        )
    }

    private func deleteLastMotionlapseWaypoint(savedCount: Int) {
        guard let slot = Pocket3CameraSettings.MotionlapseWaypointSlot(pointNumber: savedCount),
              let interval = cameraReadback.timelapseIntervalTenths,
              let duration = cameraReadback.timelapseDurationSeconds else {
            lastMotionlapseWaypointAction = "Waypoint delete not sent: waiting for live Motionlapse state."
            return
        }

        gimbal.camera.deleteMotionlapseWaypoint(
            slot: slot,
            intervalTenths: interval,
            durationSeconds: duration
        )
        lastMotionlapseWaypointAction = "Delete Point \(savedCount) sent — waiting for Pocket readback."
    }

    private func motionlapseTenths(_ degrees: Double) -> Int16? {
        let scaled = (degrees * 10.0).rounded()
        guard scaled >= Double(Int16.min), scaled <= Double(Int16.max) else { return nil }
        return Int16(scaled)
    }

    private func timelapseIntervalButton(_ title: String, _ value: UInt16) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: selectedTimelapseIntervalTenths == value,
            enabled: gimbal.isConnected
        ) {
            draftTimelapseIntervalTenths = value
        }
    }

    private func timelapseDurationButton(_ title: String, _ value: UInt32) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: selectedTimelapseDurationSeconds == value,
            enabled: gimbal.isConnected
        ) {
            draftTimelapseDurationSeconds = value
        }
    }

    private func timelapseOutputButton(
        _ title: String,
        _ output: Pocket3CameraSettings.TimelapseOutput
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: selectedTimelapseOutput == output,
            enabled: gimbal.isConnected
        ) {
            draftTimelapseOutput = output
        }
    }

    private func hyperlapseFormatButton(
        _ title: String,
        _ resolution: Pocket3CameraSettings.VideoResolution,
        _ frameRate: Pocket3CameraSettings.FrameRate
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: cameraReadback.videoResolution == resolution
                && cameraReadback.videoFrameRate == frameRate,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setVideoFormat(resolution: resolution, frameRate: frameRate)
        }
    }

    private func hyperlapseButton(
        _ title: String,
        _ speed: Pocket3CameraSettings.HyperlapseSpeed
    ) -> some View {
        CameraSettingChoiceButton(
            title: title,
            selected: cameraReadback.hyperlapseSpeed == speed,
            enabled: gimbal.isConnected
        ) {
            gimbal.camera.setHyperlapseSpeed(speed)
        }
    }

    private var canApplySelectedVideoFormat: Bool {
        guard gimbal.isConnected,
              let aspect = cameraReadback.sensorAspectRatio,
              let resolution = selectedVideoResolution,
              selectedVideoFrameRate != nil else {
            return false
        }

        return Pocket3CameraPolicy.videoFormatSupported(
            resolution: resolution,
            sensorAspectRatio: aspect
        )
    }

    private var draftVideoFormatApplyTitle: String {
        guard let resolution = selectedVideoResolution, let frameRate = selectedVideoFrameRate else {
            return "Choose Resolution + FPS"
        }
        return "Apply \(videoResolutionLabel(resolution)) / \(frameRateLabel(frameRate))"
    }

    private var draftLowLightApplyTitle: String {
        guard let resolution = draftLowLightResolution, let frameRate = draftLowLightFrameRate else {
            return "Choose Resolution + FPS"
        }
        return "Apply \(videoResolutionLabel(resolution)) / \(frameRateLabel(frameRate))"
    }

    private var canApplyTimelapse: Bool {
        gimbal.isConnected
            && selectedTimelapseIntervalTenths != nil
            && selectedTimelapseDurationSeconds != nil
            && selectedTimelapseOutput != nil
    }

    private var timelapseSelectionSummary: String {
        guard let interval = selectedTimelapseIntervalTenths,
              let duration = selectedTimelapseDurationSeconds,
              let output = selectedTimelapseOutput else {
            return "—"
        }
        return "\(timelapseIntervalLabel(interval)) / \(timelapseDurationLabel(duration)) / \(timelapseOutputLabel(output))"
    }

    private func applyDraftVideoFormat() {
        guard canApplySelectedVideoFormat,
              let resolution = selectedVideoResolution,
              let frameRate = selectedVideoFrameRate else { return }
        gimbal.camera.setVideoFormat(resolution: resolution, frameRate: frameRate)
        lastSentVideo = "\(videoResolutionLabel(resolution))/\(frameRateLabel(frameRate))"
    }

    private func applyDraftLowLightFormat() {
        guard let resolution = draftLowLightResolution, let frameRate = draftLowLightFrameRate else { return }
        gimbal.camera.setVideoFormat(resolution: resolution, frameRate: frameRate)
        lastSentLowLight = "\(videoResolutionLabel(resolution))/\(frameRateLabel(frameRate))"
    }

    private func sendWhiteBalance(_ whiteBalance: Pocket3CameraSettings.WhiteBalance, label: String) {
        guard gimbal.camera.setWhiteBalance(whiteBalance) else { return }
        lastSentWhiteBalance = label
    }

    private func sendEV(thirdStops: Int, label: String) {
        guard gimbal.camera.setAutoEV(thirdStops: thirdStops) else { return }
        lastSentEV = label
    }

    private func videoResolutionLabel(_ resolution: Pocket3CameraSettings.VideoResolution) -> String {
        switch resolution {
        case .p1080: return "1080p"
        case .p2_7K: return "2.7K"
        case .p4K: return "4K"
        case .portrait1080: return "9:16 1080"
        case .portrait2_7K: return "9:16 2.7K"
        case .square1080: return "1:1 1080"
        case .square2160: return "1:1 2160"
        case .square3K: return "1:1 3K"
        case .portrait3K: return "9:16 3K"
        }
    }

    private func frameRateLabel(_ frameRate: Pocket3CameraSettings.FrameRate) -> String {
        switch frameRate {
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps30: return "30"
        case .fps48: return "48"
        case .fps50: return "50"
        case .fps60: return "60"
        case .fps120: return "120"
        case .fps240: return "240"
        }
    }

    private func evLabel(thirdStops: Int) -> String {
        let ev = Double(thirdStops) / 3.0
        if thirdStops > 0 {
            return String(format: "+%.1f EV", ev)
        }
        return String(format: "%.1f EV", ev)
    }

    private func motionlapseDirectionLabel(_ direction: Pocket3CameraSettings.MotionlapseDirection) -> String {
        switch direction {
        case .custom: return "Custom"
        case .leftToRight: return "L → R"
        case .rightToLeft: return "R → L"
        }
    }

    private func timelapseIntervalLabel(_ value: UInt16) -> String {
        switch value {
        case 5: return "0.5s"
        case 10: return "1s"
        case 100: return "10s"
        case 600: return "60s"
        default: return "\(value) tenths"
        }
    }

    private func timelapseDurationLabel(_ value: UInt32) -> String {
        switch value {
        case 0: return "∞"
        case 300: return "5m"
        case 600: return "10m"
        case 3600: return "1h"
        case 18_000: return "5h"
        default: return "\(value)s"
        }
    }

    private func timelapseOutputLabel(_ output: Pocket3CameraSettings.TimelapseOutput) -> String {
        switch output {
        case .video: return "Video"
        case .jpegAndVideo: return "JPEG+Video"
        case .rawAndVideo: return "RAW+Video"
        }
    }

    private func clearLastSentCameraSettings() {
        lastSentVideo = "—"
        lastSentWhiteBalance = "—"
        lastSentEV = "—"
        lastSentFocus = "—"
        lastSentPro = "—"
        lastSentCompression = "—"
        lastSentExposureMode = "—"
        lastSentISO = "—"
        lastSentISOMax = "—"
        lastSentShutter = "—"
        lastSentColor = "—"
        lastSentProductShowcase = "—"
        lastSentLowLight = "—"
        lastSentSlowMotion = "—"
        lastSentPhotoFrame = "—"
        lastSentPhotoFormat = "—"
        lastSentPhotoCountdown = "—"
        lastSentTimelapse = "—"
        lastSentAudioChannel = "—"
    }

    // MARK: - Touch arbitration / command mapping

    private func updateCombinedTouch(yaw: Double, pitch: Double, active: Bool) {
        touchYaw = active ? yaw : 0
        touchPitch = active ? pitch : 0
        yawTouchActive = active
        pitchTouchActive = active
        publishTouchControl()
    }

    private func updateYawTouch(value: Double, active: Bool) {
        touchYaw = active ? value : 0
        yawTouchActive = active
        publishTouchControl()
    }

    private func updatePitchTouch(value: Double, active: Bool) {
        touchPitch = active ? value : 0
        pitchTouchActive = active
        publishTouchControl()
    }

    private func publishTouchControl() {
        let active = yawTouchActive || pitchTouchActive
        gamepad.noteTouchInput(active: active)

        if active {
            headTracking.setManualOverride(.touch, active: true)
            let mapped = JoystickMapper.map(
                normalizedX: CGFloat(touchYaw),
                // JoystickMapper follows UIKit Y-positive-down coordinates.
                normalizedY: CGFloat(-touchPitch),
                mode: preferences.responseMode
            )
            gimbal.setJoystick(pitch: mapped.pitch, yaw: mapped.yaw)
        } else {
            if gamepad.lastInputSource == .touch {
                gimbal.releaseJoystick()
            }
            headTracking.setManualOverride(.touch, active: false)
        }
    }

    private func releaseAllTouchControl() {
        touchYaw = 0
        touchPitch = 0
        yawTouchActive = false
        pitchTouchActive = false
        gamepad.noteTouchInput(active: false)
        if gamepad.lastInputSource == .touch {
            gimbal.releaseJoystick()
        }
        headTracking.setManualOverride(.touch, active: false)
    }

    private var recordButtonEnabled: Bool {
        gimbal.isConnected && cameraState.canToggleRecording
    }

    private var primaryCaptureButtonEnabled: Bool {
        if currentShootingMode == .photo {
            return gimbal.isConnected
        }
        return recordButtonEnabled
    }

    private func performPrimaryCaptureAction() {
        if currentShootingMode == .photo {
            gimbal.camera.shootPhoto()
            return
        }
        toggleCameraRecording()
    }

    private func toggleCameraRecording() {
        guard let recording = cameraState.recording,
              cameraState.canToggleRecording else { return }
        gimbal.camera.setRecording(!recording)
    }
}

// MARK: - Layout model

private enum TouchJoystickLayout: String, CaseIterable, Identifiable {
    case left
    case right
    case dual

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .dual: "Dual"
        }
    }
}

// MARK: - Status / placeholder preview

private struct CameraTopStatusBar: View {
    let portrait: Bool
    let formatDescriptor: String
    @ObservedObject var gimbal: Pocket3GimbalSession
    @ObservedObject var preferences: ControllerPreferences
    @ObservedObject var gamepad: GameControllerManager
    @ObservedObject var headTracking: HeadTrackingManager
    let connectedCameraDisplayName: String?
    let onOpenCameraConnections: () -> Void

    var body: some View {
        Group {
            if portrait {
                VStack(spacing: 7) {
                    HStack(spacing: 12) {
                        connectionButton
                        Spacer(minLength: 8)
                        formatStatus
                    }
                    HStack(spacing: 12) {
                        inputStatus
                        responseStatus
                        Spacer(minLength: 8)
                        mediaStatus
                    }
                }
            } else {
                HStack(spacing: 16) {
                    connectionButton
                    formatStatus
                    Spacer()
                    inputStatus
                    Spacer()
                    responseStatus
                    mediaStatus
                }
            }
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // Keep the status card width stable when transient content such as
        // the REC elapsed-time label appears or disappears. Without this,
        // the card's intrinsic width changes and can recenter the surrounding
        // portrait control stack by a few points.
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var connectionButton: some View {
        let presentation = CameraConnectionPresentation.make(
            isConnected: gimbal.isConnected,
            connectedCameraDisplayName: connectedCameraDisplayName
        )
        return Button(action: onOpenCameraConnections) {
            HStack(spacing: 8) {
                Circle()
                    .fill(gimbal.isConnected ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(presentation.topLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            gimbal.isConnected
                ? "\(presentation.topLabel) connected. Open cameras."
                : "Cameras. No camera connected."
        )
    }

    @ViewBuilder
    private var inputStatus: some View {
        if headTracking.isEnabled && headTracking.isCentered && !headTracking.isManualOverrideActive {
            Label("Head", systemImage: "airpodspro")
                .fixedSize()
        } else if gamepad.isConnected && gamepad.lastInputSource == .gamepad {
            Label("Gamepad", systemImage: "gamecontroller.fill")
                .fixedSize()
        } else {
            Label("Touch", systemImage: "hand.tap.fill")
                .fixedSize()
        }
    }

    private var formatStatus: some View {
        Text(formatDescriptor)
            .font(.system(size: portrait ? 10 : 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08), in: Capsule())
            .accessibilityLabel("Camera format \(formatDescriptor)")
    }

    private var responseStatus: some View {
        Text(preferences.responseMode == .linear ? "LINEAR" : "PROGRESSIVE")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    @ViewBuilder
    private var mediaStatus: some View {
        if gimbal.isConnected {
            HStack(spacing: portrait ? 10 : 14) {
                if let batteryPercent = gimbal.cameraBatteryPercent {
                    HStack(spacing: 3) {
                        Image(systemName: "battery.100")
                        Text("\(batteryPercent)%")
                        if gimbal.cameraBatteryCharging == true {
                            Image(systemName: "bolt.fill")
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        gimbal.cameraBatteryCharging == true
                            ? "Camera battery \(batteryPercent) percent, charging"
                            : "Camera battery \(batteryPercent) percent"
                    )
                }

                if let freeMiB = gimbal.cameraState.storageFreeMiB {
                    Text("SD \(storageFreeText(freeMiB))")
                        .accessibilityLabel("SD card \(storageFreeText(freeMiB)) free")
                }

                if let remaining = gimbal.cameraState.remainingRecordSeconds {
                    Label(remainingTimeText(remaining), systemImage: "clock")
                        .accessibilityLabel("Recording time remaining \(remainingTimeAccessibilityText(remaining))")
                }

                if gimbal.cameraState.recording == true,
                   let elapsed = gimbal.cameraState.elapsedRecordSeconds {
                    Label("REC \(elapsedTimeText(elapsed))", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Recording, elapsed \(elapsedTimeAccessibilityText(elapsed))")
                }
            }
            .font(.system(size: portrait ? 11 : 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            // Do not use fixedSize here. While recording, the REC timer adds
            // another label; fixedSize makes this HStack demand extra width and
            // can enlarge the parent layout. Allow the status row to compress
            // slightly instead while keeping every item on one line.
            .minimumScaleFactor(0.82)
        }
    }

    private func storageFreeText(_ freeMiB: UInt32) -> String {
        let decimalGB = Double(freeMiB) * 1_048_576.0 / 1_000_000_000.0
        return String(format: "%.1f GB", decimalGB)
    }

    private func remainingTimeText(_ seconds: UInt16) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func elapsedTimeText(_ seconds: UInt16) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func remainingTimeAccessibilityText(_ seconds: UInt16) -> String {
        let total = Int(seconds)
        return "\(total / 3600) hours \((total % 3600) / 60) minutes"
    }

    private func elapsedTimeAccessibilityText(_ seconds: UInt16) -> String {
        let total = Int(seconds)
        return "\(total / 3600) hours \((total % 3600) / 60) minutes \(total % 60) seconds"
    }

}

private struct CameraLivePreview: View {
    let output: Pocket3VideoOutput
    let isConnected: Bool
    let videoReceiving: Bool
    let aspectFill: Bool

    var body: some View {
        ZStack {
            Color.black

            Pocket3VideoPreviewView(output: output, aspectFill: aspectFill)

            if !videoReceiving {
                VStack(spacing: 5) {
                    Image(systemName: isConnected ? "video.fill" : "video.slash.fill")
                        .font(.title2)
                    Text(isConnected ? "STARTING DIRECT VIDEO" : "POCKET 3 NOT CONNECTED")
                        .font(.caption.weight(.semibold))
                    Text(isConnected ? "Waiting for capture-confirmed H.264 SPS / IDR" : "Connect to start direct preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.48), in: Capsule())
            }
        }
    }
}

private struct CameraGridOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let w = proxy.size.width
                let h = proxy.size.height
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: w * fraction, y: 0))
                    path.addLine(to: CGPoint(x: w * fraction, y: h))
                    path.move(to: CGPoint(x: 0, y: h * fraction))
                    path.addLine(to: CGPoint(x: w, y: h * fraction))
                }
            }
            .stroke(.white.opacity(0.18), lineWidth: 0.7)
        }
    }
}

// MARK: - Gimbal controls

private struct CameraHorizontalAxisJoystick: View {
    let label: LocalizedStringKey
    let enabled: Bool
    let onChange: (_ value: Double, _ active: Bool) -> Void
    @State private var value = 0.0

    private let travel: CGFloat = 42

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: 138, height: 50)
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.75))

                Rectangle()
                    .fill(.white.opacity(0.20))
                    .frame(width: 82, height: 1)

                Circle()
                    .fill(.thinMaterial)
                    .overlay(Circle().stroke(.white.opacity(0.78), lineWidth: 1))
                    .frame(width: 34, height: 34)
                    .offset(x: value * travel)
            }
            .frame(width: 150, height: 58)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        value = max(-1, min(1, gesture.translation.width / travel))
                        onChange(value, true)
                    }
                    .onEnded { _ in
                        value = 0
                        onChange(0, false)
                    }
            )
        }
        .opacity(enabled ? 1 : 0.42)
    }
}

private struct CameraVerticalAxisJoystick: View {
    let label: LocalizedStringKey
    let enabled: Bool
    let onChange: (_ value: Double, _ active: Bool) -> Void
    @State private var value = 0.0

    private let travel: CGFloat = 39

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: 50, height: 132)
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.75))

                Rectangle()
                    .fill(.white.opacity(0.20))
                    .frame(width: 1, height: 78)

                Circle()
                    .fill(.thinMaterial)
                    .overlay(Circle().stroke(.white.opacity(0.78), lineWidth: 1))
                    .frame(width: 34, height: 34)
                    .offset(y: -value * travel)
            }
            .frame(width: 58, height: 142)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        // Positive output means physical pitch-up.
                        value = max(-1, min(1, -gesture.translation.height / travel))
                        onChange(value, true)
                    }
                    .onEnded { _ in
                        value = 0
                        onChange(0, false)
                    }
            )
        }
        .opacity(enabled ? 1 : 0.42)
    }
}

private struct CameraCombinedJoystick: View {
    let label: LocalizedStringKey
    let enabled: Bool
    let onChange: (_ yaw: Double, _ pitch: Double, _ active: Bool) -> Void
    @State private var vector = CGSize.zero

    private let radius: CGFloat = 28

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 88, height: 88)
                    .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 0.75))

                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                    .frame(width: 58, height: 58)

                Circle()
                    .fill(.thinMaterial)
                    .overlay(Circle().stroke(.white.opacity(0.82), lineWidth: 1))
                    .frame(width: 34, height: 34)
                    .offset(vector)
            }
            .frame(width: 98, height: 98)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        let x = gesture.translation.width
                        let y = gesture.translation.height
                        let magnitude = max(1, (x * x + y * y).squareRoot())
                        let scale = min(1, radius / magnitude)
                        let clamped = CGSize(width: x * scale, height: y * scale)
                        vector = clamped
                        onChange(
                            Double(clamped.width / radius),
                            Double(-clamped.height / radius),
                            true
                        )
                    }
                    .onEnded { _ in
                        vector = .zero
                        onChange(0, 0, false)
                    }
            )
        }
        .opacity(enabled ? 1 : 0.42)
    }
}

// MARK: - Camera actions / layout picker

private struct CameraActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.75))

                Text(title)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: 48, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }
}

private struct CameraCaptureButton: View {
    let enabled: Bool
    let recording: Bool
    let transitioning: Bool
    let photoShutter: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.95), lineWidth: 3.2)
                    .frame(width: 58, height: 58)

                if photoShutter {
                    // A white still-photo shutter is intentionally distinct from the
                    // red video record control while retaining the same hit target/layout.
                    Circle()
                        .fill(.white)
                        .frame(width: 45, height: 45)
                } else if recording {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.red)
                        .frame(width: 31, height: 31)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 45, height: 45)
                }
            }
            .frame(width: 68, height: 68)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : (transitioning ? 0.75 : 0.55))
        .accessibilityLabel(
            photoShutter
                ? "Take Pocket 3 photo"
                : (recording ? "Stop Pocket 3 recording" : "Start Pocket 3 recording")
        )
    }
}

private struct CameraLayoutPicker: View {
    @Binding var selection: TouchJoystickLayout
    @Binding var show: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Joystick Layout")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    show = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(TouchJoystickLayout.allCases) { layout in
                Button {
                    selection = layout
                    show = false
                } label: {
                    HStack {
                        Image(systemName: symbol(for: layout))
                            .frame(width: 22)
                        Text(layout.title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: selection == layout ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            if selection == .dual {
                Text("Dual: yaw on the left, pitch on the right.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func symbol(for layout: TouchJoystickLayout) -> String {
        switch layout {
        case .left: "circle.grid.cross.left.filled"
        case .right: "circle.grid.cross.right.filled"
        case .dual: "rectangle.split.2x1"
        }
    }
}

// MARK: - Bottom camera strip

private struct CameraBottomControlBar: View {
    @Binding var showTools: Bool
    @Binding var showSettings: Bool
    @Binding var settingsDestination: CameraSettingsDestination
    let modeValue: String
    let videoValue: String
    let whiteBalanceValue: String
    let evValue: String
    let focusValue: String

    var body: some View {
        HStack(spacing: 0) {
            CameraControlItem(title: "MODE", value: modeValue, enabled: true) {
                openSettings(.video)
            }
            Divider().frame(height: 26)
            CameraControlItem(title: "WB", value: whiteBalanceValue, enabled: true) {
                openSettings(.whiteBalance)
            }
            Divider().frame(height: 26)
            CameraControlItem(title: "EV", value: evValue, enabled: true) {
                openSettings(.exposure)
            }
            Divider().frame(height: 26)
            CameraControlItem(title: "FOCUS", value: focusValue, enabled: true) {
                openSettings(.focus)
            }
            Divider().frame(height: 26)
            CameraControlItem(
                title: "CAMERA",
                value: "",
                enabled: true,
                systemImage: "camera.fill"
            ) {
                openSettings(.camera)
            }
            Divider().frame(height: 26)
            CameraControlItem(
                title: "TOOLS",
                value: "",
                enabled: true,
                systemImage: "slider.horizontal.3"
            ) {
                showTools.toggle()
                if showTools {
                    showSettings = false
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func openSettings(_ destination: CameraSettingsDestination) {
        if showSettings && settingsDestination == destination {
            showSettings = false
            return
        }

        settingsDestination = destination
        showSettings = true
        showTools = false
    }
}

private struct CameraSettingChoiceButton: View {
    let title: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                selected ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(selected ? 0.28 : 0.10), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }
}

private struct CameraControlItem: View {
    let title: LocalizedStringKey
    let value: String
    let enabled: Bool
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.48)
    }
}

#Preview("Camera Landscape") {
    CameraControlScreen(
        gimbal: Pocket3GimbalSession(),
        preferences: ControllerPreferences(),
        gamepad: GameControllerManager(),
        headTracking: HeadTrackingManager(),
        connectedCameraDisplayName: nil,
        onConnectCamera: {},
        onDisconnectCamera: {},
        onOpenLegacyDebug: {}
    )
    .frame(width: 852, height: 393)
}

#Preview("Camera Portrait") {
    CameraControlScreen(
        gimbal: Pocket3GimbalSession(),
        preferences: ControllerPreferences(),
        gamepad: GameControllerManager(),
        headTracking: HeadTrackingManager(),
        connectedCameraDisplayName: "Pocket 3",
        onConnectCamera: {},
        onDisconnectCamera: {},
        onOpenLegacyDebug: {}
    )
    .frame(width: 393, height: 852)
}
