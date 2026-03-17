import AVFoundation
import CoreImage
import QuartzCore
import SwiftUI
import Vision

struct BodyPoseObservation {
    let footY: CGFloat
    let ankleY: CGFloat
    let kneeY: CGFloat
    let hipY: CGFloat
}

final class CameraPoseDetector: NSObject, ObservableObject {
    let session = AVCaptureSession()

    var onObservation: ((BodyPoseObservation?) -> Void)?
    var onAuthorizationChange: ((Bool) -> Void)?

    private let sessionQueue = DispatchQueue(label: "mambajump.camera.session")
    private let visionQueue = DispatchQueue(label: "mambajump.camera.vision")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var latestTimestamp = CMTime.invalid

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            onAuthorizationChange?(true)
            configureAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.onAuthorizationChange?(granted)
                if granted {
                    self?.configureAndStartSession()
                }
            }
        default:
            onAuthorizationChange?(false)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.onObservation?(nil)
                }
                return
            }

            self.session.addInput(input)

            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)

            guard self.session.canAddOutput(self.videoOutput) else {
                self.session.commitConfiguration()
                return
            }

            self.session.addOutput(self.videoOutput)
            self.videoOutput.connection(with: .video)?.videoRotationAngle = 90

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    private func processBodyPose(in sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onObservation?(nil)
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp != latestTimestamp else { return }
        latestTimestamp = timestamp

        let request = VNDetectHumanBodyPoseRequest()

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            try handler.perform([request])

            guard let result = request.results?.first else {
                DispatchQueue.main.async { [weak self] in
                    self?.onObservation?(nil)
                }
                return
            }

            let recognizedPoints = try result.recognizedPoints(.all)

            let anklePoints = [recognizedPoints[.leftAnkle], recognizedPoints[.rightAnkle]]
                .compactMap(validPoint)
            let kneePoints = [recognizedPoints[.leftKnee], recognizedPoints[.rightKnee]]
                .compactMap(validPoint)
            let hipPoints = [recognizedPoints[.leftHip], recognizedPoints[.rightHip]]
                .compactMap(validPoint)

            guard
                let ankleY = medianY(from: anklePoints) ?? medianY(from: kneePoints),
                let kneeY = medianY(from: kneePoints) ?? medianY(from: hipPoints),
                let hipY = medianY(from: hipPoints)
            else {
                DispatchQueue.main.async { [weak self] in
                    self?.onObservation?(nil)
                }
                return
            }

            // Prefer ankles, but allow knees when feet are partially occluded.
            let footY = medianY(from: anklePoints) ?? max(0, kneeY - 0.08)
            let observation = BodyPoseObservation(footY: footY, ankleY: ankleY, kneeY: kneeY, hipY: hipY)

            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(observation)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(nil)
            }
        }
    }

    private func validPoint(_ point: VNRecognizedPoint?) -> VNRecognizedPoint? {
        guard let point, point.confidence >= 0.2 else { return nil }
        return point
    }

    private func medianY(from points: [VNRecognizedPoint]) -> CGFloat? {
        guard !points.isEmpty else { return nil }
        let sorted = points.map(\.location.y).sorted()
        return sorted[sorted.count / 2]
    }
}

extension CameraPoseDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processBodyPose(in: sampleBuffer)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

