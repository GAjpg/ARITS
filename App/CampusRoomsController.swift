import UIKit

extension CampusRoom.Side {
    static func allChoices(_ action:@escaping(CampusRoom.Side)->Void) -> [(String,()->Void)] {
        [("🟡 黄侧",{ action(.left) }),("🔵 蓝侧",{ action(.right) })]
    }
}
enum CampusRoomPlacement { case add(edgeID:String), move(roomID:String) }

final class CampusRoomsController: UITableViewController {
    private let id:String,edgeID:String
    private var graph:CampusGraph!
    private var rooms:[CampusRoom] = []
    private var busy = false
    private var groups:[[CampusRoom]] {
        graph?.roomGroups.compactMap { group in let local = group.filter { $0.edge_id == edgeID };return local.isEmpty ? nil : local }.sorted { ($0.first?.fraction ?? 0) < ($1.first?.fraction ?? 0) } ?? []
    }
    init(id:String,edgeID:String) { self.id = id;self.edgeID = edgeID;super.init(style:.insetGrouped);title = "沿线房间" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"标房间",style:.plain,target:self,action:#selector(add))
        #endif
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);reload() }
    private func reload() { graph = try? CampusApp.library.load(id);rooms = graph?.rooms.filter { $0.edge_id == edgeID }.sorted { $0.fraction < $1.fraction } ?? [];tableView.reloadData() }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { groups.count }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        guard let e = graph?.edges.first(where:{$0.id == edgeID}) else { return nil }
        return "\(graph.node(e.from).map { graph.nodeLabel($0) } ?? "起点") — \(graph.node(e.to).map { graph.nodeLabel($0) } ?? "终点") 的两侧分别显示黄线与蓝线。颜色固定在现实中的同一侧，不随转身交换。用 iPhone 对准房门旁的地面标注位置，再按房间靠近的颜色选择黄侧或蓝侧。Mac 可查看、改名和修改黄蓝侧。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let group = groups[p.row],r = group[0],c = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        let edge = graph.edges.first { $0.id == r.edge_id }
        c.textLabel?.text = r.name;c.detailTextLabel?.text = group.count > 1 ? "\(group.count) 个标注入口，点击选择管理" : String(format:"距 %@ 约 %.1f 米 · 线路%@",edge.flatMap { graph.node($0.from).map { graph.nodeLabel($0) } } ?? "线段起点",(edge?.length_m ?? 0)*r.fraction,r.side.title);c.accessoryType = .disclosureIndicator;return c
    }
    @objc private func add() { place(.add(edgeID:edgeID)) }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true);guard !busy else { return }
        let group = groups[p.row]
        if group.count == 1 { editRoom(group[0]);return }
        campusChoices(group[0].name,choices:group.enumerated().map { i,r in
            (String(format:"入口 %d · %@ · 距线段起点约 %.1f 米",i+1,r.side.title,(graph.edges.first { $0.id == r.edge_id }?.length_m ?? 0)*r.fraction),{ [weak self] in self?.editRoom(r) })
        })
    }
    private func editRoom(_ r:CampusRoom) {
        var choices:[(String,()->Void)] = [
            ("修改名称",{ [weak self] in self?.campusText("房间名称",value:r.name) { name in self?.commit { g in if let i = g.rooms.firstIndex(where:{$0.id == r.id}) { g.rooms[i].name = name } } } }),
            ("修改黄蓝侧",{ [weak self] in guard let self else { return };self.campusChoices("房间靠近线路哪种颜色？",message:self.tableView(self.tableView,titleForFooterInSection:0),choices:CampusRoom.Side.allChoices { side in self.commit { g in if let i = g.rooms.firstIndex(where:{$0.id == r.id}) { g.rooms[i].side = side } } }) })]
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        choices.append(("重新标注位置",{ [weak self] in self?.place(.move(roomID:r.id)) }))
        #endif
        choices.append(("删除房间标注",{ [weak self] in self?.commit { $0.rooms.removeAll { $0.id == r.id } } }))
        campusChoices(r.name,choices:choices)
    }
    private func place(_ task:CampusRoomPlacement) {
        guard !busy else { return }
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        do {
            let g = try CampusApp.library.load(id)
            guard let edge = g.edges.first(where:{$0.id == edgeID}),let rid = edge.region_id else { throw CampusError.invalid("连线已不存在，请重新打开路网。") }
            guard let dir = try? CampusApp.library.regionDirectory(buildingID:id,regionID:rid),FileManager.default.fileExists(atPath:dir.appendingPathComponent("environment.arworldmap").path) else { throw CampusError.invalid("本机没有环境地图，请先导入完整 ZIP 备份。") }
            let ar = CampusNetworkARController(graph:g,regionID:rid,roomTask:task),nav = UINavigationController(rootViewController:ar)
            nav.modalPresentationStyle = .fullScreen;present(nav,animated:true)
        } catch { campusError(error) }
        #else
        campusMessage("需要 iPhone 现场标注","房间位置要对准实际场景设置，不手填百分比。")
        #endif
    }
    private func commit(_ edit:@escaping(inout CampusGraph)->Void) {
        guard !busy else { return };busy = true;let id = self.id
        CampusApp.io.async { [weak self] in
            let result = Result { () -> Void in var g = try CampusApp.library.load(id);edit(&g);try g.validate();try CampusApp.library.save(g) }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;switch result { case .success:self.reload();case .failure(let e):self.campusError(e) } }
        }
    }
}
final class CampusDestinationPicker: UITableViewController,UISearchResultsUpdating {
    private let graph:CampusGraph
    private let destinations:[CampusDestination]
    private var shown:[CampusDestination]
    private let done:(CampusDestination)->Void
    init(graph:CampusGraph,destinations:[CampusDestination],done:@escaping(CampusDestination)->Void) {
        self.graph = graph;self.destinations = destinations;shown = destinations;self.done = done
        super.init(style:.insetGrouped);title = "选择目的地"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() { super.viewDidLoad();let search = UISearchController(searchResultsController:nil);search.searchResultsUpdater = self;search.obscuresBackgroundDuringPresentation = false;search.searchBar.placeholder = "房间 / 楼层";navigationItem.searchController = search }
    func updateSearchResults(for searchController:UISearchController) {
        let text = searchController.searchBar.text ?? "";shown = text.isEmpty ? destinations : destinations.filter { $0.title(in:graph).localizedCaseInsensitiveContains(text) };tableView.reloadData()
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { shown.count }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell { let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil),d = shown[p.row];c.textLabel?.text = d.title(in:graph);c.detailTextLabel?.text = d.kind == .room ? "同一环境同名房间，定位后选择最近可达入口" : "已标记目的地";return c }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) { let d = shown[p.row];navigationController?.popViewController(animated:false);DispatchQueue.main.async { self.done(d) } }
}
