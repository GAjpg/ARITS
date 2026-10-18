import UIKit

private typealias ElevatorDeviceBinding = LiDARCampusBindings.ElevatorDevice

/// Edits hall-device bindings only. The caller owns the map-tool entry and cross-floor links.
final class ElevatorBindingController:UIViewController {
    var onChanged:(() -> Void)?
    private let buildingID:String,catalog:LiDARCampusCatalog,placements:[String:LiDARMapPlacement],links:[LiDARMapLink],root:URL
    private let content = UIStackView(),radio = ElevatorBLEService()
    private var bindings:LiDARCampusBindings?,loadError:String?,busy = false,preview = false
    private var loadToken = UUID(),backgroundObserver:NSObjectProtocol?
    private weak var editor:ElevatorDeviceBindingEditor?
    private struct Group { var id:String,floors:[LiDARCampusCatalog.Floor],connected:Set<String> }

    init(buildingID:String,catalog:LiDARCampusCatalog,placements:[String:LiDARMapPlacement],links:[LiDARMapLink],root:URL = LiDARLibrary.root) {
        self.buildingID = buildingID;self.catalog = catalog;self.placements = placements;self.links = links;self.root = root
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = WayfindingPalette.ground
        let back = UIButton(type:.system);Style.round(back,symbol:"chevron.left",label:"返回");back.addTarget(self,action:#selector(close),for:.touchUpInside)
        let heading = UILabel();heading.text = "电梯装置";heading.font = .systemFont(ofSize:24,weight:.heavy);heading.textColor = WayfindingPalette.ink
        let subtitle = Self.text(catalog.building(buildingID)?.name ?? "楼栋不存在",size:14)
        let title = UIStackView(arrangedSubviews:[heading,subtitle]);title.axis = .vertical;title.spacing = 4
        let header = UIStackView(arrangedSubviews:[back,title]);header.spacing = 12;header.alignment = .center
        let scroll = UIScrollView();scroll.alwaysBounceVertical = true
        content.axis = .vertical;content.spacing = 16
        for v in [header,scroll] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v) }
        content.translatesAutoresizingMaskIntoConstraints = false;scroll.addSubview(content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:16),header.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-16),header.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),
            scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:16),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            content.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:4),content.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),
            content.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:16),content.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-16),content.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-32)
        ])
        radio.onDiscovery = { [weak self] value in self?.editor?.updateDiscovery(value) }
        backgroundObserver = NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in self?.radio.stopDiscovery() }
        if preview { render() } else { reload() }
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);navigationController?.setNavigationBarHidden(true,animated:false) }
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true { radio.stopDiscovery() }
    }
    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }
    @objc private func close() { radio.stopDiscovery();if navigationController?.viewControllers.first === self { dismiss(animated:true) } else { navigationController?.popViewController(animated:true) } }
    private func reload() {
        let token = UUID();loadToken = token;busy = true;render()
        LiDARNavigationStore.queue.async { [weak self] in
            guard let self else { return };let result = Result { try LiDARCampusBindings.load(root:self.root) }
            DispatchQueue.main.async {
                guard self.loadToken == token else { return };self.busy = false
                switch result { case .success(let value):self.bindings = value;self.loadError = nil
                case .failure(let error):self.bindings = nil;self.loadError = error.localizedDescription }
                self.render()
            }
        }
    }
    private func groups() -> [Group] {
        guard let building = catalog.building(buildingID) else { return [] }
        var ids = [String:Set<String>]()
        for link in links where link.kind == .elevator {
            guard let group = link.group_id,!group.isEmpty,let a = placements[link.a.map_id],let b = placements[link.b.map_id],
                  a.building_id == buildingID,b.building_id == buildingID else { continue }
            ids[group,default:[]].formUnion([a.floor_id,b.floor_id])
        }
        let existing = bindings?.elevator_devices.filter { $0.building_id == buildingID } ?? []
        let all = Set(ids.keys).union(existing.map(\.group_id))
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { id in
            let connected = ids[id] ?? [],floorIDs = connected.union(existing.filter { $0.group_id == id }.map(\.floor_id))
            var floors = building.sortedFloors.filter { floorIDs.contains($0.id) }
            floors += floorIDs.filter { id in !building.floors.contains { $0.id == id } }.sorted().map { .init(name:"已移除楼层",id:$0) }
            return Group(id:id,floors:floors,connected:connected)
        }
    }
    private func render() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0);$0.removeFromSuperview() }
        content.addArrangedSubview(Self.text("为每层电梯口绑定对应装置。导航接近电梯时，可主动点击上行或下行按钮呼梯。",size:14))
        if busy && bindings == nil { content.addArrangedSubview(Self.card([Self.text("正在读取绑定…",size:16)]));return }
        if let loadError {
            let retry = ResultRow(title:"重新读取",detail:nil,action:{ [weak self] in self?.reload() })
            content.addArrangedSubview(Self.card([Self.text("绑定未能读取\n"+loadError,size:14),retry]));return
        }
        let groups = groups()
        if groups.isEmpty {
            // An elevator link that touches this building but whose other end is not filed here is not a missing link.
            let unfiled = links.contains { l in
                l.kind == .elevator && [l.a,l.b].contains { placements[$0.map_id]?.building_id == buildingID } && ![l.a,l.b].allSatisfy { placements[$0.map_id]?.building_id == buildingID }
            }
            content.addArrangedSubview(Self.card(unfiled
                ? [Self.text("电梯连接另一端未归类",size:22,weight:.heavy),Self.text("本楼的电梯连接有一端的地图还没有归类到这栋楼。请用“归类 / 修改楼栋、楼层和区域”把两端地图都放进本楼和各自楼层。",size:14)]
                : [Self.text("先建立电梯连接",size:22,weight:.heavy),Self.text("在地图工具“跨图连接”中，把本楼不同楼层的电梯口节点连起来，并选择是哪部电梯。",size:14)]));return
        }
        for (index,group) in groups.enumerated() {
            let name = UUID(uuidString:group.id) == nil ? group.id : "电梯 \(index+1)"
            let column = UIStackView();column.axis = .vertical;column.spacing = 0
            let title = Self.text(name,size:22,weight:.heavy)
            column.addArrangedSubview(Self.padded(title,top:18,bottom:10))
            if group.connected.isEmpty { column.addArrangedSubview(Self.padded(Self.text("连接已移除，可清理原有绑定",size:13),top:0,bottom:10)) }
            for floor in group.floors {
                let binding = bindings?.device(group:group.id,floor:floor.id)
                let detail = binding.map { $0.peripheral_name+" · "+Self.directions($0.directions) } ?? "未绑定 · 添加"
                let row = ResultRow(title:floor.name,detail:detail,action:busy ? nil : { [weak self] in self?.open(group:group,floor:floor,name:name) },separator:true)
                column.addArrangedSubview(row)
                if floor.level == nil { column.addArrangedSubview(Self.padded(Self.text("楼层号未设置，暂不能呼梯",size:13),top:0,bottom:10)) }
            }
            let card = UIView();Style.float(card,radius:22);column.translatesAutoresizingMaskIntoConstraints = false;card.addSubview(column)
            NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:card.leadingAnchor),column.trailingAnchor.constraint(equalTo:card.trailingAnchor),column.topAnchor.constraint(equalTo:card.topAnchor),column.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-6)])
            content.addArrangedSubview(card)
        }
    }
    private func open(group:Group,floor:LiDARCampusCatalog.Floor,name:String) {
        guard bindings != nil,!busy else { return }
        let existing = bindings?.device(group:group.id,floor:floor.id)
        let page = ElevatorDeviceBindingEditor(name:name,floor:floor,existing:existing,canBind:group.connected.contains(floor.id) && catalog.building(buildingID)?.floors.contains(where: { $0.id == floor.id }) == true)
        editor = page
        page.onScan = { [weak self] in
            guard let self else { return }
            if self.preview { self.seedDiscovery(page);return }
            if self.radio.discoveryState.phase == .scanning { self.radio.stopDiscovery() } else { self.radio.startDiscovery() }
        }
        page.onFinish = { [weak self] in
            guard let self else { return };self.radio.stopDiscovery()
            if !self.preview && !self.busy { self.reload() }
        }
        page.onSave = { [weak self,weak page] name,directions in
            guard let self else { return }
            let value = ElevatorDeviceBinding(groupID:group.id,buildingID:self.buildingID,floorID:floor.id,peripheralName:name,directions:directions,id:existing?.id ?? UUID().uuidString)
            self.persist(group:group.id,floor:floor.id,expected:existing,value:value,editor:page)
        }
        page.onDelete = { [weak self,weak page] in self?.persist(group:group.id,floor:floor.id,expected:existing,value:nil,editor:page) }
#if targetEnvironment(macCatalyst)
        page.modalPresentationStyle = .fullScreen
#else
        page.modalPresentationStyle = .pageSheet;page.sheetPresentationController?.detents = [.large()];page.sheetPresentationController?.prefersGrabberVisible = true
#endif
        present(page,animated:!preview)
    }
    /// Re-read inside the shared storage queue and change just one pair. Never overwrite another editor's changes.
    private func persist(group:String,floor:String,expected:ElevatorDeviceBinding?,value:ElevatorDeviceBinding?,editor:ElevatorDeviceBindingEditor?) {
        guard !preview else { editor?.showError("仅预览，不会修改绑定");return }
        guard !busy else { return };busy = true;editor?.setBusy(true)
        LiDARNavigationStore.queue.async { [weak self,weak editor] in
            guard let self else { return }
            let result = Result { () -> LiDARCampusBindings in
                var latest = try LiDARCampusBindings.load(root:self.root)
                guard latest.device(group:group,floor:floor) == expected else { throw LiDARScanError.invalid("这层绑定已被其他页面修改，请关闭后重新打开。") }
                latest.elevator_devices.removeAll { $0.group_id == group && $0.floor_id == floor }
                if let value { latest.elevator_devices.append(value) }
                try latest.save(root:self.root);return latest
            }
            DispatchQueue.main.async {
                self.busy = false;editor?.setBusy(false)
                switch result {
                case .success(let saved):self.bindings = saved;self.radio.stopDiscovery();editor?.dismiss(animated:true);self.render();self.onChanged?()
                case .failure(let error):editor?.showError(error.localizedDescription)
                }
            }
        }
    }
    fileprivate static func directions(_ list:[ElevatorDeviceBinding.Direction]) -> String {
        [list.contains(.up) ? "上行" : nil,list.contains(.down) ? "下行" : nil].compactMap { $0 }.joined(separator:" / ")
    }
    fileprivate static func text(_ value:String,size:CGFloat,weight:UIFont.Weight = .regular) -> UILabel {
        let l = UILabel();l.text = value;l.numberOfLines = 0;l.font = .systemFont(ofSize:size,weight:weight);l.textColor = weight == .heavy || weight == .bold ? WayfindingPalette.ink : WayfindingPalette.secondary;return l
    }
    fileprivate static func padded(_ view:UIView,top:CGFloat,bottom:CGFloat) -> UIView {
        let box = UIView();view.translatesAutoresizingMaskIntoConstraints = false;box.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:18),view.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-18),view.topAnchor.constraint(equalTo:box.topAnchor,constant:top),view.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-bottom)]);return box
    }
    fileprivate static func card(_ views:[UIView]) -> UIView {
        let c = UIView();Style.float(c,radius:22);let s = UIStackView(arrangedSubviews:views);s.axis = .vertical;s.spacing = 12;s.translatesAutoresizingMaskIntoConstraints = false;c.addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:c.leadingAnchor,constant:18),s.trailingAnchor.constraint(equalTo:c.trailingAnchor,constant:-18),s.topAnchor.constraint(equalTo:c.topAnchor,constant:18),s.bottomAnchor.constraint(equalTo:c.bottomAnchor,constant:-18)]);return c
    }
