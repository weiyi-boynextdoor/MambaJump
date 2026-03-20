# Android Body Detection Survey for Migrating MambaJump

For this app, the Android options narrow cleanly to three paths:

1. `ML Kit Pose Detection` if you want the closest high-level SDK replacement for Apple Vision.
2. `MediaPipe Pose Landmarker` if you want better control and a stronger fit for video analysis.
3. `TensorFlow Lite + MoveNet` only if you want to own the full stack.

For this specific use case, single-person jump detection from camera plus imported video, the recommendation is:

- Use `MediaPipe Pose Landmarker` if Android is a real product target and you want room to tune quality later.
- Use `ML Kit Pose Detection` if you want the fastest initial port from the current Vision-style architecture.

## Survey

### ML Kit Pose Detection

Best for: fastest Android migration with a simple app-level API.

Why it fits:

- It gives you 33 landmarks, per-landmark confidence, 2D coordinates, and a 3D position API with an experimental Z value.
- It has `STREAM_MODE` for tracked live input.
- It lets ML Kit pick `CPU` or `CPU_GPU`.

Good parts:

- Easy to wire into `CameraX`
- On-device
- Relatively small API surface
- Good for single-person tracking

Weak parts:

- Google labels it `beta` and explicitly says it has no SLA or compatibility guarantee.
- It adds app size, about `~10.1MB` for base and `~13.3MB` for accurate in the Android guide.

Practical note:

- For the imported-video flow, ML Kit can work, but it is less explicitly video-oriented than MediaPipe.

### MediaPipe Pose Landmarker

Best for: a stronger long-term Android body-pose stack.

Why it fits:

- It supports `IMAGE`, `VIDEO`, and `LIVE_STREAM` modes.
- It outputs 33 landmarks.
- It supports `numPoses`, optional segmentation masks, and 3D world coordinates.

Good parts:

- Better match for the current app because it has both live analysis and offline video scanning.
- More configurable.
- Easier to evolve into richer sports-analysis features.

Weak parts:

- More setup and more moving parts than ML Kit.
- Google labels the Solutions docs as `Preview`, so it is not as stable as an Apple system framework.

Practical note:

- If you later want multi-person scenes, segmentation, or more custom analytics, this is the path to want.

### TensorFlow Lite + MoveNet

Best for: maximum control.

Why it fits:

- MoveNet is fast and well known for fitness and wellness use cases.

Good parts:

- You fully own model choice, delegates, preprocessing, smoothing, and upgrade cadence.

Weak parts:

- This is the most engineering work.
- You need to handle camera pipeline, frame decoding, tracking, landmark smoothing, coordinate transforms, model packaging, and likely your own robustness heuristics.
- MoveNet's common single-person form is 17 keypoints, which is less rich than ML Kit or MediaPipe's 33-point topology.

Practical note:

- Do not start here unless you already know you need custom models.

## How They Differ From Apple Vision

### Vision

- System framework on Apple platforms. You do not ship the pose model yourself.
- Tight integration with `AVFoundation`, the Core ML ecosystem, and Apple hardware.
- 2D body pose gives 19 landmarks in Vision's body-landmarks documentation.
- Vision also has a 3D body pose request on newer OS versions; Apple says it detects 17 3D joints, and depth data can improve accuracy.
- Apple's 3D request is explicitly for the most prominent person.
- Overall feel: stable platform API, smaller app-bundle impact, strong Apple-only integration.

### ML Kit, MediaPipe, and TFLite on Android

- You ship SDKs and model assets as part of your app stack.
- More app-size impact and more integration choices.
- More cross-platform flexibility than Vision.
- More variation in maturity:
  - ML Kit Pose Detection: `beta`
  - MediaPipe Pose Landmarker: `Preview`
  - TFLite: stable runtime, but you own much more behavior yourself
- In exchange, Android options usually give you more direct model and control choices than Vision.

## Decision Guide

Choose `ML Kit` if:

- You want the quickest Android port.
- Single-person jump tracking is the main goal.
- You prefer a simpler detector API over flexibility.

Choose `MediaPipe` if:

- Imported video analysis matters a lot.
- You want better configurability and future headroom.
- You may later want multi-pose, segmentation, or richer motion features.

Choose `TFLite + MoveNet` if:

- You need custom models or fully controlled inference behavior.
- You are willing to build the missing infrastructure yourself.

## Bottom Line

For a near-1:1 migration of this app's current architecture, `ML Kit Pose Detection + CameraX` is the easiest mental replacement for Vision.

For the better Android-native foundation, especially because this app analyzes both live camera and selected video clips, `MediaPipe Pose Landmarker` is the stronger choice.

## Sources

- [ML Kit Pose Detection Android](https://developers.google.com/ml-kit/vision/pose-detection/android)
- [ML Kit PoseLandmark reference](https://developers.google.com/android/reference/com/google/mlkit/vision/pose/PoseLandmark)
- [MediaPipe Pose Landmarker Android](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker/android)
- [Apple Vision body landmarks](https://developer.apple.com/documentation/vision/body-landmarks)
- [Apple Vision 3D human body pose](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images)
- [TensorFlow MoveNet overview](https://www.tensorflow.org/hub/tutorials/movenet)
