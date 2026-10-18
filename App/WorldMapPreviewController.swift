#if !targetEnvironment(macCatalyst)
import UIKit

final class WorldMapPreviewController: UIViewController {
    private let package: SavedWorldMap
    var loadRequested: (() -> Void)?
    var closed: (() -> Void)?
    init(package: SavedWorldMap) { self.package = package; super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.1, alpha: 1)
        let title = UILabel(); title.text = package.metadata.name; title.font = .systemFont(ofSize: 22, weight: .bold); title.textColor = .white; title.numberOfLines = 2
        let text = UILabel(); text.text = "回到照片中的同一片环境。加载后缓慢扫描地面和两侧固定物体。\n不需要重新设 A、B；恢复后核对原标记。最长等待 60 秒，会自动开始测试记录。"
        text.numberOfLines = 0; text.textColor = .lightGray; text.font = .systemFont(ofSize: 14)
        let image = UIImageView(); image.contentMode = .scaleAspectFit
        if let cg = UIImage(contentsOfFile: package.directory.appendingPathComponent("reference.jpg").path)?.cgImage {
            image.image = UIImage(cgImage: cg, scale: 1, orientation: .right)
        }
        let load = UIButton(type: .system); load.configuration = .filled(); load.configuration?.title = "加载地图并开始恢复测试"
        load.configuration?.baseBackgroundColor = .systemMint; load.configuration?.baseForegroundColor = .black
        load.addTarget(self, action: #selector(startLoading), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("返回", for: .normal); cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, text]); header.axis = .vertical; header.spacing = 12
        let footer = UIStackView(arrangedSubviews: [load, cancel]); footer.axis = .vertical; footer.spacing = 12
        for item in [header, image, footer] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            image.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), image.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8), load.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])
    }
    @objc private func startLoading() { let callback = loadRequested; dismiss(animated: true) { callback?() } }
    @objc private func close() { let callback = closed; dismiss(animated: true) { callback?() } }
}
#endif
