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
    /// 帧分析专用队列：Vision 推理（弱光下单次可达上百毫秒）不再占用 session
    /// 控制队列，stopChecking/startChecking 不会被推理阻塞。
    private let analysisQueue = DispatchQueue(label: "local.xiaoyu-mac-helper.active-vision.analysis")
    private var session: AVCaptureSession?
    private var callback: FaceAttentionCompletionBox?
    private var lastSampleDate: Date?
    private var needsGaze = true
    /// 是否有帧正在推理（仅 queue 上访问）：弱光下单次推理可达上百毫秒，
    /// 超过 200ms 节流间隔时丢弃新帧，避免 analysisQueue 单调积压、结果越来越陈旧。
    private var isAnalyzing = false

    func startChecking(needsGaze: Bool, _ completion: @escaping (FaceAttentionResult?) -> Void) {
        let callback = FaceAttentionCompletionBox(completion)
        queue.async { [weak self, callback] in
            guard let self else { return }

            self.callback = callback
            self.needsGaze = needsGaze
            self.lastSampleDate = nil

            // startSession 全程同步运行在本串行队列内，session == nil 即可判定未启动。
            guard self.session == nil else {
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

            guard !isAnalyzing else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            // 帧数据在缓冲区被保留期间不会被管线复用（引用计数保证），异步分析安全。
            // CVPixelBuffer 本体线程安全（CF 类型），Sendable 标注缺失仅为 API 声明问题。
            nonisolated(unsafe) let analysisBuffer = pixelBuffer
            let sampleNeedsGaze = needsGaze
            let callbackBox = callback
            isAnalyzing = true
            analysisQueue.async { [weak self, callbackBox] in
                let result = FaceAttentionAnalyzer.analyze(pixelBuffer: analysisBuffer, needsGaze: sampleNeedsGaze)
                callbackBox.call(result)
                guard let self else { return }
                self.queue.async {
                    self.isAnalyzing = false
                }
            }
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
        isAnalyzing = false
        session?.stopRunning()
        session = nil
    }
}
