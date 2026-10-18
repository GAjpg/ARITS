import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
func waitUntil(_ finished: () -> Bool) {
    let limit = Date().addingTimeInterval(10)
    while !finished(), Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    require(finished(), "异步记录在期限内结束")
}

let base = FileManager.default.temporaryDirectory.appendingPathComponent("ARProbe-recorder-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: base) }
let recorder = try RunRecorder(sessionID: "session-test", configuration: [:], device: ["synthetic_test_fixture": true], rootDirectory: base)
let id = "frame-test"
let metadata: [String: Any] = ["run_id": recorder.runID, "session_id": "session-test", "frame_id": id,
                             "image": ["path": "frames/\(id).jpg"]]
let bytes = Data("synthetic data; not a real AR image".utf8)
var committed = false
recorder.commit(image: bytes, frame: metadata, frameID: id) { result in
    if case .failure(let error) = result { fputs("\(error)\n", stderr); exit(1) }
    committed = true
}
waitUntil { committed }
let savedBytes = try Data(contentsOf: recorder.directory.appendingPathComponent("frames/\(id).jpg"))
require(savedBytes == bytes, "图片提交字节完整")
require(FileManager.default.fileExists(atPath: recorder.directory.appendingPathComponent("frames/\(id).json").path), "图片与元数据配对提交")
var finished = false
recorder.finish(statistics: [:]) { result in
    if case .failure(let error) = result { fputs("\(error)\n", stderr); exit(1) }
    finished = true
}
waitUntil { finished }
let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: recorder.directory.appendingPathComponent("summary.json"))) as! [String: Any]
require(summary["captured_frames"] as? Int == 1, "只统计完整提交的样本")
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: recorder.directory.appendingPathComponent("files.json"))) as! [String: Any]
let files = manifest["files"] as! [[String: Any]]
require(files.contains { $0["path"] as? String == "frames/frame-test.jpg" && ($0["sha256"] as? String)?.count == 64 }, "导出清单包含真实大小与 SHA256")
var rejected = false
recorder.commit(image: bytes, frame: metadata, frameID: id) { result in
    if case .failure = result { rejected = true }
}
waitUntil { rejected }
require(rejected, "结束后拒绝晚到样本")
let second = try RunRecorder(sessionID: "session-new", configuration: [:], device: ["synthetic_test_fixture": true], rootDirectory: base)
var wrongSessionRejected = false
second.commit(image: bytes, frame: metadata, frameID: id) { result in
    if case .failure = result { wrongSessionRejected = true }
}
waitUntil { wrongSessionRejected }
require(!FileManager.default.fileExists(atPath: second.directory.appendingPathComponent("frames/\(id).jpg").path), "跨会话样本不会写入新记录")
let preview = try RunRecorder(sessionID: "preview-session", configuration: [:], device: ["platform": "macOS_Mac_Catalyst"], rootDirectory: base, dataMode: .simulation)
var previewFrame: [String: Any] = ["run_id": preview.runID, "session_id": "preview-session", "frame_id": id,
                                 "data_kind": "simulation", "is_real_ar_capture": false,
                                 "image": ["path": "frames/\(id).jpg"], "validity": ["ready_for_ar_alignment": false]]
var previewCommitted = false
preview.commit(image: bytes, frame: previewFrame, frameID: id) { result in
    if case .success = result { previewCommitted = true }
}
waitUntil { previewCommitted }
var previewFinished = false
preview.finish(statistics: [:]) { result in if case .success = result { previewFinished = true } }
waitUntil { previewFinished }
let previewRun = try JSONSerialization.jsonObject(with: Data(contentsOf: preview.directory.appendingPathComponent("run.json"))) as! [String: Any]
let previewSummary = try JSONSerialization.jsonObject(with: Data(contentsOf: preview.directory.appendingPathComponent("summary.json"))) as! [String: Any]
require(preview.runID.hasPrefix("preview-run-") && previewRun["is_real_ar_capture"] as? Bool == false,
        "模拟记录采用独立前缀并明确标记非实拍")
require(previewSummary["field_validation"] as? String == "not_applicable_simulation", "模拟记录不声称真实现场验收")
let invalidPreview = try RunRecorder(sessionID: "invalid-preview", configuration: [:], device: [:], rootDirectory: base, dataMode: .simulation)
previewFrame["run_id"] = invalidPreview.runID; previewFrame["session_id"] = "invalid-preview"
previewFrame["validity"] = ["ready_for_visual_localization_query": true]
var badSimulationRejected = false
invalidPreview.commit(image: bytes, frame: previewFrame, frameID: id) { result in if case .failure = result { badSimulationRejected = true } }
waitUntil { badSimulationRejected }
require(!FileManager.default.fileExists(atPath: invalidPreview.directory.appendingPathComponent("frames/\(id).jpg").path), "拒绝声称可用于定位的模拟样本")
let realOnly = try RunRecorder(sessionID: "real-only", configuration: [:], device: [:], rootDirectory: base)
previewFrame["run_id"] = realOnly.runID; previewFrame["session_id"] = "real-only"
previewFrame["validity"] = [:]
var mixedModeRejected = false
realOnly.commit(image: bytes, frame: previewFrame, frameID: id) { result in if case .failure = result { mixedModeRejected = true } }
waitUntil { mixedModeRejected }
require(!FileManager.default.fileExists(atPath: realOnly.directory.appendingPathComponent("frames/\(id).jpg").path), "真实记录拒绝混入模拟图片")
print("记录检查完成；样本为软件测试数据，不是实拍或 AR 证据。")
