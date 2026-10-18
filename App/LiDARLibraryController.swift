import UIKit
import UniformTypeIdentifiers

enum LiDARLibrary {
    static let root = ProbeIO.documents.appendingPathComponent("GeometryTrials",isDirectory:true)
    static let queue = DispatchQueue(label:"lidar.library.io",qos:.userInitiated)
    static func scans() -> [(URL,LiDARScanManifest)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf:url.appendingPathComponent("scan.json")),
                  let manifest = try? JSONDecoder().decode(LiDARScanManifest.self,from:data) else { return nil }
            return (url,manifest)
        }.sorted { $0.1.created_utc > $1.1.created_utc }
    }
}

final class LiDARLibraryController: UITableViewController, UIDocumentPickerDelegate {
    private let graph: CampusGraph?
    private let regionID: String?
    private var scans: [(URL,LiDARScanManifest)] = []
    private var busy = false
    init(graph:CampusGraph? = nil,regionID:String? = nil) {
        self.graph = graph; self.regionID = regionID; super.init(style:.insetGrouped)
        title = "原始扫描记录"
    }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title:"导入",style:.plain,target:self,action:#selector(importScan))
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated); reload() }
    private func reload() {
        scans = LiDARLibrary.scans().filter { regionID == nil || $0.1.region_id == regionID }; tableView.reloadData()
    }
    override func numberOfSections(in tableView:UITableView) -> Int { 2 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { section == 0 ? 3 : scans.count }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? {
        section == 0 ? (graph?.region(regionID ?? "")?.name ?? "快速验证区域") : "扫描记录 · 点击查看和导出"
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == 0 ? "先建图，再分别从多个位置做独立查询。查询会重新启动 AR 会话，使用相同环境名称不会加载旧 ARWorldMap。建图与查询坐标独立；本阶段在 Mac 上验证能否找回位置。" : "LiDAR 记录单独导出，不包含在原路网环境备份中。地图最多 100 帧，查询最多 24 帧；不自动上传。"
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style:.subtitle,reuseIdentifier:nil); c.detailTextLabel?.numberOfLines = 0
        if p.section == 0 {
            c.textLabel?.text = ["① 建图扫描","② 独立查询扫描","验证方法与注意事项"][p.row]
            c.detailTextLabel?.text = ["缓慢扫描一个有转角或门框的小区域，建议 20–45 秒","站在不同位置扫描 5–10 秒，每次重新开始","至少 5 次查询，加 2 次地图外查询；明暗不同也要测"][p.row]
        } else {
            let m = scans[p.row].1; c.textLabel?.text = "\(m.role.title) · \(m.label)"
            c.detailTextLabel?.text = "\(m.region_name) · \(m.lighting) · \(m.frames.count) 帧 · \(m.state == "complete" ? "已完成" : "未完成 / 中断")\n\(m.created_utc)"
        }
        c.accessoryType = .disclosureIndicator; return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true); guard !busy else { return }
        if p.section == 1 { detail(scans[p.row]); return }
        if p.row == 2 {
            campusMessage("第一阶段怎么测", "1. 在转角 / 活动室建一张小几何图，扫描墙角、门框、家具等稳定结构。\n2. 结束后从不同位置开启查询；地图外也做查询，名称加“地图外”。\n3. 查询时不要只拍地面、白墙或远处；让 0.2–4.5 米内的多面结构进入画面。\n4. 每份记录导出 ZIP 到 Mac，运行 Tools/lidar_validate.py 配准。\n\n本阶段不训练模型，不恢复 ARWorldMap，不把几何坐标自动绑定到原路网。点多、配准残差小，都不等于定位正确。")
        } else { prepare(p.row == 0 ? .map : .query) }
    }
    private func prepare(_ role:LiDARScanRole) {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard LiDARCaptureController.supported else { campusMessage("需要支持 LiDAR 的设备","请在 iPhone 15 Pro 等支持 sceneDepth 的真机上运行。Mac 可查看、导入和导出记录。"); return }
        campusText(role == .map ? "建图名称" : "查询位置备注",placeholder:role == .map ? "例如：活动室转角" : "例如：东门内侧 / 地图外") { [weak self] name in
            guard let self else { return }
            self.campusChoices("本次光照",choices:CampusLighting.allCases.map { light in
                (light.title, { [weak self] in self?.start(role,label:name,lighting:light) })
            })
        }
        #else
        campusMessage("需要真机采集","Mac 可管理记录，深度采集请在支持 LiDAR 的 iPhone 上进行。")
        #endif
    }
    #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
    private func start(_ role:LiDARScanRole,label:String,lighting:CampusLighting) {
        let m = LiDARScanManifest(role:role,label:label,buildingID:graph?.building_id ?? "standalone",
            regionID:regionID ?? "standalone",regionName:graph?.region(regionID ?? "")?.name ?? "快速验证区域",
            lighting:lighting.rawValue,hardware:ProbeIO.hardwareIdentifier(),
            appVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown")
        let c = LiDARCaptureController(manifest:m)
        c.onSaved = { [weak self] in self?.reload() }
        let nav = UINavigationController(rootViewController:c); nav.modalPresentationStyle = .fullScreen
        present(nav,animated:true)
    }
    #endif
    private func detail(_ scan:(URL,LiDARScanManifest)) {
        let (url,m) = scan
        let hasNavigation = FileManager.default.fileExists(atPath:url.appendingPathComponent("navigation.json").path)
        let bytes = (try? FileManager.default.subpathsOfDirectory(atPath:url.path))?.reduce(Int64(0)) { count,path in
            count + ((try? FileManager.default.attributesOfItem(atPath:url.appendingPathComponent(path).path)[.size] as? NSNumber)?.int64Value ?? 0)
        } ?? 0
        campusChoices(m.label,message:"\(m.role.title) · \(m.frames.count) 帧\n\(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file))\n状态：\(m.state)\n结束原因：\(m.end_reason ?? "尚未正常结束")\n独立会话：未加载 ARWorldMap\n环境名只用于分组，坐标未绑定原路网。",choices:[
            ("导出深度、照片与点云 ZIP",{ [weak self] in self?.export(url) }),
            (hasNavigation ? "清理原始扫描，保留导航地图" : "删除这份扫描",{ [weak self] in
                guard let self else { return }
                let a = UIAlertController(title:hasNavigation ? "清理原始扫描？" : "删除扫描？",message:hasNavigation ? "删除深度、逐帧照片和诊断扫描，保留导航几何、参考照片和路线。需要原始数据请先导出。" : "请先导出需要保留的验证数据。",preferredStyle:.alert)
                a.addAction(UIAlertAction(title:"取消",style:.cancel))
                a.addAction(UIAlertAction(title:"删除",style:.destructive) { _ in
                    do {
                        if hasNavigation { try LiDARNavigationArchive.removeRawScanData(in:url) }
                        else { try FileManager.default.removeItem(at:url) }
                        self.reload()
                    } catch { self.campusError(error) }
                }); self.present(a,animated:true)
            })])
    }
    private func export(_ url:URL) {
        busy = true;title = "正在打包…"
        LiDARLibrary.queue.async { [weak self] in
            let result = Result { () -> URL in
                try ProbeIO.makeManifest(at:url)
                let zip = ProbeIO.documents.appendingPathComponent("Exports/lidar-\(url.lastPathComponent).zip")
                try ProbeZip.create(directory:url,destination:zip);return zip
            }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;self.title = "原始扫描记录"
                switch result { case .success(let zip):self.campusShare(zip);case .failure(let e):self.campusError(e) }
            }
        }
    }
    @objc private func importScan() {
        guard !busy else { return }; let p = UIDocumentPickerViewController(forOpeningContentTypes:[.zip],asCopy:true)
        p.delegate = self;present(p,animated:true)
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let url = urls.first,!busy else { return };busy = true
        let scoped = url.startAccessingSecurityScopedResource()
        LiDARLibrary.queue.async { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lidar-import-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:temp) }
            let result = Result { () -> Void in
                let source = try CampusBackupZIP.extract(url,to:temp)
                try CampusFiles.verify(source)
                let data = try Data(contentsOf:source.appendingPathComponent("scan.json"))
                let m = try JSONDecoder().decode(LiDARScanManifest.self,from:data);try m.validate()
                try FileManager.default.createDirectory(at:LiDARLibrary.root,withIntermediateDirectories:true)
                let target = LiDARLibrary.root.appendingPathComponent("\(m.role.rawValue)-\(m.scan_id)")
                guard !FileManager.default.fileExists(atPath:target.path) else { throw LiDARScanError.invalid("这份记录已经存在，未重复导入。") }
                try FileManager.default.moveItem(at:source,to:target)
            }
            DispatchQueue.main.async { guard let self else { return };self.busy = false;self.reload()
                if case .failure(let e) = result { self.campusError(e) }
            }
        }
    }
}
