import UIKit
import UniformTypeIdentifiers
import CoreLocation

final class LiDARHomeController: UIViewController {
    private let subtitle = UILabel()
    private var trip:LiDARTripCoordinator?
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .systemGroupedBackground
        title = "校园导航"
        navigationItem.rightBarButtonItem = UIBarButtonItem(image:UIImage(systemName:"gearshape"),style:.plain,target:self,action:#selector(settings))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "设置"
        let heading = UILabel();heading.text = "找到方向，\n从这里出发。";heading.numberOfLines = 0
        heading.font = .systemFont(ofSize:34,weight:.bold)
        subtitle.font = .preferredFont(forTextStyle:.subheadline);subtitle.textColor = .secondaryLabel;subtitle.numberOfLines = 0
        let campus = card(title:"校园地图",detail:"室外到楼门，进楼后接室内导航",symbol:"map.circle.fill",color:.systemBlue,action:#selector(campusMap))
        let navigate = card(title:"室内导航",detail:"选择室内地图与目的地，开启 AR 指引",symbol:"location.north.line.fill",color:.systemTeal,action:#selector(navigation))
        let mapping = card(title:"建图",detail:"扫描空间，在地面标点并连接路线",symbol:"map.fill",color:.systemIndigo,action:#selector(mapping))
        let stack = UIStackView(arrangedSubviews:[heading,subtitle,campus,navigate,mapping]);stack.axis = .vertical;stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:24),
            stack.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-24),
            stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:30),
            stack.bottomAnchor.constraint(lessThanOrEqualTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-20)])
    }
    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        subtitle.text = "本地几何定位 · \(LiDARNavigationStore.maps().count) 张可导航地图\n第二阶段验证 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.2.0")"
    }
    private func card(title:String,detail:String,symbol:String,color:UIColor,action:Selector) -> UIButton {
        let button = UIButton(type:.system)
        var config = UIButton.Configuration.filled();config.baseBackgroundColor = color;config.baseForegroundColor = .white
        config.title = title;config.subtitle = detail;config.titleAlignment = .leading;config.image = UIImage(systemName:symbol)
        config.imagePlacement = .leading;config.imagePadding = 20;config.titlePadding = 9
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize:34,weight:.medium)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in var out = incoming;out.font = .systemFont(ofSize:28,weight:.bold);return out }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in var out = incoming;out.font = .systemFont(ofSize:14,weight:.regular);return out }
        config.contentInsets = NSDirectionalEdgeInsets(top:24,leading:24,bottom:24,trailing:20)
        config.background.cornerRadius = 25;button.configuration = config;button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant:142).isActive = true
        button.addTarget(self,action:action,for:.touchUpInside);return button
    }
    @objc private func campusMap() {
        guard let host = navigationController else { return }
        let coordinator = LiDARTripCoordinator(host:host);trip = coordinator
        host.pushViewController(coordinator.makeCampusController(),animated:true)
    }
    @objc private func navigation() { navigationController?.pushViewController(LiDARCampusBrowserController(mode:.navigation),animated:true) }
    @objc private func mapping() { navigationController?.pushViewController(LiDARCampusBrowserController(mode:.mapping),animated:true) }
    @objc private func settings() { navigationController?.pushViewController(LiDARSettingsController(style:.insetGrouped),animated:true) }
}

final class LiDARSettingsController: UITableViewController {
    private var names = ["几何地图与备份","原始扫描与 ZIP 导入导出","几何导航验证记录","原路网与 ARWorldMap 工具","存储空间与清理","第二阶段使用说明"]
    override func viewDidLoad() {
        super.viewDidLoad();title = "设置"
        names.append("导航界面视觉稿（不开相机）")
        #if DEBUG
        names.append("界面预览（不采集）")
        #endif
        names.append("校园地图数据")
        names.append("电梯呼叫按钮");names.append("电梯呼叫页预览")
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { names.count }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.value1,reuseIdentifier:nil);c.textLabel?.text = names[p.row];c.accessoryType = .disclosureIndicator
        if names[p.row] == "电梯呼叫按钮" { c.detailTextLabel?.text = ElevatorCallMode.current.title }
        return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true)
        if names[p.row] == "校园地图数据" { navigationController?.pushViewController(CampusMapDataController(),animated:true);return }
        if names[p.row] == "电梯呼叫按钮" {
            let sheet = UIAlertController(title:"电梯呼叫按钮",message:ElevatorCallMode.allCases.reversed().map { "\($0.title)：\($0.detail)" }.joined(separator:"\n"),preferredStyle:.actionSheet)
            for mode in ElevatorCallMode.allCases.reversed() {
                sheet.addAction(UIAlertAction(title:mode.title+(mode == ElevatorCallMode.current ? " ✓" : ""),style:.default) { [weak tableView] _ in
                    ElevatorCallMode.current = mode;tableView?.reloadRows(at:[p],with:.none)
                })
            }
            sheet.addAction(UIAlertAction(title:"取消",style:.cancel))
            sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at:p)
            present(sheet,animated:true);return
        }
        if names[p.row] == "电梯呼叫页预览" { present(ElevatorPanelPreviewController(),animated:true);return }
        switch p.row {
        case 0:navigationController?.pushViewController(LiDARCampusBrowserController(mode:.mapping),animated:true)
        case 1:navigationController?.pushViewController(LiDARLibraryController(),animated:true)
        case 2:navigationController?.pushViewController(LiDARNavigationRunsController(style:.insetGrouped),animated:true)
        case 3:navigationController?.pushViewController(CampusHomeController(style:.insetGrouped),animated:true)
        case 4:navigationController?.pushViewController(CampusStorageController(),animated:true)
        case 6:navigationController?.pushViewController(NavigationDesignPreviewController(),animated:true)
        #if DEBUG
        case 7:
            campusChoices("界面预览（不采集）",choices:[
                ("标点命名",{ [weak self] in
                    let naming = LiDARNodeNamingController(number:1) { [weak self] value in
                        guard let value else { return };self?.campusMessage("仅预览，未保存", "名称：\(value.name ?? "自动编号")\n类型：\(value.kind.title)")
                    }
                    self?.present(UINavigationController(rootViewController:naming),animated:true)
                }),
                ("门牌列表（示例）",{ [weak self] in
                    let nodes = [LiDARRouteNode(name:"1309",position:ProbePoint(0,0,0),id:"preview-room",kind:.room),LiDARRouteNode(name:"手动活动室",position:ProbePoint(2,0,0),id:"manual-room",kind:.room)]
                    let records = [
                        LiDARLandmark(category:.room_plate,trigger:.manual,text:LiDARLandmarkText(raw:"界面示例 · 1309",candidates:[],confirmedByUser:true,edited:false),destination:LiDARLandmarkDestination(enabled:true,node_id:"preview-room"),geometry:.unknown(),evidence:[]),
                        LiDARLandmark(category:.room_plate,trigger:.manual,text:LiDARLandmarkText(raw:"界面示例 · 未设入口的1310",candidates:[],confirmedByUser:true,edited:false),destination:LiDARLandmarkDestination(enabled:false,node_id:nil),geometry:.unknown(),evidence:[])]
                    self?.present(UINavigationController(rootViewController:LiDARPlateListController(landmarks:records,nodes:nodes)),animated:true)
                }),
                ("手动房间命名",{ [weak self] in
                    let naming = LiDARRoomNamingController(names:["1309","活动室"]) { [weak self] name in
                        guard let name else { return };self?.campusMessage("仅预览，未保存","房间名称：\(name)\n真机上下一步确认入口地面位置。")
                    }
                    self?.present(UINavigationController(rootViewController:naming),animated:true)
                }),
                ("门牌确认",{ [weak self] in
                    let image = UIGraphicsImageRenderer(size:CGSize(width:400,height:150)).image { c in
                        UIColor.systemGray6.setFill();c.fill(CGRect(x:0,y:0,width:400,height:150))
                        ("1309\n界面预览" as NSString).draw(in:CGRect(x:25,y:20,width:350,height:110),withAttributes:[.font:UIFont.systemFont(ofSize:36,weight:.semibold),.foregroundColor:UIColor.label])
                    }
                    let review = LiDARPlateReviewController(image:image,recognized:"1309",candidates:["1309","1809"],measurement:"三维位置未知：这是界面预览，没有采集相机或深度。") { [weak self] input in
                        guard let input else { return };self?.campusMessage("仅预览，未保存","文字：\(input.text)\n类别：\(input.category)\n安装位置：\(input.mount == .wall ? "贴在墙上" : input.mount == .door ? "贴在门上" : "不确定")\n下一步设置入口：\(input.setEntrance ? "是" : "否，仅记录")")
                    }
                    self?.present(UINavigationController(rootViewController:review),animated:true)
                }),
                ("点云叠加（合成布局）",{ [weak self] in self?.navigationController?.pushViewController(LiDAROverlayLayoutPreviewController(),animated:true) })])
        #endif
        default:campusMessage("第二阶段怎么用","先选择楼栋和楼层，再新建区域；旧地图可在“未分类”中重新归类。\n\n采集要领：距离固定结构约1–3米，缓慢行走，换距离和角度，上下轻微倾斜；避开玻璃镜面。可来回观察，但返回起点不会自动修复漂移，若墙面重影应暂停检查。过热时先降温。\n\n建图：新建局部地图 → 缓慢扫描墙角、门框和地面 → ＋对准地面标点，默认连接上一个点 → 保存。\n\n导航：选地图、所在起点附近（或不知道起点）和目的地 → 开始定位，观察周围约6秒 → 手机本地求解 → 预览候选路线 → 核对后开始导航。可重新定位或报告错位。\n\n先做5–10米、带转弯的小区域。重叠率不是正确概率；多个位置相似时换方向扫描。每次导航都不加载 ARWorldMap。旧的原始扫描不能直接变成带路线的新地图。")
        }
    }
}

