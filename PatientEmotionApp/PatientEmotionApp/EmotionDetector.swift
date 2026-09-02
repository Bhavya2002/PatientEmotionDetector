import Foundation
import CoreML
import Vision
import CoreVideo
import AVFoundation
import Combine

// ── Data structures ───────────────────────────────────────────────────────────

struct EmotionDataPoint: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let emotion: String
    let confidence: Double
}

/// App-level state machine for calibration vs. live detection.
enum DetectionPhase {
    case calibrating(secondsRemaining: Int)
    case detecting
}

// ── Geometric helpers ─────────────────────────────────────────────────────────

private struct FaceGeometry {
    /// Horizontal span between eyebrow centroids, normalised by inter-ocular distance.
    let browSpan: CGFloat
    /// Mean height of eyebrows above corresponding eye centres, normalised by IOD.
    let browHeight: CGFloat

    static func from(observation: VNFaceObservation) -> FaceGeometry? {
        guard let lm = observation.landmarks,
              let lBrow = lm.leftEyebrow,  let rBrow = lm.rightEyebrow,
              let lEye  = lm.leftEye,      let rEye  = lm.rightEye
        else { return nil }

        func centroid(_ pts: [CGPoint]) -> CGPoint {
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }

        let lBrowC = centroid(lBrow.normalizedPoints)
        let rBrowC = centroid(rBrow.normalizedPoints)
        let lEyeC  = centroid(lEye.normalizedPoints)
        let rEyeC  = centroid(rEye.normalizedPoints)

        let iod = hypot(rEyeC.x - lEyeC.x, rEyeC.y - lEyeC.y)
        guard iod > 0 else { return nil }

        let browSpan   = hypot(rBrowC.x - lBrowC.x, rBrowC.y - lBrowC.y) / iod
        let lBrowLift  = (lBrowC.y - lEyeC.y) / iod
        let rBrowLift  = (rBrowC.y - rEyeC.y) / iod
        let browHeight = (lBrowLift + rBrowLift) / 2

        return FaceGeometry(browSpan: browSpan, browHeight: browHeight)
    }
}

// ── Probability smoothing ─────────────────────────────────────────────────────

private struct ProbabilityBuffer {
    let windowSize: Int
    private var buffer: [[String: Double]] = []

    init(windowSize: Int = 12) { self.windowSize = windowSize }

    mutating func push(_ probs: [String: Double]) {
        buffer.append(probs)
        if buffer.count > windowSize { buffer.removeFirst() }
    }

    func bestNeutralRelaxed() -> (String, Double)? {
        guard !buffer.isEmpty else { return nil }
        var sums: [String: Double] = [:]
        for frame in buffer {
            for key in ["Neutral", "Relaxed"] {
                sums[key, default: 0] += frame[key, default: 0]
            }
        }
        let means = sums.mapValues { $0 / Double(buffer.count) }
        guard let winner = means.max(by: { $0.value < $1.value }) else { return nil }
        return (winner.key, winner.value)
    }
}

// ── Main detector ─────────────────────────────────────────────────────────────

class EmotionDetector: ObservableObject {
    @Published var currentEmotion:    String = "Calibrating..."
    @Published var currentConfidence: Double = 0.0
    @Published var detectionPhase:    DetectionPhase = .calibrating(secondsRemaining: 5)
    
    // 1-minute rolling history for the live moving graph UI
    @Published var rollingHistory:    [EmotionDataPoint] = []

    // ── Calibration config ───
    private let calibrationDuration: TimeInterval = 5
    private var calibrationStart:    Date?
    private var calibrationSamples:  [FaceGeometry] = []
    private var baseline:            FaceGeometry?

    // Stress threshold
    private let stressThreshold: CGFloat = 0.10

    // ── Detection state ──────
    var recordingData:    [EmotionDataPoint] = []
    private var isRecording        = false
    private var sessionStartTime:  Date?
    private var lastRecordedTime:  TimeInterval = -1
    
