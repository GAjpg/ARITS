import UIKit

final class CampusNavigationSetupController:UITableViewController {
    private var graph:CampusGraph,start:CampusStartSelection?,destination:CampusDestination?
    private var candidateID:String?
    private var starting = false
    private let done:(CampusGraph,CampusStartSelection,CampusDestination,String?)->Void
    init(graph:CampusGraph,initialStart:CampusStartSelection? = nil,initialCandidateID:String? = nil,done:@escaping(CampusGraph,CampusStartSelection,CampusDestination,String?)->Void) {
        self.graph = graph;start = initialStart;candidateID = initialCandidateID;self.done = done;super.init(style:.insetGrouped);title = "导航设置"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);tableView.reloadData() }
    override func numberOfSections(in tableView:UITableView) -> Int { 2 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { section == 0 ? 4 : 1 }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == 0 ? "起始地依次选择楼栋、楼层和环境，附近节点可不选。选定环境后直接恢复；只有不知道环境时才按画面搜索。" : "环境恢复后仍从真实位置出发，先核对路线是否与现场对齐。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        if p.section == 1 { c.textLabel?.text = starting ? "正在准备当地昼夜信息…" : "开始导航";c.textLabel?.textColor = start != nil && destination != nil ? .systemTeal : .secondaryLabel }
        else {
            if p.row == 3 {
                c.textLabel?.text = "昼夜恢复偏好";c.detailTextLabel?.text = CampusLightingSettings.shared.summary(graph.building_id);c.detailTextLabel?.numberOfLines = 0;c.accessoryType = .disclosureIndicator;return c
            }
            if p.row == 2 {
                c.textLabel?.text = "恢复子环境";c.detailTextLabel?.text = graph.mapCandidate(candidateID)?.name ?? "自动选择，失败后尝试其他子环境";c.accessoryType = .disclosureIndicator;return c
            }
            c.textLabel?.text = p.row == 0 ? "起始地" : "目的地"
            c.detailTextLabel?.text = p.row == 0 ? start.map { graph.name+" · "+$0.title(in:graph) } ?? "选择楼栋 / 楼层 / 环境" : destination?.title(in:graph) ?? "请选择"
            c.accessoryType = .disclosureIndicator
        };return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true)
        guard !starting else { return }
        if p.section == 1 {
            guard let start,let destination else { campusMessage("先选择起始地和目的地","起始地可明确选择不知道楼层或环境。");return }
            do { _ = try CampusLocalizationScope.make(graph:graph,start:start) } catch { campusError(error);return }
            starting = true;tableView.reloadData()
            let begin = { [weak self] in
                guard let self else { return };self.starting = false;self.tableView.reloadData()
                guard self.viewIfLoaded?.window != nil,self.navigationController?.topViewController === self else { return }
                self.navigationController?.popViewController(animated:false);DispatchQueue.main.async { self.done(self.graph,start,destination,self.candidateID) }
            }
            if candidateID == nil { CampusLightingSettings.shared.prepareForNavigation(graph.building_id,completion:begin) } else { begin() };return
        }
        if p.row == 3 { navigationController?.pushViewController(CampusLightingSettingsController(buildingID:graph.building_id),animated:true);return }
        if p.row == 2 {
            guard let rid = start?.directRegionID else { campusMessage("先指定起始环境","指定环境后可选择具体地图；不知道环境时自动搜索。");return }
            let entries = [CampusChoicePicker.Entry(title:"自动选择",detail:"先按附近节点范围，再按昼夜光照排序；失败尝试其他光照") { [weak self] in self?.candidateID = nil;self?.tableView.reloadData() }]+graph.map_candidates.filter { $0.region_id == rid }.map { m in
                CampusChoicePicker.Entry(title:m.name,detail:"仅测试此子环境；不自动换到旧图") { [weak self] in self?.candidateID = m.id;self?.tableView.reloadData() }
            }
            navigationController?.pushViewController(CampusChoicePicker(title:"选择恢复地图",entries:entries),animated:true);return
        }
        if p.row == 0 {
            navigationController?.pushViewController(CampusStartPicker(graph:graph,initial:start,allowBuildingChange:true) { [weak self] graph,start in
                guard let self else { return };if self.graph.building_id != graph.building_id { self.destination = nil };self.graph = graph;self.start = start;self.candidateID = nil;self.tableView.reloadData()
            },animated:true)
        } else {
            let choices = graph.roomDestinations + graph.nodes.filter { $0.kind != .waypoint }.map { CampusDestination(nodeID:$0.id) }
            guard !choices.isEmpty else { campusMessage("尚无目的地","先在所选楼栋添加房间或目的节点。");return }
            navigationController?.pushViewController(CampusDestinationPicker(graph:graph,destinations:choices) { [weak self] in self?.destination = $0;self?.tableView.reloadData() },animated:true)
        }
    }
}

