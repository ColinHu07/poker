import Foundation

final class TableStateFusion {
    private var lastState: HandState?

    func reset() {
        lastState = nil
    }

    func ingest(_ observation: TableObservation) -> HandState {
        let heroCards = observation.heroCards.count == 2 ? observation.heroCards : lastState?.heroCards ?? observation.heroCards
        let boardCards = observation.boardCards.isEmpty ? lastState?.boardCards ?? [] : observation.boardCards
        let pot = observation.pot ?? lastState?.pot
        let heroStack = observation.heroStack ?? lastState?.heroStack
        let opponentStacks = observation.chipStacks.isEmpty ? lastState?.opponentStacks ?? [:] : observation.chipStacks
        let actionHistory = mergedActions(previous: lastState?.actionHistory ?? [], current: observation.playerActions)
        let foldedSeats = actionHistory.filter { $0.localizedCaseInsensitiveContains("fold") }.count
        let visibleSeatCount = max(observation.seatCount, lastState?.activeOpponents ?? 0)
        let activeOpponents = max(1, visibleSeatCount - foldedSeats)
        let confidence = blendedConfidence(previous: lastState?.confidence, current: observation.confidence, heroCards: heroCards, pot: pot)

        let state = HandState(
            street: street(forBoardCount: boardCards.count),
            heroCards: heroCards,
            boardCards: boardCards,
            activeOpponents: min(max(activeOpponents, 1), 8),
            foldedSeats: foldedSeats,
            pot: pot,
            betToCall: inferredBetToCall(from: actionHistory, pot: pot),
            heroStack: heroStack,
            opponentStacks: opponentStacks,
            actionHistory: actionHistory,
            confidence: confidence,
            updatedAt: observation.observedAt
        )
        lastState = state
        return state
    }

    private func street(forBoardCount count: Int) -> PokerStreet {
        switch count {
        case 0: return .preflop
        case 3: return .flop
        case 4: return .turn
        case 5...: return .river
        default: return .unknown
        }
    }

    private func mergedActions(previous: [String], current: [String]) -> [String] {
        var merged = previous
        for action in current where !merged.contains(action) {
            merged.append(action)
        }
        return merged.suffix(12)
    }

    private func blendedConfidence(previous: Double?, current: Double, heroCards: [PlayingCard], pot: Int?) -> Double {
        let base = previous.map { $0 * 0.62 + current * 0.38 } ?? current
        let heroPenalty = heroCards.count == 2 ? 0.0 : 0.22
        let potPenalty = pot == nil ? 0.12 : 0.0
        return min(0.99, max(0.0, base - heroPenalty - potPenalty))
    }

    private func inferredBetToCall(from actions: [String], pot: Int?) -> Int {
        guard actions.contains(where: { $0.localizedCaseInsensitiveContains("call") }) else {
            return 0
        }
        return max(1, min(20, (pot ?? 0) / 3))
    }
}

struct PokerTrainerEngine {
    static func evaluate(handState: HandState, riskProfile: PokerRiskProfile = .conservative) -> (SolverResult?, Advice) {
        guard handState.isReadyForTrainerAdvice, let pot = handState.pot else {
            return (
                nil,
                Advice(
                    action: .confirmState,
                    amount: nil,
                    winPercent: nil,
                    neededPercent: nil,
                    confidence: handState.confidence,
                    rationale: "Need stable hero cards, pot, and table confidence before trainer advice.",
                    isActionable: false
                )
            )
        }

        let input = SolverInput(
            heroCards: handState.heroCards,
            boardCards: handState.boardCards,
            activeOpponents: handState.activeOpponents,
            pot: pot,
            betToCall: handState.betToCall,
            heroStack: handState.heroStack,
            riskProfile: riskProfile
        )

        let result = PokerOddsCalculator().solve(input: input)
        let advice = PokerAdviceEngine().recommend(result: result, input: input, stateConfidence: handState.confidence)
        return (result, advice)
    }
}

