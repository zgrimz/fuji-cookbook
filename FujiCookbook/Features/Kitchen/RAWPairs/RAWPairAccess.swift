import Photos

/// The app's photo library access, in the terms the RAW+JPEG route decides on.
enum PhotoAccess: Equatable {
    case notDetermined
    /// The user chose Limit Access: the app sees only the photos selected in Apple's screen.
    case limited
    case full
    case denied
    /// Screen Time or device management forbids access; the user can't grant it.
    case restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .limited: self = .limited
        case .authorized: self = .full
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }

    /// Whether the app can fetch any photo by its identifier.
    var canRead: Bool { self == .limited || self == .full }
}

/// What tapping Choose RAW+JPEG Photos opens, for each state of access.
///
/// The photo picker hands over only the JPEG of a RAW+JPEG photo; the RAF is a resource Photos keeps
/// behind it, reachable only with photo library access. A photo picked in the picker isn't granted
/// by being picked: with limited access its identifier fetches nothing unless it was selected in
/// Apple's screen (iPhone 14 Pro, iOS 27.0.1, 2026-11-13).
enum RAWPairRoute: Equatable {
    /// Say why the app asks, then show the system prompt.
    case explainer
    /// The photos shared with the app, and Apple's screen to share more.
    case sharedPhotos
    /// Full access: the regular picker, whose picks the app can then read.
    case photoPicker
    /// The user said no; only the Settings app can change it.
    case accessDenied
    /// Access can't be granted on this device.
    case accessRestricted

    init(_ access: PhotoAccess) {
        switch access {
        case .notDetermined: self = .explainer
        case .limited: self = .sharedPhotos
        case .full: self = .photoPicker
        case .denied: self = .accessDenied
        case .restricted: self = .accessRestricted
        }
    }
}
