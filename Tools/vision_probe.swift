import Foundation
import Vision
import ImageIO

// Offline text-recognition probe for exported raw scans (stage 1E). Read-only.
// usage: swift Tools/vision_probe.swift <scan dir>... > vision.jsonl
// Frames are stored in native capturedImage orientation; a portrait-held phone needs
// orientation .right. Boxes are Vision-normalized in that oriented image (origin bottom-left).
func recognize(_ url: URL) throws -> [[String: Any]] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, orientation: .right, options: [:]).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let top = observation.topCandidates(3).first else { return nil }
        let b = observation.boundingBox
        return ["text": top.string, "confidence": top.confidence,
                "alternatives": observation.topCandidates(3).map { [$0.string, $0.confidence] as [Any] },
                "box": [b.minX, b.minY, b.width, b.height]]
    }
}
for path in CommandLine.arguments.dropFirst() {
    let dir = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("scan.json")),
          let scan = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let frames = scan["frames"] as? [[String: Any]] else { continue }
    for frame in frames {
        guard let index = frame["index"] as? Int else { continue }
        let image = dir.appendingPathComponent(String(format: "frames/%04d/rgb.jpg", index))
        let texts = (try? recognize(image)) ?? []
        let line: [String: Any] = ["scan": dir.lastPathComponent, "label": scan["label"] ?? "", "frame": index, "texts": texts]
        if let json = try? JSONSerialization.data(withJSONObject: line), let s = String(data: json, encoding: .utf8) { print(s) }
    }
}
