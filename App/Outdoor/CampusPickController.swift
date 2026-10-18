import UIKit

/// Picks on the campus map instead of typing ids: the outdoor building an indoor map belongs to,
/// where a building's door is (a pin, tap or drag; zoom in for precision), or a door's access path
/// (taps add bends; a tap near a campus path snaps onto it and completes the path). Nothing is
/// saved here; the caller stores the choice.
final class CampusPickController: UIViewController {
    enum Mode {
        case building(currentOSM:String?)
        case door(buildingOSM:String?,current:OutdoorCoordinate?)
        case accessPath(door:OutdoorCoordinate,doorName:String,buildingOSM:String?,existing:[OutdoorCoordinate]?)
    }
    var onBuilding:((OutdoorBuilding) -> Void)?
    var onDoor:((OutdoorCoordinate) -> Void)?
    /// Door first, last point on the path network.
    var onAccessPath:(([OutdoorCoordinate]) -> Void)?
    private var draft:[OutdoorCoordinate] = [],draftComplete = false
    private let secondary = UIButton(type:.system)
    private let snapM = 12.0
    private let mode:Mode,campus:OutdoorCampus
    private let mapView = OutdoorCampusMapView(),hint = PaddedLabel(),closeButton = UIButton(type:.system)
    private let card = UIView(),cardTitle = UILabel(),cardDetail = UILabel(),confirm = UIButton(type:.system)
    private var cardTop:NSLayoutConstraint?
    private var pickedBuilding:OutdoorBuilding?,pickedPoint:OutdoorCoordinate?

