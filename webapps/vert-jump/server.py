from __future__ import annotations

import uuid
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory
from werkzeug.utils import secure_filename

from analyzer import analyze_uploaded_video


APP_DIR = Path(__file__).resolve().parent
RUNTIME_DIR = APP_DIR / "runtime"
UPLOAD_DIR = RUNTIME_DIR / "uploads"
OUTPUT_DIR = RUNTIME_DIR / "outputs"

for directory in (UPLOAD_DIR, OUTPUT_DIR):
	directory.mkdir(parents=True, exist_ok=True)


app = Flask(__name__, static_folder=".", static_url_path="")
app.config["MAX_CONTENT_LENGTH"] = 512 * 1024 * 1024


@app.get("/")
def index():
	return send_from_directory(APP_DIR, "index.html")


@app.get("/outputs/<path:filename>")
def outputs(filename: str):
	return send_from_directory(OUTPUT_DIR, filename, as_attachment=False)


@app.post("/api/analyze")
def analyze():
	uploaded_file = request.files.get("video")
	if uploaded_file is None or uploaded_file.filename == "":
		return jsonify({"error": "A video file is required."}), 400

	try:
		baseline_seconds = float(request.form.get("baseline_seconds", "0.5"))
		takeoff_threshold_ratio = float(request.form.get("takeoff_threshold_ratio", "0.12"))
	except ValueError:
		return jsonify({"error": "Invalid numeric parameters."}), 400

	job_id = uuid.uuid4().hex
	original_name = secure_filename(uploaded_file.filename) or f"{job_id}.mp4"
	input_path = UPLOAD_DIR / f"{job_id}_{original_name}"
	annotated_name = f"{Path(original_name).stem}_analysis.mp4"
	output_path = OUTPUT_DIR / f"{job_id}_{annotated_name}"
	uploaded_file.save(input_path)

	try:
		result = analyze_uploaded_video(
			video_path=input_path,
			output_path=output_path,
			baseline_seconds=baseline_seconds,
			takeoff_threshold_ratio=takeoff_threshold_ratio,
		)
	except Exception as exc:
		if input_path.exists():
			input_path.unlink()
		if output_path.exists():
			output_path.unlink()
		return jsonify({"error": str(exc)}), 500

	result["annotated_video_url"] = f"/outputs/{output_path.name}"
	result["output_video_name"] = output_path.name
	return jsonify({"result": result})


if __name__ == "__main__":
	app.run(host="0.0.0.0", port=8000, debug=True)
