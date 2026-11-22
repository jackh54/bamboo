import AppKit
import SwiftUI

/// A site icon: the given image (a tab's live favicon), else the cached icon
/// for `host`, else a letter tile for the host or a globe.
struct FaviconView: View {
    var image: NSImage?
    var host: String?
    var size: CGFloat = 16
    @State private var cached: NSImage?

    var body: some View {
        Group {
            if let icon = image ?? cached {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let letter = host.flatMap(Self.monogram) {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Theme.Colors.field)
                    .overlay {
                        Text(letter)
                            .font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.82))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: host) {
            cached = image == nil ? host.flatMap(FaviconLoader.shared.icon(forHost:)) : nil
        }
    }

    private static func monogram(_ host: String) -> String? {
        let name = host.hasPrefix("www.") ? host.dropFirst(4) : Substring(host)
        return name.first.map { String($0).uppercased() }
    }
}
