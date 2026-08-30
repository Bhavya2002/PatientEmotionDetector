import SwiftUI
import UIKit
import AVFoundation

struct LiveSessionView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var emotionDetector = EmotionDetector()
    
    @State private var exportedVideoURL: URL?
    @State private var isExporting = false
    @State private var showShareSheet = false
    
    var body: some View {
        ZStack {
            // Camera Preview Background
            CameraPreview(session: cameraManager.captureSession)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                // Live Emotion Overlay
                Text(emotionDetector.currentEmotion)
                    .font(.largeTitle)
                    .bold()
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.yellow)
                    .cornerRadius(10)
                    .padding(.top, 50)
                
                Spacer()
                
                if isExporting {
                    ProgressView("Processing Video...")
                        .padding()
                        .background(Color.white)
                        .cornerRadius(10)
                        .padding(.bottom, 50)
                } else {
                    Button(action: toggleRecording) {
                        Circle()
                            .fill(cameraManager.isRecording ? Color.red : Color.white)
                            .frame(width: 70, height: 70)
                            .overlay(
                                Circle().stroke(Color.white, lineWidth: 2)
                                    .frame(width: 80, height: 80)
                            )
                    }
                    .padding(.bottom, 50)
                }
            }
        }
        .onAppear {
            cameraManager.onFrameUpdate = { pixelBuffer in
                emotionDetector.processFrame(pixelBuffer)
            }
            
            cameraManager.onRecordingFinished = { url in
                isExporting = true
                let data = emotionDetector.stopRecordingSession()
                VideoExporter.exportVideoWithGraph(videoURL: url, emotionData: data) { exportedURL in
                    isExporting = false
                    if let exportedURL = exportedURL {
                        self.exportedVideoURL = exportedURL
                        self.showShareSheet = true
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
    
    func toggleRecording() {
        if cameraManager.isRecording {
            cameraManager.stopRecording()
        } else {
            emotionDetector.startRecordingSession()
            cameraManager.startRecording()
        }
    }
}

// SwiftUI Wrapper for AVCaptureVideoPreviewLayer
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// SwiftUI Wrapper for UIActivityViewController
struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
