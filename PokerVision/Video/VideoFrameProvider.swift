import AVFoundation
import CoreVideo

protocol VideoFrameProvider: AnyObject {
    var onFrame: ((CVPixelBuffer, CMTime, CGImagePropertyOrientation?) -> Void)? { get set }
    func start() async throws
    func stop()
    var isRunning: Bool { get }
    var sourceDescription: String { get }
}

enum VideoProviderError: Error, LocalizedError {
    case permissionDenied
    case sourceUnavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied"
        case .sourceUnavailable: return "Video source unavailable"
        case .configurationFailed: return "Failed to configure video source"
        }
    }
}
