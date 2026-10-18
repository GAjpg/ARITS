import UIKit
import UniformTypeIdentifiers

enum CampusApp {
    static let library = CampusLibrary(root: ProbeIO.documents.appendingPathComponent("CampusNetworks"))
    static let planner: any CampusRoutePlanning = CampusOfflinePlanner()
    static let io = DispatchQueue(label: "campus.network.io", qos: .userInitiated)
}

extension UIViewController {
    func campusError(_ error: Error) { campusMessage("操作未完成", error.localizedDescription) }
    func campusMessage(_ title: String, _ message: String) {
        let a = UIAlertController(title:title,message:message,preferredStyle:.alert)
        a.addAction(UIAlertAction(title:"知道了",style:.default)); present(a,animated:true)
    }
    func campusText(_ title: String, value: String = "", placeholder: String = "", done: @escaping (String) -> Void) {
        let a = UIAlertController(title:title,message:nil,preferredStyle:.alert)
        a.addTextField { $0.text = value; $0.placeholder = placeholder; $0.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title:"取消",style:.cancel))
        a.addAction(UIAlertAction(title:"确定",style:.default) { _ in
            let text = (a.textFields?.first?.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            if !text.isEmpty { done(String(text.prefix(120))) }
        }); present(a,animated:true)
    }
    func campusChoices(_ title: String, message: String? = nil, choices: [(String, () -> Void)]) {
        let a = UIAlertController(title:title,message:message,preferredStyle:.actionSheet)
        for (name, action) in choices { a.addAction(UIAlertAction(title:name,style:.default) { _ in action() }) }
        a.addAction(UIAlertAction(title:"取消",style:.cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:view.bounds.midY,width:1,height:1)
        present(a,animated:true)
    }
    func campusShare(_ url: URL) {
        let share = UIActivityViewController(activityItems:[url],applicationActivities:nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:view.bounds.midY,width:1,height:1)
        present(share,animated:true)
    }
}

final class CampusHomeController: UITableViewController, UIDocumentPickerDelegate {
    private var buildings: [CampusGraph] = []
    private var busy = false
    override func viewDidLoad() {
        super.viewDidLoad(); title = "LiDAR 验证 · "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1.0")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"新建",style:.plain,target:self,action:#selector(create))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title:"LiDAR 验证",style:.plain,target:self,action:#selector(openLiDAR))
        tableView.register(UITableViewCell.self,forCellReuseIdentifier:"cell")
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); buildings = CampusApp.library.list(); tableView.reloadData()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? buildings.count : 6 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "楼栋与路网" : "工具" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "现场标记节点并连线；每层可以保存多个区域。备份包含路网、AR 环境地图和参考照片。" : "AR 采集需使用真实 iPhone。Mac 可管理楼层、查看路网、规划和备份已导入的数据。"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        if indexPath.section == 0 {
            let g = buildings[indexPath.row]; cell.textLabel?.text = g.name
            cell.detailTextLabel?.text = "\(g.floors.count) 层 · \(g.regions.count) 区域 · \(g.nodes.count) 节点 · \(g.edges.count) 连接 · \(g.rooms.count) 房间"
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.textLabel?.text = ["导入路网 JSON / 环境备份 ZIP","打开原 AR 验证器","导出历史路网验证记录","存储空间与清理","使用说明","LiDAR 扫描与导出（第一阶段）"][indexPath.row]
            cell.accessoryType = .disclosureIndicator
        }; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true); guard !busy else { return }
        if indexPath.section == 0 { navigationController?.pushViewController(CampusBuildingController(id:buildings[indexPath.row].building_id),animated:true); return }
        switch indexPath.row {
        case 0:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.zip,.json],asCopy:true); picker.delegate = self; present(picker,animated:true)
        case 1:
            #if targetEnvironment(macCatalyst) || targetEnvironment(simulator)
            navigationController?.pushViewController(PreviewViewController(),animated:true)
            #else
            navigationController?.pushViewController(ProbeViewController(),animated:true)
            #endif
        case 2: navigationController?.pushViewController(CampusTrialsController(),animated:true)
        case 3: navigationController?.pushViewController(CampusStorageController(),animated:true)
        case 5: navigationController?.pushViewController(LiDARLibraryController(),animated:true)
        default:
            campusMessage("先做一小片路网", "新建楼栋 → 添加楼层 → 新建区域 → 现场标点连线 → 保存区域 → 选择起始地和目的地 → 附近扫描导航。\n\n转角需要加路点，确保连线沿走廊。区域交接处绑定同一个已有节点。楼梯口按实际楼层分别标记，再在楼栋页面配对。\n\n采集未保存前请保持应用在前台。退出采集会提示是否放弃草稿；保存后可导出完整备份。")
        }
    }
    @objc private func create() {
        campusText("新建楼栋",placeholder:"例如：宿舍楼") { [weak self] name in
            do { let g = try CampusApp.library.save(CampusGraph(name:name)); self?.navigationController?.pushViewController(CampusBuildingController(id:g.building_id),animated:true) }
            catch { self?.campusError(error) }
        }
    }
    @objc private func openLiDAR() { navigationController?.pushViewController(LiDARLibraryController(),animated:true) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, !busy else { return }; busy = true; title = "正在校验备份…"
        let scoped = url.startAccessingSecurityScopedResource()
        CampusApp.io.async { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("campus-incoming-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:temp) }
            let result = Result { () -> String in
                if url.pathExtension.lowercased() == "json" {
                    let g = try CampusApp.library.importGraph(url)
                    return "已导入「\(g.name)」路网。JSON 不含 AR 环境，现场导航需要完整 ZIP 备份。"
                }
                let root = try CampusBackupZIP.extract(url,to:temp)
                if FileManager.default.fileExists(atPath:root.appendingPathComponent("backup.json").path) {
                    #if !targetEnvironment(macCatalyst)
                    let g = try CampusApp.library.importPackage(root,validateMap:CampusARStore.validateArchive)
                    #else
                    let g = try CampusApp.library.importPackage(root)
                    #endif
                    return "已导入「\(g.name)」。已有楼栋会保留，重复编号的备份导入为副本。"
                }
                #if !targetEnvironment(macCatalyst)
                let name = try WorldMapStore.importPackage(root)
                return "已导入旧版环境地图「\(name)」，可在原 AR 验证器的「环境地图」中加载。"
                #else
                throw CampusError.invalid("旧版环境地图包请在 iPhone 上导入；Mac 支持新版本完整路网备份。")
                #endif
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.title = "LiDAR 验证 · "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1.0")
                self.buildings = CampusApp.library.list(); self.tableView.reloadData()
                switch result { case .success(let message): self.campusMessage("导入完成",message); case .failure(let e): self.campusError(e) }
            }
        }
    }
}

