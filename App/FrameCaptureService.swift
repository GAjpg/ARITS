#if !targetEnvironment(macCatalyst)
import ARKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

func durationMS(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

// ARKit owns the buffer contents; retaining one frame buffer keeps it alive.
// This lease is read-only, and only the serial image queue accesses its pixels.
private struct RetainedCameraPixels: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

@MainActor
final class FrameCaptureService {
    private let queue = DispatchQueue(label: "campus.probe.image", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private(set) var busy = false
    private var lastTimestamp: TimeInterval?

    func reset() { lastTimestamp = nil }

    func capture(frame: ARFrame, recorder: RunRecorder, reason: String, route: [String: Any],
                 calibrationGeometry: [String: Any]? = nil,
                 imageDelivery: (@MainActor (Data) -> Void)? = nil,
                 completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void) -> Bool {
        guard !busy, lastTimestamp != frame.timestamp else { return false }
        busy = true; lastTimestamp = frame.timestamp
        // Retain one pixel buffer, not ARFrame or an unbounded series of camera frames.
        let pixels = frame.capturedImage
        let retainedPixels = RetainedCameraPixels(buffer: pixels)
        let imageContext = context
        let width = CVPixelBufferGetWidth(pixels); let height = CVPixelBufferGetHeight(pixels)
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let frameID = recorder.newFrameID()
        let timestamp = frame.timestamp
        let cameraMatrix = matrixRows(frame.camera.transform)
        let tracking = trackingName(frame.camera.trackingState)
        let started = ContinuousClock.now
        var frameMetadata: [String: Any] = [
            "data_kind": ProbeDataMode.real.rawValue, "is_real_ar_capture": true,
            "schema_version": 1, "run_id": recorder.runID, "session_id": recorder.sessionID, "frame_id": frameID,
            "image": ["path": "frames/\(frameID).jpg", "source_width": width, "source_height": height,
                      "saved_width": width, "saved_height": height, "rotation_deg": 0, "mirrored": false,
                      "conversion": "sensor_orientation_CIImage_to_JPEG_EXIF_1"],
            "intrinsics": ["reference_width": Int(resolution.width), "reference_height": Int(resolution.height),
                           "fx": Double(k.columns.0.x), "fy": Double(k.columns.1.y),
                           "cx": Double(k.columns.2.x), "cy": Double(k.columns.2.y), "source": "ARFrame.camera.intrinsics"],
            "pixel_transform": ["source_to_saved": [[1,0,0],[0,1,0],[0,0,1]]],
            "timing": ["ar_frame_timestamp_seconds": timestamp, "clock_domain": "ARKit_session",
                       "pose_association": "same_ARFrame", "sync_quality": "sdk_frame_associated", "reason": reason],
            "pose": ["coordinate_system": "arkit_right_handed_y_up_camera_forward_minus_z",
                     "direction": "camera_to_session", "matrix": cameraMatrix],
            "tracking": ["camera": tracking], "route": route,
            "validity": ["image_saved": true, "intrinsics_available": true,
                         "intrinsics_dimensions_match": Int(resolution.width) == width && Int(resolution.height) == height,
                         "image_geometry_verified": false, "ready_for_visual_localization_query": false,
                         "ready_for_ar_alignment": false]
        ]
        if let calibrationGeometry { frameMetadata["calibration_geometry"] = calibrationGeometry }
        let metadata = frameMetadata
        // These fields are SDK associated, not a claim that real-world accuracy is verified.
        queue.async { [weak self, imageContext, retainedPixels, metadata] in
            do {
                let image = CIImage(cvPixelBuffer: retainedPixels.buffer)
                guard let cg = imageContext.createCGImage(image, from: image.extent) else { throw CaptureError.encoding }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw CaptureError.encoding
                }
                CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85,
                                                            kCGImagePropertyOrientation: 1] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.encoding }
                var saved = metadata
                saved["processing"] = ["encode_ms": durationMS(started.duration(to: .now)), "jpeg_bytes": data.length]
                recorder.commit(image: data as Data, frame: saved, frameID: frameID) { [weak self] result in
                    self?.busy = false
                    switch result {
                    case .success:
                        completion(.success(["frame_id": frameID, "capture_to_commit_ms": durationMS(started.duration(to: .now))]))
                        imageDelivery?(data as Data)
                    case .failure(let error): completion(.failure(error))
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.busy = false; completion(.failure(error)) }
            }
        }
        return true
    }
}

enum CaptureError: Error, LocalizedError {
    case encoding
    var errorDescription: String? { "相机图像编码失败；本次样本没有记为成功。" }
}

func trackingName(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal: return "tracking"
    case .notAvailable: return "not_available"
    case .limited(let reason):
        switch reason {
        case .initializing: return "limited_initializing"
        case .excessiveMotion: return "limited_excessive_motion"
        case .insufficientFeatures: return "limited_insufficient_features"
        case .relocalizing: return "limited_relocalizing"
        @unknown default: return "limited_unknown"
        }
    }
}
#endif
