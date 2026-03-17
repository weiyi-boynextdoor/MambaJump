import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = JumpEstimatorViewModel()

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.detector.session)
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
                metrics
                instructions
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MambaJump")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text(viewModel.statusText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metricCard(
                title: "Jump Height",
                primary: String(format: "%.2f in", viewModel.jumpHeightInches),
                secondary: String(format: "%.0f cm", viewModel.jumpHeightMeters * 100.0)
            )

            metricCard(
                title: "Airtime",
                primary: String(format: "%.0f ms", viewModel.airTime * 1000.0),
                secondary: viewModel.isAirborne ? "Live jump" : "Last jump"
            )
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tips")
                .font(.headline)

            Text("Keep your whole body visible, point the phone from the side or front, and stand far enough back that your feet never leave the frame.")
            Text("The app estimates height from flight time using h = g × t² / 8, so stable lighting and a clear landing help accuracy.")
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.92))
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