    // Live tracking timing for rolling history
    private var liveStartTime:     Date = Date()
    private var lastRollingSampleTime: TimeInterval = -1

    private var probBuffer         = ProbabilityBuffer(windowSize: 12)
    private var emotionModel:      VNCoreMLModel?
    private let landmarksRequest   = VNDetectFaceLandmarksRequest()

    // ── Init ─────────────────────────────────────────────────────────────────

    init() {
        if let config  = try? MLModelConfiguration(),
           let model   = try? PatientEmotionModel(configuration: config).model,
           let vnModel = try? VNCoreMLModel(for: model) {
            self.emotionModel = vnModel
        } else {
            print("⚠️ Failed to load PatientEmotionModel.")
        }
    }

    // ── Session control ───────────────────────────────────────────────────────

    func startRecordingSession() {
        recordingData.removeAll()
        sessionStartTime = Date()
        lastRecordedTime = 0.0
        isRecording      = true

        let initialEmotion = (currentEmotion == "Calibrating..." || currentEmotion == "Detecting..." || currentEmotion == "No Face") ? "Neutral" : currentEmotion
        recordingData.append(
            EmotionDataPoint(time: 0.0, emotion: initialEmotion, confidence: max(currentConfidence, 0.75))
        )
    }

    func stopRecordingSession() -> [EmotionDataPoint] {
        isRecording = false
        if let start = sessionStartTime {
            let offset = Date().timeIntervalSince(start)
            let finalEmotion = (currentEmotion == "Calibrating..." || currentEmotion == "Detecting..." || currentEmotion == "No Face") ? "Neutral" : currentEmotion
            recordingData.append(
                EmotionDataPoint(time: offset, emotion: finalEmotion, confidence: max(currentConfidence, 0.75))
            )
        }
        return recordingData
    }

    /// Call this to restart calibration (e.g. new patient).
    func resetCalibration() {
        calibrationStart   = nil
        calibrationSamples = []
        baseline           = nil
        probBuffer         = ProbabilityBuffer(windowSize: 12)
        rollingHistory.removeAll()
        liveStartTime      = Date()
        lastRollingSampleTime = -1
        DispatchQueue.main.async {
            self.detectionPhase  = .calibrating(secondsRemaining: 5)
            self.currentEmotion  = "Calibrating..."
        }
    }

    // ── Frame processing ──────────────────────────────────────────────────────

