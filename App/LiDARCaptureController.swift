#if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import UIKit
import ARKit
import RealityKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Each controller owns a fresh ARSession. In particular query capture has no
/// path that loads CampusARStore, ARWorldMap, route nodes or previous transforms.
final class LiDARCaptureController: UIViewController, ARSessionDelegate {
    static var supported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    var onSaved: (() -> Void)?
    private let info: LiDARScanManifest
    private let scene = ARView(frame:.zero,cameraMode:.ar,automaticallyConfigureSession:false)
    private let status = UILabel(), instruction = UILabel(), count = UILabel()
    private let action = UIButton(type:.system), save = UIButton(type:.system)
    private let io = DispatchQueue(label:"lidar.capture.io",qos:.userInitiated)
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var writer: LiDARScanWriter?
    private var running = false, startedSession = false, writing = false, finishing = false, ended = false
    private var frameCount = 0, pointCount = 0, skipped = 0
    private var lastAccepted = -Double.infinity, lastEvent = -Double.infinity
    private var previousTime:Double?, previousPosition:SIMD3<Float>?
    private var unhealthySince:Double?
    private var startTime:Double?, hasDepth = false, normal = false
    private var oldIdleTimer = false
    init(manifest:LiDARScanManifest) { info = manifest;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = info.role.title;view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"结束",style:.plain,target:self,action:#selector(close))
        scene.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(scene)
        NSLayoutConstraint.activate([scene.leadingAnchor.constraint(equalTo:view.leadingAnchor),scene.trailingAnchor.constraint(equalTo:view.trailingAnchor),scene.topAnchor.constraint(equalTo:view.topAnchor),scene.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        let panel = UIVisualEffectView(effect:UIBlurEffect(style:.systemMaterial));panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        for label in [status,instruction,count] { label.numberOfLines = 0 }
        status.font = .preferredFont(forTextStyle:.headline);count.font = .monospacedDigitSystemFont(ofSize:15,weight:.medium)
        instruction.font = .preferredFont(forTextStyle:.subheadline)
        instruction.text = info.role == .map ? "缓慢扫描墙角、门框和固定物体，覆盖不同方向。不要只拍地面。建议先做一个 5–10 米的小区域。" : "从这里重新建立独立坐标。缓慢观察附近结构 5–10 秒，保持在当前小区域；本次不加载旧地图。"
        var cfg = UIButton.Configuration.filled();cfg.baseBackgroundColor = .systemTeal;action.configuration = cfg
        action.setTitle("开始扫描",for:.normal);action.addTarget(self,action:#selector(start),for:.touchUpInside);action.isEnabled = false
        save.configuration = .bordered();save.setTitle("保存并结束",for:.normal);save.addTarget(self,action:#selector(saveScan),for:.touchUpInside);save.isEnabled = false
        let buttons = UIStackView(arrangedSubviews:[action,save]);buttons.axis = .horizontal;buttons.spacing = 12;buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews:[status,count,instruction,buttons]);stack.axis = .vertical;stack.spacing = 10;stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:12),panel.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-12),panel.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-12),stack.leadingAnchor.constraint(equalTo:panel.contentView.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:panel.contentView.trailingAnchor,constant:-14),stack.topAnchor.constraint(equalTo:panel.contentView.topAnchor,constant:14),stack.bottomAnchor.constraint(equalTo:panel.contentView.bottomAnchor,constant:-14)])
        status.text = "正在启动相机…";count.text = "0 / \(info.role.frameLimit) 帧 · 独立会话"
        scene.session.delegate = self;scene.session.delegateQueue = .main
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.didEnterBackgroundNotification,object:nil)
        oldIdleTimer = UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled = true
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated);guard !startedSession else { return };startedSession = true
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: runSession()
        case .notDetermined: AVCaptureDevice.requestAccess(for:.video) { [weak self] granted in
            DispatchQueue.main.async { if granted { self?.runSession() } else { self?.status.text = "请在系统设置中允许相机访问" } }
        }
        default:status.text = "请在系统设置中允许相机访问"
        }
    }
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated);scene.session.pause();UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func runSession() {
        guard Self.supported else { status.text = "当前设备不支持 sceneDepth";return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity;config.frameSemantics = [.sceneDepth]
        config.initialWorldMap = nil
        // No plane smoothing / scene reconstruction: export raw sceneDepth.
        config.planeDetection = [];config.sceneReconstruction = []
        scene.session.run(config,options:[.resetTracking,.removeExistingAnchors])
    }
    @objc private func start() {
        guard normal,hasDepth,!running,!ended,!finishing else { return }
        do { writer = try LiDARScanWriter(root:LiDARLibrary.root,manifest:info) }
        catch { campusError(error);return }
        running = true;startTime = nil;action.isEnabled = false;action.setTitle("正在采集",for:.normal);save.isEnabled = true
        status.text = "扫描中 · 每次最多 \(info.role.frameLimit) 帧"
        event("recording_started",time:ProcessInfo.processInfo.systemUptime,
              details:"thermal_state=\(ProcessInfo.processInfo.thermalState.rawValue); initial_world_map=nil; frame_limit=\(info.role.frameLimit)")
    }
    private func event(_ name:String,time:Double,details:String = "") {
        guard let writer else { return };io.async { try? writer.event(name,timestamp:time,details:details) }
    }
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard !finishing,!ended else { return }
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        hasDepth = frame.sceneDepth?.confidenceMap != nil
        if !running { action.isEnabled = normal && hasDepth;status.text = normal && hasDepth ? "已就绪 · \(info.lighting) · 未加载旧地图" : "等待稳定跟踪和 LiDAR 深度…";return }
        let t = frame.timestamp,p = SIMD3<Float>(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        if let oldT = previousTime,t-oldT > 0.75 {
            event("frame_gap",time:t,details:"相机帧间隔超过 0.75 秒")
            finish(reason:"frame_gap",valid:false);return
        }
        if let oldT = previousTime,let oldP = previousPosition,t > oldT,t-oldT < 0.2,simd_distance(oldP,p) > 0.8 {
            event("pose_jump",time:t,details:"大于 0.8 米的帧间跳变")
            finish(reason:"pose_jump",valid:false);return
        }
        previousTime = t;previousPosition = p
        if startTime == nil { startTime = t }
        let elapsed = t-(startTime ?? t)
        if elapsed > (info.role == .map ? 90 : 20) { finish(reason:"time_limit",valid:true);return }
        guard normal,let depth = frame.sceneDepth,let conf = depth.confidenceMap else {
            status.text = "跟踪或深度暂不可用 · 已暂停取帧"
            if unhealthySince == nil { unhealthySince = t }
            if t-lastEvent > 1 { event("tracking_or_depth_unavailable",time:t,details:"\(frame.camera.trackingState)");lastEvent = t }
            if t-(unhealthySince ?? t) > 3 { finish(reason:"tracking_unavailable_over_3s",valid:false) }
            return
        }
        unhealthySince = nil
        status.text = "扫描中 · \(Int(elapsed)) 秒 · 缓慢转动 / 行走"
        guard t-lastAccepted >= (info.role == .map ? 0.5 : 0.35) else { return }
        guard !writing else { skipped += 1;return }
        let calibration = LiDARCalibration(width:CVPixelBufferGetWidth(depth.depthMap),height:CVPixelBufferGetHeight(depth.depthMap),
            imageWidth:CVPixelBufferGetWidth(frame.capturedImage),imageHeight:CVPixelBufferGetHeight(frame.capturedImage),
            fx:Double(frame.camera.intrinsics[0][0]),fy:Double(frame.camera.intrinsics[1][1]),cx:Double(frame.camera.intrinsics[2][0]),cy:Double(frame.camera.intrinsics[2][1]))
        let image = frame.capturedImage, depthBuffer = depth.depthMap
        let pose = matrixRows(frame.camera.transform), index = frameCount
        let exposure = frame.camera.exposureDuration, offset = Double(frame.camera.exposureOffset)
        guard let writer else { return };writing = true;lastAccepted = t
        io.async { [self] in
            let result = Result { () -> (Int,Double) in
                let packed = try Self.pack(depthBuffer,bytesPerPixel:4,pixelFormat:kCVPixelFormatType_DepthFloat32)
                let confidence = try Self.pack(conf,bytesPerPixel:1,pixelFormat:kCVPixelFormatType_OneComponent8)
                guard CVPixelBufferGetWidth(conf) == calibration.width,CVPixelBufferGetHeight(conf) == calibration.height else { throw LiDARScanError.invalid("深度与置信度尺寸不符") }
                var metadata = LiDARFrame(index:index,timestamp:t,transform:pose,calibration:calibration,validFraction:0,exposureDuration:exposure,exposureOffset:offset)
                let points = try LiDARGeometry.points(depth:packed,confidence:confidence,frame:metadata,pixelStride:4)
                let samples = ((calibration.width+3)/4)*((calibration.height+3)/4)
                metadata.valid_fraction = Double(points.count)/Double(samples)
                guard metadata.valid_fraction >= 0.05 else { return (-1,metadata.valid_fraction) }
                let ci = CIImage(cvPixelBuffer:image)
                guard let jpeg = context.jpegRepresentation(of:ci,colorSpace:CGColorSpaceCreateDeviceRGB(),options:[kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:0.55]) else { throw LiDARScanError.invalid("无法保存相机图片") }
                let count = try writer.append(frame:metadata,depth:packed,confidence:confidence,jpeg:jpeg)
                return (count,metadata.valid_fraction)
            }
            DispatchQueue.main.async { [self] in
                writing = false
                switch result {
                case .success(let (points,fraction)):
                    if points < 0 { status.text = "有效深度不足 5% · 靠近固定结构再扫描";event("low_depth_coverage",time:t);return }
                    frameCount += 1;pointCount = points
                    count.text = "\(frameCount) / \(info.role.frameLimit) 帧 · 有效深度 \(Int(fraction*100))%\n预览 \(pointCount) 点 · 忙时跳过 \(skipped) 帧"
                    if frameCount >= info.role.frameLimit { finish(reason:"frame_limit",valid:true) }
                case .failure(let e):event("write_failed",time:t,details:e.localizedDescription);finish(reason:"write_failed",valid:false)
                }
            }
        }
    }
    private static func pack(_ buffer:CVPixelBuffer,bytesPerPixel:Int,pixelFormat:OSType) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat else { throw LiDARScanError.invalid("不支持的深度像素格式") }
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer),height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw LiDARScanError.invalid("读取深度失败") }
        return try LiDARGeometry.packedRows(Data(bytes:base,count:stride*height),rowBytes:CVPixelBufferGetWidth(buffer)*bytesPerPixel,height:height,stride:stride)
    }
    @objc private func saveScan() { finish(reason:"user_saved",valid:true) }
    @objc private func background() { if running { finish(reason:"app_backgrounded",valid:false) } }
    func sessionWasInterrupted(_ session:ARSession) { if running { finish(reason:"session_interrupted",valid:false) } }
    func session(_ session:ARSession,didFailWithError error:Error) {
        status.text = error.localizedDescription;if running { event("session_error",time:ProcessInfo.processInfo.systemUptime,details:error.localizedDescription);finish(reason:"session_error",valid:false) }
    }
    private func finish(reason:String,valid:Bool) {
        guard !finishing,!ended,let writer else { return }
        running = false;finishing = true;action.isEnabled = false;save.isEnabled = false
        scene.session.pause();status.text = "正在写入点云与校验文件…"
        let summaryTime = ProcessInfo.processInfo.systemUptime
        let summary = "busy_dropped=\(skipped); thermal_state=\(ProcessInfo.processInfo.thermalState.rawValue)"
        io.async { [self] in
            let result = Result { () -> LiDARScanManifest in
                try writer.event("capture_summary",timestamp:summaryTime,details:summary)
                return try writer.finish(reason:reason,valid:valid)
            }
            DispatchQueue.main.async { [self] in
                finishing = false;ended = true;onSaved?()
                switch result {
                case .success(let manifest):
                    status.text = manifest.state == "complete" ? "已保存 · \(manifest.frames.count) 帧" : "已保存中断记录 · \(manifest.frames.count) 帧"
                    instruction.text = manifest.state == "complete" ? "点击左上角结束，回到记录列表导出 ZIP。做下一次查询时会创建全新 AR 会话。" : "本次跟踪中断或不足 3 帧，不能作为有效定位试验。记录仍可导出检查；请重新采集。"
                case .failure(let e):status.text = "保存未完成";campusError(e)
                }
            }
        }
    }
    @objc private func close() {
        guard !finishing else { return }
        if running { finish(reason:"user_ended",valid:true);return }
        dismiss(animated:true)
    }
}
#endif
