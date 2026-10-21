import UIKit
import UniformTypeIdentifiers

private final class NativeClipboardPasteControl:UIPasteControl {
    var explicitAccessibilityActivation:(()->Void)?
    override func accessibilityActivate()->Bool {
        explicitAccessibilityActivation?()
        return super.accessibilityActivate()
    }
}

private final class ClipboardCandidateTextButton:UIButton {
    private let pressedSurface=UIView()
    override var isHighlighted:Bool {didSet{applyColors()}}
    override init(frame:CGRect) {
        super.init(frame:frame)
        backgroundColor = .clear;isOpaque=false;clipsToBounds=true
        pressedSurface.isUserInteractionEnabled=false;pressedSurface.isOpaque=false
        pressedSurface.layer.cornerRadius=8;pressedSurface.layer.cornerCurve = .continuous
        pressedSurface.clipsToBounds=true;addSubview(pressedSurface);sendSubviewToBack(pressedSurface)
        contentHorizontalAlignment = .leading
        titleLabel?.font = .systemFont(ofSize:20)
        titleLabel?.numberOfLines=1;titleLabel?.lineBreakMode = .byTruncatingTail;titleLabel?.textAlignment = .left
        applyColors()
    }
    private func applyColors() {
        pressedSurface.backgroundColor=isHighlighted ? InputThemeColors.selection:.clear
        setTitleColor(isHighlighted ? InputThemeColors.selectedText:InputThemeColors.text,for:.normal)
    }
    override func layoutSubviews() {
        super.layoutSubviews();pressedSurface.frame=ClipboardCandidateInlineLayout.highlightFrame(in:bounds)
        titleLabel?.frame=ClipboardCandidateInlineLayout.titleContentFrame(in:bounds)
        sendSubviewToBack(pressedSurface)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
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
    private let known=ClipboardCandidateTextButton(frame:.zero)
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
        backgroundColor = .clear;isOpaque=false;clipsToBounds=true
        native.backgroundColor = .clear;native.isOpaque=false;native.clipsToBounds=true
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
        known.addAction(UIAction{[weak self] _ in
            guard let self,let snapshot=self.publication.snapshot else{return}
            self.insertKnown?(snapshot)
        },for:.touchUpInside)
        for control in [native,known] {
            control.addAction(UIAction{[weak self] _ in self?.interactionBegan?()},for:.touchDown)
            addSubview(control)
        }
        show(snapshot:nil)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func layoutSubviews() {
        super.layoutSubviews()
        // Unknown data uses the actual native control, not an invisible proxy.
        // Cache preview uses the same single-row text surface as word candidates.
        let fitting=native.sizeThatFits(.init(width:ClipboardCandidateInlineLayout.nativeMaximumWidth,height:ClipboardCandidateInlineLayout.nativeMaximumHeight))
        native.frame=ClipboardCandidateInlineLayout.nativeFrame(in:bounds,fitting:fitting)
        known.frame=ClipboardCandidateInlineLayout.textFrame(in:bounds)
    }
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
