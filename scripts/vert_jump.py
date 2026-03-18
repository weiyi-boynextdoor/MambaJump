#!/usr/bin/env python
"""
Estimate airtime and vertical jump height from an in-place jump video.

Example:
    conda activate base
    python scripts/vert_jump.py --video path/to/jump.mp4 --show
"""

from __future__ import annotations

import argparse
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np
try:
    import mediapipe as mp
except ImportError:
    mp = None


GRAVITY_MPS2 = 9.80665


@dataclass
class FrameMeasurement:
    frame_index: int
    time_seconds: float
    foot_y: float
    hip_y: float
    quality: float


@dataclass
class JumpResult:
    fps: float
    takeoff_frame: int
    landing_frame: int
    airtime_seconds: float
    jump_height_meters: float
    jump_height_cm: float
    baseline_foot_y: float
    baseline_hip_y: float


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_INPUT_DIR = SCRIPT_DIR / "inputs"
DEFAULT_OUTPUT_DIR = SCRIPT_DIR / "outputs"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Measure airtime and estimated vertical jump height from a single jump video."
    )
    parser.add_argument("--video", required=True, help="Path to the input jump video.")
    parser.add_argument(
        "--method",
        choices=("auto", "mediapipe", "color"),
        default="auto",
        help="Tracking method. Auto tries MediaPipe first and falls back to color-based tracking.",
    )
    parser.add_argument(
        "--model-complexity",
        type=int,
        default=1,
        choices=(0, 1, 2),
        help="MediaPipe Pose model complexity.",
    )
    parser.add_argument(
        "--visibility-threshold",
        type=float,
        default=0.60,
        help="Minimum landmark visibility required for frame measurements.",
    )
    parser.add_argument(
        "--baseline-seconds",
        type=float,
        default=0.50,
        help="Initial standing time used to estimate the baseline posture.",
    )
    parser.add_argument(
        "--takeoff-threshold-ratio",
        type=float,
        default=0.12,
        help="Foot lift threshold as a fraction of standing hip-to-foot distance.",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Display the annotated video while processing.",
    )
    parser.add_argument(
        "--save-video",
        type=Path,
        default=None,
        help="Optional path to save an annotated result video. Defaults to scripts/outputs.",
    )
    return parser.parse_args()


def landmark_y(
    landmarks: list,
    index: int,
) -> tuple[float, float]:
    landmark = landmarks[index]
    return landmark.y, landmark.visibility


def mean_pair(values: Iterable[float]) -> float:
    values = list(values)
    return sum(values) / len(values)


def resolve_video_path(video_arg: str) -> Path:
    candidate = Path(video_arg).expanduser()
    if candidate.is_absolute() and candidate.exists():
        return candidate.resolve()

    local_candidate = (Path.cwd() / candidate).resolve()
    if local_candidate.exists():
        return local_candidate

    input_candidate = (DEFAULT_INPUT_DIR / candidate).resolve()
    if input_candidate.exists():
        return input_candidate

    raise FileNotFoundError(f"Video file does not exist: {video_arg}")


def resolve_output_path(video_path: Path, save_video: Path | None) -> Path:
    if save_video is not None:
        output_path = save_video.expanduser()
        if not output_path.is_absolute():
            output_path = (Path.cwd() / output_path).resolve()
        return output_path

    DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    return (DEFAULT_OUTPUT_DIR / f"{video_path.stem}_analysis.mp4").resolve()


def open_video_io(video_path: Path, output_path: Path | None) -> tuple[cv2.VideoCapture, cv2.VideoWriter | None, float, int, int]:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise FileNotFoundError(f"Could not open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps <= 0:
        raise RuntimeError("Video FPS is unavailable.")

    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    writer = None
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        writer = cv2.VideoWriter(
            str(output_path),
            cv2.VideoWriter_fourcc(*"mp4v"),
            fps,
            (width, height),
        )

    return cap, writer, fps, width, height


def build_measurement_lookup(measurements: list[FrameMeasurement]) -> dict[int, FrameMeasurement]:
    return {item.frame_index: item for item in measurements}


def annotate_summary(frame: np.ndarray, result: JumpResult, method_used: str, status_text: str) -> None:
    lines = [
        f"Method: {method_used}",
        status_text,
        f"Airtime: {result.airtime_seconds:.3f} s",
        f"Height: {result.jump_height_cm:.1f} cm",
    ]
    y = 32
    for line in lines:
        cv2.putText(
            frame,
            line,
            (20, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.75,
            (40, 255, 40),
            2,
            cv2.LINE_AA,
        )
        y += 32


def annotate_jump_events(frame: np.ndarray, frame_index: int, result: JumpResult) -> str:
    if frame_index < result.takeoff_frame:
        return "State: before takeoff"
    if frame_index == result.takeoff_frame:
        cv2.putText(frame, "Takeoff", (20, 170), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 220, 255), 3, cv2.LINE_AA)
        return "State: takeoff"
    if frame_index < result.landing_frame:
        return "State: airborne"
    if frame_index == result.landing_frame:
        cv2.putText(frame, "Landing", (20, 170), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 220, 255), 3, cv2.LINE_AA)
        return "State: landing"
    return "State: after landing"


