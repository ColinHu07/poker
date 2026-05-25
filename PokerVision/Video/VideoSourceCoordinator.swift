import AVFoundation
import MWDATCamera
import MWDATCore

final class VideoSourceCoordinator {
    private(set) var activeSourceName = "None"
    private(set) var isStreaming = false

    var onFrame: ((CVPixelBuffer, CMTime, CGImagePropertyOrientation?) -> Void)?
    var onStreamStateChange: ((StreamState) -> Void)?
    var onStreamError: ((StreamError) -> Void)?
    var onPhotoCapture: ((Data) -> Void)?

    private let metaProvider: MetaGlassesVideoProvider
    private let phoneProvider: PhoneCameraVideoProvider
    private var activeProvider: VideoFrameProvider?

    var activeMetaDeviceSession: DeviceSession? {
        metaProvider.deviceSession
    }

    init(wearables: WearablesInterface) {
        self.metaProvider = MetaGlassesVideoProvider(wearables: wearables)
        self.phoneProvider = PhoneCameraVideoProvider()
    }

    func start(preferMeta: Bool) async {
        stop()

        if preferMeta {
            wireMetaCallbacks()
            do {
                try await metaProvider.start()
                activeProvider = metaProvider
                activeSourceName = metaProvider.sourceDescription
                isStreaming = true
                return
            } catch {
                // Meta stream failed — fall through to phone camera
            }
        }

        wirePhoneCallbacks()
        do {
            try await phoneProvider.start()
            activeProvider = phoneProvider
            activeSourceName = phoneProvider.sourceDescription
            isStreaming = true
        } catch {
            activeSourceName = "Unavailable"
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

    private func wirePhoneCallbacks() {
        phoneProvider.onFrame = { [weak self] pb, ts, o in self?.onFrame?(pb, ts, o) }
    }
}
