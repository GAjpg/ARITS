#if !targetEnvironment(macCatalyst)
import UIKit
import ARKit
import RealityKit
import AVFoundation

final class CampusNetworkARController: UIViewController, ARSessionDelegate {
    private enum Phase { case loading, searching, restoring, check, capture, navigation, stairs, arrived, suspended }
    private var graph: CampusGraph
    private var regionID: String?
    private var localBindings:[CampusBinding] = []
    private var mapID:String?,requestedMapID:String?
    private var mapAttempts:[String] = []
    private var mapAttemptIndex = 0
    private var mapToRegion = CampusMapGeometry.identity
    private var coordinateReady = true
    private var saveTarget = CampusCaptureSaveTarget()
    private let localSupplement:Bool
    private var scanCoverage = CampusSupplementCoverage()
    private var lastCoverageSample = 0.0
    private var connected:[String:[[Double]]] = [:]
    private var handoffGate = CampusStableNavigationGate()
    private var logicalRegionID:String?
    private let destination: CampusDestination?
    private let roomTask:CampusRoomPlacement?
    private var searchStart:CampusStartSelection = .unknown
    private var searchScope:CampusLocalizationScope?
    private var restrictOnRestore = false
    private var roomMarkingEdgeID:String?
    private let supplementLighting:CampusLighting?
    private var captureLighting:CampusLighting = .other
    private var restoreStarted = 0.0,restoreRequestStarted = 0.0,lastRestoreReadiness = 0.0
    private var sdkNormalLogged = false
    private struct GuideChoice { let title:String,nodeID:String,url:URL,date:String }
    private var guideChoices:[GuideChoice] = []
    private var navigationPlan: CampusNavigationPlan?
    private var path: CampusPath? { navigationPlan?.path }
    private let matcher = CampusSceneMatcher()
    private var ranking = false
    private var candidates: [String] = []
    private var candidateIndex = 0
    private var automaticAttempt = false
    private var lastReplan = 0.0
    private var lastNavigationLog = 0.0
    private var lastNavigationUpdate = 0.0
    private var routeProgress:Double?
    private var routeOffset = 0.0
    private var cueKey:String?
    private var cueTurn:CampusRouteGeometry.Turn?
    private var cueGate = CampusStableNavigationGate(),arrivalGate = CampusStableNavigationGate()
    private var replanGate = CampusStableNavigationGate()
    private var returnTarget:CampusLocatedPosition?
    private var routeWarningDistance:Double {
        let value = UserDefaults.standard.double(forKey:"campus.navigation.routeWarningDistance")
        return [3.0,5.0,8.0].contains(value) ? value : 5
    }
    private var routeLookAhead:Double {
        let value = UserDefaults.standard.double(forKey:"campus.navigation.lookAhead")
        return [10.0,20.0,30.0].contains(value) ? value : 20
    }
    private var located: CampusLocatedPosition?
    private var plannedStart:CampusLocatedPosition?
    private var legIndex = 0
    private var phase: Phase = .loading
    private var arView: ARView!
    private let featureOverlay = CampusFeatureOverlay()
    private var savedFeatures:CampusFeaturePointCloud?
    private var lastFeatureDrawing = 0.0
    private var featureDisplay:CampusFeatureDisplay = CampusFeatureDisplay(rawValue:UserDefaults.standard.integer(forKey:"campus.featureDisplay")) ?? .off
    private let config = ARWorldTrackingConfiguration()
    private var currentSession = UUID().uuidString
    private var gate: WorldMapRestoreGate?
    private var observed = Set<String>()
    private var loadToken = UUID()
    private var boundaryTime = 0.0
    private var lastTracking = "not_available"
    private var lastHUD = 0.0
    private var lastDrawing = 0.0
    private var drawKey = ""
    private var lastLog = 0.0
    private var lastPhoto = 0.0
    private var previousPose: (Double,SIMD3<Float>)?
    private var markers: [String: AnchorEntity] = [:]
    private var lines: [AnchorEntity] = []
    private var selected: String?
    private var dirty = false
    private var busy = false
    private var photoBusy = false
    private var background = false
    private var authorized = false
    private var undo: [(CampusGraph,String?,[CampusBinding],Bool)] = []
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("campus-capture-"+UUID().uuidString)
    private var refs: URL { scratch.appendingPathComponent("references") }
    private var views: URL { scratch.appendingPathComponent("views") }
    private var recoveryGuides:URL { scratch.appendingPathComponent("guides") }
    private var viewCount = 0
    private var lastView: (time:Double,position:SIMD3<Float>,forward:SIMD3<Float>)?
    private let status = UILabel(), detail = UILabel(), instruction = UILabel(), reticle = UILabel()
    private let guide = UIImageView()
    private let maneuverIcon = UIImageView()
    private let roomButton = UIButton(type:.system)
    private let addButton = UIButton(type:.system), connectButton = UIButton(type:.system), saveButton = UIButton(type:.system)
    private let advanceButton = UIButton(type:.system),guideCaptureButton = UIButton(type:.system)
    private let replanButton = UIButton(type:.system)
    private var recorder: RunRecorder?
    private let captures = FrameCaptureService()
    private var photoCount = 0
    private let detailedDiagnostics = UserDefaults.standard.bool(forKey:"campus.detailedDiagnostics")
    private var restores = 0
    private var alignmentConfirmed = false
    private var isCapture: Bool { destination == nil }
    private var region: CampusRegion? { regionID.flatMap { graph.region($0) } }
    private var normal: Bool { authorized && !background && lastTracking == "tracking" }
    private var bindings: [CampusBinding] { localBindings }
    init(graph: CampusGraph, regionID: String, roomTask:CampusRoomPlacement? = nil,supplementLighting:CampusLighting? = nil,candidateID:String? = nil,localSupplement:Bool = false,replacingMapID:String? = nil) { self.saveTarget = CampusCaptureSaveTarget(replacing:replacingMapID);self.localSupplement = localSupplement;self.requestedMapID = candidateID;self.graph = graph; self.regionID = regionID; self.roomTask = roomTask;self.supplementLighting = supplementLighting;captureLighting = supplementLighting ?? graph.mapCandidate(replacingMapID)?.lighting ?? .other; destination = nil; switch roomTask { case .add(let eid):roomMarkingEdgeID = eid;case .move(let id):roomMarkingEdgeID = graph.room(id)?.edge_id;case nil:break }; super.init(nibName:nil,bundle:nil) }
    init(graph: CampusGraph, destination: CampusDestination,start:CampusStartSelection,candidateID:String? = nil) { localSupplement = false;self.requestedMapID = candidateID;self.graph = graph; self.destination = destination;roomTask = nil;supplementLighting = nil;searchStart = start; super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        arView = ARView(frame:view.bounds,cameraMode:.ar,automaticallyConfigureSession:false)
        arView.autoresizingMask = [.flexibleWidth,.flexibleHeight]; view.addSubview(arView)
        arView.session.delegate = self; arView.session.delegateQueue = .main
        config.planeDetection = [.horizontal]; config.worldAlignment = .gravity
        featureOverlay.frame = view.bounds;featureOverlay.autoresizingMask = [.flexibleWidth,.flexibleHeight];view.addSubview(featureOverlay)
        applyFeatureDisplay()
        title = isCapture ? (localSupplement ? (saveTarget.createsSubenvironment ? "创建子环境" : "补采子环境") : supplementLighting != nil ? "补采不同光照" : roomTask == nil ? "现场建路网" : "标房间") : "AR 导航"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"返回",style:.plain,target:self,action:#selector(close))
        let moreItem = UIBarButtonItem(title:"更多",style:.plain,target:self,action:#selector(more))
        navigationItem.rightBarButtonItems = isCapture ? [moreItem,UIBarButtonItem(title:"拍照",style:.plain,target:self,action:#selector(captureRecoveryGuide))] : [moreItem]
        buildHUD()
        try? FileManager.default.createDirectory(at:refs,withIntermediateDirectories:true)
        do {
            recorder = try RunRecorder(sessionID:UUID().uuidString,configuration:["campus_network_test":true,"building_id":graph.building_id,"mode":isCapture ? "capture" : "navigation","world_map_test":false,"visual_model_available":false,"scene_retrieval":isCapture || searchStart.directRegionID != nil ? "not_used" : "Vision_feature_print_v2","app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.7.3","start_hint":searchStart.title(in:graph),"navigation_look_ahead_m":routeLookAhead,"diagnostic_recording":detailedDiagnostics ? "detailed" : "light"],device:["platform":"iOS","ios_version":UIDevice.current.systemVersion,"hardware_identifier":ProbeIO.hardwareIdentifier()],rootDirectory:ProbeIO.documents.appendingPathComponent("NetworkTrials"))
            if let recorder {
                try CampusFiles.encode(graph,to:recorder.directory.appendingPathComponent("graph.json"))
                if let path { try CampusFiles.encode(path,to:recorder.directory.appendingPathComponent("path.json")) }
            }
        } catch { instruction.text = "验证日志未能创建：\(error.localizedDescription)" }
        NotificationCenter.default.addObserver(self,selector:#selector(didBackground),name:UIApplication.didEnterBackgroundNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(didForeground),name:UIApplication.didBecomeActiveNotification,object:nil)
        UIApplication.shared.isIdleTimerDisabled = true
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: authorized = true; begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.video) { [weak self] granted in DispatchQueue.main.async { self?.authorized = granted; granted ? self?.begin() : self?.campusMessage("需要相机权限","请在系统设置中开启相机权限。") } }
        default: campusMessage("需要相机权限","请在系统设置中开启相机权限。")
        }
    }
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true || isBeingDismissed { arView.session.pause() }
    }
    deinit { NotificationCenter.default.removeObserver(self); try? FileManager.default.removeItem(at:scratch) }
    private func buildHUD() {
        let top = UIVisualEffectView(effect:UIBlurEffect(style:.systemChromeMaterialDark)); top.layer.cornerRadius = 16; top.clipsToBounds = true
        let bottom = UIVisualEffectView(effect:UIBlurEffect(style:.systemChromeMaterialDark)); bottom.layer.cornerRadius = 18; bottom.clipsToBounds = true
        for p in [top,bottom] { p.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(p) }
        for l in [status,detail,instruction] { l.textColor = .white; l.numberOfLines = 0 }
        status.font = .systemFont(ofSize:19,weight:.bold); detail.font = .systemFont(ofSize:13); instruction.font = .systemFont(ofSize:isCapture ? 15 : 23,weight:.semibold)
        let a = UIStackView(arrangedSubviews:[status,detail]); a.axis = .vertical; a.spacing = 6
        maneuverIcon.contentMode = .scaleAspectFit;maneuverIcon.tintColor = .systemMint;maneuverIcon.isHidden = isCapture
        maneuverIcon.image = UIImage(systemName:"location.fill");maneuverIcon.widthAnchor.constraint(equalToConstant:36).isActive = true
        let topRow = UIStackView(arrangedSubviews:[maneuverIcon,a]);topRow.spacing = 14;topRow.alignment = .center
        topRow.translatesAutoresizingMaskIntoConstraints = false; top.contentView.addSubview(topRow)
        func button(_ b:UIButton,_ title:String,_ action:Selector) { var c = UIButton.Configuration.filled(); c.title = title; c.baseBackgroundColor = .systemTeal; c.baseForegroundColor = .white; c.cornerStyle = .medium; c.contentInsets = .init(top:12,leading:8,bottom:12,trailing:8); b.configuration = c; b.addTarget(self,action:action,for:.touchUpInside) }
        button(addButton,"标点",#selector(add)); button(connectButton,"连线",#selector(connect)); button(roomButton,"房间",#selector(addRoom)); button(saveButton,"保存",#selector(save))
        button(advanceButton,"继续",#selector(advance));button(guideCaptureButton,"拍摄参考照片",#selector(captureRecoveryGuide))
        button(replanButton,"重新规划路线",#selector(replanCurrentLocation))
        if !isCapture { advanceButton.configuration?.baseBackgroundColor = .darkGray;advanceButton.configuration?.image = UIImage(systemName:"list.bullet");advanceButton.configuration?.imagePadding = 8 }
        let row = UIStackView(arrangedSubviews:supplementLighting != nil ? [guideCaptureButton,saveButton] : roomTask == nil ? [addButton,connectButton,roomButton,saveButton] : [roomButton,saveButton]); row.spacing = 8; row.distribution = .fillEqually
        row.isHidden = !isCapture
        let navigationRow = UIStackView(arrangedSubviews:[replanButton,advanceButton]);navigationRow.spacing = 8;navigationRow.distribution = .fillEqually
        let b = UIStackView(arrangedSubviews:[instruction,row,navigationRow]); b.axis = .vertical; b.spacing = 12
        b.translatesAutoresizingMaskIntoConstraints = false; bottom.contentView.addSubview(b)
        for (s,p) in [(topRow,top),(b,bottom)] { NSLayoutConstraint.activate([s.topAnchor.constraint(equalTo:p.contentView.topAnchor,constant:14),s.bottomAnchor.constraint(equalTo:p.contentView.bottomAnchor,constant:-14),s.leadingAnchor.constraint(equalTo:p.contentView.leadingAnchor,constant:14),s.trailingAnchor.constraint(equalTo:p.contentView.trailingAnchor,constant:-14)]) }
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),top.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),top.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),bottom.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-8),bottom.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),bottom.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12)])
        reticle.text = "＋"; reticle.font = .systemFont(ofSize:32,weight:.light); reticle.textColor = .white; reticle.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(reticle)
        NSLayoutConstraint.activate([reticle.centerXAnchor.constraint(equalTo:view.centerXAnchor),reticle.centerYAnchor.constraint(equalTo:view.centerYAnchor,constant:-35)])
        guide.isUserInteractionEnabled = true;guide.addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(chooseReferenceGuide)));guide.contentMode = .scaleAspectFit; guide.backgroundColor = .black; guide.layer.cornerRadius = 10; guide.clipsToBounds = true; guide.translatesAutoresizingMaskIntoConstraints = false; guide.isHidden = true; view.addSubview(guide)
        NSLayoutConstraint.activate([guide.topAnchor.constraint(equalTo:top.bottomAnchor,constant:8),guide.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),guide.widthAnchor.constraint(equalToConstant:110),guide.heightAnchor.constraint(equalToConstant:145)])
    }
    private func log(_ event:String,_ fields:[String:Any] = [:]) {
        var f = fields; f["event"] = event; f["region_id"] = regionID ?? "none"; f["ar_session_id"] = currentSession; f["leg_index"] = legIndex;f["map_candidate_id"] = mapID ?? "none";f["logical_region_id"] = logicalRegionID ?? regionID ?? "none"
        recorder?.append("events.jsonl",f)
    }
    private func showReferenceGuide(_ choice:GuideChoice?) {
        guard let choice,let raw = UIImage(contentsOfFile:choice.url.path),let cg = raw.cgImage else { guide.isHidden = true;return }
        guide.image = UIImage(cgImage:cg,scale:1,orientation:.right);guide.isHidden = false
        guide.accessibilityLabel = "恢复参考画面："+choice.title+"。点击更换，仅作视角提示。"
        log("network_view_guide_shown",["node_id":choice.nodeID,"name":choice.title])
    }
    @objc private func chooseReferenceGuide() {
        guard !guideChoices.isEmpty else { campusMessage("暂无恢复参考视角","恢复现有环境后，在采集页面保存几个看向固定物体的视角，并保存环境更新。");return }
        navigationController?.pushViewController(CampusChoicePicker(title:"恢复参考画面",entries:guideChoices.map { g in .init(title:g.title,detail:g.date.isEmpty ? "旧节点照片" : String(g.date.prefix(10))) { [weak self] in self?.showReferenceGuide(g) } }),animated:true)
    }
    @objc private func captureRecoveryGuide() {
        guard isCapture,phase == .capture,normal,!busy,!photoBusy,!bindings.isEmpty else { campusMessage("先恢复并核对环境","正常跟踪并进入采集后，才可保存恢复视角。");return }
        campusChoices("当前参考画面的光照",choices:CampusLighting.allCases.map { light in (light.title,{ [weak self] in self?.captureLighting = light;self?.chooseGuideNode() }) })
    }
    private func chooseGuideNode() {
        guard let frame = arView.session.currentFrame else { return }
        let camera = frame.camera.transform.columns.3
        let choices = bindings.compactMap { b -> (CampusBinding,Float)? in
            guard let anchor = frame.anchors.first(where:{$0.identifier.uuidString == b.anchor_id}) else { return nil }
            return (b,simd_distance(camera,anchor.transform.columns.3))
        }.sorted { $0.1 < $1.1 }.map { b,d in
            CampusChoicePicker.Entry(title:graph.node(b.node_id).map { graph.nodeLabel($0) } ?? "节点",detail:String(format:"距此节点约 %.1f 米；看向附近固定物体",d)) { [weak self] in self?.saveRecoveryGuide(nodeID:b.node_id) }
        }
        navigationController?.pushViewController(CampusChoicePicker(title:"视角靠近哪个节点？",entries:choices),animated:true)
    }
    private func saveRecoveryGuide(nodeID:String) {
        guard phase == .capture,normal,!busy,!photoBusy,let frame = arView.session.currentFrame,
              let anchor = frame.anchors.first(where:{$0.name == "campus-node/"+nodeID}) else { return }
        let count = ((try? FileManager.default.contentsOfDirectory(at:recoveryGuides,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "json" }.count
        guard count < 192 else { campusMessage("参考视角已达上限","每个环境最多 192 个手动参考视角；已有视角和地图补采仍保留。");return }
        let g = CampusRecoveryGuide(nodeID:nodeID,name:graph.node(nodeID).map { graph.nodeLabel($0) } ?? "节点",lighting:captureLighting,cameraRelativeToNode:matrixRows(simd_inverse(anchor.transform)*frame.camera.transform))
        let ref = WorldMapReferenceFrame(frame:frame),directory = recoveryGuides,token = loadToken
        photoBusy = true;refresh()
        CampusApp.io.async { [weak self] in
            let result = Result { try CampusARStore.writeGuide(ref,guide:g,directory:directory) }
            DispatchQueue.main.async {
                guard let self,self.loadToken == token else { return };self.photoBusy = false
                switch result {
                case .success:self.dirty = true;self.instruction.text = "已记录 \(g.name) 附近的\(g.lighting.title)恢复视角。看向其他方向可继续记录，最后保存环境。";self.log("network_recovery_guide_captured",["guide_id":g.id,"node_id":nodeID,"lighting":g.lighting.rawValue])
                case .failure(let e):self.campusError(e)
                };self.refresh()
            }
        }
    }
    private func begin() {
        guard ARWorldTrackingConfiguration.isSupported else { campusMessage("不支持 AR","请使用支持 ARKit 的真实 iPhone。"); return }
        if isCapture, let region {
            if region.map_saved { loadRegion(region.id) }
            else { coordinateReady = !graph.bindings.contains { $0.region_id == region.id };localBindings = [];currentSession = UUID().uuidString; config.initialWorldMap = nil; arView.session.run(config,options:[.resetTracking,.removeExistingAnchors]); phase = .capture; instruction.text = "首次采集此区域。缓慢扫描固定环境，标记节点并连接路网；至少两个节点后保存。"; refresh() }
        } else { beginSearch() }
    }
    private func beginSearch() {
        guard !isCapture,authorized,!background,!busy else { return }
        do { searchScope = try CampusLocalizationScope.make(graph:graph,start:searchStart) } catch { campusError(error);return }
        if let rid = searchStart.directRegionID { loadRegion(rid,restrictToStart:true);return }
        arView.session.pause();clearScene();guide.isHidden = true;regionID = nil;navigationPlan = nil;located = nil
        phase = .searching;busy = true;ranking = false;loadToken = UUID();let token = loadToken
        currentSession = UUID().uuidString;lastTracking = "not_available";previousPose = nil
        boundaryTime = arView.session.currentFrame?.timestamp ?? 0
        config.initialWorldMap = nil;arView.session.run(config,options:[.resetTracking,.removeExistingAnchors])
        instruction.text = "正在准备起始地附近的环境。缓慢扫描门框、墙面标识和走廊。";refresh()
        let searchBegan = ProcessInfo.processInfo.systemUptime
        matcher.prepare(graph:graph,regionIDs:searchScope?.regionIDs,preferredLighting:CampusLightingSettings.shared.preferredLighting(graph.building_id)) { [weak self] result in
            guard let self,self.loadToken == token else { return };self.busy = false
            switch result {
            case .success(let count):self.log("network_search_prepared",["index_prepare_seconds":ProcessInfo.processInfo.systemUptime-searchBegan,"available_regions":count,"start_hint":self.searchStart.title(in:self.graph),"restricted_regions":Array(self.searchScope?.regionIDs ?? []).sorted()]);self.instruction.text = "起始地：\(self.searchStart.title(in:self.graph))。在范围内搜索 \(count) 个区域；扫描附近环境，无需站到所选点上。"
            case .failure(let e):self.phase = .suspended;self.instruction.text = e.localizedDescription
            };self.refresh()
        }
    }
    private func tryNextCandidate() {
        guard !background else { phase = .suspended;refresh();return }
        guard candidateIndex < candidates.count else { phase = .suspended;instruction.text = "这些待识别区域没有恢复成功。继续扫描固定环境后重新识别，或在更多中选择所在区域重试。";refresh();return }
        let next = candidates[candidateIndex];candidateIndex += 1;loadRegion(next,automatic:true,restrictToStart:true)
    }
    private func restoreTimedOut() {
        log("network_restore_timeout")
        if !isCapture,mapAttemptIndex < mapAttempts.count,let rid = regionID {
            let next = mapAttempts[mapAttemptIndex];mapAttemptIndex += 1
            loadRegion(rid,automatic:automaticAttempt,restrictToStart:restrictOnRestore,candidateID:next)
        } else if automaticAttempt { tryNextCandidate() }
        else { phase = .suspended;instruction.text = "未恢复当前区域，请继续扫描固定环境后重试。";refresh() }
    }
    private func mappedCamera(_ frame:ARFrame) -> simd_float4x4? {
        guard coordinateReady,let binding = bindings.first,let anchor = frame.anchors.first(where:{$0.identifier.uuidString == binding.anchor_id}) else { return nil }
        return matrixFromRows(binding.anchor_to_map)*simd_inverse(anchor.transform)*frame.camera.transform
    }
    private func regionToSession(_ frame:ARFrame) -> simd_float4x4? {
        guard coordinateReady,let b = bindings.first,let anchor = frame.anchors.first(where: { $0.identifier.uuidString == b.anchor_id }) else { return nil }
        return anchor.transform*simd_inverse(matrixFromRows(b.anchor_to_map))
    }
    private var planningGraph:CampusGraph { CampusMapGeometry.navigationGraph(graph,transforms:connected) }
    private func replan(frame:ARFrame,enforceStartScope:Bool = false,positionOverride:CampusLocatedPosition? = nil) throws {
        guard regionID != nil,let destination,let camera = mappedCamera(frame) else { throw CampusError.invalid("尚未恢复当前位置。") }
        let p = camera.columns.3
        let position = try positionOverride ?? CampusMapGeometry.locate(graph:graph,transforms:connected,point:[Double(p.x),Double(p.y),Double(p.z)],allowedRanges:enforceStartScope ? searchScope?.edgeRanges : nil)
        let next = try CampusApp.planner.plan(CampusPlanningRequest(graph:planningGraph,start:position.position,destination:destination))
        navigationPlan = next;located = position;plannedStart = position;legIndex = 0
        returnTarget = position.distance_m > CampusRouteAccess.joinRadius || ((next.path.legs.first?.kind != .walk || connected[next.path.legs.first?.region_id ?? ""] == nil) && position.distance_m > CampusRouteAccess.transferRadius) ? position : nil
        logicalRegionID = position.position.region_id;handoffGate.reset();routeProgress = nil;cueKey = nil;cueTurn = nil;cueGate.reset();arrivalGate.reset();replanGate.reset();drawKey = ""
        if let url = recorder?.directory.appendingPathComponent("path.json") { CampusApp.io.async { try? CampusFiles.encode(next,to:url) } }
        log("network_route_from_current_position",["edge_id":position.position.edge_id,"fraction":position.position.fraction,"snap_distance_m":position.distance_m,"destination_id":destination.id])
    }
    private func routeGeometry() -> CampusRouteGeometry? {
        guard let plan = navigationPlan,let path,legIndex < path.legs.count else { return nil }
        let leg = path.legs[legIndex]
        guard leg.kind == .walk,let rid = leg.region_id,connected[rid] != nil else { return nil }
        let points = leg.node_ids.compactMap { plan.point(nodeID:$0,regionID:rid) }.map { p in ProbePoint(p.map_position[0],p.map_position[1],p.map_position[2]) }
        guard points.count == leg.node_ids.count else { return nil }
        return try? CampusRouteGeometry(points:points)
    }
    private func updateNavigation(_ frame:ARFrame) {
        guard phase == .navigation,alignmentConfirmed,normal,let rid = regionID,let matrix = mappedCamera(frame) else { return }
        let p = matrix.columns.3,point = ProbePoint(Double(p.x),Double(p.y),Double(p.z))
        let nearest:CampusLocatedPosition
        do { nearest = try CampusMapGeometry.locate(graph:graph,transforms:connected,point:point.array,previousEdgeID:located?.position.edge_id) }
        catch { suspend(error.localizedDescription,event:"network_network_unavailable");return }
        located = nearest;routeOffset = nearest.distance_m
        if logicalRegionID != nearest.position.region_id {
            logicalRegionID = nearest.position.region_id
            log("network_logical_region_changed",["logical_region_id":nearest.position.region_id,"active_map_region_id":rid,"AR_session_reset":false])
        }
        var geometry = routeGeometry()
        var projection = try? geometry?.project(point,near:routeProgress)
        let legEdges = path.flatMap { legIndex < $0.legs.count ? $0.legs[legIndex].edge_ids : nil } ?? []
        var pendingReplan = CampusRouteAccess.shouldReplan(closest:nearest,plannedStart:plannedStart,edgeIDs:legEdges,routeProjection:projection?.point)
        if pendingReplan { cueGate.reset();arrivalGate.reset() }
        if replanGate.observe(key:nearest.position.edge_id,time:frame.timestamp,valid:pendingReplan,hold:0.8),frame.timestamp-lastReplan >= 1 {
            lastReplan = frame.timestamp
            do {
                try replan(frame:frame,positionOverride:nearest)
                geometry = routeGeometry();projection = try? geometry?.project(point);pendingReplan = false
                log("network_route_replanned",["reason":"nearest_network_branch_changed","edge_id":nearest.position.edge_id,"offset_m":nearest.distance_m])
            } catch { log("network_replan_failed",["reason":error.localizedDescription]);instruction.text = "此处线路暂不能通往目的地。\n\(error.localizedDescription)";return }
        }
        let needsJoin = nearest.distance_m > (geometry == nil ? CampusRouteAccess.transferRadius : CampusRouteAccess.joinRadius)
        returnTarget = needsJoin ? nearest : nil
        if needsJoin {
            cueGate.reset();arrivalGate.reset();cueKey = nil;cueTurn = nil
            if let projection { routeProgress = projection.distance }
            showReturnGuidance(nearest,camera:matrix)
            if frame.timestamp-lastNavigationLog >= 1 {
                lastNavigationLog = frame.timestamp
                log("network_return_to_route",["edge_id":nearest.position.edge_id,"fraction":nearest.position.fraction,"distance_m":nearest.distance_m,"warning_distance_m":routeWarningDistance,"target_map_position":nearest.point,"bearing_is_walkable_path":false])
            };return
        }
        if pendingReplan {
            maneuverIcon.transform = .identity;maneuverIcon.image = UIImage(systemName:"arrow.triangle.2.circlepath")
            instruction.text = "正在按附近线路更新路线…";return
        }
        guard let geometry,let projection else { beginLeg();return }
        maneuverIcon.transform = .identity;maneuverIcon.tintColor = .systemMint;detail.textColor = .white
        routeProgress = projection.distance
        let turn = geometry.nextTurn(progress:projection.distance)
        let key = turn.map { "\($0.vertex):\($0.direction.rawValue)" } ?? "end"
        if cueGate.observe(key:key,time:frame.timestamp,valid:true),cueKey != key {
            cueKey = key;cueTurn = turn
            log("network_navigation_step_changed",["cue":key,"along_route_m":projection.distance,"offset_m":projection.offset,"source":"AR_route_progress"])
        }
        let remaining = max(0,geometry.length-projection.distance),end = geometry.points.last!
        let endpointDistance = hypot(point.x-end.x,point.z-end.z)
        let finalLeg = legIndex == (path?.legs.count ?? 0)-1
        if !finalLeg,remaining <= 1.5,endpointDistance <= 2,
           handoffGate.observe(key:"leg-\(legIndex)",time:frame.timestamp,valid:true,hold:0.8) {
            legIndex += 1;beginLeg();return
        }
        if remaining > 1.5 || endpointDistance > 2 { handoffGate.reset() }
        let arrival = arrivalGate.observe(key:"destination",time:frame.timestamp,valid:finalLeg && remaining <= 1.2 && endpointDistance <= 1.5,hold:1)
        if arrival {
            log("network_destination_reached",["source":"AR_route_progress","horizontal_distance_m":endpointDistance,"remaining_route_m":remaining])
            UIImpactFeedbackGenerator(style:.light).impactOccurred()
            phase = .arrived;arView.session.pause();clearScene();guide.isHidden = true
            status.text = "已到达 \(destination?.title(in:graph) ?? "目的地")附近";detail.text = region.map { graph.floorName($0.floor_id)+" · "+$0.name }
            instruction.text = navigationPlan?.arrival_hint ?? "请核对实际位置。";maneuverIcon.image = UIImage(systemName:"checkmark.circle.fill");refresh();return
        }
        status.text = "前往 \(destination?.title(in:graph) ?? "目的地")"
        detail.text = "\(graph.floorName(region?.floor_id ?? "")) · 剩余约 \(Int(max(0,(path?.total_cost_m ?? geometry.length)-projection.distance).rounded())) 米"
        if let turn = cueTurn {
            let distance = max(0,turn.distance-projection.distance)
            let action = turn.direction == .left ? "左转" : turn.direction == .right ? "右转" : "转身"
            maneuverIcon.image = UIImage(systemName:turn.direction == .left ? "arrow.turn.up.left" : turn.direction == .right ? "arrow.turn.up.right" : "arrow.uturn.down")
            instruction.text = distance <= 1.5 ? "在这里\(action)" : distance <= 4 ? "前方约 \(Int(ceil(distance))) 米\(action)" : "沿走廊继续前行\n约 \(Int(ceil(distance))) 米后\(action)"
        } else if remaining <= 4 {
            maneuverIcon.image = UIImage(systemName:finalLeg ? "mappin.circle.fill" : "arrow.up.forward")
            instruction.text = finalLeg ? "即将到达\n\(navigationPlan?.arrival_hint ?? "请核对目的地。")" : "即将进入下一段\n同层已连接区域自动继续"
        } else {
            maneuverIcon.image = UIImage(systemName:"arrow.up");instruction.text = "沿走廊继续前行"
        }
        if frame.timestamp-lastNavigationLog >= 1 {
            lastNavigationLog = frame.timestamp
            log("network_navigation_progress",["along_route_m":projection.distance,"offset_m":projection.offset,"remaining_leg_m":remaining,"look_ahead_m":routeLookAhead,"cue":cueKey ?? "pending","region_id":rid])
        }
    }
    private func showReturnGuidance(_ location:CampusLocatedPosition,camera:simd_float4x4) {
        let far = location.distance_m > routeWarningDistance
        status.text = "前往 \(destination?.title(in:graph) ?? "目的地")"
        detail.text = String(format:"%@距路网约 %.1f 米 · 定位仍在跟踪",far ? "距离线路较远 · " : "",location.distance_m)
        detail.textColor = far ? .systemOrange : .white
        instruction.text = "沿橙色箭头方向寻找通行入口\n回到线路后继续导航"
        maneuverIcon.image = UIImage(systemName:"location.north.line.fill");maneuverIcon.tintColor = .systemOrange
        let dx = Float(location.point[0])-camera.columns.3.x,dz = Float(location.point[2])-camera.columns.3.z
        let fx = -camera.columns.2.x,fz = -camera.columns.2.z
        maneuverIcon.transform = CGAffineTransform(rotationAngle:CGFloat(atan2(fx*dz-fz*dx,fx*dx+fz*dz)))
    }
    @objc private func replanCurrentLocation() {
        guard phase == .navigation,alignmentConfirmed,normal,!busy,let frame = arView.session.currentFrame else { return }
        do {
            try replan(frame:frame);lastReplan = frame.timestamp
            log("network_route_replanned",["reason":"manual_current_position","AR_session_reset":false])
            updateNavigation(frame);draw();refresh()
        } catch { campusError(error) }
    }
    @objc private func addRoom() {
        guard phase == .capture,normal,!busy,!photoBusy,let rid = regionID,let frame = arView.session.currentFrame,
              let reference = bindings.first,let anchor = frame.anchors.first(where:{$0.identifier.uuidString == reference.anchor_id}),
              let hit = arView.raycast(from:arView.convert(reticle.center,from:view),allowing:.existingPlaneGeometry,alignment:.horizontal).first else { campusMessage("未找到地面","将＋对准房门附近的走廊地面后重试。");return }
        let mapped = matrixFromRows(reference.anchor_to_map)*simd_inverse(anchor.transform)*hit.worldTransform
        let p = mapped.columns.3
        do {
            let existing:CampusRoom?,specificEdge:String?
            switch roomTask {
            case .add(let eid):existing = nil;specificEdge = eid
            case .move(let id):existing = graph.room(id);specificEdge = existing?.edge_id
            case nil:existing = nil;specificEdge = nil
            }
            let point = [Double(p.x),Double(p.y),Double(p.z)]
            let edge:CampusEdge,fraction:Double
            if let eid = specificEdge {
                guard let e = graph.edges.first(where:{$0.id == eid && $0.region_id == rid && $0.kind == .walk}),
                      let a = graph.binding(nodeID:e.from,regionID:rid),let b = graph.binding(nodeID:e.to,regionID:rid) else { throw CampusError.invalid("未找到要标房间的连线。") }
                let projection = try CampusPositionLocator.project(point,a:a.position,b:b.position)
                guard projection.distance <= 2.5 else { throw CampusError.invalid("房间不在所选连线附近，请沿这段走廊对准房门旁的地面。") }
                edge = e;fraction = projection.fraction
            } else {
                let found = try CampusPositionLocator.locate(graph:graph,regionID:rid,point:point)
                guard let e = graph.edges.first(where:{$0.id == found.position.edge_id}) else { return };edge = e;fraction = found.position.fraction
            }
            roomMarkingEdgeID = edge.id;drawKey = "";draw()
            campusText("房间名称",value:existing?.name ?? "",placeholder:"例如：101") { [weak self] name in
                self?.campusChoices("房间在哪一侧？",message:"该连线两侧已显示黄线和蓝线。按房间靠近的颜色选择，转身也不交换。位置自动计算，无需输入距离。",choices:CampusRoom.Side.allChoices { side in
                    guard let self else { return };self.undo.append((self.graph,self.selected,self.bindings,self.coordinateReady))
                    let room = CampusRoom(name:name,edgeID:edge.id,fraction:fraction,side:side,id:existing?.id ?? UUID().uuidString)
                    self.graph.rooms.removeAll { $0.id == room.id };self.graph.rooms.append(room);self.dirty = true
                    self.log("network_room_ar_placed",["room_id":room.id,"edge_id":edge.id,"computed_fraction":fraction,"side":side.rawValue,"placement_source":"AR_ground_raycast"])
                    self.instruction.text = "已标注「\(name)」。核对房间标记，点击保存发布修改。";self.draw();self.refresh()
                })
            }
        } catch { campusError(error) }
    }
    private func beginLeg() {
        clearScene(); previousPose = nil;returnTarget = nil;replanGate.reset()
        maneuverIcon.transform = .identity;maneuverIcon.tintColor = .systemMint;detail.textColor = .white
        guard let path, legIndex < path.legs.count else {
            arView.session.pause();phase = .arrived;guide.isHidden = true
            status.text = "已到达 \(destination?.title(in:graph) ?? "目的地")附近";detail.text = "请核对实际位置"
            instruction.text = navigationPlan?.arrival_hint ?? "请核对真实门牌。";maneuverIcon.image = UIImage(systemName:"checkmark.circle.fill");refresh();return
        }
        let leg = path.legs[legIndex]
        if leg.kind == .walk,let rid = leg.region_id,connected[rid] != nil,alignmentConfirmed,normal {
            phase = .navigation;routeProgress = nil;cueGate.reset();arrivalGate.reset();handoffGate.reset()
            instruction.text = "继续跟随箭头 · 同层区域无需重新恢复"
            log("network_continuous_region_handoff",["logical_region_id":rid,"active_map_region_id":regionID ?? "","AR_session_reset":false]);draw();refresh();return
        }
        alignmentConfirmed = false
        if leg.kind == .stairs {
            arView.session.pause(); regionID = nil; phase = .stairs; guide.isHidden = true
            let a = graph.node(leg.node_ids.first!)!, b = graph.node(leg.node_ids.last!)!
            status.text = "经 \(a.name) 前往 \(graph.floorName(b.floor_id))"
            instruction.text = "楼梯段暂停 AR 路线。到达另一层后确认楼层和楼梯出口，再扫描恢复环境。"; refresh()
        } else { loadRegion(leg.region_id!) }
    }
    private func loadRegion(_ rid:String,automatic:Bool = false,restrictToStart:Bool = false,candidateID:String? = nil) {
        guard !busy, let r = graph.region(rid), r.map_saved else { campusMessage("区域尚未保存","先完成区域采集，再使用导航。"); return }
        scanCoverage = CampusSupplementCoverage();lastCoverageSample = 0
        var selectedMap = candidateID ?? requestedMapID
        if candidateID == nil {
            let lighting = supplementLighting ?? CampusLightingSettings.shared.preferredLighting(graph.building_id)
            mapAttempts = graph.rankedMaps(regionID:rid,nearNodeID:searchStart.nearbyNodeID,preferredLighting:lighting).map(\.id)
            if let selectedMap,graph.mapCandidate(selectedMap)?.region_id == rid { mapAttempts = [selectedMap] } else if requestedMapID != nil { requestedMapID = nil;selectedMap = nil }
            selectedMap = mapAttempts.first;mapAttemptIndex = selectedMap == nil ? 0 : 1
        }
        let loadingMapID = selectedMap
        arView.session.pause(); clearScene(); savedFeatures = nil;regionID = rid; phase = .loading; busy = true; gate = nil; observed.removeAll()
        returnTarget = nil;replanGate.reset()
        loadToken = UUID(); let token = loadToken; let g = graph; automaticAttempt = automatic;restrictOnRestore = restrictToStart;located = nil
        if !isCapture,!restrictToStart { searchStart = .environment(regionID:rid,nodeID:nil) }
        instruction.text = "正在校验环境地图…"; refresh()
        let references = refs, searchViews = views,guideDirectory = recoveryGuides,copyReferences = isCapture
        restoreRequestStarted = ProcessInfo.processInfo.systemUptime;sdkNormalLogged = false;lastRestoreReadiness = 0
        log("network_map_load_started",["direct_environment":!automatic,"vision_used":!isCapture && searchStart.directRegionID == nil,"start_hint":searchStart.title(in:graph)])
        log("network_lighting_preference",["summary":CampusLightingSettings.shared.summary(graph.building_id),"preferred_lighting":CampusLightingSettings.shared.preferredLighting(graph.building_id).rawValue,"requested_map_id":requestedMapID ?? "automatic","map_attempt_order":mapAttempts])
        let loadBegan = restoreRequestStarted,nearbyNode = searchStart.nearbyNodeID
        CampusApp.io.async { [weak self] in
            let result = Result { () -> (CampusARStore.Loaded,[GuideChoice],CampusFeaturePointCloud?,Double) in
                let loaded = try CampusARStore.loadVerified(graph:g,region:r,candidateID:loadingMapID),dir = loaded.directory
                if copyReferences {
                    for (name,target) in [("references",references),("views",searchViews),("guides",guideDirectory)] {
                        try? FileManager.default.removeItem(at:target)
                        let source = dir.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath:source.path) { try FileManager.default.copyItem(at:source,to:target) }
                    }
                }
                let nodeIDs = Set(loaded.snapshot.bindings.map(\.node_id))
                var choices:[GuideChoice] = []
                for json in (try? FileManager.default.contentsOfDirectory(at:dir.appendingPathComponent("guides"),includingPropertiesForKeys:nil)) ?? [] where json.pathExtension == "json" {
                    guard let guide = try? JSONDecoder().decode(CampusRecoveryGuide.self,from:Data(contentsOf:json)),(try? guide.validate(nodeIDs:nodeIDs)) != nil else { continue }
                    let url = json.deletingPathExtension().appendingPathExtension("jpg")
                    if FileManager.default.fileExists(atPath:url.path) { choices.append(GuideChoice(title:(g.node(guide.reference_node_id).map { g.nodeLabel($0) } ?? "节点")+" · "+guide.lighting.title,nodeID:guide.reference_node_id,url:url,date:guide.created_utc)) }
                }
                choices.sort { a,b in if (a.nodeID == nearbyNode) != (b.nodeID == nearbyNode) { return a.nodeID == nearbyNode };return a.date > b.date }
                for b in loaded.snapshot.bindings {
                    let url = dir.appendingPathComponent("references/\(b.node_id).jpg")
                    choices.append(GuideChoice(title:(g.node(b.node_id).map { g.nodeLabel($0) } ?? "节点")+" · 原参考画面",nodeID:b.node_id,url:url,date:""))
                }
                if choices.allSatisfy({$0.date.isEmpty}),let nearbyNode { choices.sort { ($0.nodeID == nearbyNode) && ($1.nodeID != nearbyNode) } }
                let cloud = try? CampusFeatureStore.make(map:loaded.map,regionID:rid,date:loaded.snapshot.saved_utc,mapHash:CampusFiles.hash(dir.appendingPathComponent("environment.arworldmap")))
                return (loaded,choices,cloud,ProcessInfo.processInfo.systemUptime-loadBegan)
            }
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }; self.busy = false
                switch result {
                case .failure(let e): if !self.isCapture { self.restoreTimedOut() } else { self.phase = .suspended; self.campusError(e); self.refresh() }
                case .success(let (loaded,choices,cloud,loadSeconds)):
                    let map = loaded.map
                    self.mapID = loadingMapID
                    self.mapToRegion = g.mapCandidate(loadingMapID)?.map_to_region ?? CampusMapGeometry.identity
                    self.localBindings = loaded.snapshot.bindings.filter { g.binding(nodeID:$0.node_id,regionID:rid) != nil }.map { b in
                        var converted = b;converted.anchor_to_map = CampusMapGeometry.multiply(self.mapToRegion,b.anchor_to_map);return converted
                    }
                    self.coordinateReady = true;self.connected = CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:rid)
                    self.savedFeatures = cloud
                    self.guideChoices = choices
                    self.log("network_map_loaded",["file_load_seconds":loadSeconds,"validation_seconds":loaded.validationSeconds,"decode_seconds":loaded.decodeSeconds,"cache_hit":loaded.cacheHit,"guide_count":choices.count,"map_candidate_id":loadingMapID ?? "legacy","connected_regions":self.connected.count])
                    self.viewCount = ((try? FileManager.default.contentsOfDirectory(at:self.views,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "jpg" }.count; self.lastView = nil
                    if self.background { self.phase = .suspended; self.instruction.text = "地图已校验，回到前台后点击重新恢复。"; self.refresh(); return }
                    self.showReferenceGuide(choices.first)
                    self.boundaryTime = self.arView.session.currentFrame?.timestamp ?? 0
                    self.currentSession = UUID().uuidString; self.lastTracking = "not_available"; self.previousPose = nil
                    let timeout:Double = automatic ? (self.searchStart == .unknown ? 15 : 30) : (!self.isCapture && self.requestedMapID == nil && self.mapAttempts.count > 1 ? 20 : 60)
                    self.restoreStarted = ProcessInfo.processInfo.systemUptime
                    self.gate = WorldMapRestoreGate(startTime:self.restoreStarted,timeout:timeout); self.phase = .restoring
                    self.config.initialWorldMap = map
                    self.log("network_restore_requested",["expected_anchor_ids":self.bindings.map(\.anchor_id),"timeout_seconds":timeout,"supplement_lighting":self.supplementLighting?.rawValue ?? "none"])
                    self.arView.session.run(self.config,options:[.resetTracking,.removeExistingAnchors]); self.config.initialWorldMap = nil
                    self.instruction.text = self.isCapture ? "缓慢扫描附近的门框、墙面标识和地面，恢复已有标点。" : "在当前位置扫描固定环境，正在尝试 \(self.graph.floorName(r.floor_id)) · \(r.name)。无需走到采集起点。"; self.refresh()
                    DispatchQueue.main.asyncAfter(deadline:.now()+timeout) { [weak self] in
                        guard let self,self.loadToken == token,self.phase == .restoring else { return }
                        self.restoreTimedOut()
                    }
                }
            }
        }
    }
    private func refresh() {
        let canEdit = isCapture && phase == .capture && normal && !busy && !photoBusy
        addButton.isEnabled = canEdit;connectButton.isEnabled = canEdit && coordinateReady && !bindings.isEmpty;guideCaptureButton.isEnabled = canEdit && !bindings.isEmpty
        roomButton.isEnabled = canEdit && coordinateReady && graph.edges.contains { $0.region_id == regionID && $0.kind == .walk }
        saveButton.configuration?.title = saveTarget.createsSubenvironment ? "保存新图" : "保存更新"
        saveButton.isEnabled = canEdit && coordinateReady && bindings.count >= 2 && arView.session.currentFrame?.worldMappingStatus == .mapped
        advanceButton.isHidden = phase == .capture || phase == .loading || phase == .searching || phase == .restoring
        advanceButton.isEnabled = !busy
        replanButton.isHidden = isCapture || phase != .navigation
        replanButton.isEnabled = normal && alignmentConfirmed && !busy
        switch phase {
        case .check: advanceButton.configuration?.title = "位置正确，继续"
        case .navigation:
            advanceButton.configuration?.title = "查看路线 / 手动确认到达"; advanceButton.isEnabled = normal && !busy
        case .stairs: advanceButton.configuration?.title = "我已到达，确认楼层 / 出口"; advanceButton.isEnabled = !busy
        case .suspended: advanceButton.configuration?.title = isCapture && dirty ? "核对标点后继续" : isCapture ? "重新恢复环境" : "重新识别当前位置"
        case .arrived: advanceButton.configuration?.title = "完成并返回"
        default: break
        }
        if phase == .check || (phase == .suspended && isCapture && dirty) { advanceButton.isEnabled = normal && !busy }
        navigationItem.leftBarButtonItem?.isEnabled = !busy && !photoBusy
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = !busy && !photoBusy }
        reticle.isHidden = !isCapture
    }
    @objc private func add() {
        guard phase == .capture, normal, !photoBusy, !busy else { return }
        campusChoices("添加 / 绑定节点",choices:CampusNodeKind.allCases.map { kind in
            (kind == .waypoint ? "路点（自动编号）" : "新建：\(kind.title)",{ [weak self] in
                guard let self else { return }
                if kind == .waypoint { self.place(name:"",kind:kind,existing:nil) }
                else { self.campusText("\(kind.title)名称",placeholder:"例如：东楼梯口 / 活动室门口") { [weak self] name in self?.place(name:name,kind:kind,existing:nil) } } })
        } + [("绑定已有节点（局部地图 / 区域交接）",{ [weak self] in
            guard let self, let region = self.region else { return }
            let nodes = self.graph.nodes.filter { n in n.floor_id == region.floor_id && (self.coordinateReady || self.graph.binding(nodeID:n.id,regionID:region.id) != nil) && !self.bindings.contains(where: { $0.node_id == n.id }) }
            guard !nodes.isEmpty else { self.campusMessage("没有可绑定节点","先在另一区域标记交接点。本区域已有节点请通过「连线」选择。"); return }
            let picker = CampusNodePicker(title:"选择现实中的同一个节点",graph:self.graph,nodes:nodes) { [weak self] n in self?.place(name:n.name,kind:n.kind,existing:n) }
            self.navigationController?.pushViewController(picker,animated:true)
        })])
    }
    private func place(name:String,kind:CampusNodeKind,existing:CampusNode?) {
        guard phase == .capture, normal, !busy, !photoBusy, let rid = regionID, let region, let frame = arView.session.currentFrame else { return }
        let screen = arView.convert(reticle.center,from:view)
        guard let hit = arView.raycast(from:screen,allowing:.existingPlaneGeometry,alignment:.horizontal).first,
              frame.camera.transform.columns.3.y-hit.worldTransform.columns.3.y > 0.15 else {
            campusMessage("未找到可标记地面","缓慢扫描真实地板，保持＋对准要标点的位置后重试。"); return
        }
        if !coordinateReady && existing == nil { campusMessage("先连接原路网坐标","通过「绑定已有节点」在同一现实位置绑定两个相距 2 米以上的原节点；完成后再新增节点。");return }
        let before = graph, previousSelected = selected,previousBindings = bindings,previousReady = coordinateReady
        let node = existing ?? CampusNode(floorID:region.floor_id,name:name,kind:kind)
        var transform = matrix_identity_float4x4; transform.columns.3 = hit.worldTransform.columns.3
        let anchor = ARAnchor(name:"campus-node/"+node.id,transform:transform)
        do {
            if existing == nil { graph.nodes.append(node) }
            let mapped = regionToSession(frame).map { simd_inverse($0)*transform } ?? transform
            var binding = CampusBinding(regionID:rid,nodeID:node.id,anchorID:anchor.identifier.uuidString,transform:matrixRows(mapped))
            localBindings.append(binding)
            if !coordinateReady,localBindings.count >= 2 {
                let fit = try CampusMapGeometry.fit(source:localBindings,target:graph.bindings.filter { $0.region_id == rid })
                mapToRegion = fit.transform
                for i in localBindings.indices { localBindings[i].anchor_to_map = CampusMapGeometry.multiply(fit.transform,localBindings[i].anchor_to_map) }
                binding = localBindings.last!;coordinateReady = true;previousPose = nil
            }
            if graph.binding(nodeID:node.id,regionID:rid) == nil { graph.bindings.append(binding) }
            if coordinateReady,let selected { try graph.connect(selected,node.id,regionID:rid) }
            try graph.validate()
        } catch { graph = before;localBindings = previousBindings;coordinateReady = previousReady;campusError(error); return }
        undo.append((before,previousSelected,previousBindings,previousReady)); selected = node.id; dirty = true
        arView.session.add(anchor:anchor); addMarker(anchor,node:node)
        let reference = WorldMapReferenceFrame(frame:frame), token = loadToken, destination = refs
        photoBusy = true; refresh(); log("network_node_bound",["node_id":node.id,"anchor_id":anchor.identifier.uuidString,"reused_global_node":existing != nil])
        CampusApp.io.async { [weak self] in
            let result = Result { try CampusARStore.writeReference(reference,nodeID:node.id,directory:destination) }
            DispatchQueue.main.async {
                guard let self,self.loadToken == token else { return }; self.photoBusy = false
                switch result { case .success: self.instruction.text = self.coordinateReady ? "已标记「\(self.graph.nodeLabel(node))」，坐标已连接。继续标点会从这里连线；岔路分支可在「连线」中切换起点。" : "已绑定第一个共同节点「\(self.graph.nodeLabel(node))」。再绑定本区域另一个相距 2 米以上的原节点，连接坐标后再新增路网。"
                case .failure(let e): self.campusError(e); self.undoLast() }
                self.draw(); self.refresh()
            }
        }
    }
    @objc private func connect() {
        guard phase == .capture, normal, !busy, !photoBusy else { return }
        let local = bindings.compactMap { graph.node($0.node_id) }
        campusChoices("连线与分支",message:"当前连线起点：\(selected.flatMap { graph.node($0).map { graph.nodeLabel($0) } } ?? "未选择")",choices:[
            ("切换连线起点",{ [weak self] in self?.pickLocal("选择分支起点",nodes:local) { n in self?.selected = n.id; self?.instruction.text = "下一次标点将从「\(self?.graph.nodeLabel(n) ?? "节点")」连线。" } }),
            ("连接到已标节点（闭合环路）",{ [weak self] in
                guard let self, let from = self.selected, let rid = self.regionID else { self?.campusMessage("先选择起点","在「切换连线起点」中选择一个节点。"); return }
                self.pickLocal("选择连接终点",nodes:local.filter { $0.id != from }) { [weak self] n in
                    guard let self else { return }; let before = self.graph
                    do { let edge = try self.graph.connect(from,n.id,regionID:rid); self.undo.append((before,self.selected,self.bindings,self.coordinateReady)); self.selected = n.id; self.dirty = true; self.draw(); self.instruction.text = String(format:"已连接到 %@，估计 %.2f 米。",self.graph.nodeLabel(n),edge.length_m ?? 0) }
                    catch { self.graph = before; self.campusError(error) }
                }
            }),
            ("下一点不与当前节点连线",{ [weak self] in self?.selected = nil; self?.instruction.text = "下一次标点将开启新的分支；之后可手动连接。" }),
            ("撤销最近一次标点 / 连线",{ [weak self] in self?.undoLast() })])
    }
    private func pickLocal(_ title:String,nodes:[CampusNode],done:@escaping(CampusNode)->Void) {
        guard !nodes.isEmpty else { return }; navigationController?.pushViewController(CampusNodePicker(title:title,graph:graph,nodes:nodes,done:done),animated:true)
    }
    private func undoLast() {
        guard let previous = undo.popLast() else { return }
        let oldIDs = Set(previous.2.map(\.anchor_id))
        for b in bindings where !oldIDs.contains(b.anchor_id) {
            if let anchor = arView.session.currentFrame?.anchors.first(where:{$0.identifier.uuidString == b.anchor_id}) { arView.session.remove(anchor:anchor) }
            markers[b.node_id]?.removeFromParent(); markers[b.node_id] = nil
        }
        graph = previous.0; selected = previous.1;localBindings = previous.2;coordinateReady = previous.3;previousPose = nil; dirty = true; draw(); refresh(); log("network_edit_undone")
    }
    @objc private func save() { saveMap(exitAfter:false) }
    private func saveMap(exitAfter:Bool,preferredNodeIDs:[String]? = nil) {
        guard phase == .capture, normal,coordinateReady, !busy, !photoBusy, bindings.count >= 2,
              arView.session.currentFrame?.worldMappingStatus == .mapped, let rid = regionID else {
            campusMessage("还不能保存","至少标记两个节点，继续扫描到「可保存地图」。"); return
        }
        let valid = Set(graph.bindings.filter { $0.region_id == rid }.map(\.node_id))
        let suggested = scanCoverage.suggestedNodeIDs().filter { valid.contains($0) }
        if localSupplement,saveTarget.createsSubenvironment,preferredNodeIDs == nil {
            let picker = CampusMapNodeSelectionController(graph:graph,regionID:rid,selected:suggested,suggested:suggested) { [weak self] ids in self?.saveMap(exitAfter:exitAfter,preferredNodeIDs:ids) }
            let nav = UINavigationController(rootViewController:picker);nav.modalPresentationStyle = .fullScreen;present(nav,animated:true);return
        }
        busy = true; refresh(); let token = loadToken, session = currentSession
        instruction.text = "正在保存环境和路网，保持缓慢扫描…"
        arView.session.getCurrentWorldMap { [weak self] map,error in
            DispatchQueue.main.async {
                guard let self,self.loadToken == token else { return }
                guard let map,self.normal,self.phase == .capture,self.currentSession == session,
                      self.arView.session.currentFrame?.worldMappingStatus == .mapped else {
                    self.busy = false; self.refresh(); self.campusMessage("地图未保存",error?.localizedDescription ?? "保存期间跟踪发生变化，恢复扫描后重试。"); return
                }
                let g = self.graph,refs = self.refs,views = self.views,guides = self.recoveryGuides
                let local = self.bindings,lighting = self.captureLighting,sourceID = self.mapID,replacementID = self.saveTarget.replacementID
                CampusApp.io.async { [weak self] in
                    let result = Result { try CampusARStore.save(graph:g,regionID:rid,map:map,references:refs,views:views,guides:guides,sessionID:session,localBindings:local,lighting:lighting,sourceMapID:sourceID,preferredNodeIDs:preferredNodeIDs,suggestedNodeIDs:suggested,replacingMapID:replacementID) }
                    DispatchQueue.main.async {
                        guard let self,self.loadToken == token else { return }; self.busy = false
                        switch result {
                        case .success(let (saved,cloud,candidate)):
                            self.graph = saved;self.savedFeatures = cloud;self.dirty = false;self.undo.removeAll()
                            self.saveTarget.didSave(candidate.id);self.mapID = candidate.id;self.mapToRegion = candidate.map_to_region
                            let action = replacementID == nil ? "已创建子环境。" : "已更新此子环境，没有新增副本。"
                            self.instruction.text = action+"继续保存会更新同一份。退出后重新测试恢复，通过后可标记已实测。"
                            self.log("network_region_saved",["revision":saved.revision,"map_candidate_id":candidate.id,"feature_point_count":map.rawFeaturePoints.points.count,"supplement_lighting":lighting.rawValue,"previous_map_preserved":replacementID == nil,"save_action":replacementID == nil ? "create" : "replace","preferred_node_ids":candidate.preferred_node_ids ?? [],"suggested_node_ids":suggested,"native_map_cropped":false])
                            if exitAfter { self.finishAndClose();return }
                        case .failure(let e): self.campusError(e)
                        }; self.refresh()
                    }
                }
            }
        }
    }
    @objc private func advance() {
        guard !busy else { return }
        switch phase {
        case .check:
            guard normal else { return }; alignmentConfirmed = true; guide.isHidden = true
            if !isCapture,let rid = regionID { searchStart = .environment(regionID:rid,nodeID:nil) }
            phase = isCapture ? .capture : .navigation
            if !isCapture,let id = mapID { log("network_candidate_alignment_confirmed",["map_candidate_id":id,"cold_start_test":true]) }
            log("network_alignment_confirmed",["source":"human_observation","numeric_accuracy_measured":false])
            if localSupplement { dirty = true;instruction.text = "已对齐原路网。缓慢扫描局部固定物体的不同视角。创建子环境首次保存时确认对应节点；更新已有子环境保留原来的对应节点。";draw();refresh();return }
            if supplementLighting != nil { dirty = true;instruction.text = "已对齐旧环境。沿走廊缓慢扫描当前光照下的固定物体，保存恢复视角；完成后保存环境更新。";draw();refresh();return }
            if !isCapture && returnTarget == nil && (path?.legs.first?.kind != .walk || connected[path?.legs.first?.region_id ?? ""] == nil) { beginLeg(); return }
            instruction.text = isCapture ? (roomTask == nil ? "已恢复标点，可继续添加节点和连接；保存后才会更新路网。" : "沿所选走廊找到房门，将＋对准门旁的地面，点击房间标注，再保存。") : "沿地面箭头行走\n转弯提示随行走自动更新"; draw(); refresh()
            if !isCapture,let frame = arView.session.currentFrame { updateNavigation(frame);draw() }
        case .navigation:
            guard normal,let frame = arView.session.currentFrame,let leg = path?.legs[legIndex],let rid = regionID,
                  let id = leg.node_ids.last,let point = navigationPlan?.point(nodeID:id,regionID:leg.region_id ?? rid),let endpoint = sessionPoint(point,frame:frame) else { return }
            let camera = frame.camera.transform.columns.3
            let distance = Double(hypot(camera.x-endpoint.x,camera.z-endpoint.z))
            guard CampusNavigationProgress.canConfirm(horizontalDistance:distance) else { showFollowingOverview();return }
            if distance > 2,let path,legIndex+1 < path.legs.count { previewFollowing(distance:distance);return }
            campusChoices("核对实际位置",message:followingText(),choices:[("继续跟随箭头",{}),("已到达本段终点",{ [weak self] in self?.confirmPassage(distance:distance) })])
        case .stairs: chooseArrival()
        case .arrived: finishAndClose()
        case .suspended:
            if isCapture && dirty {
                guard normal, bindings.allSatisfy({ b in arView.session.currentFrame?.anchors.contains { $0.identifier.uuidString == b.anchor_id } ?? false }) else { campusMessage("无法找回全部标点","请返回并放弃未保存草稿，再恢复已保存区域或重新采集。"); return }
                phase = .check; draw(); instruction.text = "核对所有已标节点是否仍在原处。只有实际对齐时才点击继续。"; refresh()
            } else if isCapture, let rid = regionID {
                if region?.map_saved == true { loadRegion(rid) } else { phase = .capture; currentSession = UUID().uuidString; config.initialWorldMap = nil; arView.session.run(config,options:[.resetTracking,.removeExistingAnchors]); refresh() }
            } else { beginSearch() }
        default: break
        }
    }
    private func confirmPassage(distance:Double) {
        log("network_leg_arrival_confirmed",["source":"human_observation","horizontal_distance_m":distance,"allowed_radius_m":CampusNavigationProgress.passageRadius]);legIndex += 1;beginLeg()
    }
    private func followingText() -> String {
        guard let path else { return "识别当前位置并生成路线后，即可预览后续路线。" }
        var instructions:[String] = []
        if let geometry = routeGeometry() {
            let progress = routeProgress ?? 0
            instructions += geometry.turns.filter { $0.distance+1 > progress }.map { turn in
                let action = turn.direction == .left ? "左转" : turn.direction == .right ? "右转" : "转身"
                return "约 \(Int(ceil(max(0,turn.distance-progress)))) 米后\(action)"
            }
            if legIndex+1 == path.legs.count { instructions.append("前往 \(destination?.title(in:graph) ?? "目的地")。\(navigationPlan?.arrival_hint ?? "请核对实际位置。")") }
        }
        instructions += path.legs.dropFirst(legIndex+1).map { l in
            if l.kind == .stairs,let n = l.node_ids.last.flatMap({graph.node($0)}) { return "经楼梯前往 \(graph.floorName(n.floor_id)) · \(graph.nodeLabel(n))" }
            let r = graph.region(l.region_id ?? ""),end = l.node_ids.last.flatMap { graph.node($0).map { graph.nodeLabel($0) } } ?? destination?.title(in:graph) ?? "目的地"
            return "\(r.map { graph.floorName($0.floor_id)+" · "+$0.name } ?? "下一段") → \(end)"
        };return instructions.joined(separator:"\n")
    }
    private func previewFollowing(distance:Double) {
        campusChoices("下一段预览",message:String(format:"距当前交接点约 %.1f 米。\n",distance)+followingText()+"\n\n尚未走过交接处时，可继续沿当前路线；实际进入下一段后再切换环境。",choices:[
            ("继续当前路线",{}),("已通过，切换下一段",{ [weak self] in self?.confirmPassage(distance:distance) })])
    }
    private func showFollowingOverview() { campusMessage("后续路线预览",followingText()) }
    private func chooseSearchStart() {
        suspend("选择附近起始地后重新识别。",event:"network_start_hint_change_requested")
        navigationController?.pushViewController(CampusStartPicker(graph:graph,initial:searchStart) { [weak self] _,start in self?.searchStart = start;self?.beginSearch() },animated:true)
    }
    private func chooseArrival() {
        let leg = path!.legs[legIndex], planned = graph.node(leg.node_ids.last!)!
        campusChoices("确认所在楼层",message:"计划到达：\(graph.title(planned))",choices:[
            ("已到达：\(graph.title(planned))",{ [weak self] in self?.log("network_floor_arrival",["node_id":planned.id]); self?.legIndex += 1; self?.beginLeg() }),
            ("从实际所在位置重新识别",{ [weak self] in self?.chooseSearchStart() })])
    }
    private func addMarker(_ anchor:ARAnchor,node:CampusNode) {
        guard markers[node.id] == nil else { return }
        let entity = AnchorEntity(anchor:anchor)
        let color:UIColor = node.kind == .stair ? .systemOrange : node.kind == .room ? .systemCyan : .systemMint
        let mark = ModelEntity(mesh:.generateSphere(radius:0.055),materials:[UnlitMaterial(color:color)]); mark.position = [0,0.07,0]; entity.addChild(mark)
        if let name = graph.nodeMapLabel(node) {
            let text = ModelEntity(mesh:.generateText(name,extrusionDepth:0.001,font:.systemFont(ofSize:0.10),containerFrame:.zero,alignment:.left,lineBreakMode:.byWordWrapping),materials:[UnlitMaterial(color:.white)])
            text.position = [0.08,0.07,0];text.orientation = simd_quatf(angle:-.pi/2,axis:[1,0,0]);entity.addChild(text)
        }
        arView.scene.addAnchor(entity); markers[node.id] = entity
    }
    private func clearScene() {
        featureOverlay.clear()
        drawKey = ""
        for entity in markers.values { entity.removeFromParent() }; markers.removeAll()
        for entity in lines { entity.removeFromParent() }; lines.removeAll()
    }
    private func hideScene(_ hide:Bool) {
        if hide { featureOverlay.clear() }
        for entity in Array(markers.values)+lines { entity.children.forEach { $0.isEnabled = !hide } }
    }
    private func sessionPoint(_ point:CampusRoutePoint,frame:ARFrame) -> SIMD3<Float>? {
        guard connected[point.region_id] != nil,let transform = regionToSession(frame) else { return nil }
        let p = transform*SIMD4(Float(point.map_position[0]),Float(point.map_position[1]),Float(point.map_position[2]),1)
        return SIMD3(p.x,p.y,p.z)
    }
    private func draw() {
        guard normal,coordinateReady,[.capture,.navigation,.check].contains(phase),let frame = arView.session.currentFrame,let rid = regionID,
              let reference = bindings.first,let anchor = frame.anchors.first(where: { $0.identifier.uuidString == reference.anchor_id }),
              let regionToWorld = regionToSession(frame) else { hideScene(true);return }
        let needed = isCapture || phase == .check ? bindings.map(\.node_id) : []
        for id in Array(markers.keys) where !needed.contains(id) { markers[id]?.removeFromParent();markers[id] = nil }
        for binding in bindings where needed.contains(binding.node_id) {
            if let live = frame.anchors.first(where: { $0.identifier.uuidString == binding.anchor_id }),let node = graph.node(binding.node_id) { addMarker(live,node:node) }
        }
        let toReference = simd_inverse(anchor.transform)*regionToWorld
        func localPoint(_ p:[Double]) -> SIMD3<Float> {
            let v = toReference*SIMD4(Float(p[0]),Float(p[1]),Float(p[2]),1);return SIMD3(v.x,v.y,v.z)
        }
        let geometryGraph = isCapture ? graph : planningGraph
        var routes:[[SIMD3<Float>]] = []
        if isCapture {
            for edge in graph.edges where edge.region_id == rid && edge.enabled {
                if let a = graph.binding(nodeID:edge.from,regionID:rid),let b = graph.binding(nodeID:edge.to,regionID:rid) { routes.append([localPoint(a.position),localPoint(b.position)]) }
            }
        } else if let path,legIndex < path.legs.count,let plan = navigationPlan {
            var route:[SIMD3<Float>] = []
            // Draw through linked same-floor boundaries; only the front 10/20/30 m is rendered.
            for leg in path.legs.dropFirst(legIndex) {
                guard leg.kind == .walk,let logical = leg.region_id,connected[logical] != nil else { break }
                let points = leg.node_ids.compactMap { plan.point(nodeID:$0,regionID:logical) }.map { localPoint($0.map_position) }
                guard points.count == leg.node_ids.count else { break }
                if route.isEmpty { route = points } else { route += points.dropFirst() }
            }
            if route.count >= 2 { routes.append(route) }
        }
        var accessArrow:[SIMD3<Float>] = [],accessPoint:SIMD3<Float>?
        if !isCapture,let target = returnTarget,let camera = mappedCamera(frame) {
            let p = camera.columns.3
            accessArrow = CampusRouteAccess.directionArrow(from:ProbePoint(Double(p.x),Double(p.y),Double(p.z)),to:ProbePoint(target.point[0],target.point[1],target.point[2])).map { localPoint($0.array) }
            accessPoint = localPoint(target.point)
        }
        let signature = routes.map { $0.map { "\(Int(($0.x*30).rounded())),\(Int(($0.y*30).rounded())),\(Int(($0.z*30).rounded()))" }.joined(separator:":") }.joined(separator:";")+String(describing:phase)+graph.rooms.map { $0.id+$0.name+String($0.fraction)+$0.side.rawValue }.joined()+(roomMarkingEdgeID ?? "")+"leg:\(legIndex):window:\(Int(((routeProgress ?? 0)*4).rounded(.down))):\(routeLookAhead)"+accessArrow.map { "\(Int(($0.x*20).rounded())),\(Int(($0.z*20).rounded()))" }.joined()
        guard signature != drawKey else { return };drawKey = signature
        for entity in lines { entity.removeFromParent() };lines.removeAll()
        for points in routes {
            do {
                let root = AnchorEntity(anchor:anchor)
                if phase == .navigation { root.addChild(try RouteRenderer.navigation(points:points,progress:routeProgress ?? 0,ahead:routeLookAhead)) }
                else { root.addChild(try RouteRenderer.network(points:points,color:phase == .check ? .systemYellow : .systemMint,arrows:!isCapture)) }
                arView.scene.addAnchor(root);lines.append(root)
            } catch { instruction.text = "路线绘制失败：\(error.localizedDescription)" }
        }
        if !accessArrow.isEmpty,let accessPoint {
            do { let root = AnchorEntity(anchor:anchor);root.addChild(try RouteRenderer.returnBearing(points:accessArrow,target:accessPoint));arView.scene.addAnchor(root);lines.append(root) }
            catch { instruction.text = "返回方向绘制失败：\(error.localizedDescription)" }
        }
        if isCapture,let eid = roomMarkingEdgeID,let e = graph.edges.first(where: { $0.id == eid && $0.region_id == rid }),
           let a = graph.binding(nodeID:e.from,regionID:rid),let b = graph.binding(nodeID:e.to,regionID:rid) {
            let root = AnchorEntity(anchor:anchor);root.addChild(RouteRenderer.coloredSides(a:localPoint(a.position),b:localPoint(b.position)));arView.scene.addAnchor(root);lines.append(root)
        }
        for room in graph.rooms {
            if !isCapture,room.id != destination?.id { continue }
            guard let edge = graph.edges.first(where: { $0.id == room.edge_id }),let logical = edge.region_id,
                  isCapture ? logical == rid : connected[logical] != nil,
                  let a = geometryGraph.binding(nodeID:edge.from,regionID:logical),let b = geometryGraph.binding(nodeID:edge.to,regionID:logical) else { continue }
            let pa = localPoint(a.position),pb = localPoint(b.position),p = pa+(pb-pa)*Float(room.fraction)
            if !isCapture {
                let world = anchor.transform*SIMD4(p,1),camera = frame.camera.transform.columns.3
                if hypot(Double(world.x-camera.x),Double(world.z-camera.z)) > routeLookAhead { continue }
            }
            let d = SIMD3(pb.x-pa.x,0,pb.z-pa.z);guard simd_length(d) > 0.01 else { continue }
            let right = simd_normalize(SIMD3(-d.z,0,d.x)),side:Float = room.side == .right ? 0.3 : -0.3
            let color:UIColor = isCapture ? (room.side == .left ? .systemYellow : .systemBlue) : .systemCyan
            let root = AnchorEntity(anchor:anchor),text = ModelEntity(mesh:.generateText(room.name,extrusionDepth:0.001,font:.systemFont(ofSize:0.1),containerFrame:.zero,alignment:.left,lineBreakMode:.byWordWrapping),materials:[UnlitMaterial(color:color)])
            text.position = p+SIMD3(0,0.05,0)+right*side;text.orientation = simd_quatf(angle:-.pi/2,axis:[1,0,0]);root.addChild(text);arView.scene.addAnchor(root);lines.append(root)
        };hideScene(false)
    }
    func session(_ session:ARSession,didAdd anchors:[ARAnchor]) {
        let expected = Set(bindings.map(\.anchor_id))
        for anchor in anchors where expected.contains(anchor.identifier.uuidString) { observed.insert(anchor.identifier.uuidString) }
    }
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard !background,frame.timestamp > boundaryTime else { return }
        let tracking = trackingName(frame.camera.trackingState)
        if tracking != lastTracking { lastTracking = tracking; log("network_tracking_changed",["timestamp":frame.timestamp,"state":tracking]) }
        let mappedPosition = mappedCamera(frame).map { SIMD3($0.columns.3.x,$0.columns.3.y,$0.columns.3.z) }
        let poseJump:Double? = mappedPosition.flatMap { p in
            guard let old = previousPose else { return nil };let dt = frame.timestamp-old.0
            return dt > 0 && dt < 0.15 ? Double(simd_distance(p,old.1)) : nil
        }
        if phase == .restoring,var gate {
            if normal,!sdkNormalLogged { sdkNormalLogged = true;log("network_restore_first_normal",["sdk_seconds":ProcessInfo.processInfo.systemUptime-restoreStarted]) }
            let expected = Set(bindings.map(\.anchor_id)), present = Set(frame.anchors.map { $0.identifier.uuidString })
            let success = gate.observe(now:ProcessInfo.processInfo.systemUptime,trackingNormal:normal,anchorObserved:expected.isSubset(of:observed),anchorPresent:!expected.isEmpty && expected.isSubset(of:present),sampleTime:frame.timestamp,position:mappedPosition.map { [Double($0.x),Double($0.y),Double($0.z)] })
            self.gate = gate
            if let poseJump,poseJump > 0.5 { log("network_restore_pose_correction",["timestamp":frame.timestamp,"distance_m":poseJump,"map_position":mappedPosition.map { [Double($0.x),Double($0.y),Double($0.z)] } ?? [],"stable_seconds_reset":true]) }
            if frame.timestamp-lastRestoreReadiness >= 1 {
                lastRestoreReadiness = frame.timestamp
                log("network_restore_readiness",["tracking":tracking,"expected":expected.count,"observed":expected.intersection(observed).count,"present":expected.intersection(present).count,"healthy_frames":gate.healthyFrames,"healthy_seconds":gate.healthySeconds,"map_position":mappedPosition.map { [Double($0.x),Double($0.y),Double($0.z)] } ?? [],"elapsed_seconds":ProcessInfo.processInfo.systemUptime-restoreStarted])
            }
            if success {
                restores += 1; previousPose = nil
                if !isCapture {
                    let validationBegan = ProcessInfo.processInfo.systemUptime
                    do { try replan(frame:frame,enforceStartScope:restrictOnRestore);log("network_route_validation_finished",["validation_seconds":ProcessInfo.processInfo.systemUptime-validationBegan]) }
                    catch { if automaticAttempt { log("network_start_scope_rejected",["reason":error.localizedDescription]);tryNextCandidate();return };phase = .suspended; instruction.text = "已恢复 \(region?.name ?? "环境")，但\(error.localizedDescription)"; refresh(); return }
                }
                phase = .check
                log("network_sdk_restored",["timestamp":frame.timestamp,"restore_seconds":gate.restoreSeconds ?? 0,"physical_alignment_verified":false,"total_request_seconds":ProcessInfo.processInfo.systemUptime-restoreRequestStarted])
                instruction.text = isCapture ? "环境已恢复。核对黄色路网和节点是否贴在原位置，正确后继续。" : "已识别 \(region.map { graph.floorName($0.floor_id)+" · "+$0.name } ?? "环境")。核对黄色路线和节点位置后继续；路线从当前位置出发。"; draw(); refresh()
                if !isCapture,let target = returnTarget { instruction.text = String(format:"环境跟踪已稳定，距线路约 %.1f 米。\n核对黄色路网是否对齐；橙色箭头指向最近线路。",target.distance_m) }
            } else if gate.state == .timedOut { restoreTimedOut(); return }
        }
        if phase == .searching,normal,!busy,!ranking {
            ranking = true; let token = loadToken
            matcher.rank(pixels:frame.capturedImage) { [weak self] result in
                guard let self,self.loadToken == token,self.phase == .searching else { return }; self.ranking = false
                switch result { case .success(let ids): self.candidates = Array(ids.prefix(8)); self.candidateIndex = 0; self.log("network_scene_candidates",["ordered_region_ids":self.candidates,"query_timestamp":frame.timestamp,"similarity_is_position_confidence":false]);self.tryNextCandidate()
                case .failure(let error): self.instruction.text = error.localizedDescription }
            }
        }
        if [.capture,.navigation,.check].contains(phase),let poseJump,poseJump > 0.5 {
            suspend("位置出现异常跳变，路线已隐藏。核对或重新恢复后再继续。",event:"network_pose_jump",fields:["timestamp":frame.timestamp,"distance_m":poseJump,"coordinate_system":"camera_in_saved_map","before_map_position":previousPose.map { [Double($0.1.x),Double($0.1.y),Double($0.1.z)] } ?? [],"after_map_position":mappedPosition.map { [Double($0.x),Double($0.y),Double($0.z)] } ?? []])
        };previousPose = mappedPosition.map { (frame.timestamp,$0) }
        if isCapture,phase == .capture,normal,alignmentConfirmed || region?.map_saved != true,let rid = regionID,let p = mappedPosition,frame.timestamp-lastCoverageSample >= 0.5 {
            lastCoverageSample = frame.timestamp
            scanCoverage.observe(bindings:graph.bindings.filter { $0.region_id == rid },position:[Double(p.x),Double(p.y),Double(p.z)])
        }
        let missing = bindings.contains { b in !frame.anchors.contains { $0.identifier.uuidString == b.anchor_id } }
        if !normal || missing { cueGate.reset();arrivalGate.reset();replanGate.reset();handoffGate.reset() }
        if phase == .navigation,normal,!missing,frame.timestamp-lastNavigationUpdate >= 0.2 {
            lastNavigationUpdate = frame.timestamp;updateNavigation(frame)
        }
        hideScene(!normal || missing || !coordinateReady || ![.capture,.navigation,.check].contains(phase))
        if featureDisplay != .off,view.window != nil,frame.timestamp-lastFeatureDrawing >= 0.25 {
            lastFeatureDrawing = frame.timestamp;drawFeatures(frame:frame,ready:normal && !missing && [.capture,.navigation,.check].contains(phase))
        }
        if frame.timestamp-lastLog >= (detailedDiagnostics ? 0.1 : 0.5) {
            lastLog = frame.timestamp
            recorder?.append("poses.jsonl",["timestamp":frame.timestamp,"matrix":matrixRows(frame.camera.transform),"tracking":tracking,"direction":"camera_to_session","ar_session_id":currentSession,"region_id":regionID ?? "none"])
            recorder?.append("camera-events.jsonl",["timestamp":frame.timestamp,"tracking":tracking,"world_mapping_status":worldMappingName(frame.worldMappingStatus),"ar_session_id":currentSession])
            recorder?.append("anchors.jsonl",["timestamp":frame.timestamp,"region_id":regionID ?? "none","anchors":frame.anchors.filter { observed.contains($0.identifier.uuidString) }.map { ["anchor_id":$0.identifier.uuidString,"anchor_to_session":matrixRows($0.transform)] as [String:Any] }])
        }
        collectSearchView(frame)
        if frame.timestamp-lastPhoto >= (detailedDiagnostics ? 8 : 30),photoCount < (detailedDiagnostics ? 300 : 60),let recorder,!captures.busy,!busy,!photoBusy {
            lastPhoto = frame.timestamp
            _ = captures.capture(frame:frame,recorder:recorder,reason:"network_diagnostic_including_limited_tracking",route:["region_id":regionID ?? "none","leg_index":legIndex,"ar_session_id":currentSession]) { [weak self] result in
                if case .success = result { self?.photoCount += 1 }
            }
        }
        if frame.timestamp-lastDrawing >= 0.25 { lastDrawing = frame.timestamp; draw() }
        if frame.timestamp-lastHUD > 0.3 {
            lastHUD = frame.timestamp
            let r = region
            if phase != .stairs && phase != .arrived && phase != .navigation { status.text = "\(r.map { graph.floorName($0.floor_id)+" · "+$0.name } ?? graph.name)\n\(phase == .searching ? "正在识别当前位置" : phase == .restoring ? "正在对齐环境 · \(Int(ProcessInfo.processInfo.systemUptime-restoreStarted)) 秒" : phase == .check ? "待核对位置" : normal ? "跟踪正常" : "跟踪受限")" }
            if isCapture {
                let mapping = phase == .restoring ? "尚未对齐，暂不能补采或保存 · 连续稳定 \(String(format:"%.1f",gate?.healthySeconds ?? 0))/2 秒" : phase == .check ? "待核对实际位置，确认后才可补采或保存" : phase == .capture && normal ? worldMappingTitle(frame.worldMappingStatus) : "跟踪暂不可用，暂不能补采或保存"
                detail.text = "\(bindings.count) 个本图绑定 · \(coordinateReady ? mapping : "请绑定两个共同节点，连接原路网坐标")\n连线起点：\(selected.flatMap { graph.node($0).map { graph.nodeLabel($0) } } ?? "未选择") · \(dirty ? "环境或路网有未保存更新" : "已保存 / 尚未修改")"
            }
            else if phase == .navigation && (!normal || missing) { detail.text = "位置跟踪暂不可用，路线已隐藏";instruction.text = "稍停一下\n缓慢扫描附近环境" }
            refresh()
        }
    }
    private func suspend(_ reason:String,event:String,fields:[String:Any] = [:]) {
        phase = .suspended; alignmentConfirmed = false; previousPose = nil; hideScene(true); instruction.text = reason; log(event,fields); refresh()
    }
    @objc private func didBackground() {
        background = true; arView.session.pause()
        suspend("应用切到后台，位置需要重新核对或恢复。",event:"network_backgrounded")
    }
    @objc private func didForeground() {
        guard background else { return }; background = false; previousPose = nil
        if isCapture && dirty { config.initialWorldMap = nil; arView.session.run(config); refresh() }
        else if isCapture && region?.map_saved != true { config.initialWorldMap = nil; arView.session.run(config); refresh() }
        else { refresh() } // Explicit retry loads a saved map; never reveal stale arrows.
    }
    func sessionWasInterrupted(_ session:ARSession) { suspend("AR 会话中断，请核对或重新恢复。",event:"network_interrupted") }
    func sessionInterruptionEnded(_ session:ARSession) { previousPose = nil; refresh() }
    func sessionShouldAttemptRelocalization(_ session:ARSession) -> Bool { true }
    func session(_ session:ARSession,didFailWithError error:Error) { suspend(error.localizedDescription,event:"network_session_failed") }
    private func collectSearchView(_ frame:ARFrame) {
        guard isCapture,phase == .capture,normal,!busy,!photoBusy,presentedViewController == nil,navigationController?.topViewController === self else { return }
        let t = frame.camera.transform,p = SIMD3(t.columns.3.x,t.columns.3.y,t.columns.3.z),forward = SIMD3(t.columns.2.x,t.columns.2.y,t.columns.2.z)
        if let last = lastView {
            guard frame.timestamp-last.time >= 4,(simd_distance(p,last.position) >= 0.5 || simd_dot(forward,last.forward) < 0.866) else { return }
        }
        dirty = true // Scanning still changes the map after the photo quota is full.
        lastView = (frame.timestamp,p,forward)
        guard viewCount < 192 else { return }
        photoBusy = true;let reference = WorldMapReferenceFrame(frame:frame),dir = views
        CampusApp.io.async { [weak self] in
            let result = Result { try CampusARStore.writeSearchView(reference,directory:dir) }
            DispatchQueue.main.async { guard let self else { return };self.photoBusy = false
                if case .success = result { self.viewCount += 1;self.dirty = true;self.log("network_search_view_saved",["view_count":self.viewCount,"timestamp":reference.metadata["timestamp"] ?? 0]) }
                self.refresh()
            }
        }
    }
    @objc private func more() {
        var choices:[(String,()->Void)] = [("导出本次验证记录",{ [weak self] in self?.exportTrial() }),
            ("切换恢复参考画面",{ [weak self] in self?.chooseReferenceGuide() }),
            ("特征点显示：\(featureDisplay.title)",{ [weak self] in self?.chooseFeatureDisplay() }),
            ("查看已保存特征分布",{ [weak self] in guard let self,let rid = self.regionID else { return };self.navigationController?.pushViewController(CampusGraphController(graph:self.graph,regionID:rid,featureMode:1,candidateID:self.mapID),animated:true) })]
        if isCapture { choices.append(("查看当前采集分布（未保存）",{ [weak self] in self?.previewCurrentFeatures() })) }
        if !isCapture,let rid = regionID {
            choices.append(("切换恢复子环境",{ [weak self] in
                guard let self else { return }
                let entries = self.graph.map_candidates.filter { $0.region_id == rid }.map { m in
                    CampusChoicePicker.Entry(title:m.name,detail:"重新恢复此图，需核对位置") { [weak self] in self?.requestedMapID = m.id;self?.loadRegion(rid) }
                };self.navigationController?.pushViewController(CampusChoicePicker(title:"选择恢复子环境",entries:entries),animated:true)
            }))
        }
        if isCapture { choices.append(("拍摄参考照片",{ [weak self] in self?.captureRecoveryGuide() })) }
        if !isCapture {
            choices += [("从当前位置重新规划路线",{ [weak self] in self?.replanCurrentLocation() }),
                ("重新恢复环境（重新匹配位置）",{ [weak self] in self?.beginSearch() }),
                ("修改起始地并重新识别",{ [weak self] in self?.chooseSearchStart() }),
                ("预览后续路线",{ [weak self] in self?.showFollowingOverview() }),
                ("离线路较远提示：\(Int(routeWarningDistance)) 米",{ [weak self] in
                    self?.campusChoices("离线路多远时提示距离较远？",message:"位置跟踪可靠时，距离较远仍显示路线和返回方向。橙色箭头表示方位，请经可通行入口回到线路。",choices:[3.0,5.0,8.0].map { distance in
                        ("\(Int(distance)) 米",{ [weak self] in UserDefaults.standard.set(distance,forKey:"campus.navigation.routeWarningDistance");self?.log("network_route_warning_changed",["distance_m":distance]);if let frame = self?.arView.session.currentFrame { self?.updateNavigation(frame) } })
                    })
                }),
                ("前方路线长度：\(Int(routeLookAhead)) 米",{ [weak self] in
                    self?.campusChoices("前方显示多长的路线？",choices:[10.0,20.0,30.0].map { length in
                        ("\(Int(length)) 米",{ [weak self] in UserDefaults.standard.set(length,forKey:"campus.navigation.lookAhead");self?.drawKey = "";self?.draw();self?.log("network_route_window_changed",["look_ahead_m":length]) })
                    })
                }),
                ("选择所在区域重试",{ [weak self] in
                    guard let self else { return }; self.campusChoices("当前位置在哪个区域？",message:"可在当前区域任意已采集位置扫描；仍需 ARKit 恢复环境。",choices:self.graph.regions.filter { $0.map_saved }.map { r in
                        (self.graph.floorName(r.floor_id)+" · "+r.name,{ [weak self] in self?.loadRegion(r.id) })
                    })
                })]
        }
        choices += [("报告路线错位并隐藏",{ [weak self] in self?.suspend("已记录错位反馈，请核对或重新恢复。",event:"network_alignment_rejected") }),
            ("操作说明",{ [weak self] in self?.campusMessage("现场工具", "仅普通路点不显示名称；岔路口、楼梯口和目的地保留名称，创建时填写，也可在楼栋列表中改名。转角加点，岔路切换连线起点，环路连接到已有节点。对准房门旁的走廊地面点击「房间」，可把门牌标在连线上；按黄线／蓝线选择房间侧别。\n\n采集时缓慢扫描多个视角，程序会自动补充区域检索照片。区域入口的补充采集首次保存新建子环境；已有子环境入口的补充采集覆盖该子环境。同一次采集继续保存只更新同一份。创建子环境先恢复原图，选择光照，首次保存时在路网图上确认对应节点。对应节点只用于选图，不改变实际地图范围。\n\n导航先选择楼栋、楼层和环境，附近节点可选；已知环境直接恢复，不知道环境时再搜索。选了附近节点时优先尝试为该节点指定的子环境。恢复后核对路线即可继续。同层区域有两个相距较远的共同节点时，可自动连续导航；实际更换地图需要重新恢复。楼梯段手动确认楼层。") })]
        campusChoices("现场工具",choices:choices)
    }
    private func applyFeatureDisplay() {
        if featureDisplay.showsLive { arView.debugOptions.insert(.showFeaturePoints) }
        else { arView.debugOptions.remove(.showFeaturePoints) }
        featureOverlay.isHidden = featureDisplay == .off;featureOverlay.clear()
        featureOverlay.message = featureDisplay.showsSaved ? "橙色为当前子环境的已保存地图点，恢复环境后才显示。\n当前画面点由系统显示；点数不代表恢复成功率。" : featureDisplay.showsLive ? "系统点：当前画面正在跟踪的特征。\n它们不代表已保存地图的全部特征。" : ""
    }
    private func chooseFeatureDisplay() {
        campusChoices("特征点显示",message:"当前画面点随镜头变化；橙色点来自当前选择的子环境。它们都是粗略特征，不能证明某处一定能恢复。",choices:CampusFeatureDisplay.allCases.map { mode in
            (mode.title,{ [weak self] in guard let self else { return };self.featureDisplay = mode;UserDefaults.standard.set(mode.rawValue,forKey:"campus.featureDisplay");self.applyFeatureDisplay();self.lastFeatureDrawing = 0;self.log("network_feature_display_changed",["mode":mode.title]) })
        })
    }
    private func drawFeatures(frame:ARFrame,ready:Bool) {
        guard featureDisplay.showsSaved else { return }
        guard ready else { featureOverlay.clear();featureOverlay.message = "已保存地图点暂不显示：等待环境恢复或跟踪稳定。";return }
        guard let cloud = savedFeatures,let binding = bindings.first,
              let anchor = frame.anchors.first(where:{$0.identifier.uuidString == binding.anchor_id}) else {
            featureOverlay.clear();featureOverlay.message = "尚无已保存特征点。采集完成后保存环境即可查看。";return
        }
        featureOverlay.update(cloud:cloud,transform:anchor.transform*simd_inverse(matrixFromRows(binding.anchor_to_map))*matrixFromRows(mapToRegion),frame:frame,view:arView)
    }
    private func previewCurrentFeatures() {
        guard isCapture,coordinateReady,phase == .capture,normal,!busy,!photoBusy,let rid = regionID else { campusMessage("先恢复环境","进入正常采集后可以查看当前会话的地图快照。");return }
        busy = true;refresh();let token = loadToken,sessionID = currentSession
        arView.session.getCurrentWorldMap { [weak self] map,error in
            DispatchQueue.main.async {
                guard let self,self.loadToken == token else { return }
                guard let map,self.normal,self.phase == .capture,self.currentSession == sessionID else { self.busy = false;self.refresh();self.campusMessage("暂时无法读取",error?.localizedDescription ?? "跟踪发生变化，稳定后重试。");return }
                let g = self.graph,sessionToRegion = self.arView.session.currentFrame.flatMap { self.regionToSession($0) }.map { matrixRows(simd_inverse($0)) } ?? CampusMapGeometry.identity
                CampusApp.io.async { [weak self] in
                    let result = Result { () -> (CampusGraph,CampusFeaturePointCloud) in
                        let cloud = try CampusFeatureStore.make(map:map,regionID:rid,date:ISO8601DateFormatter().string(from:Date()),mapHash:nil)
                        return (g,CampusFeatureStore.transformed(cloud,by:sessionToRegion))
                    }
                    DispatchQueue.main.async {
                        guard let self,self.loadToken == token else { return };self.busy = false;self.refresh()
                        switch result {
                        case .success(let (preview,cloud)):self.navigationController?.pushViewController(CampusGraphController(graph:preview,regionID:rid,featureMode:1,preview:cloud),animated:true)
                        case .failure(let e):self.campusError(e)
                        }
                    }
                }
            }
        }
    }
    private func finishTrial(_ completion:@escaping()->Void) {
        guard !captures.busy else { campusMessage("稍等片刻","正在保存验证照片，请稍后重试。"); return }
        guard let recorder else { completion(); return }
        do { try CampusFiles.encode(graph,to:recorder.directory.appendingPathComponent("graph.json")) }
        catch { campusError(error); return }
        self.recorder = nil
        recorder.finish(statistics:["captured_frames":photoCount,"campus_network_test":true,"sdk_restores":restores,"last_alignment_confirmed":alignmentConfirmed,"numeric_accuracy_measured":false]) { [weak self] result in
            if case .failure(let e) = result { self?.campusError(e) } else { completion() }
        }
    }
    private func exportTrial() {
        guard let record = recorder else { campusMessage("记录已结束","本次验证记录已经结束；重新打开采集或导航会开始新记录。"); return }
        finishTrial { [weak self] in
            guard let self else { return }; self.busy = true; self.refresh()
            CampusApp.io.async { [weak self] in
                let result = Result { () -> URL in let url = ProbeIO.documents.appendingPathComponent("Exports/"+record.runID+".zip"); try ProbeZip.create(directory:record.directory,destination:url); return url }
                DispatchQueue.main.async { guard let self else { return }; self.busy = false; self.refresh(); switch result { case .success(let u):self.campusShare(u); case .failure(let e):self.campusError(e) } }
            }
        }
    }
    @objc private func close() {
        guard !busy,!photoBusy else { return }
        if isCapture && dirty {
            let a = UIAlertController(title:"有未保存的环境或路网更新",message:"扫描得到的环境数据也需要保存。"+(saveTarget.createsSubenvironment ? "本次首次保存会新建一个子环境；继续保存只更新它。" : "保存会覆盖本次子环境并更新路网，其他子环境保留。"),preferredStyle:.alert)
            a.addAction(UIAlertAction(title:"继续采集",style:.cancel)); a.addAction(UIAlertAction(title:"保存并返回",style:.default) { [weak self] _ in self?.saveMap(exitAfter:true) })
            a.addAction(UIAlertAction(title:"放弃修改并返回",style:.destructive) { [weak self] _ in self?.finishAndClose() }); present(a,animated:true)
        } else { finishAndClose() }
    }
    private func finishAndClose() { finishTrial { [weak self] in self?.arView.session.pause(); UIApplication.shared.isIdleTimerDisabled = false; self?.dismiss(animated:true) } }
}
#endif