    init(campus:OutdoorCampus,mode:Mode) { self.campus = campus;self.mode = mode;super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = WayfindingPalette.ground
        navigationController?.setNavigationBarHidden(true,animated:false)
        mapView.setCampus(campus)
        hint.font = .systemFont(ofSize:15,weight:.semibold);hint.textColor = WayfindingPalette.ink;hint.backgroundColor = .white
        hint.layer.cornerRadius = 18;hint.clipsToBounds = true;hint.numberOfLines = 2
        Style.round(closeButton,symbol:"xmark",label:"取消");closeButton.addTarget(self,action:#selector(cancel),for:.touchUpInside)
        card.backgroundColor = .white;card.layer.cornerRadius = 28;card.layer.cornerCurve = .continuous;card.layer.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner]
        card.layer.shadowColor = WayfindingPalette.ink.cgColor;card.layer.shadowOpacity = 0.12;card.layer.shadowRadius = 18;card.layer.shadowOffset = CGSize(width:0,height:-6)
        cardTitle.font = .systemFont(ofSize:22,weight:.heavy);cardTitle.textColor = WayfindingPalette.ink;cardTitle.numberOfLines = 2
        cardDetail.font = .systemFont(ofSize:13);cardDetail.textColor = WayfindingPalette.secondary;cardDetail.numberOfLines = 2
        var c = UIButton.Configuration.filled();c.cornerStyle = .capsule;c.baseBackgroundColor = WayfindingPalette.route;c.baseForegroundColor = .white
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:17,weight:.bold);return a }
        confirm.configuration = c;confirm.addTarget(self,action:#selector(done),for:.touchUpInside)
        var sc = UIButton.Configuration.filled();sc.cornerStyle = .capsule;sc.baseBackgroundColor = UIColor(white:0.94,alpha:1);sc.baseForegroundColor = WayfindingPalette.ink
        sc.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0;a.font = .systemFont(ofSize:16,weight:.bold);return a }
        secondary.configuration = sc;secondary.addTarget(self,action:#selector(undo),for:.touchUpInside);secondary.isHidden = true
        secondary.heightAnchor.constraint(equalToConstant:48).isActive = true
        let column = UIStackView(arrangedSubviews:[cardTitle,cardDetail,confirm,secondary]);column.axis = .vertical;column.spacing = 8;column.setCustomSpacing(16,after:cardDetail)
        column.translatesAutoresizingMaskIntoConstraints = false;card.addSubview(column)
        for v in [mapView,hint,closeButton,card] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v) }
        let top = card.topAnchor.constraint(equalTo:view.bottomAnchor);cardTop = top
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo:view.leadingAnchor),mapView.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo:view.topAnchor),mapView.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),closeButton.topAnchor.constraint(equalTo:g.topAnchor,constant:10),
            hint.leadingAnchor.constraint(equalTo:closeButton.trailingAnchor,constant:10),hint.trailingAnchor.constraint(lessThanOrEqualTo:view.trailingAnchor,constant:-16),
            hint.centerYAnchor.constraint(equalTo:closeButton.centerYAnchor),hint.heightAnchor.constraint(greaterThanOrEqualToConstant:44),
            card.leadingAnchor.constraint(equalTo:view.leadingAnchor),card.trailingAnchor.constraint(equalTo:view.trailingAnchor),top,
            column.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:20),column.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-20),
            column.topAnchor.constraint(equalTo:card.topAnchor,constant:22),column.bottomAnchor.constraint(equalTo:card.safeAreaLayoutGuide.bottomAnchor,constant:-12),
            confirm.heightAnchor.constraint(equalToConstant:54)
        ])
        switch mode {
        case .building(let current):
            hint.text = "点选这张室内地图所在的楼"
            mapView.onBuildingTapped = { [weak self] b in self?.pick(building:b) }
            if let current,let b = campus.building(id:current) { mapView.highlightedBuildingID = b.id;pick(building:b,reveal:true) }
        case .accessPath(let door,let name,let osm,let existing):
            hint.text = "点路网完成引路，点空白处加转折"
            mapView.highlightedBuildingID = osm;mapView.doorMarkers = [(name,door)];mapView.accessPathsHighlighted = true
            draft = existing ?? [door];draftComplete = (existing?.count ?? 0) >= 2
            mapView.onPointTapped = { [weak self] p in self?.addPathPoint(p) }
            updatePathCard()
            if let osm { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.mapView.reveal(buildingID:osm,bottomInset:-(self.cardTop?.constant ?? 0)+40) } }
        case .door(let osm,let current):
            hint.text = "点选或拖动图钉到这扇门的位置"
            mapView.highlightedBuildingID = osm;mapView.markerDraggable = true
            mapView.onMarkerMoved = { [weak self] p in self?.pick(door:p) }
            mapView.onPointTapped = { [weak self] p in self?.pick(door:p) }
            if let current { pick(door:current) }
            // Zoom to the building (after layout) so the door can be placed precisely.
            if let osm { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.mapView.reveal(buildingID:osm,bottomInset:-(self.cardTop?.constant ?? 0)+40) } }
        }
    }
    private func pick(building b:OutdoorBuilding,reveal:Bool = true) {
        guard !b.name.isEmpty else { return }
        pickedBuilding = b;mapView.highlightedBuildingID = b.id
        cardTitle.text = b.fullName;cardDetail.text = "将这张室内地图所在的楼栋绑定到它。之后在校园地图上点这栋楼即可看到已建图的楼层。"
        confirm.configuration?.title = "绑定到这栋楼"
        showCard()
        if reveal { mapView.reveal(buildingID:b.id,bottomInset:-(cardTop?.constant ?? 0)) }
    }
    private func pick(door p:OutdoorCoordinate) {
        pickedPoint = p;mapView.marker = p
        cardTitle.text = "门的位置";cardDetail.text = String(format:"%.6f, %.6f · 可拖动图钉或点选调整",p.latitude,p.longitude)
        confirm.configuration?.title = "使用这个位置"
        showCard()
    }
    /// Nearest point on the campus path network within `snapM`.
    private func snap(_ p:OutdoorCoordinate) -> (point:OutdoorCoordinate,distance:Double)? {
        let g = campus.graph
        return g.edges.map { e in campus.frame.project(p,from:g.nodes[e.from],to:g.nodes[e.to]) }
            .filter { $0.distanceM <= snapM }.min { $0.distanceM < $1.distanceM }.map { ($0.point,$0.distanceM) }
    }
    private func addPathPoint(_ p:OutdoorCoordinate) {
        if draftComplete { draft.removeLast();draftComplete = false }
        if let s = snap(p) { draft.append(s.point);draftComplete = true;UIImpactFeedbackGenerator(style:.light).impactOccurred() }
        else { draft.append(p);UISelectionFeedbackGenerator().selectionChanged() }
        updatePathCard()
    }
    @objc private func undo() {
        guard draft.count > 1 else { return }
        draft.removeLast();draftComplete = false;updatePathCard()
    }
    private func updatePathCard() {
        mapView.accessPaths = [draft]
        let length = zip(draft,draft.dropFirst()).reduce(0.0) { $0+campus.frame.distance($1.0,$1.1) }
        cardTitle.text = "门的引路"
        cardDetail.text = draftComplete ? String(format:"已接到路网 · 全长约 %.0f 米。可继续点选调整终点。",length)
                                        : draft.count > 1 ? String(format:"已画 %.0f 米 · 点路网上的位置完成",length) : "从门出发：点路网上要接入的位置。中途需要拐弯就先点转折处。"
        confirm.configuration?.title = "保存这条引路";confirm.isEnabled = draftComplete
        secondary.configuration?.title = "撤销上一个点";secondary.isHidden = false;secondary.isEnabled = draft.count > 1
        showCard()
    }
    private func showCard() {
        view.layoutIfNeeded()
        let h = card.systemLayoutSizeFitting(CGSize(width:view.bounds.width,height:UIView.layoutFittingCompressedSize.height),
                                              withHorizontalFittingPriority:.required,verticalFittingPriority:.fittingSizeLevel).height
        cardTop?.constant = -h
        UIView.animate(withDuration:UIAccessibility.isReduceMotionEnabled ? 0 : 0.5,delay:0,usingSpringWithDamping:0.86,initialSpringVelocity:0.2,options:[.beginFromCurrentState]) { self.view.layoutIfNeeded() }
    }
    @objc private func done() {
        if case .accessPath = mode { if draftComplete { onAccessPath?(draft) };dismiss(animated:true);return }
        if let b = pickedBuilding { onBuilding?(b) } else if let p = pickedPoint { onDoor?(p) }
        dismiss(animated:true)
    }
    @objc private func cancel() { dismiss(animated:true) }
}
