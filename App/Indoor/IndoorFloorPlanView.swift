import UIKit

/// The indoor counterpart of OutdoorCampusMapView. Map x is right, map z is screen y.
/// headingRad is clockwise from map -z (0 faces screen-up, pi/2 faces map +x).
/// No camera/session ownership: compact/full-screen transitions do not touch AR.
final class IndoorFloorPlanView:UIView {
    var route:[ProbePoint] = [] { didSet { if route != oldValue { rebuildRoute() } } }
    var progressM:Double = 0 { didSet { updateProgress() } }
    var destination:ProbePoint? { didSet { updateDestination(appearing:oldValue == nil) } }
    var position:ProbePoint? { didSet { positionMoved() } }
    var headingRad:Double? { didSet { kick() } }
    var headingUp = false { didSet { kick() } }
    var followsPosition = true { didSet { if followsPosition,!oldValue,let shownPosition { animateCamera(to:shownPosition,scale:scale) } else { kick() } } }
    var compact = false { didSet { configureMode() } }

    private let world = CALayer(),walkable = CAShapeLayer(),wallLines = CAShapeLayer(),roomLayer = CALayer()
    private struct RoomMark { let point:CGPoint;let label:CATextLayer;let dot:CAShapeLayer;let width:CGFloat }
    private var roomMarks:[RoomMark] = []
    private let routeCasing = CAShapeLayer(),routeLine = CAShapeLayer(),passed = CAShapeLayer()
    private let destinationLayer = CAShapeLayer(),destinationDirection = CAShapeLayer(),userLayer = CALayer(),headingCone = CAShapeLayer()
    private var floorBounds = CGRect.zero,scale:CGFloat = 1,minimumScale:CGFloat = 1,focus = CGPoint.zero,angle:CGFloat = 0
    private var previousSize = CGSize.zero,didFit = false,routeLength = 0.0
    private var destinationEdgePath:CGPath?
    private var cameraAnimation:(from:(CGPoint,CGFloat),to:(CGPoint,CGFloat),start:CFTimeInterval,duration:CFTimeInterval)?
    private var shownPosition:CGPoint?,positionFrom:CGPoint?,positionTo:CGPoint?,positionStart:CFTimeInterval = 0,shownHeading:CGFloat?
    private var velocity = CGPoint.zero,interacting = false,lastTick:CFTimeInterval = 0
    private var link:CADisplayLink?,motionObserver:NSObjectProtocol?
    private var reduceMotion:Bool { UIAccessibility.isReduceMotionEnabled }
    private var following:Bool { compact || followsPosition }
    private var maximumScale:CGFloat { max(minimumScale*40,24) }
    private var targetAngle:CGFloat { (compact || headingUp) ? -validHeading : 0 }
    private var validHeading:CGFloat { headingRad.flatMap { $0.isFinite ? CGFloat($0) : nil } ?? 0 }
    private var cameraTransform:CGAffineTransform {
        CGAffineTransform(translationX:bounds.midX,y:bounds.midY).rotated(by:angle).scaledBy(x:scale,y:scale).translatedBy(x:-focus.x,y:-focus.y)
    }

    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = WayfindingPalette.ground;clipsToBounds = true
        accessibilityLabel = "楼层地图，显示步行路线与我的位置"
        world.anchorPoint = .zero;world.bounds = CGRect(x:0,y:0,width:1,height:1);layer.addSublayer(world)
        walkable.fillColor = WayfindingPalette.road.cgColor
        wallLines.fillColor = nil;wallLines.strokeColor = WayfindingPalette.ink.withAlphaComponent(0.20).cgColor;wallLines.lineCap = .round
        for l in [routeCasing,routeLine,passed] { l.fillColor = nil;l.lineCap = .round;l.lineJoin = .round }
        routeCasing.strokeColor = WayfindingPalette.road.cgColor;routeLine.strokeColor = WayfindingPalette.route.cgColor;passed.strokeColor = WayfindingPalette.routePassed.cgColor
        for l in [walkable,wallLines,routeCasing,routeLine,passed] { world.addSublayer(l) }
        layer.addSublayer(roomLayer)
        destinationLayer.path = CGPath(ellipseIn:CGRect(x:-7,y:-7,width:14,height:14),transform:nil)
        destinationLayer.fillColor = WayfindingPalette.road.cgColor;destinationLayer.strokeColor = WayfindingPalette.route.cgColor;destinationLayer.lineWidth = 3.5;destinationLayer.opacity = 0
        layer.addSublayer(destinationLayer)
        let triangle = CGMutablePath();triangle.move(to:CGPoint(x:7,y:0));triangle.addLine(to:CGPoint(x:-5,y:-5));triangle.addLine(to:CGPoint(x:-5,y:5));triangle.closeSubpath()
        destinationDirection.path = triangle;destinationDirection.fillColor = WayfindingPalette.route.cgColor
        destinationDirection.strokeColor = WayfindingPalette.road.cgColor;destinationDirection.lineWidth = 2;destinationDirection.lineJoin = .round;destinationDirection.opacity = 0
        layer.addSublayer(destinationDirection)
        let cone = UIBezierPath();cone.move(to:.zero);cone.addArc(withCenter:.zero,radius:34,startAngle:-.pi/2-0.45,endAngle:-.pi/2+0.45,clockwise:true);cone.close()
        headingCone.path = cone.cgPath;headingCone.fillColor = WayfindingPalette.route.withAlphaComponent(0.22).cgColor
        userLayer.addSublayer(headingCone)
        let ring = CALayer();ring.bounds = CGRect(x:0,y:0,width:22,height:22);ring.cornerRadius = 11;ring.backgroundColor = WayfindingPalette.road.cgColor
        ring.shadowColor = WayfindingPalette.ink.cgColor;ring.shadowOpacity = 0.18;ring.shadowRadius = 4;ring.shadowOffset = CGSize(width:0,height:2)
        let dot = CALayer();dot.bounds = CGRect(x:0,y:0,width:15,height:15);dot.cornerRadius = 7.5;dot.backgroundColor = WayfindingPalette.route.cgColor;dot.position = CGPoint(x:11,y:11)
        ring.addSublayer(dot);userLayer.addSublayer(ring);ring.position = .zero;userLayer.opacity = 0;layer.addSublayer(userLayer)
        addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(pan(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target:self,action:#selector(pinch(_:))))
        let double = UITapGestureRecognizer(target:self,action:#selector(doubleTap(_:)));double.numberOfTapsRequired = 2;addGestureRecognizer(double)
        let twoFinger = UITapGestureRecognizer(target:self,action:#selector(zoomOut(_:)));twoFinger.numberOfTouchesRequired = 2;addGestureRecognizer(twoFinger)
        motionObserver = NotificationCenter.default.addObserver(forName:UIAccessibility.reduceMotionStatusDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self,self.reduceMotion else { return }
            if let a = self.cameraAnimation { self.focus = a.to.0;self.scale = a.to.1 }
            self.cameraAnimation = nil;self.velocity = .zero;self.shownPosition = self.positionTo;self.positionFrom = nil
            self.angle = self.targetAngle;self.shownHeading = self.headingRad == nil ? nil : self.validHeading
            self.destinationLayer.removeAllAnimations();self.destinationDirection.removeAllAnimations();self.userLayer.removeAllAnimations()
            self.roomMarks.forEach { $0.label.removeAllAnimations();$0.dot.removeAllAnimations() };self.stopLink();self.render()
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    deinit { link?.invalidate();if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) } }
    override var isHidden:Bool { didSet { if isHidden { stopLink() } else { kick() } } }
    override func willMove(toWindow window:UIWindow?) { super.willMove(toWindow:window);if window == nil { stopLink() } }
    override func didMoveToWindow() { super.didMoveToWindow();if window != nil { updateDestination(appearing:destination != nil);kick() } }

    /// Build merged row runs once per floor, instead of one view/layer per cell or a per-frame redraw.
    func setFloor(grid:LiDARSpaceGrid,walls:[LiDARStructureLine],rooms:[LiDARRouteNode] = []) {
        let spec = grid.spec
        guard (try? spec.validate()) != nil,grid.effective.count == spec.count else { return }
        // This mask belongs only to the renderer. Routing continues to use grid.effective unchanged.
        let display = Self.displayMask(grid.effective,width:spec.width,height:spec.height,cellM:spec.cell_m)
        let path = CGMutablePath(),c = CGFloat(spec.cell_m)
        for j in 0..<spec.height {
            var i = 0
            while i < spec.width {
                if !display[j*spec.width+i] { i += 1;continue }
                let begin = i
                while i < spec.width && display[j*spec.width+i] { i += 1 }
                path.addRect(CGRect(x:spec.origin_x+Double(begin)*spec.cell_m,y:spec.origin_z+Double(j)*spec.cell_m,width:Double(i-begin)*spec.cell_m,height:Double(c)))
            }
        }
        let wall = CGMutablePath()
        for line in Self.displayWalls(walls) {
            wall.move(to:line.0);wall.addLine(to:line.1)
        }
        CATransaction.begin();CATransaction.setDisableActions(true);walkable.path = path;wallLines.path = wall;CATransaction.commit()
        floorBounds = CGRect(x:spec.origin_x,y:spec.origin_z,width:Double(spec.width)*spec.cell_m,height:Double(spec.height)*spec.cell_m)
        setRooms(rooms)
        cameraAnimation = nil;velocity = .zero;didFit = false;setNeedsLayout()
    }
    /// Room coordinates are entrance positions, not inferred centres of unscanned rooms.
    /// Labels are built once and stay upright while the map rotates beneath them.
    private func setRooms(_ nodes:[LiDARRouteNode]) {
        roomLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let font = UIFont.systemFont(ofSize:12,weight:.medium),screenScale = window?.screen.scale ?? UIScreen.main.scale
        var seen = Set<String>()
        roomMarks = nodes.compactMap { node in
            let name = node.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard node.resolvedKind == .room,!name.isEmpty,Self.valid(node.position),seen.insert(node.id).inserted else { return nil }
            let label = CATextLayer();label.string = name;label.font = font;label.fontSize = 12
            label.contentsScale = screenScale;label.alignmentMode = .center;label.truncationMode = .end
            label.foregroundColor = WayfindingPalette.buildingLabel.withAlphaComponent(0.70).cgColor;label.opacity = 0
            let dot = CAShapeLayer();dot.path = CGPath(ellipseIn:CGRect(x:-2,y:-2,width:4,height:4),transform:nil)
            dot.fillColor = WayfindingPalette.buildingLabel.withAlphaComponent(0.45).cgColor;dot.opacity = 0
            roomLayer.addSublayer(dot);roomLayer.addSublayer(label)
            return RoomMark(point:Self.point(node.position),label:label,dot:dot,width:ceil((name as NSString).size(withAttributes:[.font:font]).width)+4)
        }
    }
    private func layoutRoomMarks() {
        let viewport = bounds.insetBy(dx:compact ? 10 : 8,dy:compact ? 10 : 8),transform = cameraTransform
        let routePoints = route.allSatisfy(Self.valid) ? route.map { Self.point($0).applying(transform) } : []
        let routeSegments = Array(zip(routePoints,routePoints.dropFirst()))
        var occupied = [CGRect]()
        if let person = shownPosition?.applying(transform) { occupied.append(CGRect(x:person.x-19,y:person.y-19,width:38,height:38)) }
        if let destination,Self.valid(destination) {
            let d = Self.point(destination).applying(transform);occupied.append(CGRect(x:d.x-14,y:d.y-14,width:28,height:28))
            if destinationDirection.opacity > 0 { let p = destinationDirection.position;occupied.append(CGRect(x:p.x-12,y:p.y-12,width:24,height:24)) }
        }
        for mark in roomMarks {
            let anchor = mark.point.applying(transform)
            let isDestination = destination.map { Self.valid($0) && hypot(mark.point.x-CGFloat($0.x),mark.point.y-CGFloat($0.z)) < 0.35 } ?? false
            let onScreen = viewport.contains(anchor) && !isDestination
            let markerBox = CGRect(x:anchor.x-4,y:anchor.y-4,width:8,height:8)
            let markerVisible = onScreen && !occupied.contains { $0.intersects(markerBox) }
            mark.dot.position = anchor
            if mark.dot.opacity != (markerVisible ? 1 : 0) { fade(mark.dot,to:markerVisible ? 1 : 0) }
            var chosen:CGRect?
            if onScreen {
                let w = min(mark.width,compact ? 84 : 144),h:CGFloat = 17
                let choices = [CGRect(x:anchor.x+8,y:anchor.y-h/2,width:w,height:h),
                               CGRect(x:anchor.x-w-8,y:anchor.y-h/2,width:w,height:h),
                               CGRect(x:anchor.x-w/2,y:anchor.y-h-7,width:w,height:h),
                               CGRect(x:anchor.x-w/2,y:anchor.y+7,width:w,height:h)]
                for box in choices where viewport.contains(box) && !occupied.contains(where: { $0.intersects(box.insetBy(dx:-3,dy:-3)) }) {
                    // Keep room names away from the navigation stroke. Geometry/labels are not rebuilt.
                    let clear = !routeSegments.contains { Self.intersects($0.0,$0.1,rect:box.insetBy(dx:-7,dy:-5)) }
                    if clear { chosen = box;break }
                }
            }
            if let box = chosen {
                mark.label.frame = box;occupied.append(box.insetBy(dx:-3,dy:-3))
                if mark.label.opacity != 1 { fade(mark.label,to:1) }
            } else if mark.label.opacity != 0 { fade(mark.label,to:0) }
        }
    }
    private static func intersects(_ a:CGPoint,_ b:CGPoint,rect:CGRect) -> Bool {
        // Liang–Barsky clipping: a diagonal route should reserve just its stroke, not its entire bbox.
        let dx = b.x-a.x,dy = b.y-a.y
        var lo:CGFloat = 0,hi:CGFloat = 1
        for (p,q) in [(-dx,a.x-rect.minX),(dx,rect.maxX-a.x),(-dy,a.y-rect.minY),(dy,rect.maxY-a.y)] {
            if abs(p) < 1e-9 { if q < 0 { return false };continue }
            let t = q/p
            if p < 0 { lo = max(lo,t) } else { hi = min(hi,t) }
            if lo > hi { return false }
        }
        return true
    }
    /// Fill only small enclosed holes, then close one cell. Neither operation changes map data.
    private static func displayMask(_ source:[Bool],width:Int,height:Int,cellM:Double) -> [Bool] {
        guard width > 0,height > 0,source.count == width*height,cellM.isFinite,cellM > 0 else { return source }
        var result = source,visited = [Bool](repeating:false,count:source.count)
        let limit = Int(floor(1/(cellM*cellM)+1e-7))
        for start in source.indices where !source[start] && !visited[start] {
            var cells = [start],head = 0,touchesEdge = false;visited[start] = true
            while head < cells.count {
                let at = cells[head],x = at%width,y = at/width;head += 1
                if x == 0 || y == 0 || x == width-1 || y == height-1 { touchesEdge = true }
                for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx = x+dx,ny = y+dy
                    guard nx >= 0,nx < width,ny >= 0,ny < height else { continue }
                    let n = ny*width+nx
                    if !source[n] && !visited[n] { visited[n] = true;cells.append(n) }
                }
            }
            if !touchesEdge && cells.count <= limit { for at in cells { result[at] = true } }
        }
        var dilated = result
        for y in 0..<height { for x in 0..<width where result[y*width+x] {
            for dy in -1...1 { for dx in -1...1 {
                let nx = x+dx,ny = y+dy
                if nx >= 0,nx < width,ny >= 0,ny < height { dilated[ny*width+nx] = true }
            } }
        } }
        var closed = result
        for y in 0..<height { for x in 0..<width where !result[y*width+x] {
            var surrounded = true
            for dy in -1...1 { for dx in -1...1 {
                let nx = x+dx,ny = y+dy
                if nx < 0 || nx >= width || ny < 0 || ny >= height || !dilated[ny*width+nx] { surrounded = false }
            } }
            closed[y*width+x] = surrounded
        } }
        return closed
    }
    /// Merge display duplicates only. Retain original members to avoid chaining two distinct walls.
    private static func displayWalls(_ source:[LiDARStructureLine]) -> [(CGPoint,CGPoint)] {
        struct Segment {
            let a:CGPoint,b:CGPoint
            var length:CGFloat { hypot(b.x-a.x,b.y-a.y) }
            var axis:CGPoint { let l = length;return CGPoint(x:(b.x-a.x)/l,y:(b.y-a.y)/l) }
            var center:CGPoint { CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2) }
        }
        func dot(_ a:CGPoint,_ b:CGPoint) -> CGFloat { a.x*b.x+a.y*b.y }
        func minus(_ a:CGPoint,_ b:CGPoint) -> CGPoint { CGPoint(x:a.x-b.x,y:a.y-b.y) }
        func cross(_ a:CGPoint,_ b:CGPoint) -> CGFloat { a.x*b.y-a.y*b.x }
        func overlap(_ a:Segment,_ b:Segment) -> Bool {
            let u = a.axis,aa = dot(a.a,u),ab = dot(a.b,u),ba = dot(b.a,u),bb = dot(b.b,u)
            return min(max(aa,ab),max(ba,bb))-max(min(aa,ab),min(ba,bb)) > 0.001
        }
        func mergeable(_ a:[Segment],_ b:[Segment]) -> Bool {
            var overlaps = false
            for p in a { for q in b {
                guard abs(dot(p.axis,q.axis)) > cos(8 * .pi/180),
                      abs(cross(minus(q.center,p.center),p.axis)) < 0.15,
                      abs(cross(minus(p.center,q.center),q.axis)) < 0.15 else { return false }
                overlaps = overlaps || overlap(p,q)
            } }
            return overlaps
        }
        var groups = source.filter { $0.kind == "wall_foot" && valid($0.a) && valid($0.b) }
            .map { Segment(a:point($0.a),b:point($0.b)) }.filter { $0.length > 0.001 }
            .sorted { $0.length > $1.length }.map { [$0] }
        var i = 0
        while i < groups.count {
            var j = i+1
            while j < groups.count {
                if mergeable(groups[i],groups[j]) { let members = groups.remove(at:j);groups[i].append(contentsOf:members);j = i+1 }
                else { j += 1 }
            }
            i += 1
        }
        return groups.compactMap { group in
            let reference = group[0].axis,total = group.reduce(CGFloat(0)) { $0+$1.length }
            var axis = CGPoint.zero,center = CGPoint.zero
            for s in group {
                let sign:CGFloat = dot(s.axis,reference) < 0 ? -1 : 1
                axis.x += s.axis.x*s.length*sign;axis.y += s.axis.y*s.length*sign
                center.x += s.center.x*s.length/total;center.y += s.center.y*s.length/total
            }
            let norm = hypot(axis.x,axis.y);axis.x /= norm;axis.y /= norm
            let projected = group.flatMap { [dot(minus($0.a,center),axis),dot(minus($0.b,center),axis)] }
            guard let lo = projected.min(),let hi = projected.max(),hi-lo >= 0.5 else { return nil }
            return (CGPoint(x:center.x+lo*axis.x,y:center.y+lo*axis.y),CGPoint(x:center.x+hi*axis.x,y:center.y+hi*axis.y))
        }
    }
    private static func valid(_ p:ProbePoint) -> Bool { p.x.isFinite && p.z.isFinite }
    private static func point(_ p:ProbePoint) -> CGPoint { CGPoint(x:p.x,y:p.z) }
    private static func polyline(_ points:[CGPoint]) -> CGPath {
        let p = CGMutablePath();if let first = points.first { p.move(to:first);for q in points.dropFirst() { p.addLine(to:q) } };return p
    }
    private func rebuildRoute() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        let valid = route.allSatisfy(Self.valid),points = valid ? route.map(Self.point) : []
        routeCasing.path = points.count >= 2 ? Self.polyline(points) : nil;routeLine.path = routeCasing.path;passed.path = routeCasing.path
        routeLength = zip(points,points.dropFirst()).reduce(0) { $0+Double(hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y)) }
        CATransaction.commit();updateProgress()
    }
    private func updateProgress() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        passed.strokeEnd = routeLength > 0 && progressM.isFinite ? CGFloat(max(0,min(1,progressM/routeLength))) : 0
        CATransaction.commit();render()
    }
    private func updateDestination(appearing:Bool) {
        let visible = destination.map(Self.valid) == true
        if !visible { fade(destinationLayer,to:0);fade(destinationDirection,to:0) };render()
        if visible && appearing && !reduceMotion && window != nil {
            let pop = CASpringAnimation(keyPath:"transform.scale");pop.fromValue = 0.3;pop.toValue = 1;pop.damping = 11;pop.duration = pop.settlingDuration
            destinationLayer.add(pop,forKey:"pop")
        }
    }
    override var intrinsicContentSize:CGSize { compact ? CGSize(width:132,height:156) : CGSize(width:UIView.noIntrinsicMetric,height:UIView.noIntrinsicMetric) }
    private func configureMode() {
        invalidateIntrinsicContentSize()
        if compact { Style.float(self,radius:20);backgroundColor = WayfindingPalette.ground;layer.borderColor = WayfindingPalette.road.cgColor;layer.borderWidth = 3 }
        else { layer.cornerRadius = 0;layer.borderWidth = 0;layer.shadowOpacity = 0 }
        roomLayer.isHidden = compact
        gestureRecognizers?.forEach { $0.isEnabled = !compact }
        cameraAnimation = nil;velocity = .zero;interacting = false;didFit = false;setNeedsLayout();kick()
    }
    override func layoutSubviews() {
        super.layoutSubviews();guard bounds.width > 0,bounds.height > 0,!floorBounds.isEmpty else { return }
        minimumScale = min(bounds.width*0.92/floorBounds.width,bounds.height*0.85/floorBounds.height)
        if !didFit {
            scale = compact ? bounds.width/25 : minimumScale
            focus = following ? shownPosition ?? CGPoint(x:floorBounds.midX,y:floorBounds.midY) : CGPoint(x:floorBounds.midX,y:floorBounds.midY);didFit = true
        } else if previousSize != bounds.size { scale = compact ? bounds.width/25 : max(minimumScale,min(maximumScale,scale));focus = clamped(focus) }
        if previousSize != bounds.size { destinationEdgePath = UIBezierPath(roundedRect:bounds.insetBy(dx:17,dy:17),cornerRadius:8).cgPath }
        previousSize = bounds.size;render()
    }
    /// Fit route and person in the unobscured band; compact mode always keeps its automatic follow.
    func frameRoute(top:CGFloat,bottom:CGFloat) {
        guard !compact,route.count >= 2,route.allSatisfy(Self.valid),bounds.width > 0 else { return }
        let rotation = CGAffineTransform(rotationAngle:angle)
        var points = route.map(Self.point);if let u = shownPosition { points.append(u) }
        let rotated = points.map { $0.applying(rotation) }
        let box = Self.polyline(rotated).boundingBox,band = max(120,bounds.height-max(0,top)-max(0,bottom))
        let s = max(minimumScale,min(maximumScale,min(bounds.width*0.8/max(box.width,20),band*0.8/max(box.height,20))))
        let center = CGPoint(x:box.midX,y:box.midY-(max(0,top)+band/2-bounds.midY)/s).applying(rotation.inverted())
        followsPosition = false;animateCamera(to:center,scale:s,duration:0.6)
    }
    private func animateCamera(to point:CGPoint,scale target:CGFloat,duration:CFTimeInterval = 0.45) {
        velocity = .zero;let goal = (clamped(point),compact ? bounds.width/25 : max(minimumScale,min(maximumScale,target)))
        if reduceMotion || window == nil { focus = goal.0;scale = goal.1;render();return }
        cameraAnimation = ((focus,scale),goal,CACurrentMediaTime(),duration);kick()
    }
    private func clamped(_ p:CGPoint) -> CGPoint {
        guard !floorBounds.isEmpty else { return p }
        return CGPoint(x:max(floorBounds.minX-60,min(floorBounds.maxX+60,p.x)),y:max(floorBounds.minY-60,min(floorBounds.maxY+60,p.y)))
    }
    private func move(by delta:CGPoint) {
        let d = delta.applying(CGAffineTransform(rotationAngle:angle).scaledBy(x:scale,y:scale).inverted())
        focus = clamped(CGPoint(x:focus.x-d.x,y:focus.y-d.y))
    }
    @objc private func pan(_ g:UIPanGestureRecognizer) {
        guard !compact else { return }
        switch g.state {
        case .began:cameraAnimation = nil;velocity = .zero;interacting = true;followsPosition = false
        case .changed:let d = g.translation(in:self);g.setTranslation(.zero,in:self);move(by:d);render()
        case .ended:interacting = false;velocity = reduceMotion ? .zero : g.velocity(in:self);kick()
        default:interacting = false;velocity = .zero;kick()
        }
    }
    @objc private func pinch(_ g:UIPinchGestureRecognizer) {
        guard !compact else { return }
        if g.state == .began { cameraAnimation = nil;velocity = .zero;interacting = true;followsPosition = false }
        let touch = g.location(in:self),before = touch.applying(cameraTransform.inverted())
        scale = max(minimumScale,min(maximumScale,scale*g.scale));g.scale = 1
        let after = touch.applying(cameraTransform.inverted());focus = clamped(CGPoint(x:focus.x+before.x-after.x,y:focus.y+before.y-after.y))
        if g.state == .ended || g.state == .cancelled { interacting = false };render()
    }
    @objc private func doubleTap(_ g:UITapGestureRecognizer) {
        followsPosition = false;let p = g.location(in:self).applying(cameraTransform.inverted())
        animateCamera(to:CGPoint(x:focus.x+(p.x-focus.x)*0.5,y:focus.y+(p.y-focus.y)*0.5),scale:scale*2,duration:0.35)
    }
    @objc private func zoomOut(_ g:UITapGestureRecognizer) { animateCamera(to:focus,scale:scale/2,duration:0.35) }
    private func positionMoved() {
        guard let position,Self.valid(position) else { positionFrom = nil;positionTo = nil;shownPosition = nil;fade(userLayer,to:0);render();return }
        let p = Self.point(position)
        if let old = shownPosition,hypot(p.x-old.x,p.y-old.y) < 60,!reduceMotion {
            positionFrom = old;positionTo = p;positionStart = CACurrentMediaTime()
        } else { shownPosition = p;positionTo = p;positionFrom = nil }
        fade(userLayer,to:1);kick()
    }
    private func fade(_ l:CALayer,to value:Float) {
        let a = CABasicAnimation(keyPath:"opacity");a.fromValue = l.presentation()?.opacity ?? l.opacity;a.toValue = value;a.duration = reduceMotion ? 0 : 0.2
        CATransaction.begin();CATransaction.setDisableActions(true);l.opacity = value;l.add(a,forKey:"fade");CATransaction.commit()
    }
    private func kick() {
        guard window != nil,!isHidden else { if reduceMotion { angle = targetAngle;shownHeading = headingRad == nil ? nil : validHeading };render();return }
        if link == nil { let l = CADisplayLink(target:self,selector:#selector(tick(_:)));l.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120);l.add(to:.main,forMode:.common);link = l;lastTick = CACurrentMediaTime() }
    }
    private func stopLink() { link?.invalidate();link = nil }
    @objc private func tick(_ l:CADisplayLink) {
        let now = CACurrentMediaTime(),dt = min(0.05,now-lastTick);lastTick = now;var busy = interacting
        if reduceMotion {
            if let a = cameraAnimation { focus = a.to.0;scale = a.to.1 };cameraAnimation = nil;velocity = .zero
            shownPosition = positionTo;positionFrom = nil;angle = targetAngle;shownHeading = headingRad == nil ? nil : validHeading
        } else {
            if let a = cameraAnimation {
                let t = min(1,(now-a.start)/a.duration),e = CGFloat(1-pow(1-t,3))
                focus = CGPoint(x:a.from.0.x+(a.to.0.x-a.from.0.x)*e,y:a.from.0.y+(a.to.0.y-a.from.0.y)*e);scale = a.from.1*pow(a.to.1/a.from.1,e)
                if t >= 1 { cameraAnimation = nil } else { busy = true }
            } else if hypot(velocity.x,velocity.y) > 8 {
                move(by:CGPoint(x:velocity.x*dt,y:velocity.y*dt));let k = CGFloat(exp(-4.2*dt));velocity.x *= k;velocity.y *= k;busy = true
            } else { velocity = .zero }
            if let from = positionFrom,let to = positionTo {
                let t = min(1,(now-positionStart)/0.8),e = CGFloat(t*t*(3-2*t));shownPosition = CGPoint(x:from.x+(to.x-from.x)*e,y:from.y+(to.y-from.y)*e)
                if t >= 1 { positionFrom = nil } else { busy = true }
            }
            let diff = atan2(sin(targetAngle-angle),cos(targetAngle-angle))
            if abs(diff) > 0.002 { angle += diff*CGFloat(min(1,dt/0.12));busy = true } else { angle = targetAngle }
            if let h = headingRad,h.isFinite {
                let goal = CGFloat(h),cur = shownHeading ?? goal,d = atan2(sin(goal-cur),cos(goal-cur))
                shownHeading = abs(d) > 0.002 ? cur+d*CGFloat(min(1,dt/0.1)) : goal;if abs(d) > 0.002 { busy = true }
            } else { shownHeading = nil }
        }
        if following,cameraAnimation == nil,!interacting,let p = shownPosition { focus = clamped(p) }
        render();if !busy { stopLink() }
    }
    private func render() {
        guard bounds.width > 0 else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        world.setAffineTransform(cameraTransform);wallLines.lineWidth = 2/max(scale,1e-6)
        routeCasing.lineWidth = 11/max(scale,1e-6);routeLine.lineWidth = 7/max(scale,1e-6);passed.lineWidth = routeLine.lineWidth
        if let destination,Self.valid(destination) {
            let target = Self.point(destination).applying(cameraTransform),safe = bounds.insetBy(dx:17,dy:17)
            let offscreen = compact && !safe.contains(target)
            destinationLayer.position = target
            if offscreen,let outline = destinationEdgePath {
                // Intersect the direction ray with an inset rounded rectangle, so the marker
                // remains inside the mini window's rounded white frame even at a corner.
                let center = CGPoint(x:bounds.midX,y:bounds.midY),dx = target.x-center.x,dy = target.y-center.y
                var lo:CGFloat = 0,hi:CGFloat = 1
                for _ in 0..<18 {
                    let t = (lo+hi)/2,p = CGPoint(x:center.x+dx*t,y:center.y+dy*t)
                    if outline.contains(p) { lo = t } else { hi = t }
                }
                destinationDirection.position = CGPoint(x:center.x+dx*lo,y:center.y+dy*lo)
                destinationDirection.setAffineTransform(CGAffineTransform(rotationAngle:atan2(dy,dx)))
            }
            if destinationLayer.opacity != (offscreen ? 0 : 1) { fade(destinationLayer,to:offscreen ? 0 : 1) }
            if destinationDirection.opacity != (offscreen ? 1 : 0) { fade(destinationDirection,to:offscreen ? 1 : 0) }
        }
        if let u = shownPosition { userLayer.position = u.applying(cameraTransform) }
        headingCone.isHidden = shownHeading == nil;headingCone.setAffineTransform(CGAffineTransform(rotationAngle:(shownHeading ?? 0)+angle))
        if !compact { layoutRoomMarks() }
        CATransaction.commit()
    }
}
