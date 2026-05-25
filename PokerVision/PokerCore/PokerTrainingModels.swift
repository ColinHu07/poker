import Foundation

enum PokerStreet: String, Hashable {
    case unknown = "Unknown"
    case preflop = "Preflop"
    case flop = "Flop"
    case turn = "Turn"
    case river = "River"
}

enum PokerTrainerAction: String, Hashable {
    case confirmState = "Confirm state"
    case check = "Check"
    case fold = "Fold"
    case call = "Call"
    case bet = "Bet"
    case raise = "Raise"
}

enum PokerRiskProfile: String, Hashable {
    case conservative = "Conservative"
    case balanced = "Balanced"
}

struct TableObservation: Hashable {
    let heroCards: [PlayingCard]
    let boardCards: [PlayingCard]
    let seatCount: Int
    let playerActions: [String]
    let chipStacks: [String: Int]
    let pot: Int?
    let heroStack: Int?
    let detections: [PokerDetection]
    let confidence: Double
    let observedAt: Date

    init(analysis: PokerSceneAnalysis) {
        self.heroCards = analysis.heroCards
        self.boardCards = analysis.boardCards
        self.seatCount = max(analysis.players.count, analysis.players.isEmpty ? 0 : analysis.players.count + 1)
        self.playerActions = analysis.visibleActions
        self.chipStacks = Dictionary(
            uniqueKeysWithValues: analysis.players.compactMap { player in
                guard let stack = player.stack else { return nil }
                return (player.name, stack)
            }
        )
        self.pot = analysis.pot
        self.heroStack = analysis.heroStack
        self.detections = analysis.detections
        self.confidence = Self.confidence(for: analysis)
        self.observedAt = analysis.analyzedAt
    }

    private static func confidence(for analysis: PokerSceneAnalysis) -> Double {
        var factors: [Double] = []
        factors.append(analysis.heroCards.count == 2 ? 0.95 : 0.35)
        factors.append(analysis.pot == nil ? 0.55 : 0.95)

        if !analysis.detections.isEmpty {
            let averageDetection = analysis.detections.map(\.confidence).reduce(0, +) / Double(analysis.detections.count)
            factors.append(averageDetection)
        }

        if !analysis.boardCards.isEmpty {
            factors.append(analysis.boardCards.count >= 3 ? 0.92 : 0.65)
        }

        return factors.reduce(1.0) { min($0, $1) }
    }
}

struct HandState: Hashable {
    let street: PokerStreet
    let heroCards: [PlayingCard]
    let boardCards: [PlayingCard]
    let activeOpponents: Int
    let foldedSeats: Int
    let pot: Int?
    let betToCall: Int
    let heroStack: Int?
    let opponentStacks: [String: Int]
    let actionHistory: [String]
    let confidence: Double
    let updatedAt: Date

    var isReadyForTrainerAdvice: Bool {
        heroCards.count == 2 && confidence >= 0.70 && pot != nil
    }

    var compactSummary: String {
        let hero = heroCards.map(\.display).joined(separator: " ")
        let board = boardCards.map(\.display).joined(separator: " ")
        let potText = pot.map { "$\($0)" } ?? "Pot ?"
        return "\(street.rawValue) | \(hero.isEmpty ? "Hero ?" : hero) | \(board.isEmpty ? "Board ?" : board) | \(potText)"
    }
}

struct SolverInput: Hashable {
    let heroCards: [PlayingCard]
    let boardCards: [PlayingCard]
    let activeOpponents: Int
    let pot: Int
    let betToCall: Int
    let heroStack: Int?
    let riskProfile: PokerRiskProfile
}

struct SolverResult: Hashable {
    let winEquity: Double
    let tieEquity: Double
    let lossEquity: Double
    let neededEquity: Double
    let callEV: Double
    let halfPotBetEV: Double
    let potBetEV: Double
    let confidenceSpread: Double
    let trials: Int

    var equityText: String {
        "\(Int((winEquity + tieEquity * 0.5) * 100))%"
    }

    var neededEquityText: String {
        "\(Int(neededEquity * 100))%"
    }
}

struct Advice: Hashable {
    let action: PokerTrainerAction
    let amount: Int?
    let winPercent: Double?
    let neededPercent: Double?
    let confidence: Double
    let rationale: String
    let isActionable: Bool

    var compactTitle: String {
        switch (action, amount) {
        case (.bet, .some(let amount)), (.raise, .some(let amount)):
            return "\(action.rawValue) $\(amount)"
        default:
            return action.rawValue
        }
    }
}

