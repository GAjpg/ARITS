import UIKit
import SceneKit
import simd

/// Desktop / Simulator workflow preview. No ARSession, camera, or measured pose.
@MainActor
final class PreviewViewController: UIViewController, UIDocumentPickerDelegate {
    private let sceneView = SCNView()
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let routeNode = SCNNode()
    private let originNode = SCNNode()
    private var hasOrigin = false
    private var hasDirection = false
    private var trackingAvailable = true
    private var routeKind: RouteKind = .right
    private var forwardLength = 2.0
    private var turnLength = 2.0
    private var points: [ProbePoint] = []
    private var sessionID = "preview-" + UUID().uuidString
    private var recorder: RunRecorder?
    private var timer: Timer?
    private var saving = false
    private var finishing = false
    private var exportBusy = false
    private var capturedCount = 0
    private var lastAutoCapture = 0.0
    private var lastRunURL: URL?
    private let startedClock = ProcessInfo.processInfo.systemUptime

    private let statusLabel = UILabel()
    private let messageLabel = UILabel()
    private let cameraLabel = UILabel()
    private let stepLabel = UILabel()
    private let originButton = UIButton(type: .system)
    private let directionButton = UIButton(type: .system)
    private let recordButton = UIButton(type: .system)
    private let captureButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let historyButton = UIButton(type: .system)
    private let reportButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let trackingButton = UIButton(type: .system)
    private let routeControl = UISegmentedControl(items: RouteKind.allCases.map { $0.title })
    private let forwardStepper = UIStepper()
    private let turnStepper = UIStepper()
    private let lengthLabel = UILabel()
    private let progressSlider = UISlider()
    private let yawSlider = UISlider()
    private let autoSwitch = UISwitch()
    private let contentStack = UIStackView()
    private var sidebarWidth: NSLayoutConstraint?
    private var compactSceneHeight: NSLayoutConstraint?
    private var compactLayout: Bool?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.10, alpha: 1)
        overrideUserInterfaceStyle = .dark
        buildScene()
        buildInterface()
        lastRunURL = ProbeIO.existingRuns(at: ProbeIO.previewRuns).first
        updateCamera()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        if ProcessInfo.processInfo.arguments.contains("--preview-smoke-test") {
            // Explicit opt-in for automated desktop workflow checks only.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runSmokeTest() }
        }
    }

    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = view.bounds.width < 760
        guard compactLayout != compact else { return }
        compactLayout = compact
        sidebarWidth?.isActive = !compact
        compactSceneHeight?.isActive = compact
        contentStack.axis = compact ? .vertical : .horizontal
    }
    private var clock: Double { ProcessInfo.processInfo.systemUptime - startedClock }

    private func box(_ width: CGFloat, _ height: CGFloat, _ depth: CGFloat, color: UIColor,
                     at position: SCNVector3, parent: SCNNode? = nil) -> SCNNode {
        let geometry = SCNBox(width: width, height: height, length: depth, chamferRadius: 0.015)
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.roughness.contents = 0.85
        let node = SCNNode(geometry: geometry); node.position = position
        (parent ?? scene.rootNode).addChildNode(node)
        return node
    }

    private func buildScene() {
        sceneView.scene = scene; sceneView.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.17, alpha: 1)
        sceneView.antialiasingMode = .multisampling4X
        sceneView.autoenablesDefaultLighting = false
        sceneView.isPlaying = false
        sceneView.allowsCameraControl = false
        let camera = SCNCamera(); camera.fieldOfView = 64; camera.projectionDirection = .vertical
        camera.zNear = 0.05; camera.zFar = 80
        cameraNode.camera = camera; scene.rootNode.addChildNode(cameraNode); sceneView.pointOfView = cameraNode
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 650; scene.rootNode.addChildNode(ambient)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni
        light.light?.intensity = 1100; light.position = SCNVector3(0, 4, -2); scene.rootNode.addChildNode(light)
        let floor = UIColor(red: 0.36, green: 0.43, blue: 0.48, alpha: 1)
        let wall = UIColor(red: 0.65, green: 0.71, blue: 0.73, alpha: 1)
        _ = box(3.6, 0.12, 8, color: floor, at: SCNVector3(0, -0.08, -1.5))
        _ = box(11, 0.12, 3.6, color: floor, at: SCNVector3(0, -0.08, -2.6))
        for x: Float in [-1.85, 1.85] {
            _ = box(0.12, 2.6, 3.3, color: wall, at: SCNVector3(x, 1.3, 0.85))
            for z: Float in [1.5, 0.1] {
                _ = box(0.04, 2.05, 0.85, color: UIColor(red: 0.13, green: 0.22, blue: 0.29, alpha: 1),
                        at: SCNVector3(x > 0 ? 1.77 : -1.77, 1.025, z))
            }
        }
        _ = box(11, 2.6, 0.12, color: wall, at: SCNVector3(0, 1.3, -4.45))
        for z in stride(from: Float(2), through: -7, by: -0.5) {
            _ = box(3.5, 0.002, 0.012, color: .darkGray, at: SCNVector3(0, -0.014, z))
        }
        for x in stride(from: Float(-1.5), through: 1.5, by: 0.5) {
            _ = box(0.012, 0.002, 8, color: .darkGray, at: SCNVector3(x, -0.014, -1.5))
        }
        scene.rootNode.addChildNode(routeNode); scene.rootNode.addChildNode(originNode)
        let disc = SCNCylinder(radius: 0.14, height: 0.018)
        disc.firstMaterial?.diffuse.contents = UIColor.systemYellow
        originNode.geometry = disc; originNode.position.y = 0.015; originNode.isHidden = true
    }

    private func label(_ text: String, size: CGFloat = 14, color: UIColor = .white, bold: Bool = false) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0; label.textColor = color
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return label
    }
    private func column(_ children: [UIView], spacing: CGFloat = 10) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: children); stack.axis = .vertical; stack.spacing = spacing
        return stack
    }
    private func row(_ children: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: children); stack.axis = .horizontal
        stack.spacing = 8; stack.alignment = .center; stack.distribution = .fillEqually; return stack
    }
    private func configure(_ button: UIButton, _ title: String, _ action: Selector, accent: Bool = false) {
        var config = UIButton.Configuration.filled(); config.title = title; config.cornerStyle = .medium
        config.baseBackgroundColor = accent ? .systemMint : UIColor(red: 0.16, green: 0.21, blue: 0.27, alpha: 1)
        config.baseForegroundColor = accent ? .black : .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        button.configuration = config; button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }

    private func buildInterface() {
        let header = column([
            label("走廊导航 · 功能预览", size: 25, bold: true),
            label("模拟预览  /  AR 关闭  /  合成图片与姿态", size: 13, color: .systemOrange, bold: true)
        ], spacing: 5)
        header.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(header)
        let sceneContainer = UIView(); sceneContainer.layer.cornerRadius = 18; sceneContainer.clipsToBounds = true
        sceneView.translatesAutoresizingMaskIntoConstraints = false; sceneContainer.addSubview(sceneView)
        NSLayoutConstraint.activate([sceneView.leadingAnchor.constraint(equalTo: sceneContainer.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: sceneContainer.trailingAnchor), sceneView.topAnchor.constraint(equalTo: sceneContainer.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: sceneContainer.bottomAnchor)])
        let bottom = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        bottom.translatesAutoresizingMaskIntoConstraints = false; sceneContainer.addSubview(bottom)
        stepLabel.numberOfLines = 0; stepLabel.textColor = .white; stepLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        cameraLabel.numberOfLines = 0; cameraLabel.textColor = .lightGray; cameraLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let overlay = column([stepLabel, cameraLabel], spacing: 6); overlay.translatesAutoresizingMaskIntoConstraints = false
        bottom.contentView.addSubview(overlay)
        NSLayoutConstraint.activate([bottom.leadingAnchor.constraint(equalTo: sceneContainer.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: sceneContainer.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: sceneContainer.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: bottom.contentView.leadingAnchor, constant: 18),
            overlay.trailingAnchor.constraint(equalTo: bottom.contentView.trailingAnchor, constant: -18),
            overlay.topAnchor.constraint(equalTo: bottom.contentView.topAnchor, constant: 14), overlay.bottomAnchor.constraint(equalTo: bottom.contentView.bottomAnchor, constant: -14)])

        configure(originButton, "设模拟起点", #selector(originTapped))
        configure(directionButton, "设模拟方向", #selector(directionTapped))
        configure(recordButton, "开始记录", #selector(recordTapped), accent: true)
        configure(captureButton, "保存模拟帧", #selector(captureTapped))
        configure(exportButton, "导出 ZIP", #selector(exportTapped))
        configure(reportButton, "查看记录", #selector(reportTapped))
        configure(historyButton, "历史记录", #selector(historyTapped))
        configure(resetButton, "重置预览", #selector(resetTapped))
        configure(trackingButton, "模拟跟踪丢失", #selector(trackingTapped))
        routeControl.selectedSegmentIndex = 3; routeControl.selectedSegmentTintColor = .systemMint
        routeControl.addTarget(self, action: #selector(routeChanged), for: .valueChanged)
        routeControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        for stepper in [forwardStepper, turnStepper] {
            stepper.minimumValue = 0.5; stepper.maximumValue = 10; stepper.stepValue = 0.5; stepper.value = 2
            stepper.addTarget(self, action: #selector(lengthChanged), for: .valueChanged)
        }
        lengthLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let forwardRow = row([label("前进长度"), forwardStepper]); forwardRow.distribution = .fill
        let turnRow = row([label("转弯长度"), turnStepper]); turnRow.distribution = .fill
        progressSlider.minimumValue = 0; progressSlider.maximumValue = 1
        yawSlider.minimumValue = -110; yawSlider.maximumValue = 110
        for slider in [progressSlider, yawSlider] {
            slider.tintColor = .systemMint; slider.addTarget(self, action: #selector(cameraChanged), for: .valueChanged)
        }
        autoSwitch.onTintColor = .systemMint
        autoSwitch.addTarget(self, action: #selector(autoChanged), for: .valueChanged)
        let autoRow = row([label("每 8 秒保存模拟帧", size: 13), autoSwitch]); autoRow.distribution = .fill
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold); statusLabel.textColor = .systemMint; statusLabel.numberOfLines = 0
        messageLabel.text = "先设起点和方向，再开始记录。"; messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 12); messageLabel.textColor = .lightGray
        let controls = column([
            label("01  放置测试路线", size: 16, bold: true), row([originButton, directionButton]), routeControl,
            forwardRow, turnRow, lengthLabel,
            label("02  改变模拟视角", size: 16, bold: true), label("沿路线移动", size: 12, color: .lightGray), progressSlider,
            label("左右转头", size: 12, color: .lightGray), yawSlider, trackingButton,
            label("03  记录与导出", size: 16, bold: true), statusLabel, row([recordButton, captureButton]), autoRow,
            row([exportButton, reportButton]), row([historyButton, resetButton]), messageLabel,
            label("图片含虚拟路线与模拟水印。此模式只验证程序流程，不能判断定位精度或地面稳定性。", size: 11, color: .systemOrange)
        ], spacing: 9)
        let scroll = UIScrollView(); scroll.alwaysBounceVertical = true
        controls.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(controls)
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            controls.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            controls.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16)])
        let content = contentStack
        content.addArrangedSubview(sceneContainer); content.addArrangedSubview(scroll); content.axis = .horizontal; content.spacing = 20
        sidebarWidth = scroll.widthAnchor.constraint(equalToConstant: 340)
        compactSceneHeight = sceneContainer.heightAnchor.constraint(equalToConstant: 220)
        content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: header.leadingAnchor), content.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            sidebarWidth!])
    }

    private func refresh() {
        let recording = recorder != nil
        let locked = recording || finishing || exportBusy
        originButton.isEnabled = !locked; directionButton.isEnabled = hasOrigin && !locked
        routeControl.isEnabled = !locked; forwardStepper.isEnabled = !locked; turnStepper.isEnabled = !locked
        resetButton.isEnabled = !locked; trackingButton.isEnabled = !finishing
        recordButton.isEnabled = !finishing && !saving && !exportBusy && (recording || (hasDirection && trackingAvailable))
        recordButton.configuration?.title = finishing ? "正在结束…" : recording ? "结束记录" : "开始记录"
        captureButton.isEnabled = recording && trackingAvailable && !saving && !finishing
        exportButton.isEnabled = lastRunURL != nil && !locked
        historyButton.isEnabled = !locked; reportButton.isEnabled = lastRunURL != nil && !locked
        trackingButton.configuration?.title = trackingAvailable ? "模拟跟踪丢失" : "恢复模拟跟踪"
        routeNode.isHidden = !hasDirection || !trackingAvailable
        originNode.isHidden = !hasOrigin || !trackingAvailable
        lengthLabel.text = String(format: "前进 %.1f m  /  转弯 %.1f m（模拟）", forwardLength, turnLength)
        statusLabel.text = finishing ? "正在提交文件…" : recording ? "正在记录 · 已保存 \(capturedCount) 帧" : "待机 · \(lastRunURL == nil ? "暂无记录" : "已有可导出记录")"
        if !trackingAvailable { stepLabel.text = "模拟跟踪丢失：隐藏路线并暂停采图" }
        else if !hasOrigin { stepLabel.text = "第一步：点击「设模拟起点」" }
        else if !hasDirection { stepLabel.text = "第二步：点击「设模拟方向」" }
        else { stepLabel.text = "\(routeKind.title)路线 · 拖动右侧滑块改变视角" }
    }

    @objc private func originTapped() {
        hasOrigin = true; hasDirection = false
        messageLabel.text = "模拟起点固定在走廊地面 (0, 0, 0)。"; refresh()
    }
    @objc private func directionTapped() {
        hasDirection = true; rebuildRoute(); messageLabel.text = "方向设为沿当前走廊向前。可以切换路线。"; refresh()
    }
    @objc private func routeChanged() { routeKind = RouteKind.allCases[routeControl.selectedSegmentIndex]; rebuildRoute(); refresh() }
    @objc private func lengthChanged() {
        forwardLength = forwardStepper.value; turnLength = turnStepper.value; rebuildRoute(); refresh()
    }

    private func rebuildRoute() {
        routeNode.childNodes.forEach { $0.removeFromParentNode() }
        points = ProbeGeometry.route(routeKind, forward: forwardLength, turn: turnLength)
        guard hasDirection else { return }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dx = b.x - a.x, dz = b.z - a.z, length = hypot(dx, dz)
            let strip = box(0.19, 0.025, CGFloat(length), color: .systemMint,
                            at: SCNVector3(Float((a.x + b.x)/2), 0.03, Float((a.z + b.z)/2)), parent: routeNode)
            strip.eulerAngles.y = Float(atan2(dx, dz))
            let repetitions = max(1, Int(length / 0.75))
            for step in 1...repetitions {
                let fraction = min(0.92, Double(step) / Double(repetitions + 1))
                addChevron(x: a.x + dx * fraction, z: a.z + dz * fraction, dx: dx/length, dz: dz/length)
            }
        }
        updateCamera()
    }
    private func addChevron(x: Double, z: Double, dx: Double, dz: Double) {
        let tip = SIMD3<Double>(x + dx * 0.16, 0.058, z + dz * 0.16)
        for side: Double in [-1, 1] {
            let end = SIMD3<Double>(x - dx * 0.13 + dz * side * 0.16, 0.058, z - dz * 0.13 - dx * side * 0.16)
            let delta = end - tip
            let arm = box(0.055, 0.012, CGFloat(simd_length(delta)), color: .white,
                          at: SCNVector3(Float((tip.x + end.x)/2), 0.058, Float((tip.z + end.z)/2)), parent: routeNode)
            arm.eulerAngles.y = Float(atan2(delta.x, delta.z))
        }
    }
    @objc private func cameraChanged() { updateCamera() }
    private func updateCamera() {
        let route = points.count >= 2 ? points : ProbeGeometry.route(.right, forward: forwardLength, turn: turnLength)
        let lengths = (1..<route.count).map { hypot(route[$0].x - route[$0 - 1].x, route[$0].z - route[$0 - 1].z) }
        var distance = Double(progressSlider.value) * lengths.reduce(0, +)
        var target = route[0]; var baseYaw: Double = 0
        for index in 0..<lengths.count {
            let a = route[index], b = route[index + 1]
            let part = min(1, distance / max(0.001, lengths[index]))
            target = ProbePoint(a.x + (b.x - a.x)*part, 0, a.z + (b.z - a.z)*part)
            baseYaw = -atan2(b.x - a.x, -(b.z - a.z))
            if distance <= lengths[index] { break }; distance -= lengths[index]
        }
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        cameraNode.position = SCNVector3(Float(target.x), 1.55, Float(target.z) + (progressSlider.value == 0 ? 1.2 : 0))
        cameraNode.eulerAngles = SCNVector3(-0.35, Float(baseYaw) + yawSlider.value * .pi/180, 0)
        SCNTransaction.commit()
        cameraLabel.text = String(format: "合成相机  x %.2f  y 1.55  z %.2f\n路线进度 %.0f%% · 转头 %.0f°", cameraNode.position.x, cameraNode.position.z, progressSlider.value*100, yawSlider.value)
        sceneView.setNeedsDisplay()
    }
    @objc private func trackingTapped() {
        trackingAvailable.toggle(); recorder?.append("events.jsonl", ["event": "simulated_tracking_changed", "timestamp": clock, "available": trackingAvailable])
        messageLabel.text = trackingAvailable ? "模拟跟踪恢复，路线重新显示。" : "已模拟跟踪丢失；不会生成有效 AR 测量。"; refresh()
    }
    @objc private func resetTapped() {
        sessionID = "preview-" + UUID().uuidString; hasOrigin = false; hasDirection = false
        trackingAvailable = true; progressSlider.value = 0; yawSlider.value = 0
        routeNode.childNodes.forEach { $0.removeFromParentNode() }; points = []
        updateCamera(); messageLabel.text = "预览已重置，历史记录保留。"; refresh()
    }

    private var routeMetadata: [String: Any] {
        ["kind": routeKind.rawValue, "forward_m": forwardLength, "turn_m": turnLength,
         "test_points_session": points.enumerated().map { ["id": "P\($0.offset)", "session": $0.element.array] as [String: Any] }]
    }
    @objc private func recordTapped() {
        if recorder != nil { finishRecording(); return }
        do {
            #if targetEnvironment(macCatalyst)
            let platform = "macOS_Mac_Catalyst"
            #else
            let platform = "iOS_Simulator"
            #endif
            let recorder = try RunRecorder(sessionID: sessionID, configuration: ["route": routeMetadata, "auto_capture_seconds": 8],
                                           device: ["platform": platform, "simulation": true], rootDirectory: ProbeIO.previewRuns, dataMode: .simulation)
            recorder.onFailure = { [weak self] error in self?.messageLabel.text = "保存出错：" + error }
            self.recorder = recorder; capturedCount = 0; lastAutoCapture = clock
            recorder.append("anchors.jsonl", ["timestamp": clock, "event": "synthetic_origin", "matrix": matrixRows(matrix_identity_float4x4)])
            messageLabel.text = "已开始模拟记录。拖动视角并保存几帧。"; refresh()
        } catch { showError(error) }
    }
    private func finishRecording(completion: (() -> Void)? = nil) {
        guard let recorder, !saving, !finishing else { return }
        finishing = true; refresh()
        recorder.append("events.jsonl", ["event": "recording_ended", "timestamp": clock])
        recorder.finish(statistics: ["simulation": true, "performance_measures_real_ar": false]) { [weak self] result in
            guard let self else { return }; self.finishing = false; self.recorder = nil
            switch result {
            case .success(let url): self.lastRunURL = url; self.messageLabel.text = "记录已结束。可查看文件或导出 ZIP。"
            case .failure(let error): self.showError(error)
            }
            self.refresh(); completion?()
        }
    }
    @objc private func autoChanged() {
        lastAutoCapture = clock
        recorder?.append("events.jsonl", ["event": "auto_capture_changed", "timestamp": clock, "enabled": autoSwitch.isOn])
    }
    private func tick() {
        guard let recorder, !finishing else { return }
        recorder.append("poses.jsonl", ["timestamp": clock, "matrix": matrixRows(cameraNode.simdWorldTransform),
                                       "tracking": trackingAvailable ? "simulated_tracking" : "simulated_not_available", "data_kind": "simulation"])
        if trackingAvailable && autoSwitch.isOn && !saving && clock - lastAutoCapture >= 8 {
            lastAutoCapture = clock; capture(reason: "automatic_simulation")
        }
    }
    @objc private func captureTapped() { capture(reason: "manual_simulation") }
    private func capture(reason: String, completion: (() -> Void)? = nil) {
        guard let recorder, !saving, !finishing, trackingAvailable else { return }
        saving = true; refresh()
        let frameID = recorder.newFrameID(), timestamp = clock
        let matrix = matrixRows(cameraNode.simdWorldTransform)
        let snapshot = sceneView.snapshot()
        let width = max(2, Int(min(1200, snapshot.size.width))), height = max(2, Int(Double(width)*snapshot.size.height/max(1, snapshot.size.width)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            snapshot.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.withAlphaComponent(0.8).setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: 44))
            ("SIMULATION / 模拟图像 · 非实拍" as NSString).draw(at: CGPoint(x: 14, y: 11),
                withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: UIColor.systemOrange])
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            saving = false; refresh(); messageLabel.text = "模拟图像编码失败"; completion?(); return
        }
        let focal = Double(height)/2/tan(64 * .pi/360)
        let frame: [String: Any] = [
            "schema_version": 1, "run_id": recorder.runID, "session_id": sessionID, "frame_id": frameID,
            "data_kind": "simulation", "simulation": true, "is_real_ar_capture": false,
            "image": ["path": "frames/\(frameID).jpg", "source_width": width, "source_height": height,
                      "saved_width": width, "saved_height": height, "rotation_deg": 0, "mirrored": false,
                      "conversion": "SceneKit_snapshot_with_virtual_route_and_SIMULATION_watermark"],
            "intrinsics": ["reference_width": width, "reference_height": height, "fx": focal, "fy": focal,
                           "cx": Double(width)/2, "cy": Double(height)/2, "source": "synthetic_camera_FOV_not_calibrated"],
            "timing": ["simulation_timestamp_seconds": timestamp, "clock_domain": "process_uptime_preview",
                       "pose_association": "synthetic_scene_snapshot", "reason": reason],
            "pose": ["coordinate_system": "arkit_right_handed_y_up_camera_forward_minus_z", "direction": "camera_to_session", "matrix": matrix],
            "tracking": ["camera": "simulated_tracking"], "route": routeMetadata,
            "validity": ["image_saved": true, "intrinsics_available": true, "intrinsics_dimensions_match": true,
                         "image_geometry_verified": false, "ready_for_visual_localization_query": false, "ready_for_ar_alignment": false]
        ]
        recorder.append("camera-events.jsonl", ["timestamp": timestamp, "frame_id": frameID, "event": "synthetic_snapshot"])
        recorder.commit(image: jpeg, frame: frame, frameID: frameID) { [weak self] result in
            guard let self else { return }; self.saving = false
            switch result {
            case .success: self.capturedCount += 1; self.messageLabel.text = "已保存 \(frameID)（模拟图片和 JSON）。"
            case .failure(let error): self.showError(error)
            }
            self.refresh(); completion?()
        }
    }

    @objc private func exportTapped() {
        guard let run = lastRunURL else { return }
        makeArchive(run) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let zip):
                let picker = UIDocumentPickerViewController(forExporting: [zip], asCopy: true)
                picker.delegate = self; picker.shouldShowFileExtensions = true
                self.present(picker, animated: true)
                self.messageLabel.text = "请选择 ZIP 保存位置。所有数据标记为模拟。"
            case .failure(let error): self.showError(error)
            }
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        messageLabel.text = "ZIP 已保存：" + (urls.first?.lastPathComponent ?? "模拟测试包")
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        messageLabel.text = "已取消另存；已生成的 ZIP 和历史记录仍保留。"
    }
    private func makeArchive(_ run: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        exportBusy = true; refresh()
        let folder = ProbeIO.previewRoot.appendingPathComponent("PreviewExports", isDirectory: true)
        let zip = folder.appendingPathComponent(run.lastPathComponent + ".zip")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<URL, Error> {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ProbeZip.create(directory: run, destination: zip); return zip
            }
            DispatchQueue.main.async { [weak self] in self?.exportBusy = false; self?.refresh(); completion(result) }
        }
    }
    @objc private func historyTapped() {
        let runs = ProbeIO.existingRuns(at: ProbeIO.previewRuns)
        let alert = UIAlertController(title: "模拟历史记录", message: runs.isEmpty ? "还没有记录。" : "选择记录后可查看或导出。", preferredStyle: .alert)
        for url in runs.prefix(8) {
            alert.addAction(UIAlertAction(title: url.lastPathComponent, style: .default) { [weak self] _ in
                self?.lastRunURL = url; self?.messageLabel.text = "已选择 " + url.lastPathComponent; self?.refresh(); self?.reportTapped()
            })
        }
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel)); present(alert, animated: true)
    }
    @objc private func reportTapped() {
        guard let run = lastRunURL else { return }
        let controller = UIViewController(); controller.title = "模拟记录详情"; controller.view.backgroundColor = .systemBackground
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(scroll)
        let summary = (try? String(contentsOf: run.appendingPathComponent("summary.json"), encoding: .utf8)) ?? "此记录尚未正常结束。"
        let files = (try? FileManager.default.contentsOfDirectory(at: run.appendingPathComponent("frames"), includingPropertiesForKeys: nil)) ?? []
        let photos = files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items: [UIView] = [label("模拟数据 · 不适用于定位精度验收", size: 18, color: .systemOrange, bold: true),
            label(run.lastPathComponent, size: 13), label("已保存 \(photos.count) 张模拟图像\n\n\(summary)", size: 13, color: .secondaryLabel),
            label("保存目录\n" + run.path, size: 12, color: .secondaryLabel)]
        for url in photos.prefix(12) {
            if let image = UIImage(contentsOfFile: url.path) {
                let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit
                imageView.heightAnchor.constraint(equalToConstant: 240).isActive = true
                items.append(imageView); items.append(label(url.lastPathComponent, size: 12, color: .secondaryLabel))
            }
        }
        let stack = column(items, spacing: 14); stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)])
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "关闭", primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) })
        let navigation = UINavigationController(rootViewController: controller); navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }
    @objc private func backgrounded() {
        autoSwitch.isOn = false
        recorder?.append("events.jsonl", ["event": "preview_backgrounded", "timestamp": clock])
    }
    private func showError(_ error: Error) {
        messageLabel.text = "操作失败：" + error.localizedDescription
        let alert = UIAlertController(title: "操作未完成", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default)); present(alert, animated: true)
    }

    // Exercises the actual snapshot -> recorder -> manifest -> ZIP path on Mac.
    private func runSmokeTest(index: Int = 0) {
        if index == 0 { originTapped(); directionTapped(); recordTapped() }
        guard recorder != nil else { return }
        if index == 10 {
            finishRecording { [weak self] in
                guard let self, let run = self.lastRunURL else { return }
                self.makeArchive(run) { result in
                    if case .success(let zip) = result { self.messageLabel.text = "自动流程检查完成：10 帧模拟数据已打包。"; print("PREVIEW_SMOKE_ZIP=" + zip.path) }
                }
            }
            return
        }
        progressSlider.value = Float(index)/12; yawSlider.value = Float(index % 3 - 1)*15; updateCamera()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.capture(reason: "automated_desktop_smoke_test") { [weak self] in self?.runSmokeTest(index: index + 1) }
        }
    }
}
