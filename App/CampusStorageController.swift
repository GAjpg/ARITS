import UIKit

final class CampusStorageController:UITableViewController {
    private var usage:[CampusStorageUsage] = []
    private var historyBytes:Int64 = 0,trialBytes:Int64 = 0
    private var busy = false
    init() { super.init(style:.insetGrouped);title = "存储空间" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    private func size(_ bytes:Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);reloadUsage() }
    private func reloadUsage() {
        guard !busy else { return };busy = true;title = "正在统计…"
        let documents = ProbeIO.documents,cache = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first,temporary = FileManager.default.temporaryDirectory
        CampusApp.io.async { [weak self] in
            let usage = CampusStorage.usage(documents:documents,library:CampusApp.library,cache:cache,temporary:temporary)
            let history = CampusApp.library.historyCleanupCandidates().reduce(Int64(0)) { $0+CampusStorage.bytes(at:$1) }
            let trials = CampusStorage.trialCleanupCandidates(documents:documents).reduce(Int64(0)) { $0+CampusStorage.bytes(at:$1) }
            DispatchQueue.main.async {
                guard let self else { return };self.usage = usage;self.historyBytes = history;self.trialBytes = trials;self.busy = false;self.title = "存储空间";self.tableView.reloadData()
            }
        }
    }
    override func numberOfSections(in tableView:UITableView) -> Int { 3 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { section == 0 ? usage.count : section == 1 ? 3 : 1 }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? {
        section == 0 ? "文件占用估计：\(size(usage.reduce(0) { $0+$1.bytes }))" : section == 1 ? "选择清理内容" : "后续路网验证记录"
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        switch section {
        case 0:return "统计应用数据文件，不含安装包；与系统显示可能有差异。当前环境包含路网、ARWorldMap 和参考照片。"
        case 1:return "清理历史保留当前版本和上一个版本。清理记录保留各类最近 3 份已结束记录，未结束记录保留。导出备份需逐个选择删除。"
        default:return "轻量：每 0.5 秒记录位置与锚点，每 30 秒拍一张诊断照，最多 60 张。详细：每 0.1 秒记录，每 8 秒拍照，最多 300 张。跟踪异常、恢复耗时和导航步骤始终记录；设置从下一次路网采集或导航生效，原验证器不受影响。"
        }
    }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        if p.section == 0 { cell.textLabel?.text = usage[p.row].title;cell.detailTextLabel?.text = size(usage[p.row].bytes) }
        else if p.section == 1 {
            cell.textLabel?.text = ["清理旧历史版本","清理旧验证记录","查看导出备份与文件"][p.row]
            cell.detailTextLabel?.text = p.row == 0 ? "预计可清理 \(size(historyBytes))" : p.row == 1 ? "预计可清理 \(size(trialBytes))" : "逐个分享或删除导出的文件"
            cell.accessoryType = .disclosureIndicator
        } else { cell.textLabel?.text = UserDefaults.standard.bool(forKey:"campus.detailedDiagnostics") ? "详细记录" : "轻量记录（默认）";cell.accessoryType = .disclosureIndicator }
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) {
        tableView.deselectRow(at:p,animated:true);guard !busy,p.section != 0 else { return }
        if p.section == 2 {
            campusChoices("后续路网验证记录",choices:[("轻量记录",{ [weak self] in UserDefaults.standard.set(false,forKey:"campus.detailedDiagnostics");self?.tableView.reloadData() }),("详细记录",{ [weak self] in UserDefaults.standard.set(true,forKey:"campus.detailedDiagnostics");self?.tableView.reloadData() })]);return
        }
        if p.row == 2 { navigationController?.pushViewController(CampusExportFilesController(),animated:true);return }
        let history = p.row == 0,bytes = history ? historyBytes : trialBytes
        let alert = UIAlertController(title:history ? "清理旧历史版本？" : "清理旧验证记录？",message:"预计释放 \(size(bytes))。\n"+(history ? "保留当前环境和上一个版本，导出备份保留。" : "保留各类最近 3 份已结束记录及所有未结束记录，当前环境和导出备份保留。"),preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"取消",style:.cancel))
        alert.addAction(UIAlertAction(title:"清理",style:.destructive) { [weak self] _ in
            guard let self else { return };self.busy = true;self.title = "正在清理…"
            CampusApp.io.async {
                let result = Result { if history { return try CampusApp.library.pruneHistory() };return try CampusStorage.pruneTrials(documents:ProbeIO.documents) }
                DispatchQueue.main.async {
                    self.busy = false;self.reloadUsage()
                    switch result { case .success(let count):self.campusMessage("清理完成","已清理 \(count) 项。");case .failure(let error):self.campusError(error) }
                }
            }
        });present(alert,animated:true)
    }
}

private final class CampusExportFilesController:UITableViewController {
    private var files:[URL] = []
    init() { super.init(style:.insetGrouped);title = "导出备份与文件" }
    required init?(coder:NSCoder) { fatalError("init(coder:)") }
    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        files = ["Exports","PreviewExports"].flatMap { name in
            ((try? FileManager.default.contentsOfDirectory(at:ProbeIO.documents.appendingPathComponent(name),includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey])) ?? []).filter {
                guard let attrs = try? $0.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { return false }
                return attrs.isRegularFile == true && attrs.isSymbolicLink != true
            }
        }.sorted { $0.lastPathComponent > $1.lastPathComponent };tableView.reloadData()
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { files.count }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? { "点击分享文件；向左滑动可删除这份导出文件。删除备份前，确认需要保留的副本已保存到其他位置。" }
    override func tableView(_ tableView:UITableView,cellForRowAt p:IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil),file = files[p.row]
        cell.textLabel?.text = file.lastPathComponent;cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount:CampusStorage.bytes(at:file),countStyle:.file);cell.accessoryType = .disclosureIndicator;return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt p:IndexPath) { tableView.deselectRow(at:p,animated:true);campusShare(files[p.row]) }
    override func tableView(_ tableView:UITableView,trailingSwipeActionsConfigurationForRowAt p:IndexPath) -> UISwipeActionsConfiguration? {
        let file = files[p.row],action = UIContextualAction(style:.destructive,title:"删除") { [weak self] _,_,completion in
            guard let self else { completion(false);return }
            let alert = UIAlertController(title:"删除这份导出文件？",message:file.lastPathComponent+"\n当前使用的路网与环境保留。",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"取消",style:.cancel) { _ in completion(false) })
            alert.addAction(UIAlertAction(title:"删除文件",style:.destructive) { _ in
                do { try FileManager.default.removeItem(at:file);self.files.removeAll { $0 == file };self.tableView.reloadData();completion(true) }
                catch { completion(false);self.campusError(error) }
            });self.present(alert,animated:true)
        };let config = UISwipeActionsConfiguration(actions:[action]);config.performsFirstActionWithFullSwipe = false;return config
    }
}
