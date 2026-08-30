import AVFoundation
import CoreImage
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false
    
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    
    var onFrameUpdate: ((CVPixelBuffer) -> Void)?
    var onRecordingFinished: ((URL) -> Void)?
    
    override init() {
        super.init()
        setupCamera()
    }
    
    private func setupCamera() {
        captureSession.sessionPreset = .high
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }
        
        // Ensure video is portrait
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if let connection = movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
        }
    }
    
    func startRecording() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        DispatchQueue.main.async { self.isRecording = true }
    }
    
    func stopRecording() {
        movieOutput.stopRecording()
        DispatchQueue.main.async { self.isRecording = false }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrameUpdate?(pixelBuffer)
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if error == nil {
            onRecordingFinished?(outputFileURL)
        } else {
            print("Recording error: \(String(describing: error))")
        }
    }
}