enum LiDARNavigationStore {
    static let queue = DispatchQueue(label:"lidar.navigation.storage",qos:.userInitiated)
    struct CrossTargets { let targets:[LiDARNodeRef];let maps:[String:(URL,LiDARNavigationMap)];let links:[LiDARMapLink] }
    /// Loads a map with everything indoor navigation uses and builds its controller (main-thread completion).
    /// `start` is a node id prior, `resume` a last-position prior; `cross` navigates to other maps through links.
    static func openIndoor(_ url:URL,destinations:[String],name:String,start:String?,cross:CrossTargets?,resume:ProbePoint?,
                           onFinished:((_ arrived:Bool,_ walkedM:Double,_ floorChanges:Int,_ endNode:LiDARNodeRef?) -> Void)? = nil,completion:@escaping (Result<UIViewController,Error>) -> Void) {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard LiDARGeometryARController.supported else { completion(.failure(CampusError.invalid("导航需要支持 LiDAR 的 iPhone。")));return }
        queue.async {
            let result = Result { () -> (LiDARNavigationMap,[ProbePoint],LiDARLandmarkSet?,LiDARMagnetic.Reference?,LiDARPassageCalibration?,LiDARSpaceGrid?) in
                let (map,points) = try load(url)
                let space = spaceInputs(url,map:map,points:points)
                return (map,points,try LiDARLandmarkSet.load(url,map:map,geometrySHA256:try CampusFiles.hash(url.appendingPathComponent("geometry.f32"))),
                        magneticReference(url,map:map),space.calibration,space.grid)
            }
            DispatchQueue.main.async {
                completion(result.map { (map,points,landmarks,magnetic,calibration,grid) -> UIViewController in
                    let controller = LiDARGeometryARController(map:map,points:points,destinations:destinations,destinationName:name,startNodeID:start,landmarks:landmarks,
                                                               magneticReference:magnetic,calibration:calibration,spaceGrid:grid,resumePosition:resume)
                    if let cross { controller.setCrossMap(targets:cross.targets,directories:cross.maps.mapValues(\.0),maps:cross.maps.mapValues(\.1),links:cross.links) }
                    controller.onFinished = onFinished
                    return controller
                })
            }
        }
        #else
        completion(.failure(CampusError.invalid("实时 AR 导航请在 iPhone 上运行。")))
        #endif
    }
    static let runs = ProbeIO.documents.appendingPathComponent("GeometryNavigationRuns",isDirectory:true)
    static func maps() -> [(URL,LiDARNavigationMap)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at:LiDARLibrary.root,includingPropertiesForKeys:nil)) ?? []
        return urls.compactMap { url in
            // A supplement save interrupted mid-swap leaves a folder that no longer loads; restore its newest version.
            if LiDARMapVersions.hasOpenTransaction(url) || (FileManager.default.fileExists(atPath:url.appendingPathComponent(LiDARMapVersions.directoryName).path)
               && (try? LiDARNavigationArchive.load(url)) == nil) { LiDARMapVersions.recoverIfBroken(url) }
            // Still pending after recovery (e.g. rollback failed): keep it closed rather than list a mixed map.
            guard !LiDARMapVersions.hasOpenTransaction(url),let data = try? Data(contentsOf:url.appendingPathComponent("navigation.json")),
                  let map = try? JSONDecoder().decode(LiDARNavigationMap.self,from:data), (try? map.validate()) != nil else { return nil }
            return (url,map)
        }.sorted { $0.1.created_utc > $1.1.created_utc }
    }
    /// The map's compass reference: magnetic-reference.json, or for maps saved before it existed,
    /// derived from the initial session's raw readings in magnetic-samples.jsonl. nil when neither exists.
    static func magneticReference(_ url:URL,map:LiDARNavigationMap) -> LiDARMagnetic.Reference? {
        if let data = try? Data(contentsOf:url.appendingPathComponent(LiDARMagnetic.Reference.fileName)),
           let r = try? JSONDecoder().decode(LiDARMagnetic.Reference.self,from:data),r.method == LiDARMagnetic.method { return r }
        // Older maps: rebuild from raw readings. The initial session's readings are in the map's
        // sidecar; a supplement's are in its run log on this phone, moved by its confirmed transform.
        var cells = [LiDARMagnetic.Reference.Cell]()
        if let raw = try? Data(contentsOf:url.appendingPathComponent("magnetic-samples.jsonl")) {
            cells += LiDARMagnetic.reference(LiDARMagnetic.samples(jsonl:raw,sessionID:map.session_id)).cells
        }
        let supplements = (map.sources ?? []).filter { $0.kind == LiDARMapSource.supplement }
        if !supplements.isEmpty {
            let runs = (try? FileManager.default.contentsOfDirectory(at:runs,includingPropertiesForKeys:nil)) ?? []
            for source in supplements {
                let marker = Data(source.session_id.utf8)
                for run in runs {
                    guard let raw = try? Data(contentsOf:run.appendingPathComponent("magnetic-heading.jsonl")),raw.range(of:marker) != nil else { continue }
                    cells += LiDARMagnetic.reference(LiDARMagnetic.moved(LiDARMagnetic.samples(jsonl:raw,sessionID:source.session_id),by:source.map_from_session)).cells
                }
            }
        }
        guard !cells.isEmpty else { return nil }
        let reference = LiDARMagnetic.Reference(cell_m:3,cells:cells)
        // Cache the rebuilt reference beside the map (a derived sidecar, kept by versions and export).
        if (try? LiDARNavigationArchive.write(reference,to:url.appendingPathComponent(LiDARMagnetic.Reference.fileName))) != nil { try? ProbeIO.makeManifest(at:url) }
        return reference
    }
    /// Space routing (experimental): the map's calibration and walkable grid. The walked trajectory
    /// comes from walked-trajectory.json, or for older maps from the scan manifests on this phone
    /// (the map's own scan plus its supplement scans), and is then cached as a sidecar.
    static func spaceInputs(_ url:URL,map:LiDARNavigationMap,points:[ProbePoint]) -> (calibration:LiDARPassageCalibration?,grid:LiDARSpaceGrid?) {
        let calibration = try? LiDARPassageCalibration.load(url,mapID:map.map_id)
        var trajectory:LiDARWalkedTrajectory?
        if let data = try? Data(contentsOf:url.appendingPathComponent(LiDARWalkedTrajectory.fileName)),
           let t = try? JSONDecoder().decode(LiDARWalkedTrajectory.self,from:data),t.map_id == map.map_id { trajectory = t }
        else {
            var scans = [LiDARScanManifest]()
            if let data = try? Data(contentsOf:url.appendingPathComponent("scan.json")),let m = try? JSONDecoder().decode(LiDARScanManifest.self,from:data) { scans.append(m) }
            for dir in (try? FileManager.default.contentsOfDirectory(at:LiDARLibrary.root,includingPropertiesForKeys:nil)) ?? [] where dir != url {
                guard let data = try? Data(contentsOf:dir.appendingPathComponent("scan.json")),
                      let m = try? JSONDecoder().decode(LiDARScanManifest.self,from:data),m.supplement_of_map_id == map.map_id else { continue }
                scans.append(m)
            }
            let rebuilt = LiDARWalkedTrajectory.from(mapID:map.map_id,scans:scans)
            if !rebuilt.polylines.isEmpty {
                trajectory = rebuilt
                if let data = try? JSONEncoder().encode(rebuilt) { _ = try? LiDARMapVersions.publishSidecar(url,name:LiDARWalkedTrajectory.fileName,data:data) }
            }
        }
        return (calibration,try? LiDARSpaceGrid.build(points:points,trajectory:trajectory,calibration:calibration))
    }
    static func load(_ url:URL) throws -> (LiDARNavigationMap,[ProbePoint]) {
        try LiDARNavigationArchive.load(url)
    }
    static func write<T:Encodable>(_ value:T,to url:URL) throws {
        try LiDARNavigationArchive.write(value,to:url)
    }
    static func importMap(_ zip:URL) throws {
        let destination = try LiDARNavigationArchive.importZIP(zip,into:LiDARLibrary.root)
        let (map,_) = try load(destination)
        if case .placed(let placement) = LiDARMapPlacement.load(destination,mapID:map.map_id) {
            var catalog = try LiDARCampusCatalog.load(root:LiDARLibrary.root)
            if catalog.adopt(placement) { try catalog.save(root:LiDARLibrary.root) }
        }
    }
    static func exportMap(_ url:URL) throws -> URL {
        let (map,_) = try load(url)
        let output = ProbeIO.documents.appendingPathComponent("Exports/geometry-map-"+map.map_id+".zip")
        try LiDARNavigationArchive.exportZIP(url,to:output);return output
    }
}