    func processFrame(_ pixelBuffer: CVPixelBuffer, cameraPosition: AVCaptureDevice.Position) {
        let orientation: CGImagePropertyOrientation = (cameraPosition == .front) ? .upMirrored : .up
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            // Step 1 – Get face + landmarks
            try handler.perform([landmarksRequest])
            guard let faceObs = landmarksRequest.results?.first else {
                DispatchQueue.main.async { self.currentEmotion = "No Face" }
                return
            }

            let geometry = FaceGeometry.from(observation: faceObs)

            // Step 2 – Calibration phase
            if baseline == nil {
                runCalibration(geometry: geometry)
                return
            }

            // Step 3 – Classify Neutral / Relaxed via CoreML
            guard let emotionModel = emotionModel else { return }
            let roi = expandedROI(from: faceObs.boundingBox)
            let emotionRequest = VNCoreMLRequest(model: emotionModel) { [weak self] req, _ in
                guard let self = self,
                      let results = req.results as? [VNClassificationObservation] else { return }

                var probs: [String: Double] = [:]
                for obs in results { probs[obs.identifier] = Double(obs.confidence) }
                self.probBuffer.push(probs)

                // Step 4 – Stress override via geometry
                let emotion: String
                let confidence: Double

                if let geo = geometry, let base = self.baseline, self.isStressed(geo, baseline: base) {
                    emotion    = "Stressed"
                    confidence = self.stressConfidence(geo, baseline: base)
                } else if let (label, conf) = self.probBuffer.bestNeutralRelaxed() {
                    emotion    = label
                    confidence = conf
                } else {
                    return
                }

                // Update live rolling history (1-minute window)
                let liveElapsed = Date().timeIntervalSince(self.liveStartTime)
                if liveElapsed - self.lastRollingSampleTime >= 0.2 { // Sample at 5Hz for smooth UI
                    self.lastRollingSampleTime = liveElapsed
                    let newPoint = EmotionDataPoint(time: liveElapsed, emotion: emotion, confidence: confidence)
                    
                    DispatchQueue.main.async {
                        self.currentEmotion    = emotion
                        self.currentConfidence = confidence
                        self.rollingHistory.append(newPoint)
                        
                        // Drop data points older than 60 seconds
                        let cutoff = liveElapsed - 60.0
                        self.rollingHistory.removeAll { $0.time < cutoff }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.currentEmotion    = emotion
                        self.currentConfidence = confidence
                    }
                }

                // Record for video export
                if self.isRecording, let start = self.sessionStartTime {
                    let offset = Date().timeIntervalSince(start)
                    if offset - self.lastRecordedTime >= 0.1 {
                        self.lastRecordedTime = offset
                        self.recordingData.append(
                            EmotionDataPoint(time: offset, emotion: emotion, confidence: confidence)
                        )
                    }
                }
            }
            emotionRequest.regionOfInterest = roi

            let cropHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            try cropHandler.perform([emotionRequest])

        } catch {
            print("Vision error: \(error)")
        }
    }

    // ── Calibration helpers ───────────────────────────────────────────────────

    private func runCalibration(geometry: FaceGeometry?) {
        if calibrationStart == nil { calibrationStart = Date() }
        guard let start = calibrationStart else { return }

        let elapsed  = Date().timeIntervalSince(start)
        let remaining = max(0, Int(calibrationDuration - elapsed) + 1)

        DispatchQueue.main.async {
            self.detectionPhase  = .calibrating(secondsRemaining: remaining)
            self.currentEmotion  = "Calibrating..."
        }

        if let g = geometry { calibrationSamples.append(g) }

        if elapsed >= calibrationDuration && !calibrationSamples.isEmpty {
            let n      = CGFloat(calibrationSamples.count)
            let sumBS  = calibrationSamples.map(\.browSpan).reduce(0, +)
            let sumBH  = calibrationSamples.map(\.browHeight).reduce(0, +)
            baseline   = FaceGeometry(browSpan: sumBS / n, browHeight: sumBH / n)
            liveStartTime = Date()
            lastRollingSampleTime = -1
            print("✅ Calibration done. BaseBrowSpan=\(baseline!.browSpan)  BaseBrowHeight=\(baseline!.browHeight)")
            DispatchQueue.main.async { self.detectionPhase = .detecting }
        }
    }

    // ── Stress geometry logic ─────────────────────────────────────────────────

    private func isStressed(_ geo: FaceGeometry, baseline: FaceGeometry) -> Bool {
        let spanDrop   = (baseline.browSpan   - geo.browSpan)   / baseline.browSpan
        let heightDrop = (baseline.browHeight - geo.browHeight) / max(baseline.browHeight, 0.001)
        return spanDrop > stressThreshold || heightDrop > stressThreshold
    }

    private func stressConfidence(_ geo: FaceGeometry, baseline: FaceGeometry) -> Double {
        let spanDrop   = (baseline.browSpan   - geo.browSpan)   / baseline.browSpan
        let heightDrop = (baseline.browHeight - geo.browHeight) / max(baseline.browHeight, 0.001)
        let maxDrop    = max(spanDrop, heightDrop)
        return min(Double(maxDrop / 0.35), 1.0)
    }

    private func expandedROI(from box: CGRect) -> CGRect {
        return CGRect(
            x: box.minX,
            y: box.minY + box.height * 0.35,
            width: box.width,
            height: box.height * 0.65
        )
    }
}
