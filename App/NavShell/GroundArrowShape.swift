import simd

/// A flat arrow that follows a curve: a ribbon along the (smoothed) path with an arrowhead at the
/// end pointing along the last direction. Shared by the outdoor (SceneKit) and indoor (RealityKit)
/// turn arrows, so a slight bend draws a slight arrow and a sharp turn a sharp one.
/// Points are 2D in metres (x right, y forward/north); output triangles are counter-clockwise.
enum GroundArrowShape {
    struct Mesh { var vertices:[SIMD2<Float>];var indices:[UInt32] }

    /// Chaikin corner cutting (endpoints kept), to round the turn without moving it much.
    static func smooth(_ p:[SIMD2<Float>],iterations:Int = 2) -> [SIMD2<Float>] {
        guard p.count > 2 else { return p }
        var pts = p
        for _ in 0..<iterations {
            var out = [pts[0]]
            for i in 0..<(pts.count-1) {
                let a = pts[i],b = pts[i+1]
                out.append(a*0.75+b*0.25);out.append(a*0.25+b*0.75)
            }
            out.append(pts[pts.count-1]);pts = out
        }
        return pts
    }
    /// Ribbon of `width` along `path`, ending `headLength` before its end, plus a head `headWidth` wide.
    /// `endInset` pulls the tip back along the last direction (the fill inside an outline).
    static func make(path raw:[SIMD2<Float>],width:Float,headWidth:Float,headLength:Float,endInset:Float = 0) -> Mesh? {
        // Drop near-duplicate points.
        var path = [SIMD2<Float>]()
        for p in raw where path.last.map({ simd_distance($0,p) > 0.02 }) ?? true { path.append(p) }
        if endInset > 0,path.count >= 2 {
            let a = path[path.count-2],b = path[path.count-1],d = simd_normalize(b-a)
            path[path.count-1] = b-d*min(endInset,simd_distance(a,b)*0.9)
        }
        guard path.count >= 2 else { return nil }
        // Cut the ribbon where the head begins.
        var lengths = [Float(0)]
        for i in 1..<path.count { lengths.append(lengths[i-1]+simd_distance(path[i-1],path[i])) }
        let total = lengths.last!
        guard total > headLength+0.05 else { return nil }
        let cut = total-headLength
        var body = [path[0]]
        for i in 1..<path.count {
            if lengths[i] >= cut {
                let f = (cut-lengths[i-1])/max(1e-5,lengths[i]-lengths[i-1]);body.append(path[i-1]+(path[i]-path[i-1])*f);break
            }
            body.append(path[i])
        }
        let tip = path[path.count-1],base = body[body.count-1]
        let dirEnd = simd_normalize(tip-base)
        var v = [SIMD2<Float>](),idx = [UInt32]()
        // Ribbon: left/right offsets with averaged normals at joints (miter, clamped).
        for i in 0..<body.count {
            let prev = i > 0 ? simd_normalize(body[i]-body[i-1]) : simd_normalize(body[1]-body[0])
            let next = i < body.count-1 ? simd_normalize(body[i+1]-body[i]) : (i > 0 ? (i == body.count-1 ? dirEnd : prev) : prev)
            var t = prev+next;if simd_length(t) < 1e-4 { t = next }
            t = simd_normalize(t)
            let n = SIMD2(-t.y,t.x),miter = min(2,1/max(0.35,simd_dot(n,SIMD2(-prev.y,prev.x))))
            v.append(body[i]+n*(width/2)*miter);v.append(body[i]-n*(width/2)*miter)
        }
        for i in 0..<(body.count-1) {
            let a = UInt32(2*i),b = a+1,c = a+2,d = a+3
            idx += [a,b,c, c,b,d]
        }
        // Head: base across the ribbon end, tip ahead.
        let n = SIMD2(-dirEnd.y,dirEnd.x),h0 = UInt32(v.count)
        v.append(base+n*(headWidth/2));v.append(base-n*(headWidth/2));v.append(tip)
        idx += [h0,h0+1,h0+2]
        return Mesh(vertices:v,indices:idx)
    }
}