final class LiDARGeometryLibraryController: UITableViewController,UIDocumentPickerDelegate {
    enum Mode { case mapping,navigation }
    private let mode:Mode
    private var maps = [(URL,LiDARNavigationMap)]()
    private var busy = false
    /// Set while the file picker is open for a passage calibration of this map.
    private var calibrationTarget:(URL,LiDARNavigationMap)?
    private let filterIDs:Set<String>?
    private var autoOpenMapID:String?
    /// When set, map actions present on this screen instead (a region opened from the floor view).
    weak var host:UIViewController?
    var onChange:(() -> Void)?
    private var showsCreate:Bool { mode == .mapping && filterIDs == nil }
    // Every sheet and alert (the campus helpers call present) goes to the host while acting for it.
    override func present(_ controller:UIViewController,animated:Bool,completion:(() -> Void)? = nil) {
        guard let host else { super.present(controller,animated:animated,completion:completion);return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.view;popover.sourceRect = CGRect(x:host.view.bounds.midX,y:host.view.bounds.midY,width:1,height:1)
        }
        host.present(controller,animated:animated,completion:completion)
    }
    private var actionNavigation:UINavigationController? { host?.navigationController ?? navigationController }
    /// Opens one map's actions without showing this list.
    func openMap(_ id:String) { reload();if let item = maps.first(where:{ $0.1.map_id == id }) { open(item) } }
    init(mode:Mode,mapIDs:Set<String>? = nil,title:String? = nil,autoOpenMapID:String? = nil) {
        self.mode = mode;filterIDs = mapIDs;self.autoOpenMapID = autoOpenMapID
        super.init(style:.insetGrouped);self.title = title ?? (mode == .mapping ? "建图" : "选择导航地图")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"导入",style:.plain,target:self,action:#selector(importMap))
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);reload() }
    private func reload() { onChange?();maps = LiDARNavigationStore.maps().filter { filterIDs?.contains($0.1.map_id) ?? true };tableView.reloadData() }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        if let id = autoOpenMapID,let item = maps.first(where:{$0.1.map_id == id}) { autoOpenMapID = nil;open(item) }
    }
    override func numberOfSections(in tableView:UITableView) -> Int { showsCreate ? 2 : 1 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { showsCreate && section == 0 ? 1 : maps.count }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? { showsCreate && section == 0 ? "现场采集" : "本机几何地图 · \(maps.count)" }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        if showsCreate && section == 0 { return "扫描和标线在同一个会话中完成，自动共用坐标。先制作5–10米、带一个转弯的局部地图。" }
        return maps.isEmpty ? "还没有可导航地图。请先建图，或导入本App导出的几何地图备份。第一阶段原始扫描仍在设置中。" : "地图只在本机处理。轻量备份包含几何和路线；原始深度与照片可在设置中单独导出。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.detailTextLabel?.numberOfLines = 0;c.accessoryType = .disclosureIndicator
        if showsCreate && p.section == 0 { c.textLabel?.text = "＋ 新建几何地图";c.textLabel?.textColor = .systemTeal;c.detailTextLabel?.text = "扫描环境 · 地面标点 · 自动连线" }
        else { let map = maps[p.row].1;c.textLabel?.text = map.name;c.detailTextLabel?.text = "\(map.nodes.count) 个节点 · \(map.edges.count) 条连接 · \(map.point_count) 个运行点" }
        return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true);guard !busy else { return }
        if showsCreate && p.section == 0 { create();return }
        open(maps[p.row])
    }
    private func open(_ item:(URL,LiDARNavigationMap)) {
        if mode == .navigation { destinations(item) }
        else {
            campusChoices(item.1.name,message:item.1.nodes.map(\.name).joined(separator:" → "),choices:[
                ("选择目的地并导航",{ [weak self] in self?.destinations(item) }),
                ("从此图补采（扩展点云与路网）",{ [weak self] in self?.supplementStart(item) }),
                ("跨图连接（楼梯 / 电梯 / 同层通道）",{ [weak self] in self?.manageLinks(item) }),
                ("导入通行空间校准文件（工作台导出）",{ [weak self] in self?.pickCalibration(item) }),
                ("修改节点类型（无需重扫）",{ [weak self] in self?.editNodeKind(item) }),
                ("出入口室外坐标（衔接室外导航）",{ [weak self] in self?.manageEntrances(item) }),
                ("电梯呼梯装置",{ [weak self] in self?.manageElevatorDevices(item) }),
                ("恢复上一版本",{ [weak self] in self?.restoreVersion(item) }),
                ("归类 / 修改楼栋、楼层和区域",{ [weak self] in self?.classify(item) }),
                ("门牌列表",{ [weak self] in self?.showPlates(item) }),
                ("修改门牌文字（识别用）",{ [weak self] in self?.editPlateText(item) }),
                ("导出轻量地图备份",{ [weak self] in self?.export(item.0) }),
                ("查看点云与路网分布",{ [weak self] in self?.showDistribution(item) }),
                ("删除这张地图",{ [weak self] in self?.delete(item) })])
        }
    }
    /// "1F · 舞台东" from the map's placement, or its name when unclassified.
    static func label(_ url:URL,_ map:LiDARNavigationMap,catalog:LiDARCampusCatalog?) -> String {
        if case .placed(let p) = LiDARMapPlacement.load(url,mapID:map.map_id) {
            return "\(catalog?.resolve(p)?.floor.name ?? p.floor_name) · \(p.region_name)"
        }
        return map.name
    }
    private func manageLinks(_ item:(URL,LiDARNavigationMap)) {
        let all = LiDARNavigationStore.maps(),byID = Dictionary(all.map { ($0.1.map_id,$0) },uniquingKeysWith:{ a,_ in a })
        let catalog = try? LiDARCampusCatalog.load(root:LiDARLibrary.root)
        let links = Self.loadLinksResolvingElevators()
        func name(_ r:LiDARNodeRef) -> String {
            guard let m = byID[r.map_id] else { return "已删除的地图" }
            return Self.label(m.0,m.1,catalog:catalog)+" · "+(m.1.nodes.first { $0.id == r.node_id }?.name ?? "已删除的节点")
        }
        var choices:[(String,() -> Void)] = links.links(touching:item.1.map_id).map { l in
            let kind = l.kind == .elevator ? "\(l.kind.title)（\(l.group_id ?? "未编号")）" : l.kind.title
            return ("\(kind)：\(name(l.a)) ↔ \(name(l.b))",{ [weak self] in self?.linkActions(l,item:item,maps:all,links:links) })
        }
        choices.insert(("＋ 新建连接",{ [weak self] in self?.newLink(item,maps:all,catalog:catalog) }),at:0)
        campusChoices("跨图连接",message:"楼梯连接两端的楼梯口节点，电梯连接电梯口节点，同层通道连接两张区域图里的同一位置。导航时按连接换图并在对应节点附近重新定位。",choices:choices)
    }
    /// Elevator links saved before elevator ids existed get one here, once, from the mapping side.
    /// Navigation applies the same deterministic result in memory without writing.
    static func loadLinksResolvingElevators() -> LiDARCampusLinks {
        let loaded = (try? LiDARCampusLinks.load(root:LiDARLibrary.root)) ?? LiDARCampusLinks()
        let (resolved,assigned) = loaded.resolvingElevatorGroups()
        if assigned > 0 { try? resolved.save(root:LiDARLibrary.root) }
        return resolved
    }
    private func linkActions(_ link:LiDARMapLink,item:(URL,LiDARNavigationMap),maps all:[(URL,LiDARNavigationMap)],links:LiDARCampusLinks) {
        var choices:[(String,() -> Void)] = []
        if link.kind == .elevator {
            choices.append(("改为另一部电梯",{ [weak self] in
                self?.chooseElevator(for:item,maps:all,links:links,excluding:link.group_id) { group in
                    self?.saveLinks { l in if let i = l.links.firstIndex(where: { $0.id == link.id }) { l.links[i].group_id = group } }
                }
            }))
        }
        choices.append(("删除这条连接",{ [weak self] in self?.saveLinks { $0.links.removeAll { $0.id == link.id } } }))
        campusChoices(link.kind == .elevator ? "\(link.kind.title)（\(link.group_id ?? "未编号")）" : link.kind.title,choices:choices)
    }
    /// Which elevator a new or edited elevator link belongs to: this building's elevators or a new one.
    private func chooseElevator(for item:(URL,LiDARNavigationMap),maps all:[(URL,LiDARNavigationMap)],links:LiDARCampusLinks,
                                excluding:String? = nil,done:@escaping (String) -> Void) {
        var buildingOf = [String:String]()
        for (url,map) in all { if case .placed(let p) = LiDARMapPlacement.load(url,mapID:map.map_id) { buildingOf[map.map_id] = p.building_id } }
        let building = buildingOf[item.1.map_id]
        var groups = [String]()
        for l in links.links where l.kind == .elevator {
            guard let g = l.group_id,!g.isEmpty,!groups.contains(g),g != excluding else { continue }
            if building == nil || buildingOf[l.a.map_id] == building || buildingOf[l.b.map_id] == building { groups.append(g) }
        }
        groups.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        let next = links.nextElevatorGroupName()
        campusChoices("这是哪部电梯？",message:"同一部电梯在各楼层的连接请选同一个，呼梯装置按它绑定。",
                      choices:groups.map { g in (g,{ done(g) }) }+[("新的一部电梯（\(next)）",{ done(next) })])
    }
    private func newLink(_ item:(URL,LiDARNavigationMap),maps all:[(URL,LiDARNavigationMap)],catalog:LiDARCampusCatalog?) {
        campusChoices("连接类型",choices:LiDARMapLink.Kind.allCases.map { kind in (kind.title,{ [weak self] in
            guard let self else { return }
            let mine = item.1.nodes.filter { kind.nodeKind == nil || $0.resolvedKind == kind.nodeKind }
            guard !mine.isEmpty else { self.campusMessage("没有\(kind.nodeKind?.title ?? "节点")","这张地图里没有\(kind.nodeKind?.title ?? "节点")。可先用“修改节点类型”把对应节点设为\(kind.nodeKind?.title ?? "")。");return }
            self.campusChoices("本图的\(kind.nodeKind?.title ?? "节点")",choices:mine.map { node in (node.name,{ [weak self] in
                guard let self else { return }
                let others = all.filter { $0.1.map_id != item.1.map_id }
                guard !others.isEmpty else { self.campusMessage("没有其他地图","请先建立另一层或另一区域的地图。");return }
                self.campusChoices("连接到哪张地图",choices:others.map { other in (Self.label(other.0,other.1,catalog:catalog),{ [weak self] in
                    guard let self else { return }
                    let theirs = other.1.nodes.filter { kind.nodeKind == nil || $0.resolvedKind == kind.nodeKind }
                    guard !theirs.isEmpty else { self.campusMessage("对方地图没有\(kind.nodeKind?.title ?? "节点")","请先在那张地图里把对应节点设为\(kind.nodeKind?.title ?? "")。");return }
                    self.campusChoices("对方的\(kind.nodeKind?.title ?? "节点")",choices:theirs.map { target in (target.name,{ [weak self] in
                        guard let self else { return }
                        let a = LiDARNodeRef(map:item.1.map_id,node:node.id),b = LiDARNodeRef(map:other.1.map_id,node:target.id)
                        let save:(String?) -> Void = { [weak self] group in
                            let link = LiDARMapLink(kind:kind,a:a,b:b,groupID:group)
                            self?.saveLinks { try $0.add(link,maps:[item.1.map_id:item.1,other.1.map_id:other.1]) }
                        }
                        guard kind == .elevator else { save(nil);return }
                        // A door already used by an elevator link names its elevator; otherwise ask.
                        let links = Self.loadLinksResolvingElevators()
                        if let group = links.elevatorGroup(at:a) ?? links.elevatorGroup(at:b) { save(group);return }
                        self.chooseElevator(for:item,maps:all,links:links) { save($0) }
                    }) })
                }) })
            }) })
        }) })
    }
    private func saveLinks(_ edit:@escaping (inout LiDARCampusLinks) throws -> Void) {
        busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { var l = try LiDARCampusLinks.load(root:LiDARLibrary.root);try edit(&l);try l.save(root:LiDARLibrary.root) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch result { case .success:self.campusMessage("已保存","跨图连接已更新。");case .failure(let error):self.campusError(error) }
            }
        }
    }
    /// Binds this map's exit nodes to where their doors are outside (and the building to its outdoor
    /// OSM id), so outdoor navigation can lead to a real door and indoor navigation can start there.
    private func manageEntrances(_ item:(URL,LiDARNavigationMap)) {
        guard case .placed(let placement) = LiDARMapPlacement.load(item.0,mapID:item.1.map_id) else {
            campusMessage("请先归类","出入口属于某栋楼。请先用“归类 / 修改楼栋、楼层和区域”把这张地图放进楼栋和楼层。");return
        }
        let exits = item.1.nodes.filter { $0.resolvedKind == .exit }
        guard !exits.isEmpty else { campusMessage("没有大楼出入口节点","请先用“修改节点类型”把门口的节点设为“大楼出入口”。");return }
        let bindings = (try? LiDARCampusBindings.load(root:LiDARLibrary.root)) ?? LiDARCampusBindings()
        let osm = bindings.osmID(forBuilding:placement.building_id),campus = LiDARTripCoordinator.bundledCampus()
        let osmName = osm.flatMap { campus?.building(id:$0)?.fullName } ?? osm
        var choices:[(String,() -> Void)] = [("所在楼栋（校园地图）：\(osmName ?? "未绑定") · 在地图上点选",{ [weak self] in
            guard let self,let campus else { self?.campusMessage("校园地图缺失","安装包中没有校园地图数据。");return }
            let pick = CampusPickController(campus:campus,mode:.building(currentOSM:osm))
            pick.onBuilding = { [weak self] b in self?.saveBindings("已绑定到「\(b.fullName)」") { try $0.bindBuilding(placement.building_id,osmID:b.id) } }
            let nav = UINavigationController(rootViewController:pick);nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
        })]
        for node in exits {
            let ref = LiDARNodeRef(map:item.1.map_id,node:node.id),e = bindings.entrance(at:ref)
            let state = e?.position.map { p in String(format:"%.6f, %.6f%@%@",p.lat,p.lon,e?.accuracy_m.map { String(format:" ±%.0f 米",$0) } ?? "",e?.verified == true ? " · 已核实" : "") } ?? "未记录"
            choices.append(("\(node.name)：\(state)",{ [weak self] in self?.entranceActions(node:node,ref:ref,building:placement.building_id,existing:e) }))
        }
        campusChoices("出入口室外坐标",message:"每个“大楼出入口”节点记录它那扇门在室外的位置。室外导航会导到这扇门，点“进入室内”后从这里开始恢复定位。",choices:choices)
    }
    /// Hall-call devices per elevator and floor of this map's building (needs elevator links between floors).
    private func manageElevatorDevices(_ item:(URL,LiDARNavigationMap)) {
        guard case .placed(let placement) = LiDARMapPlacement.load(item.0,mapID:item.1.map_id) else {
            campusMessage("请先归类","电梯装置按楼栋和楼层绑定。请先把这张地图归类到楼栋和楼层。");return
        }
        let all = LiDARNavigationStore.maps()
        var placements = [String:LiDARMapPlacement]()
        for (url,map) in all { if case .placed(let p) = LiDARMapPlacement.load(url,mapID:map.map_id) { placements[map.map_id] = p } }
        let catalog = (try? LiDARCampusCatalog.load(root:LiDARLibrary.root)) ?? LiDARCampusCatalog()
        let links = Self.loadLinksResolvingElevators().links
        let page = ElevatorBindingController(buildingID:placement.building_id,catalog:catalog,placements:placements,links:links)
        let nav = UINavigationController(rootViewController:page);nav.modalPresentationStyle = .fullScreen;present(nav,animated:true)
    }
    private func entranceActions(node:LiDARRouteNode,ref:LiDARNodeRef,building:String,existing:LiDARCampusBindings.Entrance?) {
        var choices:[(String,() -> Void)] = [
            (existing?.position == nil ? "在校园地图上点选门的位置" : "在地图上修改门的位置（拖动图钉）",{ [weak self] in
                guard let self,let campus = LiDARTripCoordinator.bundledCampus() else { return }
                let osm = ((try? LiDARCampusBindings.load(root:LiDARLibrary.root)) ?? LiDARCampusBindings()).osmID(forBuilding:building)
                let current = existing?.position.map { OutdoorCoordinate(latitude:$0.lat,longitude:$0.lon) }
                let pick = CampusPickController(campus:campus,mode:.door(buildingOSM:osm,current:current))
                pick.onDoor = { [weak self] p in
                    self?.saveBindings("已记录「\(node.name)」的位置") { try $0.setEntrance(ref,building:building,position:.init(lat:p.latitude,lon:p.longitude),accuracy:nil,source:.manual) }
                }
                let nav = UINavigationController(rootViewController:pick);nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
            }),
            ("站在这扇门外，记录手机定位",{ [weak self] in self?.recordDoor(node:node,ref:ref,building:building) }),
            ("手动填写经纬度",{ [weak self] in
                let a = UIAlertController(title:"「\(node.name)」室外坐标",message:"WGS-84 经纬度（与校园地图相同）",preferredStyle:.alert)
                a.addTextField { $0.placeholder = "纬度，例如 31.17900";$0.text = existing?.position.map { String($0.lat) };$0.keyboardType = .numbersAndPunctuation }
                a.addTextField { $0.placeholder = "经度，例如 121.59050";$0.text = existing?.position.map { String($0.lon) };$0.keyboardType = .numbersAndPunctuation }
                a.addAction(UIAlertAction(title:"取消",style:.cancel))
                a.addAction(UIAlertAction(title:"保存",style:.default) { [weak self] _ in
                    guard let lat = Double(a.textFields?[0].text ?? ""),let lon = Double(a.textFields?[1].text ?? "") else { self?.campusMessage("格式不对","请填写数字形式的纬度和经度。");return }
                    self?.saveBindings("已保存「\(node.name)」的坐标") { try $0.setEntrance(ref,building:building,position:.init(lat:lat,lon:lon),accuracy:nil,source:.manual) }
                })
                self?.present(a,animated:true)
            })]
        if let e = existing,let position = e.position {
            choices.insert((e.access_path == nil ? "添加门的引路（从门到路网）" : "修改门的引路",{ [weak self] in
                guard let self,let campus = LiDARTripCoordinator.bundledCampus() else { return }
                let osm = ((try? LiDARCampusBindings.load(root:LiDARLibrary.root)) ?? LiDARCampusBindings()).osmID(forBuilding:building)
                let door = OutdoorCoordinate(latitude:position.lat,longitude:position.lon)
                let pick = CampusPickController(campus:campus,mode:.accessPath(door:door,doorName:node.name,buildingOSM:osm,
                                                existing:e.access_path?.map { OutdoorCoordinate(latitude:$0.lat,longitude:$0.lon) }))
                pick.onAccessPath = { [weak self] path in
                    self?.saveBindings("已保存「\(node.name)」的引路") { try $0.setAccessPath(ref,path.map { .init(lat:$0.latitude,lon:$0.longitude) }) }
                }
                let nav = UINavigationController(rootViewController:pick);nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
            }),at:1)
            if e.access_path != nil { choices.append(("删除门的引路",{ [weak self] in self?.saveBindings("已删除引路") { try $0.setAccessPath(ref,nil) } })) }
            choices.append((e.verified ? "取消“已现场核实”" : "标记为已现场核实",{ [weak self] in
                self?.saveBindings(e.verified ? "已取消核实标记" : "已标记为现场核实") {
                    try $0.setEntrance(ref,building:building,position:position,accuracy:e.accuracy_m,source:e.source ?? .manual,door:e.campus_door,verified:!e.verified)
                }
            }))
            choices.append(("删除这个出入口的坐标",{ [weak self] in self?.saveBindings("已删除") { $0.removeEntrance(at:ref) } }))
        }
        campusChoices(node.name,choices:choices)
    }
    private var doorLocator:LiDARDoorLocator?
    private func recordDoor(node:LiDARRouteNode,ref:LiDARNodeRef,building:String) {
        guard doorLocator == nil else { return }
        let waiting = UIAlertController(title:"正在定位「\(node.name)」",message:"请站在门外开阔处，手机保持不动，最多约 20 秒。",preferredStyle:.alert)
        let locator = LiDARDoorLocator();doorLocator = locator
        waiting.addAction(UIAlertAction(title:"取消",style:.cancel) { [weak self] _ in locator.cancel();self?.doorLocator = nil })
        present(waiting,animated:true)
        locator.start { [weak self] result in
            guard let self else { return };self.doorLocator = nil
            waiting.dismiss(animated:true) {
                switch result {
                case .failure(let error):self.campusMessage("没有记录",error.localizedDescription)
                case .success(let fix):
                    self.campusChoices(String(format:"定位精度约 ±%.0f 米",fix.accuracy),message:String(format:"%.6f, %.6f\n精度一般在 5–15 米；如果门旁信号差，可以稍后在开阔处重录或手动填写。",fix.point.lat,fix.point.lon),choices:[
                        ("保存这个位置",{ [weak self] in
                            self?.saveBindings("已记录「\(node.name)」的室外坐标") { try $0.setEntrance(ref,building:building,position:fix.point,accuracy:fix.accuracy,source:.gps) }
                        })])
                }
            }
        }
    }
    private func saveBindings(_ done:String,_ edit:@escaping (inout LiDARCampusBindings) throws -> Void) {
        busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { var b = try LiDARCampusBindings.load(root:LiDARLibrary.root);try edit(&b);try b.save(root:LiDARLibrary.root) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch result { case .success:self.campusMessage("已保存",done);case .failure(let error):self.campusError(error) }
            }
        }
    }
    private func editNodeKind(_ item:(URL,LiDARNavigationMap)) {
        campusChoices("选择节点",choices:item.1.nodes.map { node in ("\(node.name)（\(node.resolvedKind.title)）",{ [weak self] in
            self?.campusChoices("改为",choices:CampusNodeKind.allCases.map { kind in (kind.title,{ [weak self] in
                guard let self else { return };self.busy = true
                LiDARNavigationStore.queue.async { [weak self] in
                    let result = Result { try LiDARNavigationArchive.updateRoute(item.0) { try $0.setKind(node.id,kind) } }
                    DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload()
                        if case .failure(let error) = result { self.campusError(error) } else { self.campusMessage("已修改","「\(node.name)」已改为\(kind.title)；旧版本已保留。") }
                    }
                }
            }) })
        }) })
    }
    private func supplementStart(_ item:(URL,LiDARNavigationMap)) {
        let named = item.1.namedChoices()
        func pick(_ g:(name:String,nodeIDs:[String])) -> (String,() -> Void) { (g.name,{ [weak self] in self?.supplement(item.0,start:g.nodeIDs[0]) }) }
        chooseNamed("补采：选择所在起点附近",message:"先在原图中定位并人工确认，确认后才开始补采；新点云和路网写回这张地图，更新前自动保留旧版本。",
            lead:[("不知道起点（全图匹配）",{ [weak self] in self?.supplement(item.0,start:nil) })],rooms:named.rooms.map(pick),others:named.others.map(pick))
    }
    private func supplement(_ url:URL,start:String?) {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard LiDARGeometryARController.supported else { campusMessage("设备不支持","补采需要支持 LiDAR 的 iPhone。");return }
        busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { () -> (LiDARNavigationMap,[ProbePoint],LiDARLandmarkSet?,LiDARMagnetic.Reference?,LiDARPassageCalibration?,LiDARSpaceGrid?) in
                let (map,points) = try LiDARNavigationStore.load(url)
                let space = LiDARNavigationStore.spaceInputs(url,map:map,points:points)
                return (map,points,try LiDARLandmarkSet.load(url,map:map,geometrySHA256:try CampusFiles.hash(url.appendingPathComponent("geometry.f32"))),
                        LiDARNavigationStore.magneticReference(url,map:map),space.calibration,space.grid)
            }
            DispatchQueue.main.async {
                guard let self else { return };self.busy = false
                switch result {
                case .success(let (map,points,landmarks,magnetic,calibration,_)):
                    let controller = LiDARGeometryARController(map:map,points:points,destinations:[],destinationName:"补采",startNodeID:start,landmarks:landmarks,supplementOf:url,magneticReference:magnetic,calibration:calibration)
                    controller.onSaved = { [weak self] in self?.reload() }
                    let nav = UINavigationController(rootViewController:controller);nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
                case .failure(let error):self.campusError(error)
                }
            }
        }
        #else
        campusMessage("需要 iPhone","补采需要在支持 LiDAR 的 iPhone 上运行。")
        #endif
    }
    private func restoreVersion(_ item:(URL,LiDARNavigationMap)) {
        let versions = LiDARMapVersions.list(item.0)
        guard !versions.isEmpty else { campusMessage("没有旧版本","这张地图还没有被补采更新过。");return }
        campusChoices("恢复到哪个版本",message:"恢复前会先保存当前版本，因此恢复本身也可以撤回。",choices:versions.map { v in
            ("\(v.id.prefix(15)) · \(v.nodes) 节点 · \(v.point_count) 点",{ [weak self] in
                guard let self else { return };self.busy = true
                LiDARNavigationStore.queue.async { [weak self] in
                    let result = Result { try LiDARMapVersions.restore(item.0,id:v.id) }
                    DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload()
                        if case .failure(let error) = result { self.campusError(error) } else { self.campusMessage("已恢复","地图已恢复到所选版本。") }
                    }
                }
            })
        })
    }
    private func create() { navigationController?.pushViewController(LiDARCampusBrowserController(mode:.mapping),animated:true) }
    private func classify(_ item:(URL,LiDARNavigationMap)) {
        let picker = LiDARCampusBrowserController(mode:.mapping) { [weak self] building,floor in
            guard let self else { return }
            let region:String
            if case .placed(let p) = LiDARMapPlacement.load(item.0,mapID:item.1.map_id) { region = p.region_name } else { region = item.1.name }
            self.campusText("区域名称",value:region) { [weak self] value in
                guard let self else { return };self.busy = true
                LiDARNavigationStore.queue.async { [weak self] in
                    let result = Result {
                        let placement = try LiDARMapPlacement(mapID:item.1.map_id,building:building,floor:floor,region:value)
                        try placement.write(to:item.0)
                    }
                    DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload()
                        if case .failure(let error) = result { self.campusError(error) }
                    }
                }
            }
        }
        present(UINavigationController(rootViewController:picker),animated:true)
    }
    private func destinations(_ item:(URL,LiDARNavigationMap)) {
        let named = item.1.namedChoices()
        func pick(_ g:(name:String,nodeIDs:[String])) -> (String,() -> Void) { (g.name,{ [weak self] in self?.chooseDestination(item,start:g.nodeIDs[0]) }) }
        var lead:[(String,() -> Void)] = [("不知道起点（全图匹配）",{ [weak self] in self?.chooseDestination(item,start:nil) })]
        // The last trusted position on this map (same geometry only), offered as a start prior.
        if let hash = try? CampusFiles.hash(item.0.appendingPathComponent("geometry.f32")),
           let last = LiDARIndoorResume.load(root:LiDARLibrary.root).entry(mapID:item.1.map_id,geometrySHA256:hash) {
            let near = item.1.nodes.filter { !$0.name.isEmpty }.min { hypot($0.position.x-last.position.x,$0.position.z-last.position.z) < hypot($1.position.x-last.position.x,$1.position.z-last.position.z) }
            let ago = last.savedDate.map { Self.ago($0) } ?? ""
            lead.insert(("从上次位置出发（\(ago)\(near.map { " · 靠近「\($0.name)」" } ?? "")）",{ [weak self] in
                self?.chooseDestination(item,start:nil,resume:last.position)
            }),at:0)
        }
        chooseNamed("选择所在起点附近",message:"无需站在节点正上方。已知起点时按10、15、25米逐级匹配；不确定时请选择不知道起点。“上次位置”是本机记录的最后可信位置，仍需重新定位。",
            lead:lead,rooms:named.rooms.map(pick),others:named.others.map(pick))
    }
    private static func ago(_ date:Date) -> String {
        let s = max(0,Date().timeIntervalSince(date))
        return s < 3600 ? "\(max(1,Int(s/60))) 分钟前" : s < 86400 ? "\(Int(s/3600)) 小时前" : "\(Int(s/86400)) 天前"
    }
    private func chooseDestination(_ item:(URL,LiDARNavigationMap),start:String?,resume:ProbePoint? = nil) {
        let origin = resume != nil ? "上次位置" : item.1.nodes.first { $0.id == start }?.name ?? "不知道起点"
        busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let outcome = Result { try LiDARLandmarkSet.load(item.0,map:item.1,geometrySHA256:try CampusFiles.hash(item.0.appendingPathComponent("geometry.f32"))) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch outcome {
                case .failure(let error):self.campusError(error)
                case .success:
                    let named = item.1.namedChoices()
                    func local(_ group:(name:String,nodeIDs:[String])) -> (String,() -> Void) {
                        let title = group.name+(group.nodeIDs.count > 1 ? "（\(group.nodeIDs.count)个入口，自动选近）" : "")
                        return (title,{ [weak self] in self?.navigate(item.0,destinations:group.nodeIDs,destinationName:group.name,start:start,resume:resume) })
                    }
                    var choices = named.rooms.map(local)
                    var otherChoices = named.others.map(local)
                    // Other floors / regions reachable through links.
                    let all = LiDARNavigationStore.maps(),byID = Dictionary(all.map { ($0.1.map_id,$0) },uniquingKeysWith:{ a,_ in a })
                    let links = ((try? LiDARCampusLinks.load(root:LiDARLibrary.root)) ?? LiDARCampusLinks()).resolvingElevatorGroups().links.usable(maps:byID.mapValues(\.1))
                    var reachable = Set([item.1.map_id]),frontier = [item.1.map_id]
                    while let m = frontier.popLast() {
                        for l in links where l.a.map_id == m || (l.bidirectional && l.b.map_id == m) {
                            let other = l.a.map_id == m ? l.b.map_id : l.a.map_id
                            if reachable.insert(other).inserted { frontier.append(other) }
                        }
                    }
                    let catalog = try? LiDARCampusCatalog.load(root:LiDARLibrary.root)
                    for id in reachable.subtracting([item.1.map_id]).sorted() {
                        guard let other = byID[id] else { continue }
                        let label = Self.label(other.0,other.1,catalog:catalog)
                        let otherNamed = other.1.namedChoices()
                        func across(_ group:(name:String,nodeIDs:[String])) -> (String,() -> Void) {
                            let refs = group.nodeIDs.map { LiDARNodeRef(map:id,node:$0) }
                            return ("\(label) · \(group.name)",{ [weak self] in self?.navigateAcross(item.0,start:start,targets:refs,name:"\(label) · \(group.name)",maps:byID,links:links,resume:resume) })
                        }
                        choices += otherNamed.rooms.map(across);otherChoices += otherNamed.others.map(across)
                    }
                    guard !choices.isEmpty || !otherChoices.isEmpty else { self.campusMessage("暂无可导航房间","请在建图时设置门牌入口，或通过“添加房间”建立入口并接入路网。门牌列表仍保留所有记录。");return }
                    self.chooseNamed("选择目的地",message:"起点范围：\(origin)\n同名房间显示一项；定位后按路网步行距离选择最近的可达入口。其他楼层或区域的房间需要先建立跨图连接。",rooms:choices,others:otherChoices)
                }
            }
        }
    }
    /// Corrects the recognition text of a saved plate (e.g. "132" back to the printed "3-132").
    /// The shown name is pinned first so it does not change with the text; entrance, position and
    /// evidence are untouched. Published through the versioned sidecar swap.
    private func editPlateText(_ item:(URL,LiDARNavigationMap)) {
        guard !busy else { return }
        let loaded = Result { try LiDARLandmarkSet.load(item.0,map:item.1,geometrySHA256:try CampusFiles.hash(item.0.appendingPathComponent("geometry.f32"))) }
        guard case .success(let set?) = loaded else { if case .failure(let e) = loaded { campusError(e) } else { campusMessage("没有门牌","这张地图还没有门牌。") };return }
        let plates = set.landmarks.filter { $0.category == .room_plate }
        guard !plates.isEmpty else { campusMessage("没有门牌","这张地图还没有门牌。");return }
        campusChoices("选择门牌",choices:plates.map { plate in ("\(plate.displayName)（门牌文字 \(plate.text.raw)）",{ [weak self] in
            let hint = plate.text.candidates.map(\.text).filter { $0 != plate.text.raw }.prefix(5).joined(separator:"、")
            self?.campusText(hint.isEmpty ? "门牌上印的文字" : "门牌上印的文字（识别候选：\(hint)）",value:plate.text.raw) { [weak self] raw in
                guard let self else { return }
                let text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !text.isEmpty,text.count <= 120 else { self.campusMessage("文字无效","请输入 1–120 个字符。");return }
                var next = set
                guard let i = next.landmarks.firstIndex(where:{ $0.id == plate.id }) else { return }
                if next.landmarks[i].display_name == nil && text != plate.text.raw { next.landmarks[i].display_name = plate.text.raw }
                next.landmarks[i].text = LiDARLandmarkText(raw:text,candidates:plate.text.candidates,confirmedByUser:true,edited:true)
                if next.landmarks[i].display_name == text { next.landmarks[i].display_name = nil }
                self.busy = true
                LiDARNavigationStore.queue.async { [weak self] in
                    let result = Result { () -> Void in
                        try next.validate(against:item.1)
                        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
                        try LiDARMapVersions.publishSidecar(item.0,name:LiDARLandmarkSet.fileName,data:encoder.encode(next))
                    }
                    DispatchQueue.main.async { guard let self else { return };self.busy = false
                        if case .failure(let e) = result { self.campusError(e) } else { self.campusMessage("已修改","门牌文字改为「\(text)」，名称仍为「\(next.landmarks[i].displayName)」。旧版本已保留。") }
                    }
                }
            }
        }) })
    }
    private func showPlates(_ item:(URL,LiDARNavigationMap)) {
        guard !busy else { return };busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let outcome = Result { try LiDARLandmarkSet.loadReport(item.0,map:item.1,geometrySHA256:try CampusFiles.hash(item.0.appendingPathComponent("geometry.f32"))) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return };self.busy = false
                switch outcome {
                case .success(let report):self.present(UINavigationController(rootViewController:LiDARPlateListController(landmarks:report?.set.landmarks ?? [],nodes:item.1.nodes,legacyIDs:Set(report?.downgraded ?? []))),animated:true)
                case .failure(let error):self.campusError(error)
                }
            }
        }
    }
    private func showDistribution(_ item:(URL,LiDARNavigationMap)) {
        guard !busy else { return };busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let outcome = Result { () -> LiDARDistributionData in
                let (map,points) = try LiDARNavigationStore.load(item.0)
                var data = LiDARDistributionData.saved(map,points:points)
                data.magnetic = LiDARNavigationStore.magneticReference(item.0,map:map)
                if let bytes = try? Data(contentsOf:item.0.appendingPathComponent("budget-summary.json")) {
                    data.budget = try? JSONDecoder().decode(LiDARBudgetSnapshot.self,from:bytes)
                }
                return data
            }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch outcome {
                case .success(let data):self.actionNavigation?.pushViewController(LiDARDistributionController(data:data),animated:true)
                case .failure(let error):self.campusError(error)
                }
            }
        }
    }
    private func navigate(_ url:URL,destinations:[String],destinationName:String,start:String?,resume:ProbePoint? = nil) {
        openIndoor(url,destinations:destinations,name:destinationName,start:start,cross:nil,resume:resume)
    }
    private func openIndoor(_ url:URL,destinations:[String],name:String,start:String?,cross:LiDARNavigationStore.CrossTargets?,resume:ProbePoint?) {
        busy = true
        LiDARNavigationStore.openIndoor(url,destinations:destinations,name:name,start:start,cross:cross,resume:resume) { [weak self] result in
            guard let self else { return };self.busy = false
            switch result {
            case .success(let controller):let nav = UINavigationController(rootViewController:controller);nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
            case .failure(let error):self.campusError(error)
            }
        }
    }
    /// Rooms first; the last item expands to the other named nodes (junctions, stairs, elevators).
    private func chooseNamed(_ title:String,message:String,lead:[(String,() -> Void)] = [],rooms:[(String,() -> Void)],others:[(String,() -> Void)]) {
        var choices = lead+rooms
        if !others.isEmpty {
            choices.append(("展开其他命名节点（\(others.count)）",{ [weak self] in self?.campusChoices(title,message:message,choices:lead+rooms+others) }))
        }
        campusChoices(title,message:message,choices:choices)
    }
    private func navigateAcross(_ url:URL,start:String?,targets:[LiDARNodeRef],name:String,maps:[String:(URL,LiDARNavigationMap)],links:[LiDARMapLink],resume:ProbePoint? = nil) {
        openIndoor(url,destinations:[],name:name,start:start,cross:.init(targets:targets,maps:maps,links:links),resume:resume)
    }
    private func export(_ url:URL) {
        busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { try LiDARNavigationStore.exportMap(url) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch result { case .success(let zip):self.campusShare(zip);case .failure(let error):self.campusError(error) }
            }
        }
    }
    private func delete(_ item:(URL,LiDARNavigationMap)) {
        let alert = UIAlertController(title:"删除地图？",message:"\(item.1.name) 的路线、几何及同目录原始采集记录将被删除。请先备份。",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"删除",style:.destructive) { [weak self] _ in
            do { try FileManager.default.removeItem(at:item.0);self?.reload() } catch { self?.campusError(error) }
        });present(alert,animated:true)
    }
    private func pickCalibration(_ item:(URL,LiDARNavigationMap)) {
        guard !busy else { return };calibrationTarget = item
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.json],asCopy:true);picker.delegate = self;present(picker,animated:true)
    }
    func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) { calibrationTarget = nil }
    /// Whole-file replacement, after showing what changes (paths count, raster present, geometry hash).
    private func importCalibration(_ file:URL,into target:(URL,LiDARNavigationMap)) {
        let outcome = Result { () -> (LiDARPassageCalibration,Data,String) in
            let data = try Data(contentsOf:file)
            guard data.count <= 32_000_000 else { throw LiDARScanError.invalid("校准文件过大") }
            let next = try JSONDecoder().decode(LiDARPassageCalibration.self,from:data);try next.validate(mapID:target.1.map_id)
            let current = try? LiDARPassageCalibration.load(target.0,mapID:target.1.map_id)
            let hash = try? CampusFiles.hash(target.0.appendingPathComponent("geometry.f32"))
            var lines = ["建议路径：当前 \(current?.suggested_paths.count ?? 0) 条 → 文件 \(next.suggested_paths.count) 条",
                         "通行栅格：当前\(current?.walkable == nil ? "无（自动判断）" : "有") → 文件\(next.walkable == nil ? "无（自动判断）" : "有")"]
            if let base = next.base_geometry_sha256,base != hash { lines.append("提示：文件生成后地图几何已变化（例如补采过）；坐标系不变，但请复核新扫区域。") }
            if (current?.suggested_paths.count ?? 0) > next.suggested_paths.count { lines.append("注意：文件里的路径比手机上少，导入会删掉手机上新画的路径。") }
            return (next,data,lines.joined(separator:"\n"))
        }
        switch outcome {
        case .failure(let error):campusError(error)
        case .success(let (_,data,summary)):
            let alert = UIAlertController(title:"替换通行空间校准？",message:summary+"\n\n整份文件替换，旧版本保留可恢复。",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"取消",style:.cancel))
            alert.addAction(UIAlertAction(title:"替换",style:.destructive) { [weak self] _ in
                guard let self else { return };self.busy = true
                LiDARNavigationStore.queue.async { [weak self] in
                    let result = Result { try LiDARMapVersions.publishSidecar(target.0,name:LiDARPassageCalibration.fileName,data:data) }
                    DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload()
                        if case .failure(let error) = result { self.campusError(error) } else { self.campusMessage("已导入","通行空间校准已更新，导航时生效。") }
                    }
                }
            })
            present(alert,animated:true)
        }
    }
    @objc private func importMap() {
        guard !busy else { return }
        #if targetEnvironment(macCatalyst)
        // The importer validates the ZIP itself. A broad data filter also
        // accepts ZIP type aliases returned by macOS file providers.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.data],asCopy:false)
        #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.zip],asCopy:false)
        #endif
        picker.delegate = self;present(picker,animated:true)
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        if let target = calibrationTarget {
            calibrationTarget = nil
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importCalibration(url,into:target);return
        }
        guard let url = urls.first,!busy else { return };busy = true
        let scoped = url.startAccessingSecurityScopedResource()
        LiDARNavigationStore.queue.async { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try LiDARNavigationStore.importMap(url) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload()
                if case .failure(let error) = result { self.campusError(error) }
            }
        }
    }
}

