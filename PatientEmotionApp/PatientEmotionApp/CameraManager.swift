import AVFoundation
import CoreImage
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var currentPosition: AVCaptureDevice.Position = .back

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var currentInput: AVCaptureDeviceInput?

    var onFrameUpdate: ((CVPixelBuffer, AVCaptureDevice.Position) -> Void)?
    var onRecordingFinished: ((URL) -> Void)?

    override init() {
        super.init()
        setupCamera(position: .back)
    }

    private func setupCamera(position: AVCaptureDevice.Position) {
        captureSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        // Remove previous input if any
        if let existing = currentInput {
            captureSession.removeInput(existing)
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            currentInput = input
        }

        // Add outputs only on first setup
        if captureSession.outputs.isEmpty {
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
            if captureSession.canAddOutput(movieOutput) { captureSession.addOutput(movieOutput) }
        }

        updateConnectionOrientations()

        DispatchQueue.main.async { self.currentPosition = position }
    }

    private func updateConnectionOrientations() {
        if let conn = videoOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
            conn.isVideoMirrored = (currentPosition == .front)
        }
        if let conn = movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
            conn.isVideoMirrored = (currentPosition == .front)
        }
    }

    func flipCamera() {
        guard !isRecording else { return }   // Don't flip mid-recording
        let newPosition: AVCaptureDevice.Position = (currentPosition == .back) ? .front : .back
        captureSession.beginConfiguration()
        setupCamera(position: newPosition)
        captureSession.commitConfiguration()
    }

    func startSession() {
        DispatchQueue.global(qos: .background).async {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
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
        onFrameUpdate?(pixelBuffer, currentPosition)
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
