import Foundation

/// Text for showing an error to the user. The Rust core's errors need this because
/// UniFFI describes them as a Swift type dump.
func userFacingMessage(_ error: Error) -> String {
    switch error {
    case ShieldsError.Io(let message), ShieldsError.InvalidList(let message), ShieldsError.Engine(let message):
        message
    case ShieldsError.UnknownList(let id):
        "Unknown filter list “\(id)”."
    case StoreError.Database(let message), StoreError.InvalidInput(let message):
        message
    case StoreError.NotFound(let id):
        "“\(id)” no longer exists."
    case ImportError.NotFound(let path):
        "Nothing to import was found at \(path)."
    case ImportError.PermissionDenied(let path, _):
        "macOS didn't allow Bamboo to read \(path)."
    case ImportError.Keychain(let message):
        "The Keychain refused access: \(message)"
    case ImportError.Database(let message), ImportError.Parse(let message), ImportError.Io(let message):
        message
    case ImportError.Decryption(let message):
        "The data couldn't be decrypted: \(message)"
    default:
        error.localizedDescription
    }
}
