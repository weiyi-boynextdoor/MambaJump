const gravity = 9.80665;
const dom = {
	videoFile: document.getElementById("videoFile"),
	baselineSeconds: document.getElementById("baselineSeconds"),
	takeoffRatio: document.getElementById("takeoffRatio"),
	analyzeButton: document.getElementById("analyzeButton"),
	statusBanner: document.getElementById("statusBanner"),
	sourcePreview: document.getElementById("sourcePreview"),
	resultPreview: document.getElementById("resultPreview"),
	analysisCanvas: document.getElementById("analysisCanvas"),
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
let annotatedObjectUrl = null;

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
	dom.originalMeta.textContent = `${selectedFile.name} • ${(selectedFile.size / 1024 / 1024).toFixed(2)} MB`;
	setStatus("Video loaded. Ready to analyze.", "idle");
}

async function runAnalysis() {
	if (!selectedFile) {
		return;
	}

	dom.analyzeButton.disabled = true;
	resetAnnotatedVideo();
	setStatus("Reading frames and measuring the jump. This can take a moment for longer videos.", "running");

	try {
		const analysis = await analyzeVideo(selectedFile, {
			baselineSeconds: Number.parseFloat(dom.baselineSeconds.value),
			takeoffThresholdRatio: Number.parseFloat(dom.takeoffRatio.value),
		});

		updateMetrics(analysis.result);
		const downloadName = selectedFile.name.replace(/\.[^.]+$/, "") + "_annotated.webm";
		annotatedObjectUrl = URL.createObjectURL(analysis.blob);
		dom.resultPreview.src = annotatedObjectUrl;
		dom.resultPreview.load();
		dom.annotatedMeta.textContent = `${analysis.mimeType} • ${(analysis.blob.size / 1024 / 1024).toFixed(2)} MB`;
		dom.downloadLink.href = annotatedObjectUrl;
		dom.downloadLink.download = downloadName;
		dom.downloadLink.classList.remove("disabled");
		setStatus("Analysis complete. Review the metrics and preview the annotated replay.", "success");
	} catch (error) {
		console.error(error);
		setStatus(error instanceof Error ? error.message : "Analysis failed.", "error");
	} finally {
		dom.analyzeButton.disabled = !selectedFile;
	}
}

async function analyzeVideo(file, options) {
	const fileUrl = URL.createObjectURL(file);
	try {
		const video = document.createElement("video");
		video.preload = "auto";
		video.muted = true;
		video.playsInline = true;
		video.src = fileUrl;

		await waitForLoadedMetadata(video);
		const fps = await estimateFps(video);
		const canvas = dom.analysisCanvas;
		canvas.width = video.videoWidth;
		canvas.height = video.videoHeight;
		const ctx = canvas.getContext("2d", { willReadFrequently: true });
		const stream = canvas.captureStream(Math.max(24, Math.round(fps)));
		const recorderMime = pickRecorderMimeType();
		const recorder = new MediaRecorder(stream, recorderMime ? { mimeType: recorderMime } : undefined);
		const chunks = [];

		recorder.addEventListener("dataavailable", (event) => {
			if (event.data.size > 0) {
				chunks.push(event.data);
			}
		});

		const measurements = [];
		const totalFrames = Math.max(1, Math.round(video.duration * fps));
		for (let frameIndex = 0; frameIndex < totalFrames; frameIndex += 1) {
			const targetTime = Math.min(video.duration, frameIndex / fps);
			await seekVideo(video, targetTime);
			ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
			const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
			const measurement = extractColorMeasurement(imageData, frameIndex, fps, canvas.width, canvas.height);
			if (measurement) {
				measurements.push(measurement);
			}
		}

		if (measurements.length < 10) {
			throw new Error("Not enough consistent motion features were found. Use a clearer video with the athlete fully visible.");
		}

		const result = detectJump(measurements, fps, options.baselineSeconds, options.takeoffThresholdRatio);
		await renderAnnotatedReplay({
			video,
			ctx,
			canvas,
			fps,
			result,
			measurements,
			recorder,
		});

		const blob = await stopRecorder(recorder, chunks);
		return {
			result,
			blob,
			mimeType: blob.type || recorderMime || "video/webm",
		};
	} finally {
		URL.revokeObjectURL(fileUrl);
	}
}

function waitForLoadedMetadata(video) {
	return new Promise((resolve, reject) => {
		const onLoaded = () => {
			cleanup();
			resolve();
		};
		const onError = () => {
			cleanup();
			reject(new Error("Could not load the selected video."));
		};
		const cleanup = () => {
			video.removeEventListener("loadedmetadata", onLoaded);
			video.removeEventListener("error", onError);
		};

		video.addEventListener("loadedmetadata", onLoaded);
		video.addEventListener("error", onError);
		video.load();
	});
}

