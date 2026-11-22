import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.dropFirst().first == ShieldsBuilder.helperArgument {
        ShieldsBuilder.runHelper()
    }
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
