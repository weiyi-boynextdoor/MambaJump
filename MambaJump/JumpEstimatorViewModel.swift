import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class JumpEstimatorViewModel: ObservableObject {
    @Published var statusText = "Point the camera so your full body stays in frame."
    @Published var liveFootHeight = 0.0
    @Published var airTime = 0.0
    @Published var jumpHeightMeters = 0.0
    @Published var jumpHeightInches = 0.0
    @Published var isAirborne = false
    @Published var cameraAuthorized = false
    @Published var isUsingFrontCamera = false

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
    }

    func start() {
        detector.start()
    }

    func stop() {
        detector.stop()
    }

    func switchCamera() {
        resetCalibration()
        statusText = "Switching camera. Hold still to recalibrate."
        detector.switchCamera()
    }

    private func handle(observation: BodyPoseObservation?) {
        guard let observation else {
            statusText = cameraAuthorized
                ? "Body not detected. Step back until your full body is visible."
                : "Camera access is required to estimate jump height."
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
                let duration = CACurrentMediaTime() - airborneStart
                endJump(with: duration)
            }
        } else {
            statusText = "Ready. Jump straight up while keeping your feet visible."

            if delta >= takeoffThreshold {
                isAirborne = true
                airborneStart = CACurrentMediaTime()
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
        jumpHeightInches = estimatedHeight * 39.3701
        statusText = String(
            format: "Estimated jump: %.2f in (%.0f cm) from %.0f ms airtime.",
            jumpHeightInches,
            estimatedHeight * 100.0,
            duration * 1000.0
        )
    }
}
