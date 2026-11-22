import Foundation
import Observation

/// A JavaScript `alert`, `confirm` or `prompt` waiting for an answer. Shown
/// inside its tab rather than as a window-modal sheet, so one page can't block
/// the whole window, and agents can answer it.
@MainActor
@Observable
final class JavaScriptDialog: Identifiable {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    struct Response: Sendable {
        var accepted: Bool
        var text: String?
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// Host of the frame that opened the dialog, shown as its title.
    let origin: String
    @ObservationIgnored private var continuation: CheckedContinuation<Response, Never>?

    init(kind: Kind, message: String, origin: String, continuation: CheckedContinuation<Response, Never>) {
        self.kind = kind
        self.message = message
        self.origin = origin
        self.continuation = continuation
    }

    func respond(accepted: Bool, text: String? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: Response(accepted: accepted, text: text))
    }
}
