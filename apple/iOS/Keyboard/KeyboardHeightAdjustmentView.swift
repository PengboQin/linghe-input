import UIKit

/// Pure UIKit hit routing for existing scroll surfaces. Coordinates are in
/// `root`; scroll offsets and nested clipping are handled by native conversion.
/// Excluded native controls keep their own point-inside/slop behavior.
enum KeyboardScrollSurfaceRouting {
    static func hit(in scroll: UIScrollView, point: CGPoint, root: UIView, excluding controls: [UIView] = [], event: UIEvent? = nil) -> UIView? {
        guard visible(root), root.bounds.contains(point) else { return nil }
        for control in controls where reachesRoot(control, root: root, point: point) {
            if control.point(inside: control.convert(point, from: root), with: event) { return nil }
        }
        guard reachesRoot(scroll, root: root, point: point) else { return nil }
        let local = scroll.convert(point, from: root)
        guard scroll.bounds.contains(local) else { return nil }
        return scroll.hitTest(local, with: event) ?? scroll
    }
    private static func visible(_ view: UIView) -> Bool { !view.isHidden && view.alpha > 0.01 && view.isUserInteractionEnabled }
    private static func reachesRoot(_ view: UIView, root: UIView, point: CGPoint) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor, current !== root {
            guard visible(current) else { return false }
            if current.clipsToBounds, !current.bounds.contains(current.convert(point, from: root)) { return false }
            ancestor = current.superview
        }
        return ancestor === root
    }
}

final class KeyboardInputView: UIInputView {
    var prepareAppearance: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { prepareAppearance?() }
    }
    var scrollHitTest: ((CGPoint, UIEvent?) -> UIView?)?
    var contentHeight: CGFloat = 280 {
        didSet { if contentHeight != oldValue { invalidateIntrinsicContentSize() } }
    }
    convenience init(contentHeight: CGFloat) {
        self.init(frame:.zero,inputViewStyle:.keyboard)
        self.contentHeight=contentHeight
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: contentHeight) }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let routed = isUserInteractionEnabled && !isHidden && alpha > 0.01 && bounds.contains(point) ? scrollHitTest?(point,event) : nil
        let target = routed ?? super.hitTest(point, with:event)
        #if targetEnvironment(simulator)
        if event?.type == .touches {
            NSLog("CANDIDATE_ROOT_HIT x=%.1f y=%.1f left=%.1f top=%.1f margin=%.1f safe=%.1f target=%@",point.x,point.y,frame.minX,frame.minY,layoutMargins.left,safeAreaInsets.left,target.map{String(describing:type(of:$0))} ?? "nil")
        }
        #endif
        return target
    }
}

// Only visible while adjusting. Horizontal slider and vertical title drag both
// resize the real keyboard; the normal candidate bar returns on Done.
final class KeyboardHeightAdjustmentView: UIView {
    private let title = UILabel()
    private let slider = UISlider()
    private var initialExtra: Double = 0
    private var pendingPreview: Double?
    private var previewWork: DispatchWorkItem?
    private var previewGeneration: UInt64 = 0
    private func preview(_ extra: Double) {
        pendingPreview=extra;title.text="拖动调高 · +\(Int(extra))"
        guard previewWork == nil else {return}
        let generation=previewGeneration
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.previewGeneration==generation else{return};self.previewWork=nil
            guard let value=self.pendingPreview else{return};self.pendingPreview=nil
            self.change?(value,false)
        }
        previewWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+1.0/30,execute:work)
    }
    private func commit(_ extra: Double) {
        previewGeneration &+= 1;previewWork?.cancel();previewWork=nil;pendingPreview=nil
        change?(extra,true)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {previewGeneration &+= 1;previewWork?.cancel();previewWork=nil;pendingPreview=nil}
    }
    var compact = false
    var change: ((Double, Bool) -> Void)?
    var done: (() -> Void)?
    init() {
        super.init(frame: .zero)
        let finish = UIButton(type: .system)
        finish.setTitle("完成", for: .normal); finish.accessibilityIdentifier = "finish-keyboard-height"
        finish.addAction(UIAction { [weak self] _ in self?.done?() }, for: .touchUpInside)
        title.font = .systemFont(ofSize: 13); title.textColor = InputThemeColors.secondary
        title.isUserInteractionEnabled = true; title.accessibilityIdentifier = "drag-keyboard-height"
        title.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        slider.minimumValue = 0; slider.maximumValue = 96; slider.accessibilityLabel = "键盘高度"
        slider.accessibilityIdentifier = "keyboard-height-slider"
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.preview(Double(self.slider.value))
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.commit(Double(self.slider.value))
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        [title, finish, slider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), title.topAnchor.constraint(equalTo: topAnchor),
            title.trailingAnchor.constraint(equalTo: finish.leadingAnchor, constant: -8), title.heightAnchor.constraint(equalToConstant: 28),
            finish.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), finish.topAnchor.constraint(equalTo: topAnchor), finish.widthAnchor.constraint(equalToConstant: 52), finish.heightAnchor.constraint(equalToConstant: 28),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor), slider.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyTheme() { title.textColor = InputThemeColors.secondary; tintColor = InputThemeColors.accent }
    func update(_ extra: Double) {
        slider.value = Float(extra)
        slider.accessibilityValue = "+\(Int(extra))"
        title.text = "拖动调高 · +\(Int(extra))"
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: initialExtra = Double(slider.value)
        case .changed, .ended, .cancelled:
            let delta = Double(gesture.translation(in: window).y) / (compact ? 0.5 : 1)
            let value=min(96,max(0,initialExtra-delta))
            slider.value=Float(value)
            if gesture.state == .changed {preview(value)} else {commit(value)}
        default: break
        }
    }
}
