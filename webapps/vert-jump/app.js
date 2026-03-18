const dom = {
	videoFile: document.getElementById("videoFile"),
	baselineSeconds: document.getElementById("baselineSeconds"),
	takeoffRatio: document.getElementById("takeoffRatio"),
	analyzeButton: document.getElementById("analyzeButton"),
	statusBanner: document.getElementById("statusBanner"),
	sourcePreview: document.getElementById("sourcePreview"),
	resultPreview: document.getElementById("resultPreview"),
	metricMethod: document.getElementById("metricMethod"),
	metricAirtime: document.getElementById("metricAirtime"),
	metricHeight: document.getElementById("metricHeight"),
	metricFrames: document.getElementById("metricFrames"),
	originalMeta: document.getElementById("originalMeta"),
	annotatedMeta: document.getElementById("annotatedMeta"),
	downloadLink: document.getElementById("downloadLink"),
};

let selectedFile = null;
let sourceObjectUrl = null;

dom.videoFile.addEventListener("change", handleFileSelection);
dom.analyzeButton.addEventListener("click", runAnalysis);

function handleFileSelection(event) {
	const [file] = event.target.files ?? [];
	selectedFile = file ?? null;
	dom.analyzeButton.disabled = !selectedFile;
	resetAnnotatedVideo();

	if (!selectedFile) {
		setStatus("Select a video to begin.", "idle");
		dom.originalMeta.textContent = "No file loaded.";
		dom.sourcePreview.removeAttribute("src");
		dom.sourcePreview.load();
		return;
	}

	if (sourceObjectUrl) {
		URL.revokeObjectURL(sourceObjectUrl);
	}

	sourceObjectUrl = URL.createObjectURL(selectedFile);
	dom.sourcePreview.src = sourceObjectUrl;
	dom.sourcePreview.load();
	dom.originalMeta.textContent = `${selectedFile.name} - ${(selectedFile.size / 1024 / 1024).toFixed(2)} MB`;
	setStatus("Video loaded. Ready to upload for server-side analysis.", "idle");
}

async function runAnalysis() {
	if (!selectedFile) {
		return;
	}

	dom.analyzeButton.disabled = true;
	resetAnnotatedVideo();
	setStatus("Uploading video and running Python analysis on the server.", "running");

	try {
		const formData = new FormData();
		formData.append("video", selectedFile);
		formData.append("baseline_seconds", dom.baselineSeconds.value);
		formData.append("takeoff_threshold_ratio", dom.takeoffRatio.value);

		const response = await fetch("/api/analyze", {
			method: "POST",
			body: formData,
		});
		const payload = await response.json();
		if (!response.ok) {
			throw new Error(payload.error || "Analysis failed.");
		}

		updateMetrics(payload.result);
		dom.resultPreview.src = payload.result.annotated_video_url;
		dom.resultPreview.load();
		dom.annotatedMeta.textContent = payload.result.output_video_name;
		dom.downloadLink.href = payload.result.annotated_video_url;
		dom.downloadLink.download = payload.result.output_video_name;
		dom.downloadLink.classList.remove("disabled");
		setStatus("Analysis complete. Review the metrics and preview the annotated replay.", "success");
	} catch (error) {
		console.error(error);
		setStatus(error instanceof Error ? error.message : "Analysis failed.", "error");
	} finally {
		dom.analyzeButton.disabled = !selectedFile;
	}
}

function updateMetrics(result) {
	dom.metricMethod.textContent = result.method;
	dom.metricAirtime.textContent = `${result.airtime_seconds.toFixed(3)} s`;
	dom.metricHeight.textContent = `${result.jump_height_cm.toFixed(1)} cm`;
	dom.metricFrames.textContent = `${result.takeoff_frame} / ${result.landing_frame}`;
}

function setStatus(message, type) {
	dom.statusBanner.textContent = message;
	dom.statusBanner.className = `status-banner ${type}`;
}

function resetAnnotatedVideo() {
	dom.resultPreview.removeAttribute("src");
	dom.resultPreview.load();
	dom.annotatedMeta.textContent = "Run an analysis to generate a replay.";
	dom.downloadLink.removeAttribute("href");
	dom.downloadLink.classList.add("disabled");
	dom.metricMethod.textContent = "Not started";
	dom.metricAirtime.textContent = "--";
	dom.metricHeight.textContent = "--";
	dom.metricFrames.textContent = "--";
}
