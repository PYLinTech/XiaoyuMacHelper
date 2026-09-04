import CoreGraphics
import CoreImage
import CoreVideo
@preconcurrency import Vision

struct FaceAttentionResult: Sendable {
    static let none = FaceAttentionResult(isFacingScreen: false, isGazingAtScreen: false)

    let isFacingScreen: Bool
    let isGazingAtScreen: Bool
}

enum FaceAttentionAnalyzer {
    /// 复用同一个请求实例（Vision 请求可重复执行；分析已串行化，无并发竞争）。
    private static let faceRequest = VNDetectFaceLandmarksRequest()

    private enum Metrics {
        static let minimumFaceWidth: CGFloat = 0.08
        static let minimumFaceHeight: CGFloat = 0.08
        static let faceCenterX: ClosedRange<Double> = 0.13...0.87
        static let faceCenterY: ClosedRange<Double> = 0.08...0.94

        static let lowLightBrightnessThreshold: Double = 0.24
        static let veryLowLightBrightnessThreshold: Double = 0.14
        static let brightnessSampleColumns = 10
        static let brightnessSampleRows = 8

        // 面向屏幕：允许自然轻微偏头，但必须是正脸结构。
        static let facingYawLimit: Double = 0.54
        static let facingPitchLimit: Double = 0.52
        static let facingRollLimit: Double = 0.42
        static let facingMinimumPoseScore: Double = 0.44
        static let facingMinimumGeometryScore: Double = 0.50
        static let facingMinimumFinalScore: Double = 0.56
        static let eyeDistanceRange: ClosedRange<CGFloat> = 0.15...0.76
        static let eyeLineTiltLimit: CGFloat = 0.15
        static let eyeMidpointHorizontalOffsetLimit: CGFloat = 0.22
        static let noseHorizontalOffsetLimit: CGFloat = 0.22
        static let noseVerticalOffsetRange: ClosedRange<CGFloat> = 0.04...0.48
        static let facingMinimumOpenEyeRatio: CGFloat = 0.070
        static let facingLowLightMinimumOpenEyeRatio: CGFloat = 0.056
        static let facingMaximumOpenRatioDifference: CGFloat = 0.30

        // 注视屏幕：闭眼直接失败；必须有双瞳孔，并且视线几何接近摄像头/屏幕方向。
        static let gazeYawLimit: Double = 0.38
        static let gazePitchLimit: Double = 0.40
        static let gazeRollLimit: Double = 0.32
        static let gazeMinimumPoseScore: Double = 0.58
        static let gazeMinimumFacingScore: Double = 0.58
        static let gazeMinimumFinalScore: Double = 0.64
        static let minimumOpenEyeRatio: CGFloat = 0.115
        static let lowLightMinimumOpenEyeRatio: CGFloat = 0.088
        static let idealOpenEyeRatio: CGFloat = 0.205
        static let lowLightIdealOpenEyeRatio: CGFloat = 0.170
        static let maximumOpenRatioDifference: CGFloat = 0.18
        static let pupilIndividualXLimit: Double = 0.82
        static let pupilIndividualYLimit: Double = 0.82
        static let pupilAverageXLimit: Double = 0.48
        static let pupilAverageYLimit: Double = 0.55
        static let pupilConsistencyXLimit: Double = 0.52
        static let pupilConsistencyYLimit: Double = 0.50
        static let minimumEyePointCount = 5
    }

    static func analyze(pixelBuffer: CVPixelBuffer, needsGaze: Bool) -> FaceAttentionResult {
        let quality = frameQuality(of: pixelBuffer)
        guard let observation = bestObservation(in: pixelBuffer, quality: quality) else {
            return .none
        }

        let isFacingScreen = isFacingScreen(observation, quality: quality)
        let isGazingAtScreen = needsGaze && isGazingAtScreen(observation, facingPassed: isFacingScreen, quality: quality)
        return FaceAttentionResult(isFacingScreen: isFacingScreen, isGazingAtScreen: isGazingAtScreen)
    }

    private static func bestObservation(in pixelBuffer: CVPixelBuffer, quality: FrameQuality) -> FaceObservation? {
        // 普通帧优先，弱光增强只作为兜底。增强图可能提高人脸检出率，但也可能让瞳孔 landmark 漂移。
        if let observation = performFaceRequest(pixelBuffer: pixelBuffer, quality: quality, enhancedForLowLight: false) {
            return observation
        }

        guard quality.isLowLight else { return nil }
        return performFaceRequest(pixelBuffer: pixelBuffer, quality: quality, enhancedForLowLight: true)
    }

