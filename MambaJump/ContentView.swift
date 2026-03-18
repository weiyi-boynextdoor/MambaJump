import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    struct ImportedMovie: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { movie in
                SentTransferredFile(movie.url)
            } importing: { received in
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(received.file.pathExtension)

                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }

                try FileManager.default.copyItem(at: received.file, to: tempURL)
                return Self(url: tempURL)
            }
        }
    }

    @StateObject private var viewModel = JumpEstimatorViewModel()
    @State private var isImportingVideo = false
    @State private var selectedVideoItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: viewModel.detector.session,
                isMirrored: viewModel.isUsingFrontCamera
            )
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.7),
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                metrics
                importedVideoPreview
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .task(id: selectedVideoItem) {
            guard let selectedVideoItem else { return }

            do {
                if let importedMovie = try await selectedVideoItem.loadTransferable(type: ImportedMovie.self) {
                    viewModel.analyzeImportedVideo(at: importedMovie.url)
                }
            } catch {
                viewModel.statusText = "Could not load that video from your photo library."
            }

            self.selectedVideoItem = nil
        }
        .fileImporter(
            isPresented: $isImportingVideo,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)

            do {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                viewModel.analyzeImportedVideo(at: tempURL)
            } catch {
                viewModel.statusText = "Could not import that video into the app sandbox."
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("MambaJump")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Spacer()

                Button(action: viewModel.switchCamera) {
                    Label(
                        viewModel.isUsingFrontCamera ? "Front Cam" : "Back Cam",
                        systemImage: "camera.rotate"
                    )
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }

            Text(viewModel.statusText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            PhotosPicker(
                selection: $selectedVideoItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }

            Button(action: {
                isImportingVideo = true
            }) {
                Label("Files", systemImage: "folder")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }

            Button(action: viewModel.useLiveCamera) {
                Label("Use Camera", systemImage: "video")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metricCard(
                title: "Jump Height",
                primary: String(format: "%.0f cm", viewModel.jumpHeightMeters * 100.0),
                secondary: viewModel.inputMode == .importedVideo ? "From imported video" : "Estimated height"
            )

            metricCard(
                title: "Airtime",
                primary: String(format: "%.0f ms", viewModel.airTime * 1000.0),
                secondary: viewModel.isAnalyzingImportedVideo
                    ? "Analyzing video"
                    : (viewModel.inputMode == .importedVideo ? "Video replay" : (viewModel.isAirborne ? "Live jump" : "Last jump"))
            )
        }
    }

    private var importedVideoPreview: some View {
        Group {
            if viewModel.inputMode == .importedVideo, let thumbnail = viewModel.importedVideoThumbnail {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Debug Clip")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.75))

                            Text(viewModel.importedVideoName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)

                            Text(
                                viewModel.isAnalyzingImportedVideo
                                    ? "Analyzing imported video"
                                    : "Ready for repeat debugging"
                            )
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                        }

                        Spacer()
                    }

                    trimControls
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.importedVideoDuration > 0 {
                Text("Optional trim")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))

                HStack(spacing: 12) {
                    framePreview(
                        title: "Start",
                        image: viewModel.importedVideoStartThumbnail ?? viewModel.importedVideoThumbnail,
                        time: viewModel.importedVideoStartTime
                    )

                    framePreview(
                        title: "End",
                        image: viewModel.importedVideoEndThumbnail ?? viewModel.importedVideoThumbnail,
                        time: viewModel.importedVideoEndTime
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Start frame")
                        Spacer()
                        Text(formattedTime(viewModel.importedVideoStartTime))
                    }
                    .font(.footnote)

                    Slider(
                        value: Binding(
                            get: { viewModel.importedVideoStartTime },
                            set: { viewModel.setImportedVideoStartTime($0) }
                        ),
                        in: 0...viewModel.importedVideoDuration
                    )
                    .tint(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("End frame")
                        Spacer()
                        Text(formattedTime(viewModel.importedVideoEndTime))
                    }
                    .font(.footnote)

                    Slider(
                        value: Binding(
                            get: { viewModel.importedVideoEndTime },
                            set: { viewModel.setImportedVideoEndTime($0) }
                        ),
                        in: 0...viewModel.importedVideoDuration
                    )
                    .tint(.white)
                }

                HStack {
                    Text("Default keeps the original start and end of the video.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))

                    Spacer()

                    Button(action: viewModel.analyzeSelectedImportedVideo) {
                        Label("Reanalyze", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(viewModel.isAnalyzingImportedVideo)
                }
            }
        }
    }

    private func framePreview(title: String, image: UIImage?, time: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("\(title) • \(formattedTime(time))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedTime(_ seconds: Double) -> String {
        let totalCentiseconds = Int((max(0, seconds) * 100).rounded())
        let minutes = totalCentiseconds / 6000
        let secs = (totalCentiseconds / 100) % 60
        let centiseconds = totalCentiseconds % 100
        return String(format: "%d:%02d.%02d", minutes, secs, centiseconds)
    }

    private func metricCard(title: String, primary: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))

            Text(primary)
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text(secondary)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.14))
        )
    }
}
