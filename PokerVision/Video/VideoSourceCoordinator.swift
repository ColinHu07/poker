import AVFoundation
import MWDATCamera
import MWDATCore

final class VideoSourceCoordinator {
    private(set) var activeSourceName = "None"
    private(set) var isStreaming = false
    private(set) var lastStartError: String?

    var onFrame: ((CVPixelBuffer, CMTime, CGImagePropertyOrientation?) -> Void)?
    var onStreamStateChange: ((StreamState) -> Void)?
    var onStreamError: ((StreamError) -> Void)?
    var onPhotoCapture: ((Data) -> Void)?

    private let metaProvider: MetaGlassesVideoProvider
    private var activeProvider: VideoFrameProvider?

    var activeMetaDeviceSession: DeviceSession? {
        metaProvider.deviceSession
    }

    init(wearables: WearablesInterface) {
        self.metaProvider = MetaGlassesVideoProvider(wearables: wearables)
    }

    func startMetaGlassesStream() async {
        stop()
        lastStartError = nil

        wireMetaCallbacks()
        do {
            try await metaProvider.start()
            activeProvider = metaProvider
            activeSourceName = metaProvider.sourceDescription
            isStreaming = true
        } catch {
            lastStartError = error.localizedDescription
            activeSourceName = "Meta Glasses Unavailable"
            isStreaming = false
        }
    }

    func stop() {
        activeProvider?.stop()
        activeProvider = nil
        isStreaming = false
        activeSourceName = "None"
    }

    func capturePhoto() {
        metaProvider.capturePhoto()
    }

    private func wireMetaCallbacks() {
        metaProvider.onFrame = { [weak self] pb, ts, o in self?.onFrame?(pb, ts, o) }
        metaProvider.onStreamStateChange = { [weak self] s in self?.onStreamStateChange?(s) }
        metaProvider.onStreamError = { [weak self] e in self?.onStreamError?(e) }
        metaProvider.onPhotoCapture = { [weak self] d in self?.onPhotoCapture?(d) }
    }
}
