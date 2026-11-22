import Foundation
import Observation

/// Owns the Rust shields engine and keeps WebKit's content rule lists in sync with it.
@MainActor
@Observable
final class ShieldsManager {
    @ObservationIgnored let engine: Shields

    init() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("FilterLists").path
        do {
            engine = try Shields.open(stateDir: AppPaths.shieldsDirectory.path, bundledListsDir: bundled)
        } catch {
            fatalError("Cannot open shields state: \(error)")
        }
    }

    func start() {
        // STUB(phase1): compile content rule lists, schedule list updates.
    }
}
