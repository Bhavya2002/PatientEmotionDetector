import Foundation
import AVFoundation
import UIKit
import CoreImage

class VideoExporter {

    // ── Main export method ────────────────────────────────────────────────────

    static func exportVideoWithGraph(
        videoURL: URL,
        emotionData: [EmotionDataPoint],
        completion: @escaping (URL?) -> Void
    ) {
        let asset = AVAsset(url: videoURL)
        let totalDuration = asset.duration.seconds

        guard totalDuration > 0 else {
            print("Invalid video duration: \(totalDuration)")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Prepare fallback data if emotionData is empty
        var processedData = emotionData
        if processedData.isEmpty {
            processedData = [
                EmotionDataPoint(time: 0.0, emotion: "Neutral", confidence: 0.8),
                EmotionDataPoint(time: totalDuration, emotion: "Neutral", confidence: 0.8)
            ]
        }

        // Use AVMutableVideoComposition with CIFilter handler for 100% reliable frame rendering & orientation
        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let sourceImage = request.sourceImage
            let renderSize = request.renderSize
            let currentTime = request.compositionTime.seconds

            // Render dynamic emotion HUD & 1-minute moving trend graph overlay
            let overlayImage = renderOverlay(
                size: renderSize,
                currentTime: currentTime,
                totalDuration: totalDuration,
                emotionData: processedData
            )

            if let cgImage = overlayImage.cgImage {
                let overlayCI = CIImage(cgImage: cgImage)
                let output = overlayCI.composited(over: sourceImage)
                request.finish(with: output, context: nil)
            } else {
                request.finish(with: sourceImage, context: nil)
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

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

    // ── Overlay Renderer (1-Minute Moving Window) ─────────────────────────────

    private static func renderOverlay(
        size: CGSize,
        currentTime: TimeInterval,
        totalDuration: TimeInterval,
        emotionData: [EmotionDataPoint]
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            let s = size.width / 390.0 // Base responsive scaling factor

            // 1. Find active emotion at currentTime
            let activePoint = emotionData.filter { $0.time <= currentTime }.last ?? emotionData.first!
            let emotionName = activePoint.emotion
            let confidencePct = Int(activePoint.confidence * 100)

            let themeColor: UIColor
            let emoji: String
            switch emotionName {
            case "Stressed":
                themeColor = UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1.0) // Red
                emoji = "😰"
            case "Relaxed":
                themeColor = UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0) // Green
                emoji = "😊"
            default:
                themeColor = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0) // Yellow
                emoji = "😐"
            }

            // 2. Card Background Dimensions (Bottom Floating Card)
            let cardMargin: CGFloat = 16 * s
            let cardW: CGFloat = size.width - (cardMargin * 2)
            let cardH: CGFloat = 160 * s
            let cardX: CGFloat = cardMargin
            let cardY: CGFloat = size.height - cardH - (30 * s)
            let cardRect = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)

