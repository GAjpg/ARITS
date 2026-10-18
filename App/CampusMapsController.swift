import UIKit
import UniformTypeIdentifiers

final class CampusMapsController:UITableViewController,UIDocumentPickerDelegate {
    private let buildingID:String,regionID:String
    private var graph:CampusGraph!
    private var busy = false
    private let capture:(String?,CampusLighting?,Bool,Bool)->Void
    init(buildingID:String,regionID:String,capture:@escaping(String?,CampusLighting?,Bool,Bool)->Void) {
        self.buildingID = buildingID;self.regionID = regionID;self.capture = capture
        super.init(style:.insetGrouped);title = "子环境"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    private var maps:[CampusMapCandidate] { graph?.map_candidates.filter { $0.region_id == regionID }.sorted { $0.saved_utc > $1.saved_utc } ?? [] }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);reload() }
    private func reload() { do { graph = try CampusApp.library.load(buildingID);tableView.reloadData() } catch { campusError(error) } }
    override func numberOfSections(in tableView:UITableView) -> Int { 2 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { section == 0 ? 2 : maps.count }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? { section == 0 ? "创建与导入" : "已保存的子环境" }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == 0 ? "创建时选择原图和光照，先恢复并核对路网，再扫描局部。首次保存时在路网图上确认对应节点；本次继续保存只更新同一子环境。" : "进入已有子环境补充路网或补采光照时，保存覆盖此子环境，其他子环境保留。删除保护不阻止主动更新。更新后需重新实测；覆盖前可导出 ZIP 备份。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        if p.section == 0 {
            c.textLabel?.text = p.row == 0 ? "创建子环境" : "从旧 ZIP 导入子环境"
            c.detailTextLabel?.text = p.row == 0 ? "选择原图与光照，恢复后精细扫描并确认对应节点" : "找回补采前的地图，当前路网保留"
        } else {
            let m = maps[p.row],isDefault = graph.region(regionID)?.default_map_id == m.id
            c.textLabel?.text = m.name+(isDefault ? " · 默认" : "")
            let size = (try? CampusApp.library.candidateDirectory(buildingID:buildingID,candidateID:m.id)).map { ByteCountFormatter.string(fromByteCount:CampusStorage.bytes(at:$0),countStyle:.file) } ?? "未知大小"
            let priority = m.preferred_node_ids.map { " · \($0.count) 个优先节点" } ?? ""
            c.detailTextLabel?.text = "\(m.lighting.title) · \(m.verified ? "已实测" : "待实测") · \(m.protected ? "受保护" : "可删除") · \(m.enabled ? "参与恢复" : "已停用") · \(size)\(priority)"
        };c.accessoryType = .disclosureIndicator;return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true);guard !busy else { return }
        if p.section == 0 {
            if p.row == 0 { chooseSupplementSource() }
            else { let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.zip],asCopy:true);picker.delegate = self;present(picker,animated:true) };return
        }
        let m = maps[p.row]
        var choices:[(String,()->Void)] = [
            ("查看此图特征分布",{ [weak self] in guard let self else { return };self.navigationController?.pushViewController(CampusGraphController(graph:self.graph,regionID:m.region_id,featureMode:1,candidateID:m.id),animated:true) }),
            ("在路网图上设置对应节点",{ [weak self] in self?.editPriority(m) }),
            ("补充路网",{ [weak self] in self?.capture(m.id,nil,false,true) }),
            ("补采光照",{ [weak self] in self?.campusChoices("本次光照",choices:CampusLighting.allCases.map { light in (light.title,{ [weak self] in self?.capture(m.id,light,true,true) }) }) }),
            ("以此图做冷启动导航测试",{ [weak self] in self?.navigationTest(m) }),
            ("导出此子环境 ZIP",{ [weak self] in self?.export(m) }),
            ("设为默认恢复地图",{ [weak self] in self?.change { g in if let i = g.regions.firstIndex(where:{$0.id == m.region_id}),let j = g.map_candidates.firstIndex(where:{$0.id == m.id}) { g.map_candidates[j].enabled = true;g.regions[i].default_map_id = m.id } } }),
            (m.verified ? "撤销已实测标记" : "标记已实测可恢复",{ [weak self] in
                guard let self else { return }
                self.campusChoices("人工实测标记",message:"只有退出采集后，在此图覆盖区域重新开启导航、成功恢复并核对位置，才标记已实测。一次成功不能保证所有光照和位置都可恢复。",choices:[("确认修改标记",{ [weak self] in self?.edit(m.id) { $0.verified.toggle();if $0.verified { $0.protected = true } } })])
            }),
            (m.protected ? "解除删除保护" : "保护此图",{ [weak self] in self?.edit(m.id) { $0.protected.toggle() } }),
            (m.enabled ? "停用自动恢复" : "启用自动恢复",{ [weak self] in self?.change { g in
                guard g.region(m.region_id)?.default_map_id != m.id || !m.enabled else { throw CampusError.invalid("请先把另一张图设为默认，再停用这张图。") }
                if let i = g.map_candidates.firstIndex(where:{$0.id == m.id}) { g.map_candidates[i].enabled.toggle() }
            } }),
            ("修改名称",{ [weak self] in self?.campusText("子环境名称",value:m.name) { [weak self] name in self?.edit(m.id) { $0.name = name } } })]
        if !m.protected { choices.append(("删除子环境文件",{ [weak self] in self?.delete(m) })) }
        campusChoices(m.name,message:"编号：\(m.id.prefix(8)) · \(m.saved_utc)\n补充路网或补采光照保存时更新此子环境，不新增。",choices:choices)
    }
    private func chooseSupplementSource() {
        guard !maps.isEmpty else { campusMessage("先保存原始环境","先完成初次建路网，或导入含环境地图的 ZIP。");return }
        let entries = graph.rankedMaps(regionID:regionID).map { m in
            CampusChoicePicker.Entry(title:m.name,detail:m.verified ? "已实测；先恢复并核对路网" : "待实测；先恢复并核对路网") { [weak self] in self?.chooseCreationLighting(m) }
        }
        navigationController?.pushViewController(CampusChoicePicker(title:"选择要恢复的原图",entries:entries),animated:true)
    }
    private func chooseCreationLighting(_ source:CampusMapCandidate) {
        campusChoices("新子环境的光照",message:"恢复所选原图并核对位置后开始局部采集；首次保存创建一个子环境，后续保存更新它。",choices:CampusLighting.allCases.map { light in
            (light.title,{ [weak self] in self?.capture(source.id,light,true,false) })
        })
    }
    private func editPriority(_ m:CampusMapCandidate) {
        let local = Set(graph.bindings.filter { $0.region_id == m.region_id }.map(\.node_id))
        let suggested = m.suggested_node_ids ?? m.node_coverage.filter { $0.value >= 30 && local.contains($0.key) }.map(\.key)
        navigationController?.pushViewController(CampusMapNodeSelectionController(graph:graph,regionID:m.region_id,selected:m.preferred_node_ids ?? suggested,suggested:suggested) { [weak self] ids in
            self?.edit(m.id) { $0.preferred_node_ids = ids }
        },animated:true)
    }
    private func navigationTest(_ m:CampusMapCandidate) {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        navigationController?.pushViewController(CampusNavigationSetupController(graph:graph,initialStart:.environment(regionID:m.region_id,nodeID:nil),initialCandidateID:m.id) { [weak self] g,start,destination,mapID in
            guard let self else { return }
            let c = CampusNetworkARController(graph:g,destination:destination,start:start,candidateID:mapID)
            let nav = UINavigationController(rootViewController:c);nav.modalPresentationStyle = .fullScreen;self.present(nav,animated:true)
        },animated:true)
        #else
        campusMessage("需要 iPhone","地图文件与路网可在 Mac 管理，恢复测试需要真实 iPhone。")
        #endif
    }
    private func export(_ m:CampusMapCandidate) {
        guard !busy else { return };busy = true
        let id = buildingID,url = ProbeIO.documents.appendingPathComponent("Exports/map-\(m.id).zip")
        CampusApp.io.async { [weak self] in
            let result = Result { try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try CampusApp.library.export(id,destination:url,candidateID:m.id) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;switch result { case .success:self.campusShare(url);case .failure(let e):self.campusError(e) } }
        }
    }
    private func edit(_ id:String,_ body:@escaping(inout CampusMapCandidate)->Void) { change { g in if let i = g.map_candidates.firstIndex(where:{$0.id == id}) { body(&g.map_candidates[i]) } } }
    private func change(_ body:@escaping(inout CampusGraph)throws->Void) {
        guard !busy else { return };busy = true
        let id = buildingID
        CampusApp.io.async { [weak self] in
            let result = Result { var g = try CampusApp.library.load(id);try body(&g);return try CampusApp.library.save(g) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;switch result { case .success:self.reload();case .failure(let e):self.campusError(e) } }
        }
    }
    private func delete(_ m:CampusMapCandidate) {
        guard graph.region(regionID)?.default_map_id != m.id else { campusMessage("默认地图不能删除","先设置另一张地图为默认。");return }
        let alert = UIAlertController(title:"删除这张地图？",message:"会删除地图和参考照片；旧历史版本中指向此图的引用也将不可用。请先导出备份。当前路网保留。",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"删除",style:.destructive) { [weak self] _ in
            guard let self else { return };self.busy = true
            CampusApp.io.async { [weak self] in
                guard let self else { return }
                let result = Result { try CampusApp.library.deleteCandidate(buildingID:self.buildingID,candidateID:m.id) }
                DispatchQueue.main.async { self.busy = false;switch result { case .success:self.reload();case .failure(let e):self.campusError(e) } }
            }
        });present(alert,animated:true)
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let url = urls.first,!busy else { return };busy = true
        let access = url.startAccessingSecurityScopedResource(),id = buildingID,rid = regionID
        CampusApp.io.async { [weak self] in
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try CampusApp.library.importCandidateBackup(url,buildingID:id,regionID:rid,validateMap: { native,snapshot in
                #if !targetEnvironment(macCatalyst)
                try CampusARStore.validateArchive(native,snapshot:snapshot)
                #endif
            }) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;switch result { case .success:self.reload();self.campusMessage("旧图已作为子环境保存","原来的路网和地图没有替换。请选择这个子环境进行冷启动导航验证。") ;case .failure(let e):self.campusError(e) } }
        }
    }
}
