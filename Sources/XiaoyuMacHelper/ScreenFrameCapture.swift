import AppKit
import CoreImage
import CoreVideo
@preconcurrency import ScreenCaptureKit

// MARK: - macOS 15.0 / 15.1 单帧截图降级工具
//
// SCScreenshotManager 需要 macOS 15.2+。在 15.0 / 15.1 上，
// 使用 ScreenCaptureKit 的 SCStream 手动截取一帧并裁剪到指定区域。

@MainActor
final class ScreenFrameCapture {
    /// 截取 rect（CGDisplay 坐标空间，左上原点）内的画面。
    func captureImage(in rect: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.current else { return nil }

        var matchedDisplay: SCDisplay?
        for display in content.displays where display.frame.intersects(rect) {
            matchedDisplay = display
            break
        }
        guard let display = matchedDisplay else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = FrameOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen-frame-capture"))
        } catch {
            return nil
        }

        let fullImage = await output.waitForFirstFrame(stream: stream)
        try? await stream.stopCapture()

        guard let fullImage else { return nil }
        return Self.cropping(fullImage, to: rect, displayFrame: display.frame)
    }

    private static func cropping(_ image: CGImage, to rect: CGRect, displayFrame: CGRect) -> CGImage? {
        let scaleX = CGFloat(image.width) / displayFrame.width
        let scaleY = CGFloat(image.height) / displayFrame.height

        let cropRect = CGRect(
            x: (rect.minX - displayFrame.minX) * scaleX,
            y: (rect.minY - displayFrame.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        guard cropRect.width >= 1, cropRect.height >= 1,
              cropRect.minX >= 0, cropRect.minY >= 0,
              cropRect.maxX <= CGFloat(image.width), cropRect.maxY <= CGFloat(image.height) else {
            return image
        }

        return image.cropping(to: cropRect)
    }
}

/// SCStream 屏幕输出代理，等待并返回第一帧图像。
private final class FrameOutput: NSObject, SCStreamOutput {
    private let box = ContinuationBox()

    func waitForFirstFrame(stream: SCStream) async -> CGImage? {
        let box = box
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            box.value = continuation
            Task {
                do {
                    try await stream.startCapture()
                } catch {
                    box.value?.resume(returning: nil)
                    box.value = nil
                }
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent)

        box.value?.resume(returning: cgImage)
        box.value = nil
    }
}

/// 在非隔离回调与 continuation 之间传递的单值容器。
private final class ContinuationBox: @unchecked Sendable {
    nonisolated(unsafe) var value: CheckedContinuation<CGImage?, Never>?
}
