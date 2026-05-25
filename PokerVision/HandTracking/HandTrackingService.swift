import CoreGraphics
import Vision

enum HandChirality: String {
    case left, right, unknown
}

struct HandLandmarks {
    let chirality: HandChirality
    let wrist: CGPoint
    let thumbTip: CGPoint
    let thumbIP: CGPoint
    let indexTip: CGPoint
    let indexMCP: CGPoint
    let middleTip: CGPoint
    let middleMCP: CGPoint
    let ringTip: CGPoint
    let ringMCP: CGPoint
    let littleTip: CGPoint
    let littleMCP: CGPoint

    var palmCenter: CGPoint {
        let pts = [wrist, indexMCP, middleMCP, ringMCP, littleMCP]
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
    }

    var palmWidth: CGFloat {
        hypot(indexMCP.x - littleMCP.x, indexMCP.y - littleMCP.y)
    }

    var fingerSpread: CGFloat {
        let pw = palmWidth
        guard pw > 0.001 else { return 1.0 }
        let center = palmCenter
        let tips = [thumbTip, indexTip, middleTip, ringTip, littleTip]
        let avgDist = tips.map { hypot($0.x - center.x, $0.y - center.y) }.reduce(0, +)
            / CGFloat(tips.count)
        return avgDist / pw
    }

    var handAngle: CGFloat {
        atan2(middleMCP.y - wrist.y, middleMCP.x - wrist.x)
    }

    var indexExtension: CGFloat {
        let pw = palmWidth
        guard pw > 0.003 else { return 0 }
        return hypot(indexTip.x - indexMCP.x, indexTip.y - indexMCP.y) / pw
    }

    var otherMaxExtension: CGFloat {
        let pw = palmWidth
        guard pw > 0.003 else { return 0 }
        let m = hypot(middleTip.x - middleMCP.x, middleTip.y - middleMCP.y) / pw
        let r = hypot(ringTip.x - ringMCP.x, ringTip.y - ringMCP.y) / pw
        let l = hypot(littleTip.x - littleMCP.x, littleTip.y - littleMCP.y) / pw
        return max(m, max(r, l))
    }

    var isIndexPointing: Bool {
        let pw = palmWidth
        guard pw > 0.003 else { return false }
        let idx = indexExtension
        let otherMax = otherMaxExtension
        return idx > 0.35 && otherMax < idx * 0.95
    }

    /// Per-finger extension ratios (tip-to-MCP distance over palmWidth).
    /// Used by the open-palm gesture (>=4 extended fingers).
    var middleExtension: CGFloat {
        let pw = palmWidth
        guard pw > 0.003 else { return 0 }
        return hypot(middleTip.x - middleMCP.x, middleTip.y - middleMCP.y) / pw
    }

    var ringExtension: CGFloat {
        let pw = palmWidth
        guard pw > 0.003 else { return 0 }
        return hypot(ringTip.x - ringMCP.x, ringTip.y - ringMCP.y) / pw
    }

    var pinkyExtension: CGFloat {
        let pw = palmWidth
        guard pw > 0.003 else { return 0 }
        return hypot(littleTip.x - littleMCP.x, littleTip.y - littleMCP.y) / pw
    }

    /// Open palm: index, middle, ring, and pinky all extended (>=4 fingers).
    /// Kept for compatibility / debugging; no longer used as a trigger.
    var isOpenPalm: Bool {
        let pw = palmWidth
        guard pw > 0.003 else { return false }
        let extendedThreshold: CGFloat = 0.35
        let idxExt = indexExtension >= extendedThreshold
        let midExt = middleExtension >= extendedThreshold
        let ringExt = ringExtension >= extendedThreshold
        let pinkyExt = pinkyExtension >= extendedThreshold
        let count = [idxExt, midExt, ringExt, pinkyExt].filter { $0 }.count
        return count >= 4
    }

    /// Thumb extension: how far the thumb tip sits from the palm centre,
    /// normalised by palm width. In a fist this is ~0.3, in a "thumbs up"
    /// pose it climbs to ~0.55+.
    var thumbExtension: CGFloat {
        let pw = palmWidth
        guard pw > 0.003 else { return 0 }
        let c = palmCenter
        return hypot(thumbTip.x - c.x, thumbTip.y - c.y) / pw
    }

    // MARK: - Discrete gesture predicates (one frame's worth)
    //
    // These are intentionally noisy on their own — `HandGestureDetector` does
    // 250–300 ms debouncing + cooldown to turn them into safe triggers.

    /// One-finger pose: only the index is extended. Stricter than
    /// `isIndexPointing` because we additionally require ring + pinky to be
    /// curled (so an open palm can't be misread as "index up").
    var isIndexUp: Bool {
        let pw = palmWidth
        guard pw > 0.003 else { return false }
        let extended: CGFloat = 0.40
        let curled: CGFloat = 0.30
        return indexExtension > extended
            && middleExtension < curled
            && ringExtension < curled
            && pinkyExtension < curled
    }

