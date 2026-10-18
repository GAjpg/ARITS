import ARKit
#if !targetEnvironment(macCatalyst)
import RealityKit
import UIKit

@MainActor
enum RouteRenderer {
    private static let ribbonMesh = MeshResource.generateBox(size:[0.04,0.006,1])
    private static let destinationMesh = MeshResource.generateSphere(radius:0.18)
    private static var chevronMesh:MeshResource?
    private static var returnArrowMesh:MeshResource?
    static func returnBearing(points:[SIMD3<Float>],target:SIMD3<Float>) throws -> Entity {
        let root = Entity()
        guard points.count == 2 else { return root }
        let delta = points[1]-points[0]
        guard hypot(delta.x,delta.z) > 0.05 else { return root }
        if returnArrowMesh == nil {
            var mesh = MeshDescriptor(name:"return-bearing-arrow")
            mesh.positions = MeshBuffers.Positions([[-0.22,0,0.1],[0,0,-0.3],[0.22,0,0.1]])
            mesh.normals = MeshBuffers.Normals(Array(repeating:[0,1,0],count:3));mesh.primitives = .triangles([0,2,1])
            returnArrowMesh = try .generate(from:[mesh])
        }
        let material = UnlitMaterial(color:.systemOrange),arrow = Entity()
        if let mesh = returnArrowMesh { arrow.addChild(ModelEntity(mesh:mesh,materials:[material])) }
        let shaft = ModelEntity(mesh:.generateBox(size:[0.10,0.008,0.45]),materials:[material]);shaft.position = [0,0,0.28];arrow.addChild(shaft)
        arrow.position = (points[0]+points[1])/2+[0,0.04,0];arrow.orientation = simd_quatf(angle:atan2(-delta.x,-delta.z),axis:[0,1,0]);root.addChild(arrow)
        let marker = ModelEntity(mesh:destinationMesh,materials:[material]);marker.scale.y = 0.025;marker.position = target+[0,0.035,0];root.addChild(marker)
        return root
    }
    /// Arrow spacing stays fixed in map space as the visible window moves.
    static func navigation(points:[SIMD3<Float>],progress:Double,ahead:Double) throws -> Entity {
        let root = Entity()
        let geometry = try CampusRouteGeometry(points:points.map { ProbePoint(Double($0.x),Double($0.y),Double($0.z)) })
        let start = max(0,progress-1),end = min(geometry.length,progress+ahead)
        func material(_ color:UIColor,_ distance:Double) -> UnlitMaterial {
            let fadeStart = progress+ahead*0.7
            let alpha = min(1,max(0,(progress+ahead-distance)/max(1,progress+ahead-fadeStart)))
            var m = UnlitMaterial(color:color)
            m.blending = .transparent(opacity:.init(floatLiteral:Float(alpha*0.9)))
            return m
        }
        if chevronMesh == nil {
            var mesh = MeshDescriptor(name:"navigation-chevron")
            mesh.positions = MeshBuffers.Positions([[-0.22,0,0.12],[0,0,-0.14],[0.22,0,0.12],[-0.22,0,0.03],[0,0,-0.23],[0.22,0,0.03]])
            mesh.normals = MeshBuffers.Normals(Array(repeating:[0,1,0],count:6))
            mesh.primitives = .triangles([0,1,3,3,1,4,1,2,4,4,2,5])
            chevronMesh = try .generate(from:[mesh])
        }
        func vector(_ p:ProbePoint) -> SIMD3<Float> { SIMD3(Float(p.x),Float(p.y),Float(p.z)) }
        let mint = UIColor(red:0.22,green:0.94,blue:0.8,alpha:1)
        for i in 0..<max(0,points.count-1) {
            let lo = max(start,geometry.distances[i]),hi = min(end,geometry.distances[i+1])
            guard hi-lo > 0.01 else { continue }
            for d in stride(from:lo,to:hi,by:0.75) {
                let last = min(hi,d+0.75),a = vector(geometry.point(at:d)),b = vector(geometry.point(at:last))
                let delta = b-a,length = hypot(delta.x,delta.z)
                guard length > 0.005 else { continue }
                let line = ModelEntity(mesh:ribbonMesh,materials:[material(mint,(d+last)/2)])
                line.scale.z = length;line.position = (a+b)/2+[0,0.025,0]
                line.orientation = simd_quatf(angle:atan2(-delta.x,-delta.z),axis:[0,1,0]);root.addChild(line)
            }
        }
        if let mesh = chevronMesh {
            let first = ceil(max(start,progress+0.4)/1.5)*1.5
            if first < end {
                for d in stride(from:first,to:end,by:1.5) {
                    let a = vector(geometry.point(at:d)),b = vector(geometry.point(at:min(geometry.length,d+0.1))),delta = b-a
                    guard hypot(delta.x,delta.z) > 0.001 else { continue }
                    let arrow = ModelEntity(mesh:mesh,materials:[material(.white,d)])
                    arrow.position = a+[0,0.04,0];arrow.orientation = simd_quatf(angle:atan2(-delta.x,-delta.z),axis:[0,1,0]);root.addChild(arrow)
                }
            }
        }
        if geometry.length <= progress+ahead,let last = points.last {
            let marker = ModelEntity(mesh:destinationMesh,materials:[UnlitMaterial(color:mint)])
            marker.scale.y = 0.025;marker.position = last+[0,0.03,0];root.addChild(marker)
        }
        return root
    }
    // Endpoints always follow the stored edge direction, including reverse navigation.
    static func coloredSides(a:SIMD3<Float>,b:SIMD3<Float>) -> Entity {
        let root = Entity();var d = b-a;d.y = 0;let length = simd_length(d)
        guard length >= 0.05,length < 1000 else { return root }
        let direction = d/length,right = SIMD3(-direction.z,0,direction.x)
        let rotation = simd_quatf(angle:atan2(-direction.x,-direction.z),axis:[0,1,0])
        for (side,color) in [(Float(-1),UIColor.systemYellow),(Float(1),UIColor.systemBlue)] {
            let strip = ModelEntity(mesh:.generateBox(size:[0.075,0.012,length]),materials:[UnlitMaterial(color:color)])
            strip.position = (a+b)/2+right*(0.3*side)+[0,0.035,0];strip.orientation = rotation;root.addChild(strip)
        };return root
    }
    static func network(points: [SIMD3<Float>], color: UIColor = .systemMint, arrows: Bool = true) throws -> Entity {
        let root = Entity()
        guard points.count >= 2 else { return root }
        let line = UnlitMaterial(color:color), white = UnlitMaterial(color:.white)
        var arrowCount = 0
        for (a,b) in zip(points,points.dropFirst()) {
            var delta = b-a; delta.y = 0; let length = simd_length(delta)
            guard length >= 0.05, length < 1000 else { continue }
            let direction = delta / length
            let rotation = simd_quatf(angle:atan2(-direction.x,-direction.z),axis:[0,1,0])
            let strip = ModelEntity(mesh:.generateBox(size:[0.09,0.01,length]),materials:[line])
            strip.position = (a+b)/2 + [0,0.025,0]; strip.orientation = rotation; root.addChild(strip)
            if arrows {
                for d in stride(from:Float(0.4),to:length,by:Float(1.2)) where arrowCount < 400 {
                    let fraction = d/length
                    var descriptor = MeshDescriptor(name:"network-arrow")
                    descriptor.positions = MeshBuffers.Positions([[-0.15,0,0.12],[0.15,0,0.12],[0,0,-0.22]])
                    descriptor.normals = MeshBuffers.Normals([[0,1,0],[0,1,0],[0,1,0]])
                    descriptor.primitives = .triangles([0,1,2])
                    let arrow = ModelEntity(mesh:try .generate(from:[descriptor]),materials:[white])
                    arrow.position = a + (b-a)*fraction + [0,0.035,0]; arrow.orientation = rotation
                    root.addChild(arrow); arrowCount += 1
                }
            }
        }; return root
    }
    static func make(kind: RouteKind, points: [ProbePoint]) throws -> Entity {
        let root = Entity()
        let mint = UnlitMaterial(color: UIColor(red: 0.18, green: 0.96, blue: 0.71, alpha: 1))
        let white = UnlitMaterial(color: .white)
        let cyan = UnlitMaterial(color: .systemCyan)
        guard points.count >= 2 else { return root }
        for i in 0..<(points.count - 1) {
            let a = SIMD3<Float>(Float(points[i].x), 0, Float(points[i].z))
            let b = SIMD3<Float>(Float(points[i+1].x), 0, Float(points[i+1].z))
            let d = b - a; let length = simd_length(d)
            let direction = simd_normalize(d)
            let rotation = simd_quatf(angle: atan2(-direction.x, -direction.z), axis: [0,1,0])
            if kind != .arrow {
                let strip = ModelEntity(mesh: .generateBox(size: [0.10, 0.012, length]), materials: [mint])
                strip.position = (a + b) / 2 + [0,0.015,0]; strip.orientation = rotation
                root.addChild(strip)
            }
            let distances: [Float] = kind == .arrow ? [0.35] : stride(from: Float(0.45), to: length, by: Float(0.8)).map { $0 }
            for distance in distances {
                var descriptor = MeshDescriptor(name: "floor-arrow")
                descriptor.positions = MeshBuffers.Positions([[-0.16,0,0.12],[0.16,0,0.12],[0,0,-0.20]])
                descriptor.normals = MeshBuffers.Normals([[0,1,0],[0,1,0],[0,1,0]])
                descriptor.primitives = .triangles([0,1,2])
                let arrow = Entity()
                let head = ModelEntity(mesh: try .generate(from: [descriptor]), materials: [white])
                arrow.addChild(head)
                let shaft = ModelEntity(mesh: .generateBox(size: [0.09,0.008,0.25]), materials: [white])
                shaft.position = [0,0,0.20]; arrow.addChild(shaft)
                arrow.position = a + direction * distance + [0,0.028,0]
                arrow.orientation = rotation; root.addChild(arrow)
            }
        }
        for point in [points[0], points[points.count - 1]] {
            let marker = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [cyan])
            marker.position = [Float(point.x), 0.045, Float(point.z)]
            root.addChild(marker)
        }
        return root
    }
}

#endif
