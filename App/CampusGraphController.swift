import UIKit

final class CampusGraphController: UIViewController, UIScrollViewDelegate {
    private var graph: CampusGraph
    private var regionID: String?
    private var candidateID:String?
    private let layers = UISegmentedControl(items:["路网","特征点","密度网格"])
    private var cloudPreview:CampusFeaturePointCloud?
    private var featureLayers:[CampusFeatureLayer] = []
    private var visibleMapIDs:Set<String>?
    private var featureFailures:[String] = []
    private var loadedRegionID:String?,loadedRevision:Int?
    private var featureToken = UUID()
    private let caption = UILabel(), scroll = UIScrollView(), canvas = CampusGraphCanvas()
    init(graph: CampusGraph,regionID:String? = nil,featureMode:Int = 0,preview:CampusFeaturePointCloud? = nil,candidateID:String? = nil) {
        self.candidateID = candidateID;self.graph = graph;self.regionID = regionID ?? graph.regions.first?.id;cloudPreview = preview
        visibleMapIDs = candidateID.map { [$0] }
        super.init(nibName:nil,bundle:nil);layers.selectedSegmentIndex = min(2,max(0,featureMode))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "路网图"; view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title:"楼层 / 区域",style:.plain,target:self,action:#selector(chooseRegion)),UIBarButtonItem(title:"子环境显示",style:.plain,target:self,action:#selector(chooseFeatureMaps))]
        caption.numberOfLines = 0; caption.font = .systemFont(ofSize:14); caption.translatesAutoresizingMaskIntoConstraints = false
        layers.translatesAutoresizingMaskIntoConstraints = false;layers.addTarget(self,action:#selector(changeLayer),for:.valueChanged)
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.minimumZoomScale = 0.25; scroll.maximumZoomScale = 6; scroll.delegate = self
        view.addSubview(layers);view.addSubview(caption); view.addSubview(scroll); scroll.addSubview(canvas)
        canvas.frame = CGRect(x:0,y:0,width:1000,height:700); scroll.contentSize = canvas.bounds.size
        canvas.onEdge = { [weak self] edge,t in self?.select(edge,fraction:t) }
        canvas.onCell = { [weak self] x,z,count in self?.campusMessage("网格点数",String(format:"区域坐标 X %.0f–%.0f 米，Z %.0f–%.0f 米。\n这个 1 米网格中有 %d 个显示点，所有高度叠加。\n\n点少或无点不等于没有采集；点多也不代表一定能恢复。",x,x+1,z,z+1,count)) }
        NSLayoutConstraint.activate([layers.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:12),layers.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),layers.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),caption.topAnchor.constraint(equalTo:layers.bottomAnchor,constant:10),caption.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),caption.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),scroll.topAnchor.constraint(equalTo:caption.bottomAnchor,constant:12),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor)])
    }
    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated); if cloudPreview == nil,let g = try? CampusApp.library.load(graph.building_id) { graph = g }; show()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); if scroll.zoomScale == 1,scroll.bounds.width > 0,scroll.bounds.width < 1000 { scroll.zoomScale = max(0.4,scroll.bounds.width/1000) }
    }
    func viewForZooming(in scrollView:UIScrollView) -> UIView? { canvas }
    private func show() {
        featureToken = UUID();canvas.featureLayers = [];canvas.featureCloud = nil;canvas.featureMode = layers.selectedSegmentIndex
        navigationItem.rightBarButtonItems?.last?.isEnabled = false
        canvas.graph = graph; canvas.regionID = regionID; canvas.plan = nil; canvas.setNeedsDisplay()
        caption.text = regionID.flatMap { graph.region($0) }.map { "\(graph.floorName($0.floor_id)) · \($0.name)\n点击连线编辑房间或试算路线；黄侧／蓝侧固定，不随行走方向交换。可双指缩放。各区域坐标独立，共同节点连接逻辑路网；两个相距较远的共同节点可连接坐标。" } ?? "先创建区域并采集路网。"
        guard layers.selectedSegmentIndex > 0,let rid = regionID,let region = graph.region(rid) else { return }
        if let preview = cloudPreview,preview.region_id == rid { display(preview,region:region);return }
        guard region.map_saved else { caption.text = "此环境尚未保存。采集页可从「更多 → 查看当前采集分布」检查未保存的快照。";return }
        if loadedRegionID == rid,loadedRevision == graph.revision {
            navigationItem.rightBarButtonItems?.last?.isEnabled = !featureLayers.isEmpty;displayLayers(region:region);return
        }
        featureLayers = [];featureFailures = []
        caption.text = "正在读取此区域所有子环境的特征点…"
        let token = featureToken,g = graph
        CampusApp.io.async { [weak self] in
            let result = CampusFeatureStore.loadAll(graph:g,region:region)
            DispatchQueue.main.async {
                guard let self,self.featureToken == token else { return }
                self.featureLayers = result.layers;self.featureFailures = result.failures
                self.loadedRegionID = region.id;self.loadedRevision = g.revision
                self.navigationItem.rightBarButtonItems?.last?.isEnabled = !result.layers.isEmpty
                self.displayLayers(region:region)
            }
        }
    }
    private func displayLayers(region:CampusRegion) {
        let shown = featureLayers.filter { visibleMapIDs?.contains($0.id) ?? true }
        canvas.layerColors = Dictionary(uniqueKeysWithValues:featureLayers.enumerated().map { ($0.element.id,CampusGraphCanvas.featureColor($0.offset)) })
        canvas.featureLayers = CampusFeatureDistribution.sampledLayers(shown);canvas.setNeedsDisplay()
        let cloud = canvas.featureCloud,count = cloud?.points.count ?? 0
        let grid = layers.selectedSegmentIndex == 2 ? "1 米网格显示所选地图的叠加点数。" : "不同颜色代表不同子环境；可在「子环境显示」逐张开关。"
        let legend = shown.prefix(4).enumerated().map { "● "+$0.element.name }.joined(separator:" · ")
        let errors = featureFailures.isEmpty ? "" : "\n\(featureFailures.count) 张地图未能读取，可在子环境显示中查看原因。"
        caption.text = "\(graph.floorName(region.floor_id)) · \(region.name)\n显示 \(shown.count)/\(featureLayers.count) 个子环境 · \(count) 个显示点\n\(legend)\(shown.count > 4 ? "…" : "")\n\(grid)双指缩放，点击网格查点数。\n重叠位置可能重复计数；大点云会采样显示，不代表恢复成功率。\(errors)"
    }
    private func display(_ cloud:CampusFeaturePointCloud,region:CampusRegion) {
        canvas.featureCloud = cloud;canvas.setNeedsDisplay()
        let source = cloud.source == .savedMap ? (graph.mapCandidate(candidateID ?? region.default_map_id)?.name ?? "已保存地图") : "当前会话快照 · 未保存"
        let sampled = cloud.source_point_count == cloud.points.count ? "\(cloud.points.count) 个粗略特征点" : "\(cloud.source_point_count) 个粗略点，显示采样 \(cloud.points.count) 个"
        let grid = layers.selectedSegmentIndex == 2 ? "1 米网格；浅蓝少、橙色多，最多 \(cloud.density().map(\.count).max() ?? 0) 点／格。" : "橙色为特征点，路网叠加在上方。"
        caption.text = "\(graph.floorName(region.floor_id)) · \(region.name) · \(source)\n\(sampled) · \(String(cloud.captured_utc.prefix(19)).replacingOccurrences(of:"T",with:" ")) UTC\n\(grid)俯视叠加所有高度，可缩放、点击查点数。\n这是特征分布示意，不是采集完成度或恢复成功率。"
    }
    @objc private func changeLayer() { show() }
    @objc private func chooseRegion() {
        campusChoices("查看哪一层 / 区域？",choices:graph.regions.map { r in (graph.floorName(r.floor_id)+" · "+r.name,{ [weak self] in self?.regionID = r.id;self?.candidateID = nil;self?.visibleMapIDs = nil; self?.show() }) })
    }
    @objc private func chooseFeatureMaps() {
        guard !featureLayers.isEmpty else { return }
        navigationController?.pushViewController(CampusFeatureLayerPicker(layers:featureLayers,selected:visibleMapIDs ?? Set(featureLayers.map(\.id)),failures:featureFailures) { [weak self] ids in
            guard let self,let region = self.regionID.flatMap({ self.graph.region($0) }) else { return }
            self.visibleMapIDs = ids;self.displayLayers(region:region)
        },animated:true)
    }
    private func select(_ edge:CampusEdge,fraction:Double) {
        campusChoices("\(graph.node(edge.from).map { graph.nodeLabel($0) } ?? "") → \(graph.node(edge.to).map { graph.nodeLabel($0) } ?? "")",message:String(format:"连线估计 %.2f 米。房间位置在 iPhone 上现场标注。",edge.length_m ?? 0),choices:[
            ("查看 / 标注沿线房间",{ [weak self] in guard let self else { return }; self.navigationController?.pushViewController(CampusRoomsController(id:self.graph.building_id,edgeID:edge.id),animated:true) }),
            ("从点击位置试算路线",{ [weak self] in self?.preview(edge,fraction:fraction) })])
    }
    private func preview(_ edge:CampusEdge,fraction:Double) {
        let choices = graph.roomDestinations + graph.nodes.filter { $0.kind != .waypoint }.map { CampusDestination(nodeID:$0.id) }
        guard !choices.isEmpty,let rid = edge.region_id else { campusMessage("没有目的地","先在连线上添加房间。"); return }
        navigationController?.pushViewController(CampusDestinationPicker(graph:graph,destinations:choices) { [weak self] destination in
            guard let self else { return }
            do {
                let p = try CampusApp.planner.plan(CampusPlanningRequest(graph:self.graph,start:CampusRoutePosition(regionID:rid,edgeID:edge.id,fraction:fraction),destination:destination))
                self.canvas.plan = p; self.canvas.setNeedsDisplay()
                let legs = p.path.legs.map { l in l.kind == .stairs ? "经楼梯到 \(self.graph.node(l.node_ids.last!).map { self.graph.floorName($0.floor_id) } ?? "另一层")" : self.graph.region(l.region_id!)?.name ?? "走廊" }.joined(separator:" → ")
                self.caption.text = "路线试算：\(destination.title(in:self.graph))\n\(legs)\n选路总代价 \(String(format:"%.1f",p.path.total_cost_m))（含楼梯代价）。\(p.arrival_hint ?? "")\n此处是地图点击位置，不代表真实定位。"
            } catch { self.campusError(error) }
        },animated:true)
    }
}