    /// "V sign": index + middle extended, ring + pinky curled.
    var isTwoFingersUp: Bool {
        let pw = palmWidth
        guard pw > 0.003 else { return false }
        let extended: CGFloat = 0.35
        let curled: CGFloat = 0.30
        return indexExtension > extended
            && middleExtension > extended
            && ringExtension < curled
            && pinkyExtension < curled
    }

    /// Thumbs up: thumb extended away from palm + all four other fingers
    /// curled.
    var isThumbsUp: Bool {
        let pw = palmWidth
        guard pw > 0.003 else { return false }
        let curled: CGFloat = 0.28
        return thumbExtension > 0.45
            && indexExtension < curled
            && middleExtension < curled
            && ringExtension < curled
            && pinkyExtension < curled
    }
}

struct HandTrackingResult {
    let leftHand: HandLandmarks?
    let rightHand: HandLandmarks?
    let isPointingDetected: Bool
}

final class HandTrackingService {
    var onResult: ((HandTrackingResult) -> Void)?

    private let processingQueue = DispatchQueue(
        label: "com.funnycube.handtracking", qos: .userInteractive)
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private var isProcessing = false

    private var pointingStartTime: TimeInterval?
    private var lastPointingState = false
    private let pointingConfirmDelay: TimeInterval = 0.12

    private(set) var lastFingerSpread: CGFloat = 0
    private(set) var lastHandAngle: CGFloat = 0
    private(set) var lastIndexExt: CGFloat = 0
    private(set) var lastOtherMax: CGFloat = 0
    private(set) var lastPointingRaw = false
    private var logCounter = 0

    // Stabilize left/right role assignment across frames to avoid flips.
    private var stableLeftCenter: CGPoint?
    private var stableRightCenter: CGPoint?
    private var ownershipInit = false

    init() {
        handPoseRequest.maximumHandCount = 2
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard !isProcessing else { return }
        isProcessing = true

        processingQueue.async { [weak self] in
            defer { self?.isProcessing = false }
            self?.runDetection(pixelBuffer, orientation: orientation)
        }
    }

    private func runDetection(
        _ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation
    ) {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            resetPointing()
            onResult?(HandTrackingResult(leftHand: nil, rightHand: nil, isPointingDetected: false))
            return
        }

        guard let results = handPoseRequest.results, !results.isEmpty else {
            resetPointing()
            onResult?(HandTrackingResult(leftHand: nil, rightHand: nil, isPointingDetected: false))
            return
        }

        var leftHand: HandLandmarks?
        var rightHand: HandLandmarks?

        for observation in results {
            guard let landmarks = extractLandmarks(from: observation) else { continue }

            switch landmarks.chirality {
            case .left:
                if leftHand == nil { leftHand = landmarks }
            case .right:
                if rightHand == nil { rightHand = landmarks }
            case .unknown:
                if landmarks.palmCenter.x < 0.5 {
                    if leftHand == nil { leftHand = landmarks }
                } else {
                    if rightHand == nil { rightHand = landmarks }
                }
            }
        }

        // --- Stabilize handedness roles (left/right) ---
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        let rawL = leftHand
        let rawR = rightHand
        var didSwap = false

        if let rawL = leftHand, let rawR = rightHand {
            // If we have prior centers, pick the assignment that minimizes jumps.
            if let prevLC = stableLeftCenter, let prevRC = stableRightCenter {
                let dRawLToPrevL = dist(rawL.palmCenter, prevLC)
                let dRawRToPrevL = dist(rawR.palmCenter, prevLC)
                // If rawR is closer to previous "left" center, swap.
                if dRawRToPrevL < dRawLToPrevL {
                    leftHand = rawR
                    rightHand = rawL
                    didSwap = true
                }
            } else {
                // Initialize: prefer existing chirality unless unknown, else use x-order.
                let needsXOrder = rawL.chirality == .unknown || rawR.chirality == .unknown
                if needsXOrder {
                    if rawL.palmCenter.x <= rawR.palmCenter.x {
                        leftHand = rawL
                        rightHand = rawR
                    } else {
                        leftHand = rawR
                        rightHand = rawL
                        didSwap = true
                    }
                }
            }

            stableLeftCenter = leftHand?.palmCenter
            stableRightCenter = rightHand?.palmCenter
            ownershipInit = true
        } else if let only = leftHand ?? rightHand {
            // If only one hand is visible, keep it on the closer side.
            let c = only.palmCenter
            if let prevLC = stableLeftCenter, let prevRC = stableRightCenter {
                let dL = dist(c, prevLC)
                let dR = dist(c, prevRC)
                if dL <= dR {
                    leftHand = only
                    rightHand = nil
                } else {
                    rightHand = only
                    leftHand = nil
                }
            } else {
                // No history yet: keep whatever assignment we have.
                if leftHand != nil { ownershipInit = true } else { ownershipInit = true }
            }

            stableLeftCenter = leftHand?.palmCenter ?? stableLeftCenter
            stableRightCenter = rightHand?.palmCenter ?? stableRightCenter
        }

