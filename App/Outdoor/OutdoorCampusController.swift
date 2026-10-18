import UIKit

/// Opaque stable destination identity belongs to the coordinator/binding directory.
struct OutdoorTarget {
    var buildingID:String
    var title:String
    var destinationID:String? = nil
    var floorID:String? = nil
    /// nil permits dataset entrances; [] explicitly forbids guessing an entrance.
    var entrances:[OutdoorEntrance]? = nil
}
struct OutdoorFloorOption {
    var id:String
    var name:String
    var indoorBound:Bool
    var destinations:[OutdoorTarget]
}

/// Campus home: the full-screen map with a floating search pill, a location button and a building
/// card that springs up from the bottom (floors → rooms). Floors and rooms come only from the
/// coordinator's bound indoor maps; an unbound floor goes straight to navigating to the building.
final class OutdoorCampusController: UIViewController,UITextFieldDelegate {
    var floorsForBuilding:((OutdoorBuilding)->[OutdoorFloorOption]) = { _ in [] }
    var onTargetSelected:((OutdoorTarget)->Void)?
    var onTools:(()->Void)?
    /// Bound entrances of a building (shown at its edge while its card is open).
    var doorsForBuilding:((OutdoorBuilding)->[(name:String,coordinate:OutdoorCoordinate)]) = { _ in [] }
    /// Access paths of the building's bound doors (door first), drawn dashed while selected.
    var accessPathsForBuilding:((OutdoorBuilding)->[[OutdoorCoordinate]]) = { _ in [] }
    var automaticallyStartsLocation = true
    /// Picking where indoors a trip starts (planning out of a building): rooms choose a start
    /// point, the card's button restores on the whole floor; only floors with indoor maps show.
    enum StartChoice { case room(OutdoorTarget),floor(buildingOSM:String,floorID:String) }
    var pickStartMode = false
    var onStartPicked:((StartChoice)->Void)?
    /// The last indoor destination (pinned on its building and listed first in its card).
    var lastIndoor:(osm:String,title:String,target:OutdoorTarget)?
    /// The latest location fix, for the next screen to start from without waiting.
    var latestFix:OutdoorLocationService.Fix? { location.latest }
    private var campus:OutdoorCampus?
    private let mapView = OutdoorCampusMapView(),location = OutdoorLocationService()
    private let searchPill = UIView(),search = UITextField(),clearScope = UIButton(type:.system),menuButton = UIButton(type:.system)
    private let resultsCard = UIView(),resultsStack = UIStackView(),resultsScroll = UIScrollView()
    private let locateButton = UIButton(type:.system),notice = PaddedLabel()
    private let sheet = BuildingCard()
    private var sheetTop:NSLayoutConstraint?,resultsHeight:NSLayoutConstraint?
    private var searchBuilding:OutdoorBuilding?,openBuilding:OutdoorBuilding?
    private var noticeTimer:Timer?,centeredOnFirstFix = false

