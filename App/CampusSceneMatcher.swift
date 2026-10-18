#if !targetEnvironment(macCatalyst)
import Foundation
import Vision
import CoreVideo
import ImageIO

// Image similarity ranks candidate maps only. ARKit must still relocalize;
// similarity distances are deliberately not called localization confidence.
final class CampusSceneMatcher {
    struct Reference { let regionID:String; let observation:VNFeaturePrintObservation }
    private static let cache = NSCache<NSString,VNFeaturePrintObservation>()
    private let queue = DispatchQueue(label:"campus.scene.matcher",qos:.userInitiated)
    private var references:[Reference] = []
    private var regions:[String] = []
    func prepare(graph:CampusGraph,regionIDs:Set<String>? = nil,preferredLighting:CampusLighting? = nil,completion:@escaping(Result<Int,Error>)->Void) {
        queue.async { [self] in
            let result = Result { () -> Int in
                references.removeAll(); regions.removeAll(); Self.cache.countLimit = 1500
                for r in graph.regions where r.map_saved && (regionIDs?.contains(r.id) ?? true) {
                    let mapIDs = graph.rankedMaps(regionID:r.id,preferredLighting:preferredLighting).map(\.id)
                    let directories = mapIDs.isEmpty ? [(try? CampusApp.library.regionDirectory(buildingID:graph.building_id,regionID:r.id))].compactMap { $0 } : mapIDs.compactMap { try? CampusApp.library.candidateDirectory(buildingID:graph.building_id,candidateID:$0) }
                    var seenHashes = Set<String>(),available = false
                    for directory in directories {
                        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("environment.arworldmap").path),
                              (try? CampusApp.library.verifyRegion(graph:graph,region:r,in:directory)) != nil else { continue }
                        available = true
                    for folder in ["references","views","guides"] {
                        let files = (try? FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent(folder),includingPropertiesForKeys:nil)) ?? []
                        for url in files.sorted(by:{$0.path < $1.path}) where url.pathExtension == "jpg" {
                            do {
                                let hash = try CampusFiles.hash(url)
                                guard seenHashes.insert(hash).inserted else { continue }
                                let observation:VNFeaturePrintObservation
                                if let cached = Self.cache.object(forKey:url.path as NSString) { observation = cached }
                                else {
                                    observation = try Self.feature(VNImageRequestHandler(url:url,orientation:.right,options:[:]))
                                    Self.cache.setObject(observation,forKey:url.path as NSString)
                                }
                                references.append(Reference(regionID:r.id,observation:observation))
                            } catch { continue } // A map can still be tried if its view descriptor fails.
                        }
                    }
                    }
                    if available { regions.append(r.id) }
                }
                guard !regions.isEmpty else { throw CampusError.invalid("本机没有可恢复的环境。请导入完整 ZIP 备份；路网 JSON 只包含线路。") }
                return regions.count
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func rank(pixels:CVPixelBuffer,completion:@escaping(Result<[String],Error>)->Void) {
        queue.async { [self] in
            let result = Result { () -> [String] in
                let query = try Self.feature(VNImageRequestHandler(cvPixelBuffer:pixels,orientation:.right,options:[:]))
                var best:[String:Float] = [:]
                for reference in references {
                    var distance:Float = 0
                    try query.computeDistance(&distance,to:reference.observation)
                    if distance.isFinite { best[reference.regionID] = min(best[reference.regionID] ?? .infinity,distance) }
                }
                return regions.sorted { (best[$0] ?? .infinity) == (best[$1] ?? .infinity) ? $0 < $1 : (best[$0] ?? .infinity) < (best[$1] ?? .infinity) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private static func feature(_ handler:VNImageRequestHandler) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest(); request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFit; try handler.perform([request])
        guard let result = request.results?.first else { throw CampusError.invalid("暂时无法分析画面，请继续缓慢扫描。") }
        return result
    }
}
#endif
