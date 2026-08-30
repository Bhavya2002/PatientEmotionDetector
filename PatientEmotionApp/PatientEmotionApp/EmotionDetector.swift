import Foundation
import CoreML
import Vision
import CoreVideo
import Combine

struct EmotionDataPoint {
    let time: TimeInterval
    let emotion: String
    let confidence: Double
}

class EmotionDetector: ObservableObject {
    @Published var currentEmotion: String = "Detecting..."
    @Published var currentConfidence: Double = 0.0
    
    var recordingData: [EmotionDataPoint] = []
    private var isRecording = false
    private var sessionStartTime: Date?
    
    private var emotionModel: VNCoreMLModel?
    private let faceDetectionRequest = VNDetectFaceRectanglesRequest()
    
    init() {
        // Load the auto-generated model class
        if let config = try? MLModelConfiguration(),
           let model = try? PatientEmotionModel(configuration: config).model,
           let vnModel = try? VNCoreMLModel(for: model) {
            self.emotionModel = vnModel
        } else {
            print("Failed to load PatientEmotionModel. Make sure it's added to the target!")
        }
    }
    
    func startRecordingSession() {
        recordingData.removeAll()
        sessionStartTime = Date()
        isRecording = true
    }
    
    func stopRecordingSession() -> [EmotionDataPoint] {
        isRecording = false
        return recordingData
    }
    
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let emotionModel = emotionModel else { return }
        
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        // 1. Detect Face
        do {
            try requestHandler.perform([faceDetectionRequest])
            guard let results = faceDetectionRequest.results, let firstFace = results.first else {
                DispatchQueue.main.async { self.currentEmotion = "No Face" }
                return
            }
            
            // Vision coordinates: (0,0) is bottom-left
            let faceBox = firstFace.boundingBox
            // Crop top 60% of the face for the eyes/eyebrows
            let topHalfFace = CGRect(
                x: faceBox.minX,
                y: faceBox.minY + (faceBox.height * 0.4),
                width: faceBox.width,
                height: faceBox.height * 0.6
            )
            
            // 2. Classify Emotion
            let emotionRequest = VNCoreMLRequest(model: emotionModel) { [weak self] request, error in
                guard let self = self,
                      let classifications = request.results as? [VNClassificationObservation],
                      let best = classifications.first else { return }
                
                let emotion = best.identifier
                let confidence = Double(best.confidence)
                
                DispatchQueue.main.async {
                    self.currentEmotion = emotion
                    self.currentConfidence = confidence
                }
                
                if self.isRecording, let startTime = self.sessionStartTime {
                    let timeOffset = Date().timeIntervalSince(startTime)
                    let dataPoint = EmotionDataPoint(time: timeOffset, emotion: emotion, confidence: confidence)
                    self.recordingData.append(dataPoint)
                }
            }
            
            emotionRequest.regionOfInterest = topHalfFace
            
            // We use a new request handler because regionOfInterest modifies the request context
            let cropRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            try cropRequestHandler.perform([emotionRequest])
            
        } catch {
            print("Vision error: \(error)")
        }
    }
}