    private static func performFaceRequest(pixelBuffer: CVPixelBuffer, quality: FrameQuality, enhancedForLowLight: Bool) -> FaceObservation? {
        let request = faceRequest
        let handler: VNImageRequestHandler

        if enhancedForLowLight {
            handler = VNImageRequestHandler(ciImage: enhancedLowLightImage(from: pixelBuffer, quality: quality), orientation: .up, options: [:])
        } else {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        }

        guard (try? handler.perform([request])) != nil else {
            return nil
        }

        return bestUsableObservation(in: request.results ?? [], quality: quality)
    }

    private static func enhancedLowLightImage(from pixelBuffer: CVPixelBuffer, quality: FrameQuality) -> CIImage {
        let brightnessBoost = quality.isVeryLowLight ? 0.11 : 0.07
        let contrastBoost = quality.isVeryLowLight ? 1.16 : 1.10
        let gammaPower = quality.isVeryLowLight ? 0.80 : 0.88

        return CIImage(cvPixelBuffer: pixelBuffer)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightnessBoost,
                kCIInputContrastKey: contrastBoost,
                kCIInputSaturationKey: 1.02
            ])
            .applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": gammaPower
            ])
    }

    private static func bestUsableObservation(in faces: [VNFaceObservation], quality: FrameQuality) -> FaceObservation? {
        var bestObservation: FaceObservation?
        var bestScore = Double.leastNormalMagnitude

        for face in faces {
            guard let observation = makeObservation(from: face) else { continue }

            let box = face.boundingBox
            let areaScore = clipped01(Double((box.width * box.height) / 0.13))
            let centerScore = clipped01(
                0.56 * axisScore(Double(box.midX - 0.5), limit: 0.39) +
                0.44 * axisScore(Double(box.midY - 0.52), limit: 0.44)
            )
            let poseScore = poseScore(
                yaw: observation.yaw,
                pitch: observation.pitch,
                roll: observation.roll,
                yawLimit: Metrics.facingYawLimit + (quality.isLowLight ? 0.06 : 0),
                pitchLimit: Metrics.facingPitchLimit + (quality.isLowLight ? 0.06 : 0),
                rollLimit: Metrics.facingRollLimit + (quality.isLowLight ? 0.04 : 0)
            )

            let score = 0.42 * areaScore + 0.34 * centerScore + 0.24 * poseScore
            if score > bestScore {
                bestScore = score
                bestObservation = observation
            }
        }

        return bestObservation
    }

    private static func makeObservation(from face: VNFaceObservation) -> FaceObservation? {
        let box = face.boundingBox
        guard box.width >= Metrics.minimumFaceWidth,
              box.height >= Metrics.minimumFaceHeight,
              Metrics.faceCenterX.contains(Double(box.midX)),
              Metrics.faceCenterY.contains(Double(box.midY)),
              let eyes = eyePair(from: face.landmarks),
              let noseCenter = centerOfNose(face.landmarks) else {
            return nil
        }

        return FaceObservation(
            eyes: eyes,
            noseCenter: noseCenter,
            yaw: face.yaw?.doubleValue ?? 0,
            pitch: face.pitch?.doubleValue ?? 0,
            roll: face.roll?.doubleValue ?? 0
        )
    }

    // MARK: - 面向屏幕

    private static func isFacingScreen(_ observation: FaceObservation, quality: FrameQuality) -> Bool {
        facingScore(observation, quality: quality) >= threshold(Metrics.facingMinimumFinalScore, quality: quality, lowLightReduction: 0.04)
    }

    private static func facingScore(_ observation: FaceObservation, quality: FrameQuality) -> Double {
        let toleranceScale = quality.isLowLight ? 1.12 : 1.0
        let pose = poseScore(
            yaw: observation.yaw,
            pitch: observation.pitch,
            roll: observation.roll,
            yawLimit: Metrics.facingYawLimit * toleranceScale,
            pitchLimit: Metrics.facingPitchLimit * toleranceScale,
            rollLimit: Metrics.facingRollLimit * toleranceScale
        )
        guard pose >= threshold(Metrics.facingMinimumPoseScore, quality: quality, lowLightReduction: 0.04) else {
            return 0
        }

        guard hasOpenEnoughEyesForFacing(observation.eyes, quality: quality) else {
            return 0
        }

        let geometry = facingGeometryScore(observation, toleranceScale: toleranceScale)
        guard geometry >= threshold(Metrics.facingMinimumGeometryScore, quality: quality, lowLightReduction: 0.04) else {
            return 0
        }

        return clipped01(0.48 * pose + 0.52 * geometry)
    }

    private static func hasOpenEnoughEyesForFacing(_ eyes: EyePair, quality: FrameQuality) -> Bool {
        let minimum = quality.isLowLight ? Metrics.facingLowLightMinimumOpenEyeRatio : Metrics.facingMinimumOpenEyeRatio
        return eyes.left.openRatio >= minimum &&
            eyes.right.openRatio >= minimum &&
            abs(eyes.left.openRatio - eyes.right.openRatio) <= Metrics.facingMaximumOpenRatioDifference
    }

    private static func facingGeometryScore(_ observation: FaceObservation, toleranceScale: Double) -> Double {
        let leftEye = observation.eyes.left.center
        let rightEye = observation.eyes.right.center
        let eyeMidpoint = midpoint(leftEye, rightEye)
        let eyeDistance = abs(rightEye.x - leftEye.x)
        guard Metrics.eyeDistanceRange.contains(eyeDistance) else { return 0 }

        let eyeLineTilt = abs(leftEye.y - rightEye.y)
        let eyeMidpointOffset = abs(eyeMidpoint.x - 0.5)
        let noseOffsetX = abs(observation.noseCenter.x - eyeMidpoint.x)
        let noseOffsetY = abs(observation.noseCenter.y - eyeMidpoint.y)

        let eyeTiltLimit = Metrics.eyeLineTiltLimit * CGFloat(toleranceScale)
        let eyeCenterLimit = Metrics.eyeMidpointHorizontalOffsetLimit * CGFloat(toleranceScale)
        let noseXLimit = Metrics.noseHorizontalOffsetLimit * CGFloat(toleranceScale)
        let noseYRange = Metrics.noseVerticalOffsetRange.lowerBound...(Metrics.noseVerticalOffsetRange.upperBound * CGFloat(toleranceScale))

        guard eyeLineTilt <= eyeTiltLimit,
              eyeMidpointOffset <= eyeCenterLimit,
              noseOffsetX <= noseXLimit,
              noseYRange.contains(noseOffsetY) else {
            return 0
        }

        return clipped01(
            0.25 * eyeDistanceScore(eyeDistance) +
            0.22 * axisScore(Double(eyeLineTilt), limit: Double(eyeTiltLimit)) +
            0.20 * axisScore(Double(eyeMidpointOffset), limit: Double(eyeCenterLimit)) +
            0.20 * axisScore(Double(noseOffsetX), limit: Double(noseXLimit)) +
            0.13 * rangeScore(noseOffsetY, in: noseYRange)
        )
    }

    // MARK: - 注视屏幕

    private static func isGazingAtScreen(_ observation: FaceObservation, facingPassed: Bool, quality: FrameQuality) -> Bool {
        // 注视比面向更严格；即使“面向屏幕”未单独勾选，也必须满足接近正脸的基本几何。
        let facing = facingPassed ? max(facingScore(observation, quality: quality), Metrics.gazeMinimumFacingScore) : facingScore(observation, quality: quality)
        guard facing >= threshold(Metrics.gazeMinimumFacingScore, quality: quality, lowLightReduction: 0.03) else {
            return false
        }

        let pose = poseScore(
            yaw: observation.yaw,
            pitch: observation.pitch,
            roll: observation.roll,
            yawLimit: Metrics.gazeYawLimit * (quality.isLowLight ? 1.10 : 1.0),
            pitchLimit: Metrics.gazePitchLimit * (quality.isLowLight ? 1.10 : 1.0),
            rollLimit: Metrics.gazeRollLimit * (quality.isLowLight ? 1.08 : 1.0)
        )
        guard pose >= threshold(Metrics.gazeMinimumPoseScore, quality: quality, lowLightReduction: 0.04) else {
            return false
        }

        guard let gaze = gazeEvidence(from: observation.eyes, quality: quality) else {
            return false
        }

        let finalScore = clipped01(
            0.26 * pose +
            0.20 * facing +
            0.24 * gaze.openEyeScore +
            0.30 * gaze.pupilDirectionScore
        )
        return finalScore >= threshold(Metrics.gazeMinimumFinalScore, quality: quality, lowLightReduction: 0.05)
    }

    private static func gazeEvidence(from eyes: EyePair, quality: FrameQuality) -> GazeEvidence? {
        guard let leftPupil = eyes.left.pupilCenter,
              let rightPupil = eyes.right.pupilCenter else {
            return nil
        }

        let requiredOpenRatio = quality.isLowLight ? Metrics.lowLightMinimumOpenEyeRatio : Metrics.minimumOpenEyeRatio
        let idealOpenRatio = quality.isLowLight ? Metrics.lowLightIdealOpenEyeRatio : Metrics.idealOpenEyeRatio
        let leftOpenRatio = eyes.left.openRatio
        let rightOpenRatio = eyes.right.openRatio

        // 闭眼/半闭眼先一票否决。Vision 偶尔会在闭眼时返回 pupil 点，不能信。
        guard leftOpenRatio >= requiredOpenRatio,
              rightOpenRatio >= requiredOpenRatio,
              abs(leftOpenRatio - rightOpenRatio) <= Metrics.maximumOpenRatioDifference else {
            return nil
        }

        guard let leftOffset = normalizedPupilOffset(leftPupil, in: eyes.left),
              let rightOffset = normalizedPupilOffset(rightPupil, in: eyes.right) else {
            return nil
        }

        let toleranceScale = quality.isLowLight ? 1.12 : 1.0
        guard abs(leftOffset.x) <= Metrics.pupilIndividualXLimit * toleranceScale,
              abs(rightOffset.x) <= Metrics.pupilIndividualXLimit * toleranceScale,
              abs(leftOffset.y) <= Metrics.pupilIndividualYLimit * toleranceScale,
              abs(rightOffset.y) <= Metrics.pupilIndividualYLimit * toleranceScale else {
            return nil
        }

        let averageX = (leftOffset.x + rightOffset.x) / 2
        let averageY = (leftOffset.y + rightOffset.y) / 2
        let consistencyX = abs(leftOffset.x - rightOffset.x)
        let consistencyY = abs(leftOffset.y - rightOffset.y)

        guard abs(averageX) <= Metrics.pupilAverageXLimit * toleranceScale,
              abs(averageY) <= Metrics.pupilAverageYLimit * toleranceScale,
              consistencyX <= Metrics.pupilConsistencyXLimit * toleranceScale,
              consistencyY <= Metrics.pupilConsistencyYLimit * toleranceScale else {
            return nil
        }

        let openScore = clipped01(
            0.45 * rampScore(Double(leftOpenRatio), minimum: Double(requiredOpenRatio), ideal: Double(idealOpenRatio)) +
            0.45 * rampScore(Double(rightOpenRatio), minimum: Double(requiredOpenRatio), ideal: Double(idealOpenRatio)) +
            0.10 * axisScore(Double(leftOpenRatio - rightOpenRatio), limit: Double(Metrics.maximumOpenRatioDifference))
        )
        let directionScore = clipped01(
            0.32 * axisScore(averageX, limit: Metrics.pupilAverageXLimit * toleranceScale) +
            0.28 * axisScore(averageY, limit: Metrics.pupilAverageYLimit * toleranceScale) +
            0.22 * axisScore(consistencyX, limit: Metrics.pupilConsistencyXLimit * toleranceScale) +
            0.18 * axisScore(consistencyY, limit: Metrics.pupilConsistencyYLimit * toleranceScale)
        )

        return GazeEvidence(openEyeScore: openScore, pupilDirectionScore: directionScore)
    }

    private static func normalizedPupilOffset(_ pupil: CGPoint, in eye: EyeProfile) -> CGPoint? {
        guard eye.bounds.contains(pupil) else { return nil }

        let horizontalScale = max(eye.bounds.width * 0.5, 0.001)
        let verticalScale = max(eye.bounds.height * 0.5, 0.001)
        return CGPoint(
            x: (pupil.x - eye.center.x) / horizontalScale,
            y: (pupil.y - eye.center.y) / verticalScale
        )
    }

    // MARK: - Landmark parsing

    private static func eyePair(from landmarks: VNFaceLandmarks2D?) -> EyePair? {
        guard let leftEye = landmarks?.leftEye,
              let rightEye = landmarks?.rightEye,
              leftEye.pointCount >= Metrics.minimumEyePointCount,
              rightEye.pointCount >= Metrics.minimumEyePointCount,
              let left = eyeProfile(eye: leftEye, pupil: landmarks?.leftPupil),
              let right = eyeProfile(eye: rightEye, pupil: landmarks?.rightPupil) else {
            return nil
        }

        return EyePair(left: left, right: right)
    }

    private static func eyeProfile(eye: VNFaceLandmarkRegion2D, pupil: VNFaceLandmarkRegion2D?) -> EyeProfile? {
        guard let metrics = landmarkMetrics(of: eye) else { return nil }
        return EyeProfile(
            center: metrics.center,
            bounds: metrics.bounds,
            pupilCenter: pupil.flatMap { landmarkMetrics(of: $0)?.center }
        )
    }

    private static func centerOfNose(_ landmarks: VNFaceLandmarks2D?) -> CGPoint? {
        if let nose = landmarks?.nose, let center = landmarkMetrics(of: nose)?.center {
            return center
        }

        if let noseCrest = landmarks?.noseCrest, let center = landmarkMetrics(of: noseCrest)?.center {
            return center
        }

        return nil
    }

    private static func landmarkMetrics(of region: VNFaceLandmarkRegion2D) -> LandmarkMetrics? {
        let points = region.normalizedPoints
        guard let first = points.first else { return nil }

        var sum = CGPoint.zero
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in points {
            sum.x += point.x
            sum.y += point.y
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let count = CGFloat(points.count)
        return LandmarkMetrics(
            center: CGPoint(x: sum.x / count, y: sum.y / count),
            bounds: CGRect(x: minX, y: minY, width: max(maxX - minX, 0.001), height: max(maxY - minY, 0.001))
        )
    }

    // MARK: - Frame quality

    private static func frameQuality(of pixelBuffer: CVPixelBuffer) -> FrameQuality {
        FrameQuality(brightness: estimatedBrightness(of: pixelBuffer))
    }

    private static func estimatedBrightness(of pixelBuffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return 0.5
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0.5
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return 0.5
        }

        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var total: Double = 0
        var samples = 0

        for row in 0..<Metrics.brightnessSampleRows {
            let y = min(max((row * height) / max(Metrics.brightnessSampleRows - 1, 1), 0), height - 1)
            for column in 0..<Metrics.brightnessSampleColumns {
                let x = min(max((column * width) / max(Metrics.brightnessSampleColumns - 1, 1), 0), width - 1)
                let offset = y * bytesPerRow + x * 4
                let b = Double(pointer[offset])
                let g = Double(pointer[offset + 1])
                let r = Double(pointer[offset + 2])
                total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                samples += 1
            }
        }

        return samples > 0 ? total / Double(samples) : 0.5
    }

    // MARK: - Scoring helpers

    private static func poseScore(yaw: Double, pitch: Double, roll: Double, yawLimit: Double, pitchLimit: Double, rollLimit: Double) -> Double {
        clipped01(
            0.42 * axisScore(yaw, limit: yawLimit) +
            0.38 * axisScore(pitch, limit: pitchLimit) +
            0.20 * axisScore(roll, limit: rollLimit)
        )
    }

    private static func eyeDistanceScore(_ distance: CGFloat) -> Double {
        let preferredDistance: CGFloat = 0.38
        let tolerance: CGFloat = 0.25
        return axisScore(Double(distance - preferredDistance), limit: Double(tolerance))
    }

    private static func rangeScore(_ value: CGFloat, in range: ClosedRange<CGFloat>) -> Double {
        let midpoint = (range.lowerBound + range.upperBound) / 2
        let halfWidth = max((range.upperBound - range.lowerBound) / 2, 0.001)
        return axisScore(Double(value - midpoint), limit: Double(halfWidth))
    }

    private static func rampScore(_ value: Double, minimum: Double, ideal: Double) -> Double {
        clipped01((value - minimum) / max(ideal - minimum, 0.001))
    }

    private static func axisScore(_ value: Double, limit: Double) -> Double {
        clipped01(1 - abs(value) / max(limit, 0.001))
    }

    private static func threshold(_ value: Double, quality: FrameQuality, lowLightReduction: Double) -> Double {
        max(0.46, value - (quality.isLowLight ? lowLightReduction : 0))
    }

    private static func clipped01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func midpoint(_ left: CGPoint, _ right: CGPoint) -> CGPoint {
        CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
    }

    private struct FaceObservation {
        let eyes: EyePair
        let noseCenter: CGPoint
        let yaw: Double
        let pitch: Double
        let roll: Double
    }

    private struct FrameQuality {
        let brightness: Double

        var isLowLight: Bool {
            brightness < Metrics.lowLightBrightnessThreshold
        }

        var isVeryLowLight: Bool {
            brightness < Metrics.veryLowLightBrightnessThreshold
        }
    }

    private struct EyePair {
        let left: EyeProfile
        let right: EyeProfile
    }

    private struct EyeProfile {
        let center: CGPoint
        let bounds: CGRect
        let pupilCenter: CGPoint?

        var openRatio: CGFloat {
            bounds.height / max(bounds.width, 0.001)
        }
    }

    private struct LandmarkMetrics {
        let center: CGPoint
        let bounds: CGRect
    }

    private struct GazeEvidence {
        let openEyeScore: Double
        let pupilDirectionScore: Double
    }
}