private final class CampusGraphCanvas: UIView {
    var graph:CampusGraph?, regionID:String?, plan:CampusNavigationPlan?
    var featureMode = 0
    var featureCloud:CampusFeaturePointCloud? { didSet { cells = featureCloud?.density() ?? [] } }
    var featureLayers:[CampusFeatureLayer] = [] { didSet { featureCloud = CampusFeatureDistribution.combined(featureLayers) } }
    var layerColors:[String:UIColor] = [:]
    var selectableNodes = false
    var selectedNodeIDs = Set<String>()
    private var cells:[CampusFeaturePointCloud.Cell] = []
    private var projection:(x:Double,z:Double,scale:Double)?
    var onEdge:((CampusEdge,Double)->Void)?
    var onCell:((Double,Double,Int)->Void)?
    var onNode:((String)->Void)?
    private var drawn:[(CampusEdge,CGPoint,CGPoint)] = []
    private var drawnNodes:[(String,CGPoint)] = []
    static func featureColor(_ index:Int) -> UIColor { [.systemOrange,.systemPurple,.systemBlue,.systemPink,.systemTeal,.systemGreen][index%6] }
    override init(frame:CGRect) { super.init(frame:frame); backgroundColor = .systemBackground; addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tap))) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func draw(_ rect:CGRect) {
        guard let graph,let rid = regionID,let ctx = UIGraphicsGetCurrentContext() else { return }; drawn = [];drawnNodes = []; accessibilityElements = []
        projection = nil
        let bindings = graph.bindings.filter { $0.region_id == rid }
        let features = featureMode > 0 ? (featureCloud?.points ?? []) : []
        let positions = bindings.map(\.position)+features.map(\.array);guard !positions.isEmpty else { return }
        let minX = positions.map { $0[0] }.min()!,maxX = positions.map { $0[0] }.max()!,minZ = positions.map { $0[2] }.min()!,maxZ = positions.map { $0[2] }.max()!
        let scale = min(820/max(1,maxX-minX),480/max(1,maxZ-minZ))
        projection = (minX,minZ,scale)
        func point(_ p:[Double]) -> CGPoint { CGPoint(x:90+(p[0]-minX)*scale,y:100+(p[2]-minZ)*scale) }
        func label(_ text:String,_ p:CGPoint,_ color:UIColor = .label) { (text as NSString).draw(at:p,withAttributes:[.font:UIFont.systemFont(ofSize:17,weight:.medium),.foregroundColor:color]) }
        if featureMode == 1 {
            let display = featureLayers.isEmpty ? [(UIColor.systemOrange,features)] : featureLayers.map { (layerColors[$0.id] ?? .systemOrange,$0.cloud.points) }
            for (color,points) in display {
                ctx.setFillColor(color.withAlphaComponent(0.65).cgColor)
                for p in points { let c = point(p.array);ctx.fillEllipse(in:CGRect(x:c.x-1.5,y:c.y-1.5,width:3,height:3)) }
            }
        } else if featureMode == 2 {
            let maximum = Double(cells.map(\.count).max() ?? 1)
            for cell in cells {
                let weight = log1p(Double(cell.count))/log1p(maximum)
                let color = weight > 0.65 ? UIColor.systemOrange : UIColor.systemCyan
                ctx.setFillColor(color.withAlphaComponent(0.15+0.65*weight).cgColor)
                let c = point([Double(cell.x),0,Double(cell.z)])
                ctx.fill(CGRect(x:c.x,y:c.y,width:scale,height:scale))
            }
        }
        for e in graph.edges where e.region_id == rid && e.kind == .walk {
            guard let a = graph.binding(nodeID:e.from,regionID:rid),let b = graph.binding(nodeID:e.to,regionID:rid) else { continue }
            let pa = point(a.position),pb = point(b.position); drawn.append((e,pa,pb)); ctx.setStrokeColor((e.enabled ? UIColor.systemGray : UIColor.systemRed).cgColor); ctx.setLineWidth(5); ctx.move(to:pa); ctx.addLine(to:pb); ctx.strokePath()
            let accessible = CampusEdgeAccessibility(accessibilityContainer:self)
            let title = "\(graph.nodeLabel(graph.node(e.from)!)) → \(graph.nodeLabel(graph.node(e.to)!))"
            accessible.accessibilityLabel = featureMode > 0 ? "特征网格 · \(title)中点" : "连接 \(title)"
            accessible.accessibilityHint = featureMode > 0 ? "查询线路中点所在 1 米网格的特征点数" : "编辑沿线房间或从连线中点试算路线"
            accessible.accessibilityTraits = .button
            accessible.accessibilityFrameInContainerSpace = CGRect(x:min(pa.x,pb.x)-18,y:min(pa.y,pb.y)-18,width:abs(pa.x-pb.x)+36,height:abs(pa.y-pb.y)+36)
            accessible.activate = { [weak self] in
                guard let self else { return }
                if self.featureMode > 0 {
                    if let cloud = self.featureCloud {
                        let x = floor((a.position[0]+b.position[0])/2),z = floor((a.position[2]+b.position[2])/2)
                        self.onCell?(x,z,cloud.count(x:x,z:z))
                    }
                } else { self.onEdge?(e,0.5) }
            };if !selectableNodes { accessibilityElements?.append(accessible) }
            let dx = pb.x-pa.x,dz = pb.y-pa.y,len = hypot(dx,dz)
            for (offset,color) in [(CGFloat(-6),UIColor.systemYellow),(CGFloat(6),UIColor.systemBlue)] {
                let ox = -dz/max(1,len)*offset,oy = dx/max(1,len)*offset
                ctx.setStrokeColor(color.cgColor);ctx.setLineWidth(3);ctx.move(to:CGPoint(x:pa.x+ox,y:pa.y+oy));ctx.addLine(to:CGPoint(x:pb.x+ox,y:pb.y+oy));ctx.strokePath()
            }
            for r in graph.rooms where r.edge_id == e.id && !selectableNodes {
                let side:CGFloat = r.side == .right ? 1 : -1, t = CGFloat(r.fraction)
                let center = CGPoint(x:pa.x+dx*t,y:pa.y+dz*t),door = CGPoint(x:center.x-dz/max(1,len)*28*side,y:center.y+dx/max(1,len)*28*side)
                let color:UIColor = r.side == .left ? .systemYellow : .systemBlue;ctx.setStrokeColor(color.cgColor);ctx.setLineWidth(2);ctx.move(to:center);ctx.addLine(to:door);ctx.strokePath();label(r.name+" · "+r.side.title,door,color == .systemYellow ? .systemOrange : .systemBlue)
            }
        }
        if let plan {
            ctx.setStrokeColor(UIColor.systemGreen.cgColor);ctx.setLineWidth(9)
            for leg in plan.path.legs where leg.region_id == rid {
                let ps = leg.node_ids.compactMap { plan.point(nodeID:$0,regionID:rid).map { point($0.map_position) } }
                if let first = ps.first { ctx.move(to:first); for p in ps.dropFirst() { ctx.addLine(to:p) };ctx.strokePath() }
            }
        }
        for b in bindings {
            let p = point(b.position),n = graph.node(b.node_id)!
            drawnNodes.append((n.id,p))
            let selected = selectedNodeIDs.contains(n.id),radius:CGFloat = selectableNodes ? 11 : 7
            ctx.setFillColor((selectableNodes ? (selected ? UIColor.systemBlue : UIColor.systemGray3) : (n.kind == .stair ? UIColor.systemOrange : UIColor.systemMint)).cgColor)
            ctx.fillEllipse(in:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
            if let name = graph.nodeMapLabel(n) { label(name,CGPoint(x:p.x+14,y:p.y-25)) }
            if selectableNodes {
                let accessible = CampusEdgeAccessibility(accessibilityContainer:self)
                accessible.accessibilityLabel = graph.nodeLabel(n)+(selected ? "，已选中" : "，未选中");accessible.accessibilityTraits = selected ? [.button,.selected] : .button
                accessible.accessibilityFrameInContainerSpace = CGRect(x:p.x-22,y:p.y-22,width:44,height:44)
                accessible.activate = { [weak self] in self?.onNode?(n.id) };accessibilityElements?.append(accessible)
            }
        }
        let meters = [1.0,2,5,10,20,50,100,200,500,1000].last(where:{$0*scale <= 220}) ?? 1
        ctx.setStrokeColor(UIColor.label.cgColor);ctx.setLineWidth(3);ctx.move(to:CGPoint(x:90,y:640));ctx.addLine(to:CGPoint(x:90+meters*scale,y:640));ctx.strokePath()
        label("\(Int(meters)) 米",CGPoint(x:90,y:650))
    }
    @objc private func tap(_ recognizer:UITapGestureRecognizer) {
        let p = recognizer.location(in:self)
        if selectableNodes {
            if let node = drawnNodes.min(by:{ hypot(p.x-$0.1.x,p.y-$0.1.y) < hypot(p.x-$1.1.x,p.y-$1.1.y) }),hypot(p.x-node.1.x,p.y-node.1.y) <= 30 { onNode?(node.0) }
            return
        }
        if featureMode > 0 {
            if let projection,let cloud = featureCloud {
                let x = floor((Double(p.x)-90)/projection.scale+projection.x),z = floor((Double(p.y)-100)/projection.scale+projection.z)
                onCell?(x,z,cloud.count(x:x,z:z))
            };return
        }
        let hits = drawn.map { e,a,b -> (CampusEdge,Double,CGFloat) in
            let dx = b.x-a.x,dz = b.y-a.y,t = min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dz)/max(1,dx*dx+dz*dz)))
            return (e,Double(t),hypot(p.x-a.x-dx*t,p.y-a.y-dz*t))
        }; if let best = hits.min(by:{$0.2 < $1.2}),best.2 < 36 { onEdge?(best.0,best.1) }
    }
}

