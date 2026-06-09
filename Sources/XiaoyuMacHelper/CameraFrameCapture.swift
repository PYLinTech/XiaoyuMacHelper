@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private final class FaceAttentionCompletionBox: @unchecked Sendable {
    private let handler: (FaceAttentionResult?) -> Void

    init(_ handler: @escaping (FaceAttentionResult?) -> Void) {
        self.handler = handler
    }

    func call(_ result: FaceAttentionResult?) {
        handler(result)
    }
}

final class CameraFrameCapture: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    private enum Metrics {
        static let minimumSampleInterval: TimeInterval = 0.20
    }

    private let queue = DispatchQueue(label: "local.xiaoyu-mac-helper.active-vision.camera")
    private var session: AVCaptureSession?
    private var callback: FaceAttentionCompletionBox?
    private var lastSampleDate: Date?
    private var isStarting = false
    private var needsGaze = true

    func startChecking(needsGaze: Bool, _ completion: @escaping (FaceAttentionResult?) -> Void) {
        let callback = FaceAttentionCompletionBox(completion)
        queue.async { [weak self, callback] in
            guard let self else { return }

            self.callback = callback
            self.needsGaze = needsGaze
            self.lastSampleDate = nil

            guard self.session == nil, !self.isStarting else {
                return
            }

            self.startSession()
        }
    }

    func stopChecking() {
        queue.async { [weak self] in
            self?.stopSession()
        }
    }

    private func startSession() {
        isStarting = true

        guard let device = AVCaptureDevice.default(for: .video) else {
            finishStartupFailure()
            return
        }

        do {
            configureDeviceForAmbientLight(device)

            let session = AVCaptureSession()
            // 720p 在 200ms 软件节流下仍然足够轻量，同时能明显提升瞳孔/眼部 landmark 的稳定性。
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else if session.canSetSessionPreset(.medium) {
                session.sessionPreset = .medium
            } else if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                finishStartupFailure()
                return
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: queue)

            guard session.canAddOutput(output) else {
                finishStartupFailure()
                return
            }
            session.addOutput(output)

            self.session = session
            self.lastSampleDate = nil
            self.isStarting = false
            session.startRunning()
        } catch {
            finishStartupFailure()
        }
    }


    private func configureDeviceForAmbientLight(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        } catch {
            // 摄像头配置失败不应影响采样，继续使用系统默认参数。
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        autoreleasepool {
            guard let callback else {
                return
            }

            let now = Date()
            if let lastSampleDate,
               now.timeIntervalSince(lastSampleDate) < Metrics.minimumSampleInterval {
                return
            }

            lastSampleDate = now

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            let result = FaceAttentionAnalyzer.analyze(pixelBuffer: pixelBuffer, needsGaze: needsGaze)
            callback.call(result)
        }
    }

    private func finishStartupFailure() {
        let callback = callback
        stopSession()
        callback?.call(nil)
    }

    private func stopSession() {
        callback = nil
        lastSampleDate = nil
        isStarting = false
        session?.stopRunning()
        session = nil
    }
}