            // Draw Card Background
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 20 * s)
            UIColor.black.withAlphaComponent(0.75).setFill()
            cardPath.fill()

            // Card Border
            cgCtx.saveGState()
            cardPath.lineWidth = 1.5 * s
            UIColor.white.withAlphaComponent(0.20).setStroke()
            cardPath.stroke()
            cgCtx.restoreGState()

            // 3. Header Row inside Card
            let headerY = cardY + (14 * s)

            // Left: Emotion Badge
            let badgeText = "\(emoji) \(emotionName) (\(confidencePct)%)"
            let badgeFont = UIFont.systemFont(ofSize: 17 * s, weight: .bold)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: themeColor
            ]
            let badgeSize = (badgeText as NSString).size(withAttributes: badgeAttrs)
            let badgeRect = CGRect(x: cardX + (16 * s), y: headerY, width: badgeSize.width + (16 * s), height: badgeSize.height + (8 * s))

            // Badge Background Pill
            let badgeBgPath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 8 * s)
            themeColor.withAlphaComponent(0.20).setFill()
            badgeBgPath.fill()
            (badgeText as NSString).draw(at: CGPoint(x: badgeRect.minX + (8 * s), y: badgeRect.minY + (4 * s)), withAttributes: badgeAttrs)

            // Middle: 1-Min Window Indicator
            let winText = "1-MIN WINDOW"
            let winFont = UIFont.monospacedDigitSystemFont(ofSize: 11 * s, weight: .bold)
            let winAttrs: [NSAttributedString.Key: Any] = [
                .font: winFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.60)
            ]
            (winText as NSString).draw(
                at: CGPoint(x: badgeRect.maxX + (14 * s), y: headerY + (6 * s)),
                withAttributes: winAttrs
            )

            // Right: Timecode Display (e.g., 00:05 / 00:15)
            let curStr = formatTime(currentTime)
            let totStr = formatTime(totalDuration)
            let timeText = "\(curStr) / \(totStr)"
            let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 14 * s, weight: .medium)
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: timeFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.85)
            ]
            let timeSize = (timeText as NSString).size(withAttributes: timeAttrs)
            (timeText as NSString).draw(
                at: CGPoint(x: cardX + cardW - timeSize.width - (16 * s), y: headerY + (4 * s)),
                withAttributes: timeAttrs
            )

            // 4. Trend Graph Area
            let graphX = cardX + (55 * s) // Leave room for Y-axis labels
            let graphY = headerY + badgeRect.height + (16 * s)
            let graphW = cardW - (70 * s)
            let graphH = cardH - (headerY - cardY) - badgeRect.height - (30 * s)

            let relaxedY = graphY + (graphH * 0.15)
            let neutralY = graphY + (graphH * 0.50)
            let stressedY = graphY + (graphH * 0.85)

            // Draw Y-Axis Labels & Reference Guide Lines
            let guideLevels: [(String, CGFloat, UIColor)] = [
                ("Relaxed", relaxedY, UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.35)),
                ("Neutral", neutralY, UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 0.35)),
                ("Stressed", stressedY, UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 0.35))
            ]

            let labelFont = UIFont.systemFont(ofSize: 9 * s, weight: .semibold)
            for (lbl, yPos, col) in guideLevels {
                // Label
                let lblAttrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: col.withAlphaComponent(0.9)
                ]
                let lblSize = (lbl as NSString).size(withAttributes: lblAttrs)
                (lbl as NSString).draw(
                    at: CGPoint(x: cardX + (12 * s), y: yPos - (lblSize.height / 2)),
                    withAttributes: lblAttrs
                )

                // Dashed guide line
                cgCtx.saveGState()
                let guidePath = UIBezierPath()
                guidePath.move(to: CGPoint(x: graphX, y: yPos))
                guidePath.addLine(to: CGPoint(x: graphX + graphW, y: yPos))
                let dashes: [CGFloat] = [4 * s, 4 * s]
                guidePath.setLineDash(dashes, count: dashes.count, phase: 0)
                guidePath.lineWidth = 1 * s
                col.setStroke()
                guidePath.stroke()
                cgCtx.restoreGState()
            }

            // 5. Moving 1-Minute Window Calculation
            let windowDuration: TimeInterval = 60.0
            let windowEnd = max(windowDuration, currentTime)
            let windowStart = max(0.0, windowEnd - windowDuration)

            let sortedData = emotionData.sorted { $0.time < $1.time }
            // Filter points within the rolling 1-minute window
            let windowPoints = sortedData.filter { $0.time >= windowStart && $0.time <= windowEnd }

            var curvePoints: [CGPoint] = []
            for point in windowPoints {
                let normX = min(max((point.time - windowStart) / windowDuration, 0.0), 1.0)
                let px = graphX + (CGFloat(normX) * graphW)

                let py: CGFloat
                switch point.emotion {
                case "Relaxed":  py = relaxedY
                case "Stressed": py = stressedY
                default:         py = neutralY
                }
                curvePoints.append(CGPoint(x: px, y: py))
            }

            // If graph scrolled past 60s, smoothly anchor the left boundary with historical data
            if let firstPt = curvePoints.first, firstPt.x > graphX {
                let prevPoint = sortedData.filter { $0.time < windowStart }.last
                let py: CGFloat
                switch prevPoint?.emotion {
                case "Relaxed":  py = relaxedY
                case "Stressed": py = stressedY
                default:         py = neutralY
                }
                curvePoints.insert(CGPoint(x: graphX, y: py), at: 0)
            } else if curvePoints.isEmpty {
                // Flat line fallback
                curvePoints = [CGPoint(x: graphX, y: neutralY), CGPoint(x: graphX + graphW, y: neutralY)]
            }

            // 6. Draw Moving Trend Graph Line & Area Fill
            if curvePoints.count >= 2 {
                let linePath = UIBezierPath()
                linePath.move(to: curvePoints[0])
                for i in 1..<curvePoints.count {
                    linePath.addLine(to: curvePoints[i])
                }

                // Area under curve fill
                let fillPath = UIBezierPath(cgPath: linePath.cgPath)
                if let lastPt = curvePoints.last {
                    fillPath.addLine(to: CGPoint(x: lastPt.x, y: graphY + graphH))
                }
                fillPath.addLine(to: CGPoint(x: curvePoints[0].x, y: graphY + graphH))
                fillPath.close()

                UIColor.cyan.withAlphaComponent(0.12).setFill()
                fillPath.fill()

                // Stroke curve line
                linePath.lineWidth = 2.5 * s
                UIColor.cyan.withAlphaComponent(0.95).setStroke()
                linePath.stroke()

                // Draw dots at each data point
                for pt in curvePoints {
                    let dotRect = CGRect(x: pt.x - (2.5 * s), y: pt.y - (2.5 * s), width: 5 * s, height: 5 * s)
                    let dotPath = UIBezierPath(ovalIn: dotRect)
                    UIColor.cyan.setFill()
                    dotPath.fill()
                }
            }

            // 7. Live Playhead Indicator on 1-Minute Window
            let normCurrent = min(max((currentTime - windowStart) / windowDuration, 0.0), 1.0)
            let playheadX = graphX + (CGFloat(normCurrent) * graphW)

            // Vertical scrubber line
            let scrubberPath = UIBezierPath()
            scrubberPath.move(to: CGPoint(x: playheadX, y: graphY))
            scrubberPath.addLine(to: CGPoint(x: playheadX, y: graphY + graphH))
            scrubberPath.lineWidth = 1.5 * s
            UIColor.white.withAlphaComponent(0.85).setStroke()
            scrubberPath.stroke()

            // Current emotion dot on the playhead
            let currentDotY: CGFloat
            switch emotionName {
            case "Relaxed":  currentDotY = relaxedY
            case "Stressed": currentDotY = stressedY
            default:         currentDotY = neutralY
            }

            let indicatorSize: CGFloat = 10 * s
            let indicatorRect = CGRect(
                x: playheadX - (indicatorSize / 2),
                y: currentDotY - (indicatorSize / 2),
                width: indicatorSize,
                height: indicatorSize
            )
            let indicatorPath = UIBezierPath(ovalIn: indicatorRect)
            themeColor.setFill()
            indicatorPath.fill()
            indicatorPath.lineWidth = 2 * s
            UIColor.white.setStroke()
            indicatorPath.stroke()
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let mins = s / 60
        let secs = s % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
