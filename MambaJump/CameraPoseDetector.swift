import AVFoundation
import CoreImage
import ImageIO
import QuartzCore
import SwiftUI
import Vision

struct BodyPoseObservation {
    let footY: CGFloat
    let ankleY: CGFloat
    let kneeY: CGFloat
    let hipY: CGFloat
    let timestamp: CFTimeInterval
}

final class CameraPoseDetector: NSObject, ObservableObject {
    let session = AVCaptureSession()

    var onObservation: ((BodyPoseObservation?) -> Void)?
    var onAuthorizationChange: ((Bool) -> Void)?
    var onCameraPositionChange: ((AVCaptureDevice.Position) -> Void)?
    var onVideoAnalysisStateChange: ((Bool) -> Void)?
    var onVideoAnalysisCompletion: ((Bool) -> Void)?

    private let sessionQueue = DispatchQueue(label: "mambajump.camera.session")
    private let visionQueue = DispatchQueue(label: "mambajump.camera.vision")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var latestTimestamp = CMTime.invalid
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var isAnalyzingVideo = false

    func start() {
        guard !isAnalyzingVideo else { return }
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

    func switchCamera() {
        guard !isAnalyzingVideo else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let nextPosition: AVCaptureDevice.Position = self.currentCameraPosition == .back ? .front : .back
            guard self.configureSessionInput(for: nextPosition) else { return }

            self.currentCameraPosition = nextPosition
            self.latestTimestamp = .invalid
            self.configureVideoConnection()

            DispatchQueue.main.async {
                self.onCameraPositionChange?(nextPosition)
                self.onObservation?(nil)
            }
        }
    }

    func analyzeVideo(at url: URL, timeRange: ClosedRange<Double>? = nil) {
        stop()

        visionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isAnalyzingVideo else { return }

            self.isAnalyzingVideo = true
            self.latestTimestamp = .invalid

            DispatchQueue.main.async {
                self.onVideoAnalysisStateChange?(true)
                self.onObservation?(nil)
            }

            let success = self.processVideoAsset(at: url, timeRange: timeRange)
            self.isAnalyzingVideo = false

            DispatchQueue.main.async {
                self.onVideoAnalysisStateChange?(false)
                self.onVideoAnalysisCompletion?(success)
            }
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard self.configureSessionInput(for: self.currentCameraPosition) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.onObservation?(nil)
                }
                return
            }

            if !self.session.outputs.contains(self.videoOutput) {
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
            }

            self.configureVideoConnection()

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.onCameraPositionChange?(self.currentCameraPosition)
            }
        }
    }

    private func configureSessionInput(for position: AVCaptureDevice.Position) -> Bool {
        session.inputs.forEach { session.removeInput($0) }

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            return false
        }

        session.addInput(input)
        return true
    }

    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        connection.videoRotationAngle = 90

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = currentCameraPosition == .front
        }
    }

    private func processBodyPose(in sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp != latestTimestamp else { return }
        latestTimestamp = timestamp

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(nil)
            }
            return
        }

        processPixelBuffer(
            pixelBuffer,
            orientation: currentCameraPosition == .front ? .leftMirrored : .right,
            timestamp: timestamp.seconds
        )
    }

    private func processPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: CFTimeInterval
    ) {
        let request = VNDetectHumanBodyPoseRequest()

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
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
            let observation = BodyPoseObservation(
                footY: footY,
                ankleY: ankleY,
                kneeY: kneeY,
                hipY: hipY,
                timestamp: timestamp
            )

            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(observation)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(nil)
            }
        }
    }

    private func processVideoAsset(at url: URL, timeRange: ClosedRange<Double>?) -> Bool {
        let asset = AVURLAsset(url: url)

        guard
            let track = asset.tracks(withMediaType: .video).first,
            let reader = try? AVAssetReader(asset: asset)
        else {
            return false
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { return false }
        reader.add(output)

        if let timeRange {
            let start = max(0, timeRange.lowerBound)
            let duration = max(0, timeRange.upperBound - start)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
        }

        reader.startReading()

        let orientation = orientation(for: track.preferredTransform)
        var processedFrameCount = 0

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            let frameNumber = processedFrameCount
            processedFrameCount += 1

            // Analyze every other frame to keep imports responsive while staying stable enough for airtime detection.
            guard frameNumber.isMultiple(of: 2) else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            processPixelBuffer(pixelBuffer, orientation: orientation, timestamp: timestamp)
        }

        return reader.status == .completed && processedFrameCount > 0
    }

    private func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0):
            return .right
        case (0, -1, 1, 0):
            return .left
        case (1, 0, 0, 1):
            return .up
        case (-1, 0, 0, -1):
            return .down
        default:
            return .up
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
    let isMirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        view.videoPreviewLayer.connection?.isVideoMirrored = isMirrored
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.videoPreviewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        uiView.videoPreviewLayer.connection?.isVideoMirrored = isMirrored
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
