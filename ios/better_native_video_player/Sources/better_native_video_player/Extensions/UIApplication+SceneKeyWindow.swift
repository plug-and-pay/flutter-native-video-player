import UIKit

extension UIApplication {
    /// The key window, found through the connected window scenes.
    ///
    /// `UIApplication.keyWindow` is deprecated and does not follow the UIScene
    /// life cycle, which apps built with the iOS 27 SDK must adopt. Prefers the
    /// foreground-active scene so a second scene (iPad, external display)
    /// cannot win the lookup.
    var sceneKeyWindow: UIWindow? {
        guard #available(iOS 13.0, *) else {
            return keyWindow
        }

        let windowScenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeWindowScenes = windowScenes.filter { $0.activationState == .foregroundActive }

        for windowScene in activeWindowScenes + windowScenes {
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }

        return windowScenes.first?.windows.first
    }
}