async function estimateFps(video) {
	if (typeof video.requestVideoFrameCallback !== "function") {
		return 30;
	}

	const samples = [];
	video.currentTime = 0;
	await video.play();
	await new Promise((resolve) => {
		const collect = (_, metadata) => {
			if (metadata.presentedFrames > 1 && Number.isFinite(metadata.mediaTime)) {
				samples.push(metadata.mediaTime);
			}
			if (samples.length >= 12 || video.currentTime >= Math.min(video.duration, 0.6)) {
				resolve();
				return;
			}
			video.requestVideoFrameCallback(collect);
		};
		video.requestVideoFrameCallback(collect);
	});
	video.pause();

	if (samples.length < 2) {
		return 30;
	}

	const deltas = [];
	for (let index = 1; index < samples.length; index += 1) {
		const delta = samples[index] - samples[index - 1];
		if (delta > 0) {
			deltas.push(delta);
		}
	}

	if (!deltas.length) {
		return 30;
	}

	const averageDelta = deltas.reduce((sum, value) => sum + value, 0) / deltas.length;
	return 1 / averageDelta;
}

function seekVideo(video, targetTime) {
	return new Promise((resolve, reject) => {
		const onSeeked = () => {
			cleanup();
			resolve();
		};
		const onError = () => {
			cleanup();
			reject(new Error("Video seeking failed during analysis."));
		};
		const cleanup = () => {
			video.removeEventListener("seeked", onSeeked);
			video.removeEventListener("error", onError);
		};

		video.addEventListener("seeked", onSeeked, { once: true });
		video.addEventListener("error", onError, { once: true });
		video.currentTime = targetTime;
	});
}

function extractColorMeasurement(imageData, frameIndex, fps, width, height) {
	const { data } = imageData;
	const xStart = Math.floor(width * 0.25);
	const xEnd = Math.ceil(width * 0.75);
	const yStart = Math.floor(height * 0.5);
	const yEnd = Math.ceil(height * 0.92);
	const matchedYs = [];

	for (let y = yStart; y < yEnd; y += 1) {
		for (let x = xStart; x < xEnd; x += 1) {
			const offset = (y * width + x) * 4;
			const red = data[offset];
			const green = data[offset + 1];
			const blue = data[offset + 2];
			if (isTrackedRed(red, green, blue)) {
				matchedYs.push(y);
			}
		}
	}

	if (matchedYs.length < 100) {
		return null;
	}

	matchedYs.sort((left, right) => left - right);
	const footY = percentile(matchedYs, 0.95);
	const hipY = percentile(matchedYs, 0.05);
	const quality = Math.min(1, matchedYs.length / 1200);
	return {
		frameIndex,
		timeSeconds: frameIndex / fps,
		footY,
		hipY,
		quality,
	};
}

function isTrackedRed(red, green, blue) {
	const max = Math.max(red, green, blue);
	const min = Math.min(red, green, blue);
	const delta = max - min;
	if (delta < 45 || max < 90) {
		return false;
	}
	let hue = 0;
	if (max === red) {
		hue = ((green - blue) / delta) % 6;
	} else if (max === green) {
		hue = (blue - red) / delta + 2;
	} else {
		hue = (red - green) / delta + 4;
	}
	hue *= 60;
	if (hue < 0) {
		hue += 360;
	}
	const saturation = max === 0 ? 0 : delta / max;
	return (hue <= 22 || hue >= 345) && saturation >= 0.38;
}

function percentile(sortedValues, ratio) {
	if (!sortedValues.length) {
		return 0;
	}
	const index = Math.max(0, Math.min(sortedValues.length - 1, Math.floor((sortedValues.length - 1) * ratio)));
	return sortedValues[index];
}

function detectJump(measurements, fps, baselineSeconds, takeoffThresholdRatio) {
	const baselineCount = Math.max(5, Math.round(baselineSeconds * fps));
	const baselineFrames = measurements.slice(0, baselineCount);
	if (baselineFrames.length < 5) {
		throw new Error("The baseline segment is too short. Record a short standing phase before takeoff.");
	}

	const baselineFootY = median(baselineFrames.map((item) => item.footY));
	const baselineHipY = median(baselineFrames.map((item) => item.hipY));
	const standingLegLength = Math.max(1e-6, baselineFootY - baselineHipY);
	const footLiftThreshold = takeoffThresholdRatio * standingLegLength;
	const airborneFlags = measurements.map((item) => (baselineFootY - item.footY) > footLiftThreshold);
	const minAirborneFrames = Math.max(2, Math.round(0.08 * fps));

	let consecutive = 0;
	let takeoffIndex = null;
	let landingIndex = null;

	for (let index = 0; index < airborneFlags.length; index += 1) {
		if (airborneFlags[index]) {
			consecutive += 1;
			if (consecutive === minAirborneFrames && takeoffIndex === null) {
				takeoffIndex = index - minAirborneFrames + 1;
			}
			continue;
		}

		if (takeoffIndex !== null && consecutive >= minAirborneFrames) {
			landingIndex = index;
			break;
		}
		consecutive = 0;
	}

	if (takeoffIndex === null) {
		throw new Error("Could not detect takeoff. Keep the athlete standing still before the jump.");
	}

	if (landingIndex === null) {
		if (consecutive >= minAirborneFrames) {
			landingIndex = measurements.length - 1;
		} else {
			throw new Error("Could not detect landing. Make sure the full jump and landing stay in frame.");
		}
	}

	const takeoffFrame = measurements[takeoffIndex].frameIndex;
	const landingFrame = measurements[landingIndex].frameIndex;
	const airtimeSeconds = Math.max(0, (landingFrame - takeoffFrame) / fps);
	const jumpHeightMeters = gravity * airtimeSeconds * airtimeSeconds / 8;

	return {
		method: "Color tracking",
		fps,
		takeoffFrame,
		landingFrame,
		airtimeSeconds,
		jumpHeightMeters,
		jumpHeightCm: jumpHeightMeters * 100,
		baselineFootY,
	};
}

