import WebKit

extension WKUserScript {
    /// A script from Resources/Scripts, which the build copies into the app bundle.
    convenience init(bundled name: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in world: WKContentWorld) {
        self.init(source: Self.bundledSource(name), injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly, in: world)
    }

    private static func bundledSource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            fatalError("\(name).js is missing from the app bundle")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Cannot read \(url.path): \(error)")
        }
    }
}
