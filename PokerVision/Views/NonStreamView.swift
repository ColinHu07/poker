import MWDATCore
import SwiftUI

struct NonStreamView: View {
    @ObservedObject var viewModel: PokerVisionViewModel
    @ObservedObject var wearablesVM: WearablesViewModel
    @State private var sheetHeight: CGFloat = 300
    @State private var showSample = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PokerVision")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("Meta glasses stream with display overlay")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PokerVisionBuild.streamMarker)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green.opacity(0.9))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        Button(wearablesVM.registrationState == .registered ? "Connection info" : "Register glasses") {
                            wearablesVM.connectGlasses()
                        }
                        .disabled(wearablesVM.registrationState == .registering)

                        Button("Disconnect", role: .destructive) {
                            wearablesVM.disconnectGlasses()
                        }
                        .disabled(wearablesVM.registrationState != .registered)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                }
                .frame(maxWidth: .infinity)

                if showSample {
                    SamplePreview(viewModel: viewModel)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task { await viewModel.handleStartStreaming() }
                    } label: {
                        Label(
                            viewModel.streamingStatus == .waiting ? "Starting..." : "Start stream",
                            systemImage: viewModel.streamingStatus == .waiting ? "hourglass" : "play.fill"
                        )
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.streamingStatus == .waiting)

                    Text("\(PokerVisionBuild.cameraPolicy). If the old phone-camera label appears, delete the old app and run this build again.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 10) {
                        Button {
                            showSample.toggle()
                            if showSample, viewModel.currentVideoFrame == nil {
                                viewModel.loadSampleFrame()
                            }
                        } label: {
                            Label(showSample ? "Hide sample" : "Sample", systemImage: "photo")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                        .buttonStyle(.bordered)

                        if showSample {
                            Button {
                                Task { await viewModel.analyzeBundledSample() }
                            } label: {
                                Label(
                                    viewModel.isAnalyzing ? "Analyzing..." : "Analyze",
                                    systemImage: "sparkle.magnifyingglass"
                                )
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isAnalyzing)
                        }

                        Button {
                            wearablesVM.connectGlasses()
                        } label: {
                            Label(
                                wearablesVM.registrationState == .registered ? "Registered" : "Register",
                                systemImage: "eyeglasses"
                            )
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                        .buttonStyle(.bordered)
                        .disabled(wearablesVM.registrationState == .registered)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $wearablesVM.showGettingStartedSheet) {
            if #available(iOS 16.0, *) {
                GettingStartedSheetView(height: $sheetHeight)
                    .presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible)
            } else {
                GettingStartedSheetView(height: $sheetHeight)
            }
        }
    }
}

private struct SamplePreview: View {
    @ObservedObject var viewModel: PokerVisionViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                if let frame = viewModel.currentVideoFrame {
                    GeometryReader { geometry in
                        ZStack {
                            Image(uiImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()

                            DetectionOverlay(
                                detections: viewModel.analysis?.detections ?? [],
                                imageSize: frame.size,
                                viewSize: geometry.size
                            )
                        }
                    }
                    .frame(height: 220)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 220)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }

                Text("Sample")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let analysis = viewModel.analysis {
                PokerAnalysisPanel(analysis: analysis)
            }

            if viewModel.handState != nil || viewModel.advice != nil {
                TrainerAdvicePanel(
                    handState: viewModel.handState,
                    solverResult: viewModel.solverResult,
                    advice: viewModel.advice
                )
            }
        }
    }
}

struct GettingStartedSheetView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var height: CGFloat

    var body: some View {
        VStack(spacing: 20) {
            Text("Glasses connected")
                .font(.system(size: 18, weight: .semibold))

            VStack(spacing: 12) {
                TipItemView(
                    resource: .videoIcon,
                    text: "Start streaming to analyze a current camera frame."
                )
                TipItemView(
                    resource: .tapIcon,
                    text: "Tap Analyze when you want a still-frame training readout."
                )
                TipItemView(
                    resource: .smartGlassesIcon,
                    text: "This prototype is for sandboxed study and UI research."
                )
            }

            CustomButton(title: "Continue", style: .primary, isDisabled: false) {
                dismiss()
            }
        }
        .padding(.all, 24)
        .background(
            GeometryReader { geo -> Color in
                DispatchQueue.main.async {
                    height = geo.size.height
                }
                return Color.clear
            }
        )
    }
}

struct TipItemView: View {
    let resource: ImageResource
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(resource)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(.primary)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24)
                .padding(.leading, 4)
                .padding(.top, 4)

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
