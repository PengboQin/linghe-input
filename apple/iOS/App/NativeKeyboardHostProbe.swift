#if DEBUG
import SwiftUI
import UIKit

/// Development-only host comparison. Records keyboard geometry, never text.
struct NativeKeyboardHostProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardHostProbeController { KeyboardHostProbeController() }
    func updateUIViewController(_ controller: KeyboardHostProbeController, context: Context) {}
}

final class KeyboardHostProbeController: UIViewController {
    private let field = UITextField()
    private let status = UILabel()
    private var observers: [NSObjectProtocol] = []
    private var endFrame: CGRect?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.borderStyle = .roundedRect; field.placeholder = "输入一些文字"
        field.autocapitalizationType = .none; field.autocorrectionType = .no; field.spellCheckingType = .no
        field.isSecureTextEntry = ProcessInfo.processInfo.environment["PRIVATE_INPUT_PROBE_SECURE_HOST"] == "1"
        field.accessibilityIdentifier = "native-host-field"
        status.numberOfLines = 0; status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.accessibilityIdentifier = "native-host-geometry"
        let done = UIButton(type: .system); done.setTitle("完成", for: .normal)
        done.addAction(UIAction { [weak self] _ in self?.field.resignFirstResponder() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [field, status, done]); stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            field.heightAnchor.constraint(equalToConstant: 44)
        ])
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                self?.endFrame = (notice.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                self?.recordGeometry()
            })
        }
        recordGeometry()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); field.becomeFirstResponder(); recordGeometry()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); recordGeometry() }
    private func recordGeometry() {
        let guide = view.keyboardLayoutGuide.layoutFrame
        let window = view.window
        let viewport = window?.bounds ?? view.bounds
        let windowGuide = view.convert(guide, to: window)
        let intersection = windowGuide.intersection(viewport)
        let guideVisible = !intersection.isNull && intersection.height > (window?.safeAreaInsets.bottom ?? 0) + 1
        let notificationVisible = endFrame.map { frame in
            let local = window?.convert(frame, from: nil) ?? frame
            return local.height > 0 && local.intersects(viewport)
        } ?? false
        let value = "guide_visible=\(guideVisible ? 1 : 0);notification_visible=\(notificationVisible ? 1 : 0);guide_y=\(Int(windowGuide.minY));guide_h=\(Int(guide.height));end_y=\(Int(endFrame?.minY ?? -1));end_h=\(Int(endFrame?.height ?? -1));viewport_h=\(Int(viewport.height));content_h=\(Int(view.bounds.height));first_responder=\(field.isFirstResponder ? 1 : 0);secure_host=\(field.isSecureTextEntry ? 1 : 0)"
        if status.text != value { status.text = value; status.accessibilityValue = value }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
#endif
