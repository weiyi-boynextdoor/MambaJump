from __future__ import annotations

import statistics
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


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
		if not writer.isOpened():
			cap.release()
			raise RuntimeError(f"Could not open video writer for output file: {output_path}")

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
	method_used: str = "color",
) -> None:
	cap, writer, _, _, _ = open_video_io(video_path, output_path)
	measurement_lookup = build_measurement_lookup(measurements)

	try:
		while True:
			ok, frame = cap.read()
			if not ok:
				break

			frame_index = int(cap.get(cv2.CAP_PROP_POS_FRAMES)) - 1
			hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
			mask = cv2.bitwise_or(
				cv2.inRange(hsv, np.array([0, 90, 70], dtype=np.uint8), np.array([20, 255, 255], dtype=np.uint8)),
				cv2.inRange(hsv, np.array([160, 90, 70], dtype=np.uint8), np.array([179, 255, 255], dtype=np.uint8)),
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
	finally:
		cap.release()
		if writer is not None:
			writer.release()


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
		mask = cv2.bitwise_or(
			cv2.inRange(hsv, np.array([0, 90, 70], dtype=np.uint8), np.array([20, 255, 255], dtype=np.uint8)),
			cv2.inRange(hsv, np.array([160, 90, 70], dtype=np.uint8), np.array([179, 255, 255], dtype=np.uint8)),
		)

		roi_mask = np.zeros_like(mask)
		roi_mask[650:1150, 180:540] = mask[650:1150, 180:540]
		ys, _ = np.where(roi_mask > 0)

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
		raise RuntimeError("Not enough consistent motion features were found. Use a clearer video with the athlete fully visible.")

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
	airborne_flags = [(baseline_foot_y - item.foot_y) > foot_lift_threshold for item in measurements]
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
		raise RuntimeError("Could not detect takeoff. Try trimming the video so it starts from the standing position.")

	if landing_index is None:
		if consecutive >= min_airborne_frames:
			landing_index = len(measurements) - 1
		else:
			raise RuntimeError("Could not detect landing. Make sure the full jump and landing are visible in the video.")

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


def analyze_uploaded_video(
	video_path: Path,
	output_path: Path,
	baseline_seconds: float,
	takeoff_threshold_ratio: float,
) -> dict:
	measurements, fps = collect_color_measurements(video_path)
	result = detect_jump(
		measurements=measurements,
		fps=fps,
		baseline_seconds=baseline_seconds,
		takeoff_threshold_ratio=takeoff_threshold_ratio,
	)
	render_color_output(video_path, output_path, measurements, result, method_used="python-color")

	return {
		"method": "Python color tracking",
		"fps": result.fps,
		"takeoff_frame": result.takeoff_frame,
		"landing_frame": result.landing_frame,
		"airtime_seconds": result.airtime_seconds,
		"jump_height_meters": result.jump_height_meters,
		"jump_height_cm": result.jump_height_cm,
	}