private final class CampusEdgeAccessibility: UIAccessibilityElement {
    var activate:(()->Void)?
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

private final class CampusFeatureLayerPicker:UITableViewController {
    private let layers:[CampusFeatureLayer],failures:[String]
    private var selected:Set<String>
    private let changed:(Set<String>)->Void
    init(layers:[CampusFeatureLayer],selected:Set<String>,failures:[String],changed:@escaping(Set<String>)->Void) {
        self.layers = layers;self.selected = selected;self.failures = failures;self.changed = changed
        super.init(style:.insetGrouped);title = "子环境显示"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();navigationItem.rightBarButtonItems = [UIBarButtonItem(title:"全部显示",style:.plain,target:self,action:#selector(showAll)),UIBarButtonItem(title:"全部隐藏",style:.plain,target:self,action:#selector(hideAll))]
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { layers.count }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        "开关仅改变分布图显示，不影响子环境的自动恢复、保护或原始文件。"+(failures.isEmpty ? "" : "\n未能读取：\n"+failures.joined(separator:"\n"))
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let layer = layers[p.row],c = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        c.textLabel?.text = layer.name;c.detailTextLabel?.text = "\(layer.cloud.source_point_count) 个粗略点 · \(layer.id.prefix(8))"
        c.imageView?.image = UIImage(systemName:"circle.fill");c.imageView?.tintColor = CampusGraphCanvas.featureColor(p.row)
        let toggle = UISwitch();toggle.tag = p.row;toggle.isOn = selected.contains(layer.id);toggle.accessibilityLabel = layer.name+"的特征点显示"
        toggle.addTarget(self,action:#selector(toggleLayer(_:)),for:.valueChanged);c.accessoryView = toggle;return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) { tableView.deselectRow(at:p,animated:true);toggle(layers[p.row].id) }
    @objc private func toggleLayer(_ sender:UISwitch) { toggle(layers[sender.tag].id) }
    private func toggle(_ id:String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) };changed(selected);tableView.reloadData() }
    @objc private func showAll() { selected = Set(layers.map(\.id));changed(selected);tableView.reloadData() }
    @objc private func hideAll() { selected = [];changed(selected);tableView.reloadData() }
}

final class CampusMapNodeSelectionController:UIViewController,UIScrollViewDelegate {
    private let graph:CampusGraph,regionID:String,suggested:Set<String>
    private var selected:Set<String>
    private let done:([String])->Void
    private let caption = UILabel(),scroll = UIScrollView(),canvas = CampusGraphCanvas()
    init(graph:CampusGraph,regionID:String,selected:[String],suggested:[String],done:@escaping([String])->Void) {
        self.graph = graph;self.regionID = regionID
        let valid = Set(graph.bindings.filter { $0.region_id == regionID }.map(\.node_id))
        self.selected = Set(selected).intersection(valid);self.suggested = Set(suggested).intersection(valid);self.done = done
        super.init(nibName:nil,bundle:nil);title = "子环境对应节点"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"完成",style:.done,target:self,action:#selector(finish))
        if navigationController?.viewControllers.first === self { navigationItem.leftBarButtonItem = UIBarButtonItem(title:"取消",style:.plain,target:self,action:#selector(cancel)) }
        caption.numberOfLines = 0;caption.font = .systemFont(ofSize:14);caption.translatesAutoresizingMaskIntoConstraints = false
        let actions = UIStackView();actions.axis = .horizontal;actions.distribution = .fillEqually;actions.spacing = 12;actions.translatesAutoresizingMaskIntoConstraints = false
        for (name,selector) in [("自动推荐",#selector(useSuggested)),("全选",#selector(selectEveryNode)),("清空",#selector(clear))] {
            let button = UIButton(type:.system);button.setTitle(name,for:.normal);button.addTarget(self,action:selector,for:.touchUpInside);actions.addArrangedSubview(button)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false;scroll.minimumZoomScale = 0.25;scroll.maximumZoomScale = 6;scroll.delegate = self
        view.addSubview(caption);view.addSubview(actions);view.addSubview(scroll);scroll.addSubview(canvas)
        canvas.frame = CGRect(x:0,y:0,width:1000,height:700);scroll.contentSize = canvas.bounds.size
        canvas.graph = graph;canvas.regionID = regionID;canvas.selectableNodes = true
        canvas.onNode = { [weak self] id in guard let self else { return };if self.selected.contains(id) { self.selected.remove(id) } else { self.selected.insert(id) };self.refresh() }
        NSLayoutConstraint.activate([caption.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:12),caption.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),caption.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),actions.topAnchor.constraint(equalTo:caption.bottomAnchor,constant:8),actions.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),actions.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),actions.heightAnchor.constraint(equalToConstant:42),scroll.topAnchor.constraint(equalTo:actions.bottomAnchor,constant:8),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor)])
        refresh()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews();if scroll.zoomScale == 1,scroll.bounds.width > 0,scroll.bounds.width < 1000 { scroll.zoomScale = max(0.4,scroll.bounds.width/1000) } }
    func viewForZooming(in scrollView:UIScrollView) -> UIView? { canvas }
    private func refresh() {
        canvas.selectedNodeIDs = selected;canvas.setNeedsDisplay()
        caption.text = "\(graph.region(regionID)?.name ?? "环境") · 已选 \(selected.count) 个节点\n点击路网节点选中／取消；蓝色圆点为已选，可双指缩放。\n导航起点选择这些节点时优先尝试此子环境。选择不代表已通过恢复测试，也不改变地图的实际范围。"
    }
    @objc private func useSuggested() { selected = suggested;refresh() }
    @objc private func selectEveryNode() { selected = Set(graph.bindings.filter { $0.region_id == regionID }.map(\.node_id));refresh() }
    @objc private func clear() { selected = [];refresh() }
    @objc private func cancel() { dismiss(animated:true) }
    @objc private func finish() {
        let ids = selected.sorted(),completion = done
        if navigationController?.viewControllers.first === self { dismiss(animated:true) { completion(ids) } }
        else { navigationController?.popViewController(animated:true);completion(ids) }
    }
}

// MARK: - LiDAR map preview (stage 1C, read-only)

/// Everything the 2D preview draws. Built from a snapshot so opening the page never touches
/// the live capture state; the AR session keeps running underneath.
struct LiDARDistributionData {
    enum Source { case liveCapture, savedMap }
    var title: String
    var source: Source
    /// Runtime-resolution points; sampled further for drawing.
    var points: [ProbePoint]
    var nodes: [LiDARRouteNode]
    var edges: [LiDARRouteEdge]
    var connectFrom: String?
    /// nil for saved maps without stored block statistics: shown as unknown, never guessed.
    var budget: LiDARBudgetSnapshot?
    /// Compass reference cells (map coordinates); nil when the map has none.
    var magnetic: LiDARMagnetic.Reference? = nil
    static func saved(_ map: LiDARNavigationMap, points: [ProbePoint]) -> LiDARDistributionData {
        LiDARDistributionData(title:map.name,source:.savedMap,points:points,nodes:map.nodes,edges:map.edges,connectFrom:nil,budget:nil)
    }
}

final class LiDARDistributionController: UIViewController, UIScrollViewDelegate {
    private let data: LiDARDistributionData
    private let layers = UISegmentedControl(items:["点云 + 路网","区域预算","磁场覆盖","全部"])
    private let caption = UILabel(),scroll = UIScrollView(),canvas = LiDARDistributionCanvas()
    init(data: LiDARDistributionData) { self.data = data;super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();title = "分布图";view.backgroundColor = .systemBackground
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title:"关闭",style:.done,target:self,action:#selector(close))
        }
        let fit = UIBarButtonItem(title:"适配全图",style:.plain,target:self,action:#selector(fitAll))
        let zoomIn = UIBarButtonItem(image:UIImage(systemName:"plus.magnifyingglass"),style:.plain,target:self,action:#selector(zoomIn))
        let zoomOut = UIBarButtonItem(image:UIImage(systemName:"minus.magnifyingglass"),style:.plain,target:self,action:#selector(zoomOut))
        zoomIn.accessibilityLabel = "放大";zoomOut.accessibilityLabel = "缩小"
        navigationItem.rightBarButtonItems = [fit,zoomIn,zoomOut]
        layers.selectedSegmentIndex = data.budget == nil ? 0 : 3
        layers.setEnabled(data.budget != nil,forSegmentAt:1)
        layers.addTarget(self,action:#selector(changeLayer),for:.valueChanged)
        caption.numberOfLines = 0;caption.font = .systemFont(ofSize:13);caption.textColor = .secondaryLabel
        scroll.minimumZoomScale = 0.3;scroll.maximumZoomScale = 8;scroll.delegate = self;scroll.backgroundColor = .secondarySystemBackground
        for v in [layers,caption,scroll] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v) }
        scroll.addSubview(canvas)
        canvas.data = data;canvas.frame = CGRect(origin:.zero,size:canvas.preferredSize);scroll.contentSize = canvas.bounds.size
        canvas.onTap = { [weak self] title,message in self?.campusMessage(title,message) }
        NSLayoutConstraint.activate([
            layers.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:12),
            layers.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),layers.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),
            caption.topAnchor.constraint(equalTo:layers.bottomAnchor,constant:10),
            caption.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),caption.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),
            scroll.topAnchor.constraint(equalTo:caption.bottomAnchor,constant:10),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor)])
        changeLayer()
    }
    private var fitted = false
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !fitted,scroll.bounds.width > 0,canvas.bounds.width > 0 { fitted = true;fitAll() }
        centerContent()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }
    /// Keeps a canvas smaller than the viewport centered instead of pinned to the top-left.
    private func centerContent() {
        let size = scroll.bounds.size,content = scroll.contentSize
        scroll.contentInset = UIEdgeInsets(top:max(0,(size.height-content.height)/2),left:max(0,(size.width-content.width)/2),
                                           bottom:0,right:0)
    }
    @objc private func fitAll() {
        let s = min(scroll.bounds.width/canvas.bounds.width,scroll.bounds.height/canvas.bounds.height)
        scroll.minimumZoomScale = min(0.3,s);scroll.setZoomScale(max(scroll.minimumZoomScale,min(scroll.maximumZoomScale,s)),animated:true)
    }
    @objc private func zoomIn() { scroll.setZoomScale(min(scroll.maximumZoomScale,scroll.zoomScale*1.6),animated:true) }
    @objc private func zoomOut() { scroll.setZoomScale(max(scroll.minimumZoomScale,scroll.zoomScale/1.6),animated:true) }
    @objc private func close() { dismiss(animated:true) }
    @objc private func changeLayer() {
        let i = layers.selectedSegmentIndex
        canvas.showPoints = i != 1;canvas.showBlocks = (i == 1 || i == 3) && data.budget != nil;canvas.showMagnetic = i == 2 || i == 3;canvas.setNeedsDisplay()
        let source = data.source == .liveCapture ? "当前采集 · 未保存快照" : "已保存地图"
        let named = data.nodes.filter { !$0.name.hasPrefix("节点") }.count
        var text = "\(data.title) · \(source)\n\(data.points.count) 个运行点（显示时再抽样）· \(data.nodes.count) 个节点（\(named) 个已命名）· \(data.edges.count) 条连线"
        if let b = data.budget {
            let count = { (s: String) in b.blocks.filter { $0.status == s }.count }
            text += "\n2 米块：填充中 \(count("filling")) · 已满 \(count("full")) · 有拒收 \(count("refusing")) · 疑似偏移 \(count("suspect"))；体素 \(b.voxels)/\(b.global_cap)"
            text += "\n颜色表示预算用量和诊断，不代表扫描完整或可以定位；没有方块的地方是未观察。"
        } else {
            text += "\n区域预算：未知（这张地图没有保存块统计，不从运行点云猜测）。"
        }
        if let m = data.magnetic {
            let global = m.global().map { String(format:"全图一致（%.0f°）",$0.mean_deg) } ?? "各处不一致，仅用局部"
            text += "\n磁场参照：\(m.cells.count) 格（每格 \(Int(m.cell_m)) 米）· \(global)。圆点：绿 ≤5° 分散，黄 ≤10°，橙更散；没有圆点的地方没有参照。"
        } else { text += "\n磁场参照：无（这张地图没有磁场记录）。" }
        text += "\n俯视，所有高度叠加：灰色地面，蓝→黄为 0.3–2.6 米的墙和物体，浅色为更高的天花板。双指或右上角按钮缩放，点节点或方块查看详情。"
        caption.text = text
    }
}

