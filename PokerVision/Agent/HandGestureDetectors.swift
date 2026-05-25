import Foundation

/// Generic stable-pose → one-shot trigger pipeline.
///
/// `predicate` is evaluated every frame; once it stays `true` for
/// `stableDuration` seconds the detector fires `onTrigger` once and then
/// refuses to retrigger for `cooldown` seconds.
///
/// Set `paused = true` to freeze evaluation while another modal flow is
/// active (e.g. while speech recognition is already running).
final class HandGestureDetector {
    var onTrigger: (() -> Void)?
    var paused: Bool = false

    private let label: String
    private let stableDuration: TimeInterval
    private let cooldown: TimeInterval
    private let predicate: (HandTrackingResult) -> Bool

    private var startedAt: Date?
    private var lastTriggerAt: Date?
    private var lostLogCounter = 0

    init(
        label: String,
        stableDuration: TimeInterval,
        cooldown: TimeInterval,
        predicate: @escaping (HandTrackingResult) -> Bool
    ) {
        self.label = label
        self.stableDuration = stableDuration
        self.cooldown = cooldown
        self.predicate = predicate
    }

    func process(_ result: HandTrackingResult) {
        guard !paused else {
            startedAt = nil
            return
        }
        let now = Date()

        if let last = lastTriggerAt, now.timeIntervalSince(last) < cooldown {
            startedAt = nil
            return
        }

        let active = predicate(result)
        if active {
            if startedAt == nil {
                startedAt = now
                NSLog("[Gesture:%@] candidate start", label)
            } else if let start = startedAt, now.timeIntervalSince(start) >= stableDuration {
                lastTriggerAt = now
                startedAt = nil
                NSLog("[Gesture:%@] TRIGGER (stable %.2fs)", label, now.timeIntervalSince(start))
                onTrigger?()
            }
        } else {
            if startedAt != nil {
                lostLogCounter += 1
                if lostLogCounter % 10 == 0 {
                    NSLog("[Gesture:%@] candidate lost", label)
                }
            }
            startedAt = nil
        }
    }

    func reset() {
        startedAt = nil
        lastTriggerAt = nil
    }
}

/// Convenience constructors for the three production gestures.
enum HandGestures {
    /// Index-finger up → start listening. Either hand. 300 ms / 1.0 s.
    static func indexUp() -> HandGestureDetector {
        HandGestureDetector(
            label: "IndexUp", stableDuration: 0.30, cooldown: 1.0
        ) { result in
            (result.leftHand?.isIndexUp ?? false)
                || (result.rightHand?.isIndexUp ?? false)
        }
    }

    /// Index + middle up ("V") → analyze current frame. Either hand.
    /// Slightly longer cooldown so we don't fire two analyses back-to-back.
    static func twoFingersUp() -> HandGestureDetector {
        HandGestureDetector(
            label: "TwoFingersUp", stableDuration: 0.30, cooldown: 2.0
        ) { result in
            (result.leftHand?.isTwoFingersUp ?? false)
                || (result.rightHand?.isTwoFingersUp ?? false)
        }
    }

    /// Thumbs up → confirm pending proposal. Either hand. Faster debounce
    /// because confirmation is a deliberate, high-effort pose.
    static func thumbsUp() -> HandGestureDetector {
        HandGestureDetector(
            label: "ThumbsUp", stableDuration: 0.25, cooldown: 1.5
        ) { result in
            (result.leftHand?.isThumbsUp ?? false)
                || (result.rightHand?.isThumbsUp ?? false)
        }
    }
}
