#if !targetEnvironment(macCatalyst)
import UIKit
import ARKit

struct PhotoCalibrationShot {
    let geometry: PhotoGroundGeometry
    let timestamp: TimeInterval
    let identity: PhotoRequestIdentity
    let planeID: String

    init(frame: ARFrame, plane: ARPlaneAnchor, identity: PhotoRequestIdentity) {
        let k = frame.camera.intrinsics, size = frame.camera.imageResolution
        geometry = PhotoGroundGeometry(width: Double(size.width), height: Double(size.height),
            fx: Double(k.columns.0.x), fy: Double(k.columns.1.y), cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
            cameraToSession: matrixRows(frame.camera.transform), planeToSession: matrixRows(plane.transform),
            boundaryXZ: plane.geometry.boundaryVertices.map { [Double($0.x), Double($0.z)] })
        timestamp = frame.timestamp; self.identity = identity; planeID = plane.identifier.uuidString
    }
    var metadata: [String: Any] {
        ["source": "same_ARFrame_horizontal_plane_snapshot", "plane_id": planeID,
         "plane_to_session": geometry.planeToSession, "boundary_xz_m": geometry.boundaryXZ,
         "tracking_epoch": identity.trackingEpoch, "route_revision_at_capture": identity.routeRevision,
         "manual_floor_confirmation": true, "depth_used": false,
         "preview_rotation_deg_clockwise": 90, "preview_is_mirrored": false]
    }
}

// The editor only displays the frozen JPEG. ARSession keeps running underneath.
final class PhotoPointPicker: UIViewController {
    private let shot: PhotoCalibrationShot
    private let jpeg: Data
    private let imageView = UIImageView()
    private let message = UILabel()
    private let nextButton = UIButton(type: .system)
    private let delayControl = UISegmentedControl(items: ["0 秒", "1 秒", "3 秒", "5 秒"])
    private var pixels: [[Double]] = []
    private var markerViews: [UILabel] = []
    var submitted: (([[Double]], Double) -> Void)?
    var cancelled: (() -> Void)?

    init(jpeg: Data, shot: PhotoCalibrationShot) {
        self.jpeg = jpeg; self.shot = shot
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.10, alpha: 1)
        let title = UILabel(); title.text = "在照片上选择 A、B"; title.textColor = .white
        title.font = .systemFont(ofSize: 22, weight: .bold)
        message.text = "先点地面上的 A，再点前方 B（相隔至少 0.5 米）。选点代表模型输出；当前没有识别模型。"
        message.textColor = .lightGray; message.numberOfLines = 0; message.font = .systemFont(ofSize: 14)
        let header = UIStackView(arrangedSubviews: [title, message]); header.axis = .vertical; header.spacing = 8
        if let cg = UIImage(data: jpeg)?.cgImage { imageView.image = UIImage(cgImage: cg, scale: 1, orientation: .right) }
        imageView.contentMode = .scaleAspectFit; imageView.clipsToBounds = true; imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        imageView.backgroundColor = .black
        delayControl.selectedSegmentIndex = 2; delayControl.selectedSegmentTintColor = .systemMint
        delayControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        delayControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        let explanation = UILabel(); explanation.text = "额外返回延迟：确认后回到相机，在这段时间内移动或转动手机。"
        explanation.numberOfLines = 0; explanation.textColor = .lightGray; explanation.font = .systemFont(ofSize: 13)
        nextButton.configuration = .filled(); nextButton.configuration?.title = "返回相机并开始延迟"
        nextButton.configuration?.baseBackgroundColor = .systemMint; nextButton.configuration?.baseForegroundColor = .black
        nextButton.isEnabled = false; nextButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        let reset = UIButton(type: .system); reset.setTitle("重新选点", for: .normal)
        reset.addTarget(self, action: #selector(resetPoints), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelPicker), for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [reset, cancel]); row.distribution = .fillEqually
        let footer = UIStackView(arrangedSubviews: [explanation, delayControl, nextButton, row]); footer.axis = .vertical; footer.spacing = 10
        for item in [header, imageView, footer] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46), delayControl.heightAnchor.constraint(equalToConstant: 36),
            imageView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), imageView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
    }

    private var photoRect: CGRect {
        let size = CGSize(width: shot.geometry.height, height: shot.geometry.width)
        let scale = min(imageView.bounds.width / size.width, imageView.bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (imageView.bounds.width - width) / 2, y: (imageView.bounds.height - height) / 2, width: width, height: height)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layoutMarkers() }
    private func layoutMarkers() {
        let rect = photoRect
        for (i, marker) in markerViews.enumerated() {
            let p = PhotoGeometry.portraitPoint(raw: pixels[i], width: shot.geometry.width, height: shot.geometry.height)
            marker.frame = CGRect(x: rect.minX + p[0] * rect.width - 15, y: rect.minY + p[1] * rect.height - 15, width: 30, height: 30)
        }
    }
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard pixels.count < 2 else { return }
        let point = tap.location(in: imageView), rect = photoRect
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { message.text = "请点在照片内，黑边不属于照片。"; return }
        let pixel = PhotoGeometry.rawPoint(portrait: [Double((point.x - rect.minX) / rect.width), Double((point.y - rect.minY) / rect.height)],
                                          width: shot.geometry.width, height: shot.geometry.height)
        do {
            let world = try PhotoGeometry.floorPoint(rawPixel: pixel, geometry: shot.geometry)
            if let first = pixels.first {
                let origin = try PhotoGeometry.floorPoint(rawPixel: first, geometry: shot.geometry)
                guard PhotoGeometry.horizontalDistance(origin, world) >= 0.5 else { throw PhotoGeometryError.pointsTooClose }
            }
            pixels.append(pixel)
            let marker = UILabel(); marker.text = pixels.count == 1 ? "A" : "B"; marker.textAlignment = .center
            marker.font = .systemFont(ofSize: 16, weight: .bold); marker.textColor = .black
            marker.backgroundColor = pixels.count == 1 ? .systemCyan : .systemYellow
            marker.layer.cornerRadius = 15; marker.clipsToBounds = true; imageView.addSubview(marker); markerViews.append(marker)
            layoutMarkers()
            if pixels.count == 2 {
                let a = try PhotoGeometry.floorPoint(rawPixel: pixels[0], geometry: shot.geometry)
                message.text = String(format: "A、B 已选，地面估计间距 %.2f 米。请选择延迟，再返回相机。", PhotoGeometry.horizontalDistance(a, world))
                nextButton.isEnabled = true
            } else { message.text = "A 已选。请点同一地面上的前方 B。" }
        } catch { message.text = error.localizedDescription }
    }
    @objc private func resetPoints() {
        pixels = []; markerViews.forEach { $0.removeFromSuperview() }; markerViews = []
        nextButton.isEnabled = false; message.text = "先点地面 A，再点前方 B。请确认两点都在真实地板上。"
    }
    @objc private func submit() {
        guard pixels.count == 2 else { return }
        let delay = [0.0, 1, 3, 5][delayControl.selectedSegmentIndex]
        let selection = pixels, callback = submitted
        dismiss(animated: true) { callback?(selection, delay) }
    }
    @objc private func cancelPicker() {
        let callback = cancelled
        dismiss(animated: true) { callback?() }
    }
}
#endif