final class CampusTrialsController: UITableViewController {
    private var runs: [URL] = []
    private var busy = false
    init() { super.init(style:.insetGrouped); title = "路网验证记录" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        runs = ProbeIO.existingRuns(at:ProbeIO.documents.appendingPathComponent("NetworkTrials")); tableView.reloadData()
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { runs.count }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        "每次现场采集 / 导航自动记录。点击导出诊断 ZIP；它与用于恢复环境的备份 ZIP 是两种文件。异常退出的记录也可导出检查。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil); c.textLabel?.text = runs[p.row].lastPathComponent
        c.detailTextLabel?.text = FileManager.default.fileExists(atPath:runs[p.row].appendingPathComponent("summary.json").path) ? "已结束 · 点击分享" : "未正常结束 · 可导出排查"
        c.accessoryType = .disclosureIndicator; return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true); guard !busy else { return }; busy = true; title = "正在打包…"
        let run = runs[p.row]
        CampusApp.io.async { [weak self] in
            let result = Result { () -> URL in
                try ProbeIO.makeManifest(at:run)
                let zip = ProbeIO.documents.appendingPathComponent("Exports/"+run.lastPathComponent+".zip")
                try ProbeZip.create(directory:run,destination:zip); return zip
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.title = "路网验证记录"
                switch result { case .success(let zip): self.campusShare(zip); case .failure(let e): self.campusError(e) }
            }
        }
    }
}