struct PokerAdviceEngine {
    func recommend(result: SolverResult, input: SolverInput, stateConfidence: Double) -> Advice {
        guard stateConfidence >= 0.78 else {
            return Advice(
                action: .confirmState,
                amount: nil,
                winPercent: result.winEquity,
                neededPercent: result.neededEquity,
                confidence: stateConfidence,
                rationale: "Trainer confidence is below the threshold.",
                isActionable: false
            )
        }

        let realizedEquity = result.winEquity + result.tieEquity * 0.5
        let uncertaintyMargin = max(0.03, result.confidenceSpread)
        let halfPot = max(1, input.pot / 2)
        let potBet = max(1, input.pot)

        if input.betToCall == 0 {
            if result.halfPotBetEV > Double(halfPot) * 0.10 && realizedEquity > 0.58 + uncertaintyMargin {
                return Advice(
                    action: .bet,
                    amount: halfPot,
                    winPercent: realizedEquity,
                    neededPercent: result.neededEquity,
                    confidence: stateConfidence,
                    rationale: "Free action, strong equity edge, conservative half-pot value sizing.",
                    isActionable: true
                )
            }

            return Advice(
                action: .check,
                amount: nil,
                winPercent: realizedEquity,
                neededPercent: result.neededEquity,
                confidence: stateConfidence,
                rationale: "Checking is free and betting edge is not clear enough.",
                isActionable: true
            )
        }

        if result.callEV > 0 && realizedEquity > result.neededEquity + uncertaintyMargin {
            return Advice(
                action: .call,
                amount: input.betToCall,
                winPercent: realizedEquity,
                neededPercent: result.neededEquity,
                confidence: stateConfidence,
                rationale: "Equity clears pot odds after uncertainty margin.",
                isActionable: true
            )
        }

        if result.potBetEV > result.callEV + Double(potBet) * 0.12 && realizedEquity > 0.62 + uncertaintyMargin {
            return Advice(
                action: .raise,
                amount: potBet,
                winPercent: realizedEquity,
                neededPercent: result.neededEquity,
                confidence: stateConfidence,
                rationale: "Raise is only shown when EV is clearly above call EV.",
                isActionable: true
            )
        }

        return Advice(
            action: .fold,
            amount: nil,
            winPercent: realizedEquity,
            neededPercent: result.neededEquity,
            confidence: stateConfidence,
            rationale: "Call EV is negative and checking is unavailable.",
            isActionable: true
        )
    }
}

private struct PokerCoreCard: Hashable {
    let rank: Int
    let suit: Int
}

struct PokerOddsCalculator {
    func solve(input: SolverInput) -> SolverResult {
        guard let hero = coreCards(from: input.heroCards), hero.count == 2 else {
            return emptyResult(input: input)
        }

        let board = coreCards(from: input.boardCards) ?? []
        let known = Set(hero + board)
        var deck = fullDeck().filter { !known.contains($0) }
        var rng = SeededRandomNumberGenerator(seed: seed(for: hero + board, opponents: input.activeOpponents))
        let boardCardsNeeded = max(0, 5 - board.count)
        let opponentCount = min(max(input.activeOpponents, 1), 8)
        let rawOutcomes = max(1, combinationCount(deck.count, choose: boardCardsNeeded + opponentCount * 2))
        let trials = rawOutcomes < 500_000 ? min(rawOutcomes, 50_000) : 50_000

        var wins = 0
        var ties = 0
        var losses = 0

        for _ in 0..<trials {
            deck.shuffle(using: &rng)
            var cursor = 0
            let runout = Array(deck[cursor..<cursor + boardCardsNeeded])
            cursor += boardCardsNeeded

            let finalBoard = board + runout
            let heroScore = HandEvaluator.bestScore(cards: hero + finalBoard)
            var bestOpponentScore: Int64 = 0

            for _ in 0..<opponentCount {
                let opponent = [deck[cursor], deck[cursor + 1]]
                cursor += 2
                bestOpponentScore = max(bestOpponentScore, HandEvaluator.bestScore(cards: opponent + finalBoard))
            }

            if heroScore > bestOpponentScore {
                wins += 1
            } else if heroScore == bestOpponentScore {
                ties += 1
            } else {
                losses += 1
            }
        }

        let win = Double(wins) / Double(trials)
        let tie = Double(ties) / Double(trials)
        let loss = Double(losses) / Double(trials)
        let realizedEquity = win + tie * 0.5
        let callCost = max(0, input.betToCall)
        let needed = callCost == 0 ? 0 : Double(callCost) / Double(input.pot + callCost)
        let callEV = callCost == 0 ? 0 : realizedEquity * Double(input.pot + callCost) - Double(callCost)
        let halfPot = max(1, input.pot / 2)
        let potBet = max(1, input.pot)
        let halfPotEV = valueBetEV(equity: realizedEquity, pot: input.pot, bet: halfPot)
        let potBetEV = valueBetEV(equity: realizedEquity, pot: input.pot, bet: potBet)
        let spread = 1.96 * sqrt(max(0.0001, realizedEquity * (1 - realizedEquity) / Double(trials)))

        return SolverResult(
            winEquity: win,
            tieEquity: tie,
            lossEquity: loss,
            neededEquity: needed,
            callEV: callEV,
            halfPotBetEV: halfPotEV,
            potBetEV: potBetEV,
            confidenceSpread: spread,
            trials: trials
        )
    }

    private func valueBetEV(equity: Double, pot: Int, bet: Int) -> Double {
        equity * Double(pot + bet) - (1 - equity) * Double(bet)
    }

    private func emptyResult(input: SolverInput) -> SolverResult {
        SolverResult(
            winEquity: 0,
            tieEquity: 0,
            lossEquity: 1,
            neededEquity: input.betToCall == 0 ? 0 : Double(input.betToCall) / Double(input.pot + input.betToCall),
            callEV: 0,
            halfPotBetEV: 0,
            potBetEV: 0,
            confidenceSpread: 1,
            trials: 0
        )
    }

    private func coreCards(from cards: [PlayingCard]) -> [PokerCoreCard]? {
        cards.compactMap(coreCard(from:))
    }

