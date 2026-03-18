import AVFoundation
import CoreGraphics
import Foundation
import UIKit

@MainActor
final class JumpEstimatorViewModel: ObservableObject {
    enum InputMode {
        case liveCamera
        case importedVideo
    }

    @Published var statusText = "Point the camera so your full body stays in frame."
    @Published var liveFootHeight = 0.0
    @Published var airTime = 0.0
    @Published var jumpHeightMeters = 0.0
    @Published var isAirborne = false
    @Published var cameraAuthorized = false
    @Published var isUsingFrontCamera = false
    @Published var isAnalyzingImportedVideo = false
    @Published var inputMode: InputMode = .liveCamera
    @Published var importedVideoName = ""
    @Published var importedVideoThumbnail: UIImage?

    let detector = CameraPoseDetector()

    private var baselineFootY: CGFloat?
    private var airborneStart: CFTimeInterval?
    private var recentGroundSamples: [CGFloat] = []

    private let baselineWindow = 20
    private let takeoffThreshold: CGFloat = 0.05
    private let landingThreshold: CGFloat = 0.025
    private let minimumFlightTime = 0.12
    private let gravity = 9.80665

    init() {
        detector.onObservation = { [weak self] observation in
            Task { @MainActor in
                self?.handle(observation: observation)
            }
        }

        detector.onAuthorizationChange = { [weak self] granted in
            Task { @MainActor in
                self?.cameraAuthorized = granted
                self?.statusText = granted
                    ? "Calibrating your standing foot position. Hold still for a moment."
                    : "Camera access is required to estimate jump height."
            }
        }

        detector.onCameraPositionChange = { [weak self] position in
            Task { @MainActor in
                self?.isUsingFrontCamera = position == .front
            }
        }

        detector.onVideoAnalysisStateChange = { [weak self] isRunning in
            Task { @MainActor in
                self?.isAnalyzingImportedVideo = isRunning
            }
        }

        detector.onVideoAnalysisCompletion = { [weak self] success in
            Task { @MainActor in
                guard let self else { return }

                if success {
                    if self.airTime == 0 {
                        self.statusText = "Video analysis finished, but no jump was confidently detected."
                    }
                } else {
                    self.statusText = "Could not analyze that video. Try a clear clip with your full body visible."
                }
            }
        }
    }

    func start() {
        detector.start()
    }

    func stop() {
        detector.stop()
    }

    func switchCamera() {
        guard inputMode == .liveCamera else { return }
        resetCalibration()
        statusText = "Switching camera. Hold still to recalibrate."
        detector.switchCamera()
    }

    func useLiveCamera() {
        inputMode = .liveCamera
        importedVideoName = ""
        importedVideoThumbnail = nil
        resetMeasurement()
        statusText = cameraAuthorized
            ? "Point the camera so your full body stays in frame."
            : "Camera access is required to estimate jump height."
        detector.start()
    }

    func analyzeImportedVideo(at url: URL) {
        inputMode = .importedVideo
        importedVideoName = url.lastPathComponent
        importedVideoThumbnail = thumbnail(for: url)
        resetMeasurement()
        statusText = "Analyzing \(url.lastPathComponent)..."
        detector.analyzeVideo(at: url)
    }

    private func handle(observation: BodyPoseObservation?) {
        guard let observation else {
            if isAnalyzingImportedVideo {
                statusText = "Scanning imported video for a full-body pose..."
            } else {
                statusText = cameraAuthorized
                    ? "Body not detected. Step back until your full body is visible."
                    : "Camera access is required to estimate jump height."
            }
            return
        }

        let footY = observation.footY
        liveFootHeight = Double(footY)

        if !isAirborne {
            appendGroundSample(footY)
        }

        guard let baselineFootY else {
            statusText = "Calibrating your standing foot position. Hold still for a moment."
            return
        }

        let delta = footY - baselineFootY

        if isAirborne {
            statusText = "Airborne. Keep your full body in frame."

            if delta <= landingThreshold, let airborneStart {
                let duration = observation.timestamp - airborneStart
                endJump(with: duration)
            }
        } else {
            statusText = "Ready. Jump straight up while keeping your feet visible."

            if delta >= takeoffThreshold {
                isAirborne = true
                airborneStart = observation.timestamp
                statusText = "Jump detected. Measuring airtime."
            }
        }
    }

    private func appendGroundSample(_ footY: CGFloat) {
        recentGroundSamples.append(footY)
        if recentGroundSamples.count > baselineWindow {
            recentGroundSamples.removeFirst()
        }

        let sorted = recentGroundSamples.sorted()
        baselineFootY = sorted[sorted.count / 2]
    }

    private func resetCalibration() {
        baselineFootY = nil
        airborneStart = nil
        recentGroundSamples.removeAll(keepingCapacity: true)
        isAirborne = false
        liveFootHeight = 0
    }

    private func resetMeasurement() {
        resetCalibration()
        airTime = 0
        jumpHeightMeters = 0
    }

    private func thumbnail(for url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        for time in [CMTime(seconds: 0.1, preferredTimescale: 600), .zero] {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }

    private func endJump(with duration: CFTimeInterval) {
        isAirborne = false
        airborneStart = nil

        guard duration >= minimumFlightTime else {
            statusText = "Movement was too short to count as a jump. Try again."
            return
        }

        airTime = duration

        let estimatedHeight = gravity * pow(duration, 2) / 8.0
        jumpHeightMeters = estimatedHeight
        statusText = String(
            format: "Estimated jump: %.0f cm from %.0f ms airtime.",
            estimatedHeight * 100.0,
            duration * 1000.0
        )
    }
}
