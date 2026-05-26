import Foundation

enum PokerDisplayActionKind: String, CaseIterable, Hashable {
    case fold
    case call
    case raise

    var title: String {
        switch self {
        case .fold: return "Fold"
        case .call: return "Call"
        case .raise: return "Raise"
        }
    }
}

struct PokerDisplayActionOption: Hashable {
    let action: PokerDisplayActionKind
    let percent: Int?

    init(action: PokerDisplayActionKind, percent: Int?) {
        self.action = action
        self.percent = percent.map { min(100, max(0, $0)) }
    }
}

struct PokerDisplayDecisionHUDState: Hashable {
    let bestAction: PokerDisplayActionKind
    let raiseAmount: Int?
    let options: [PokerDisplayActionOption]
    let confidencePercent: Int?
    let rawAction: String?

    var bestTitle: String {
        switch (bestAction, raiseAmount) {
        case (.raise, .some(let amount)):
            return "Best: Raise $\(amount.formatted())"
        default:
            return "Best: \(bestAction.title)"
        }
    }

    static func fromDecisionHoldem(
        rawAction: String,
        probability: Double? = nil,
        foldPercent: Int? = nil,
        callPercent: Int? = nil,
        raisePercent: Int? = nil
    ) -> PokerDisplayDecisionHUDState? {
        let normalized = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bestAction: PokerDisplayActionKind
        var raiseAmount: Int?

        if normalized == "fold" {
            bestAction = .fold
        } else if normalized == "call" || normalized == "check" {
            bestAction = .call
        } else if normalized == "allin" {
            bestAction = .raise
        } else if normalized.hasPrefix("raise") {
            bestAction = .raise
            raiseAmount = normalized
                .split(separator: " ")
                .dropFirst()
                .first
                .flatMap { Int($0) }
        } else {
            return nil
        }

        let selectedPercent = probability.map { Int(($0 * 100).rounded()) }
        return PokerDisplayDecisionHUDState(
            bestAction: bestAction,
            raiseAmount: raiseAmount,
            options: [
                PokerDisplayActionOption(
                    action: .fold,
                    percent: foldPercent ?? (bestAction == .fold ? selectedPercent : nil)
                ),
                PokerDisplayActionOption(
                    action: .call,
                    percent: callPercent ?? (bestAction == .call ? selectedPercent : nil)
                ),
                PokerDisplayActionOption(
                    action: .raise,
                    percent: raisePercent ?? (bestAction == .raise ? selectedPercent : nil)
                ),
            ],
            confidencePercent: selectedPercent,
            rawAction: rawAction
        )
    }

    static let placeholder = PokerDisplayDecisionHUDState(
        bestAction: .raise,
        raiseAmount: 1_500,
        options: [
            PokerDisplayActionOption(action: .fold, percent: 8),
            PokerDisplayActionOption(action: .call, percent: 20),
            PokerDisplayActionOption(action: .raise, percent: 72),
        ],
        confidencePercent: 72,
        rawAction: "raise 1500"
    )
}

struct PokerDisplayReadinessState: Hashable {
    let title: String
    let issues: [String]

    static func notReady(_ issues: [String]) -> PokerDisplayReadinessState {
        PokerDisplayReadinessState(title: "Look again", issues: issues)
    }
}