def render_color_output(
    video_path: Path,
    output_path: Path,
    measurements: list[FrameMeasurement],
    result: JumpResult,
    method_used: str,
    show: bool,
) -> None:
    cap, writer, _, _, _ = open_video_io(video_path, output_path)
    measurement_lookup = build_measurement_lookup(measurements)

    while True:
        ok, frame = cap.read()
        if not ok:
            break

        frame_index = int(cap.get(cv2.CAP_PROP_POS_FRAMES)) - 1
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        lower_red_1 = np.array([0, 90, 70], dtype=np.uint8)
        upper_red_1 = np.array([20, 255, 255], dtype=np.uint8)
        lower_red_2 = np.array([160, 90, 70], dtype=np.uint8)
        upper_red_2 = np.array([179, 255, 255], dtype=np.uint8)
        mask = cv2.bitwise_or(
            cv2.inRange(hsv, lower_red_1, upper_red_1),
            cv2.inRange(hsv, lower_red_2, upper_red_2),
        )
        overlay = frame.copy()
        overlay[mask > 0] = (0, 0, 255)
        frame = cv2.addWeighted(overlay, 0.25, frame, 0.75, 0)

        measurement = measurement_lookup.get(frame_index)
        if measurement is not None:
            foot_y = int(round(measurement.foot_y))
            cv2.line(frame, (0, foot_y), (frame.shape[1] - 1, foot_y), (255, 200, 0), 2)
            cv2.putText(
                frame,
                f"Foot y: {measurement.foot_y:.1f}",
                (20, frame.shape[0] - 30),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.7,
                (255, 200, 0),
                2,
                cv2.LINE_AA,
            )

        state_text = annotate_jump_events(frame, frame_index, result)
        annotate_summary(frame, result, method_used, state_text)

        if writer is not None:
            writer.write(frame)
        if show:
            cv2.imshow("Vertical Jump Analysis", frame)
            if cv2.waitKey(1) & 0xFF == 27:
                break

    cap.release()
    if writer is not None:
        writer.release()
    if show:
        cv2.destroyAllWindows()


