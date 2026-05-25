import CoreGraphics

struct SmoothedValue {
    private(set) var value: CGFloat = 0
    private let alpha: CGFloat
    private var initialized = false

    init(smoothing: CGFloat = 0.7) {
        self.alpha = smoothing
    }

    mutating func update(_ newValue: CGFloat) -> CGFloat {
        if !initialized {
            value = newValue
            initialized = true
        } else {
            value = value * alpha + newValue * (1 - alpha)
        }
        return value
    }

    mutating func reset() {
        initialized = false
        value = 0
    }
}

struct SmoothedPoint {
    private var sx: SmoothedValue
    private var sy: SmoothedValue

    init(smoothing: CGFloat = 0.7) {
        sx = SmoothedValue(smoothing: smoothing)
        sy = SmoothedValue(smoothing: smoothing)
    }

    mutating func update(_ point: CGPoint) -> CGPoint {
        CGPoint(x: sx.update(point.x), y: sy.update(point.y))
    }

    mutating func reset() {
        sx.reset()
        sy.reset()
    }
}

struct ScaleSmoother {
    private var smoother = SmoothedValue(smoothing: 0.6)
    private var baselineDistance: CGFloat?
    private var baselineScale: CGFloat = 1.0
    let minScale: CGFloat = 0.3
    let maxScale: CGFloat = 3.0

    mutating func beginScaling(currentDistance: CGFloat, currentScale: CGFloat) {
        baselineDistance = currentDistance
        baselineScale = currentScale
    }

    mutating func updateScale(currentDistance: CGFloat) -> CGFloat {
        guard let baseline = baselineDistance, baseline > 0.001 else { return baselineScale }
        let rawScale = baselineScale * (currentDistance / baseline)
        let clamped = min(max(rawScale, minScale), maxScale)
        return smoother.update(clamped)
    }

    mutating func endScaling() -> CGFloat {
        let finalVal = smoother.value
        baselineDistance = nil
        return finalVal
    }

    mutating func reset() {
        baselineDistance = nil
        baselineScale = 1.0
        smoother.reset()
    }
}