final class LiDARMapPreviewController:UIViewController {
    private let map:LiDARNavigationMap
    init(map:LiDARNavigationMap) { self.map = map;super.init(nibName:nil,bundle:nil);title = map.name }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func loadView() { view = LiDARPlanView(map:map) }
}

private final class LiDARPlanView:UIView {
    let map:LiDARNavigationMap
    init(map:LiDARNavigationMap) { self.map = map;super.init(frame:.zero);backgroundColor = .systemBackground;accessibilityLabel = "几何地图的平面路线" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func draw(_ rect:CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),!map.nodes.isEmpty else { return }
        let xs = map.nodes.map { $0.position.x },zs = map.nodes.map { $0.position.z }
        let minX = xs.min()!,minZ = zs.min()!,width = max(1,xs.max()!-minX),height = max(1,zs.max()!-minZ)
        let scale = min((bounds.width-100)/width,(bounds.height-180)/height)
        func point(_ p:ProbePoint) -> CGPoint { CGPoint(x:50+(p.x-minX)*scale,y:100+(p.z-minZ)*scale) }
        let byID = Dictionary(uniqueKeysWithValues:map.nodes.map { ($0.id,$0.position) })
        context.setStrokeColor(UIColor.systemTeal.cgColor);context.setLineWidth(5)
        for edge in map.edges { context.move(to:point(byID[edge.from]!));context.addLine(to:point(byID[edge.to]!));context.strokePath() }
        for node in map.nodes {
            let p = point(node.position);context.setFillColor(UIColor.systemIndigo.cgColor);context.fillEllipse(in:CGRect(x:p.x-7,y:p.y-7,width:14,height:14))
            (node.name as NSString).draw(at:CGPoint(x:p.x+10,y:p.y-22),withAttributes:[.font:UIFont.systemFont(ofSize:15,weight:.medium),.foregroundColor:UIColor.label])
        }
    }
}