final class CampusStartPicker:UITableViewController {
    private var graph:CampusGraph,floorID:String?,regionID:String?,nodeID:String?
    private var environmentChosen = false
    private let allowBuildingChange:Bool
    private let done:(CampusGraph,CampusStartSelection)->Void
    init(graph:CampusGraph,initial:CampusStartSelection? = nil,allowBuildingChange:Bool = false,done:@escaping(CampusGraph,CampusStartSelection)->Void) {
        self.graph = graph;self.done = done;self.allowBuildingChange = allowBuildingChange
        if let initial { switch initial {
        case .unknown:environmentChosen = true
        case .floor(let id):floorID = id;environmentChosen = true
        case .environment(let rid,let nid):regionID = rid;floorID = graph.region(rid)?.floor_id;nodeID = nid;environmentChosen = true
        case .region(let rid):regionID = rid;floorID = graph.region(rid)?.floor_id;environmentChosen = true
        case .place:break
        } }
        super.init(style:.insetGrouped);title = "选择起始地"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    private var selection:CampusStartSelection? {
        guard environmentChosen else { return nil }
        if let regionID { return .environment(regionID:regionID,nodeID:nodeID) }
        return floorID.map { .floor($0) } ?? .unknown
    }
    override func numberOfSections(in tableView:UITableView) -> Int { 2 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { section == 0 ? 4 : 1 }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == 0 ? "节点可选：选择后优先尝试为该节点设置的补采子环境，并检查附近位置。选定环境后直接恢复，不做图片检索；不知道环境时可在选定楼层内搜索。" : "不需要站到节点正上方。进入已采集位置，缓慢看向参考画面中的固定物体。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.value1,reuseIdentifier:nil)
        if p.section == 1 { c.textLabel?.text = "确认起始地";c.textLabel?.textColor = selection == nil ? .secondaryLabel : .systemTeal;return c }
        c.textLabel?.text = ["楼栋","楼层","环境","附近节点（可选）"][p.row]
        c.detailTextLabel?.text = [graph.name,floorID.map { graph.floorName($0) } ?? (environmentChosen ? "不知道楼层" : "请选择"),regionID.flatMap { graph.region($0)?.name } ?? (environmentChosen ? "不知道环境" : "请选择"),nodeID.flatMap { graph.node($0).map { graph.nodeLabel($0) } } ?? "不指定"][p.row]
        c.accessoryType = p.row == 0 && !allowBuildingChange ? .none : .disclosureIndicator;return c
    }
    private func choose(_ title:String,_ entries:[CampusChoicePicker.Entry]) {
        navigationController?.pushViewController(CampusChoicePicker(title:title,entries:entries),animated:true)
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true)
        if p.section == 1 {
            guard let selection else { campusMessage("请选择楼层和环境","也可以明确选择不知道楼层或环境。");return }
            do { _ = try CampusLocalizationScope.make(graph:graph,start:selection) } catch { campusError(error);return }
            navigationController?.popViewController(animated:false);DispatchQueue.main.async { self.done(self.graph,selection) };return
        }
        switch p.row {
        case 0:
            guard allowBuildingChange else { return }
            choose("选择楼栋",CampusApp.library.list().map { g in .init(title:g.name,detail:"\(g.floors.count) 层 · \(g.regions.count) 个环境") { [weak self] in self?.graph = g;self?.floorID = nil;self?.regionID = nil;self?.nodeID = nil;self?.environmentChosen = false;self?.tableView.reloadData() } })
        case 1:
            var choices:[CampusChoicePicker.Entry] = [.init(title:"不知道楼层和环境",detail:"搜索所选楼栋") { [weak self] in self?.floorID = nil;self?.regionID = nil;self?.nodeID = nil;self?.environmentChosen = true;self?.tableView.reloadData() }]
            choices += graph.floors.map { f in .init(title:f.name,detail:"") { [weak self] in self?.floorID = f.id;self?.regionID = nil;self?.nodeID = nil;self?.environmentChosen = false;self?.tableView.reloadData() } };choose("选择楼层",choices)
        case 2:
            guard let fid = floorID else { campusMessage("先选择楼层","不知道楼层时，可以直接确认并搜索所选楼栋。");return }
            var choices:[CampusChoicePicker.Entry] = [.init(title:"不知道环境",detail:"只在这个楼层搜索") { [weak self] in self?.regionID = nil;self?.nodeID = nil;self?.environmentChosen = true;self?.tableView.reloadData() }]
            choices += graph.regions.filter { $0.floor_id == fid && $0.map_saved }.map { r in .init(title:r.name,detail:"直接恢复此环境") { [weak self] in self?.regionID = r.id;self?.nodeID = nil;self?.environmentChosen = true;self?.tableView.reloadData() } };choose("选择环境",choices)
        default:
            guard let rid = regionID else { campusMessage("先选择环境","指定环境后才可选择其中的附近节点，节点也可以不选。");return }
            let ids = Set(graph.bindings.filter { $0.region_id == rid }.map(\.node_id))
            var choices:[CampusChoicePicker.Entry] = [.init(title:"不指定附近节点",detail:"在所选环境内识别真实位置") { [weak self] in self?.nodeID = nil;self?.tableView.reloadData() }]
            choices += graph.nodes.filter { ids.contains($0.id) }.map { n in .init(title:graph.nodeLabel(n),detail:n.kind.title) { [weak self] in self?.nodeID = n.id;self?.tableView.reloadData() } };choose("选择附近节点",choices)
        }
    }
}

final class CampusChoicePicker:UITableViewController,UISearchResultsUpdating {
    struct Entry { let title:String,detail:String,action:()->Void }
    private let entries:[Entry]
    private var shown:[Entry]
    init(title:String,entries:[Entry]) { self.entries = entries;shown = entries;super.init(style:.insetGrouped);self.title = title }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() { super.viewDidLoad();let search = UISearchController(searchResultsController:nil);search.searchResultsUpdater = self;search.obscuresBackgroundDuringPresentation = false;navigationItem.searchController = search }
    func updateSearchResults(for searchController:UISearchController) { let t = searchController.searchBar.text ?? "";shown = t.isEmpty ? entries : entries.filter { ($0.title+$0.detail).localizedCaseInsensitiveContains(t) };tableView.reloadData() }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { shown.count }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell { let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.textLabel?.text = shown[p.row].title;c.detailTextLabel?.text = shown[p.row].detail;c.isAccessibilityElement = true;c.accessibilityLabel = shown[p.row].title+(shown[p.row].detail.isEmpty ? "" : "，"+shown[p.row].detail);c.accessibilityTraits = .button;return c }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) { let action = shown[p.row].action;navigationController?.popViewController(animated:false);DispatchQueue.main.async { action() } }
}
