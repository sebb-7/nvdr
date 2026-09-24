import UIKit

/// Tiny clipboard seam so views and models do not scatter UIKit pasteboard calls.
enum AppClipboard {
    @MainActor
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }

    @MainActor
    static var string: String? {
        UIPasteboard.general.string
    }
}