final class LiDARNavigationRunsController:UITableViewController {
    private var runs = [URL]()
    private var busy = false
    override func viewDidLoad() { super.viewDidLoad();title = "几何导航记录" }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);runs = ProbeIO.existingRuns(at:LiDARNavigationStore.runs);tableView.reloadData() }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { runs.count }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? { "记录定位候选、会话编号、修正量、相机轨迹和现场反馈。点击导出 ZIP；原始查询深度在“原始扫描”中单独导出。" }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.textLabel?.text = runs[p.row].lastPathComponent;c.detailTextLabel?.text = "点击导出诊断记录";c.accessoryType = .disclosureIndicator;return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true);guard !busy else { return };busy = true
        let run = runs[p.row]
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { () -> URL in
                try ProbeIO.makeManifest(at:run)
                let zip = ProbeIO.documents.appendingPathComponent("Exports/"+run.lastPathComponent+".zip")
                try ProbeZip.create(directory:run,destination:zip);return zip
            }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch result { case .success(let zip):self.campusShare(zip);case .failure(let error):self.campusError(error) }
            }
        }
    }
}

/// Physical plate entities stay separate even when their text matches. Manual rooms have no plate entity.
final class LiDARPlateListController:UITableViewController {
    private let records:[LiDARLandmark],nodes:[LiDARRouteNode],legacyIDs:Set<String>
    init(landmarks:[LiDARLandmark],nodes:[LiDARRouteNode],legacyIDs:Set<String> = []) {
        records = landmarks;self.nodes = nodes;self.legacyIDs = legacyIDs;super.init(style:.insetGrouped)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = "门牌列表"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"关闭",style:.plain,target:self,action:#selector(close))
    }
    private func entries(_ section:Int) -> [LiDARLandmark] { records.filter { section == 0 ? $0.category == .room_plate : $0.category == .reference_feature } }
    private func hasEntrance(_ record:LiDARLandmark) -> Bool {
        record.destination.enabled && nodes.contains { $0.id == record.destination.node_id && $0.resolvedKind == .room }
    }
    override func numberOfSections(in tableView:UITableView) -> Int { 2 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { entries(section).count }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? { section == 0 ? "全部门牌 · \(entries(0).count)" : "参考特征物 · \(entries(1).count)" }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == 0 ? "未设入口的门牌仅作记录，不会成为目的地。手动添加的房间没有门牌，不在此列表里；同名门牌按实体分别保留。入口仅能在本次建图会话中设置。" : nil
    }
    override func tableView(_ tableView:UITableView,cellForRowAt index:IndexPath) -> UITableViewCell {
        let r = entries(index.section)[index.row],cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        cell.textLabel?.text = r.displayName
        cell.detailTextLabel?.text = "门牌文字 \(r.text.raw) · "+(r.category == .room_plate ? (hasEntrance(r) ? "已设入口" : legacyIDs.contains(r.id) ? "旧绑定，请重新设置入口" : "未设入口") : "仅作参考 · 不作为目的地")
        cell.detailTextLabel?.textColor = hasEntrance(r) ? .systemTeal : .secondaryLabel;cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt index:IndexPath) {
        tableView.deselectRow(at:index,animated:true);let r = entries(index.section)[index.row]
        let mount = r.mount == .wall ? "贴在墙上" : r.mount == .door ? "贴在门上" : "不确定"
        let bound = hasEntrance(r) ? "已设入口："+(nodes.first { $0.id == r.destination.node_id }?.name ?? "") : legacyIDs.contains(r.id) ? "旧绑定已降级，仅保留原始记录；需在新的建图会话中重新设置入口。" : "未设入口，不能作为目的地"
        campusMessage(r.text.raw,"\(bound)\n安装位置：\(mount)\n门牌三维：\(r.geometry.status == "measured" ? "多帧测得（非绝对精度）" : "未知")\n门牌和入口位置独立记录，当前不用于修改定位。")
    }
    @objc private func close() { dismiss(animated:true) }
}

