import UIKit

/// Colours of the "quiet wayfinding" look shared by the campus map screens.
enum WayfindingPalette {
    static let ground = UIColor(red:0.933,green:0.945,blue:0.925,alpha:1)      // #EEF1EC
    static let green = UIColor(red:0.851,green:0.894,blue:0.827,alpha:1)       // #D9E4D3
    static let water = UIColor(red:0.812,green:0.878,blue:0.902,alpha:1)
    static let building = UIColor(red:0.863,green:0.882,blue:0.902,alpha:1)    // #DCE1E6
    static let buildingEdge = UIColor(red:0.800,green:0.824,blue:0.847,alpha:1)
    static let road = UIColor.white
    static let border = UIColor(red:0.616,green:0.749,blue:0.580,alpha:1)      // #9DBF94
    static let ink = UIColor(red:0.078,green:0.125,blue:0.106,alpha:1)         // #14201B
    static let secondary = UIColor(red:0.294,green:0.345,blue:0.384,alpha:1)   // #4B5862
    static let buildingLabel = UIColor(red:0.404,green:0.451,blue:0.486,alpha:1) // #67737C, building names on the map
    static let route = UIColor(red:0.114,green:0.306,blue:0.847,alpha:1)       // #1D4ED8
    static let routeDeep = UIColor(red:0.118,green:0.227,blue:0.541,alpha:1)   // #1E3A8A
    static let routePassed = UIColor(red:0.608,green:0.690,blue:0.902,alpha:1)
}

/// Short names shown when a building's full name does not fit: explicit names first, then rules.
enum CampusShortNames {
    private static let explicit:[String:String] = [
        "行政中心":"行政","教学中心":"教学","学生活动中心":"学活","会议中心":"会议","餐饮中心":"食堂",
        "创业与管理学院":"创管","生命科学与技术学院":"生命","生命医学与工程学院":"生医工",
        "学生科创中心":"H2","校园服务中心":"H1","博士公寓":"博士寓","物质科学与技术学院":"物质","信息科学与技术学院":"信息",
    ]
    private static let numerals:[Character:String] = ["一":"1","二":"2","三":"3","四":"4","五":"5","六":"6","七":"7","八":"8","九":"9","十":"10"]
    static func short(_ raw:String) -> String {
        var s = raw.replacingOccurrences(of:"上海科技大学",with:"").trimmingCharacters(in:.whitespaces)
        if s.hasPrefix("iHuman") { return "iHuman" }
        if s.contains("创意与艺术学院"),let side = ["南","北","西","东"].first(where: { s.contains("（\($0)楼）") }) {
            return s.hasPrefix("人文") ? "人文" : s.hasPrefix("数学") ? "数学" : "创艺\(side)"
        }
        // "三号学生公寓" → "宿舍3", "二号教授公寓" → "教授2".
        for (suffix,word) in [("号学生公寓","宿舍"),("号教授公寓","教授")] where s.hasSuffix(suffix) {
            let n = s.dropLast(suffix.count);return word+(n.count == 1 ? numerals[n.first!] ?? String(n) : String(n))
        }
        var number = ""
        if let r = s.range(of:#" #(\d+)$"#,options:.regularExpression) { number = String(s[r]).replacingOccurrences(of:" #",with:"");s.removeSubrange(r) }
        if let r = s.range(of:"（") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of:" / ") { s = String(s[..<r.lowerBound]) }
        let base = explicit[s] ?? (s.count <= 3 ? s : String(s.prefix(2)))
        return base+number
    }
}

/// Offline WGS-84 campus map drawn with Core Animation: geometry is built once in metre
/// coordinates and the camera only changes one layer cameraTransform, so panning and zooming stay at
/// display rate. Labels sit at each building's interior pole and are shown in full, as a short
/// name, or not at all — never crossing the building's outline. Pan has inertia; zoom, recentre
/// and the location dot animate.
final class OutdoorCampusMapView: UIView {
    var onBuildingTapped:((OutdoorBuilding)->Void)?
    var selectsBuildings = true
    var headingUp = false { didSet { kick() } }
    var headingDegrees:Double? { didSet { kick() } }
    var userCoordinate:OutdoorCoordinate? { didSet { userMoved() } }
    var accuracyM:Double? { didSet { kick() } }
    var route:OutdoorRoute? { didSet { rebuildRoute() } }
    var routeProgressM = 0.0 { didSet { rebuildRoute() } }
    var highlightedBuildingID:String? { didSet { rebuildHighlight() } }
    private(set) var followUser = false
    var twoFingerPan = false { didSet { panGesture?.minimumNumberOfTouches = twoFingerPan ? 2 : 1 } }
    /// When set, a tap reports the tapped coordinate instead of selecting a building.
    var onPointTapped:((OutdoorCoordinate)->Void)?
    /// Bound entrances shown at the building's edge while it is selected (name + position).
    var doorMarkers:[(name:String,coordinate:OutdoorCoordinate)] = [] { didSet { rebuildDoors() } }
    private var doorLayers:[(layer:CALayer,coordinate:OutdoorCoordinate)] = []
    /// A dropped pin (e.g. a door being placed).
    var marker:OutdoorCoordinate? { didSet { if !draggingMarker { dropMarker() } } }
    private let pin = CAShapeLayer()
    /// When true the pin can be dragged; the new position is reported on release.
    var markerDraggable = false
    var onMarkerMoved:((OutdoorCoordinate)->Void)?
    private var draggingMarker = false,dragOffset = CGPoint.zero
    /// Door access paths (door first), drawn dashed; `accessPathsHighlighted` uses the action colour.
    var accessPaths:[[OutdoorCoordinate]] = [] { didSet { rebuildAccessPaths() } }
    var accessPathsHighlighted = false { didSet { rebuildAccessPaths() } }
    private let accessCasing = CAShapeLayer(),accessLine = CAShapeLayer(),accessDots = CAShapeLayer()

