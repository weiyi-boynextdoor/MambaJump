import AVFoundation
import CoreGraphics
import Foundation
import UIKit

@MainActor
final class JumpEstimatorViewModel: ObservableObject {
    enum InputMode {
        case idle
        case liveCamera
        case importedVideo
    }

    @Published var statusText = "Choose a video or the live camera to start."
    @Published var liveFootHeight = 0.0
    @Published var airTime = 0.0
    @Published var jumpHeightMeters = 0.0
    @Published var isAirborne = false
    @Published var cameraAuthorized = false
    @Published var isUsingFrontCamera = false
    @Published var isAnalyzingImportedVideo = false
    @Published var inputMode: InputMode = .idle
    @Published var importedVideoName = ""
    @Published var importedVideoThumbnail: UIImage?
    @Published var importedVideoDuration = 0.0
    @Published var importedVideoStartTime = 0.0
    @Published var importedVideoEndTime = 0.0
    @Published var importedVideoStartThumbnail: UIImage?
    @Published var importedVideoEndThumbnail: UIImage?

    let detector = CameraPoseDetector()

    private var baselineFootY: CGFloat?
    private var airborneStart: CFTimeInterval?
    private var recentGroundSamples: [CGFloat] = []
    private var importedVideoURL: URL?

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
        statusText = "Choose a video or the live camera to start."
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
        importedVideoURL = nil
        importedVideoName = ""
        importedVideoThumbnail = nil
        importedVideoDuration = 0
        importedVideoStartTime = 0
        importedVideoEndTime = 0
        importedVideoStartThumbnail = nil
        importedVideoEndThumbnail = nil
        resetMeasurement()
        statusText = cameraAuthorized
            ? "Point the camera so your full body stays in frame."
            : "Camera access is required to estimate jump height."
        detector.start()
    }

    func analyzeImportedVideo(at url: URL) {
        inputMode = .importedVideo
        detector.stop()
        importedVideoURL = url
        importedVideoName = url.lastPathComponent
        importedVideoDuration = duration(for: url)
        updateImportedVideoSelection(start: 0, end: importedVideoDuration)
        importedVideoThumbnail = thumbnail(for: url, at: importedVideoStartTime)
        analyzeSelectedImportedVideo()
    }

    func setImportedVideoStartTime(_ time: Double) {
        let clamped = max(0, min(time, importedVideoDuration))
        updateImportedVideoSelection(start: min(clamped, importedVideoEndTime), end: importedVideoEndTime)
    }

    func setImportedVideoEndTime(_ time: Double) {
        let clamped = max(0, min(time, importedVideoDuration))
        updateImportedVideoSelection(start: importedVideoStartTime, end: max(clamped, importedVideoStartTime))
    }

    func analyzeSelectedImportedVideo() {
        guard let importedVideoURL else { return }

        resetMeasurement()
        importedVideoThumbnail = thumbnail(for: importedVideoURL, at: importedVideoStartTime)
        statusText = analysisStatusText(for: importedVideoName)
        detector.analyzeVideo(at: importedVideoURL, timeRange: selectedImportedVideoRange)
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
                endJump(with: duration, takeoffTime: airborneStart, landingTime: observation.timestamp)
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

    private var selectedImportedVideoRange: ClosedRange<Double>? {
        guard importedVideoDuration > 0 else { return nil }

        let start = max(0, min(importedVideoStartTime, importedVideoDuration))
        let end = max(start, min(importedVideoEndTime, importedVideoDuration))
        return start...end
    }

    private func duration(for url: URL) -> Double {
        let seconds = AVURLAsset(url: url).duration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func refreshImportedVideoFramePreviews() {
        guard let importedVideoURL else {
            importedVideoStartThumbnail = nil
            importedVideoEndThumbnail = nil
            return
        }

        importedVideoStartThumbnail = thumbnail(for: importedVideoURL, at: importedVideoStartTime)
        importedVideoEndThumbnail = thumbnail(for: importedVideoURL, at: importedVideoEndTime)
    }

    private func updateImportedVideoSelection(start: Double, end: Double) {
        let clampedStart = max(0, min(start, importedVideoDuration))
        let clampedEnd = max(clampedStart, min(end, importedVideoDuration))
        importedVideoStartTime = clampedStart
        importedVideoEndTime = clampedEnd
        refreshImportedVideoFramePreviews()
    }

    private func analysisStatusText(for videoName: String) -> String {
        let duration = max(0, importedVideoEndTime - importedVideoStartTime)

        if duration > 0, duration < importedVideoDuration {
            return String(
                format: "Analyzing %@ from %.2fs to %.2fs...",
                videoName,
                importedVideoStartTime,
                importedVideoEndTime
            )
        }

        return "Analyzing \(videoName)..."
    }

    private func thumbnail(for url: URL, at seconds: Double) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)

        let clampedSeconds = max(0, min(seconds, max(0, asset.duration.seconds)))
        let requestedTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)

        for time in [requestedTime, CMTime(seconds: 0.1, preferredTimescale: 600), .zero] {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }

    private func endJump(
        with duration: CFTimeInterval,
        takeoffTime: CFTimeInterval,
        landingTime: CFTimeInterval
    ) {
        isAirborne = false
        airborneStart = nil

        guard duration >= minimumFlightTime else {
            statusText = "Movement was too short to count as a jump. Try again."
            return
        }

        airTime = duration

        let estimatedHeight = gravity * pow(duration, 2) / 8.0
        jumpHeightMeters = estimatedHeight

        if inputMode == .importedVideo {
            updateImportedVideoSelection(start: takeoffTime, end: landingTime)
            if let importedVideoURL {
                importedVideoThumbnail = importedVideoStartThumbnail ?? thumbnail(for: importedVideoURL, at: takeoffTime)
            }
            statusText = String(
                format: "Estimated jump: %.0f cm from %.0f ms airtime. Start and end frames were selected automatically.",
                estimatedHeight * 100.0,
                duration * 1000.0
            )
            return
        }

        statusText = String(
            format: "Estimated jump: %.0f cm from %.0f ms airtime.",
            estimatedHeight * 100.0,
            duration * 1000.0
        )
    }
}