/// Catalog browsing is separate from ARWorldMap's library. A region currently selects one map.
final class LiDARCampusBrowserController:UITableViewController,UIDocumentPickerDelegate {
    /// Keeps the actions helper of a tapped region alive while its sheets are open.
    private var regionActions:LiDARGeometryLibraryController?
    private enum Row { case building(String),floor(String),region(String),all,unclassified,addBuilding,addFloor,create }
    private let mode:LiDARGeometryLibraryController.Mode
    private let buildingID:String?,floorID:String?
    private let chooseFloor:((LiDARCampusCatalog.Building,LiDARCampusCatalog.Floor) -> Void)?
    private var catalog = LiDARCampusCatalog(),grouping = LiDARLibraryGrouping(catalog:LiDARCampusCatalog(),maps:[])
    private var maps = [(URL,LiDARNavigationMap)](),rows = [Row](),busy = false
    init(mode:LiDARGeometryLibraryController.Mode,buildingID:String? = nil,floorID:String? = nil,chooseFloor:((LiDARCampusCatalog.Building,LiDARCampusCatalog.Floor) -> Void)? = nil) {
        self.mode = mode;self.buildingID = buildingID;self.floorID = floorID;self.chooseFloor = chooseFloor
        super.init(style:.insetGrouped)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    private var building:LiDARCampusCatalog.Building? { buildingID.flatMap { catalog.building($0) } }
    private var floor:LiDARCampusCatalog.Floor? { building?.floors.first { $0.id == floorID } }
    private var regions:[LiDARLibraryGrouping.Region] {
        grouping.buildings.first { $0.building.id == buildingID }?.floors.first { $0.floor.id == floorID }?.regions ?? []
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"导入",style:.plain,target:self,action:#selector(importMap))
        if chooseFloor != nil && buildingID == nil { navigationItem.leftBarButtonItem = UIBarButtonItem(title:"取消",style:.plain,target:self,action:#selector(cancel)) }
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);reload() }
    private func reload() {
        guard !busy else { return };busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { () -> (LiDARCampusCatalog,[(URL,LiDARNavigationMap)],LiDARLibraryGrouping) in
                let catalog = try LiDARCampusCatalog.load(root:LiDARLibrary.root),maps = LiDARNavigationStore.maps()
                let grouped = LiDARLibraryGrouping(catalog:catalog,maps:maps.map { (mapID:$0.1.map_id,mapName:$0.1.name,placement:LiDARMapPlacement.load($0.0,mapID:$0.1.map_id)) })
                return (catalog,maps,grouped)
            }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                switch result {
                case .success(let (catalog,maps,grouping)):
                    self.catalog = catalog;self.maps = maps;self.grouping = grouping;self.rebuild()
                case .failure(let error):self.campusError(error)
                }
            }
        }
    }
    private func rebuild() {
        if let building,let floor {
            title = building.name+" · "+floor.name
            rows = regions.isEmpty ? [] : [.all]+regions.map { .region($0.map_id) }
            if mode == .mapping { rows.insert(.create,at:0) }
        } else if let building {
            title = building.name;rows = building.sortedFloors.map { .floor($0.id) }+[.addFloor]
        } else {
            title = chooseFloor != nil ? "选择楼栋和楼层" : mode == .mapping ? "建图 · 楼栋" : "导航 · 楼栋"
            rows = grouping.buildings.map { .building($0.building.id) }
            if chooseFloor == nil && !grouping.unclassified.isEmpty { rows.append(.unclassified) }
            rows.append(.addBuilding)
        }
        tableView.reloadData()
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { rows.count }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        if chooseFloor != nil { return "选择所属楼栋和楼层；下一步填写区域名。旧图归类只更新归属，不改点云和路线。" }
        if floorID != nil { return "可选择区域，或显示本层全部地图后再选一张。当前定位与路线规划使用所选区域地图。" }
        return "楼栋 → 楼层 → 区域。旧地图保留在“未分类”中，可在地图操作里手动归类。建图先选择楼栋和楼层，再填写区域。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt index:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.detailTextLabel?.numberOfLines = 0;c.accessoryType = .disclosureIndicator
        switch rows[index.row] {
        case .building(let id):let b = catalog.building(id)!;c.textLabel?.text = b.name;c.detailTextLabel?.text = "\(b.floors.count) 个楼层"
        case .floor(let id):let f = building!.floors.first { $0.id == id }!;c.textLabel?.text = f.name
            c.detailTextLabel?.text = chooseFloor != nil ? "选择此楼层" : "选择区域或新建地图"
        case .region(let id):let r = regions.first { $0.map_id == id }!;let map = maps.first { $0.1.map_id == id }!.1
            c.textLabel?.text = r.name;c.detailTextLabel?.text = "\(map.nodes.count) 个节点 · 地图 \(id.prefix(6))"
        case .all:c.textLabel?.text = "不限区域（浏览本层地图）";c.detailTextLabel?.text = "显示本层 \(regions.count) 张地图，选择一张再定位"
        case .unclassified:c.textLabel?.text = "未分类";c.detailTextLabel?.text = "\(grouping.unclassified.count) 张旧图或归属待核对的地图"
        case .addBuilding:c.textLabel?.text = "＋ 新建楼栋";c.textLabel?.textColor = .systemTeal
        case .addFloor:c.textLabel?.text = "＋ 新建楼层";c.textLabel?.textColor = .systemTeal
        case .create:c.textLabel?.text = "＋ 新建区域地图";c.textLabel?.textColor = .systemTeal;c.detailTextLabel?.text = "已选择 \(building!.name) · \(floor!.name)"
        }
        return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt index:IndexPath) {
        tableView.deselectRow(at:index,animated:true);guard !busy else { return }
        switch rows[index.row] {
        case .building(let id):navigationController?.pushViewController(LiDARCampusBrowserController(mode:mode,buildingID:id,chooseFloor:chooseFloor),animated:true)
        case .floor(let id):
            guard let building,let selected = building.floors.first(where:{$0.id == id}) else { return }
            if let chooseFloor { dismiss(animated:true) { chooseFloor(building,selected) } }
            else { navigationController?.pushViewController(LiDARCampusBrowserController(mode:mode,buildingID:building.id,floorID:id),animated:true) }
        case .region(let id):
            let actions = LiDARGeometryLibraryController(mode:mode,mapIDs:[id],title:regions.first{$0.map_id == id}?.name)
            actions.host = self;actions.onChange = { [weak self] in self?.reload() };regionActions = actions;actions.openMap(id)
        case .all:navigationController?.pushViewController(LiDARGeometryLibraryController(mode:mode,mapIDs:Set(regions.map(\.map_id)),title:"本层全部地图"),animated:true)
        case .unclassified:navigationController?.pushViewController(LiDARGeometryLibraryController(mode:mode,mapIDs:Set(grouping.unclassified.map(\.map_id)),title:"未分类地图"),animated:true)
        case .addBuilding:campusText("楼栋名称",placeholder:"例如：教学楼A") { [weak self] name in self?.editCatalog { _ = try $0.addBuilding(name) } }
        case .addFloor:addFloor()
        case .create:
            guard let building,let floor else { return }
            LiDARMapCreation.start(on:self,building:building,floor:floor) { [weak self] in self?.reload() }
        }
    }
    private func editCatalog(_ edit:@escaping (inout LiDARCampusCatalog) throws -> Void) {
        busy = true
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { var c = try LiDARCampusCatalog.load(root:LiDARLibrary.root);try edit(&c);try c.save(root:LiDARLibrary.root) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                if case .failure(let error) = result { self.campusError(error) };self.reload()
            }
        }
    }
    private func addFloor() {
        guard let building else { return }
        let alert = UIAlertController(title:"新建楼层",message:"名称必填。排序数可选，例如地下一层 -1、一层 1。",preferredStyle:.alert)
        alert.addTextField { $0.placeholder = "楼层名称，例如 1F" }
        alert.addTextField { $0.placeholder = "排序数（可选）";$0.keyboardType = .numbersAndPunctuation }
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"创建",style:.default) { [weak self,weak alert] _ in
            let name = alert?.textFields?.first?.text ?? "",rawLevel = alert?.textFields?.last?.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            guard rawLevel.isEmpty || Int(rawLevel) != nil else { self?.campusMessage("排序数无效","请填写整数，或留空。");return }
            self?.editCatalog { _ = try $0.addFloor(name,level:Int(rawLevel),to:building.id) }
        })
        present(alert,animated:true)
    }
    @objc private func importMap() { guard !busy else { return };let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.zip],asCopy:true);picker.delegate = self;present(picker,animated:true) }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let url = urls.first,!busy else { return };busy = true
        let scoped = url.startAccessingSecurityScopedResource()
        LiDARNavigationStore.queue.async { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try LiDARNavigationStore.importMap(url) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload();if case .failure(let error) = result { self.campusError(error) } }
        }
    }
    @objc private func cancel() { dismiss(animated:true) }
}

