import UIKit

enum KeyboardAppearanceSync {
    static func apply(to controller: UIViewController, mode: InputTheme.Mode = .system) {
        guard let view = controller.viewIfLoaded else { return }
        // UIKit already resolves the host keyboard appearance. A proxy can return
        // the previous resolved light/dark value while the keyboard is hidden;
        // caching that as an override pins the old colors during the next reveal.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            if controller.overrideUserInterfaceStyle != mode.interfaceStyle { controller.overrideUserInterfaceStyle = mode.interfaceStyle }
            if #available(iOS 17.0, *) { controller.updateTraitsIfNeeded(); view.updateTraitsIfNeeded() }
            view.setNeedsDisplay()
        }
        CATransaction.commit()
    }
}
