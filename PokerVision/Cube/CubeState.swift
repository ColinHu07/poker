import Foundation

enum CubeState: String {
    case hidden
    case spawning
    case idle
    case dismissed
}

final class CubeStateMachine {
    private(set) var state: CubeState = .hidden
    var onStateChange: ((CubeState) -> Void)?

    func transition(to newState: CubeState) {
        guard newState != state else { return }

        switch (state, newState) {
        case (.hidden, .spawning),
            (.dismissed, .spawning),
            (.idle, .spawning):
            break
        case (.spawning, .idle):
            break
        case (_, .hidden):
            break
        default:
            NSLog("[State] BLOCKED %@ → %@", state.rawValue, newState.rawValue)
            return
        }

        NSLog("[State] %@ → %@", state.rawValue, newState.rawValue)
        state = newState
        onStateChange?(newState)
    }
}
