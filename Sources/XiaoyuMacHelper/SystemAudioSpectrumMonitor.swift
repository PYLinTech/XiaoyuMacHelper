import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import CoreMedia
import AudioToolbox

@MainActor
final class SystemAudioSpectrumMonitor: NSObject {
    typealias LevelsHandler = @MainActor ([CGFloat]) -> Void

    var onLevels: LevelsHandler?
    var onCaptureStateChanged: (@MainActor (Bool) -> Void)?

    private var stream: SCStream?
    private var isStarting = false
    private var isRunning = false
    /// 仅在状态翻转时回调，避免未授权路径被 0.1s 轮询反复触发（每秒 10 次全量重绘下游视图）。
    private var lastReportedCaptureState: Bool?

    private func reportCaptureState(_ state: Bool) {
        guard lastReportedCaptureState != state else { return }
        lastReportedCaptureState = state
        onCaptureStateChanged?(state)
    }

    func start() {
        guard ScreenRecordingPermission.isAuthorized else {
            reportCaptureState(false)
            return
        }
        guard !isStarting, !isRunning else { return }
        isStarting = true
        Task { [weak self] in
            await self?.startCapture()
        }
    }

    func stop() {
        guard isStarting || isRunning || stream != nil else { return }
        isStarting = false
        isRunning = false
        reportCaptureState(false)
        let streamToStop = stream
        stream = nil
        Task {
            try? await streamToStop?.stopCapture()
        }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                await finishStartFailure()
                return
            }

            // 使用 excludingWindows 空列表构造全捕获 filter：空应用列表的旧构造
            // 存在流启动失败的社区报告，语义等价但路径更稳。
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 44_100
            configuration.channelCount = 2

            let audioQueue = DispatchQueue(label: "local.xiaoyu-mac-helper.system-audio-spectrum", qos: .userInteractive)
            let audioOutput = AudioOutput { [weak self] levels in
                Task { @MainActor [weak self] in
                    self?.onLevels?(levels)
                }
            }

            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()

            guard isStarting else {
                try? await newStream.stopCapture()
                return
            }
            stream = newStream
            isRunning = true
            isStarting = false
            reportCaptureState(true)
        } catch {
            await finishStartFailure()
        }
    }

    private func finishStartFailure() async {
        isStarting = false
        isRunning = false
        stream = nil
        reportCaptureState(false)
    }
}

// MARK: - SCStreamDelegate（流被系统侧终止时的兜底，如权限被收回/显示器拓扑变化）

extension SystemAudioSpectrumMonitor: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            // 主动 stop() 已先置空 self.stream，走到这里即系统侧外部终止：
            // 清理状态并上报，避免 isRunning 卡死、频谱永久冻结。
            self.stream = nil
            self.isStarting = false
            self.isRunning = false
            self.reportCaptureState(false)
        }
    }
}

private final class AudioOutput: NSObject, SCStreamOutput {
    private let analyzer: AudioSpectrumAnalyzer
    private let levelsHandler: ([CGFloat]) -> Void

    init(levelsHandler: @escaping ([CGFloat]) -> Void) {
        self.analyzer = AudioSpectrumAnalyzer()
        self.levelsHandler = levelsHandler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard let levels = analyzer.process(sampleBuffer: sampleBuffer) else { return }
        levelsHandler(levels)
    }
}

private final class AudioSpectrumAnalyzer {
    // 7 列频谱：columnRecipes/Floors/Caps/transientWeights/motionPhases 均为 7 元素硬编码。
    private static let barCount = 7

    private var lastDeliveryTime: CFTimeInterval = 0