    init(campus:OutdoorCampus? = nil) { self.campus = campus;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = WayfindingPalette.ground
        mapView.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(mapView)
        Style.float(searchPill,radius:26)
        let glass = UIImageView(image:UIImage(systemName:"magnifyingglass",withConfiguration:UIImage.SymbolConfiguration(pointSize:17,weight:.semibold)))
        glass.tintColor = WayfindingPalette.ink
        search.placeholder = "搜索楼栋或教室";search.font = .systemFont(ofSize:17);search.textColor = WayfindingPalette.ink
        search.returnKeyType = .search;search.clearButtonMode = .whileEditing;search.delegate = self
        search.addTarget(self,action:#selector(updateSearch),for:.editingChanged)
        clearScope.setImage(UIImage(systemName:"xmark.circle.fill"),for:.normal);clearScope.tintColor = WayfindingPalette.secondary
        clearScope.accessibilityLabel = "改为全校搜索";clearScope.isHidden = true;clearScope.addTarget(self,action:#selector(leaveBuildingSearchAction),for:.touchUpInside)
        let pillRow = UIStackView(arrangedSubviews:[glass,search,clearScope]);pillRow.spacing = 10;pillRow.alignment = .center
        glass.setContentHuggingPriority(.required,for:.horizontal);clearScope.setContentHuggingPriority(.required,for:.horizontal)
        pillRow.translatesAutoresizingMaskIntoConstraints = false;searchPill.addSubview(pillRow)
        Style.round(menuButton,symbol:"line.3.horizontal",label:"菜单");menuButton.addTarget(self,action:#selector(tools),for:.touchUpInside)
        Style.round(locateButton,symbol:"location.fill",label:"回到我的位置",tint:WayfindingPalette.route);locateButton.addTarget(self,action:#selector(locate),for:.touchUpInside)
        Style.float(resultsCard,radius:22);resultsCard.alpha = 0;resultsCard.isHidden = true
        resultsStack.axis = .vertical;resultsStack.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false;resultsScroll.addSubview(resultsStack);resultsCard.addSubview(resultsScroll)
        resultsScroll.layer.cornerRadius = 22;resultsScroll.clipsToBounds = true
        notice.font = .systemFont(ofSize:14,weight:.medium);notice.textColor = WayfindingPalette.ink;notice.backgroundColor = .white
        notice.layer.cornerRadius = 16;notice.clipsToBounds = true;notice.alpha = 0;notice.numberOfLines = 2
        sheet.onClose = { [weak self] in self?.closeBuilding() }
        sheet.onFloor = { [weak self] f in self?.pickFloor(f) }
        sheet.onTarget = { [weak self] t in self?.choose(t) }
        sheet.onWholeFloor = { [weak self] floorID in
            guard let self,let b = self.openBuilding else { return }
            self.closeBuilding();self.onStartPicked?(.floor(buildingOSM:b.id,floorID:floorID))
        }
        for v in [searchPill,menuButton,locateButton,resultsCard,notice,sheet] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v) }
        let top = sheet.topAnchor.constraint(equalTo:view.bottomAnchor);sheetTop = top
        let rh = resultsCard.heightAnchor.constraint(equalToConstant:58);resultsHeight = rh
        let g = view.safeAreaLayoutGuide
        let locateAboveSheet = locateButton.bottomAnchor.constraint(equalTo:sheet.topAnchor,constant:-16);locateAboveSheet.priority = .defaultHigh
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo:view.leadingAnchor),mapView.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo:view.topAnchor),mapView.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            searchPill.topAnchor.constraint(equalTo:g.topAnchor,constant:10),searchPill.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),
            searchPill.heightAnchor.constraint(equalToConstant:52),searchPill.trailingAnchor.constraint(equalTo:menuButton.leadingAnchor,constant:-10),
            menuButton.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),menuButton.centerYAnchor.constraint(equalTo:searchPill.centerYAnchor),
            pillRow.leadingAnchor.constraint(equalTo:searchPill.leadingAnchor,constant:18),pillRow.trailingAnchor.constraint(equalTo:searchPill.trailingAnchor,constant:-14),
            pillRow.topAnchor.constraint(equalTo:searchPill.topAnchor),pillRow.bottomAnchor.constraint(equalTo:searchPill.bottomAnchor),
            resultsCard.topAnchor.constraint(equalTo:searchPill.bottomAnchor,constant:8),resultsCard.leadingAnchor.constraint(equalTo:searchPill.leadingAnchor),
            resultsCard.trailingAnchor.constraint(equalTo:menuButton.trailingAnchor),rh,
            resultsScroll.leadingAnchor.constraint(equalTo:resultsCard.leadingAnchor),resultsScroll.trailingAnchor.constraint(equalTo:resultsCard.trailingAnchor),
            resultsScroll.topAnchor.constraint(equalTo:resultsCard.topAnchor),resultsScroll.bottomAnchor.constraint(equalTo:resultsCard.bottomAnchor),
            resultsStack.leadingAnchor.constraint(equalTo:resultsScroll.contentLayoutGuide.leadingAnchor),resultsStack.trailingAnchor.constraint(equalTo:resultsScroll.contentLayoutGuide.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo:resultsScroll.contentLayoutGuide.topAnchor),resultsStack.bottomAnchor.constraint(equalTo:resultsScroll.contentLayoutGuide.bottomAnchor),
            resultsStack.widthAnchor.constraint(equalTo:resultsScroll.frameLayoutGuide.widthAnchor),
            notice.topAnchor.constraint(equalTo:searchPill.bottomAnchor,constant:10),notice.leadingAnchor.constraint(equalTo:searchPill.leadingAnchor),
            notice.trailingAnchor.constraint(lessThanOrEqualTo:view.trailingAnchor,constant:-16),
            locateButton.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),
            locateAboveSheet,locateButton.bottomAnchor.constraint(lessThanOrEqualTo:g.bottomAnchor,constant:-24),
            sheet.leadingAnchor.constraint(equalTo:view.leadingAnchor),sheet.trailingAnchor.constraint(equalTo:view.trailingAnchor),top
        ])
        sheet.addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(dragSheet(_:))))
        mapView.onBuildingTapped = { [weak self] in self?.open($0) }
        location.onFix = { [weak self] fix in
            guard let self else { return }
            self.mapView.userCoordinate = fix.coordinate;self.mapView.accuracyM = fix.accuracyM
            // The first usable fix on campus brings the map to it once; later fixes leave the camera alone.
            if !self.centeredOnFirstFix,fix.accuracyM <= 60,self.mapView.contains(fix.coordinate) { self.centeredOnFirstFix = true;self.mapView.recenter() }
        }
        location.onHeading = { [weak self] in self?.mapView.headingDegrees = $0 }
        location.onStatus = { [weak self] s in self?.showNotice(s.map { [$0.title,$0.detail].compactMap { $0 }.joined(separator:" · ") }) }
        if let campus { mapView.setCampus(campus) } else { load() }
        if pickStartMode {
            search.placeholder = "选择你在楼内的位置"
            if let last = lastIndoor,let b = campus?.building(id:last.osm) { mapView.marker = b.centroid;mapView.highlightedBuildingID = b.id }
            showNotice(lastIndoor.map { "上次目的地：\($0.title)（已在地图上标出）" } ?? "点你所在的楼，选择楼层和教室")
        }
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);navigationController?.setNavigationBarHidden(true,animated:animated) }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated);if automaticallyStartsLocation { location.start() } }
    override func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated);location.stop()
        if navigationController?.viewControllers.contains(self) != true { navigationController?.setNavigationBarHidden(false,animated:animated) }
    }
    private func load() {
        guard let campus = LiDARTripCoordinator.bundledCampus() else { showNotice("校园地图资源缺失，请重新安装应用");return }
        self.campus = campus;mapView.setCampus(campus)
    }
    private func showNotice(_ text:String?) {
        noticeTimer?.invalidate()
        guard let text,!text.isEmpty,resultsCard.isHidden else { UIView.animate(withDuration:0.2) { self.notice.alpha = 0 };return }
        notice.text = text
        UIView.animate(withDuration:0.25) { self.notice.alpha = 1 }
        noticeTimer = Timer.scheduledTimer(withTimeInterval:6,repeats:false) { [weak self] _ in UIView.animate(withDuration:0.3) { self?.notice.alpha = 0 } }
    }

    // MARK: actions
    @objc private func locate() {
        location.start()
        // First tap follows the location; tapping again while following turns the map with the phone.
        if mapView.followUser && mapView.userCoordinate != nil { mapView.headingUp.toggle() } else { mapView.headingUp = false;mapView.recenter() }
        if mapView.userCoordinate == nil { showNotice("正在获取你的位置…") }
        Style.setSymbol(locateButton,mapView.headingUp ? "location.north.line.fill" : "location.fill")
    }
    @objc private func tools() {
        if let onTools { onTools();return }
        let menu = UIAlertController(title:nil,message:nil,preferredStyle:.actionSheet)
        menu.addAction(UIAlertAction(title:"查看完整校园",style:.default) { [weak self] _ in self?.mapView.fit() })
        menu.addAction(UIAlertAction(title:mapView.headingUp ? "地图正北朝上" : "地图随我转动",style:.default) { [weak self] _ in
            guard let self else { return };self.mapView.headingUp.toggle();Style.setSymbol(self.locateButton,self.mapView.headingUp ? "location.north.line.fill" : "location.fill")
        })
        if navigationController?.viewControllers.first !== self {
            menu.addAction(UIAlertAction(title:"返回首页",style:.default) { [weak self] _ in self?.navigationController?.popViewController(animated:true) })
        }
        menu.addAction(UIAlertAction(title:"取消",style:.cancel))
        menu.popoverPresentationController?.sourceView = menuButton;menu.popoverPresentationController?.sourceRect = menuButton.bounds
        present(menu,animated:true)
    }

    // MARK: building card
    func open(_ b:OutdoorBuilding) {
        guard !b.name.isEmpty else { return }
        hideResults();view.endEditing(true)
        openBuilding = b;searchBuilding = b
        search.text = "";search.placeholder = "在\(b.fullName)内搜索教室";clearScope.isHidden = false
        sheet.pickStart = pickStartMode
        sheet.lastRow = pickStartMode ? lastIndoor.flatMap { last in last.osm == b.id ? ("上次目的地 · \(last.title)",{ [weak self] in self?.choose(last.target) }) : nil } : nil
        sheet.show(building:b,floors:pickStartMode ? floorsForBuilding(b).filter(\.indoorBound) : floorsForBuilding(b))
        settleSheet()
        mapView.highlightedBuildingID = b.id;mapView.doorMarkers = doorsForBuilding(b);mapView.accessPaths = accessPathsForBuilding(b)
        mapView.reveal(buildingID:b.id,bottomInset:-(sheetTop?.constant ?? 0))
    }
    /// Springs the card to its content height (at most 62% of the screen).
    private func settleSheet() {
        view.layoutIfNeeded()
        let height = sheet.systemLayoutSizeFitting(CGSize(width:view.bounds.width,height:UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height
        sheetTop?.constant = -min(height,view.bounds.height*0.62)
        animate { self.view.layoutIfNeeded() }
    }
    private func closeBuilding() {
        openBuilding = nil;mapView.highlightedBuildingID = nil;mapView.doorMarkers = [];mapView.accessPaths = [];sheetTop?.constant = 0
        animate { self.view.layoutIfNeeded();self.sheet.transform = .identity }
        leaveBuildingSearch()
    }
    private func pickFloor(_ f:OutdoorFloorOption) {
        guard let b = openBuilding else { return }
        // No indoor map on this floor: navigate to the building itself.
        if !f.indoorBound { choose(.init(buildingID:b.id,title:b.fullName,floorID:f.id));return }
        UISelectionFeedbackGenerator().selectionChanged()
        sheet.select(floor:f.id);settleSheet()
    }
    @objc private func dragSheet(_ g:UIPanGestureRecognizer) {
        guard openBuilding != nil else { return }
        let dy = g.translation(in:view).y
        switch g.state {
        case .changed:sheet.transform = CGAffineTransform(translationX:0,y:dy > 0 ? dy : dy/4)
        case .ended,.cancelled:
            if dy > 90 || g.velocity(in:view).y > 700 { closeBuilding() } else { animate { self.sheet.transform = .identity } }
        default:break
        }
    }
    private func animate(_ changes:@escaping () -> Void) {
        UIView.animate(withDuration:UIAccessibility.isReduceMotionEnabled ? 0 : 0.5,delay:0,usingSpringWithDamping:0.86,initialSpringVelocity:0.2,
                       options:[.allowUserInteraction,.beginFromCurrentState],animations:changes)
    }

    // MARK: search
    @objc private func updateSearch() {
        let q = (search.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !q.isEmpty,let campus else { hideResults();return }
        var rows = [(String,String,() -> Void)]()
        for b in searchBuilding.map({ [$0] }) ?? campus.buildings where !b.name.isEmpty {
            for f in floorsForBuilding(b) where f.indoorBound {
                for t in f.destinations where t.title.localizedCaseInsensitiveContains(q) {
                    rows.append((t.title,"\(b.fullName) · \(f.name)",{ [weak self] in self?.choose(t) }))
                }
            }
        }
        if searchBuilding == nil {
            for b in campus.buildings where !b.name.isEmpty && (b.name.localizedCaseInsensitiveContains(q) || b.label.localizedCaseInsensitiveContains(q) || CampusShortNames.short(b.name).localizedCaseInsensitiveContains(q)) {
                rows.append((b.fullName,b.shortName.isEmpty || b.shortName == b.fullName ? "楼栋" : "楼栋 · \(b.shortName)",{ [weak self] in self?.open(b) }))
            }
        }
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if rows.isEmpty { resultsStack.addArrangedSubview(ResultRow(title:searchBuilding == nil ? "没有找到匹配的楼栋或教室" : "这栋楼里没有匹配的教室",detail:nil,action:nil)) }
        for (i,r) in rows.prefix(30).enumerated() { resultsStack.addArrangedSubview(ResultRow(title:r.0,detail:r.1,action:r.2,separator:i > 0)) }
        resultsHeight?.constant = min(CGFloat(max(1,min(rows.count,30)))*58,view.bounds.height*0.45)
        if resultsCard.isHidden {
            resultsCard.isHidden = false;resultsCard.transform = CGAffineTransform(translationX:0,y:-8)
            UIView.animate(withDuration:0.22) { self.resultsCard.alpha = 1;self.resultsCard.transform = .identity;self.notice.alpha = 0 }
        }
    }
    private func hideResults() {
        guard !resultsCard.isHidden else { return }
        UIView.animate(withDuration:0.18,animations:{ self.resultsCard.alpha = 0 }) { _ in self.resultsCard.isHidden = true }
    }
    private func choose(_ target:OutdoorTarget) {
        hideResults();search.text = "";view.endEditing(true)
        if openBuilding != nil { closeBuilding() }
        if pickStartMode {
            if target.destinationID != nil { onStartPicked?(.room(target)) }
            return
        }
        if let onTargetSelected { onTargetSelected(target) }
        else if let campus { navigationController?.pushViewController(OutdoorNavigationController(campus:campus,target:target,initialFix:location.latest),animated:true) }
    }
    @objc private func leaveBuildingSearchAction() { leaveBuildingSearch() }
    func leaveBuildingSearch() {
        searchBuilding = nil;search.placeholder = "搜索楼栋或教室";search.text = "";clearScope.isHidden = true;hideResults()
    }
    func textFieldShouldReturn(_ textField:UITextField) -> Bool { textField.resignFirstResponder();return true }
}

// MARK: - pieces

enum Style {
    static func float(_ v:UIView,radius:CGFloat) {
        v.backgroundColor = .white;v.layer.cornerRadius = radius;v.layer.cornerCurve = .continuous
        v.layer.shadowColor = WayfindingPalette.ink.cgColor;v.layer.shadowOpacity = 0.12;v.layer.shadowRadius = 14;v.layer.shadowOffset = CGSize(width:0,height:6)
    }
    static func round(_ b:UIButton,symbol:String,label:String,tint:UIColor = WayfindingPalette.ink,size:CGFloat = 52) {
        float(b,radius:size/2);setSymbol(b,symbol);b.tintColor = tint;b.accessibilityLabel = label
        b.widthAnchor.constraint(equalToConstant:size).isActive = true;b.heightAnchor.constraint(equalToConstant:size).isActive = true
    }
    static func setSymbol(_ b:UIButton,_ name:String) {
        b.setImage(UIImage(systemName:name,withConfiguration:UIImage.SymbolConfiguration(pointSize:19,weight:.semibold)),for:.normal)
    }
}

final class PaddedLabel:UILabel {
    override func drawText(in rect:CGRect) { super.drawText(in:rect.insetBy(dx:14,dy:7)) }
    override var intrinsicContentSize:CGSize { let s = super.intrinsicContentSize;return CGSize(width:s.width+28,height:s.height+14) }
}

/// One tappable list row: bold title, quiet detail on the right, hairline above.
final class ResultRow:UIControl {
    private let action:(() -> Void)?
    init(title:String,detail:String?,action:(() -> Void)?,separator:Bool = false,height:CGFloat = 58,inset:CGFloat = 18) {
        self.action = action;super.init(frame:.zero)
        let t = UILabel();t.text = title;t.font = .systemFont(ofSize:17,weight:.bold);t.textColor = action == nil ? WayfindingPalette.secondary : WayfindingPalette.ink
        let d = UILabel();d.text = detail;d.font = .systemFont(ofSize:13);d.textColor = WayfindingPalette.secondary;d.textAlignment = .right
        d.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);t.setContentHuggingPriority(.required,for:.horizontal)
        let row = UIStackView(arrangedSubviews:[t,d]);row.spacing = 12;row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false;addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo:leadingAnchor,constant:inset),row.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-inset),
                                     row.centerYAnchor.constraint(equalTo:centerYAnchor),heightAnchor.constraint(equalToConstant:height)])
        if separator {
            let line = UIView();line.backgroundColor = UIColor(white:0.93,alpha:1);line.translatesAutoresizingMaskIntoConstraints = false;addSubview(line)
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo:leadingAnchor,constant:inset),line.trailingAnchor.constraint(equalTo:trailingAnchor),
                                         line.topAnchor.constraint(equalTo:topAnchor),line.heightAnchor.constraint(equalToConstant:1)])
        }
        accessibilityLabel = [title,detail].compactMap { $0 }.joined(separator:"，");isAccessibilityElement = true
        accessibilityTraits = action == nil ? .staticText : .button
        addTarget(self,action:#selector(tap),for:.touchUpInside)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override var isHighlighted:Bool { didSet { UIView.animate(withDuration:0.12) { self.backgroundColor = self.isHighlighted && self.action != nil ? UIColor(white:0.95,alpha:1) : .clear } } }
    @objc private func tap() { action?() }
}

