import UIKit
import UniformTypeIdentifiers

/// Whole-file campus data management. Entry belongs exclusively to settings/building tools.
final class CampusMapDataController:UIViewController,UIDocumentPickerDelegate {
    private let storage:OutdoorCampusStorage
    private let content = UIStackView()
    private var selection:OutdoorCampusStorage.Selection?,previousAvailable = false,busy = false,problem:String?
    private var readID = UUID()
    init(directory:URL = ProbeIO.documents.appendingPathComponent("CampusMap",isDirectory:true)) {
        storage = OutdoorCampusStorage(directory:directory);super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = WayfindingPalette.ground
        let back = UIButton(type:.system);Style.round(back,symbol:"chevron.left",label:"返回");back.addTarget(self,action:#selector(close),for:.touchUpInside)
        let heading = label("校园地图数据",size:24,weight:.heavy)
        let header = UIStackView(arrangedSubviews:[back,heading]);header.spacing = 12;header.alignment = .center
        let scroll = UIScrollView();scroll.alwaysBounceVertical = true;content.axis = .vertical;content.spacing = 16
        for v in [header,scroll] { v.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(v) }
        content.translatesAutoresizingMaskIntoConstraints = false;scroll.addSubview(content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:16),header.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-16),header.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),
            scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:18),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            content.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:4),content.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-28),content.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:16),content.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-16),content.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-32)])
        reload()
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);navigationController?.setNavigationBarHidden(true,animated:false) }
    @objc private func close() { if navigationController?.viewControllers.first === self { dismiss(animated:true) } else { navigationController?.popViewController(animated:true) } }
    private func label(_ text:String,size:CGFloat = 14,weight:UIFont.Weight = .regular) -> UILabel {
        let l = UILabel();l.text = text;l.numberOfLines = 0;l.font = .systemFont(ofSize:size,weight:weight);l.textColor = size>=17 ? WayfindingPalette.ink:WayfindingPalette.secondary;return l
    }
    private func card(_ views:[UIView]) -> UIView {
        let card = UIView();Style.float(card,radius:22);let stack = UIStackView(arrangedSubviews:views);stack.axis = .vertical;stack.spacing = 16;stack.translatesAutoresizingMaskIntoConstraints = false;card.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:card.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-20)]);return card
    }
    private func render() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0);$0.removeFromSuperview() }
        content.addArrangedSubview(label("在工作台编辑校园地图，再导入手机。楼栋、步道和名称会一起更新。"))
        if let s = selection {
            content.addArrangedSubview(card([label(s.isCustom ? "正在使用自定义地图":"正在使用内置地图",size:22,weight:.heavy),label(s.campus.name,size:17,weight:.bold),label("\(s.campus.buildings.count) 栋楼 · \(s.campus.graph.nodes.count) 个步行路网点\n"+version(s.data))]))
            if let warning = s.warning { content.addArrangedSubview(card([label(warning)])) }
        }
        if let problem { content.addArrangedSubview(card([label(problem)])) }
        let action:((() -> Void)?) -> (() -> Void)? = { self.busy ? nil:$0 }
        content.addArrangedSubview(card([
            ResultRow(title:"导入 campus.json",detail:busy ? "处理中…":"替换当前地图",action:action({ [weak self] in self?.pick() })),
            ResultRow(title:"导出当前地图",detail:"继续在工作台编辑",action:selection == nil ? nil:action({ [weak self] in self?.export() }),separator:true),
            ResultRow(title:"恢复上一版",detail:previousAvailable ? "保留当前版本作备份":"暂无上一版",action:previousAvailable ? action({ [weak self] in self?.confirmRestore() }):nil,separator:true)]))
        content.addArrangedSubview(label("导入前会检查楼栋轮廓、门口索引和步行路网连通性。更新后重新打开校园地图生效；已打开的行程保留原地图。"))
        content.addArrangedSubview(label("楼栋和门口的绑定仍在建图工具中管理。合并、删除或拆分楼栋后，请核实相关绑定。"))
    }
    private func version(_ data:Data) -> String {
        let root = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],meta = root?["meta"] as? [String:Any]
        var pieces = ["完整地图 · \(ByteCountFormatter.string(fromByteCount:Int64(data.count),countStyle:.file))"]
        if let n = meta?["version"] as? Int { pieces.append("版本 \(n)") }
        return pieces.joined(separator:" · ")
    }
    private func reload() {
        busy = true;render();let id = UUID();readID = id
        LiDARNavigationStore.queue.async { [weak self] in
            guard let self else { return };let result = Result { try self.storage.current(bundled:OutdoorCampusStorage.packagedData()) },previous = self.storage.previous() != nil
            DispatchQueue.main.async {
                guard self.readID == id else { return };self.busy = false;self.previousAvailable = previous
                switch result { case .success(let value):self.selection = value;self.problem = nil;case .failure(let error):self.problem = error.localizedDescription }
                self.render()
            }
        }
    }
    private func pick() { let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.json],asCopy:false);picker.delegate = self;present(picker,animated:true) }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let url = urls.first,!busy else { return };busy = true;render()
        LiDARNavigationStore.queue.async { [weak self] in
            guard let self else { return };let scoped = url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> (Data,OutdoorCampus) in
                let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size<=32*1024*1024 else { throw OutdoorCampusError.invalid("文件超过32MB，请先在工作台检查") }
                let data = try Data(contentsOf:url);return (data,try OutdoorCampusStorage.validateImport(data))
            }
            DispatchQueue.main.async {
                self.busy = false;self.render()
                switch result { case .failure(let error):self.campusError(error)
                case .success(let (data,campus)):
                    let removed = Set(self.selection?.campus.buildings.map(\.id) ?? []).subtracting(campus.buildings.map(\.id)).count
                    var text = "\(campus.buildings.count) 栋楼 · \(campus.graph.nodes.count) 个路网点。当前地图会保留为上一版。"
                    if removed>0 { text += "\n有 \(removed) 个原楼栋编号不再存在，请在建图工具中核实相关绑定。" }
                    let alert = UIAlertController(title:"使用这份校园地图？",message:text,preferredStyle:.alert)
                    alert.addAction(UIAlertAction(title:"取消",style:.cancel));alert.addAction(UIAlertAction(title:"导入",style:.default) { [weak self] _ in self?.perform { try self?.storage.install(data,bundled:OutdoorCampusStorage.packagedData()) } });self.present(alert,animated:true)
                }
            }
        }
    }
    private func perform(_ operation:@escaping () throws -> Void) {
        guard !busy else { return };busy = true;render()
        LiDARNavigationStore.queue.async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async { guard let self else { return };self.busy = false
                if case .failure(let error) = result { self.campusError(error) };self.reload()
            }
        }
    }
    private func confirmRestore() {
        let alert = UIAlertController(title:"恢复上一版地图？",message:"当前地图也会保留，可再次恢复。重新打开校园地图后生效。",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"取消",style:.cancel));alert.addAction(UIAlertAction(title:"恢复",style:.default) { [weak self] _ in guard let self else { return };self.perform { try self.storage.restore(bundled:OutdoorCampusStorage.packagedData()) } });present(alert,animated:true)
    }
    private func export() {
        guard !busy else { return };busy = true;render()
        LiDARNavigationStore.queue.async { [weak self] in
            guard let self else { return };let result = Result { () throws -> URL in
                let data = try self.storage.current(bundled:OutdoorCampusStorage.packagedData()).data
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("campus-export-"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);let url = dir.appendingPathComponent("campus.json");try data.write(to:url,options:.atomic);return url
            }
            DispatchQueue.main.async { self.busy = false;self.render();switch result { case .success(let url):self.campusShare(url);case .failure(let error):self.campusError(error) } }
        }
    }
}