    // Compact, mainstream-inspired spectrum pipeline:
    // 1. Analyze a few musical frequency bands.
    // 2. Normalize each band with per-band AGC instead of absolute volume.
    // 3. Apply per-column attack/release and peak decay, so columns move often
    //    but keep headroom and never stay full.
    private let frequencies: [CGFloat] = [70, 115, 185, 310, 520, 900, 1600, 2850, 5000]
    private let columnRecipes: [[(Int, CGFloat)]] = [
        [(0, 0.70), (1, 0.30)],
        [(1, 0.62), (2, 0.38)],
        [(2, 0.48), (3, 0.38), (1, 0.14)],
        [(3, 0.50), (4, 0.34), (2, 0.16)],
        [(4, 0.48), (5, 0.36), (3, 0.16)],
        [(5, 0.58), (6, 0.30), (4, 0.12)],
        [(6, 0.44), (7, 0.36), (8, 0.20)]
    ]
    private let columnFloors: [CGFloat] = [0.060, 0.085, 0.115, 0.145, 0.120, 0.092, 0.070]
    private let columnCaps: [CGFloat] = [0.48, 0.66, 0.78, 0.86, 0.74, 0.62, 0.52]
    private let transientWeights: [CGFloat] = [0.36, 0.52, 0.66, 0.78, 0.61, 0.46, 0.34]
    private let motionPhases: [CGFloat] = [0.0, 1.7, 3.1, 0.9, 2.6, 4.4, 5.5]

    private var previousSample: Float = 0
    private var bandFloor: [CGFloat]
    private var bandPeak: [CGFloat]
    private var previousBands: [CGFloat]
    private var columnLevels: [CGFloat]
    private var columnPeaks: [CGFloat]
    private var energyFloor: CGFloat = 0.0008
    private var energyPeak: CGFloat = 0.020
    private var beatEnvelope: CGFloat = 0.0
    private var activityEnvelope: CGFloat = 0.0
    private var phase: CGFloat = 0.0

    init() {
        self.bandFloor = Array(repeating: 0.001, count: frequencies.count)
        self.bandPeak = Array(repeating: 0.040, count: frequencies.count)
        self.previousBands = Array(repeating: 0, count: frequencies.count)
        self.columnLevels = Array(repeating: 0.050, count: Self.barCount)
        self.columnPeaks = Array(repeating: 0.050, count: Self.barCount)
    }

    func process(sampleBuffer: CMSampleBuffer) -> [CGFloat]? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        let streamDescription = streamDescriptionPointer.pointee
        guard let samples = Self.extractMonoSamples(from: sampleBuffer, streamDescription: streamDescription), !samples.isEmpty else {
            return nil
        }

        let now = CACurrentMediaTime()
        if now - lastDeliveryTime < 1.0 / 90.0 {
            return nil
        }
        lastDeliveryTime = now