def collect_color_measurements(video_path: Path) -> tuple[list[FrameMeasurement], float]:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise FileNotFoundError(f"Could not open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps <= 0:
        raise RuntimeError("Video FPS is unavailable.")

    measurements: list[FrameMeasurement] = []
    frame_index = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break

        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        lower_red_1 = np.array([0, 90, 70], dtype=np.uint8)
        upper_red_1 = np.array([20, 255, 255], dtype=np.uint8)
        lower_red_2 = np.array([160, 90, 70], dtype=np.uint8)
        upper_red_2 = np.array([179, 255, 255], dtype=np.uint8)

        mask = cv2.bitwise_or(
            cv2.inRange(hsv, lower_red_1, upper_red_1),
            cv2.inRange(hsv, lower_red_2, upper_red_2),
        )

        roi_mask = np.zeros_like(mask)
        roi_mask[650:1150, 180:540] = mask[650:1150, 180:540]
        ys, xs = np.where(roi_mask > 0)

        if ys.size >= 100:
            foot_y = float(np.percentile(ys, 95))
            hip_y = float(np.percentile(ys, 5))
            quality = min(1.0, ys.size / 1200.0)
            measurements.append(
                FrameMeasurement(
                    frame_index=frame_index,
                    time_seconds=frame_index / fps,
                    foot_y=foot_y,
                    hip_y=hip_y,
                    quality=quality,
                )
            )

        frame_index += 1

    cap.release()

    if len(measurements) < 10:
        raise RuntimeError(
            "Color-based fallback could not find enough shoe markers. Use brighter shoes or try MediaPipe."
        )

    return measurements, fps


def collect_measurements(
    video_path: Path,
    model_complexity: int,
    visibility_threshold: float,
    show: bool,
    save_video: Path | None,
) -> tuple[list[FrameMeasurement], float]:
    if mp is None:
        raise RuntimeError("MediaPipe is not installed.")

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise FileNotFoundError(f"Could not open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps <= 0:
        raise RuntimeError("Video FPS is unavailable.")

    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    writer = None
    if save_video is not None:
        save_video.parent.mkdir(parents=True, exist_ok=True)
        writer = cv2.VideoWriter(
            str(save_video),
            cv2.VideoWriter_fourcc(*"mp4v"),
            fps,
            (width, height),
        )

    if not hasattr(mp, "solutions"):
        raise RuntimeError(
            "This MediaPipe build does not expose the legacy solutions API required by the pose tracker."
        )

    mp_pose = mp.solutions.pose
    mp_drawing = mp.solutions.drawing_utils
    measurements: list[FrameMeasurement] = []

    with mp_pose.Pose(
        static_image_mode=False,
        model_complexity=model_complexity,
        enable_segmentation=False,
        smooth_landmarks=True,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    ) as pose:
        frame_index = 0
        while True:
            ok, frame = cap.read()
            if not ok:
                break

            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            result = pose.process(rgb)

            status_text = "Pose not detected"
            if result.pose_landmarks:
                landmarks = result.pose_landmarks.landmark

                left_ankle_y, left_ankle_vis = landmark_y(landmarks, mp_pose.PoseLandmark.LEFT_ANKLE)
                right_ankle_y, right_ankle_vis = landmark_y(landmarks, mp_pose.PoseLandmark.RIGHT_ANKLE)
                left_heel_y, left_heel_vis = landmark_y(landmarks, mp_pose.PoseLandmark.LEFT_HEEL)
                right_heel_y, right_heel_vis = landmark_y(landmarks, mp_pose.PoseLandmark.RIGHT_HEEL)
                left_hip_y, left_hip_vis = landmark_y(landmarks, mp_pose.PoseLandmark.LEFT_HIP)
                right_hip_y, right_hip_vis = landmark_y(landmarks, mp_pose.PoseLandmark.RIGHT_HIP)

                foot_y = mean_pair([left_ankle_y, right_ankle_y, left_heel_y, right_heel_y])
                hip_y = mean_pair([left_hip_y, right_hip_y])
                quality = min(
                    left_ankle_vis,
                    right_ankle_vis,
                    left_heel_vis,
                    right_heel_vis,
                    left_hip_vis,
                    right_hip_vis,
                )

                if quality >= visibility_threshold:
                    measurements.append(
                        FrameMeasurement(
                            frame_index=frame_index,
                            time_seconds=frame_index / fps,
                            foot_y=foot_y,
                            hip_y=hip_y,
                            quality=quality,
                        )
                    )
                    status_text = f"Tracking quality: {quality:.2f}"
                else:
                    status_text = f"Low visibility: {quality:.2f}"

                mp_drawing.draw_landmarks(
                    frame,
                    result.pose_landmarks,
                    mp_pose.POSE_CONNECTIONS,
                )

            cv2.putText(
                frame,
                status_text,
                (20, 30),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.8,
                (0, 255, 0),
                2,
                cv2.LINE_AA,
            )

            if writer is not None:
                writer.write(frame)

            if show:
                cv2.imshow("Vertical Jump Analysis", frame)
                if cv2.waitKey(1) & 0xFF == 27:
                    break

            frame_index += 1

    cap.release()
    if writer is not None:
        writer.release()
    if show:
        cv2.destroyAllWindows()

    if len(measurements) < 10:
        raise RuntimeError(
            "Not enough valid pose frames were found. Use a clearer side-view video with the full body visible."
        )

    return measurements, fps


def median_baseline(measurements: list[FrameMeasurement], baseline_seconds: float, fps: float) -> tuple[float, float]:
    baseline_count = max(5, int(round(baseline_seconds * fps)))
    baseline_frames = measurements[:baseline_count]
    if len(baseline_frames) < 5:
        raise RuntimeError("The baseline segment is too short to estimate standing posture.")

    baseline_foot_y = statistics.median([item.foot_y for item in baseline_frames])
    baseline_hip_y = statistics.median([item.hip_y for item in baseline_frames])
    return baseline_foot_y, baseline_hip_y


def detect_jump(
    measurements: list[FrameMeasurement],
    fps: float,
    baseline_seconds: float,
    takeoff_threshold_ratio: float,
) -> JumpResult:
    baseline_foot_y, baseline_hip_y = median_baseline(measurements, baseline_seconds, fps)
    standing_leg_length = max(1e-6, baseline_foot_y - baseline_hip_y)
    foot_lift_threshold = takeoff_threshold_ratio * standing_leg_length

    airborne_flags = [
        (baseline_foot_y - item.foot_y) > foot_lift_threshold for item in measurements
    ]

    min_airborne_frames = max(2, int(round(0.08 * fps)))
    consecutive = 0
    takeoff_index = None
    landing_index = None

    for idx, is_airborne in enumerate(airborne_flags):
        if is_airborne:
            consecutive += 1
            if consecutive == min_airborne_frames and takeoff_index is None:
                takeoff_index = idx - min_airborne_frames + 1
        else:
            if takeoff_index is not None and consecutive >= min_airborne_frames:
                landing_index = idx
                break
            consecutive = 0

    if takeoff_index is None:
        raise RuntimeError(
            "Could not detect takeoff. Try trimming the video so it starts from the standing position."
        )

    if landing_index is None:
        if consecutive >= min_airborne_frames:
            landing_index = len(measurements) - 1
        else:
            raise RuntimeError(
                "Could not detect landing. Make sure the full jump and landing are visible in the video."
            )

    takeoff_frame = measurements[takeoff_index].frame_index
    landing_frame = measurements[landing_index].frame_index
    airtime_seconds = max(0.0, (landing_frame - takeoff_frame) / fps)
    jump_height_meters = GRAVITY_MPS2 * airtime_seconds * airtime_seconds / 8.0

    return JumpResult(
        fps=fps,
        takeoff_frame=takeoff_frame,
        landing_frame=landing_frame,
        airtime_seconds=airtime_seconds,
        jump_height_meters=jump_height_meters,
        jump_height_cm=jump_height_meters * 100.0,
        baseline_foot_y=baseline_foot_y,
        baseline_hip_y=baseline_hip_y,
    )


def print_result(result: JumpResult) -> None:
    print("Vertical Jump Analysis")
    print("----------------------")
    print(f"FPS: {result.fps:.2f}")
    print(f"Takeoff frame: {result.takeoff_frame}")
    print(f"Landing frame: {result.landing_frame}")
    print(f"Airtime: {result.airtime_seconds:.3f} s")
    print(f"Estimated jump height: {result.jump_height_meters:.3f} m")
    print(f"Estimated jump height: {result.jump_height_cm:.1f} cm")


def main() -> None:
    args = parse_args()
    video_path = resolve_video_path(args.video)
    output_path = resolve_output_path(video_path, args.save_video)

    measurement_error = None
    method_used = args.method
    if args.method in ("auto", "mediapipe"):
        try:
            measurements, fps = collect_measurements(
                video_path=video_path,
                model_complexity=args.model_complexity,
                visibility_threshold=args.visibility_threshold,
                show=args.show,
                save_video=output_path,
            )
            method_used = "mediapipe"
        except Exception as exc:
            measurement_error = exc
            if args.method == "mediapipe":
                raise
            measurements, fps = collect_color_measurements(video_path=video_path)
            method_used = "color"
    else:
        measurements, fps = collect_color_measurements(video_path=video_path)
        method_used = "color"

    result = detect_jump(
        measurements=measurements,
        fps=fps,
        baseline_seconds=args.baseline_seconds,
        takeoff_threshold_ratio=args.takeoff_threshold_ratio,
    )
    if measurement_error is not None:
        print(f"MediaPipe unavailable, used fallback method instead: {measurement_error}")
    if method_used == "color":
        render_color_output(
            video_path=video_path,
            output_path=output_path,
            measurements=measurements,
            result=result,
            method_used=method_used,
            show=args.show,
        )
    print(f"Input video: {video_path}")
    print(f"Output video: {output_path}")
    print(f"Tracking method: {method_used}")
    print_result(result)


if __name__ == "__main__":
    main()
