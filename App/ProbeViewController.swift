#if !targetEnvironment(macCatalyst)
import UIKit
import ARKit
import RealityKit
import AVFoundation

final class ProbeViewController: UIViewController, ARSessionDelegate {
    private var arView: ARView!
    private let configuration = ARWorldTrackingConfiguration()
    private let captureService = FrameCaptureService()
    private var sessionID = UUID().uuidString
    private var originID: UUID?
    private var anchorEntity: AnchorEntity?
    private var routeEntity: Entity?
    private var routeLocalTransform = matrix_identity_float4x4
    private var points: [ProbePoint] = []
    private var routeKind: RouteKind = .right
    private var forwardLength = 2.0
    private var turnLength = 2.0
    private var routeRevision = 0
    private var recorder: RunRecorder?
    private var finishing = false
    private var exportBusy = false
    private var recordingError = false
    private var manualCaptureRequested = false
    private var lastAutoCapture: TimeInterval?
    private var lastPoseTime: TimeInterval?
    private var lastCameraTime: TimeInterval?
    private var lastHUDTime: TimeInterval = 0
    private var lastTracking = "not_available"
    private var cameraStats = IntervalStatistics()
    private var displayStats = IntervalStatistics()
    private var displayLink: CADisplayLink?
    private var lastDisplayTime: CFTimeInterval?
    private var capturedCount = 0
    private var attemptedCount = 0
    private var skippedCount = 0
    private var captureCosts: [Double] = []
    private var lastRunURL: URL?
    private var cameraAuthorized = false
    private var inBackground = false
    private var trackingEpoch = 0
    private var photoPreparing = false
    private var photoEditorVisible = false
    private var pendingCalibration: UUID?
    private var calibrationTask: Task<Void, Never>?
    private var calibrationPaused = false
    private var calibrationAnimationUntil: TimeInterval = 0
    private var lastCalibrationTime: TimeInterval?
    private var lastCalibrationCamera: SIMD3<Float>?
    private var lastCalibrationFrame: String?
    private var calibrationsApplied = 0
    private var calibrationsRejected = 0
    private let worldMapStore = WorldMapStore()
    private var mapBusy = false
    private var mapPreviewVisible = false
    private var lastSavedMap: SavedWorldMap?
    private var restoredMap: SavedWorldMap?
    private var restoreGate: WorldMapRestoreGate?
    private var restoreAnchorObserved = false
    private var restoreBoundaryTimestamp: TimeInterval = 0
    private var mapTimeoutTask: Task<Void, Never>?
    private var mapAlignmentAssessment: Bool?
    private var mapAlignmentSuspect = false
    private var previousMapPose: (time: Double, position: SIMD3<Float>)?
    private var lastMappingStatus = "unknown"
    private let mapButton = UIButton(type: .system)

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let diagnosticLabel = UILabel()
    private let instructionLabel = UILabel()
    private let originButton = UIButton(type: .system)
    private let directionButton = UIButton(type: .system)
    private let recordButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let photoButton = UIButton(type: .system)
    private let pauseCalibrationButton = UIButton(type: .system)
    private let routeControl = UISegmentedControl(items: RouteKind.allCases.map { $0.title })
    private let autoSwitch = UISwitch()
    private let reticle = UILabel()
    private var diagnosticsVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        arView = ARView(frame: view.bounds, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        arView.session.delegate = self
        arView.session.delegateQueue = .main
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.isLightEstimationEnabled = true
        buildInterface()
        lastRunURL = ProbeIO.existingRuns().first
        lastSavedMap = worldMapStore.packages().first
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common); displayLink = link
        UIApplication.shared.isIdleTimerDisabled = true
        checkCameraAndStart()
    }

    deinit { calibrationTask?.cancel(); mapTimeoutTask?.cancel(); displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    private func checkCameraAndStart() {
        guard ARWorldTrackingConfiguration.isSupported else {
            instructionLabel.text = "请在支持 ARKit 的真实 iPhone 上运行，模拟器不能完成本实验。"
            statusLabel.text = "此设备不支持世界跟踪"
            refreshButtons(); return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAuthorized = true; startSession(reset: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cameraAuthorized = granted
                    if granted { self.startSession(reset: true) }
                    else { self.cameraDenied() }
                }
            }
        default: cameraDenied()
        }
    }

    private func cameraDenied() {
        cameraAuthorized = false; statusLabel.text = "需要相机权限"
        instructionLabel.text = "到系统设置为本应用开启相机权限，然后重新打开应用。"
        refreshButtons()
    }

    private func startSession(reset: Bool) {
        guard cameraAuthorized, !inBackground else { return }
        if reset {
            mapTimeoutTask?.cancel(); mapTimeoutTask = nil
            configuration.initialWorldMap = nil
            restoredMap = nil; restoreGate = nil; restoreAnchorObserved = false
            mapAlignmentAssessment = nil; mapAlignmentSuspect = false; previousMapPose = nil
            calibrationPaused = false; autoSwitch.isOn = false
            trackingEpoch += 1
            invalidatePendingCalibration("AR 会话已重启。")
            sessionID = UUID().uuidString
            clearRoute(); captureService.reset()
            lastAutoCapture = nil; lastPoseTime = nil; lastCameraTime = nil
        }
        arView.session.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        if restoreGate?.state == .waiting {
            instructionLabel.text = "正在恢复环境地图。缓慢扫描保存照片中的地面和两侧固定物体。"
        } else if restoredMap != nil && mapAlignmentSuspect {
            instructionLabel.text = "地图位置需要重新恢复。结束并导出当前记录后，重新加载地图。"
        } else { instructionLabel.text = "缓慢扫描地面，设置路线；也可点击「环境地图」加载已保存的路线。" }
        refreshButtons()
    }

    private func buildInterface() {
        let header = panel()
        let title = UILabel(); title.text = "走廊 AR 验证 · 0.4"; title.textColor = .white
        title.font = .systemFont(ofSize: 19, weight: .bold)
        mapButton.setTitle("环境地图", for: .normal); mapButton.tintColor = .systemMint
        mapButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        mapButton.addTarget(self, action: #selector(mapMenuTapped), for: .touchUpInside)
        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.tintColor = .white
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        let titleRow = row([title, mapButton, settingsButton]); titleRow.distribution = .fill
        mapButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        settingsButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
        statusLabel.text = "正在检查设备…"; statusLabel.textColor = .systemMint
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold); statusLabel.numberOfLines = 2
        detailLabel.text = "原始图片仅保存在本机"; detailLabel.textColor = .lightGray
        detailLabel.font = .systemFont(ofSize: 12); detailLabel.numberOfLines = 2
        diagnosticLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticLabel.textColor = .white; diagnosticLabel.numberOfLines = 0; diagnosticLabel.isHidden = true
        addStack([titleRow, statusLabel, detailLabel, diagnosticLabel], to: header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
        reticle.text = "＋"; reticle.textAlignment = .center; reticle.textColor = .white
        reticle.font = .systemFont(ofSize: 40, weight: .ultraLight); reticle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reticle)
        NSLayoutConstraint.activate([reticle.centerXAnchor.constraint(equalTo: arView.centerXAnchor),
                                     reticle.centerYAnchor.constraint(equalTo: arView.centerYAnchor)])
        let controls = panel()
        instructionLabel.textColor = .white; instructionLabel.font = .systemFont(ofSize: 14)
        instructionLabel.numberOfLines = 3
        routeControl.selectedSegmentIndex = RouteKind.allCases.firstIndex(of: routeKind) ?? 3
        routeControl.selectedSegmentTintColor = .systemMint
        routeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        routeControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        routeControl.addTarget(self, action: #selector(routeChanged), for: .valueChanged)
        configure(originButton, "设起点", #selector(originTapped))
        configure(directionButton, "设方向", #selector(directionTapped))
        configure(recordButton, "开始记录", #selector(recordTapped), accent: true)
        configure(captureButton, "保存当前帧", #selector(captureTapped))
        configure(exportButton, "导出测试包", #selector(exportTapped))
        configure(photoButton, "照片校准", #selector(photoTapped), accent: true)
        configure(pauseCalibrationButton, "暂停校准", #selector(pauseCalibrationTapped))
        autoSwitch.isOn = false; autoSwitch.onTintColor = .systemMint
        autoSwitch.addTarget(self, action: #selector(autoChanged), for: .valueChanged)
        let autoLabel = UILabel(); autoLabel.text = "每 8 秒采图"; autoLabel.textColor = .white
        autoLabel.font = .systemFont(ofSize: 12)
        let autoRow = row([autoLabel, autoSwitch]); autoRow.distribution = .fill
        let exportRow = row([autoRow, exportButton]); exportRow.distribution = .fillEqually
        addStack([instructionLabel, routeControl, row([originButton, directionButton]),
                  row([photoButton, pauseCalibrationButton]), row([recordButton, captureButton]), exportRow], to: controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func panel() -> UIVisualEffectView {
        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        panel.layer.cornerRadius = 20; panel.clipsToBounds = true; panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel); return panel
    }
    private func row(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views); stack.axis = .horizontal
        stack.spacing = 8; stack.distribution = .fillEqually; stack.alignment = .center
        return stack
    }
    private func addStack(_ views: [UIView], to panel: UIVisualEffectView) {
        let stack = UIStackView(arrangedSubviews: views); stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -14)])
    }
    private func configure(_ button: UIButton, _ title: String, _ action: Selector, accent: Bool = false) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title; configuration.baseBackgroundColor = accent ? .systemMint : .darkGray
        configuration.baseForegroundColor = accent ? .black : .white; configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 8, bottom: 11, trailing: 8)
        button.configuration = configuration
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private var trackingNormal: Bool { lastTracking == "tracking" && !inBackground && cameraAuthorized }
    private func refreshButtons() {
        let recording = recorder != nil
        let calibrationBusy = photoPreparing || photoEditorVisible || pendingCalibration != nil
        let mapWaiting = restoreGate?.state == .waiting
        let interactive = !mapBusy && !mapWaiting && !mapPreviewVisible
        originButton.isEnabled = trackingNormal && !recording && !finishing && interactive && restoredMap == nil
        directionButton.isEnabled = originID != nil && trackingNormal && !recording && !finishing && interactive && restoredMap == nil
        routeControl.isEnabled = !recording && !finishing && interactive && restoredMap == nil
        let anchorReady = originID.map { id in arView.session.currentFrame?.anchors.contains { $0.identifier == id } ?? false } ?? false
        recordButton.isEnabled = recording ? !finishing && !captureService.busy && !calibrationBusy : trackingNormal && anchorReady && routeEntity != nil && (anchorEntity?.isAnchored ?? false) && !finishing && !exportBusy
        recordButton.isEnabled = recordButton.isEnabled && !mapBusy && !mapPreviewVisible
        if restoredMap != nil && !recording { recordButton.isEnabled = false }
        recordButton.configuration?.title = finishing ? "正在结束…" : recording ? "结束记录" : "开始记录"
        captureButton.isEnabled = recording && !finishing && trackingNormal && !captureService.busy && !calibrationBusy && !recordingError && interactive
        photoButton.isEnabled = trackingNormal && !finishing && !captureService.busy && !calibrationBusy && !calibrationPaused && !recordingError && !exportBusy && interactive && restoredMap == nil
        pauseCalibrationButton.isEnabled = routeEntity != nil && !finishing && !photoPreparing && !photoEditorVisible && interactive && restoredMap == nil
        pauseCalibrationButton.configuration?.title = calibrationPaused ? "恢复校准" : "暂停校准"
        autoSwitch.isEnabled = recording && !finishing && !recordingError
        exportButton.isEnabled = !recording && !finishing && !exportBusy && (lastRunURL != nil || !ProbeIO.existingRuns().isEmpty)
        exportButton.configuration?.title = exportBusy ? "正在打包…" : "导出测试包"
        exportButton.isEnabled = exportButton.isEnabled && !mapBusy && !mapPreviewVisible
        mapButton.isEnabled = !mapBusy && !finishing && !exportBusy && !calibrationBusy && !mapPreviewVisible
        settingsButton.isEnabled = !mapBusy && !mapWaiting && !mapPreviewVisible && !calibrationBusy
    }

    private func groundHit() -> ARRaycastResult? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard trackingNormal else { instructionLabel.text = "等待跟踪恢复后再放置。"; return nil }
        guard let result = arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal).first else {
            instructionLabel.text = "中央＋未命中已识别的地面。缓慢移动，露出地砖或地面纹理。"; return nil
        }
        return result
    }

    @objc private func originTapped() {
        guard recorder == nil, let hit = groundHit() else { return }
        clearRoute()
        var transform = matrix_identity_float4x4; transform.columns.3 = hit.worldTransform.columns.3
        let anchor = ARAnchor(name: "probe-origin", transform: transform)
        arView.session.add(anchor: anchor)
        let entity = AnchorEntity(anchor: anchor)
        let marker = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [UnlitMaterial(color: .systemCyan)])
        marker.position = [0,0.04,0]; entity.addChild(marker)
        arView.scene.addAnchor(entity); anchorEntity = entity; originID = anchor.identifier
        routeRevision += 1
        instructionLabel.text = "起点已选。沿走廊向前约 0.5 米以上，仍对准同一地面，点击「设方向」。"
        refreshButtons()
    }

    @objc private func directionTapped() {
        guard recorder == nil, let hit = groundHit(), let id = originID,
              let anchor = arView.session.currentFrame?.anchors.first(where: { $0.identifier == id }) else {
            instructionLabel.text = "先设置起点，并等待起点锚点就绪。"; return
        }
        let a = SIMD3<Float>(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
        let b = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        guard abs(b.y - a.y) < 0.12 else { instructionLabel.text = "第二点与起点高度不同，请确认都在同一地板。"; return }
        var forward = b - a; forward.y = 0
        guard simd_length(forward) >= 0.5 else { instructionLabel.text = "方向点距离太近，请选择至少约 0.5 米外的地面。"; return }
        forward = simd_normalize(forward)
        let up = SIMD3<Float>(0,1,0); let right = simd_normalize(simd_cross(forward, up))
        let back = -forward
        let world = simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(a, 1)))
        routeLocalTransform = simd_inverse(anchor.transform) * world
        rebuildRoute()
    }

    private func rebuildRoute(smoothFromWorld: simd_float4x4? = nil) {
        guard let anchorEntity else { return }
        do {
            let points = ProbeGeometry.route(routeKind, forward: forwardLength, turn: turnLength)
            let route = try RouteRenderer.make(kind: routeKind, points: points)
            let target = Transform(matrix: routeLocalTransform)
            route.transform = target
            routeEntity?.removeFromParent(); anchorEntity.addChild(route)
            if let oldWorld = smoothFromWorld, let frame = arView.session.currentFrame,
               let anchor = frame.anchors.first(where: { $0.identifier == originID }) {
                route.transform = Transform(matrix: simd_inverse(anchor.transform) * oldWorld)
                route.move(to: target, relativeTo: anchorEntity, duration: 0.35, timingFunction: .easeInOut)
                calibrationAnimationUntil = frame.timestamp + 0.4
            }
            routeEntity = route; self.points = points; routeRevision += 1
            instructionLabel.text = "测试路线已放置。先观察真实地面标记，再开始记录；移动手机检查箭头是否留在原处。"
            refreshButtons()
        } catch { showError("路线生成失败", error.localizedDescription) }
    }

    private func clearRoute() {
        if let id = originID, let anchor = arView.session.currentFrame?.anchors.first(where: { $0.identifier == id }) { arView.session.remove(anchor: anchor) }
        if let entity = anchorEntity { arView.scene.removeAnchor(entity) }
        originID = nil; anchorEntity = nil; routeEntity = nil; points = []
        routeLocalTransform = matrix_identity_float4x4
        lastCalibrationTime = nil; lastCalibrationCamera = nil; lastCalibrationFrame = nil
        calibrationAnimationUntil = 0
    }

    @objc private func routeChanged() {
        routeKind = RouteKind.allCases[routeControl.selectedSegmentIndex]
        if routeEntity != nil { rebuildRoute() }
    }

    @objc private func recordTapped() {
        if recorder != nil { finishRecording(); return }
        _ = beginRecording()
    }
    @discardableResult private func beginRecording(allowUnplaced: Bool = false, worldMapTest: Bool = false) -> Bool {
        if recorder != nil { return true }
        guard restoredMap == nil || worldMapTest else { return false }
        guard (worldMapTest || trackingNormal), (allowUnplaced || routeEntity != nil) else { return false }
        do {
            var config: [String: Any] = ["route_kind": routeKind.rawValue,
                "forward_m": forwardLength, "turn_m": turnLength, "capture_interval_s": 8,
                "image_policy": "original_sensor_resolution_no_rotation_no_mirror", "jpeg_quality": 0.85,
                "photo_calibration_test": !worldMapTest, "visual_model_available": false,
                "calibration_source": worldMapTest ? "arkit_world_map" : "manual_photo_points", "depth_used": false,
                "world_map_test": worldMapTest]
            if let map = restoredMap, worldMapTest {
                config["world_map_id"] = map.metadata.map_id
                config["world_map_source_session"] = map.metadata.source_session_id
                config["world_map_restore_timeout_s"] = 60
                config["manual_recalibration_disabled"] = true
            }
            let run = try RunRecorder(sessionID: sessionID, configuration: config,
                device: ["device_model": UIDevice.current.model, "ios_version": UIDevice.current.systemVersion,
                         "planned_test_device": "iPhone 15 Pro"])
            run.onFailure = { [weak self] message in
                guard let self else { return }
                self.recordingError = true; self.autoSwitch.isOn = false
                self.instructionLabel.text = "写入失败：\(message)。请结束记录并取回已有文件。"
                self.refreshButtons()
            }
            recorder = run; recordingError = false; captureService.reset()
            capturedCount = 0; attemptedCount = 0; skippedCount = 0; captureCosts = []
            calibrationsApplied = 0; calibrationsRejected = 0
            cameraStats = IntervalStatistics(); displayStats = IntervalStatistics()
            lastPoseTime = nil; lastCameraTime = nil; lastDisplayTime = nil
            lastAutoCapture = arView.session.currentFrame?.timestamp
            instructionLabel.text = "正在记录。按走廊测试步骤走动；可手动保存，也可开启每 8 秒采图。"
            refreshButtons()
            return true
        } catch { showError("无法开始记录", error.localizedDescription); return false }
    }

    private func finishRecording() {
        guard let recorder, !captureService.busy, !finishing, !mapBusy else { return }
        if restoreGate?.state == .waiting { failMapRestore("记录在完成地图恢复之前结束。", event: "world_map_restore_cancelled") }
        finishing = true; manualCaptureRequested = false; autoSwitch.isOn = false
        var summary: [String: Any] = ["capture_attempts": attemptedCount, "capture_skipped": skippedCount,
            "camera_frame_callback_intervals": cameraStats.summary,
            "main_display_callback_intervals": displayStats.summary,
            "performance_note": "Callback timing is not GPU render timing or a physical drift measurement."]
        if !captureCosts.isEmpty { summary["capture_commit_ms"] = captureCosts }
        summary["photo_calibrations_applied"] = calibrationsApplied
        summary["photo_calibrations_rejected"] = calibrationsRejected
        summary["visual_model_inference_performed"] = false
        if let map = restoredMap {
            summary["world_map_id"] = map.metadata.map_id
            summary["world_map_restore_state"] = restoreGate?.state.rawValue ?? "unknown"
            summary["world_map_sdk_restored"] = restoreGate?.state == .restored
            summary["world_map_alignment_assessment"] = mapAlignmentAssessment.map { $0 ? "aligned" : "misaligned" } ?? "not_checked"
            summary["world_map_alignment_suspect"] = mapAlignmentSuspect
            if let seconds = restoreGate?.restoreSeconds { summary["world_map_restore_seconds"] = seconds }
        }
        recorder.append("events.jsonl", ["event": "recording_stopped"])
        recorder.finish(statistics: summary) { [weak self] result in
            guard let self else { return }
            self.recorder = nil; self.finishing = false; self.lastRunURL = recorder.directory
            switch result {
            case .success: self.instructionLabel.text = "记录已结束：\(self.capturedCount) 张照片。点击「导出测试包」取回电脑检查。"
            case .failure(let error): self.showError("结束时发生错误", "已有文件保留在本机。\(error.localizedDescription)")
            }
            self.refreshButtons()
        }
        refreshButtons()
    }

    private var photoIdentity: PhotoRequestIdentity {
        PhotoRequestIdentity(session: sessionID, run: recorder?.runID ?? "", trackingEpoch: trackingEpoch, routeRevision: routeRevision)
    }
    private func calibrationEvent(_ event: String, fields: [String: Any] = [:]) {
        var payload = fields
        payload["event"] = event; payload["source"] = "manual_photo_points"
        payload["visual_model_inference_performed"] = false
        if let frame = arView.session.currentFrame { payload["timestamp"] = frame.timestamp }
        recorder?.append("events.jsonl", payload)
    }
    private func rejectCalibration(_ message: String, frameID: String? = nil) {
        calibrationsRejected += 1
        var fields: [String: Any] = ["reason": message]
        if let frameID { fields["query_frame_id"] = frameID }
        calibrationEvent("photo_calibration_rejected", fields: fields)
        instructionLabel.text = message; refreshButtons()
    }
    private func invalidatePendingCalibration(_ reason: String) {
        calibrationTask?.cancel(); calibrationTask = nil
        if pendingCalibration != nil {
            pendingCalibration = nil
            rejectCalibration(reason)
        }
    }

    @objc private func photoTapped() {
        guard !photoPreparing, !photoEditorVisible, pendingCalibration == nil, !calibrationPaused,
              !captureService.busy, trackingNormal, let hit = groundHit(), let frame = arView.session.currentFrame else { return }
        guard let planeID = hit.anchor?.identifier,
              let plane = frame.anchors.first(where: { $0.identifier == planeID }) as? ARPlaneAnchor,
              plane.alignment == .horizontal, plane.geometry.boundaryVertices.count >= 3,
              frame.camera.transform.columns.3.y - plane.transform.columns.3.y > 0.15 else {
            instructionLabel.text = "请把中央＋对准真实地板，扫描 A、B 周围后再点「照片校准」。"; return
        }
        guard beginRecording(allowUnplaced: true), let run = recorder else { return }
        let shot = PhotoCalibrationShot(frame: frame, plane: plane, identity: photoIdentity)
        photoPreparing = true; manualCaptureRequested = false; attemptedCount += 1
        calibrationEvent("photo_calibration_requested", fields: ["query_timestamp": shot.timestamp, "ground_plane_id": shot.planeID])
        var savedFrameID = ""
        let accepted = captureService.capture(frame: frame, recorder: run, reason: "photo_calibration", route: routeSnapshot(frame),
            calibrationGeometry: shot.metadata, imageDelivery: { [weak self] data in
                guard let self else { return }
                guard self.recorder === run, let current = self.arView.session.currentFrame else {
                    self.rejectCalibration("记录已经改变，请重新拍照。", frameID: savedFrameID); return
                }
                if let reason = PhotoRequestGuard.rejection(captured: shot.identity, current: self.photoIdentity,
                    captureTime: shot.timestamp, currentTime: current.timestamp, trackingNormal: self.trackingNormal, paused: self.calibrationPaused) {
                    self.rejectCalibration(reason, frameID: savedFrameID); return
                }
                let picker = PhotoPointPicker(jpeg: data, shot: shot)
                self.photoEditorVisible = true; self.refreshButtons()
                picker.submitted = { [weak self] pixels, delay in
                    guard let self else { return }
                    self.photoEditorVisible = false
                    self.schedulePhotoCalibration(shot, frameID: savedFrameID, pixels: pixels, delay: delay)
                }
                picker.cancelled = { [weak self] in
                    guard let self else { return }
                    self.photoEditorVisible = false
                    self.calibrationEvent("photo_calibration_cancelled", fields: ["query_frame_id": savedFrameID])
                    self.instructionLabel.text = "已取消选点，原路线保留；可重新拍照或结束记录。"; self.refreshButtons()
                }
                self.present(picker, animated: true)
            }) { [weak self] result in
                guard let self else { return }
                self.photoPreparing = false
                switch result {
                case .success(let info):
                    savedFrameID = info["frame_id"] as? String ?? ""
                    self.capturedCount += 1
                    if let cost = info["capture_to_commit_ms"] as? Double { self.captureCosts.append(cost) }
                    run.append("events.jsonl", info.merging(["event": "capture_committed"]) { a, _ in a })
                case .failure(let error):
                    self.skippedCount += 1; self.rejectCalibration(error.localizedDescription)
                }
                self.refreshButtons()
            }
        if !accepted { photoPreparing = false; skippedCount += 1; rejectCalibration("取帧忙碌，请稍后重新拍照。") }
        refreshButtons()
    }

    private func schedulePhotoCalibration(_ shot: PhotoCalibrationShot, frameID: String, pixels: [[Double]], delay: Double) {
        guard let current = arView.session.currentFrame else { rejectCalibration("没有当前相机帧，请重新拍照。", frameID: frameID); return }
        if let reason = PhotoRequestGuard.rejection(captured: shot.identity, current: photoIdentity,
            captureTime: shot.timestamp, currentTime: current.timestamp, trackingNormal: trackingNormal, paused: calibrationPaused) {
            rejectCalibration(reason, frameID: frameID); return
        }
        let request = UUID(); pendingCalibration = request
        calibrationEvent("photo_calibration_points_submitted", fields: ["request_id": request.uuidString,
            "query_frame_id": frameID, "query_timestamp": shot.timestamp, "raw_pixels": pixels,
            "extra_delay_s": delay, "pixel_coordinate_system": "raw_sensor_top_left_x_right_y_down"])
        instructionLabel.text = "将在 \(Int(delay)) 秒后绑定。现在可转动或短距离移动手机，保持地面纹理可见。"
        calibrationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.pendingCalibration == request else { return }
            self.pendingCalibration = nil; self.calibrationTask = nil
            self.applyPhotoCalibration(shot, frameID: frameID, pixels: pixels, delay: delay)
        }
        refreshButtons()
    }

    private func applyPhotoCalibration(_ shot: PhotoCalibrationShot, frameID: String, pixels: [[Double]], delay: Double) {
        guard let frame = arView.session.currentFrame else { rejectCalibration("没有当前相机帧。", frameID: frameID); return }
        if let reason = PhotoRequestGuard.rejection(captured: shot.identity, current: photoIdentity,
            captureTime: shot.timestamp, currentTime: frame.timestamp, trackingNormal: trackingNormal, paused: calibrationPaused) {
            rejectCalibration(reason, frameID: frameID); return
        }
        do {
            guard pixels.count == 2 else { throw PhotoGeometryError.invalidPixel }
            let a = try PhotoGeometry.floorPoint(rawPixel: pixels[0], geometry: shot.geometry)
            let b = try PhotoGeometry.floorPoint(rawPixel: pixels[1], geometry: shot.geometry)
            let length = PhotoGeometry.horizontalDistance(a, b)
            guard length >= 0.5 else { throw PhotoGeometryError.pointsTooClose }
            guard length <= 10 else { throw PhotoGeometryError.pointsTooFar }
            guard abs(a.y - b.y) < 0.12 else { throw PhotoGeometryError.invalidGeometry }
            let p = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
            var forward = SIMD3<Float>(Float(b.x - a.x), 0, Float(b.z - a.z)); forward = simd_normalize(forward)
            let up = SIMD3<Float>(0,1,0), right = simd_normalize(simd_cross(forward, up))
            let world = simd_float4x4(columns: (SIMD4(right,0), SIMD4(up,0), SIMD4(-forward,0), SIMD4(p,1)))
            var oldWorld: simd_float4x4?
            var correctionDistance = 0.0, correctionAngle = 0.0
            if let id = originID, let anchor = frame.anchors.first(where: { $0.identifier == id }), routeEntity != nil {
                let previous = anchor.transform * routeLocalTransform
                oldWorld = previous
                correctionDistance = hypot(Double(world.columns.3.x - previous.columns.3.x), Double(world.columns.3.z - previous.columns.3.z))
                let oldForward = -SIMD3<Float>(previous.columns.2.x, 0, previous.columns.2.z)
                correctionAngle = Double(acos(min(1, max(-1, simd_dot(simd_normalize(oldForward), forward))))) * 180 / .pi
                guard correctionDistance <= 1, abs(world.columns.3.y - previous.columns.3.y) <= 0.25, correctionAngle <= 30 else {
                    rejectCalibration("新旧绑定差异过大，已保留旧路线。请对同一组 A、B 重新拍照选点。", frameID: frameID); return
                }
                // The reference anchor remains tracked; only the route's local alignment is corrected.
                anchorEntity?.children.filter { $0 !== routeEntity }.forEach { $0.removeFromParent() }
                routeLocalTransform = simd_inverse(anchor.transform) * world
            } else {
                clearRoute()
                var base = matrix_identity_float4x4; base.columns.3 = SIMD4(p,1)
                let anchor = ARAnchor(name: "photo-calibration-origin", transform: base)
                arView.session.add(anchor: anchor)
                let entity = AnchorEntity(anchor: anchor)
                arView.scene.addAnchor(entity); anchorEntity = entity; originID = anchor.identifier
                routeLocalTransform = simd_inverse(base) * world
            }
            forwardLength = length
            rebuildRoute(smoothFromWorld: oldWorld)
            lastCalibrationTime = frame.timestamp
            lastCalibrationCamera = SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
            lastCalibrationFrame = frameID; calibrationsApplied += 1
            calibrationEvent("photo_calibration_applied", fields: ["query_frame_id": frameID, "query_timestamp": shot.timestamp,
                "raw_pixels": pixels, "world_points": [a.array, b.array], "ground_plane_id": shot.planeID,
                "extra_delay_s": delay, "capture_to_binding_s": frame.timestamp - shot.timestamp,
                "correction_horizontal_m": correctionDistance, "correction_angle_deg": correctionAngle,
                "forward_m": length, "route_revision": routeRevision, "same_capture_geometry_used": true])
            instructionLabel.text = String(format: "照片绑定完成，AB 估计 %.2f 米。检查蓝色起点和转角/末端是否对应 A、B。", length)
            refreshButtons()
        } catch { rejectCalibration(error.localizedDescription, frameID: frameID) }
    }

    @objc private func pauseCalibrationTapped() {
        calibrationPaused.toggle()
        if calibrationPaused { invalidatePendingCalibration("校准已暂停，旧路线继续由 AR 跟踪。") }
        calibrationEvent("photo_calibration_pause_changed", fields: ["paused": calibrationPaused])
        instructionLabel.text = calibrationPaused ? "模拟图像识别不可用：不接受新校准，AR 跟踪正常时继续显示旧路线。" : "校准已恢复。对同一组 A、B 拍照，可在记录中再次校准。"
        refreshButtons()
    }

    @objc private func captureTapped() { manualCaptureRequested = true; instructionLabel.text = "等待下一份有效相机帧…" }
    @objc private func autoChanged() {
        lastAutoCapture = arView.session.currentFrame?.timestamp
        recorder?.append("events.jsonl", ["event": "auto_capture_changed", "enabled": autoSwitch.isOn])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if mapBusy && restoredMap != nil { return }
        if restoredMap != nil && frame.timestamp <= restoreBoundaryTimestamp { return }
        let tracking = trackingName(frame.camera.trackingState)
        if tracking != lastTracking {
            if tracking != "tracking" {
                trackingEpoch += 1
                invalidatePendingCalibration("拍照后跟踪质量下降，已拒绝延迟结果，请重新拍照。")
            }
            recorder?.append("events.jsonl", ["event": "tracking_changed", "timestamp": frame.timestamp, "state": tracking])
            if lastTracking != "tracking", tracking == "tracking", routeEntity != nil {
                instructionLabel.text = "跟踪已恢复，请对照地面标记确认原路线位置。"
            }
            lastTracking = tracking
        }
        updateMapRestore(frame)
        let originPresent = originID.map { id in frame.anchors.contains { $0.identifier == id } } ?? false
        let mapReady = restoredMap == nil || (restoreGate?.state == .restored && !mapAlignmentSuspect)
        let visible = trackingNormal && originPresent && (anchorEntity?.isAnchored ?? false) && mapReady
        setContentVisible(visible)
        if let previous = lastCameraTime, recorder != nil { cameraStats.add(seconds: frame.timestamp - previous) }
        lastCameraTime = frame.timestamp
        if let recorder, !finishing, !inBackground {
            recorder.append("camera-events.jsonl", ["timestamp": frame.timestamp, "tracking": tracking,
                "world_mapping_status": worldMappingName(frame.worldMappingStatus)])
            let mapping = worldMappingName(frame.worldMappingStatus)
            if mapping != lastMappingStatus {
                lastMappingStatus = mapping
                recorder.append("events.jsonl", ["event": "world_mapping_status_changed", "timestamp": frame.timestamp, "status": mapping])
            }
            if lastPoseTime == nil || frame.timestamp - (lastPoseTime ?? 0) >= 1.0 / 30.0 {
                lastPoseTime = frame.timestamp
                recorder.append("poses.jsonl", ["timestamp": frame.timestamp, "source": "ARFrame.camera.transform",
                    "direction": "camera_to_session", "matrix": matrixRows(frame.camera.transform), "tracking": tracking])
                if originPresent { recorder.append("anchors.jsonl", ["timestamp": frame.timestamp, "route": routeSnapshot(frame)]) }
            }
            let automatic = autoSwitch.isOn && frame.timestamp - (lastAutoCapture ?? frame.timestamp) >= 8
            let photoBusy = photoPreparing || photoEditorVisible || pendingCalibration != nil || frame.timestamp < calibrationAnimationUntil
            if (manualCaptureRequested || automatic) && !photoBusy {
                let reason = manualCaptureRequested ? "manual" : "interval_8s"
                manualCaptureRequested = false; lastAutoCapture = frame.timestamp; attemptedCount += 1
                if visible && !recordingError {
                    let accepted = captureService.capture(frame: frame, recorder: recorder, reason: reason, route: routeSnapshot(frame)) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success(let info):
                            self.capturedCount += 1
                            if let cost = info["capture_to_commit_ms"] as? Double { self.captureCosts.append(cost) }
                            self.instructionLabel.text = "已保存第 \(self.capturedCount) 张原始照片；图像几何与实际漂移仍需验证。"
                            recorder.append("events.jsonl", info.merging(["event": "capture_committed"]) { a, _ in a })
                        case .failure(let error):
                            self.skippedCount += 1; self.instructionLabel.text = "本次采图失败：\(error.localizedDescription)"
                            recorder.append("events.jsonl", ["event": "capture_failed", "reason": error.localizedDescription])
                        }
                        self.refreshButtons()
                    }
                    if !accepted { skippedCount += 1; recorder.append("events.jsonl", ["event": "capture_skipped", "reason": "busy_or_duplicate_frame", "timestamp": frame.timestamp]) }
                } else {
                    skippedCount += 1
                    recorder.append("events.jsonl", ["event": "capture_skipped", "reason": "tracking_or_anchor_unavailable", "timestamp": frame.timestamp])
                }
            }
        }
        if frame.timestamp - lastHUDTime > 0.25 {
            lastHUDTime = frame.timestamp
            updateHUD(frame, originPresent: originPresent)
            refreshButtons()
        }
    }

    private func routeSnapshot(_ frame: ARFrame) -> [String: Any] {
        guard let id = originID, let anchor = frame.anchors.first(where: { $0.identifier == id }) else {
            return ["anchor_state": "not_present", "revision": routeRevision]
        }
        let world = anchor.transform * routeLocalTransform
        let testPoints = points.enumerated().map { index, point -> [String: Any] in
            let p = world * SIMD4<Float>(Float(point.x), Float(point.y), Float(point.z), 1)
            return ["name": "route_point_\(index)", "local": point.array, "session": [Double(p.x),Double(p.y),Double(p.z)]]
        }
        return ["anchor_id": id.uuidString, "anchor_state": "present_in_ARFrame",
                "entity_is_anchored": anchorEntity?.isAnchored ?? false,
                "revision": routeRevision, "kind": routeKind.rawValue,
                "last_photo_calibration_frame": lastCalibrationFrame ?? "none",
                "photo_calibration_paused": calibrationPaused,
                "localization_provider": restoredMap == nil ? "manual_photo_points" : "arkit_world_map",
                "world_map_restore_state": restoreGate?.state.rawValue ?? "not_applicable",
                "world_map_id": restoredMap?.metadata.map_id ?? "none",
                "geometry_role": frame.timestamp < calibrationAnimationUntil ? "target_during_correction_animation" : "route_target",
                "anchor_to_session": matrixRows(anchor.transform), "route_to_anchor": matrixRows(routeLocalTransform),
                "test_points_session": testPoints]
    }

    private func setContentVisible(_ visible: Bool) {
        // Keep the AnchorEntity enabled so RealityKit can continue resolving it.
        anchorEntity?.children.forEach { $0.isEnabled = visible }
    }

    private func updateHUD(_ frame: ARFrame, originPresent: Bool) {
        statusLabel.text = lastTracking == "tracking" ? "● 跟踪正常 · \(originPresent ? "起点已关联" : "扫描地面中")" : "● 跟踪受限 · 路线已暂停"
        statusLabel.textColor = lastTracking == "tracking" ? .systemMint : .systemOrange
        var detail = "\(recorder == nil ? "未记录" : "记录中") · \(capturedCount) 张 · 手动照片校准 \(calibrationsApplied) 次"
        if let time = lastCalibrationTime, let camera = lastCalibrationCamera {
            let now = frame.camera.transform.columns.3
            let displacement = hypot(now.x - camera.x, now.z - camera.z)
            detail += String(format: "\n校准后 %.0f 秒 · 相对位移 %.2f 米 · %@", frame.timestamp - time, displacement, calibrationPaused ? "校准暂停" : "校准可用")
        } else { detail += "\n几何验收待完成 · 没有识别模型" }
        detailLabel.text = detail
        if let map = restoredMap, let gate = restoreGate {
            let assessment = mapAlignmentAssessment.map { $0 ? "人工确认对齐" : "人工反馈错位" } ?? "待人工核对 A、B"
            switch gate.state {
            case .waiting:
                statusLabel.text = "● 正在恢复：\(map.metadata.name)"
                statusLabel.textColor = .systemOrange
                detailLabel.text = String(format: "等待 %.0f / 60 秒 · %@\n已自动记录；扫描保存照片中的环境", ProcessInfo.processInfo.systemUptime - gate.startTime, lastTracking)
            case .restored:
                statusLabel.text = mapAlignmentSuspect ? "● 地图位置待重新恢复" : "● 地图已恢复 · \(map.metadata.name)"
                statusLabel.textColor = mapAlignmentSuspect ? .systemOrange : .systemMint
                detailLabel.text = String(format: "恢复用时 %.1f 秒 · %@\n记录中 %d 张 · %@", gate.restoreSeconds ?? 0, assessment, capturedCount, worldMappingTitle(frame.worldMappingStatus))
            case .timedOut, .failed:
                statusLabel.text = "● 地图未恢复 · 路线已隐藏"; statusLabel.textColor = .systemOrange
                detailLabel.text = "结束并导出这次记录，再加载同一地图重试。"
            }
        } else {
            statusLabel.text = (statusLabel.text ?? "") + "\n建图：" + (trackingNormal ? worldMappingTitle(frame.worldMappingStatus) : "等待跟踪恢复")
        }
        let t = frame.camera.transform.columns.3
        let size = frame.camera.imageResolution
        diagnosticLabel.text = String(format: "ARKit 真机帧 · %@\n相机 %.2f, %.2f, %.2f m\n原图 %.0f × %.0f · 姿态与图像来自同一 ARFrame\n尝试 %d / 跳过 %d · %@\n路线长度 %.1f + %.1f m\n会话 %@", lastTracking, t.x,t.y,t.z,size.width,size.height,
            attemptedCount, skippedCount, captureService.busy ? "正在编码写入" : "取帧空闲", forwardLength,turnLength,String(sessionID.prefix(8)))
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        if recorder != nil, !inBackground, let previous = lastDisplayTime { displayStats.add(seconds: link.timestamp - previous) }
        lastDisplayTime = link.timestamp
    }

    @objc private func backgrounded() {
        if restoreGate?.state == .waiting { failMapRestore("等待地图恢复时应用进入后台，请结束记录后重新加载。") }
        markMapAlignmentSuspect("应用进入后台，原路线位置需重新恢复。", event: "world_map_backgrounded_after_restore")
        trackingEpoch += 1; invalidatePendingCalibration("应用进入后台，延迟校准已取消。")
        inBackground = true; manualCaptureRequested = false; displayLink?.isPaused = true
        recorder?.append("events.jsonl", ["event": "app_backgrounded"])
        arView.session.pause(); setContentVisible(false); refreshButtons()
    }
    @objc private func foregrounded() {
        let wasBackground = inBackground; inBackground = false
        displayLink?.isPaused = false; lastDisplayTime = nil; lastCameraTime = nil; lastAutoCapture = nil
        if wasBackground {
            lastAutoCapture = arView.session.currentFrame?.timestamp
            recorder?.append("events.jsonl", ["event": "app_foregrounded"])
            startSession(reset: false)
        } else if !cameraAuthorized && AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            cameraAuthorized = true; startSession(reset: true)
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        if restoreGate?.state == .waiting { failMapRestore("等待地图恢复时 AR 会话中断，请重新加载。") }
        markMapAlignmentSuspect("AR 会话中断，原路线位置需重新恢复。", event: "world_map_interrupted_after_restore")
        trackingEpoch += 1; invalidatePendingCalibration("AR 会话中断，延迟校准已取消。")
        lastTracking = "interrupted"; setContentVisible(false)
        recorder?.append("events.jsonl", ["event": "session_interrupted"])
        instructionLabel.text = "AR 会话中断，路线已隐藏；等待恢复后检查原起点。"; refreshButtons()
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        recorder?.append("events.jsonl", ["event": "session_interruption_ended"])
        lastCameraTime = nil; lastAutoCapture = nil
        startSession(reset: false)
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
    func session(_ session: ARSession, didFailWithError error: Error) {
        failMapRestore("AR 会话失败：\(error.localizedDescription)")
        markMapAlignmentSuspect("AR 会话失败，原路线位置需重新恢复。", event: "world_map_failed_after_restore")
        trackingEpoch += 1; invalidatePendingCalibration("AR 会话失败，延迟校准已取消。")
        lastTracking = "session_failed"; setContentVisible(false); autoSwitch.isOn = false
        recorder?.append("events.jsonl", ["event": "session_failed", "error": error.localizedDescription])
        statusLabel.text = "AR 会话失败"; instructionLabel.text = "\(error.localizedDescription)。结束并导出已有数据后，可在设置中重启 AR。"
        refreshButtons()
    }
    private var canSaveWorldMap: Bool {
        guard !mapBusy, !mapPreviewVisible, recorder == nil, !finishing, !exportBusy,
              restoredMap == nil, trackingNormal, routeEntity != nil,
              anchorEntity?.isAnchored == true, let id = originID,
              let frame = arView.session.currentFrame else { return false }
        return frame.worldMappingStatus == .mapped && frame.anchors.contains { $0.identifier == id }
    }

    @objc private func mapMenuTapped() {
        let maps = worldMapStore.packages()
        let explanation: String
        if recorder != nil && restoredMap != nil {
            explanation = "恢复测试自动记录。核对 A、B 后确认结果；结束记录后才能加载另一张地图。"
        } else if recorder != nil {
            explanation = "请先结束当前记录，再保存或加载环境地图。保存前需要扫描至「可保存地图」。"
        } else {
            explanation = "保存：先放好路线、结束记录，再扫描至「可保存地图」。加载：回到同一环境后选择地图。"
        }
        let sheet = UIAlertController(title: "环境地图 · 已保存 \(maps.count) 张", message: explanation, preferredStyle: .actionSheet)
        let save = UIAlertAction(title: "保存当前环境与路线", style: .default) { [weak self] _ in self?.nameWorldMap() }
        save.isEnabled = canSaveWorldMap; sheet.addAction(save)
        if let gate = restoreGate, gate.state == .restored, recorder != nil {
            let aligned = UIAlertAction(title: "确认：路线与 A、B 对齐", style: .default) { [weak self] _ in self?.assessMapAlignment(true) }
            aligned.isEnabled = !mapAlignmentSuspect && trackingNormal; sheet.addAction(aligned)
            sheet.addAction(UIAlertAction(title: "反馈：路线存在错位", style: .default) { [weak self] _ in self?.assessMapAlignment(false) })
        }
        if recorder == nil && !finishing {
            for package in maps.prefix(12) {
                sheet.addAction(UIAlertAction(title: "加载：\(package.metadata.name)", style: .default) { [weak self] _ in self?.previewWorldMap(package) })
            }
            if !maps.isEmpty {
                sheet.addAction(UIAlertAction(title: "分享地图包（含独立路线数据）", style: .default) { [weak self] _ in self?.chooseMapExport(maps) })
            }
        }
        sheet.addAction(UIAlertAction(title: "返回", style: .cancel))
        sheet.popoverPresentationController?.sourceView = mapButton; sheet.popoverPresentationController?.sourceRect = mapButton.bounds
        present(sheet, animated: true)
    }

    private func nameWorldMap() {
        guard canSaveWorldMap else { return }
        let alert = UIAlertController(title: "保存环境地图", message: "围绕路线慢慢观察地面、门框和两侧固定物体。使用一个容易辨认的名称。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "例如：宿舍三楼短走廊"; $0.text = "走廊测试 \(self.worldMapStore.packages().count + 1)" }
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = String((alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            guard !name.isEmpty else { self.instructionLabel.text = "地图名称不能为空。"; return }
            self.saveWorldMap(name: name)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel)); present(alert, animated: true)
    }

    private func saveWorldMap(name: String) {
        guard canSaveWorldMap, let id = originID, let frame = arView.session.currentFrame else { return }
        let identity = photoIdentity, localTransform = routeLocalTransform
        let route = PortableRoute(id: UUID().uuidString, name: name, kind: routeKind, forward: forwardLength, turn: turnLength)
        let reference = WorldMapReferenceFrame(frame: frame), timestamp = frame.timestamp
        mapBusy = true; instructionLabel.text = "正在保存环境地图和路线，保持缓慢扫描…"; refreshButtons()
        arView.session.getCurrentWorldMap { [weak self] (map: ARWorldMap?, error: Error?) in
            DispatchQueue.main.async {
                guard let self else { return }
                guard identity == self.photoIdentity, self.trackingNormal, !self.inBackground,
                      self.arView.session.currentFrame?.worldMappingStatus == .mapped else {
                    self.mapBusy = false; self.instructionLabel.text = "保存期间跟踪或路线发生变化，请恢复扫描后重新保存。"; self.refreshButtons(); return
                }
                guard let map, let anchor = map.anchors.first(where: { $0.identifier == id }),
                      let name = anchor.name, map.rawFeaturePoints.points.count > 0 else {
                    self.mapBusy = false; self.refreshButtons()
                    self.showError("地图未保存", error?.localizedDescription ?? "地图没有包含路线起点或足够环境特征，请继续扫描。")
                    return
                }
                let metadata = WorldMapMetadata(map_id: route.route_id, name: route.name,
                    created_utc: ISO8601DateFormatter().string(from: Date()), source_session_id: identity.session,
                    origin_anchor_id: id.uuidString, origin_anchor_name: name, anchor_to_map: matrixRows(anchor.transform),
                    route_to_anchor: matrixRows(localTransform), saved_mapping_status: "mapped", feature_point_count: map.rawFeaturePoints.points.count,
                    app_version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    reference_timestamp: timestamp)
                self.worldMapStore.save(map: map, metadata: metadata, route: route, reference: reference) { [weak self] result in
                    guard let self else { return }; self.mapBusy = false; self.refreshButtons()
                    switch result {
                    case .success(let package):
                        self.lastSavedMap = package
                        self.instructionLabel.text = "已保存「\(package.metadata.name)」。可以完全关闭 App，再在同一环境中加载地图，不需重设 A、B。"
                    case .failure(let error): self.showError("地图未保存", error.localizedDescription)
                    }
                }
            }
        }
    }

    private func previewWorldMap(_ package: SavedWorldMap) {
        guard recorder == nil, !mapBusy, !finishing, !inBackground else { return }
        mapPreviewVisible = true; refreshButtons()
        let preview = WorldMapPreviewController(package: package)
        preview.loadRequested = { [weak self] in self?.mapPreviewVisible = false; self?.loadWorldMap(package) }
        preview.closed = { [weak self] in self?.mapPreviewVisible = false; self?.refreshButtons() }
        present(preview, animated: true)
    }

    private func loadWorldMap(_ package: SavedWorldMap) {
        guard recorder == nil, !mapBusy, !finishing, cameraAuthorized, !inBackground else { return }
        mapBusy = true; instructionLabel.text = "正在校验并加载地图…"; refreshButtons()
        worldMapStore.load(package) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.mapBusy = false; self.refreshButtons(); self.showError("加载失败", error.localizedDescription)
            case .success(let loaded):
                guard !self.inBackground else {
                    self.mapBusy = false; self.refreshButtons(); self.instructionLabel.text = "加载时应用进入后台，请返回后重新选择地图。"; return
                }
                self.prepareWorldMapRestore(loaded)
            }
        }
    }

    private func prepareWorldMapRestore(_ loaded: LoadedWorldMap) {
        arView.session.pause(); setContentVisible(false)
        mapTimeoutTask?.cancel(); mapTimeoutTask = nil
        trackingEpoch += 1; invalidatePendingCalibration("已开始新的地图恢复会话。")
        restoreBoundaryTimestamp = arView.session.currentFrame?.timestamp ?? 0
        clearRoute(); sessionID = UUID().uuidString; captureService.reset()
        lastTracking = "not_available"; lastMappingStatus = "unknown"
        restoredMap = loaded.package; restoreAnchorObserved = false; restoreGate = nil
        mapAlignmentAssessment = nil; mapAlignmentSuspect = false; previousMapPose = nil
        routeKind = RouteKind(rawValue: loaded.package.route.kind) ?? .straight
        forwardLength = loaded.package.route.forward_m; turnLength = loaded.package.route.turn_m
        routeControl.selectedSegmentIndex = RouteKind.allCases.firstIndex(of: routeKind) ?? 1
        calibrationPaused = true; autoSwitch.isOn = true
        guard beginRecording(allowUnplaced: true, worldMapTest: true), let run = recorder else {
            mapBusy = false; configuration.initialWorldMap = nil; restoredMap = nil; calibrationPaused = false
            startSession(reset: true); refreshButtons(); return
        }
        let expectedSession = sessionID
        worldMapStore.attach(loaded.package, to: run) { [weak self] result in
            guard let self, self.sessionID == expectedSession, self.recorder === run else { return }
            self.mapBusy = false
            switch result {
            case .failure(let error):
                self.restoreGate = WorldMapRestoreGate(startTime: ProcessInfo.processInfo.systemUptime)
                self.failMapRestore("无法保存本次测试使用的地图：\(error.localizedDescription)")
                self.arView.session.run(self.configuration)
            case .success:
                guard !self.inBackground else {
                    self.restoreGate = WorldMapRestoreGate(startTime: ProcessInfo.processInfo.systemUptime)
                    self.failMapRestore("开始恢复时应用进入后台，请结束记录后重新加载。"); self.refreshButtons(); return
                }
                let started = ProcessInfo.processInfo.systemUptime
                self.restoreGate = WorldMapRestoreGate(startTime: started)
                run.append("events.jsonl", ["event": "world_map_restore_requested", "map_id": loaded.package.metadata.map_id,
                    "source_session_id": loaded.package.metadata.source_session_id,
                    "expected_anchor_id": loaded.package.metadata.origin_anchor_id, "timeout_s": 60,
                    "localization_provider": "arkit_world_map", "visual_model_inference_performed": false,
                    "started_uptime_s": started, "manual_recalibration_disabled": true])
                self.configuration.initialWorldMap = loaded.worldMap
                self.arView.session.run(self.configuration, options: [.resetTracking, .removeExistingAnchors])
                // Later foreground resumes use the live session rather than injecting the saved map again.
                self.configuration.initialWorldMap = nil
                self.instructionLabel.text = "地图恢复中：扫描保存照片中的环境。成功后路线自动出现，不要重新设起点或照片校准。"
                self.mapTimeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard let self, self.sessionID == expectedSession, self.restoreGate?.state == .waiting else { return }
                    self.failMapRestore("60 秒内未能恢复地图。结束并导出记录后，可回到保存位置重试。", event: "world_map_restore_timeout")
                }
            }
            self.refreshButtons()
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard restoredMap != nil, restoreGate?.state == .waiting,
              let target = restoredMap?.metadata.origin_anchor_id else { return }
        if let anchor = anchors.first(where: { $0.identifier.uuidString == target }), RigidMatrix.valid(matrixRows(anchor.transform)) {
            restoreAnchorObserved = true
            recorder?.append("events.jsonl", ["event": "world_map_target_anchor_observed", "anchor_id": target])
        }
    }

    private func updateMapRestore(_ frame: ARFrame) {
        guard let package = restoredMap, var gate = restoreGate else { return }
        let target = frame.anchors.first { $0.identifier.uuidString == package.metadata.origin_anchor_id
            && $0.name == package.metadata.origin_anchor_name }
        if gate.state == .waiting {
            let relativeCamera = target.map { simd_inverse($0.transform)*frame.camera.transform }
            let success = gate.observe(now: ProcessInfo.processInfo.systemUptime, trackingNormal: trackingNormal,
                anchorObserved: restoreAnchorObserved, anchorPresent: target.map { RigidMatrix.valid(matrixRows($0.transform)) } ?? false,
                sampleTime:frame.timestamp,position:relativeCamera.map { [Double($0.columns.3.x),Double($0.columns.3.y),Double($0.columns.3.z)] })
            restoreGate = gate
            if gate.state == .timedOut {
                failMapRestore("60 秒内未能恢复地图。结束并导出记录后，可在同一环境重试。", event: "world_map_restore_timeout")
            } else if success, let anchor = target {
                originID = anchor.identifier
                let entity = AnchorEntity(anchor: anchor); arView.scene.addAnchor(entity); anchorEntity = entity
                routeLocalTransform = matrixFromRows(package.metadata.route_to_anchor)
                rebuildRoute(); setContentVisible(false)
                mapTimeoutTask?.cancel(); mapTimeoutTask = nil
                recorder?.append("events.jsonl", ["event": "world_map_sdk_restored", "timestamp": frame.timestamp,
                    "map_id": package.metadata.map_id, "restore_seconds": gate.restoreSeconds ?? 0,
                    "anchor_id": anchor.identifier.uuidString, "anchor_to_session": matrixRows(anchor.transform),
                    "localization_provider": "arkit_world_map", "physical_alignment_verified": false,
                    "visual_model_inference_performed": false])
                instructionLabel.text = "地图已恢复，路线自动出现。请核对原 A、B，在「环境地图」里确认对齐或反馈错位。"
                refreshButtons()
            }
        }
        if gate.state == .restored {
            let position = SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
            if let old = previousMapPose {
                let dt = frame.timestamp - old.time, distance = simd_distance(position, old.position)
                if dt > 0 && dt < 0.15 && distance > 0.5 && !mapAlignmentSuspect {
                    mapAlignmentSuspect = true; mapAlignmentAssessment = nil; setContentVisible(false)
                    recorder?.append("events.jsonl", ["event": "world_map_pose_jump_detected", "timestamp": frame.timestamp,
                        "distance_m": Double(distance), "interval_s": dt])
                    instructionLabel.text = "手机位置出现异常跳变，路线已隐藏。结束记录并重新加载地图，避免继续使用错误位置。"
                }
            }
            previousMapPose = (frame.timestamp, position)
        }
    }

    private func failMapRestore(_ message: String, event: String = "world_map_restore_failed") {
        guard var gate = restoreGate, gate.state == .waiting || gate.state == .timedOut else { return }
        if event == "world_map_restore_timeout" {
            _ = gate.observe(now: gate.startTime + gate.timeout, trackingNormal: false, anchorObserved: false, anchorPresent: false)
        } else { gate.fail() }
        restoreGate = gate; mapTimeoutTask?.cancel(); mapTimeoutTask = nil
        setContentVisible(false)
        recorder?.append("events.jsonl", ["event": event, "reason": message, "map_id": restoredMap?.metadata.map_id ?? "unknown"])
        instructionLabel.text = message; refreshButtons()
    }

    private func assessMapAlignment(_ aligned: Bool) {
        guard let map = restoredMap, restoreGate?.state == .restored, recorder != nil else { return }
        mapAlignmentAssessment = aligned
        if !aligned { mapAlignmentSuspect = true; setContentVisible(false) }
        recorder?.append("events.jsonl", ["event": "world_map_alignment_assessed", "map_id": map.metadata.map_id,
            "aligned": aligned, "source": "human_observation", "numeric_accuracy_measured": false])
        instructionLabel.text = aligned ? "已记录你对 A、B 对齐的确认。继续正常走动，再结束并导出测试包。" : "已记录错位反馈，路线已隐藏。结束并导出测试包后重新加载地图。"
    }

    private func markMapAlignmentSuspect(_ message: String, event: String) {
        guard restoreGate?.state == .restored, !mapAlignmentSuspect else { return }
        mapAlignmentSuspect = true; mapAlignmentAssessment = nil; previousMapPose = nil
        setContentVisible(false)
        recorder?.append("events.jsonl", ["event": event, "reason": message])
        instructionLabel.text = message
    }

    private func chooseMapExport(_ maps: [SavedWorldMap]) {
        if maps.count == 1 { exportWorldMap(maps[0]); return }
        let sheet = UIAlertController(title: "选择要分享的地图", message: "环境文件仅供 iOS 使用；route.json 是独立的通用路线数据。", preferredStyle: .actionSheet)
        for package in maps.prefix(12) {
            sheet.addAction(UIAlertAction(title: package.metadata.name, style: .default) { [weak self] _ in self?.exportWorldMap(package) })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = mapButton; sheet.popoverPresentationController?.sourceRect = mapButton.bounds
        present(sheet, animated: true)
    }

    private func exportWorldMap(_ package: SavedWorldMap) {
        guard recorder == nil, !mapBusy, !exportBusy else { return }
        exportBusy = true; instructionLabel.text = "正在校验并打包地图…"; refreshButtons()
        worldMapStore.export(package) { [weak self] result in
            guard let self else { return }; self.exportBusy = false; self.refreshButtons()
            switch result {
            case .failure(let error): self.showError("地图导出失败", error.localizedDescription)
            case .success(let url):
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = self.mapButton; share.popoverPresentationController?.sourceRect = self.mapButton.bounds
                self.present(share, animated: true)
            }
        }
    }

    @objc private func settingsTapped() {
        let sheet = UIAlertController(title: "验证设置", message: "本地测试路线不代表建筑中的真实导航路线。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: diagnosticsVisible ? "隐藏诊断数据" : "显示诊断数据", style: .default) { [weak self] _ in
            guard let self else { return }; self.diagnosticsVisible.toggle(); self.diagnosticLabel.isHidden = !self.diagnosticsVisible
        })
        if recorder == nil && !finishing {
            if restoredMap == nil { sheet.addAction(UIAlertAction(title: "调整路线长度", style: .default) { [weak self] _ in self?.editLengths() }) }
            sheet.addAction(UIAlertAction(title: "重启 AR 会话并清除路线", style: .default) { [weak self] _ in self?.startSession(reset: true) })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = settingsButton
        sheet.popoverPresentationController?.sourceRect = settingsButton.bounds
        present(sheet, animated: true)
    }
    private func editLengths() {
        let alert = UIAlertController(title: "测试路线尺寸", message: "按现场可通行空间设置，单位米，范围 0.5～10。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "前进段"; $0.text = String(self.forwardLength); $0.keyboardType = .decimalPad }
        alert.addTextField { $0.placeholder = "转弯段"; $0.text = String(self.turnLength); $0.keyboardType = .decimalPad }
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields,
                  let a = Double(fields[0].text ?? ""), let b = Double(fields[1].text ?? ""),
                  a.isFinite, b.isFinite, (0.5...10).contains(a), (0.5...10).contains(b) else { return }
            self.forwardLength = a; self.turnLength = b
            if self.routeEntity != nil { self.rebuildRoute() }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel)); present(alert, animated: true)
    }

    @objc private func exportTapped() {
        let runs = ProbeIO.existingRuns()
        guard !runs.isEmpty, recorder == nil, !exportBusy else { return }
        if runs.count == 1 { export(runs[0]); return }
        let sheet = UIAlertController(title: "选择测试记录", message: "未正常结束的记录也保留，可导出排查。", preferredStyle: .actionSheet)
        for run in runs.prefix(12) { sheet.addAction(UIAlertAction(title: run.lastPathComponent, style: .default) { [weak self] _ in self?.export(run) }) }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = exportButton; sheet.popoverPresentationController?.sourceRect = exportButton.bounds
        present(sheet, animated: true)
    }
    private func export(_ run: URL) {
        exportBusy = true; instructionLabel.text = "正在校验文件并生成 ZIP，请稍候…"; refreshButtons()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try ProbeIO.makeManifest(at: run)
                let zip = ProbeIO.documents.appendingPathComponent("Exports").appendingPathComponent(run.lastPathComponent + ".zip")
                try ProbeZip.create(directory: run, destination: zip)
                DispatchQueue.main.async {
                    guard let self else { return }; self.exportBusy = false; self.refreshButtons()
                    let share = UIActivityViewController(activityItems: [zip], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.exportButton
                    share.popoverPresentationController?.sourceRect = self.exportButton.bounds
                    share.completionWithItemsHandler = { [weak self] _, completed, _, error in
                        self?.instructionLabel.text = error != nil ? "分享发生错误，ZIP 仍保留在本机。" : completed ? "系统分享已完成，请在电脑打开 ZIP 确认数据完整。" : "分享已取消，原记录与 ZIP 仍保留在本机。"
                    }
                    self.present(share, animated: true)
                }
            } catch { DispatchQueue.main.async { self?.exportBusy = false; self?.refreshButtons(); self?.showError("导出失败", error.localizedDescription) } }
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default)); present(alert, animated: true)
    }
}

#endif
