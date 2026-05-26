import AVFoundation
import MWDATCamera
import MWDATCore

final class MetaGlassesVideoProvider: VideoFrameProvider {
    var onFrame: ((CVPixelBuffer, CMTime, CGImagePropertyOrientation?) -> Void)?

    private(set) var isRunning = false
    let sourceDescription = "Meta Glasses"

    var onStreamStateChange: ((StreamState) -> Void)?
    var onStreamError: ((StreamError) -> Void)?
    var onPhotoCapture: ((Data) -> Void)?

    private let wearables: WearablesInterface
    private(set) var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var frameToken: AnyListenerToken?
    private var stateToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var photoToken: AnyListenerToken?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
    }

    func start() async throws {
        let selector = try await makeDeviceSelector()
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .medium,
            frameRate: 24
        )
        let deviceSession = try wearables.createSession(deviceSelector: selector)
        guard let stream = try deviceSession.addStream(config: config) else {
            throw DeviceSessionError.capabilityNotFound
        }
        self.deviceSession = deviceSession
        self.stream = stream

        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            guard let self, self.isRunning else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer)
            self.onFrame?(pixelBuffer, timestamp, nil)
        }

        stateToken = stream.statePublisher.listen { [weak self] state in
            guard let self else { return }
            switch state {
            case .streaming: self.isRunning = true
            case .stopped: self.isRunning = false
            default: break
            }
            self.onStreamStateChange?(state)
        }

        errorToken = stream.errorPublisher.listen { [weak self] error in
            self?.onStreamError?(error)
        }

        photoToken = stream.photoDataPublisher.listen { [weak self] photo in
            self?.onPhotoCapture?(photo.data)
        }

        do {
            try deviceSession.start()
            await stream.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        isRunning = false

        let ft = frameToken
        let st = stateToken
        let et = errorToken
        let pt = photoToken
        let currentStream = stream
        let currentDeviceSession = deviceSession

        frameToken = nil
        stateToken = nil
        errorToken = nil
        photoToken = nil
        stream = nil
        deviceSession = nil

        Task {
            await ft?.cancel()
            await st?.cancel()
            await et?.cancel()
            await pt?.cancel()
            await currentStream?.stop()
            currentDeviceSession?.stop()
        }
    }

    func capturePhoto() {
        let currentStream = stream
        Task {
            currentStream?.capturePhoto(format: PhotoCaptureFormat.jpeg)
        }
    }

    private func makeDeviceSelector() async throws -> any DeviceSelector {
        let candidateFilter: DeviceFilter = { device in
            let deviceType = device.deviceType()
            return device.linkState == .connected
                && device.compatibility() == .compatible
                && (
                    deviceType == .metaRayBanDisplay
                    || deviceType == .rayBanMeta
                    || deviceType == .rayBanMetaOptics
                    || deviceType == .oakleyMetaHSTN
                    || deviceType == .oakleyMetaVanguard
                )
        }

        if let deviceId = firstEligibleDevice(matching: candidateFilter) {
            return SpecificDeviceSelector(device: deviceId)
        }

        let selector = AutoDeviceSelector(wearables: wearables, filter: candidateFilter)
        if let activeDevice = selector.activeDevice {
            return SpecificDeviceSelector(device: activeDevice)
        }

        if let activeDevice = await waitForActiveDevice(selector: selector) {
            return SpecificDeviceSelector(device: activeDevice)
        }

        throw DeviceSessionError.noEligibleDevice
    }

    private func firstEligibleDevice(matching filter: DeviceFilter) -> DeviceIdentifier? {
        wearables.devices.first { id in
            guard let device = wearables.deviceForIdentifier(id) else { return false }
            return filter(device)
        }
    }

    private func waitForActiveDevice(selector: AutoDeviceSelector) async -> DeviceIdentifier? {
        await withTaskGroup(of: DeviceIdentifier?.self) { group in
            group.addTask {
                for await activeDevice in selector.activeDeviceStream() {
                    if let activeDevice {
                        return activeDevice
                    }
                }
                return nil
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