final class CampusBuildingController: UITableViewController {
    private let id: String
    private var graph: CampusGraph!
    private var busy = false
    init(id: String) { self.id = id; super.init(style:.insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() { super.viewDidLoad(); navigationItem.rightBarButtonItems = [UIBarButtonItem(title:"管理",style:.plain,target:self,action:#selector(manage)),UIBarButtonItem(title:"路网图",style:.plain,target:self,action:#selector(showGraph))] }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    private func reload() {
        do {
            graph = try CampusApp.library.load(id);title = graph.name;tableView.reloadData()
            // Also retire files left by an interrupted subenvironment replacement.
            if !busy {
                busy = true;let buildingID = id
                CampusApp.io.async { [weak self] in
                    let result = Result { try CampusApp.library.prepareMaps(buildingID) }
                    DispatchQueue.main.async { guard let self else { return };self.busy = false
                        switch result { case .success(let g):self.graph = g;self.tableView.reloadData();case .failure(let e):self.campusError(e) }
                    }
                }
            }
        }
        catch { campusError(error) }
    }
    private func commit(_ change: @escaping (inout CampusGraph) throws -> Void, completion: (() -> Void)? = nil) {
        guard !busy else { return }; busy = true; title = "正在保存…"
        let id = self.id
        CampusApp.io.async { [weak self] in
            let result = Result { () -> CampusGraph in
                var g = try CampusApp.library.load(id); try change(&g); return try CampusApp.library.save(g)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result {
                case .success(let g): self.graph = g; self.title = g.name; self.tableView.reloadData(); completion?()
                case .failure(let e): self.reload(); self.campusError(e)
                }
            }
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { graph == nil ? 0 : 4 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section { case 0: return graph.floors.count+1; case 1:return graph.regions.count+1; case 2:return 4; default:return graph.nodes.count+graph.roomGroups.count }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["楼层","环境区域","导航与数据","节点与沿线房间"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "同一楼层可拆成多个小区域。交接处绑定两个相距 2 米以上的共同节点，可连接坐标并连续导航；全部区域仍共用整栋楼路网。" : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt p: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        switch p.section {
        case 0: c.textLabel?.text = p.row == graph.floors.count ? "＋ 添加楼层" : graph.floors[p.row].name
        case 1:
            if p.row == graph.regions.count { c.textLabel?.text = "＋ 新建区域" }
            else { let r = graph.regions[p.row]; c.textLabel?.text = "\(graph.floorName(r.floor_id)) · \(r.name)"
                c.detailTextLabel?.text = "\(graph.bindings.filter { $0.region_id == r.id }.count) 个节点 · \(r.map_saved ? (hasLocalMap(r) ? "\(graph.map_candidates.filter { $0.region_id == r.id }.count) 个子环境" : "仅路网，需导入完整备份") : "尚未采集")" }
        case 2:
            c.textLabel?.text = ["选择起始地和目的地","配对跨层楼梯","查看线路连接","导出备份 / 路网 JSON"][p.row]
        default:
            if p.row < graph.nodes.count { let n = graph.nodes[p.row]; c.textLabel?.text = graph.title(n); c.detailTextLabel?.text = n.kind.title }
            else { let group = graph.roomGroups[p.row-graph.nodes.count],r = group[0]; c.textLabel?.text = graph.title(r); c.detailTextLabel?.text = "沿线房间 · \(group.count) 个标注入口" }
        }
        c.accessoryType = .disclosureIndicator; return c
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt p: IndexPath) {
        tableView.deselectRow(at:p,animated:true); guard !busy else { return }
        switch p.section {
        case 0:
            if p.row == graph.floors.count { campusText("楼层名称",placeholder:"例如：一楼") { [weak self] name in self?.commit { $0.floors.append(CampusFloor(name:name)) } } }
            else { let floor = graph.floors[p.row]; campusText("修改楼层名称",value:floor.name) { [weak self] name in self?.commit { g in if let i = g.floors.firstIndex(where:{$0.id == floor.id}) { g.floors[i].name = name } } } }
        case 1: p.row == graph.regions.count ? newRegion() : regionMenu(graph.regions[p.row])
        case 2:
            switch p.row { case 0: plan(); case 1: pairStairs(); case 2: navigationController?.pushViewController(CampusConnectionsController(id:id),animated:true); default: dataMenu() }
        default:
            if p.row >= graph.nodes.count {
                let entrances = graph.roomGroups[p.row-graph.nodes.count]
                campusChoices(entrances[0].name,message:"导航时选择最近的可达入口。此处选择要管理的标注位置。",choices:entrances.enumerated().map { index,room in
                    ("入口 \(index+1) · \(room.side.title)",{ [weak self] in guard let self else { return };self.navigationController?.pushViewController(CampusRoomsController(id:self.id,edgeID:room.edge_id),animated:true) })
                });return
            }
            let node = graph.nodes[p.row]
            if node.kind == .waypoint {
                campusMessage(graph.title(node),"普通路点不显示名称。可在现场通过编号选择它进行绑定或连线。")
            } else {
                campusText("修改\(node.kind.title)名称",value:node.name) { [weak self] name in
                    self?.commit { g in if let i = g.nodes.firstIndex(where: { $0.id == node.id }) { g.nodes[i].name = name } }
                }
            }
        }
    }
    private func hasLocalMap(_ r:CampusRegion) -> Bool {
        guard let dir = try? CampusApp.library.regionDirectory(buildingID:id,regionID:r.id) else { return false }
        return FileManager.default.fileExists(atPath:dir.appendingPathComponent("environment.arworldmap").path)
    }
    private func newRegion() {
        guard !graph.floors.isEmpty else { campusMessage("先添加楼层","每个区域需要属于一个楼层。"); return }
        campusChoices("在哪一层采集？",choices:graph.floors.map { floor in (floor.name,{ [weak self] in
            self?.campusText("区域名称",placeholder:"例如：东侧走廊") { [weak self] name in
                guard let self else { return }; let r = CampusRegion(floorID:floor.id,name:name)
                self.commit({ $0.regions.append(r) }, completion: { [weak self] in self?.regionMenu(r) })
            }
        }) })
    }
    private func regionMenu(_ r: CampusRegion) {
        campusChoices(r.name,choices:[("LiDAR 几何验证（建图 / 独立查询）",{ [weak self] in
            guard let self else { return };self.navigationController?.pushViewController(LiDARLibraryController(graph:self.graph,regionID:r.id),animated:true)
        }),("子环境（保护 / 实测 / 默认 / 旧图导入）",{ [weak self] in
            guard let self else { return }
            self.navigationController?.pushViewController(CampusMapsController(buildingID:self.id,regionID:r.id) { [weak self] candidate,lighting,local,replace in self?.openCapture(r.id,supplementLighting:lighting,candidateID:candidate,localSupplement:local,replacingMapID:replace ? candidate : nil) },animated:true)
        }),("\(r.map_saved ? "恢复并补充路网" : "开始现场采集")",{ [weak self] in self?.openCapture(r.id) }),
            ("查看特征点分布",{ [weak self] in guard let self else { return };self.navigationController?.pushViewController(CampusGraphController(graph:self.graph,regionID:r.id,featureMode:1),animated:true) }),
            ("补采光照",{ [weak self] in guard r.map_saved else { self?.campusMessage("先完成环境采集","保存原环境后，才能在原路网上补采其他光照。");return };self?.campusChoices("本次补采的光照",message:"先恢复并核对原环境，再扫描当前光照下的固定物体并保存。本次首次保存新建子环境；继续保存更新同一份。其他子环境保留；补采效果需冷启动导航验证。",choices:CampusLighting.allCases.map { light in (light.title,{ [weak self] in self?.openCapture(r.id,supplementLighting:light) }) }) }),
            ("导出本区域环境备份 ZIP",{ [weak self] in self?.exportBackup(regionID:r.id) }),
            ("修改名称",{ [weak self] in self?.campusText("区域名称",value:r.name) { name in self?.commit { g in if let i = g.regions.firstIndex(where:{$0.id == r.id}) { g.regions[i].name = name } } } }),
            ("删除这个区域",{ [weak self] in
                guard let self else { return }; let a = UIAlertController(title:"删除区域？",message:"移除该区域及其独有节点、连接。导出的备份和历史版本会保留。",preferredStyle:.alert)
                a.addAction(UIAlertAction(title:"取消",style:.cancel)); a.addAction(UIAlertAction(title:"删除",style:.destructive) { _ in self.commit { $0.removeRegion(r.id) } }); self.present(a,animated:true)
            })])
    }
    private func openCapture(_ rid:String,supplementLighting:CampusLighting? = nil,candidateID:String? = nil,localSupplement:Bool = false,replacingMapID:String? = nil) {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        do { let g = try CampusApp.library.load(id); if (supplementLighting != nil || localSupplement) && g.region(rid)?.map_saved != true { throw CampusError.invalid("请先完成并保存原环境，再补采。") }; if let r = g.region(rid),r.map_saved,!hasLocalMap(r) { campusMessage("本机没有环境地图","此路网来自 JSON。请导入包含 AR 环境的完整 ZIP 备份，再恢复采集。");return }; let c = CampusNetworkARController(graph:g,regionID:rid,supplementLighting:supplementLighting,candidateID:candidateID,localSupplement:localSupplement || supplementLighting != nil,replacingMapID:replacingMapID); let nav = UINavigationController(rootViewController:c); nav.modalPresentationStyle = .fullScreen; present(nav,animated:true) }
        catch { campusError(error) }
        #else
        campusMessage("需要真实 iPhone","Mac / 模拟器可管理和规划路网；现场采集、AR 恢复与导航需要在 iPhone 上运行。")
        #endif
    }
    private func pickNode(_ title: String, nodes: [CampusNode], done: @escaping (CampusNode) -> Void) {
        guard !nodes.isEmpty else { campusMessage("尚无可选节点","先采集区域并添加节点。"); return }
        let picker = CampusNodePicker(title:title,graph:graph,nodes:nodes,done:done)
        navigationController?.pushViewController(picker,animated:true)
    }
    private func pairStairs() {
        let stairs = graph.nodes.filter { $0.kind == .stair }
        pickNode("选择楼梯一端",nodes:stairs) { [weak self] a in
            guard let self else { return }
            self.pickNode("选择另一层对应出口",nodes:stairs.filter { $0.floor_id != a.floor_id }) { [weak self] b in
                guard let self else { return }
                self.campusText("楼梯通行代价",value:"8",placeholder:"正数；走廊距离与此代价一起用于选路") { text in
                    guard let cost = Double(text), cost > 0, cost < 10000 else { self.campusMessage("数值无效","请输入大于 0 的通行代价。"); return }
                    self.commit { g in
                        guard !g.edges.contains(where: { $0.kind == .stairs && Set([$0.from,$0.to]) == Set([a.id,b.id]) }) else { throw CampusError.invalid("这两个楼梯口已经配对。") }
                        g.edges.append(CampusEdge(stairFrom:a.id,to:b.id,cost:cost))
                    }
                }
            }
        }
    }
    private func plan() {
        let choices = graph.roomDestinations + graph.nodes.filter { $0.kind != .waypoint }.map { CampusDestination(nodeID:$0.id) }
        guard !choices.isEmpty else { campusMessage("先添加目的地","可以在走廊连线上添加房间；普通路点无需作为目的地。");return }
        navigationController?.pushViewController(CampusNavigationSetupController(graph:graph) { [weak self] selectedGraph,start,destination,candidateID in
            guard let self else { return }
            #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            let c = CampusNetworkARController(graph:selectedGraph,destination:destination,start:start,candidateID:candidateID),nav = UINavigationController(rootViewController:c)
            nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
            #else
            let scope = try? CampusLocalizationScope.make(graph:selectedGraph,start:start)
            self.campusMessage("导航设置已完成", "起始地：\(start.title(in:selectedGraph))\n目的地：\(destination.title(in:selectedGraph))\n待识别区域：\(scope?.regionIDs.count ?? 0) 个\n\n在 iPhone 上于起始地附近扫描，识别真实位置后导航。")
            #endif
        },animated:true)
    }
    @objc private func showGraph() { guard let graph else { return };navigationController?.pushViewController(CampusGraphController(graph:graph),animated:true) }
    @objc private func manage() {
        guard !busy else { return }
        campusChoices("楼栋管理",choices:[("修改楼栋名称",{ [weak self] in self?.campusText("楼栋名称",value:self?.graph.name ?? "") { name in self?.commit { $0.name = name } } }),
            ("备份与文件传递",{ [weak self] in self?.dataMenu() })])
    }
    private func dataMenu() {
        campusChoices("备份与文件传递",message:"所有功能在手机离线运行。JSON 传递路网；完整 ZIP 同时包含 AR 环境和照片。",choices:[
            ("导出完整备份 ZIP",{ [weak self] in self?.exportBackup() }),
            ("导出完整路网 JSON",{ [weak self] in
                guard let self else { return }
                do { let g = try CampusApp.library.load(self.id),url = ProbeIO.documents.appendingPathComponent("Exports/graph-\(self.id).json")
                    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try CampusFiles.encode(g,to:url);self.campusShare(url)
                } catch { self.campusError(error) }
            }),
            ("查看楼层路网图",{ [weak self] in guard let self else { return };self.navigationController?.pushViewController(CampusGraphController(graph:self.graph),animated:true) })])
    }
    private func exportBackup(regionID:String? = nil) {
        guard !busy else { return }; busy = true; title = "正在校验并备份…"
        let id = self.id, url = ProbeIO.documents.appendingPathComponent("Exports/campus-\(id)-\(UUID().uuidString.prefix(6)).zip")
        CampusApp.io.async { [weak self] in
            let result = Result { try CampusApp.library.export(id,destination:url,regionID:regionID); return url }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.reload()
                switch result { case .success(let url): self.campusShare(url); case .failure(let e): self.campusError(e) }
            }
        }
    }

}

final class CampusNodePicker: UITableViewController, UISearchResultsUpdating {
    private let graph: CampusGraph
    private let nodes: [CampusNode]
    private var shown: [CampusNode]
    private let done: (CampusNode) -> Void
    init(title: String, graph: CampusGraph, nodes: [CampusNode], done: @escaping (CampusNode) -> Void) {
        self.graph = graph; self.nodes = nodes; shown = nodes; self.done = done
        super.init(style:.insetGrouped); self.title = title
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); let search = UISearchController(searchResultsController:nil); search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "节点编号 / 楼层"; navigationItem.searchController = search
    }
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""; shown = text.isEmpty ? nodes : nodes.filter { graph.title($0).localizedCaseInsensitiveContains(text) }; tableView.reloadData()
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { shown.count }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil); c.textLabel?.text = graph.title(shown[p.row]); c.detailTextLabel?.text = shown[p.row].kind.title; return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        let n = shown[p.row]; navigationController?.popViewController(animated:false); DispatchQueue.main.async { self.done(n) }
    }
}

final class CampusConnectionsController: UITableViewController {
    private let id:String; private var graph:CampusGraph!
    private var busy = false
    init(id:String) { self.id = id; super.init(style:.insetGrouped); title = "线路连接" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated); graph = try? CampusApp.library.load(id); tableView.reloadData() }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { graph?.edges.count ?? 0 }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let e = graph.edges[p.row], c = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        c.textLabel?.text = "\(graph.node(e.from).map { graph.nodeLabel($0) } ?? "?") \(e.bidirectional ? "↔" : "→") \(graph.node(e.to).map { graph.nodeLabel($0) } ?? "?")"
        c.detailTextLabel?.text = e.kind == .stairs ? "楼梯 · 通行代价 \(e.cost_m) · \(e.enabled ? "可用" : "停用")" : String(format:"%@ · 估计 %.2f 米 · %@",graph.region(e.region_id!)?.name ?? "区域",e.length_m ?? 0,e.enabled ? "可用" : "停用")
        return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        guard !busy else { return }
        let edge = graph.edges[p.row]; tableView.deselectRow(at:p,animated:true)
        campusChoices("修改连接",choices:[(edge.enabled ? "暂时停用" : "恢复通行",{ [weak self] in self?.change(edge.id,remove:false) }),
            ("沿线房间（添加 / 编辑）",{ [weak self] in guard let self,edge.kind == .walk else { return };self.navigationController?.pushViewController(CampusRoomsController(id:self.id,edgeID:edge.id),animated:true) }),
            ("删除错误连接",{ [weak self] in self?.change(edge.id,remove:true) })])
    }
    private func change(_ eid:String,remove:Bool) {
        guard !busy else { return }; busy = true; title = "正在保存…"
        let id = self.id
        CampusApp.io.async { [weak self] in
            let result = Result { () -> CampusGraph in
                var g = try CampusApp.library.load(id)
                if remove { g.removeEdge(eid) } else if let i = g.edges.firstIndex(where:{$0.id == eid}) { g.edges[i].enabled.toggle() }
                return try CampusApp.library.save(g)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.title = "线路连接"
                switch result { case .success(let g): self.graph = g; self.tableView.reloadData(); case .failure(let e): self.campusError(e) }
            }
        }
    }
}