function median(values) {
	const sorted = [...values].sort((left, right) => left - right);
	const middle = Math.floor(sorted.length / 2);
	if (sorted.length % 2 === 0) {
		return (sorted[middle - 1] + sorted[middle]) / 2;
	}
	return sorted[middle];
}

async function renderAnnotatedReplay({ video, ctx, canvas, fps, result, measurements, recorder }) {
	const measurementLookup = new Map(measurements.map((item) => [item.frameIndex, item]));
	recorder.start();

	for (let frameIndex = 0; frameIndex < Math.max(1, Math.round(video.duration * fps)); frameIndex += 1) {
		const targetTime = Math.min(video.duration, frameIndex / fps);
		await seekVideo(video, targetTime);
		ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
		const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
		tintTrackedPixels(imageData);
		ctx.putImageData(imageData, 0, 0);

		const measurement = measurementLookup.get(frameIndex);
		if (measurement) {
			drawFootLine(ctx, canvas, measurement.footY);
		}
		drawSummary(ctx, canvas, frameIndex, result);
		await waitForFrame();
	}
}

function tintTrackedPixels(imageData) {
	const { data } = imageData;
	for (let index = 0; index < data.length; index += 4) {
		const red = data[index];
		const green = data[index + 1];
		const blue = data[index + 2];
		if (!isTrackedRed(red, green, blue)) {
			continue;
		}
		data[index] = Math.min(255, red + 30);
		data[index + 1] = Math.max(0, green - 30);
		data[index + 2] = Math.max(0, blue - 30);
	}
}

function drawFootLine(ctx, canvas, footY) {
	ctx.save();
	ctx.strokeStyle = "#ffd166";
	ctx.lineWidth = 4;
	ctx.beginPath();
	ctx.moveTo(0, footY);
	ctx.lineTo(canvas.width, footY);
	ctx.stroke();
	ctx.restore();
}

function drawSummary(ctx, canvas, frameIndex, result) {
	ctx.save();
	ctx.fillStyle = "rgba(15, 17, 23, 0.72)";
	ctx.fillRect(16, 16, Math.min(canvas.width - 32, 310), 144);
	ctx.fillStyle = "#f7f1e8";
	ctx.font = '700 28px "Segoe UI"';
	ctx.fillText("MambaJump", 32, 48);
	ctx.font = '500 20px "Segoe UI"';
	ctx.fillText(`Airtime: ${result.airtimeSeconds.toFixed(3)} s`, 32, 82);
	ctx.fillText(`Height: ${result.jumpHeightCm.toFixed(1)} cm`, 32, 110);
	ctx.fillText(getStateLabel(frameIndex, result), 32, 138);
	ctx.restore();
}

function getStateLabel(frameIndex, result) {
	if (frameIndex < result.takeoffFrame) {
		return "State: before takeoff";
	}
	if (frameIndex === result.takeoffFrame) {
		return "State: takeoff";
	}
	if (frameIndex < result.landingFrame) {
		return "State: airborne";
	}
	if (frameIndex === result.landingFrame) {
		return "State: landing";
	}
	return "State: after landing";
}

function waitForFrame() {
	return new Promise((resolve) => {
		requestAnimationFrame(() => resolve());
	});
}

function stopRecorder(recorder, chunks) {
	return new Promise((resolve, reject) => {
		recorder.addEventListener(
			"stop",
			() => {
				resolve(new Blob(chunks, { type: recorder.mimeType || "video/webm" }));
			},
			{ once: true },
		);
		recorder.addEventListener("error", () => reject(new Error("Failed to build the annotated replay.")), {
			once: true,
		});
		recorder.stop();
	});
}

function pickRecorderMimeType() {
	const candidates = [
		"video/webm;codecs=vp9",
		"video/webm;codecs=vp8",
		"video/webm",
	];
	return candidates.find((candidate) => MediaRecorder.isTypeSupported(candidate)) ?? "";
}

function updateMetrics(result) {
	dom.metricMethod.textContent = result.method;
	dom.metricAirtime.textContent = `${result.airtimeSeconds.toFixed(3)} s`;
	dom.metricHeight.textContent = `${result.jumpHeightCm.toFixed(1)} cm`;
	dom.metricFrames.textContent = `${result.takeoffFrame} / ${result.landingFrame}`;
}

function setStatus(message, type) {
	dom.statusBanner.textContent = message;
	dom.statusBanner.className = `status-banner ${type}`;
}

function resetAnnotatedVideo() {
	if (annotatedObjectUrl) {
		URL.revokeObjectURL(annotatedObjectUrl);
		annotatedObjectUrl = null;
	}
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