        // --- Pointing signal after stabilization ---
        let anyPointing = (leftHand?.isIndexPointing ?? false)
            || (rightHand?.isIndexPointing ?? false)

        let summonHand = leftHand ?? rightHand
        if let hand = summonHand {
            lastFingerSpread = hand.fingerSpread
            lastHandAngle = hand.handAngle
            lastIndexExt = hand.indexExtension
            lastOtherMax = hand.otherMaxExtension
        }
        lastPointingRaw = anyPointing

        let now = ProcessInfo.processInfo.systemUptime
        var pointingConfirmed = false
        if anyPointing {
            if pointingStartTime == nil { pointingStartTime = now }
            if let start = pointingStartTime, now - start >= pointingConfirmDelay {
                pointingConfirmed = true
            }
        } else {
            pointingStartTime = nil
        }

        let pointingEvent = pointingConfirmed && !lastPointingState
        lastPointingState = pointingConfirmed

        logCounter += 1
        if logCounter % 15 == 0 {
            let lhCh = leftHand?.chirality.rawValue ?? "nil"
            let rhCh = rightHand?.chirality.rawValue ?? "nil"
            let rawLCh = rawL?.chirality.rawValue ?? "nil"
            let rawRCh = rawR?.chirality.rawValue ?? "nil"
            let idxE = summonHand?.indexExtension ?? 0
            let otherM = summonHand?.otherMaxExtension ?? 0
            let pw = summonHand?.palmWidth ?? 0
            NSLog("[Hand] LH=%@ RH=%@ pw=%.3f idxExt=%.2f otherMax=%.2f rawPt=%d debounce=%.2fs confirmed=%d edge=%d stableInit=%d",
                  lhCh, rhCh, pw, idxE, otherM,
                  anyPointing ? 1 : 0,
                  pointingStartTime.map { now - $0 } ?? 0,
                  pointingConfirmed ? 1 : 0,
                  pointingEvent ? 1 : 0,
                  ownershipInit ? 1 : 0)
            NSLog("[HandRoles] rawLH=%@ rawRH=%@ stableLH=%@ stableRH=%@ swap=%d",
                  rawLCh, rawRCh, lhCh, rhCh, didSwap ? 1 : 0)
        }

        onResult?(HandTrackingResult(
            leftHand: leftHand,
            rightHand: rightHand,
            isPointingDetected: pointingEvent
        ))
    }

    private func resetPointing() {
        pointingStartTime = nil
        lastPointingState = false
    }

    private func extractLandmarks(from observation: VNHumanHandPoseObservation) -> HandLandmarks? {
        do {
            let wrist = try observation.recognizedPoint(.wrist)
            let thumbTip = try observation.recognizedPoint(.thumbTip)
            let thumbIP = try observation.recognizedPoint(.thumbIP)
            let indexTip = try observation.recognizedPoint(.indexTip)
            let indexMCP = try observation.recognizedPoint(.indexMCP)
            let middleTip = try observation.recognizedPoint(.middleTip)
            let middleMCP = try observation.recognizedPoint(.middleMCP)
            let ringTip = try observation.recognizedPoint(.ringTip)
            let ringMCP = try observation.recognizedPoint(.ringMCP)
            let littleTip = try observation.recognizedPoint(.littleTip)
            let littleMCP = try observation.recognizedPoint(.littleMCP)

            let minConfidence: Float = 0.05
            let points = [
                wrist, thumbTip, thumbIP, indexTip, indexMCP,
                middleTip, middleMCP, ringTip, ringMCP, littleTip, littleMCP,
            ]
            guard points.allSatisfy({ $0.confidence > minConfidence }) else { return nil }

            let chirality: HandChirality
            switch observation.chirality {
            case .left: chirality = .left
            case .right: chirality = .right
            default: chirality = .unknown
            }

            return HandLandmarks(
                chirality: chirality,
                wrist: wrist.location,
                thumbTip: thumbTip.location,
                thumbIP: thumbIP.location,
                indexTip: indexTip.location,
                indexMCP: indexMCP.location,
                middleTip: middleTip.location,
                middleMCP: middleMCP.location,
                ringTip: ringTip.location,
                ringMCP: ringMCP.location,
                littleTip: littleTip.location,
                littleMCP: littleMCP.location
            )
        } catch {
            return nil
        }
    }
}