private enum LiDARMapCreation {
    static func start(on host:UIViewController,building:LiDARCampusCatalog.Building,floor:LiDARCampusCatalog.Floor,onSaved:@escaping () -> Void) {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard LiDARGeometryARController.supported else { host.campusMessage("设备不支持","采集需要支持 LiDAR 的 iPhone。");return }
        host.campusText("区域名称",placeholder:"例如：西口走廊") { [weak host] raw in
            guard let host else { return }
            do {
                let region = try LiDARCampusCatalog.cleanName(raw)
                host.campusChoices("采集光照",message:"\(building.name) · \(floor.name) · \(region)",choices:CampusLighting.allCases.map { light in
                    (light.title,{
                        let controller = LiDARGeometryARController(name:region,lighting:light.rawValue,building:building,floor:floor);controller.onSaved = onSaved
                        let panel = UINavigationController(rootViewController:controller);panel.modalPresentationStyle = .fullScreen;host.present(panel,animated:true)
                    })
                })
            } catch { host.campusError(error) }
        }
        #else
        host.campusMessage("需要 iPhone 采集","已选择 \(building.name) · \(floor.name)。Mac 可管理目录、归类地图和查看备份；采集在 iPhone 上进行。")
        #endif
    }
}

/// A door position from a short burst of precise fixes: asks for temporary full accuracy, keeps fixes
/// within 20 m and averages the best ones (weighted by accuracy). Stops early at ±5 m, gives up after 20 s.
final class LiDARDoorLocator:NSObject,CLLocationManagerDelegate {
    struct Fix { let point:LiDARCampusBindings.GeoPoint;let accuracy:Double }
    private let manager = CLLocationManager()
    private var done:((Result<Fix,Error>) -> Void)?,fixes = [CLLocation](),timer:DispatchWorkItem?
    func start(_ completion:@escaping (Result<Fix,Error>) -> Void) {
        done = completion;manager.delegate = self;manager.desiredAccuracy = kCLLocationAccuracyBest;manager.distanceFilter = kCLDistanceFilterNone
        let work = DispatchWorkItem { [weak self] in self?.finish() };timer = work
        DispatchQueue.main.asyncAfter(deadline:.now()+20,execute:work)
        authorize()
    }
    func cancel() { timer?.cancel();manager.stopUpdatingLocation();done = nil }
    private func authorize() {
        switch manager.authorizationStatus {
        case .notDetermined:manager.requestWhenInUseAuthorization()
        case .authorizedAlways,.authorizedWhenInUse:
            if manager.accuracyAuthorization == .reducedAccuracy {
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey:"EntranceBinding") { [weak self] _ in
                    guard let self,self.done != nil else { return }
                    if self.manager.accuracyAuthorization == .fullAccuracy { self.manager.startUpdatingLocation() }
                    else { self.fail("需要“精确位置”才能记录门口坐标。可以在弹窗中允许一次，或手动填写经纬度。") }
                }
            } else { manager.startUpdatingLocation() }
        default:fail("没有定位权限。可在系统设置中允许，或手动填写经纬度。")
        }
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) { if done != nil && fixes.isEmpty { authorize() } }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        fixes += locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 20 && abs($0.timestamp.timeIntervalSinceNow) < 5 && CLLocationCoordinate2DIsValid($0.coordinate) }
        if fixes.filter({ $0.horizontalAccuracy <= 5 }).count >= 3 { finish() }
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        fail(error.localizedDescription)
    }
    private func fail(_ message:String) {
        timer?.cancel();manager.stopUpdatingLocation()
        let callback = done;done = nil;callback?(.failure(CampusError.invalid(message)))
    }
    private func finish() {
        timer?.cancel();manager.stopUpdatingLocation()
        guard let callback = done else { return };done = nil
        guard let best = fixes.map(\.horizontalAccuracy).min() else { callback(.failure(CampusError.invalid("20 秒内没有得到 20 米以内的定位。请到更开阔处重试，或手动填写经纬度。")));return }
        let used = fixes.filter { $0.horizontalAccuracy <= best*1.5 },weights = used.map { 1/($0.horizontalAccuracy*$0.horizontalAccuracy) },total = weights.reduce(0,+)
        let lat = zip(used,weights).reduce(0) { $0+$1.0.coordinate.latitude*$1.1 }/total,lon = zip(used,weights).reduce(0) { $0+$1.0.coordinate.longitude*$1.1 }/total
        callback(.success(Fix(point:.init(lat:lat,lon:lon),accuracy:best)))
    }
}
