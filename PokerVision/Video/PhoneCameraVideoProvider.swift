import AVFoundation
import UIKit

final class PhoneCameraVideoProvider: NSObject, VideoFrameProvider {
    var onFrame: ((CVPixelBuffer, CMTime, CGImagePropertyOrientation?) -> Void)?

    private(set) var isRunning = false
    let sourceDescription = "iPhone Camera"

    private let captureSession = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.funnycube.camera", qos: .userInteractive)

    func start() async throws {
        guard !isRunning else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw VideoProviderError.permissionDenied }
        } else if status != .authorized {
            throw VideoProviderError.permissionDenied
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            captureSession.commitConfiguration()
            throw VideoProviderError.sourceUnavailable
        }

        configureCamera(camera)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            captureSession.commitConfiguration()
            throw VideoProviderError.configurationFailed
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        output.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }

        if let connection = output.connection(with: .video) {
            connection.videoOrientation = .portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
        }

        captureSession.commitConfiguration()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            outputQueue.async { [weak self] in
                self?.captureSession.startRunning()
                continuation.resume()
            }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        outputQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func configureCamera(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.unlockForConfiguration()
        } catch {
            return
        }
    }
}

extension PhoneCameraVideoProvider: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isRunning,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, timestamp, .up)
    }
}
