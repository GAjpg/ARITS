import UIKit
import ARKit
import SceneKit
import AVFoundation

/// Outdoor AR guidance: a chain of flat chevrons lying on the ground along the route ahead, over
/// `chainLengthM` (default 10 m), fading towards the far end with a gentle forward-flowing shimmer.
/// Near the next turn the chevrons grow and brighten and a large curved turn arrow pulses on the
/// ground at the turn. Positions come from the route and GNSS progress; AR only supplies the camera,
/// the floor height and true north (gravityAndHeading), so this is guidance, not survey accuracy.
final class OutdoorARView:UIView,ARSessionDelegate {
    var onStatus:((NavigationShellState.Status?)->Void)?
    var onUnavailable:(()->Void)?
    var route:OutdoorRoute? { didSet { shownAlong = nil;announcedTurn = nil;progressM = nil } }
    var coordinate:OutdoorCoordinate?
    /// Progress from the navigation screen (windowed matching); global projection when nil.
    var progressM:Double?
    /// Turns to emphasise (along-route distance, manoeuvre), already merged; route.steps when empty.
    var turns:[(distance:Double,maneuver:NavigationManeuver)] = []
    var locationUsable = false
    var headingUsable = false
    /// How far ahead the chain reaches, in metres.
    var chainLengthM:Double {
        get { UserDefaults.standard.object(forKey:"nav.arrowChainM") as? Double ?? 10 }
        set { UserDefaults.standard.set(newValue,forKey:"nav.arrowChainM") }
    }
    private let scene = ARSCNView(frame:.zero)
    private let chainRoot = SCNNode(),turnRoot = SCNNode(),turnNode = SCNNode()
    /// The turn arrow follows the route's own curve around the turn; rebuilt when the turn changes.
    private var turnKey:String?
    private var chevrons = [SCNNode]()
    private let spacingM = 1.25,firstAheadM = 1.6,maxChevrons = 26
    private var runGeneration = 0
    private var wantsActive = false,requestingCamera = false
    private var active = false,firstFrame = false,lastFloorQuery:TimeInterval = 0,floorY:Float?,lastTime:TimeInterval = 0
    private var shownAlong:Double?,announcedTurn:(index:Int,stage:Int)?
    private let haptic = UIImpactFeedbackGenerator(style:.medium)

    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = .black
        scene.scene = SCNScene();scene.session.delegate = self;scene.session.delegateQueue = .main
        scene.rendersContinuously = true;scene.antialiasingMode = .multisampling4X
        scene.translatesAutoresizingMaskIntoConstraints = false;addSubview(scene)
        NSLayoutConstraint.activate([scene.leadingAnchor.constraint(equalTo:leadingAnchor),scene.trailingAnchor.constraint(equalTo:trailingAnchor),
                                     scene.topAnchor.constraint(equalTo:topAnchor),scene.bottomAnchor.constraint(equalTo:bottomAnchor)])
        scene.scene.rootNode.addChildNode(chainRoot);scene.scene.rootNode.addChildNode(turnRoot)
        let chevronFill = Self.flat(Self.chevron(halfWidth:0.36,halfHeight:0.21,thickness:0.17),color:WayfindingPalette.route,order:101)
        let chevronEdge = Self.flat(Self.chevron(halfWidth:0.43,halfHeight:0.26,thickness:0.29),color:.white,order:100)
        for _ in 0..<maxChevrons {
            let n = SCNNode();n.addChildNode(chevronEdge.clone());n.addChildNode(chevronFill.clone());n.isHidden = true
            chainRoot.addChildNode(n);chevrons.append(n)
        }
        turnNode.isHidden = true;turnRoot.addChildNode(turnNode)
        let pulse = CABasicAnimation(keyPath:"scale");pulse.fromValue = SCNVector3(1,1,1);pulse.toValue = SCNVector3(1.08,1,1.08)
        pulse.duration = 0.8;pulse.autoreverses = true;pulse.repeatCount = .infinity;pulse.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
        if !UIAccessibility.isReduceMotionEnabled { turnNode.addAnimation(pulse,forKey:"pulse") }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }

    // MARK: geometry (2D shapes laid flat: +y in the shape becomes north, -z in AR)
    private static func chevron(halfWidth w:CGFloat,halfHeight h:CGFloat,thickness t:CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to:CGPoint(x:0,y:h));p.addLine(to:CGPoint(x:w,y:-h));p.addLine(to:CGPoint(x:w,y:-h-t))
        p.addLine(to:CGPoint(x:0,y:h-t));p.addLine(to:CGPoint(x:-w,y:-h-t));p.addLine(to:CGPoint(x:-w,y:-h));p.close()
        return p
    }
    private static func flat(_ path:UIBezierPath,color:UIColor,order:Int) -> SCNNode {
        path.flatness = 0.01
        let shape = SCNShape(path:path,extrusionDepth:0)
        let m = SCNMaterial();m.diffuse.contents = color;m.lightingModel = .constant;m.isDoubleSided = true
        m.readsFromDepthBuffer = false;m.writesToDepthBuffer = false;m.blendMode = .alpha
        shape.materials = [m]
        let n = SCNNode(geometry:shape);n.eulerAngles.x = -.pi/2;n.renderingOrder = order
        let holder = SCNNode();holder.addChildNode(n);return holder
    }

    // MARK: session
    func start() {
        wantsActive = true
        guard !active,!requestingCamera else { return }
        guard ARWorldTrackingConfiguration.isSupported else { onStatus?(.init("当前设备不支持实景指引",detail:"继续使用地图导航。",level:.attention));onUnavailable?();return }
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized:run()
        case .notDetermined:
            requestingCamera = true
            AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in DispatchQueue.main.async { self?.requestingCamera = false;guard self?.wantsActive == true else { return };if allowed { self?.run() } else { self?.denied() } } }
        default:denied()
        }
    }
    private func denied() { onStatus?(.init("相机权限未开启",detail:"仍可使用地图导航。",level:.attention));onUnavailable?() }
    private func run() {
        guard wantsActive,window != nil,!active else { return }
        let configuration = ARWorldTrackingConfiguration()
        // ARKit: with gravityAndHeading, -Z points to true north and +X to east.
        configuration.worldAlignment = .gravityAndHeading;configuration.planeDetection = [.horizontal]
        configuration.isLightEstimationEnabled = false
        active = true;firstFrame = false;floorY = nil;shownAlong = nil;runGeneration += 1;let token = runGeneration
        scene.session.run(configuration,options:[.resetTracking,.removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in
            guard let self,self.active,self.runGeneration == token,!self.firstFrame else { return }
            self.stop();self.onStatus?(.init("实景相机暂不可用",detail:"已返回地图，路线仍保留。",level:.attention));self.onUnavailable?()
        }
        onStatus?(.init("正在准备实景指引",detail:"缓慢移动手机，让相机看清地面。"))
    }
    func stop() { runGeneration += 1;wantsActive = false;active = false;scene.session.pause();hideAll() }
    private func hideAll() { chevrons.forEach { $0.isHidden = true };turnNode.isHidden = true }
    /// Flat geometry from a 2D mesh (x east, y north → AR x, -z).
    private static func geometry(_ m:GroundArrowShape.Mesh,color:UIColor) -> SCNGeometry {
        let v = m.vertices.map { SCNVector3($0.x,0,-$0.y) }
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:v)],elements:[SCNGeometryElement(indices:m.indices,primitiveType:.triangles)])
        let mat = SCNMaterial();mat.diffuse.contents = color;mat.lightingModel = .constant;mat.isDoubleSided = true
        mat.readsFromDepthBuffer = false;mat.writesToDepthBuffer = false;g.materials = [mat];return g
    }

    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard active else { return }
        firstFrame = true
        let dt = lastTime == 0 ? 1/60 : min(0.1,frame.timestamp-lastTime);lastTime = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            hideAll();onStatus?(.init("实景位置暂不稳定",detail:"停稳手机观察周围，或放平查看地图。",level:.attention));return
        }
        guard locationUsable,headingUsable,let route,let coordinate else {
            hideAll();onStatus?(.init("正在确认位置与朝向",detail:"定位或指南针就绪后显示地面箭头。",level:.attention));return
        }
        let camera = frame.camera.transform.columns.3
        // Floor height under the phone, queried a few times per second and low-passed.
        if frame.timestamp-lastFloorQuery > 0.2 {
            lastFloorQuery = frame.timestamp
            let q = ARRaycastQuery(origin:SIMD3(camera.x,camera.y,camera.z),direction:SIMD3<Float>(0,-1,0),allowing:.estimatedPlane,alignment:.horizontal)
            let measured = session.raycast(q).first.map { $0.worldTransform.columns.3.y } ?? camera.y-1.45
            floorY = floorY.map { $0*0.85+measured*0.15 } ?? measured
        }
        let ground = (floorY ?? camera.y-1.45)+0.02
        // Progress along the route, eased so GNSS jumps do not make the chain jerk.
        let target = progressM ?? route.projection(coordinate).alongM
        let along = shownAlong.map { abs(target-$0) > 25 ? target : $0+(target-$0)*min(1,dt*2.5) } ?? target
        shownAlong = along
        guard route.lengthM-along > 1,let here = route.point(at:along) else { hideAll();return }
        let origin = OutdoorLocalFrame(origin:here)
        func world(_ s:Double) -> SIMD2<Float>? {
            guard let p = route.point(at:min(route.lengthM,max(0,s))) else { return nil }
            let v = origin.local(p);return SIMD2(camera.x+Float(v.east),camera.z-Float(v.north))
        }
        // Next turn within reach.
        let turnKinds:Set<NavigationManeuver> = [.left,.right,.sharpLeft,.sharpRight,.slightLeft,.slightRight,.uTurn]
        let source:[(distance:Double,maneuver:NavigationManeuver)] = turns.isEmpty ? route.steps.map { ($0.distanceFromStartM,$0.maneuver) } : turns
        let turn = source.enumerated().first { turnKinds.contains($0.element.maneuver) && $0.element.distance > along+0.5 }
        let turnS = turn.map { $0.element.distance }
        let length = chainLengthM,now = CACurrentMediaTime()
        var i = 0
        var s = along+firstAheadM
        while i < chevrons.count && s <= min(route.lengthM-0.3,along+length) {
            let node = chevrons[i];i += 1
            guard let p = world(s),let a = world(s-0.4),let b = world(s+0.4) else { node.isHidden = true;s += spacingM;continue }
            let d = b-a,heading = atan2(-d.x,-d.y)
            let f = Float((s-along)/max(length,1))
            var alpha = 1-0.88*pow(f,1.4)
            if !UIAccessibility.isReduceMotionEnabled { alpha *= 0.78+0.22*Float(sin(2 * .pi*(now*0.9-(s-along)/4))) }
            var scale:Float = 1
            if let t = turnS,abs(s-t) < 3 { let k = Float(1-abs(s-t)/3);scale = 1+0.35*k;alpha = max(alpha,0.75+0.25*k) }
            node.position = SCNVector3(p.x,ground,p.y);node.eulerAngles.y = heading;node.scale = SCNVector3(scale,1,scale)
            node.opacity = CGFloat(alpha);node.isHidden = false
            s += spacingM
        }
        while i < chevrons.count { chevrons[i].isHidden = true;i += 1 }
        // The turn arrow on the ground at the turn, when the turn is within the chain or 15 m.
        turnNode.isHidden = true
        if let turn,let t = turnS,t-along < max(15,length),t-along > 1,let p = world(t),let turnPoint = route.point(at:t) {
            // The arrow follows the route from 2 m before to 2.5 m after the turn, corner rounded.
            let key = "\(route.lengthM)|\(t)"
            if key != turnKey {
                turnKey = key
                let f = OutdoorLocalFrame(origin:turnPoint)
                let samples = stride(from:max(0,t-2.0),through:min(route.lengthM,t+2.6),by:0.4).compactMap { route.point(at:$0) }.map { q -> SIMD2<Float> in
                    let l = f.local(q);return SIMD2(Float(l.east),Float(l.north)) }
                let path = GroundArrowShape.smooth(samples,iterations:3)
                turnNode.childNodes.forEach { $0.removeFromParentNode() }
                if let edge = GroundArrowShape.make(path:path,width:0.46,headWidth:1.0,headLength:0.8),
                   let fill = GroundArrowShape.make(path:path,width:0.28,headWidth:0.74,headLength:0.62,endInset:0.16) {
                    let e = SCNNode(geometry:Self.geometry(edge,color:.white));e.renderingOrder = 102
                    let i = SCNNode(geometry:Self.geometry(fill,color:NavigationPalette.attention));i.renderingOrder = 103;i.position.y = 0.004
                    turnNode.addChildNode(e);turnNode.addChildNode(i)
                }
            }
            turnNode.position = SCNVector3(p.x,ground+0.01,p.y)
            turnNode.opacity = CGFloat(min(1,0.55+0.45*(1-(t-along)/max(15,length))));turnNode.isHidden = false
            // A light tap at 15 m and a firmer one at 5 m before each turn.
            let stage = t-along < 5 ? 2 : t-along < 15 ? 1 : 0
            if stage > 0,announcedTurn?.index != turn.offset || (announcedTurn?.stage ?? 0) < stage {
                announcedTurn = (turn.offset,stage);haptic.impactOccurred(intensity:stage == 2 ? 1 : 0.5)
            }
        }
        onStatus?(nil)
    }
    func session(_ session:ARSession,didFailWithError error:Error) {
        stop();onStatus?(.init("实景指引暂不可用",detail:"已保留路线，继续使用地图。",level:.attention));onUnavailable?()
    }
    func sessionWasInterrupted(_ session:ARSession) { hideAll();onStatus?(.init("实景已暂停",detail:"返回后重新准备相机，地图路线仍保留。",level:.attention)) }
}
