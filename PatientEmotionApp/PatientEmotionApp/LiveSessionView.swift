import SwiftUI
import UIKit
import AVFoundation

struct LiveSessionView: View {
    @StateObject private var cameraManager   = CameraManager()
    @StateObject private var emotionDetector = EmotionDetector()

    @State private var exportedVideoURL: URL?
    @State private var isExporting    = false
    @State private var showShareSheet = false

    private func emotionColor(_ emotion: String) -> Color {
        switch emotion {
        case "Stressed": return Color(red: 1.0, green: 0.27, blue: 0.23)
        case "Relaxed":  return Color(red: 0.19, green: 0.82, blue: 0.35)
        default:         return Color(red: 1.0, green: 0.84, blue: 0.04)
        }
    }

    private func emotionEmoji(_ emotion: String) -> String {
        switch emotion {
        case "Stressed": return "😰"
        case "Relaxed":  return "😊"
        default:         return "😐"
        }
    }

    var body: some View {
        ZStack {
            // ── Camera Preview ──────────────────────────────────────────────
            CameraPreview(session: cameraManager.captureSession)
                .edgesIgnoringSafeArea(.all)

            // ── Calibration overlay ──────────────────────────────────────────
            if case .calibrating(let secs) = emotionDetector.detectionPhase {
                Color.black.opacity(0.70)
                    .edgesIgnoringSafeArea(.all)
                VStack(spacing: 20) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                    Text("Calibrating Baseline")
                        .font(.title).bold().foregroundColor(.white)
                    Text("Please look straight at the camera\nwith a neutral expression")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.85))
                    Text("\(secs)")
                        .font(.system(size: 72, weight: .heavy, design: .rounded))
                        .foregroundColor(.yellow)

                    // Flip camera button during calibration
                    Button {
                        cameraManager.flipCamera()
                        emotionDetector.resetCalibration()
                    } label: {
                        Label(
                            cameraManager.currentPosition == .back ? "Switch to Front Camera" : "Switch to Back Camera",
                            systemImage: "arrow.triangle.2.circlepath.camera"
                        )
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.2))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 8)
                }

            } else {

                // ── Detection UI ─────────────────────────────────────────────────
                VStack(spacing: 12) {
                    // Top Bar: Live Emotion Badge + Recalibrate Button
                    HStack {
                        // Live emotion badge
                        HStack(spacing: 8) {
                            Text(emotionEmoji(emotionDetector.currentEmotion))
                                .font(.title3)
                            Text(emotionDetector.currentEmotion)
                                .font(.headline)
                                .foregroundColor(emotionColor(emotionDetector.currentEmotion))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.65))
                        .clipShape(Capsule())

                        Spacer()

                        // Recalibrate button
                        Button {
                            emotionDetector.resetCalibration()
                        } label: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .disabled(cameraManager.isRecording)
                    }
                    .padding(.top, 55)
                    .padding(.horizontal, 20)

                    // ── Live 1-Minute Moving Graph Overlay ─────────────────────────
                    RollingEmotionGraphView(
                        history: emotionDetector.rollingHistory,
                        currentEmotion: emotionDetector.currentEmotion,
                        themeColor: emotionColor(emotionDetector.currentEmotion)
                    )
                    .frame(height: 120)
                    .padding(.horizontal, 16)

                    Spacer()

                    // ── Bottom Controls ──────────────────────────────────────────
                    HStack(alignment: .center, spacing: 40) {

                        // Flip camera button
                        Button {
                            cameraManager.flipCamera()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(cameraManager.isRecording ? .gray : .white)
                                .padding(14)
                                .background(.black.opacity(0.55))
                                .clipShape(Circle())
                        }
                        .disabled(cameraManager.isRecording)

                        // Record button
                        if isExporting {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.3)
                                Text("Exporting…")
                                    .font(.caption2).bold()
                                    .foregroundColor(.white)
                            }
                            .frame(width: 75, height: 75)
                        } else {
                            Button(action: toggleRecording) {
                                ZStack {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3.5)
                                        .frame(width: 75, height: 75)
                                    Circle()
                                        .fill(cameraManager.isRecording ? Color.red : Color.white)
                                        .frame(width: cameraManager.isRecording ? 36 : 60, height: cameraManager.isRecording ? 36 : 60)
                                        .cornerRadius(cameraManager.isRecording ? 8 : 30)
                                }
                            }
                        }

                        // Spacer placeholder for alignment
                        Color.clear.frame(width: 54, height: 54)
                    }
                    .padding(.bottom, 45)
                }

            } // end if/else calibrating

        } // ZStack
        .onAppear {
            cameraManager.startSession()

            cameraManager.onFrameUpdate = { pixelBuffer, position in
                emotionDetector.processFrame(pixelBuffer, cameraPosition: position)
            }

            cameraManager.onRecordingFinished = { url in
                isExporting = true
                let data = emotionDetector.stopRecordingSession()
                VideoExporter.exportVideoWithGraph(videoURL: url, emotionData: data) { exportedURL in
                    isExporting = false
                    if let exportedURL {
                        self.exportedVideoURL = exportedURL
                        self.showShareSheet   = true
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedVideoURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func toggleRecording() {
        if cameraManager.isRecording {
            cameraManager.stopRecording()
        } else {
            emotionDetector.startRecordingSession()
            cameraManager.startRecording()
        }
    }
}

// ── Live 1-Minute Moving Graph View ───────────────────────────────────────────

struct RollingEmotionGraphView: View {
    let history: [EmotionDataPoint]
    let currentEmotion: String
    let themeColor: Color
    
    private let windowDuration: Double = 60.0 // 1-minute window

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            let graphLeft = 52.0
            let graphRight = w - 16.0
            let graphW = max(10.0, graphRight - graphLeft)
            
            let graphTop = 26.0
            let graphBottom = h - 14.0
            let graphH = max(10.0, graphBottom - graphTop)
            
            let relaxedY = graphTop + (graphH * 0.15)
            let neutralY = graphTop + (graphH * 0.50)
            let stressedY = graphTop + (graphH * 0.85)
            
            // Calculate time bounds: window rolls forward once latest > 60s
            let latestTime = history.last?.time ?? 0.0
            let windowEnd = max(windowDuration, latestTime)
            let windowStart = max(0.0, windowEnd - windowDuration)
            
            ZStack(alignment: .topLeading) {
                // Background Card
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.70))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )

                // Header title
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("LIVE 1-MIN WINDOW")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                    Spacer()
                    Text("Past 60s")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                // Y-Axis Reference Guide Lines & Labels
                Group {
                    // Relaxed Guide
                    Text("Relaxed")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.8))
                        .position(x: 28, y: relaxedY)
                    Path { p in
                        p.move(to: CGPoint(x: graphLeft, y: relaxedY))
                        p.addLine(to: CGPoint(x: graphRight, y: relaxedY))
                    }
                    .stroke(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Neutral Guide
                    Text("Neutral")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.04).opacity(0.8))
                        .position(x: 28, y: neutralY)
                    Path { p in
                        p.move(to: CGPoint(x: graphLeft, y: neutralY))
                        p.addLine(to: CGPoint(x: graphRight, y: neutralY))
                    }
                    .stroke(Color(red: 1.0, green: 0.84, blue: 0.04).opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Stressed Guide
                    Text("Stressed")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.8))
                        .position(x: 28, y: stressedY)
                    Path { p in
                        p.move(to: CGPoint(x: graphLeft, y: stressedY))
                        p.addLine(to: CGPoint(x: graphRight, y: stressedY))
                    }
                    .stroke(Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                // Trend Curve
                if history.count >= 2 {
                    // Compute points
                    let points: [CGPoint] = history.map { pt in
                        let normX = min(max((pt.time - windowStart) / windowDuration, 0.0), 1.0)
                        let px = graphLeft + (normX * graphW)
                        let py: CGFloat
                        switch pt.emotion {
                        case "Relaxed":  py = relaxedY
                        case "Stressed": py = stressedY
                        default:         py = neutralY
                        }
                        return CGPoint(x: px, y: py)
                    }

                    // Area Fill Under Curve
                    Path { path in
                        guard let first = points.first, let last = points.last else { return }
                        path.move(to: CGPoint(x: first.x, y: graphBottom))
                        path.addLine(to: first)
                        for pt in points.dropFirst() {
                            path.addLine(to: pt)
                        }
                        path.addLine(to: CGPoint(x: last.x, y: graphBottom))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.25), Color.cyan.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Line Path
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for pt in points.dropFirst() {
                            path.addLine(to: pt)
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.6), Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )

                    // Leading Playhead Dot (Now)
                    if let last = points.last {
                        Circle()
                            .fill(themeColor)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .position(last)
                    }
                }
            }
        }
    }
}

// ── AVCaptureVideoPreviewLayer wrapper ─────────────────────────────────────────
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame        = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// ── UIActivityViewController wrapper ───────────────────────────────────────────
struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
