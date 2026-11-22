import Foundation
import WebKit

/// Builds shields in a short-lived helper process: a copy of Bamboo's own
/// executable started with `helperArgument`. Parsing ~200k filters and compiling
/// WebKit rule lists peaks at several hundred MB, and a long-running browser
/// would keep most of that after the build; a helper hands it back to macOS
/// when it exits. The browser then loads the persisted engine and the compiled
/// lists from `ruleListStore`.
enum ShieldsBuilder {
    static let helperArgument = "--build-shields"

    /// Shared by the helper and the browser, so lists the helper compiles are
    /// found by identifier without recompiling.
    @MainActor static let ruleListStore: WKContentRuleListStore = WKContentRuleListStore(
        url: AppPaths.shieldsDirectory.appendingPathComponent("ContentRuleLists", isDirectory: true))

    static var bundledListsDirectory: String? {
        Bundle.main.resourceURL?.appendingPathComponent("FilterLists").path
    }

    enum BuildError: LocalizedError {
        case helperFailed(status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .helperFailed(let status, let output):
                "The shields builder exited with status \(status)" + (output.isEmpty ? "." : ": \(output)")
            }
        }
    }

    /// Runs the helper and waits for it to finish.
    static func buildInHelper() async throws {
        guard let executable = Bundle.main.executableURL else {
            preconditionFailure("Bamboo has no executable URL")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [helperArgument]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw BuildError.helperFailed(status: status, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The helper's entry point, called from main.swift before any UI starts.
    /// Rebuilds (a no-op when nothing changed), compiles the rule lists and exits.
    @MainActor
    static func runHelper() -> Never {
        Task { @MainActor in
            do {
                let shields = try Shields.open(stateDir: AppPaths.shieldsDirectory.path, bundledListsDir: bundledListsDirectory)
                let build = try shields.rebuild()
                _ = try await ShieldsManager.compile(build.ruleSets, in: ruleListStore)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        // A real run loop, not dispatchMain(): that exits the main thread, freeing the
        // CFRunLoop WebKit's rule list store posts its completion handlers to.
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }
}