final class LiDARDistributionCanvas: UIView {
    var data: LiDARDistributionData? { didSet { prepare() } }
    var showPoints = true,showBlocks = true,showMagnetic = true
    var onTap: ((String,String) -> Void)?
    private var pixelsPerMeter: CGFloat = 40
    private let margin: CGFloat = 40
    private var minX = 0.0,minZ = 0.0,width = 10.0,depth = 10.0,floorY: Double?
    private var drawn = [ProbePoint]()
    var preferredSize: CGSize { CGSize(width:CGFloat(width)*pixelsPerMeter+2*margin,height:CGFloat(depth)*pixelsPerMeter+2*margin) }
    override init(frame: CGRect) {
        super.init(frame:frame);backgroundColor = .systemBackground
        addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tap(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private func prepare() {
        guard let data else { return }
        drawn = LiDARSampling.sample(data.points,limit:20_000)
        let xs = drawn.map(\.x)+data.nodes.map(\.position.x),zs = drawn.map(\.z)+data.nodes.map(\.position.z)
        minX = (xs.min() ?? 0)-0.5;minZ = (zs.min() ?? 0)-0.5
        width = max(2,(xs.max() ?? 1)+0.5-minX);depth = max(2,(zs.max() ?? 1)+0.5-minZ)
        // Cap the canvas so very large maps stay drawable; zooming covers the rest.
        pixelsPerMeter = min(40,CGFloat(6_000/max(width,depth)))
        floorY = data.budget?.floor_y ?? (drawn.isEmpty ? nil : LiDARSampling.floorHeight(drawn))
        isAccessibilityElement = false
        accessibilityElements = data.nodes.map { n -> UIAccessibilityElement in
            let element = LiDARNodeAccessibilityElement(accessibilityContainer:self)
            let s = screen(n.position.x,n.position.z)
            element.accessibilityFrameInContainerSpace = CGRect(x:s.x-14,y:s.y-14,width:28,height:28)
            element.accessibilityLabel = "\(n.name)，\(n.resolvedKind.title)\(n.id == data.connectFrom ? "，当前连线起点" : "")"
            element.accessibilityTraits = .button
            element.activate = { [weak self] in self?.showNode(n) }
            return element
        }
        setNeedsDisplay()
    }
    private func showNode(_ n: LiDARRouteNode) {
        guard let data else { return }
        let degree = data.edges.filter { $0.from == n.id || $0.to == n.id }.count
        onTap?(n.name,String(format:"类型：%@\n位置 X %.2f · Z %.2f 米\n连线 %d 条%@",n.resolvedKind.title,n.position.x,n.position.z,degree,n.id == data.connectFrom ? "\n当前连线起点" : ""))
    }
    private func screen(_ x: Double,_ z: Double) -> CGPoint {
        CGPoint(x:margin+CGFloat(x-minX)*pixelsPerMeter,y:margin+CGFloat(z-minZ)*pixelsPerMeter)
    }
    private func world(_ p: CGPoint) -> (Double,Double) {
        (Double((p.x-margin)/pixelsPerMeter)+minX,Double((p.y-margin)/pixelsPerMeter)+minZ)
    }
    private func blockColor(_ status: String) -> UIColor {
        switch status {
        case "full": return UIColor.systemGreen.withAlphaComponent(0.22)
        case "refusing": return UIColor.systemOrange.withAlphaComponent(0.30)
        case "suspect": return UIColor.systemRed.withAlphaComponent(0.35)
        default: return UIColor.systemBlue.withAlphaComponent(0.10)
        }
    }
    private func nodeColor(_ kind: CampusNodeKind) -> UIColor {
        switch kind { case .junction: return .systemPurple;case .room: return .systemRed;case .stair: return .systemBrown;case .elevator: return .systemIndigo;case .exit: return .systemGreen;case .waypoint: return .systemTeal }
    }
    override func draw(_ rect: CGRect) {
        guard let data,let ctx = UIGraphicsGetCurrentContext() else { return }
        if showBlocks,let b = data.budget {
            let side = CGFloat(b.block_m)*pixelsPerMeter
            for block in b.blocks {
                let o = screen(Double(block.bx)*b.block_m,Double(block.bz)*b.block_m),r = CGRect(x:o.x,y:o.y,width:side,height:side)
                guard r.intersects(rect) else { continue }
                ctx.setFillColor(blockColor(block.status).cgColor);ctx.fill(r)
                ctx.setStrokeColor(UIColor.separator.cgColor);ctx.setLineWidth(0.5);ctx.stroke(r)
            }
        }
        if showPoints {
            for p in drawn {
                let s = screen(p.x,p.z)
                guard rect.insetBy(dx:-2,dy:-2).contains(s) else { continue }
                if let f = floorY,p.y < f+0.30 { ctx.setFillColor(UIColor.systemGray4.cgColor) }
                else if let f = floorY,p.y > f+2.6 { ctx.setFillColor(UIColor.systemOrange.withAlphaComponent(0.18).cgColor) }
                else {
                    let h = CGFloat(max(0,min(1,((p.y-(floorY ?? p.y-1))-0.3)/2.3)))
                    ctx.setFillColor(UIColor(hue:0.62-0.5*h,saturation:0.85,brightness:0.8,alpha:1).cgColor)
                }
                ctx.fill(CGRect(x:s.x-1,y:s.y-1,width:2,height:2))
            }
        }
        if showMagnetic,let m = data.magnetic {
            let r = CGFloat(m.cell_m)*pixelsPerMeter*0.45
            for cell in m.cells {
                let c = screen(cell.x,cell.z),box = CGRect(x:c.x-r,y:c.y-r,width:2*r,height:2*r)
                guard box.intersects(rect) else { continue }
                let color:UIColor = cell.offset.spread_deg <= 5 ? .systemGreen : cell.offset.spread_deg <= 10 ? .systemYellow : .systemOrange
                ctx.setFillColor(color.withAlphaComponent(0.28).cgColor);ctx.fillEllipse(in:box)
                ctx.setStrokeColor(color.cgColor);ctx.setLineWidth(1.5);ctx.strokeEllipse(in:box)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues:data.nodes.map { ($0.id,$0) })
        ctx.setStrokeColor(UIColor.systemRed.cgColor);ctx.setLineWidth(3)
        for e in data.edges { if let a = byID[e.from],let b = byID[e.to] {
            ctx.move(to:screen(a.position.x,a.position.z));ctx.addLine(to:screen(b.position.x,b.position.z))
        } }
        ctx.strokePath()
        let font = UIFont.systemFont(ofSize:12,weight:.semibold)
        for n in data.nodes {
            let s = screen(n.position.x,n.position.z)
            if n.id == data.connectFrom {
                ctx.setStrokeColor(UIColor.systemYellow.cgColor);ctx.setLineWidth(3);ctx.strokeEllipse(in:CGRect(x:s.x-11,y:s.y-11,width:22,height:22))
            }
            ctx.setFillColor(nodeColor(n.resolvedKind).cgColor);ctx.fillEllipse(in:CGRect(x:s.x-6,y:s.y-6,width:12,height:12))
            (n.name as NSString).draw(at:CGPoint(x:s.x+8,y:s.y-8),withAttributes:[.font:font,.foregroundColor:UIColor.label])
        }
        // 1 m and 5 m scale bar.
        let base = CGPoint(x:margin,y:bounds.height-margin/2)
        ctx.setStrokeColor(UIColor.label.cgColor);ctx.setLineWidth(2)
        ctx.move(to:base);ctx.addLine(to:CGPoint(x:base.x+5*pixelsPerMeter,y:base.y));ctx.strokePath()
        ("5 米" as NSString).draw(at:CGPoint(x:base.x,y:base.y-16),withAttributes:[.font:UIFont.systemFont(ofSize:11),.foregroundColor:UIColor.label])
    }
    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard let data else { return }
        let p = g.location(in:self)
        if let n = data.nodes.min(by: { hypot(screen($0.position.x,$0.position.z).x-p.x,screen($0.position.x,$0.position.z).y-p.y) < hypot(screen($1.position.x,$1.position.z).x-p.x,screen($1.position.x,$1.position.z).y-p.y) }),
           hypot(screen(n.position.x,n.position.z).x-p.x,screen(n.position.x,n.position.z).y-p.y) < 22 {
            showNode(n);return
        }
        if showMagnetic,let m = data.magnetic,let cell = m.cells.min(by: { hypot(screen($0.x,$0.z).x-p.x,screen($0.x,$0.z).y-p.y) < hypot(screen($1.x,$1.z).x-p.x,screen($1.x,$1.z).y-p.y) }),
           hypot(screen(cell.x,cell.z).x-p.x,screen(cell.x,cell.z).y-p.y) < CGFloat(m.cell_m)*pixelsPerMeter*0.45 {
            onTap?("磁场参照格",String(format:"偏差均值 %.1f°\n分散 %.1f°（90%% 在 %.1f° 内）\n读数 %d 个\n\n这是建图时指南针与相机方向的差，用于排除方向错误的候选。",cell.offset.mean_deg,cell.offset.spread_deg,cell.offset.p90_deg,cell.offset.count))
            return
        }
        guard showBlocks,let b = data.budget else { return }
        let (x,z) = world(p),bx = Int(floor(x/b.block_m)),bz = Int(floor(z/b.block_m))
        guard let block = b.blocks.first(where: { $0.bx == bx && $0.bz == bz }) else {
            onTap?("未观察","这个 2 米块没有采集记录。可能没扫到，也可能是玻璃、反光或超出深度范围。");return
        }
        let names = ["filling":"填充中","full":"已满","refusing":"有拒收","suspect":"疑似偏移"]
        onTap?("2 米块 \(names[block.status] ?? block.status)","体素 \(block.voxels)（地面 \(block.floor_voxels) · 结构 \(block.structure_voxels)）\n拒收 \(block.refused) 次\n\n这是预算用量，不代表扫描完整或一定能定位。")
    }
}

private final class LiDARNodeAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?();return activate != nil }
}
