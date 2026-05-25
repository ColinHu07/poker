import Foundation
import MWDATDisplay

enum PokerDisplayRenderer {
    static func idle(onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 12, padding: EdgeInsets(all: 16)) {
            MWDATDisplay.Text("PokerVision", style: .heading)
            MWDATDisplay.Text("Frame the table, then select Analyze.", style: .body, color: .secondary)
            MWDATDisplay.Button(label: "Analyze", style: .primary, iconName: .magicWand, onClick: onAnalyze)
        }
    }

    static func analyzing() -> FlexBox {
        FlexBox(direction: .column, spacing: 12, padding: EdgeInsets(all: 16)) {
            MWDATDisplay.Text("Analyzing", style: .heading)
            MWDATDisplay.Text("Reading players, cards, pot, and stack.", style: .body, color: .secondary)
        }
    }

    static func unavailable(message: String, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 12, padding: EdgeInsets(all: 16)) {
            MWDATDisplay.Text("PokerVision", style: .heading)
            MWDATDisplay.Text(message, style: .body, color: .secondary)
            MWDATDisplay.Button(label: "Try again", style: .secondary, iconName: .twoArrowsClockwise, onClick: onAnalyze)
        }
    }

    static func tableRead(_ analysis: PokerSceneAnalysis, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 12, padding: EdgeInsets(all: 16)) {
            MWDATDisplay.Text("Table read", style: .heading)
            metricRow(label: "Players", value: playerCountText(analysis))
            metricRow(label: "Your cards", value: cardText(analysis.heroCards, fallbackCount: analysis.tableCounts.heroCardCount))
            metricRow(label: "Table cards", value: cardText(analysis.boardCards, fallbackCount: analysis.tableCounts.boardCardCount))
            metricRow(label: "Pot", value: moneyText(analysis.pot))
            metricRow(label: "Your money", value: moneyText(analysis.heroStack))
            MWDATDisplay.Button(label: "Analyze again", style: .primary, iconName: .twoArrowsClockwise, onClick: onAnalyze)
        }
    }

    static func decision(_ state: PokerDisplayDecisionHUDState, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 10, padding: EdgeInsets(all: 16)) {
            MWDATDisplay.Text(state.bestTitle, style: .heading)
            for option in normalizedOptions(state.options) {
                actionBar(option)
            }
            if let confidencePercent = state.confidencePercent {
                MWDATDisplay.Text("Confidence \(confidencePercent)%", style: .meta, color: .secondary)
            }
            MWDATDisplay.Button(label: "Analyze again", style: .primary, iconName: .twoArrowsClockwise, onClick: onAnalyze)
        }
    }

    static func notReady(_ state: PokerDisplayReadinessState, onAnalyze: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 10, padding: EdgeInsets(all: 16)) {
            MWDATDisplay.Text(state.title, style: .heading)
            for issue in state.issues.prefix(3) {
                MWDATDisplay.Text(issue, style: .body, color: .secondary)
            }
            MWDATDisplay.Button(label: "Analyze again", style: .primary, iconName: .twoArrowsClockwise, onClick: onAnalyze)
        }
    }

    private static func metricRow(label: String, value: String) -> FlexBox {
        FlexBox(direction: .row, spacing: 10, alignment: .start, crossAlignment: .center) {
            MWDATDisplay.Text(label, style: .meta, color: .secondary)
            MWDATDisplay.Text(value, style: .body)
        }
        .padding(12)
        .background(.card)
    }

    private static func actionBar(_ option: PokerDisplayActionOption) -> FlexBox {
        let percentText = option.percent.map { "\($0)%" } ?? "--"
        return FlexBox(direction: .column, spacing: 4, padding: EdgeInsets(all: 10)) {
            FlexBox(direction: .row, spacing: 8, alignment: .start, crossAlignment: .center) {
                MWDATDisplay.Text(option.action.title, style: .body)
                MWDATDisplay.Text(percentText, style: .body)
            }
            MWDATDisplay.Text(barText(percent: option.percent), style: .meta, color: .secondary)
        }
        .background(.card)
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
