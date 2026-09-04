@preconcurrency import AVFoundation

private final class CameraPermissionCompletionBox: @unchecked Sendable {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    @MainActor
    func call(_ value: Bool) {
        handler(value)
    }
}

enum CameraPermission {
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        let callback = CameraPermissionCompletionBox(completion)
        AVCaptureDevice.requestAccess(for: .video) { isGranted in
            Task { @MainActor in
                callback.call(isGranted)
            }
        }
    }
}