#if DEBUG
    private func seedDiscovery(_ page:ElevatorDeviceBindingEditor) {
        page.updateDiscovery(.init(phase:.scanning,devices:[.init(id:UUID(),name:"ELEV-2F",rssi:-52,lastSeenAt:ProcessInfo.processInfo.systemUptime),.init(id:UUID(),name:"ELEV-3F",rssi:-65,lastSeenAt:ProcessInfo.processInfo.systemUptime)],reason:nil))
    }
    static func snapshot(showEditor:Bool) -> ElevatorBindingController {
        let floors = [LiDARCampusCatalog.Floor(name:"1F",level:1,id:"f1"),.init(name:"2F",level:2,id:"f2"),.init(name:"3F",level:3,id:"f3")]
        let building = LiDARCampusCatalog.Building(name:"教学中心",floors:floors,id:"b1")
        let placements = Dictionary(uniqueKeysWithValues:floors.map { f in ("map-"+f.id,try! LiDARMapPlacement(mapID:"map-"+f.id,building:building,floor:f,region:"大厅")) })
        let links = [LiDARMapLink(kind:.elevator,a:.init(map:"map-f1",node:"a"),b:.init(map:"map-f2",node:"b"),groupID:"西侧电梯"),.init(kind:.elevator,a:.init(map:"map-f2",node:"b"),b:.init(map:"map-f3",node:"c"),groupID:"西侧电梯")]
        let page = ElevatorBindingController(buildingID:building.id,catalog:.init(buildings:[building]),placements:placements,links:links)
        page.preview = true;var sample = LiDARCampusBindings()
        sample.elevator_devices = [.init(groupID:"西侧电梯",buildingID:"b1",floorID:"f1",peripheralName:"ELEV-1F",directions:[.up]),.init(groupID:"西侧电梯",buildingID:"b1",floorID:"f2",peripheralName:"ELEV-2F",directions:[.up,.down])]
        page.bindings = sample
        if showEditor { DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { page.open(group:page.groups()[0],floor:floors[1],name:"西侧电梯");if let editor = page.editor { page.seedDiscovery(editor) } } }
        return page
    }
