import Foundation
import AVFoundation
import UIKit

class VideoExporter {
    static func exportVideoWithGraph(videoURL: URL, emotionData: [EmotionDataPoint], completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: videoURL)
        
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let assetTrack = asset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }
        
        do {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: assetTrack, at: .zero)
        } catch {
            completion(nil)
            return
        }
        
        // Add Audio track if exists
        if let audioAssetTrack = asset.tracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioAssetTrack, at: .zero)
        }
        
        let videoSize = assetTrack.naturalSize
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(assetTrack.preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        // --- Overlay Setup ---
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        let overlayLayer = CALayer()
        
        parentLayer.frame = CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height)
        videoLayer.frame = CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height)
        overlayLayer.frame = CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height)
        
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)
        
        // Emotion Text
        let textLayer = CATextLayer()
        textLayer.frame = CGRect(x: 20, y: videoSize.height - 100, width: videoSize.width - 40, height: 80)
        textLayer.font = UIFont.boldSystemFont(ofSize: 40)
        textLayer.fontSize = 40
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = UIColor.yellow.cgColor
        textLayer.string = "Emotion: Starting..."
        
        overlayLayer.addSublayer(textLayer)
        
        // Animate Text
        if !emotionData.isEmpty {
            let totalDuration = asset.duration.seconds
            var values: [String] = []
            var keyTimes: [NSNumber] = []
            
            for point in emotionData {
                values.append("Emotion: \(point.emotion)")
                let relativeTime = min(max(point.time / totalDuration, 0.0), 1.0)
                keyTimes.append(NSNumber(value: relativeTime))
            }
            
            // CAKeyframeAnimation on "string" doesn't work perfectly on CATextLayer.
            // But we can create discrete text layers that show/hide, or use CAKeyframeAnimation on a custom property.
            // A simpler approach for AVCoreAnimation is changing the string property if CA allows.
            // Actually, CAKeyframeAnimation on "string" IS supported for CATextLayer in AVVideoComposition.
            let textAnimation = CAKeyframeAnimation(keyPath: "string")
            textAnimation.values = values
            textAnimation.keyTimes = keyTimes
            textAnimation.calculationMode = .discrete
            textAnimation.duration = totalDuration
            textAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
            textAnimation.isRemovedOnCompletion = false
            
            textLayer.add(textAnimation, forKey: "textAnimation")
        }
        
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        
        // --- Export ---
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("Export_\(UUID().uuidString).mp4")
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil)
            return
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                if exportSession.status == .completed {
                    completion(outputURL)
                } else {
                    print("Export failed: \(String(describing: exportSession.error))")
                    completion(nil)
                }
            }
        }
    }
}
