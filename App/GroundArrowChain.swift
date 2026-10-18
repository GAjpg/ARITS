#if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import RealityKit
import UIKit

/// Indoor counterpart of the outdoor AR chain (same look): flat chevrons on the floor along the
/// route ahead over `lengthM`, fading towards the far end with a forward shimmer; near the next
/// turn they grow and brighten and a pulsing turn arrow lies on the floor at the turn. Entities are
/// built once and only moved each frame. Coordinates are those of `root`'s parent (map space).
@MainActor
final class GroundArrowChain {
    let root = Entity()
    private var chevrons:[Entity] = []
    private let turnNode = Entity()
    /// The turn arrow follows the route's own curve around the turn; rebuilt when the turn changes.
    private var turnKey:String?
    private let spacing = 1.25,firstAhead = 1.2,maxCount = 26
    private var announced:(turn:Double,stage:Int)?
    private let haptic = UIImpactFeedbackGenerator(style:.medium)

    init() {
        let fill = UnlitMaterial(color:WayfindingPalette.route),edge = UnlitMaterial(color:.white)
        let inner = Self.chevronMesh(w:0.36,h:0.21,t:0.17),outer = Self.chevronMesh(w:0.43,h:0.26,t:0.29)
        for _ in 0..<maxCount {
            let e = Entity()
            if let outer { let m = ModelEntity(mesh:outer,materials:[edge]);m.position.y = 0;e.addChild(m) }
            if let inner { let m = ModelEntity(mesh:inner,materials:[fill]);m.position.y = 0.003;e.addChild(m) }
            e.isEnabled = false;root.addChild(e);chevrons.append(e)
        }
        turnNode.isEnabled = false;root.addChild(turnNode)
    }

    /// A flat mesh from 2D triangles (x right, y forward → AR x, -z), visible from both sides.
    private static func mesh(_ pts:[SIMD2<Float>],_ tris:[UInt32]) -> MeshResource? {
        var d = MeshDescriptor(name:"flat")
        d.positions = MeshBuffers.Positions(pts.map { SIMD3($0.x,0,-$0.y) })
        d.normals = MeshBuffers.Normals(Array(repeating:SIMD3<Float>(0,1,0),count:pts.count))
        var both = tris
        for i in stride(from:0,to:tris.count,by:3) { both += [tris[i],tris[i+2],tris[i+1]] }
        d.primitives = .triangles(both)
        return try? .generate(from:[d])
    }
    private static func chevronMesh(w:Float,h:Float,t:Float) -> MeshResource? {
        mesh([[0,h],[w,-h],[w,-h-t],[0,h-t],[-w,-h-t],[-w,-h]],[0,1,2, 0,2,3, 0,3,4, 0,4,5])
    }
    /// Lays the chain along `route` (map points, floor height per point) from `progress` metres.
    /// `turns` are along-route distances of upcoming turns with their side.
    func update(route:CampusRouteGeometry,progress:Double,lengthM:Double,turns:[(at:Double,right:Bool)],floor:(Double,Double) -> Double?) {
        let now = CACurrentMediaTime(),reduce = UIAccessibility.isReduceMotionEnabled
        let next = turns.first { $0.at > progress+0.5 }
        func ground(_ p:ProbePoint) -> SIMD3<Float> { SIMD3(Float(p.x),Float((floor(p.x,p.z) ?? p.y)+0.02),Float(p.z)) }
        var i = 0,s = progress+firstAhead
        while i < chevrons.count && s <= min(route.length-0.3,progress+lengthM) {
            let e = chevrons[i];i += 1
            let a = route.point(at:max(0,s-0.4)),b = route.point(at:min(route.length,s+0.4)),dx = b.x-a.x,dz = b.z-a.z
            let f = (s-progress)/max(lengthM,1)
            var alpha = 1-0.88*pow(f,1.4)
            if !reduce { alpha *= 0.78+0.22*sin(2 * .pi*(now*0.9-(s-progress)/4)) }
            var scale:Float = 1
            if let t = next,abs(s-t.at) < 3 { let k = 1-abs(s-t.at)/3;scale = Float(1+0.35*k);alpha = max(alpha,0.75+0.25*k) }
            e.position = ground(route.point(at:s));e.orientation = simd_quatf(angle:Float(atan2(-dx,-dz)),axis:[0,1,0])
            e.scale = [scale,1,scale];Self.setOpacity(e,Float(alpha));e.isEnabled = true
            s += spacing
        }
        while i < chevrons.count { chevrons[i].isEnabled = false;i += 1 }
        turnNode.isEnabled = false
        if let t = next,t.at-progress < max(12,lengthM),t.at-progress > 0.8 {
            let node = turnNode,b = route.point(at:t.at)
            let key = "\(route.length)|\(t.at)"
            if key != turnKey {
                turnKey = key
                // The route from 2 m before to 2.5 m after the turn, corner rounded; map (x, z) → 2D (x, -z).
                let samples = stride(from:max(0,t.at-2.0),through:min(route.length,t.at+2.6),by:0.4).map { s -> SIMD2<Float> in
                    let q = route.point(at:s);return SIMD2(Float(q.x-b.x),Float(-(q.z-b.z))) }
                let path = GroundArrowShape.smooth(samples,iterations:3)
                node.children.removeAll()
                if let edge = GroundArrowShape.make(path:path,width:0.42,headWidth:0.92,headLength:0.72),
                   let fill = GroundArrowShape.make(path:path,width:0.26,headWidth:0.68,headLength:0.56,endInset:0.15),
                   let edgeMesh = Self.mesh(edge.vertices,edge.indices),let fillMesh = Self.mesh(fill.vertices,fill.indices) {
                    node.addChild(ModelEntity(mesh:edgeMesh,materials:[UnlitMaterial(color:.white)]))
                    let amber = ModelEntity(mesh:fillMesh,materials:[UnlitMaterial(color:NavigationPalette.attention)]);amber.position.y = 0.003
                    node.addChild(amber)
                }
            }
            node.position = ground(b)+[0,0.01,0];node.orientation = simd_quatf(angle:0,axis:[0,1,0])
            let pulse:Float = reduce ? 1 : 1+0.06*Float(sin(2 * .pi*now/1.6))
            node.scale = [pulse,1,pulse]
            Self.setOpacity(node,Float(min(1,0.55+0.45*(1-(t.at-progress)/max(12,lengthM)))));node.isEnabled = true
            let stage = t.at-progress < 4 ? 2 : t.at-progress < 10 ? 1 : 0
            if stage > 0,announced?.turn != t.at || (announced?.stage ?? 0) < stage { announced = (t.at,stage);haptic.impactOccurred(intensity:stage == 2 ? 1 : 0.5) }
        }
    }
    /// iOS 18: an opacity component; iOS 17: transparent materials (quantised to limit churn).
    private static func setOpacity(_ e:Entity,_ a:Float) {
        if #available(iOS 18.0,*) { e.components.set(OpacityComponent(opacity:a));return }
        let q = (a*20).rounded()/20
        for child in e.children {
            guard let model = child as? ModelEntity,var m = model.model?.materials.first as? UnlitMaterial else { continue }
            if case .transparent(let o) = m.blending,abs(o.scale-q) < 0.01 { continue }
            m.blending = .transparent(opacity:.init(floatLiteral:q));model.model?.materials = [m]
        }
    }
    func hide() { chevrons.forEach { $0.isEnabled = false };turnNode.isEnabled = false }
}
#endif