/// The building card: name, indoor status, floor chips, the selected floor's rooms, and
/// "navigate to this building".
private final class BuildingCard:UIView {
    var onClose:(() -> Void)?,onFloor:((OutdoorFloorOption) -> Void)?,onTarget:((OutdoorTarget) -> Void)?
    var onWholeFloor:((String) -> Void)?
    var pickStart = false
    var lastRow:(title:String,action:() -> Void)?
    private var selectedFloor:String?
    private let title = UILabel(),subtitle = UILabel(),chips = UIStackView(),chipScroll = UIScrollView(),rooms = UIStackView(),roomScroll = UIScrollView()
    private let toBuilding = UIButton(type:.system)
    private var floors:[OutdoorFloorOption] = [],building:OutdoorBuilding?
    private var roomsHeight:NSLayoutConstraint?
    override init(frame:CGRect) {
        super.init(frame:frame)
        backgroundColor = .white;layer.cornerRadius = 28;layer.cornerCurve = .continuous;layer.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner]
        layer.shadowColor = WayfindingPalette.ink.cgColor;layer.shadowOpacity = 0.12;layer.shadowRadius = 18;layer.shadowOffset = CGSize(width:0,height:-6)
        let grabber = UIView();grabber.backgroundColor = UIColor(white:0.84,alpha:1);grabber.layer.cornerRadius = 2.5;grabber.translatesAutoresizingMaskIntoConstraints = false
        let grabberRow = UIView();grabberRow.addSubview(grabber)
        title.font = .systemFont(ofSize:24,weight:.heavy);title.textColor = WayfindingPalette.ink;title.numberOfLines = 2
        subtitle.font = .systemFont(ofSize:13);subtitle.textColor = WayfindingPalette.secondary;subtitle.numberOfLines = 2
        let close = UIButton(type:.system);close.setImage(UIImage(systemName:"xmark",withConfiguration:UIImage.SymbolConfiguration(pointSize:13,weight:.bold)),for:.normal)
        close.tintColor = WayfindingPalette.ink;close.backgroundColor = UIColor(white:0.94,alpha:1);close.layer.cornerRadius = 18;close.accessibilityLabel = "关闭"
        close.addTarget(self,action:#selector(closeTap),for:.touchUpInside)
        let names = UIStackView(arrangedSubviews:[title,subtitle]);names.axis = .vertical;names.spacing = 4
        let head = UIStackView(arrangedSubviews:[names,close]);head.alignment = .top;head.spacing = 12
        chips.spacing = 8;chips.alignment = .center;chips.distribution = .fill;chips.translatesAutoresizingMaskIntoConstraints = false;chipScroll.showsHorizontalScrollIndicator = false;chipScroll.addSubview(chips)
        rooms.axis = .vertical;rooms.translatesAutoresizingMaskIntoConstraints = false;roomScroll.addSubview(rooms)
        var config = UIButton.Configuration.filled();config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:16,weight:.bold);return a }
        toBuilding.configuration = config;toBuilding.addTarget(self,action:#selector(buildingTap),for:.touchUpInside)
        let column = UIStackView(arrangedSubviews:[grabberRow,head,chipScroll,roomScroll,toBuilding]);column.axis = .vertical;column.spacing = 14
        column.setCustomSpacing(8,after:grabberRow)
        column.translatesAutoresizingMaskIntoConstraints = false;addSubview(column)
        let rh = roomScroll.heightAnchor.constraint(equalToConstant:0);roomsHeight = rh
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo:leadingAnchor,constant:20),column.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-20),
            column.topAnchor.constraint(equalTo:topAnchor,constant:10),column.bottomAnchor.constraint(equalTo:safeAreaLayoutGuide.bottomAnchor,constant:-12),
            grabber.heightAnchor.constraint(equalToConstant:5),grabber.widthAnchor.constraint(equalToConstant:40),
            grabber.centerXAnchor.constraint(equalTo:grabberRow.centerXAnchor),grabber.topAnchor.constraint(equalTo:grabberRow.topAnchor),grabber.bottomAnchor.constraint(equalTo:grabberRow.bottomAnchor),
            close.widthAnchor.constraint(equalToConstant:36),close.heightAnchor.constraint(equalToConstant:36),
            chipScroll.heightAnchor.constraint(equalToConstant:40),
            chips.leadingAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.leadingAnchor),chips.trailingAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.topAnchor),chips.bottomAnchor.constraint(equalTo:chipScroll.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo:chipScroll.frameLayoutGuide.heightAnchor),
            rooms.leadingAnchor.constraint(equalTo:roomScroll.contentLayoutGuide.leadingAnchor),rooms.trailingAnchor.constraint(equalTo:roomScroll.contentLayoutGuide.trailingAnchor),
            rooms.topAnchor.constraint(equalTo:roomScroll.contentLayoutGuide.topAnchor),rooms.bottomAnchor.constraint(equalTo:roomScroll.contentLayoutGuide.bottomAnchor),
            rooms.widthAnchor.constraint(equalTo:roomScroll.frameLayoutGuide.widthAnchor),rh,
            toBuilding.heightAnchor.constraint(equalToConstant:52)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    func show(building b:OutdoorBuilding,floors f:[OutdoorFloorOption]) {
        building = b;floors = f;title.text = b.fullName
        let bound = f.filter(\.indoorBound)
        subtitle.text = bound.isEmpty ? "尚未接入室内导航 · 将导航到楼门口" : "室内导航已接入 · \(bound.count) 层可选"
        chipScroll.isHidden = f.isEmpty
        var config = toBuilding.configuration;config?.title = pickStart ? "整层恢复（不指定教室）" : bound.isEmpty ? "导航到这栋楼" : "只导航到这栋楼"
        config?.baseBackgroundColor = bound.isEmpty && !pickStart ? WayfindingPalette.route : UIColor(red:0.933,green:0.953,blue:1,alpha:1)
        config?.baseForegroundColor = bound.isEmpty && !pickStart ? .white : WayfindingPalette.route;toBuilding.configuration = config
        toBuilding.isHidden = pickStart && bound.isEmpty
        if pickStart && bound.isEmpty { subtitle.text = "这栋楼还没有室内地图，无法从楼内出发" }
        select(floor:bound.first?.id)
    }
    func select(floor id:String?) {
        selectedFloor = id
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for f in floors {
            var c = UIButton.Configuration.filled();c.cornerStyle = .capsule;c.title = f.indoorBound ? f.name : "\(f.name) 未建图"
            let on = f.id == id
            c.baseBackgroundColor = on ? WayfindingPalette.ink : .white;c.baseForegroundColor = on ? .white : (f.indoorBound ? WayfindingPalette.ink : WayfindingPalette.secondary)
            c.background.strokeColor = on ? nil : UIColor(white:0.84,alpha:1);c.background.strokeWidth = on ? 0 : 1.5
            c.contentInsets = NSDirectionalEdgeInsets(top:0,leading:18,bottom:0,trailing:18)
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:15,weight:on ? .bold : .medium);return a }
            let b = UIButton(configuration:c,primaryAction:UIAction { [weak self] _ in self?.onFloor?(f) })
            b.accessibilityHint = f.indoorBound ? nil : "这层没有室内地图，将导航到楼门口"
            b.setContentHuggingPriority(.required,for:.horizontal);b.setContentCompressionResistancePriority(.required,for:.horizontal)
            b.heightAnchor.constraint(equalToConstant:40).isActive = true
            chips.addArrangedSubview(b)
        }
        rooms.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = floors.first { $0.id == id }?.destinations ?? []
        var count = 0
        if let last = lastRow { rooms.addArrangedSubview(ResultRow(title:last.title,detail:"从这里出发",action:last.action,separator:false,height:56,inset:0));count += 1 }
        for t in list { rooms.addArrangedSubview(ResultRow(title:t.title,detail:pickStart ? "我在这里" : nil,action:{ [weak self] in self?.onTarget?(t) },separator:count > 0,height:56,inset:0));count += 1 }
        roomScroll.isHidden = count == 0
        roomsHeight?.constant = min(CGFloat(count)*56,56*4.5)
    }
    @objc private func closeTap() { onClose?() }
    @objc private func buildingTap() {
        if pickStart { if let f = selectedFloor { onWholeFloor?(f) };return }
        if let b = building { onTarget?(.init(buildingID:b.id,title:b.fullName)) }
    }
}
