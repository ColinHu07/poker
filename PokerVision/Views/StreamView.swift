import SwiftUI

struct StreamView: View {
    @ObservedObject var viewModel: PokerVisionViewModel
    @ObservedObject var wearablesVM: WearablesViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
                GeometryReader { geometry in
                    ZStack {
                        Image(uiImage: videoFrame)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()

                        DetectionOverlay(
                            detections: viewModel.analysis?.detections ?? [],
                            imageSize: videoFrame.size,
                            viewSize: geometry.size
                        )
                    }
                }
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.white)
            }

            VStack(spacing: 12) {
                PokerVisionTopBar(
                    source: viewModel.debugInfo.activeSource,
                    isAnalyzing: viewModel.isAnalyzing
                )

                Spacer()

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

                StreamControls(viewModel: viewModel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .onDisappear {
            Task {
                if viewModel.streamingStatus != .stopped {
                    await viewModel.stopSession()
                }
            }
        }
        .sheet(isPresented: $viewModel.showPhotoPreview) {
            if let photo = viewModel.capturedPhoto {
                PhotoPreviewView(
                    photo: photo,
                    onDismiss: { viewModel.dismissPhotoPreview() }
                )
            }
        }
    }
}

struct PokerVisionTopBar: View {
    let source: String
    let isAnalyzing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label("PokerVision", systemImage: "camera.viewfinder")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            if isAnalyzing {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.white)
            }

            Text(source)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StreamControls: View {
    @ObservedObject var viewModel: PokerVisionViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await viewModel.analyzeLiveFrame() }
            } label: {
                Label("Analyze", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.currentVideoFrame == nil || viewModel.isAnalyzing)

            CircleButton(icon: "camera.fill", text: nil) {
                viewModel.capturePhoto()
            }
            .accessibilityIdentifier("capture_photo_button")

            CircleButton(icon: "stop.fill", text: nil) {
                Task { await viewModel.stopSession() }
            }
            .accessibilityIdentifier("stop_streaming_button")
        }
    }
}

struct TrainerAdvicePanel: View {
    let handState: HandState?
    let solverResult: SolverResult?
    let advice: Advice?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Trainer demo", systemImage: "graduationcap")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let handState {
                    Text(handState.street.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            if let advice {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon(for: advice.action))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(color(for: advice.action))
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(advice.compactTitle)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text(advice.rationale)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    if let win = advice.winPercent {
                        MetricPill(label: "Win", value: percent(win))
                    }
                    if let needed = advice.neededPercent {
                        MetricPill(label: "Need", value: percent(needed))
                    }
                    MetricPill(label: "Conf", value: percent(advice.confidence))
                    if let solverResult {
                        MetricPill(label: "Runs", value: compactNumber(solverResult.trials))
                    }
                }
            } else {
                Label("Waiting for stable table state", systemImage: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for action: PokerTrainerAction) -> String {
        switch action {
        case .confirmState: return "exclamationmark.magnifyingglass"
        case .check: return "checkmark.circle"
        case .fold: return "xmark.circle"
        case .call: return "phone.arrow.up.right"
        case .bet, .raise: return "arrow.up.circle"
        }
    }

    private func color(for action: PokerTrainerAction) -> Color {
        switch action {
        case .confirmState: return .yellow
        case .check: return .blue
        case .fold: return .red
        case .call: return .green
        case .bet, .raise: return .orange
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func compactNumber(_ value: Int) -> String {
        value >= 1000 ? "\(value / 1000)k" : "\(value)"
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.black.opacity(0.08), in: Capsule())
    }
}

struct PokerAnalysisPanel: View {
    let analysis: PokerSceneAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(analysis.source.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let pot = analysis.pot {
                    Label("$\(pot)", systemImage: "circle.grid.2x2")
                        .font(.system(size: 14, weight: .bold))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                CountLine(title: "Players", value: analysis.tableCounts.playerCount.map(String.init) ?? "Unknown")
                CardRow(title: "Your cards", cards: analysis.heroCards, fallbackCount: analysis.tableCounts.heroCardCount)
                CardRow(title: "Table cards", cards: analysis.boardCards, fallbackCount: analysis.tableCounts.boardCardCount)
            }

            if let handDescription = analysis.handDescription {
                Label(handDescription, systemImage: "checkmark.seal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green)
            }

            if !analysis.visibleActions.isEmpty {
                ChipRow(title: "Actions", values: analysis.visibleActions)
            }

            if !analysis.detections.isEmpty {
                ChipRow(title: "Boxes", values: ["\(analysis.detections.count) detections"])
            }

            if !analysis.players.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Players")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(analysis.players) { player in
                        PlayerLine(player: player)
                    }
                }
            }

            if !analysis.notes.isEmpty {
                Text(analysis.notes[0])
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DetectionOverlay: View {
    let detections: [PokerDetection]
    let imageSize: CGSize
    let viewSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(detections) { detection in
                let frame = displayFrame(for: detection.normalizedBoundingBox)
                DetectionBox(detection: detection)
                    .frame(width: max(frame.width, 36), height: max(frame.height, 24))
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }

    private func displayFrame(for normalized: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        let scaledSize: CGSize
        let offset: CGPoint

        if imageAspect > viewAspect {
            let height = viewSize.height
            let width = height * imageAspect
            scaledSize = CGSize(width: width, height: height)
            offset = CGPoint(x: (viewSize.width - width) / 2, y: 0)
        } else {
            let width = viewSize.width
            let height = width / imageAspect
            scaledSize = CGSize(width: width, height: height)
            offset = CGPoint(x: 0, y: (viewSize.height - height) / 2)
        }

        return CGRect(
            x: offset.x + normalized.minX * scaledSize.width,
            y: offset.y + normalized.minY * scaledSize.height,
            width: normalized.width * scaledSize.width,
            height: normalized.height * scaledSize.height
        )
    }
}

private struct DetectionBox: View {
    let detection: PokerDetection

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .stroke(color, lineWidth: 2)
                .background(color.opacity(0.08))

            Text("\(detection.label) \(detection.confidenceIntervalText)")
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
                .offset(x: 4, y: 4)
        }
    }

    private var color: Color {
        switch detection.category {
        case .heroCard: return .green
        case .boardCard: return .mint
        case .pot: return .yellow
        case .stack: return .cyan
        case .action: return .blue
        case .text: return .white.opacity(0.7)
        }
    }
}

private struct CardRow: View {
    let title: String
    let cards: [PlayingCard]
    let fallbackCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            if cards.isEmpty {
                Text(fallbackCount == 0 ? "Unknown" : "\(fallbackCount) seen")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cards) { card in
                    CardToken(card: card)
                }
            }
        }
    }
}

private struct CountLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct CardToken: View {
    let card: PlayingCard

    var body: some View {
        Text(card.display)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(card.suit.displayColor)
            .frame(width: 44, height: 34)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct ChipRow: View {
    let title: String
    let values: [String]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.blue)
            }
        }
    }
}

private struct PlayerLine: View {
    let player: PokerPlayerState

    var body: some View {
        HStack(spacing: 8) {
            Text(player.name)
                .font(.system(size: 13, weight: .semibold))
            if let stack = player.stack {
                Text("$\(stack)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if player.isDealer {
                Text("Dealer")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.yellow.opacity(0.2), in: Capsule())
            }
            Spacer()
            if let lastAction = player.lastAction {
                Text(lastAction)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