    private func coreCard(from card: PlayingCard) -> PokerCoreCard? {
        guard let rank = rankValue(card.rank) else { return nil }
        let suit: Int
        switch card.suit {
        case .clubs: suit = 0
        case .diamonds: suit = 1
        case .hearts: suit = 2
        case .spades: suit = 3
        }
        return PokerCoreCard(rank: rank, suit: suit)
    }

    private func rankValue(_ rank: String) -> Int? {
        switch rank.uppercased() {
        case "A": return 14
        case "K": return 13
        case "Q": return 12
        case "J": return 11
        case "T", "10": return 10
        default: return Int(rank)
        }
    }

    private func fullDeck() -> [PokerCoreCard] {
        (2...14).flatMap { rank in
            (0...3).map { suit in PokerCoreCard(rank: rank, suit: suit) }
        }
    }

    private func combinationCount(_ n: Int, choose k: Int) -> Int {
        guard k >= 0, n >= k else { return 0 }
        if k == 0 { return 1 }
        let k = min(k, n - k)
        return (1...k).reduce(1) { result, i in
            min(1_000_000, result * (n - k + i) / i)
        }
    }

    private func seed(for cards: [PokerCoreCard], opponents: Int) -> UInt64 {
        cards.reduce(UInt64(opponents + 17)) { partial, card in
            partial &* 31 &+ UInt64(card.rank * 7 + card.suit)
        }
    }
}

private enum HandEvaluator {
    private struct RankGroup {
        let rank: Int
        let count: Int
    }

    static func bestScore(cards: [PokerCoreCard]) -> Int64 {
        guard cards.count >= 5 else { return 0 }
        var best: Int64 = 0
        for combo in combinations(cards, choose: 5) {
            best = max(best, scoreFive(combo))
        }
        return best
    }

    private static func scoreFive(_ cards: [PokerCoreCard]) -> Int64 {
        let ranks = cards.map(\.rank).sorted(by: >)
        var rankCounts: [Int: Int] = [:]
        for rank in ranks {
            rankCounts[rank, default: 0] += 1
        }
        let grouped = rankCounts
            .map { RankGroup(rank: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.rank > rhs.rank : lhs.count > rhs.count
            }
        let flush = Set(cards.map(\.suit)).count == 1
        let straight = straightHigh(ranks: ranks)

        if flush, let straight {
            return pack(category: 8, ranks: [straight])
        }

        if let quads = grouped.first(where: { $0.count == 4 }) {
            let kicker = ranks.first { $0 != quads.rank } ?? 0
            return pack(category: 7, ranks: [quads.rank, kicker])
        }

        let trips = grouped.filter { $0.count == 3 }.map { $0.rank }.sorted(by: >)
        let pairs = grouped.filter { $0.count == 2 }.map { $0.rank }.sorted(by: >)
        if let topTrip = trips.first, let pair = (pairs.first ?? trips.dropFirst().first) {
            return pack(category: 6, ranks: [topTrip, pair])
        }

        if flush {
            return pack(category: 5, ranks: ranks)
        }

        if let straight {
            return pack(category: 4, ranks: [straight])
        }

        if let topTrip = trips.first {
            let kickers = ranks.filter { $0 != topTrip }
            return pack(category: 3, ranks: [topTrip] + kickers)
        }

        if pairs.count >= 2 {
            let topPairs = Array(pairs.prefix(2))
            let kicker = ranks.first { !topPairs.contains($0) } ?? 0
            return pack(category: 2, ranks: topPairs + [kicker])
        }

        if let pair = pairs.first {
            let kickers = ranks.filter { $0 != pair }
            return pack(category: 1, ranks: [pair] + kickers)
        }

        return pack(category: 0, ranks: ranks)
    }

    private static func straightHigh(ranks: [Int]) -> Int? {
        var unique = Array(Set(ranks)).sorted(by: >)
        if unique.contains(14) {
            unique.append(1)
        }
        guard unique.count >= 5 else { return nil }
        for start in 0...(unique.count - 5) {
            let window = unique[start..<start + 5]
            if window.enumerated().allSatisfy({ offset, rank in rank == unique[start] - offset }) {
                return unique[start]
            }
        }
        return nil
    }

    private static func pack(category: Int, ranks: [Int]) -> Int64 {
        var score = Int64(category)
        let padded = Array(ranks.prefix(5)) + Array(repeating: 0, count: max(0, 5 - ranks.count))
        for rank in padded.prefix(5) {
            score = score * 15 + Int64(rank)
        }
        return score
    }

    private static func combinations(_ cards: [PokerCoreCard], choose count: Int) -> [[PokerCoreCard]] {
        guard count > 0 else { return [[]] }
        guard cards.count >= count else { return [] }
        if count == 1 { return cards.map { [$0] } }

        var result: [[PokerCoreCard]] = []
        for index in 0...(cards.count - count) {
            let head = cards[index]
            let tail = Array(cards[(index + 1)...])
            for combo in combinations(tail, choose: count - 1) {
                result.append([head] + combo)
            }
        }
        return result
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