#else
    private func seedDiscovery(_ page:ElevatorDeviceBindingEditor) {}
#endif
}

private final class ElevatorDeviceBindingEditor:UIViewController {
    var onScan:(() -> Void)?,onFinish:(() -> Void)?,onSave:((String,[ElevatorDeviceBinding.Direction]) -> Void)?,onDelete:(() -> Void)?
    private let elevatorName:String,floor:LiDARCampusCatalog.Floor,existing:ElevatorDeviceBinding?,canBind:Bool
    private let nameField = UITextField(),up = UIButton(type:.system),down = UIButton(type:.system),scan = UIButton(type:.system),save = UIButton(type:.system),remove = UIButton(type:.system),cancel = UIButton(type:.system)
    private let devices = UIStackView(),scanStatus = UILabel()
    private var directions:Set<ElevatorDeviceBinding.Direction>,writing = false
    private var discoverySignature:String?
    init(name:String,floor:LiDARCampusCatalog.Floor,existing:ElevatorDeviceBinding?,canBind:Bool) {
        elevatorName = name;self.floor = floor;self.existing = existing;self.canBind = canBind;directions = Set(existing?.directions ?? [.up,.down]);super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = WayfindingPalette.ground
        let title = ElevatorBindingController.text("\(floor.name) · \(elevatorName)",size:24,weight:.heavy)
        let hint = ElevatorBindingController.text("绑定这一层电梯口的装置，选择实际可按的方向。",size:14)
        nameField.text = existing?.peripheral_name;nameField.placeholder = "例如 ELEV-2F";nameField.font = .systemFont(ofSize:17,weight:.bold);nameField.textColor = WayfindingPalette.ink
        nameField.autocapitalizationType = .none;nameField.autocorrectionType = .no;nameField.keyboardType = .asciiCapable;nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done;nameField.addTarget(self,action:#selector(endTyping),for:.editingDidEndOnExit)
        nameField.heightAnchor.constraint(equalToConstant:48).isActive = true
        let fieldCard = ElevatorBindingController.card([ElevatorBindingController.text("装置广播名",size:13),nameField])
        for (button,text) in [(up,"上行"),(down,"下行")] {
            button.configuration = .filled();button.configuration?.title = text;button.configuration?.cornerStyle = .capsule
            button.configuration?.titleTextAttributesTransformer = .init { var value = $0;value.font = .systemFont(ofSize:17,weight:.bold);return value }
            button.heightAnchor.constraint(equalToConstant:44).isActive = true;button.addTarget(self,action:#selector(toggle(_:)),for:.touchUpInside)
        }
        let choices = UIStackView(arrangedSubviews:[up,down]);choices.distribution = .fillEqually;choices.spacing = 12
        let directionCard = ElevatorBindingController.card([ElevatorBindingController.text("可用方向",size:13),choices]);updateDirections()
        scan.configuration = .plain();scan.configuration?.title = "查找附近装置";scan.tintColor = WayfindingPalette.route;scan.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true
        scan.addTarget(self,action:#selector(scanNearby),for:.touchUpInside)
        scanStatus.numberOfLines = 0;scanStatus.font = .systemFont(ofSize:14);scanStatus.textColor = WayfindingPalette.secondary;scanStatus.text = "也可以直接填写装置广播名。查找不会呼叫电梯。"
        devices.axis = .vertical
        let nearby = ElevatorBindingController.card([scan,scanStatus,devices])
        var config = UIButton.Configuration.filled();config.title = "保存绑定";config.baseBackgroundColor = WayfindingPalette.route;config.baseForegroundColor = .white;config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = .init { var value = $0;value.font = .systemFont(ofSize:17,weight:.bold);return value }
        save.configuration = config;save.heightAnchor.constraint(equalToConstant:52).isActive = true;save.addTarget(self,action:#selector(saveBinding),for:.touchUpInside);save.isEnabled = canBind
        cancel.configuration = .plain();cancel.configuration?.title = "取消";cancel.tintColor = WayfindingPalette.ink;cancel.heightAnchor.constraint(equalToConstant:44).isActive = true;cancel.addTarget(self,action:#selector(cancelled),for:.touchUpInside)
        remove.configuration = .plain();remove.configuration?.title = "删除此层绑定";remove.tintColor = UIColor(red:159/255,green:29/255,blue:18/255,alpha:1);remove.heightAnchor.constraint(equalToConstant:44).isActive = true;remove.isHidden = existing == nil;remove.addTarget(self,action:#selector(deleteBinding),for:.touchUpInside)
        let column = UIStackView(arrangedSubviews:[title,hint,fieldCard,directionCard,nearby,remove]);column.axis = .vertical;column.spacing = 16
        if !canBind { hint.text = "这层的电梯连接已不存在，可删除旧绑定后重新建立连接。" }
        let scroll = UIScrollView();scroll.alwaysBounceVertical = true;scroll.keyboardDismissMode = .interactive
        let footer = UIView();footer.backgroundColor = WayfindingPalette.road;footer.layer.cornerRadius = 28;footer.layer.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner]
        footer.layer.shadowColor = WayfindingPalette.ink.cgColor;footer.layer.shadowOpacity = 0.12;footer.layer.shadowRadius = 18;footer.layer.shadowOffset = CGSize(width:0,height:-6)
        let actions = UIStackView(arrangedSubviews:[cancel,save]);actions.spacing = 12;actions.distribution = .fillEqually
        for v in [scroll,footer] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v) }
        actions.translatesAutoresizingMaskIntoConstraints = false;footer.addSubview(actions)
        column.translatesAutoresizingMaskIntoConstraints = false;scroll.addSubview(column)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo:view.leadingAnchor),footer.trailingAnchor.constraint(equalTo:view.trailingAnchor),footer.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor),
            actions.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:20),actions.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-20),actions.topAnchor.constraint(equalTo:footer.topAnchor,constant:20),actions.bottomAnchor.constraint(equalTo:footer.bottomAnchor,constant:-16),
            column.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:16),column.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-16),column.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:24),column.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),column.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-32)])
    }
    override func viewDidDisappear(_ animated:Bool) { super.viewDidDisappear(animated);onFinish?() }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func updateDirections() {
        for (button,direction) in [(up,ElevatorDeviceBinding.Direction.up),(down,.down)] {
            let selected = directions.contains(direction)
            button.configuration?.baseBackgroundColor = selected ? WayfindingPalette.ink : WayfindingPalette.road
            button.configuration?.baseForegroundColor = selected ? .white : WayfindingPalette.secondary
            button.configuration?.background.strokeColor = selected ? .clear : WayfindingPalette.buildingEdge
            button.configuration?.background.strokeWidth = 1
            button.accessibilityTraits = selected ? [.button,.selected] : [.button]
        }
    }
    @objc private func toggle(_ sender:UIButton) { let d:ElevatorDeviceBinding.Direction = sender === up ? .up : .down;if directions.contains(d) { directions.remove(d) } else { directions.insert(d) };updateDirections();UISelectionFeedbackGenerator().selectionChanged() }
    @objc private func scanNearby() { onScan?() }
    @objc private func cancelled() { dismiss(animated:true) }
    @objc private func endTyping() { nameField.resignFirstResponder() }
    @objc private func saveBinding() {
        let name = (nameField.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.utf8.count <= 160,ElevatorCallPlanning.wireFloor(advertisedName:name) != nil else { showError("请填写装置广播名，例如 ELEV-2F。它需要与装置实际广播的名称完全一致。");return }
        guard !directions.isEmpty else { showError("至少选择一个可用方向。");return }
        guard canBind,!writing else { return }
        onSave?(name,[.up,.down].filter { directions.contains($0) })
    }
    @objc private func deleteBinding() {
        let alert = UIAlertController(title:"删除这层的装置绑定？",message:"删除后，这层电梯口将不再提供呼梯按钮。其他楼层不受影响。",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"取消",style:.cancel));alert.addAction(UIAlertAction(title:"删除",style:.destructive) { [weak self] _ in self?.onDelete?() });present(alert,animated:true)
    }
    func setBusy(_ value:Bool) { writing = value;devices.isUserInteractionEnabled = !value;isModalInPresentation = value;for control in [nameField,up,down,scan,save,remove,cancel] as [UIControl] { control.isEnabled = !value };save.isEnabled = !value && canBind;save.configuration?.showsActivityIndicator = value }
    func showError(_ text:String) { let alert = UIAlertController(title:"暂未保存",message:text,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"知道了",style:.default));present(alert,animated:true) }
    func updateDiscovery(_ value:ElevatorBLEService.DiscoveryState) {
        guard isViewLoaded else { loadViewIfNeeded();updateDiscovery(value);return }
        let names = Dictionary(grouping:value.devices,by:\.name)
        let signature = String(describing:value.phase)+"|"+(value.reason ?? "")+"|"+names.keys.sorted().map { $0+":"+String(names[$0]!.count) }.joined(separator:"|")
        guard signature != discoverySignature else { return };discoverySignature = signature
        devices.arrangedSubviews.forEach { devices.removeArrangedSubview($0);$0.removeFromSuperview() }
        let scanning = value.phase == .scanning;scan.configuration?.title = scanning ? "停止查找" : "查找附近装置"
        switch value.phase {
        case .idle:scanStatus.text = "查找已停止，可填写广播名或重新查找。"
        case .scanning:scanStatus.text = value.devices.isEmpty ? "正在查找附近装置…请靠近这一层的电梯口。" : "点击名称填入。请确认装置属于当前楼层和这部电梯。"
        case .unavailable:
            switch value.reason {
            case "missing_bluetooth_usage_description":scanStatus.text = "当前版本尚未启用蓝牙查找，可先手动填写广播名。"
            case "bluetooth_powered_off":scanStatus.text = "请打开蓝牙，再查找附近装置。"
            case "bluetooth_unauthorized":scanStatus.text = "请在系统设置中允许蓝牙访问。"
            case "bluetooth_unsupported":scanStatus.text = "这台设备不支持蓝牙查找，可手动填写。"
            default:scanStatus.text = "蓝牙暂时不可用，可稍后重试或手动填写。"
            }
        }
        for (name,found) in names.sorted(by: { $0.key < $1.key }) where !name.isEmpty {
            let allowed = scanning && found.count == 1 && ElevatorCallPlanning.wireFloor(advertisedName:name) != nil && !writing
            devices.addArrangedSubview(ResultRow(title:name,detail:found.count > 1 ? "多台同名，请核对" : allowed ? "选用" : "名称不受支持",action:allowed ? { [weak self] in guard let self,!self.writing else { return };self.nameField.text = name;UISelectionFeedbackGenerator().selectionChanged() } : nil,separator:true,inset:0))
        }
    }
}
