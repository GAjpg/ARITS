#if !targetEnvironment(macCatalyst)
import UIKit
import ARKit
import RealityKit

enum CampusFeatureDisplay:Int,CaseIterable {
    case off,live,saved,both
    var title:String { ["关闭","当前画面特征点","已保存地图特征点","两种点同时显示"][rawValue] }
    var showsLive:Bool { self == .live || self == .both }
    var showsSaved:Bool { self == .saved || self == .both }
}

final class CampusFeatureOverlay:UIView {
    private var dots:[CGPoint] = []
    var message = "" { didSet { caption.text = message;caption.isHidden = message.isEmpty } }
    private let caption = UILabel()
    override init(frame:CGRect) {
        super.init(frame:frame);isUserInteractionEnabled = false;backgroundColor = .clear
        caption.numberOfLines = 0;caption.textColor = .white;caption.font = .systemFont(ofSize:12,weight:.medium)
        caption.backgroundColor = UIColor.black.withAlphaComponent(0.65);caption.layer.cornerRadius = 6;caption.clipsToBounds = true
        caption.translatesAutoresizingMaskIntoConstraints = false;addSubview(caption)
        NSLayoutConstraint.activate([caption.centerXAnchor.constraint(equalTo:centerXAnchor),caption.centerYAnchor.constraint(equalTo:centerYAnchor,constant:80),caption.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-40)])
        accessibilityLabel = "已保存特征点显示"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    func clear() { dots.removeAll(keepingCapacity:true);setNeedsDisplay() }
    func update(cloud:CampusFeaturePointCloud,transform:simd_float4x4,frame:ARFrame,view:ARView) {
        let inverse = simd_inverse(frame.camera.transform)
        var visible:[CGPoint] = [];visible.reserveCapacity(1500)
        // Bound work independently of the saved map's size. No entity per point.
        let stride = max(1,Int(ceil(Double(cloud.points.count)/4000)))
        for i in Swift.stride(from:0,to:cloud.points.count,by:stride) {
            let p = cloud.points[i],world = transform*SIMD4(Float(p.x),Float(p.y),Float(p.z),1)
            let camera = inverse*world
            guard camera.z < -0.1,simd_length(SIMD3(camera.x,camera.y,camera.z)) <= 15,
                  let projected = view.project(SIMD3(world.x,world.y,world.z)),view.bounds.contains(projected) else { continue }
            visible.append(convert(projected,from:view));if visible.count == 1500 { break }
        }
        dots = visible;setNeedsDisplay()
        message = "橙色：已保存地图点 · 15 米内示意 \(dots.count) 点\n可能透过物体显示；点数不代表恢复成功率。"
    }
    override func draw(_ rect:CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.85).cgColor)
        for p in dots { context.fillEllipse(in:CGRect(x:p.x-1.8,y:p.y-1.8,width:3.6,height:3.6)) }
    }
}
#endif

// A lightweight screen-space overlay shared by LiDAR capture and layout previews.
// It never allocates RealityKit entities for individual points.
import UIKit

final class LiDARPointOverlay:UIView {
    struct Dot { let point:CGPoint;let color:UIColor }
    private var dots = [Dot]()
    private let caption = UILabel()
    override init(frame:CGRect) {
        super.init(frame:frame);isUserInteractionEnabled = false;backgroundColor = .clear
        caption.numberOfLines = 0;caption.textColor = .white;caption.font = .systemFont(ofSize:12,weight:.medium)
        caption.backgroundColor = UIColor.black.withAlphaComponent(0.68);caption.layer.cornerRadius = 6;caption.clipsToBounds = true
        caption.translatesAutoresizingMaskIntoConstraints = false;addSubview(caption)
        NSLayoutConstraint.activate([caption.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor,constant:8),caption.leadingAnchor.constraint(equalTo:leadingAnchor,constant:16),caption.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,constant:-16)])
        accessibilityLabel = "点云叠加预览"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    func update(_ values:[Dot],message:String) {
        dots = Array(values.prefix(1500));caption.text = message;caption.isHidden = message.isEmpty;setNeedsDisplay()
    }
    func clear() { dots.removeAll(keepingCapacity:true);caption.text = nil;setNeedsDisplay() }
    override func draw(_ rect:CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for dot in dots {
            context.setFillColor(dot.color.withAlphaComponent(0.85).cgColor)
            context.fillEllipse(in:CGRect(x:dot.point.x-1.6,y:dot.point.y-1.6,width:3.2,height:3.2))
        }
    }
}

#if DEBUG
/// Synthetic screen points for layout checks; never represented as AR capture or alignment evidence.
final class LiDAROverlayLayoutPreviewController:UIViewController {
    private let overlay = LiDARPointOverlay()
    override func viewDidLoad() {
        super.viewDidLoad();title = "点云叠加 · 界面示例";view.backgroundColor = .darkGray
        view.addSubview(overlay)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews();overlay.frame = view.bounds
        let colors:[UIColor] = [.systemGreen,.systemRed,.systemGray,.systemOrange]
        var dots = [LiDARPointOverlay.Dot]()
        for column in 0..<4 { for row in 0..<20 {
            dots.append(.init(point:CGPoint(x:view.bounds.width*CGFloat(column+1)/5,y:200+CGFloat(row)*14),color:colors[column]))
        } }
        overlay.update(dots,message:"合成点，仅检查布局，未开启相机\n绿：贴合 · 红：表面前方冲突\n灰：遮挡或深度未知 · 橙：隔离帧")
    }
}
#endif
