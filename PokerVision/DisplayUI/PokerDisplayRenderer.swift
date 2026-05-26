import Foundation
import MWDATDisplay

enum PokerDisplayRenderer {
    static func idle(onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        displayStack {
            MWDATDisplay.Text("PokerVision", style: .heading)
            MWDATDisplay.Text("Frame the table.", style: .body, color: .secondary)
            largeAnalyzeButton(label: "Analyze", iconName: .magicWand, onAnalyze: onAnalyze)
        }
    }

    static func analyzing() -> FlexBox {
        displayStack {
            MWDATDisplay.Text("Analyzing", style: .heading)
            MWDATDisplay.Text("Reading players, cards, pot, and stack.", style: .body, color: .secondary)
        }
    }

    static func unavailable(message: String, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        displayStack {
            MWDATDisplay.Text("PokerVision", style: .heading)
            MWDATDisplay.Text(message, style: .body, color: .secondary)
            largeAnalyzeButton(label: "Try again", iconName: .twoArrowsClockwise, onAnalyze: onAnalyze)
        }
    }

    static func tableRead(_ analysis: PokerSceneAnalysis, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        displayStack {
            MWDATDisplay.Text("Table read", style: .heading)
            metricRow(label: "Players", value: playerCountText(analysis))
            metricRow(label: "Your cards", value: cardText(analysis.heroCards, fallbackCount: analysis.tableCounts.heroCardCount))
            metricRow(label: "Table cards", value: cardText(analysis.boardCards, fallbackCount: analysis.tableCounts.boardCardCount))
            metricRow(label: "Pot", value: moneyText(analysis.pot))
            metricRow(label: "Your money", value: moneyText(analysis.heroStack))
            largeAnalyzeButton(label: "Analyze again", iconName: .twoArrowsClockwise, onAnalyze: onAnalyze)
        }
    }

    static func decision(_ state: PokerDisplayDecisionHUDState, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        displayStack {
            MWDATDisplay.Text(state.bestTitle, style: .heading)
            for option in normalizedOptions(state.options) {
                actionBar(option, isBest: option.action == state.bestAction)
            }
            if let confidencePercent = state.confidencePercent {
                MWDATDisplay.Text("Confidence \(confidencePercent)%", style: .meta, color: .secondary)
            }
            largeAnalyzeButton(label: "Analyze again", iconName: .twoArrowsClockwise, onAnalyze: onAnalyze)
        }
    }

    static func notReady(_ state: PokerDisplayReadinessState, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        displayStack {
            MWDATDisplay.Text(state.title, style: .heading)
            for issue in state.issues.prefix(3) {
                MWDATDisplay.Text(issue, style: .body, color: .secondary)
            }
            largeAnalyzeButton(label: "Analyze again", iconName: .twoArrowsClockwise, onAnalyze: onAnalyze)
        }
    }

    private static func displayStack(@ComponentBuilder content: () -> [any ViewComponent]) -> FlexBox {
        FlexBox(
            direction: .column,
            spacing: 12,
            alignment: .center,
            crossAlignment: .stretch,
            padding: EdgeInsets(all: 16),
            content: content
        )
    }

    private static func metricRow(label: String, value: String) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, alignment: .center, crossAlignment: .center) {
            MWDATDisplay.Text(label, style: .meta, color: .secondary)
            MWDATDisplay.Text(value, style: .body)
        }
        .padding(14)
        .background(.card)
    }

    private static func actionBar(_ option: PokerDisplayActionOption, isBest: Bool) -> FlexBox {
        let percentText = option.percent.map { "\($0)%" } ?? "--"
        return FlexBox(direction: .column, spacing: 6, padding: EdgeInsets(all: 14)) {
            FlexBox(direction: .row, spacing: 10, alignment: .center, crossAlignment: .center) {
                if isBest {
                    MWDATDisplay.Icon(name: .checkmarkCircle)
                }
                MWDATDisplay.Text(option.action.title, style: .body)
                MWDATDisplay.Text(percentText, style: .body, color: isBest ? .primary : .secondary)
            }
            MWDATDisplay.Text(barText(percent: option.percent), style: .meta, color: .secondary)
        }
        .background(.card)
    }

    private static func largeAnalyzeButton(
        label: String,
        iconName: IconName,
        onAnalyze: @escaping @Sendable () -> Void
    ) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, alignment: .center, crossAlignment: .center) {
            MWDATDisplay.Icon(name: iconName)
            MWDATDisplay.Text(label, style: .heading)
        }
        .padding(18)
        .background(.card)
        .onTap(onAnalyze)
    }

    private static func normalizedOptions(_ options: [PokerDisplayActionOption]) -> [PokerDisplayActionOption] {
        PokerDisplayActionKind.allCases.map { action in
            options.first { $0.action == action } ?? PokerDisplayActionOption(action: action, percent: nil)
        }
    }

    private static func barText(percent: Int?) -> String {
        guard let percent else { return "[----------]" }
        let filled = min(10, max(0, Int((Double(percent) / 10.0).rounded())))
        return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: 10 - filled) + "]"
    }

    private static func playerCountText(_ analysis: PokerSceneAnalysis) -> String {
        guard let playerCount = analysis.tableCounts.playerCount else {
            return "Unknown"
        }
        return "\(playerCount)"
    }

    private static func cardText(_ cards: [PlayingCard], fallbackCount: Int) -> String {
        let text = cards.map(\.display).joined(separator: " ")
        if !text.isEmpty { return text }
        return fallbackCount == 0 ? "Unknown" : "\(fallbackCount) seen"
    }

    private static func moneyText(_ amount: Int?) -> String {
        guard let amount else { return "Unknown" }
        return "$\(amount)"
    }
}