        return analyze(samples: samples, sampleRate: streamDescription.mSampleRate)
    }

    private func analyze(samples: [Float], sampleRate: Double) -> [CGFloat] {
        let sampleCount = max(256, min(samples.count, 1536))
        let startIndex = max(0, samples.count - sampleCount)
        let activeSamples = Array(samples[startIndex..<samples.count])

        let time = analyzeTimeDomain(activeSamples)
        let gate = playbackGate(rms: time.rms, peak: time.peak, motion: time.motion)
        guard gate > 0.01 else { return decayToIdle() }

        updateEnergyAGC(rms: time.rms, peak: time.peak, motion: time.motion)

        let rawBands = analyzeBands(activeSamples, sampleRate: sampleRate)
        let bands = normalizeBands(rawBands)
        let flux = spectralFlux(bands)
        let motion = normalizeMotion(time.motion, rms: time.rms)
        let energy = normalizeEnergy(rms: time.rms, peak: time.peak, motion: time.motion)

        let beatTarget = clamp01(flux * 1.55 + motion * 0.55 + energy * 0.28) * gate
        beatEnvelope += (beatTarget - beatEnvelope) * (beatTarget > beatEnvelope ? 0.78 : 0.18)
        let activityTarget = clamp01(energy * 0.62 + flux * 0.46 + motion * 0.36) * gate
        activityEnvelope += (activityTarget - activityEnvelope) * (activityTarget > activityEnvelope ? 0.42 : 0.08)

        phase += 0.12 + beatEnvelope * 0.24 + activityEnvelope * 0.08
        if phase > CGFloat.pi * 2 { phase -= CGFloat.pi * 2 }

        var targets: [CGFloat] = []
        targets.reserveCapacity(Self.barCount)
        for index in 0..<Self.barCount {
            targets.append(makeColumnTarget(index: index, bands: bands, flux: flux, energy: energy, motion: motion, gate: gate))
        }

        updateColumns(targets: targets, flux: flux, motion: motion)
        return Array(columnLevels.prefix(Self.barCount)).map { clamp($0, min: 0.018, max: 0.92) }
    }

    private func makeColumnTarget(index: Int, bands: [CGFloat], flux: CGFloat, energy: CGFloat, motion: CGFloat, gate: CGFloat) -> CGFloat {
        let recipe = index < columnRecipes.count ? columnRecipes[index] : columnRecipes.last ?? []
        var spectral: CGFloat = 0
        var totalWeight: CGFloat = 0
        for item in recipe {
            let bandIndex = item.0
            let weight = item.1
            if bandIndex >= 0, bandIndex < bands.count {
                spectral += bands[bandIndex] * weight
                totalWeight += weight
            }
        }
        if totalWeight > 0 { spectral /= totalWeight }

        // This is deliberately not symmetric: each column gets a small phase
        // difference, but the phase only appears when real audio is active.
        let phaseOffset = value(from: motionPhases, at: index, fallback: CGFloat(index) * 0.9)
        let organic = max(0, CGFloat(sin(Double(phase + phaseOffset)))) * activityEnvelope * 0.10
        let bounce = beatEnvelope * value(from: transientWeights, at: index, fallback: 0.50) * 0.24
        let detail = flux * (0.10 + CGFloat((index * 5) % 4) * 0.018) + motion * (0.045 + CGFloat(index % 3) * 0.014)

        // Preserve hierarchy without forcing the same maximum height.  Center is
        // taller, neighbor columns are lively, edge columns stay noticeably lower.
        let floor = value(from: columnFloors, at: index, fallback: 0.070) * (0.55 + gate * 0.45)
        let cap = value(from: columnCaps, at: index, fallback: 0.62)
        let shaped = pow(clamp01(spectral), 0.72)
        let drive = clamp01(shaped * 0.78 + bounce + detail + organic + energy * 0.075)

        // Leave visual headroom.  A column can briefly reach its cap, but cannot
        // sit there permanently because columnPeaks decay in updateColumns().
        return floor + (cap - floor) * drive
    }

    private func updateColumns(targets: [CGFloat], flux: CGFloat, motion: CGFloat) {
        for index in 0..<min(targets.count, columnLevels.count) {
            let cap = value(from: columnCaps, at: index, fallback: 0.62)
            let target = min(cap, max(0.018, targets[index]))

            columnPeaks[index] = max(target, columnPeaks[index] * (0.90 - min(0.10, flux * 0.06)))
            let limitedTarget = min(target, columnPeaks[index] + 0.055)

            let isRising = limitedTarget > columnLevels[index]
            let attack: CGFloat = 0.60 + flux * 0.24 + motion * 0.10
            let release: CGFloat = 0.20 + CGFloat((index * 7) % 5) * 0.018
            let rate = isRising ? min(0.92, attack) : release
            columnLevels[index] += (limitedTarget - columnLevels[index]) * rate
        }
    }

    private func decayToIdle() -> [CGFloat] {
        beatEnvelope *= 0.62
        activityEnvelope *= 0.70
        for index in 0..<columnLevels.count {
            let idle = value(from: columnFloors, at: index, fallback: 0.06) * 0.36
            columnLevels[index] += (idle - columnLevels[index]) * 0.22
            columnPeaks[index] += (idle - columnPeaks[index]) * 0.18
        }
        return Array(columnLevels.prefix(Self.barCount)).map { max(0.018, $0) }
    }

    private func analyzeTimeDomain(_ samples: [Float]) -> (rms: CGFloat, peak: CGFloat, motion: CGFloat) {
        var rmsSum: Double = 0
        var peak: Float = 0
        var motionSum: Double = 0
        var previous = previousSample
        for raw in samples {
            let sample = min(1, max(-1, raw))
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            rmsSum += Double(sample * sample)
            motionSum += Double(abs(sample - previous))
            previous = sample
        }
        previousSample = previous
        let count = max(1, samples.count)
        return (
            CGFloat(sqrt(rmsSum / Double(count))),
            CGFloat(peak),
            CGFloat(motionSum) / CGFloat(count)
        )
    }

    private func analyzeBands(_ samples: [Float], sampleRate: Double) -> [CGFloat] {
        var values: [CGFloat] = []
        values.reserveCapacity(frequencies.count)
        let nyquist = max(1000, CGFloat(sampleRate) * 0.5)
        for frequency in frequencies {
            let clampedFrequency = min(max(45, frequency), nyquist * 0.82)
            let magnitude = goertzelMagnitude(samples: samples, sampleRate: sampleRate, frequency: Double(clampedFrequency))
            // Log scale keeps loud songs from saturating and quiet details visible.
            let value = CGFloat(log1p(Double(magnitude * 32.0)) / log1p(32.0))
            values.append(value)
        }
        return values
    }

    private func normalizeBands(_ rawBands: [CGFloat]) -> [CGFloat] {
        var normalized: [CGFloat] = []
        normalized.reserveCapacity(rawBands.count)
        for index in 0..<rawBands.count {
            let raw = rawBands[index]
            let floorRate: CGFloat = raw < bandFloor[index] ? 0.12 : 0.004
            bandFloor[index] += (min(raw * 0.82, 0.18) - bandFloor[index]) * floorRate
            bandFloor[index] = clamp(bandFloor[index], min: 0.0001, max: 0.22)

            let peakTarget = max(raw, bandFloor[index] + 0.030)
            let peakRate: CGFloat = peakTarget > bandPeak[index] ? 0.34 : 0.012
            bandPeak[index] += (peakTarget - bandPeak[index]) * peakRate
            bandPeak[index] = clamp(bandPeak[index], min: bandFloor[index] + 0.030, max: 1.0)

            let value = (raw - bandFloor[index]) / max(0.026, bandPeak[index] - bandFloor[index])
            normalized.append(pow(clamp01(value), 0.86))
        }
        return normalized
    }

    private func spectralFlux(_ bands: [CGFloat]) -> CGFloat {
        guard !bands.isEmpty else { return 0 }
        var flux: CGFloat = 0
        for index in 0..<min(bands.count, previousBands.count) {
            let rise = max(0, bands[index] - previousBands[index])
            let weight: CGFloat = index >= 2 && index <= 6 ? 1.18 : 0.92
            flux += rise * weight
            previousBands[index] += (bands[index] - previousBands[index]) * (bands[index] > previousBands[index] ? 0.58 : 0.18)
        }
        return clamp01(flux / CGFloat(max(1, bands.count)) * 3.0)
    }

    private func updateEnergyAGC(rms: CGFloat, peak: CGFloat, motion: CGFloat) {
        let energy = max(rms, peak * 0.40, motion * 2.2)
        let floorTarget = min(0.060, energy * 0.18)
        energyFloor += (floorTarget - energyFloor) * (floorTarget < energyFloor ? 0.10 : 0.004)
        energyFloor = clamp(energyFloor, min: 0.0001, max: 0.080)

        let peakTarget = max(energy, energyFloor + 0.010)
        energyPeak += (peakTarget - energyPeak) * (peakTarget > energyPeak ? 0.30 : 0.018)
        energyPeak = clamp(energyPeak, min: energyFloor + 0.010, max: 0.90)
    }

    private func normalizeEnergy(rms: CGFloat, peak: CGFloat, motion: CGFloat) -> CGFloat {
        let energy = max(rms, peak * 0.42, motion * 2.3)
        let value = (energy - energyFloor) / max(0.010, energyPeak - energyFloor)
        return pow(clamp01(value), 0.86)
    }

    private func normalizeMotion(_ motion: CGFloat, rms: CGFloat) -> CGFloat {
        let value = motion / max(0.0008, rms * 0.42 + energyFloor * 0.65)
        return clamp01(value * 1.18)
    }

    private func playbackGate(rms: CGFloat, peak: CGFloat, motion: CGFloat) -> CGFloat {
        let rmsGate = smoothstep((rms - 0.00018) / 0.0020)
        let peakGate = smoothstep((peak - 0.00080) / 0.0050)
        let motionGate = smoothstep((motion - 0.00014) / 0.0017)
        return max(rmsGate, max(peakGate, motionGate))
    }

    /// Hann 窗缓存：窗函数只依赖样本数，而频段循环（9 频段 × 90fps）反复用同一窗，
    /// 按 buffer 容量预生成一次，避免每帧每频段重复算 cos。
    private var hannWindowCache: [Float] = []

    private func hannWindow(forCount count: Int) -> [Float] {
        if hannWindowCache.count == count { return hannWindowCache }
        let denominator = max(1, count - 1)
        let window = (0..<count).map { index in
            Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / Double(denominator)))
        }
        hannWindowCache = window
        return window
    }

    private func goertzelMagnitude(samples: [Float], sampleRate: Double, frequency: Double) -> CGFloat {
        guard !samples.isEmpty, sampleRate > 0, frequency > 0 else { return 0 }
        let n = samples.count
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let coefficient = 2.0 * cos(omega)
        var q0 = 0.0
        var q1 = 0.0
        var q2 = 0.0
        let window = hannWindow(forCount: n)
        for index in 0..<n {
            q0 = coefficient * q1 - q2 + Double(samples[index]) * Double(window[index])
            q2 = q1
            q1 = q0
        }
        let power = q1 * q1 + q2 * q2 - coefficient * q1 * q2
        return CGFloat(sqrt(max(0, power)) / Double(max(1, n)))
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = clamp01(value)
        return t * t * (3.0 - 2.0 * t)
    }

    private func value(from values: [CGFloat], at index: Int, fallback: CGFloat) -> CGFloat {
        guard index >= 0, index < values.count else { return fallback }
        return values[index]
    }

    private func clamp01(_ value: CGFloat) -> CGFloat {
        clamp(value, min: 0, max: 1)
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(upper, Swift.max(lower, value))
    }

    private static func extractMonoSamples(from sampleBuffer: CMSampleBuffer, streamDescription: AudioStreamBasicDescription) -> [Float]? {
        let formatFlags = streamDescription.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)

        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, bufferListSize > 0 else {
            return extractMonoSamplesFromDataBuffer(sampleBuffer: sampleBuffer, streamDescription: streamDescription)
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let audioBufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return extractMonoSamplesFromDataBuffer(sampleBuffer: sampleBuffer, streamDescription: streamDescription)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        var channelSamples: [[Float]] = []
        channelSamples.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            let channelCount = max(1, Int(buffer.mNumberChannels))
            if isFloat, bitsPerChannel == 32 {
                channelSamples.append(deinterleavedFloatSamples(data: data, byteCount: byteCount, channelCount: channelCount))
            } else if isSignedInteger, bitsPerChannel == 16 {
                channelSamples.append(deinterleavedInt16Samples(data: data, byteCount: byteCount, channelCount: channelCount))
            } else if isSignedInteger, bitsPerChannel == 32 {
                channelSamples.append(deinterleavedInt32Samples(data: data, byteCount: byteCount, channelCount: channelCount))
            }
        }

        guard !channelSamples.isEmpty else {
            return extractMonoSamplesFromDataBuffer(sampleBuffer: sampleBuffer, streamDescription: streamDescription)
        }
        if channelSamples.count == 1 {
            return channelSamples[0]
        }
        let minCount = channelSamples.map { $0.count }.min() ?? 0
        guard minCount > 0 else { return nil }
        var mono = Array(repeating: Float(0), count: minCount)
        for samples in channelSamples {
            for index in 0..<minCount {
                mono[index] += samples[index]
            }
        }
        let scale = Float(1.0 / Double(channelSamples.count))
        for index in 0..<mono.count {
            mono[index] *= scale
        }
        return mono
    }

    private static func extractMonoSamplesFromDataBuffer(sampleBuffer: CMSampleBuffer, streamDescription: AudioStreamBasicDescription) -> [Float]? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let byteCount = CMBlockBufferGetDataLength(dataBuffer)
        guard byteCount > 0 else { return nil }
        var bytes = Array(repeating: UInt8(0), count: byteCount)
        let status = bytes.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: byteCount, destination: baseAddress)
        }
        guard status == noErr else { return nil }

        let formatFlags = streamDescription.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)

        return bytes.withUnsafeBytes { rawBuffer -> [Float]? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            if isFloat, bitsPerChannel == 32 {
                return deinterleavedFloatSamples(data: baseAddress, byteCount: byteCount, channelCount: channelCount)
            }
            if isSignedInteger, bitsPerChannel == 16 {
                return deinterleavedInt16Samples(data: baseAddress, byteCount: byteCount, channelCount: channelCount)
            }
            if isSignedInteger, bitsPerChannel == 32 {
                return deinterleavedInt32Samples(data: baseAddress, byteCount: byteCount, channelCount: channelCount)
            }
            return nil
        }
    }

    private static func deinterleavedFloatSamples(data: UnsafeRawPointer, byteCount: Int, channelCount: Int) -> [Float] {
        deinterleavedSamples(
            data: data, byteCount: byteCount, channelCount: channelCount,
            as: Float.self
        ) { $0 }
    }

    private static func deinterleavedInt16Samples(data: UnsafeRawPointer, byteCount: Int, channelCount: Int) -> [Float] {
        deinterleavedSamples(
            data: data, byteCount: byteCount, channelCount: channelCount,
            as: Int16.self
        ) { Float($0) / 32768.0 }
    }

    private static func deinterleavedInt32Samples(data: UnsafeRawPointer, byteCount: Int, channelCount: Int) -> [Float] {
        deinterleavedSamples(
            data: data, byteCount: byteCount, channelCount: channelCount,
            as: Int32.self
        ) { Float(Double($0) / 2_147_483_648.0) }
    }

    /// 交错采样 → 单声道均值，骨架共用，仅单样本换算由 `convert` 决定。
    private static func deinterleavedSamples<T>(
        data: UnsafeRawPointer,
        byteCount: Int,
        channelCount: Int,
        as type: T.Type,
        convert: (T) -> Float
    ) -> [Float] {
        let valueCount = byteCount / MemoryLayout<T>.size
        guard valueCount > 0 else { return [] }
        let pointer = data.assumingMemoryBound(to: T.self)
        if channelCount <= 1 {
            var mono: [Float] = []
            mono.reserveCapacity(valueCount)
            for index in 0..<valueCount {
                mono.append(convert(pointer[index]))
            }
            return mono
        }
        let frameCount = valueCount / channelCount
        var mono = Array(repeating: Float(0), count: frameCount)
        for frame in 0..<frameCount {
            var sum = Float(0)
            let base = frame * channelCount
            for channel in 0..<channelCount {
                sum += convert(pointer[base + channel])
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }
}