    private struct Building { let data:OutdoorBuilding;let ring:[CGPoint];let path:CGPath;let area:CGFloat;let centroid:CGPoint;let pole:CGPoint;let full:String;let short:String;let rank:Int;let label:LabelLayer }
    /// A building name: text with a narrow white halo (pre-rendered), and a dot shown when the text
    /// sits outside the building.
    private final class LabelLayer:CALayer {
        let text = CALayer(),dot = CAShapeLayer()
        var key = ""
        override init() {
            super.init();addSublayer(dot);addSublayer(text);opacity = 0
            dot.path = CGPath(ellipseIn:CGRect(x:-3.5,y:-3.5,width:7,height:7),transform:nil)
            dot.fillColor = WayfindingPalette.secondary.cgColor;dot.strokeColor = UIColor.white.cgColor;dot.lineWidth = 1.5
        }
        override init(layer:Any) { super.init(layer:layer) }
        required init?(coder:NSCoder) { fatalError("init(coder:)") }
    }
    private var labelImages:[String:UIImage] = [:]
    /// Text with a white halo, cached per string and style.
    private func labelImage(_ text:String,highlighted:Bool) -> UIImage {
        let key = text+(highlighted ? "|h" : "|n")
        if let i = labelImages[key] { return i }
        let font = UIFont.systemFont(ofSize:highlighted ? 13 : 12,weight:highlighted ? .bold : .semibold)
        let color = highlighted ? WayfindingPalette.routeDeep : WayfindingPalette.buildingLabel
        let size = (text as NSString).size(withAttributes:[.font:font]),pad:CGFloat = 3
        let image = UIGraphicsImageRenderer(size:CGSize(width:ceil(size.width)+2*pad,height:ceil(size.height)+2*pad)).image { _ in
            let at = CGPoint(x:pad,y:pad)
            (text as NSString).draw(at:at,withAttributes:[.font:font,.foregroundColor:UIColor.white,.strokeColor:UIColor.white,.strokeWidth:9])
            (text as NSString).draw(at:at,withAttributes:[.font:font,.foregroundColor:color])
        }
        labelImages[key] = image;return image
    }
    /// Importance 1–5: the campus data's rank, else estimated from size and key landmarks.
    private static func rank(_ b:OutdoorBuilding,area:CGFloat) -> Int {
        if let r = b.rank { return max(1,min(5,r)) }
        let name = b.name
        if ["图书馆","教学中心","行政中心","学生活动中心","体育馆","会议中心","餐饮中心"].contains(where: { name.contains($0) }) { return 5 }
        return area > 9000 ? 4 : area > 3500 ? 3 : area > 1200 ? 2 : 1
    }
    private var campus:OutdoorCampus?
    private var buildings:[Building] = []
    private var localBounds = CGRect.zero
    // Layers: world (metres, one cameraTransform) and screen overlays (labels, location).
    private let world = CALayer(),greens = CAShapeLayer(),waters = CAShapeLayer(),majorRoads = CAShapeLayer(),minorRoads = CAShapeLayer()
    private let buildingFill = CAShapeLayer(),highlight = CAShapeLayer(),border = CAShapeLayer()
    private let routeCasing = CAShapeLayer(),routeLine = CAShapeLayer(),routePassed = CAShapeLayer(),door = CAShapeLayer()
    private let labelLayer = CALayer(),accuracyRing = CAShapeLayer(),userLayer = CALayer(),headingCone = CAShapeLayer()
    private let attribution = UILabel()
    // Camera.
    private var scale:CGFloat = 1,minimumScale:CGFloat = 1,focus = CGPoint.zero,angle:CGFloat = 0
    private var cameraAnimation:(from:(CGPoint,CGFloat),to:(CGPoint,CGFloat),start:CFTimeInterval,duration:CFTimeInterval)?
    private var velocity = CGPoint.zero
    private var previousSize = CGSize.zero,didFit = false
    // Location dot, eased between fixes.
    private var shownUser:CGPoint?,userFrom:CGPoint?,userTo:CGPoint?,userStart:CFTimeInterval = 0
    private var shownHeading:CGFloat?
    private var link:CADisplayLink?,lastTick:CFTimeInterval = 0,interacting = false
    private var panGesture:UIPanGestureRecognizer?
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled

    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = WayfindingPalette.ground;clipsToBounds = true
        accessibilityLabel = "校园地图，支持缩放和平移，点选楼栋"
        world.anchorPoint = .zero;world.bounds = CGRect(x:0,y:0,width:1,height:1);layer.addSublayer(world)
        for (l,color) in [(greens,WayfindingPalette.green),(waters,WayfindingPalette.water),(buildingFill,WayfindingPalette.building)] { l.fillColor = color.cgColor;l.strokeColor = nil }
        buildingFill.strokeColor = WayfindingPalette.buildingEdge.cgColor
        for l in [majorRoads,minorRoads,routeCasing,routeLine,routePassed] { l.fillColor = nil;l.lineCap = .round;l.lineJoin = .round }
        majorRoads.strokeColor = WayfindingPalette.road.cgColor;minorRoads.strokeColor = WayfindingPalette.road.cgColor
        border.fillColor = nil;border.strokeColor = WayfindingPalette.border.cgColor
        highlight.fillColor = WayfindingPalette.route.withAlphaComponent(0.16).cgColor;highlight.strokeColor = WayfindingPalette.route.cgColor;highlight.opacity = 0
        routeCasing.strokeColor = UIColor.white.cgColor;routeLine.strokeColor = WayfindingPalette.route.cgColor;routePassed.strokeColor = WayfindingPalette.routePassed.cgColor
        door.fillColor = UIColor.white.cgColor;door.strokeColor = WayfindingPalette.route.cgColor
        for l in [accessCasing,accessLine] { l.fillColor = nil;l.lineCap = .round;l.lineJoin = .round }
        accessCasing.strokeColor = UIColor.white.cgColor;accessDots.fillColor = UIColor.white.cgColor
        for l in [greens,waters,minorRoads,majorRoads,buildingFill,highlight,border,accessCasing,accessLine,routeCasing,routeLine,routePassed,door] { world.addSublayer(l) };world.addSublayer(accessDots)
        layer.addSublayer(labelLayer)
        let head = UIBezierPath(arcCenter:CGPoint(x:0,y:-26),radius:11,startAngle:0,endAngle:2 * .pi,clockwise:true)
        let stalk = UIBezierPath();stalk.move(to:CGPoint(x:-6,y:-18));stalk.addLine(to:CGPoint(x:0,y:0));stalk.addLine(to:CGPoint(x:6,y:-18));stalk.close()
        head.append(stalk);pin.path = head.cgPath;pin.fillColor = NavigationPalette.attention.cgColor;pin.strokeColor = UIColor.white.cgColor;pin.lineWidth = 2.5
        pin.shadowColor = UIColor.black.cgColor;pin.shadowOpacity = 0.25;pin.shadowRadius = 3;pin.shadowOffset = CGSize(width:0,height:2);pin.isHidden = true
        accuracyRing.fillColor = WayfindingPalette.route.withAlphaComponent(0.12).cgColor;accuracyRing.strokeColor = WayfindingPalette.route.withAlphaComponent(0.25).cgColor;accuracyRing.lineWidth = 1
        layer.addSublayer(accuracyRing)
        let cone = UIBezierPath();cone.move(to:.zero);cone.addArc(withCenter:.zero,radius:34,startAngle:-.pi/2-0.45,endAngle:-.pi/2+0.45,clockwise:true);cone.close()
        headingCone.path = cone.cgPath;headingCone.fillColor = WayfindingPalette.route.withAlphaComponent(0.22).cgColor
        let ring = CALayer();ring.bounds = CGRect(x:0,y:0,width:22,height:22);ring.cornerRadius = 11;ring.backgroundColor = UIColor.white.cgColor
        ring.shadowColor = UIColor.black.cgColor;ring.shadowOpacity = 0.18;ring.shadowRadius = 4;ring.shadowOffset = CGSize(width:0,height:2)
        let dot = CALayer();dot.bounds = CGRect(x:0,y:0,width:15,height:15);dot.cornerRadius = 7.5;dot.backgroundColor = WayfindingPalette.route.cgColor;dot.position = CGPoint(x:11,y:11)
        ring.addSublayer(dot);userLayer.addSublayer(headingCone);userLayer.addSublayer(ring);ring.position = .zero
        userLayer.isHidden = true;accuracyRing.isHidden = true;layer.addSublayer(userLayer)
        attribution.text = "© OpenStreetMap";attribution.font = .systemFont(ofSize:10);attribution.textColor = WayfindingPalette.secondary
        attribution.translatesAutoresizingMaskIntoConstraints = false;addSubview(attribution)
        NSLayoutConstraint.activate([attribution.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),attribution.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-6)])
        let pan = UIPanGestureRecognizer(target:self,action:#selector(pan(_:)));panGesture = pan;addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target:self,action:#selector(pinch(_:))))
        let tap = UITapGestureRecognizer(target:self,action:#selector(tap(_:)));addGestureRecognizer(tap)
        let double = UITapGestureRecognizer(target:self,action:#selector(doubleTap(_:)));double.numberOfTapsRequired = 2;addGestureRecognizer(double);tap.require(toFail:double)
        let twoFinger = UITapGestureRecognizer(target:self,action:#selector(zoomOutTap(_:)));twoFinger.numberOfTouchesRequired = 2;addGestureRecognizer(twoFinger)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func willMove(toWindow newWindow:UIWindow?) { super.willMove(toWindow:newWindow);if newWindow == nil { link?.invalidate();link = nil } }

    // MARK: data
    func setCampus(_ data:OutdoorCampus) {
        campus = data
        labelLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let scaleFactor = window?.screen.scale ?? UIScreen.main.scale
        let edited = data.buildings.contains { $0.rank != nil }
        buildings = data.buildings.map { b in
            let ring = b.ring.map(local),path = Self.polygon(ring),box = path.boundingBox
            // Edited campus data (from the workbench) is authoritative for full and short names;
            // the built-in short-name rules only fill in for the original OpenStreetMap data.
            let full = edited ? (b.name.isEmpty ? b.label : b.name) : b.label
            let short = edited ? (b.shortName.isEmpty ? full : b.shortName) : CampusShortNames.short(b.name.isEmpty ? b.label : b.name)
            let label = LabelLayer();label.contentsScale = scaleFactor;label.text.contentsScale = scaleFactor
            if !full.isEmpty { labelLayer.addSublayer(label) }
            let area = box.width*box.height
            return Building(data:b,ring:ring,path:path,area:area,centroid:Self.centroid(ring) ?? CGPoint(x:box.midX,y:box.midY),pole:Self.pole(ring,box:box),
                            full:full,short:short,rank:Self.rank(b,area:area),label:label)
        }.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.area > $1.area }
        let all = CGMutablePath();buildings.forEach { all.addPath($0.path) };buildingFill.path = all
        let green = CGMutablePath(),water = CGMutablePath()
        for a in data.areas {
            switch a.kind {
            case "water","basin","riverbank":water.addPath(Self.polygon(a.ring.map(local)))
            case "grass","forest","meadow","pitch","park","garden":green.addPath(Self.polygon(a.ring.map(local)))
            default:break
            }
        }
        greens.path = green;waters.path = water
        let major = CGMutablePath(),minor = CGMutablePath()
        for r in data.roads {
            let p = Self.polyline(r.points.map(local))
            if ["footway","path","steps","cycleway","pedestrian"].contains(r.kind) { minor.addPath(p) } else { major.addPath(p) }
        }
        majorRoads.path = major;minorRoads.path = minor
        let ring = data.campusRing.map(local);border.path = Self.polygon(ring);localBounds = border.path!.boundingBox
        didFit = false;rebuildRoute();rebuildHighlight();setNeedsLayout()
    }
    private func local(_ p:OutdoorCoordinate) -> CGPoint {
        guard let campus else { return .zero };let q = campus.frame.local(p);return CGPoint(x:q.east,y:-q.north)
    }
    private static func polygon(_ pts:[CGPoint]) -> CGPath { let p = CGMutablePath();if let f = pts.first { p.move(to:f);pts.dropFirst().forEach { p.addLine(to:$0) };p.closeSubpath() };return p }
    private static func polyline(_ pts:[CGPoint]) -> CGPath { let p = CGMutablePath();if let f = pts.first { p.move(to:f);pts.dropFirst().forEach { p.addLine(to:$0) } };return p }
    private static func inside(_ p:CGPoint,_ ring:[CGPoint]) -> Bool {
        var c = false,j = ring.count-1
        for i in ring.indices { let a = ring[i],b = ring[j];if (a.y > p.y) != (b.y > p.y),p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { c.toggle() };j = i }
        return c
    }
    private static func edgeDistance(_ p:CGPoint,_ ring:[CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude,j = ring.count-1
        for i in ring.indices {
            let a = ring[j],b = ring[i],dx = b.x-a.x,dy = b.y-a.y,l = dx*dx+dy*dy
            let t = l > 0 ? max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/l)) : 0
            best = min(best,hypot(p.x-(a.x+t*dx),p.y-(a.y+t*dy)));j = i
        }
        return best
    }
    /// Area centroid of a simple polygon (nil when degenerate).
    private static func centroid(_ r:[CGPoint]) -> CGPoint? {
        guard r.count >= 3 else { return nil }
        var a:CGFloat = 0,cx:CGFloat = 0,cy:CGFloat = 0,j = r.count-1
        for i in r.indices { let k = r[j].x*r[i].y-r[i].x*r[j].y;a += k;cx += (r[j].x+r[i].x)*k;cy += (r[j].y+r[i].y)*k;j = i }
        guard abs(a) > 1e-9 else { return nil };return CGPoint(x:cx/(3*a),y:cy/(3*a))
    }
    /// The interior point farthest from the outline (centroids of L-shaped buildings fall outside).
    private static func pole(_ ring:[CGPoint],box:CGRect) -> CGPoint {
        guard ring.count >= 3 else { return CGPoint(x:box.midX,y:box.midY) }
        var best = CGPoint(x:box.midX,y:box.midY),bestD = inside(best,ring) ? edgeDistance(best,ring) : -1
        var step = max(box.width,box.height)/16,origin = box
        for _ in 0..<3 {
            var y = origin.minY
            while y <= origin.maxY { var x = origin.minX
                while x <= origin.maxX { let p = CGPoint(x:x,y:y);if inside(p,ring) { let d = edgeDistance(p,ring);if d > bestD { bestD = d;best = p } };x += step }
                y += step }
            origin = CGRect(x:best.x-step,y:best.y-step,width:2*step,height:2*step);step /= 4
        }
        return best
    }

    // MARK: camera
    private var cameraTransform:CGAffineTransform {
        CGAffineTransform(translationX:bounds.midX,y:bounds.midY).rotated(by:angle).scaledBy(x:scale,y:scale).translatedBy(x:-focus.x,y:-focus.y)
    }
    private var targetAngle:CGFloat { headingUp ? -CGFloat(headingDegrees ?? 0) * .pi/180 : 0 }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0,bounds.height > 0,localBounds.width > 0 else { return }
        minimumScale = min(bounds.width*0.92/localBounds.width,bounds.height*0.85/localBounds.height)
        if !didFit { scale = minimumScale;focus = CGPoint(x:localBounds.midX,y:localBounds.midY);didFit = true }
        else if previousSize != bounds.size { scale = max(minimumScale,scale);clampCenter() }
        previousSize = bounds.size;render()
    }
    private var maximumScale:CGFloat { minimumScale*40 }
    func fit() { followUser = false;animateCamera(to:CGPoint(x:localBounds.midX,y:localBounds.midY),scale:minimumScale) }
    func center(on coordinate:OutdoorCoordinate) { animateCamera(to:local(coordinate),scale:scale) }
    func zoom(_ factor:CGFloat) { animateCamera(to:focus,scale:scale*factor) }
    @objc func recenter() {
        guard let p = userCoordinate else { fit();return }
        followUser = true;animateCamera(to:local(p),scale:max(scale,minimumScale*6))
    }
    /// Shows the whole route (and the person) between the top and bottom overlays.
    func frameRoute(top:CGFloat,bottom:CGFloat) {
        guard let route,route.points.count >= 2,bounds.width > 0 else { return }
        var box = Self.polyline(route.points.map(local)).boundingBox
        if let u = shownUser { box = box.union(CGRect(origin:u,size:.zero)) }
        let band = max(120,bounds.height-top-bottom),w = max(box.width,20),h = max(box.height,20)
        let s = max(minimumScale,min(maximumScale,min(bounds.width*0.8/w,band*0.8/h)))
        let v = CGPoint(x:0,y:(top+band/2-bounds.midY)/s).applying(CGAffineTransform(rotationAngle:-angle))
        followUser = false
        animateCamera(to:CGPoint(x:box.midX-v.x,y:box.midY-v.y),scale:s,duration:0.6)
    }
    /// Whether a coordinate lies on (or just around) the campus.
    func contains(_ c:OutdoorCoordinate) -> Bool { localBounds.insetBy(dx:-40,dy:-40).contains(local(c)) }
    /// Brings a building into the band above a bottom card, zooming in only as far as needed.
    func reveal(buildingID:String,bottomInset:CGFloat,topInset:CGFloat = 110) {
        guard let b = buildings.first(where: { $0.data.id == buildingID }),bounds.height > 0 else { return }
        let box = b.path.boundingBox,band = max(120,bounds.height-bottomInset-topInset)
        let wanted = min(bounds.width*0.55/max(box.width,1),band*0.55/max(box.height,1))
        let s = max(minimumScale,min(maximumScale,max(scale,min(wanted,minimumScale*12))))
        let target = topInset+band/2
        let v = CGPoint(x:0,y:(target-bounds.midY)/s).applying(CGAffineTransform(rotationAngle:-angle))
        followUser = false
        animateCamera(to:CGPoint(x:b.pole.x-v.x,y:b.pole.y-v.y),scale:s)
    }
    private func animateCamera(to c:CGPoint,scale s:CGFloat,duration:CFTimeInterval = 0.45) {
        velocity = .zero
        let target = (clamped(c),max(minimumScale,min(maximumScale,s)))
        if reduceMotion || window == nil { focus = target.0;scale = target.1;render();return }
        cameraAnimation = ((focus,scale),target,CACurrentMediaTime(),duration);kick()
    }
    private func clamped(_ c:CGPoint) -> CGPoint {
        guard !localBounds.isEmpty else { return c }
        let inset:CGFloat = 60
        return CGPoint(x:min(localBounds.maxX+inset,max(localBounds.minX-inset,c.x)),y:min(localBounds.maxY+inset,max(localBounds.minY-inset,c.y)))
    }
    private func clampCenter() { focus = clamped(focus) }

    // MARK: gestures
    @objc private func pan(_ g:UIPanGestureRecognizer) {
        if g.state == .began,markerDraggable,let m = marker {
            let tip = local(m).applying(cameraTransform),touch = g.location(in:self)
            if hypot(touch.x-tip.x,touch.y-(tip.y-18)) < 36 { draggingMarker = true;dragOffset = CGPoint(x:tip.x-touch.x,y:tip.y-touch.y);UISelectionFeedbackGenerator().selectionChanged() }
        }
        if draggingMarker {
            let p = g.location(in:self)
            let screen = CGPoint(x:p.x+dragOffset.x,y:p.y+dragOffset.y).applying(cameraTransform.inverted())
            if let campus { marker = campus.frame.coordinate(east:Double(screen.x),north:Double(-screen.y)) }
            pin.setAffineTransform(CGAffineTransform(scaleX:1.15,y:1.15));render()
            if g.state == .ended || g.state == .cancelled {
                draggingMarker = false;pin.setAffineTransform(.identity);g.setTranslation(.zero,in:self)
                UIImpactFeedbackGenerator(style:.light).impactOccurred();if let m = marker { onMarkerMoved?(m) }
            }
            return
        }
        switch g.state {
        case .began:cameraAnimation = nil;velocity = .zero;interacting = true;followUser = false
        case .changed:
            let d = g.translation(in:self);g.setTranslation(.zero,in:self);move(by:d);render()
        default:
            interacting = false
            if !reduceMotion { velocity = g.velocity(in:self) };kick()
        }
    }
    private func move(by screen:CGPoint) {
        let inv = CGAffineTransform(rotationAngle:angle).scaledBy(x:scale,y:scale).inverted(),d = screen.applying(inv)
        focus.x -= d.x;focus.y -= d.y;clampCenter()
    }
    @objc private func pinch(_ g:UIPinchGestureRecognizer) {
        if g.state == .began { cameraAnimation = nil;velocity = .zero;interacting = true;followUser = false }
        let touch = g.location(in:self),before = touch.applying(cameraTransform.inverted())
        scale = max(minimumScale,min(maximumScale,scale*g.scale));g.scale = 1
        let after = touch.applying(cameraTransform.inverted());focus.x += before.x-after.x;focus.y += before.y-after.y;clampCenter()
        if g.state == .ended || g.state == .cancelled { interacting = false }
        render()
    }
    @objc private func doubleTap(_ g:UITapGestureRecognizer) {
        let p = g.location(in:self).applying(cameraTransform.inverted());followUser = false
        animateCamera(to:CGPoint(x:focus.x+(p.x-focus.x)*0.5,y:focus.y+(p.y-focus.y)*0.5),scale:scale*2,duration:0.35)
    }
    @objc private func zoomOutTap(_ g:UITapGestureRecognizer) { animateCamera(to:focus,scale:scale/2,duration:0.35) }
    @objc private func tap(_ g:UITapGestureRecognizer) {
        let p = g.location(in:self).applying(cameraTransform.inverted())
        if let onPointTapped,let campus { onPointTapped(campus.frame.coordinate(east:Double(p.x),north:Double(-p.y)));return }
        guard selectsBuildings else { return }
        let hits = buildings.filter { $0.path.contains(p) }.sorted {
            if $0.data.name.isEmpty != $1.data.name.isEmpty { return !$0.data.name.isEmpty };return $0.area < $1.area
        }
        if let b = hits.first?.data { highlightedBuildingID = b.id;UISelectionFeedbackGenerator().selectionChanged();onBuildingTapped?(b) }
    }

    // MARK: frame loop (runs only while something moves)
    private func kick() {
        guard window != nil else { render();return }
        if link == nil { let l = CADisplayLink(target:self,selector:#selector(tick(_:)));l.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120);l.add(to:.main,forMode:.common);link = l;lastTick = CACurrentMediaTime() }
    }
    @objc private func tick(_ l:CADisplayLink) {
        let now = CACurrentMediaTime(),dt = min(0.05,now-lastTick);lastTick = now
        var busy = interacting
        if let a = cameraAnimation {
            let t = min(1,(now-a.start)/a.duration),e = CGFloat(1-pow(1-t,3))
            focus = CGPoint(x:a.from.0.x+(a.to.0.x-a.from.0.x)*e,y:a.from.0.y+(a.to.0.y-a.from.0.y)*e)
            scale = a.from.1*pow(a.to.1/a.from.1,e)
            if t >= 1 { cameraAnimation = nil } else { busy = true }
        } else if hypot(velocity.x,velocity.y) > 8 {
            move(by:CGPoint(x:velocity.x*dt,y:velocity.y*dt))
            let k = CGFloat(exp(-4.2*dt));velocity.x *= k;velocity.y *= k;busy = true
        } else { velocity = .zero }
        if let from = userFrom,let to = userTo {
            let t = min(1,(now-userStart)/0.8),e = CGFloat(t*t*(3-2*t))
            shownUser = CGPoint(x:from.x+(to.x-from.x)*e,y:from.y+(to.y-from.y)*e)
            if t >= 1 { userFrom = nil } else { busy = true }
        }
        if followUser,cameraAnimation == nil,!interacting,let u = shownUser { focus = u }
        let goal = targetAngle,diff = atan2(sin(goal-angle),cos(goal-angle))
        if abs(diff) > 0.002 { angle += diff*CGFloat(min(1,dt/0.12));busy = true } else { angle = goal }
        if let h = headingDegrees {
            let goalH = CGFloat(h) * .pi/180,cur = shownHeading ?? goalH,dh = atan2(sin(goalH-cur),cos(goalH-cur))
            shownHeading = abs(dh) > 0.002 ? cur+dh*CGFloat(min(1,dt/0.1)) : goalH;if abs(dh) > 0.002 { busy = true }
        } else { shownHeading = nil }
        render()
        if !busy { l.invalidate();link = nil }
    }
    private func userMoved() {
        guard let c = userCoordinate else { shownUser = nil;userFrom = nil;userTo = nil;render();return }
        let p = local(c)
        if let s = shownUser,hypot(p.x-s.x,p.y-s.y) < 60,!reduceMotion { userFrom = s;userTo = p;userStart = CACurrentMediaTime() }
        else { shownUser = p;userFrom = nil;userTo = p }
        kick()
    }

    // MARK: drawing
    private func render() {
        guard bounds.width > 0 else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        world.setAffineTransform(cameraTransform)
        // Screen-constant widths, growing a little as the map zooms in.
        let zoom = sqrt(max(1,scale/max(minimumScale,1e-6))),px = 1/scale
        majorRoads.lineWidth = min(14,3.2*zoom)*px;minorRoads.lineWidth = min(8,1.8*zoom)*px
        buildingFill.lineWidth = 0.8*px;border.lineWidth = 1.6*px;highlight.lineWidth = 2.5*px
        routeCasing.lineWidth = 11*px;routeLine.lineWidth = 7*px;routePassed.lineWidth = 7*px;door.lineWidth = 3.5*px
        accessCasing.lineWidth = 8*px;accessLine.lineWidth = 4.5*px;accessLine.lineDashPattern = [NSNumber(value:Double(7*px)),NSNumber(value:Double(6*px))]
        // Bends and the end point of a path being edited, as small ringed dots.
        if accessPathsHighlighted {
            let dots = CGMutablePath(),r = 5*px
            for path in accessPaths { for c in path.dropFirst() { let q = local(c);dots.addEllipse(in:CGRect(x:q.x-r,y:q.y-r,width:2*r,height:2*r)) } }
            accessDots.path = dots;accessDots.lineWidth = 2.5*px
        } else { accessDots.path = nil }
        if let end = route?.entrance.coordinate { let e = local(end),r = 6*px;door.path = CGPath(ellipseIn:CGRect(x:e.x-r,y:e.y-r,width:2*r,height:2*r),transform:nil) }
        layoutLabels()
        if let m = marker { pin.position = local(m).applying(cameraTransform) }
        for d in doorLayers { d.layer.position = local(d.coordinate).applying(cameraTransform) }
        if let u = shownUser {
            let s = u.applying(cameraTransform);userLayer.isHidden = false;userLayer.position = s
            headingCone.isHidden = shownHeading == nil
            headingCone.setAffineTransform(CGAffineTransform(rotationAngle:(shownHeading ?? 0)+angle))
            if let a = accuracyM,a.isFinite,a > 0 {
                let r = CGFloat(a)*scale;accuracyRing.isHidden = r < 12
                accuracyRing.path = CGPath(ellipseIn:CGRect(x:s.x-r,y:s.y-r,width:2*r,height:2*r),transform:nil)
            } else { accuracyRing.isHidden = true }
        } else { userLayer.isHidden = true;accuracyRing.isHidden = true }
        CATransaction.commit()
    }
    /// Largest buildings first; a label shows only if its whole box lies inside the building's
    /// outline (no corner outside, no outline vertex inside the box) and it overlaps no other label.
    /// Map-style labels, most important first: a building shows once zoomed in past its rank's
    /// threshold (rank 5 even at campus scale). The name sits inside the building when it fits,
    /// otherwise beside a dot on the building (right, left, above or below — whichever is free).
    /// Full name when there is room and zoom allows, else the short name. Names never overlap.
    private func layoutLabels() {
        let toWorld = cameraTransform.inverted(),view = bounds.insetBy(dx:4,dy:4)
        let zoom = scale/max(minimumScale,1e-6)
        var placed = doorLayers.compactMap { d -> CGRect? in
            let p = local(d.coordinate).applying(cameraTransform),w = (d.layer.sublayers?.last?.bounds.width ?? 0)
            return CGRect(x:p.x-16,y:p.y-27,width:32+w+4,height:43)
        }
        if let u = shownUser { let s = u.applying(cameraTransform);placed.append(CGRect(x:s.x-14,y:s.y-14,width:28,height:28)) }
        if let m = marker,!pin.isHidden { let s = local(m).applying(cameraTransform);placed.append(CGRect(x:s.x-14,y:s.y-40,width:28,height:42)) }
        let threshold:[Int:CGFloat] = [5:0.9,4:1.6,3:2.6,2:4.2,1:6.5]
        for b in buildings where !b.full.isEmpty {
            let highlighted = b.data.id == highlightedBuildingID
            var chosen:(text:String,box:CGRect,dot:CGPoint?)?
            if highlighted || zoom >= threshold[b.rank] ?? 99 {
                let texts = (zoom >= (threshold[b.rank] ?? 99)*2.2 || highlighted) && b.full != b.short ? [b.full,b.short] : [b.short]
                let anchors = [b.centroid,b.pole].map { $0.applying(cameraTransform) }
                outer: for text in texts where !text.isEmpty {
                    let size = labelImage(text,highlighted:highlighted).size
                    // Inside the building, centred.
                    for a in anchors where view.contains(a) {
                        let box = CGRect(x:a.x-size.width/2,y:a.y-size.height/2,width:size.width,height:size.height)
                        if view.contains(box),fits(box.insetBy(dx:2,dy:2),b.ring,toWorld),!placed.contains(where: { $0.intersects(box) }) { chosen = (text,box,nil);break outer }
                    }
                    // Outside: beside a dot on the building.
                    let d = anchors[1]
                    guard view.contains(d) else { continue }
                    let gap:CGFloat = 6
                    for box in [CGRect(x:d.x+gap,y:d.y-size.height/2,width:size.width,height:size.height),
                                CGRect(x:d.x-gap-size.width,y:d.y-size.height/2,width:size.width,height:size.height),
                                CGRect(x:d.x-size.width/2,y:d.y-gap-size.height,width:size.width,height:size.height),
                                CGRect(x:d.x-size.width/2,y:d.y+gap,width:size.width,height:size.height)] {
                        let withDot = box.union(CGRect(x:d.x-5,y:d.y-5,width:10,height:10))
                        if view.contains(box),!placed.contains(where: { $0.intersects(withDot) }) { chosen = (text,box,d);break outer }
                    }
                }
            }
            let label = b.label
            if let c = chosen {
                placed.append(c.dot.map { c.box.union(CGRect(x:$0.x-5,y:$0.y-5,width:10,height:10)) } ?? c.box)
                let key = c.text+(highlighted ? "|h" : "|n")
                if label.key != key { label.key = key;label.text.contents = labelImage(c.text,highlighted:highlighted).cgImage }
                // The holder sits at the label's origin; the dot is placed relative to it.
                label.frame = c.box;label.text.frame = CGRect(origin:.zero,size:c.box.size)
                if let d = c.dot { label.dot.isHidden = false;label.dot.position = CGPoint(x:d.x-c.box.minX,y:d.y-c.box.minY) } else { label.dot.isHidden = true }
                if label.opacity < 1 { fade(label,to:1) }
            } else if label.opacity > 0 { fade(label,to:0) }
        }
    }
    private func fits(_ box:CGRect,_ ring:[CGPoint],_ toWorld:CGAffineTransform) -> Bool {
        let pts = [CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY),CGPoint(x:box.minX,y:box.maxY),
                   CGPoint(x:box.midX,y:box.minY),CGPoint(x:box.maxX,y:box.midY),CGPoint(x:box.midX,y:box.maxY),CGPoint(x:box.minX,y:box.midY)].map { $0.applying(toWorld) }
        guard pts.allSatisfy({ Self.inside($0,ring) }) else { return false }
        return !ring.contains { box.contains($0.applying(cameraTransform)) }
    }
    private func fade(_ l:CALayer,to value:Float) {
        CATransaction.begin();CATransaction.setDisableActions(false)
        let a = CABasicAnimation(keyPath:"opacity");a.fromValue = l.presentation()?.opacity ?? l.opacity;a.toValue = value;a.duration = reduceMotion ? 0 : 0.2
        l.opacity = value;l.add(a,forKey:"fade");CATransaction.commit()
    }
    /// Each door: a white disc with a blue ring and door glyph, its name in a small pill beside it.
    private func rebuildDoors() {
        doorLayers.forEach { $0.layer.removeFromSuperlayer() };doorLayers = []
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let glyph = UIImage(systemName:"door.left.hand.open",withConfiguration:UIImage.SymbolConfiguration(pointSize:12,weight:.bold))?
            .withTintColor(WayfindingPalette.route,renderingMode:.alwaysOriginal)
        for (i,d) in doorMarkers.enumerated() {
            let holder = CALayer();holder.bounds = CGRect(x:0,y:0,width:1,height:1)
            let disc = CALayer();disc.bounds = CGRect(x:0,y:0,width:28,height:28);disc.cornerRadius = 14;disc.backgroundColor = UIColor.white.cgColor
            disc.borderColor = WayfindingPalette.route.cgColor;disc.borderWidth = 2.5;disc.position = .zero
            disc.shadowColor = UIColor.black.cgColor;disc.shadowOpacity = 0.2;disc.shadowRadius = 3;disc.shadowOffset = CGSize(width:0,height:1)
            let icon = CALayer();icon.contents = glyph?.cgImage;icon.contentsGravity = .resizeAspect;icon.contentsScale = scale
            icon.bounds = CGRect(x:0,y:0,width:15,height:15);icon.position = CGPoint(x:14,y:14);disc.addSublayer(icon)
            let font = UIFont.systemFont(ofSize:12,weight:.semibold),size = (d.name as NSString).size(withAttributes:[.font:font])
            let pill = CALayer();pill.bounds = CGRect(x:0,y:0,width:size.width+14,height:22);pill.cornerRadius = 11
            pill.backgroundColor = WayfindingPalette.ink.cgColor;pill.position = CGPoint(x:16+pill.bounds.width/2,y:-14)
            let text = CATextLayer();text.string = d.name;text.font = font;text.fontSize = 12;text.foregroundColor = UIColor.white.cgColor
            text.alignmentMode = .center;text.contentsScale = scale;text.frame = CGRect(x:0,y:(22-size.height)/2-1,width:pill.bounds.width,height:size.height+2)
            pill.addSublayer(text)
            holder.addSublayer(disc);if !d.name.isEmpty { holder.addSublayer(pill) }
            layer.addSublayer(holder);doorLayers.append((holder,d.coordinate))
            if !reduceMotion {
                let pop = CASpringAnimation(keyPath:"transform.scale");pop.fromValue = 0.3;pop.toValue = 1;pop.damping = 11
                pop.beginTime = CACurrentMediaTime()+Double(i)*0.06;pop.duration = pop.settlingDuration;pop.fillMode = .backwards
                holder.add(pop,forKey:"pop")
            }
        }
        render()
    }
    private func rebuildAccessPaths() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        let p = CGMutablePath()
        for path in accessPaths where path.count >= 2 { p.addPath(Self.polyline(path.map(local))) }
        accessCasing.path = p;accessLine.path = p
        accessLine.strokeColor = (accessPathsHighlighted ? NavigationPalette.attention : WayfindingPalette.route).cgColor
        accessDots.strokeColor = NavigationPalette.attention.cgColor
        CATransaction.commit();render()
    }
    private func dropMarker() {
        if pin.superlayer == nil { layer.addSublayer(pin) }
        guard marker != nil else { pin.isHidden = true;return }
        pin.isHidden = false;render()
        guard !reduceMotion else { return }
        let drop = CASpringAnimation(keyPath:"transform.translation.y");drop.fromValue = -40;drop.toValue = 0;drop.damping = 12;drop.duration = drop.settlingDuration
        pin.add(drop,forKey:"drop");UIImpactFeedbackGenerator(style:.light).impactOccurred()
    }
    private func rebuildRoute() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        guard let route,route.points.count >= 2 else { routeCasing.path = nil;routeLine.path = nil;routePassed.path = nil;door.path = nil;CATransaction.commit();return }
        let pts = route.points.map(local)
        routeCasing.path = Self.polyline(pts);routeLine.path = routeCasing.path
        // The walked part in a lighter blue, up to the projected progress.
        var passed = [pts[0]],walked = 0.0
        for i in 1..<pts.count {
            let seg = route.cumulativeM[i]-route.cumulativeM[i-1]
            if walked+seg >= routeProgressM { let f = seg > 0 ? CGFloat((routeProgressM-walked)/seg) : 0
                passed.append(CGPoint(x:pts[i-1].x+(pts[i].x-pts[i-1].x)*f,y:pts[i-1].y+(pts[i].y-pts[i-1].y)*f));break }
            walked += seg;passed.append(pts[i])
        }
        routePassed.path = routeProgressM > 0.5 ? Self.polyline(passed) : nil
        CATransaction.commit();render()
    }
    private func rebuildHighlight() {
        let b = buildings.first { $0.data.id == highlightedBuildingID }
        CATransaction.begin();CATransaction.setDisableActions(true)
        if let b { highlight.path = b.path };CATransaction.commit()
        fade(highlight,to:b == nil ? 0 : 1);render()
    }
}
