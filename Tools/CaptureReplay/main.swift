import Foundation

// Offline replay of the stage-1 capture policy over an exported raw map scan (read-only).
// The exported frames were already sampled every ~0.65 s by the old capture, so this shows
// how the new policy would treat those frames, not the 4 Hz candidate stream on the phone.
// usage: capture-replay <raw map scan dir> [out.json]
do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { throw LiDARScanError.invalid("usage: capture-replay <scan dir> [out.json]") }
    let dir = URL(fileURLWithPath:args[1])
    let manifest = try JSONDecoder().decode(LiDARScanManifest.self,from:Data(contentsOf:dir.appendingPathComponent("scan.json")))
    var policy = LiDARKeyframePolicy(),gate = LiDARRevisitGate()
    let budget = LiDARBlockBudget()
    var accepted = [Int](),reasons = [String:Int](),skips = [String:Int](),revisits = [String:Int](),flags = [Int]()
    var medians = [Double](),isolated = 0
    for frame in manifest.frames {
        let folder = dir.appendingPathComponent(frame.folder)
        let obs = try LiDARGeometry.observations(depth:Data(contentsOf:folder.appendingPathComponent("depth.f32")),
                                                 confidence:Data(contentsOf:folder.appendingPathComponent("confidence.u8")),frame:frame)
        let valid = Double(obs.count)/Double(((frame.calibration.width+3)/4)*((frame.calibration.height+3)/4))
        let d = policy.decide(.init(timestamp:frame.timestamp,cameraToSession:frame.camera_to_session,trackingNormal:true,
                                    validDepthFraction:valid,preview:budget.preview(obs)))
        // Same order as the App: revisit check, then the gate decides whether geometry may join.
        let report = budget.revisitCheck(obs);revisits[report.status,default:0] += 1
        if let m = report.median_m { medians.append(m) }
        let step = gate.step(report,batchBeforeCommit:budget.batch)
        if step.newlyFlagged { flags.append(frame.index);if let b = step.rollbackToBatch { budget.rollback(toBatch:b) };gate.reset() }
        guard d.accept else { skips[d.skip_reason ?? "?",default:0] += 1;continue }
        for r in d.reasons { reasons[r,default:0] += 1 }
        if step.commitGeometry { budget.commit(obs) } else { isolated += 1 }
        policy.didAccept(timestamp:frame.timestamp,cameraToSession:frame.camera_to_session);accepted.append(frame.index)
    }
    let snap = budget.snapshot()
    var statuses = [String:Int]();for b in snap.blocks { statuses[b.status,default:0] += 1 }
    medians.sort()
    let summary: [String:Any] = ["label":manifest.label,"frames":manifest.frames.count,"accepted":accepted.count,"accepted_frames":accepted,
        "accept_reasons":reasons,"skip_reasons":skips,"revisit_reports":revisits,"revisit_flags_at_frames":flags,"isolated_frames":isolated,
        "revisit_median_m_p50":medians.isEmpty ? NSNull() : medians[medians.count/2],
        "voxels":snap.voxels,"blocks":snap.blocks.count,"block_status":statuses,"refused_block":snap.refused_block,
        "runtime_points":budget.runtimePoints(limit:18_000).count]
    let data = try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys])
    if args.count >= 3 { try data.write(to:URL(fileURLWithPath:args[2])) }
    print(String(data:data,encoding:.utf8)!)
} catch { fputs("\(error.localizedDescription)\n",stderr);exit(1) }
