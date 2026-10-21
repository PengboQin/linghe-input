import UIKit
import UniformTypeIdentifiers

private final class NativeClipboardPasteControl:UIPasteControl {
    var explicitAccessibilityActivation:(()->Void)?
    override func accessibilityActivate()->Bool {
        explicitAccessibilityActivation?()
        return super.accessibilityActivate()
    }
}

/// Unknown clipboard contents stay behind Apple's explicit paste gesture.
/// A preview is supplied only from a previously consented, version-bound cache.
final class ClipboardPasteCandidateView:UIView {
    var providers:(([NSItemProvider],ClipboardCandidateState.Request)->Void)?
    var insertKnown:((ClipboardCandidatePresentation.Snapshot)->Void)?
    var requestForNativePress:(()->ClipboardCandidateState.Request?)?
    var interactionBegan:(()->Void)?
    var isTrackingPaste:Bool {native.isTracking || known.isTracking}
    private let native:NativeClipboardPasteControl
    private let known=UIButton(type:.system)
    private var publication=ClipboardCandidatePresentation()
    private var nativePressSeen=false
    private var nativePressRequest:ClipboardCandidateState.Request?
    override init(frame:CGRect) {
        let configuration=UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerRadius=8
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = InputThemeColors.text
        native=NativeClipboardPasteControl(configuration:configuration)
        super.init(frame:frame)
        pasteConfiguration=UIPasteConfiguration(acceptableTypeIdentifiers:[UTType.utf8PlainText.identifier,UTType.plainText.identifier])
        native.target=self
        native.accessibilityIdentifier="clipboard-paste-candidate"
        native.accessibilityLabel="粘贴剪贴板"
        native.explicitAccessibilityActivation = { [weak self] in
            guard let self else{return}
            self.nativePressSeen=true;self.nativePressRequest=self.requestForNativePress?()
        }
        native.addAction(UIAction{[weak self] _ in
            guard let self else{return}
            self.nativePressSeen=true;self.nativePressRequest=self.requestForNativePress?()
        },for:.touchDown)
        native.addAction(UIAction{[weak self] _ in
            self?.nativePressSeen=true;self?.nativePressRequest=nil
        },for:[.touchCancel,.touchUpOutside])
        known.accessibilityIdentifier="clipboard-text-candidate"
        known.contentHorizontalAlignment = .leading
        known.titleLabel?.font = .systemFont(ofSize:20)
        known.titleLabel?.lineBreakMode = .byTruncatingTail
        known.addAction(UIAction{[weak self] _ in
            guard let self,let snapshot=self.publication.snapshot else{return}
            self.insertKnown?(snapshot)
        },for:.touchUpInside)
        for control in [native,known] {
            control.addAction(UIAction{[weak self] _ in self?.interactionBegan?()},for:.touchDown)
            control.translatesAutoresizingMaskIntoConstraints=false;addSubview(control)
            NSLayoutConstraint.activate([control.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),control.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),control.topAnchor.constraint(equalTo:topAnchor),control.bottomAnchor.constraint(equalTo:bottomAnchor)])
        }
        show(snapshot:nil)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func show(snapshot:ClipboardCandidatePresentation.Snapshot?,request:ClipboardCandidateState.Request?=nil) {
        // A cache arriving between touch-down and touch-up cannot exchange the
        // actual control under the finger. Both controls paste the same copy.
        guard publication.publish(snapshot,request:request,tracking:isTrackingPaste) else{return}
        let preview=snapshot?.preview
        native.isHidden=preview != nil;known.isHidden=preview == nil
        known.setTitle(preview,for:.normal);known.setTitleColor(InputThemeColors.text,for:.normal)
        known.accessibilityLabel=preview.map{"粘贴：\($0)"}
    }
    override func canPaste(_ itemProviders:[NSItemProvider])->Bool {
        itemProviders.count==1 && itemProviders[0].canLoadObject(ofClass:NSString.self)
    }
    override func paste(itemProviders:[NSItemProvider]) {
        // A delayed provider is tied to the original gesture, never to a newer
        // clipboard/document fetched when the permission callback finally runs.
        let request=nativePressSeen ? nativePressRequest:publication.request
        nativePressSeen=false;nativePressRequest=nil
        guard canPaste(itemProviders),let request else{return};providers?(itemProviders,request)
    }
}
