import UIKit
import PrivateInputKit
import CryptoKit
import OSLog

private struct KeyboardCompositionHost: InlineCompositionHost {
    let proxy: UITextDocumentProxy
    let compositionDocument: UUID?
    var markObserved: ((String) -> Void)?
    var compositionBefore:String? { proxy.documentContextBeforeInput }
    var compositionAfter:String? { proxy.documentContextAfterInput }
    var compositionSelection:String? { proxy.selectedText }
    func markComposition(_ text:String,selection:NSRange) { proxy.setMarkedText(text,selectedRange:selection); markObserved?(text) }
    func unmarkComposition() { proxy.unmarkText() }
}

/// Observe the real initial touch without recognizing a gesture or competing
/// with collection selection, native pans or the system context menu.
private final class CandidateTouchObserver: UIGestureRecognizer {
    var began: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        began?()
        state = .failed
    }
}
private final class CandidateCollectionView: UICollectionView {
    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        let observer = CandidateTouchObserver(target:nil, action:nil)
        observer.cancelsTouchesInView=false
        observer.delaysTouchesBegan=false
        observer.delaysTouchesEnded=false
        observer.began = { [weak self] in self?.interactionBegan?() }
        addGestureRecognizer(observer)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var controlEventGeneration: UInt64 = 0
    private(set) var isHandlingControlEvent = false
    func markControlEvent() {
        controlEventGeneration &+= 1
        let generation=controlEventGeneration
        isHandlingControlEvent=true
        DispatchQueue.main.async { [weak self] in
            guard let self,self.controlEventGeneration==generation else{return}
            self.isHandlingControlEvent=false
        }
    }
    var interactionBegan: (() -> Void)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        #if targetEnvironment(simulator)
        if event?.type == .touches,event?.allTouches?.contains(where:{$0.phase == .began}) == true {
            NSLog("CANDIDATE_TOUCH hit collection=%@ x=%.1f y=%.1f target=%@",accessibilityIdentifier ?? "",point.x,point.y,target.map{String(describing:type(of:$0))} ?? "nil")
        }
        #endif
        if target != nil, event?.type == .touches,
           event?.allTouches?.contains(where: { $0.phase == .began }) == true {
            interactionBegan?()
        }
        return target
    }
    override func touchesShouldCancel(in view: UIView) -> Bool { view is UIControl || super.touchesShouldCancel(in: view) }
    #if targetEnvironment(simulator)
    private var routedHits = 0
    private var panBegins = 0
    private var touchBegins = 0
    private var touchMoves = 0
    override func layoutSubviews() { super.layoutSubviews(); reportScroll() }
    override func didMoveToWindow() { super.didMoveToWindow(); reportScroll() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchBegins += 1; super.touchesBegan(touches, with: event); reportScroll()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchMoves += 1; super.touchesMoved(touches, with: event); reportScroll()
    }
    func reportScroll(routed: Bool = false, began: Bool = false) {
        if routed { routedHits += 1 }; if began { panBegins += 1 }
        guard accessibilityIdentifier == "symbol-items" else { return }
        var hierarchy: [String] = []
        var parent: UIView? = self
        while let current = parent {
            hierarchy.append("\(type(of: current)):hidden=\(current.isHidden),alpha=\(current.alpha),enabled=\(current.isUserInteractionEnabled)")
            if current is UIInputView { break }; parent = current.superview
        }
        let value: [String: Any] = ["marker": "symbol-grid-native-v3", "offset": contentOffset.y, "contentHeight": contentSize.height, "viewportHeight": bounds.height, "scrollEnabled": isScrollEnabled, "delaysContentTouches": delaysContentTouches, "panEnabled": panGestureRecognizer.isEnabled, "panState": panGestureRecognizer.state.rawValue, "routedHits": routedHits, "panBegins": panBegins, "touchBegins": touchBegins, "touchMoves": touchMoves, "dragging": isDragging, "decelerating": isDecelerating, "hierarchy": hierarchy]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), let text = String(data: data, encoding: .utf8) {
            if accessibilityValue != text { accessibilityValue = text }
            let label = "symbol-grid-native-v3 " + text
            if accessibilityLabel != label { accessibilityLabel = label }
        }
    }
    #endif
}

final class KeyboardViewController: UIInputViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private enum Layout { case nine, letters, numbers, symbols }
    private var engine: NativeEngine!
    private var english = false
    private var shift = false
    private var layout: Layout = .nine
    private var panelHistory: [Layout] = []
    private var chineseLayout: Layout = .nine
    private var symbols = KeyboardPreferences.commonSymbols
    private var privacyResetObserver:UUID?
    private var symbolUsage = SymbolUsage()
    private var symbolUsageWritable = true
    private var symbolPageValues = SymbolCatalog.categories[0].symbols
    private var keyboardPresentation:UInt64 = 0
    private var keyboardAppeared = false
    private var learningRefreshPending = false
    private var deferredLearningRefresh:DispatchWorkItem?
    private var learningWorkGeneration:UInt64 = 0
    private var learningRefreshFailures = 0
    private var learningPreparationID:UUID?
    private var learningMaintenance = LearningMaintenanceBoundary()
    private static var learningPresentationFence = LearningPresentationFence()
    private let learningDiagnosticOwner = KeyboardRuntimeDiagnostics.allocateOwner()
    private typealias DecisionTrace = KeyboardDecisionTrace<ActivityArchiveCapture.DiagnosticScope>
    private var decisionTrace: DecisionTrace?
    private var decisionSnapshotIDs = Set<String>()
    private var diagnosticMarkedRequest: (text: String, scope: ActivityArchiveCapture.DiagnosticScope)?
    private var pendingDecisionSelection: DecisionTrace.Selection?
    private var pressedKeyboardControls=Set<ObjectIdentifier>()
    private var builtInputModeSwitchKey:Bool?
    private var syncingAppearance = false
    private var appliedTheme: InputTheme?
    private var appliedAppearance: UIUserInterfaceStyle?
    private var sharedLayout = KeyboardPreferences.chineseLayout
    private var startEnglish = KeyboardPreferences.startInEnglish
    private var lastRemember: Bool?
    private var lastSharedRemember = KeyboardPreferences.rememberWords
    private var expanded = false
    private var candidatePageWork: DispatchWorkItem?
    private var candidatePageGeneration: UInt64 = 0
    private var candidateExpansionFillRemaining = 0
    private var wasChinesePending = false
    private let inlineComposition = InlineComposition()
    private let emptySymbolPair = SymbolPairing.EmptyPairDeletion()
    private var compositionPosition = KeyboardPreferences.compositionPosition
    private var sharedCompositionPosition = UserDefaults.standard.string(forKey:"last-shared-composition-position") ?? KeyboardPreferences.compositionPosition
    private var compositionHost:KeyboardCompositionHost {
        .init(proxy:textDocumentProxy,compositionDocument:documentID,markObserved:{ [weak self] text in
            guard let self, let scope = self.diagnosticScope() else { return }
            self.diagnosticMarkedRequest = (text, scope)
        })
    }
    private var lastRevision = -1
    private var preferenceObserver: NSObjectProtocol?
    private var preferencesPending = false
    private var choices: [InputCandidate] = []
    private struct PublishedCandidateIdentity: Hashable {
        let text: String, reading: String
        let source: String?, partial: String?, remainder: String?, latin: String?
        let personal: UUID?
        init(_ row: InputCandidate) {
            text=row.text; reading=row.comment; source=row.sourceInput
            partial=row.partialCode; remainder=row.pinyinRemainder; latin=row.latinInput; personal=row.personalID
        }
    }
    private var publishedCandidates = StableCandidatePublication<InputCandidate, PublishedCandidateIdentity>()
    // Pagination follows the engine stream, not the number of appended rows:
    // late results can add new rows while keeping the original prefix visible.
    private var candidateSourceOffset = 0
    private var deletionPrediction=DeletionPredictionLatch()
    private var hasMore = false
    private let englishChecker = UITextChecker()
    private var sharedMixedEnglish=UserDefaults.standard.object(forKey:"last-shared-mixed-english") as? Bool ?? KeyboardPreferences.mixedEnglish
    private var englishPrefix = ""
    private var englishDocument: UUID?
    private var cursorActive = false
    private var cursorEditsComposition = false
    private var cursorOrigin: CGFloat = 0
    private var cursorSteps = 0
    private var cursorDocument: UUID?
    private var suppressSpaceUntil: TimeInterval = 0
    private var loading = false
    // Intent survives a touch interrupt; a new revision/presentation clears it.
    private var candidatePageRequested=false
    private let root = UIStackView()
    private let header = UIView()
    private var headerHeight:NSLayoutConstraint!
    private var candidateTop:NSLayoutConstraint!
    private var candidateLeading:NSLayoutConstraint!
    private var letterActionButton:UIButton?
    private let preeditRow = UIView()
    private let preeditScroll = UIScrollView()
    private let composition = UILabel()
    private let fallbackCompositionScroll = UIScrollView()
    private let fallbackCompositionLabel = UILabel()
    private var fallbackCompositionWidth: NSLayoutConstraint!
    private var fallbackCompositionVisible = false
    private var expandTop: NSLayoutConstraint!
    private var gridTop: NSLayoutConstraint!
    private var gridTrailing: NSLayoutConstraint!
    private var preeditTrailing: NSLayoutConstraint!
    private var preeditHeight: NSLayoutConstraint!
    private var footerHeight: NSLayoutConstraint!
    private var expandHeight:NSLayoutConstraint!
    private var geometrySize = CGSize.zero
    private var geometryCompact = false
    private var heightConstraint: NSLayoutConstraint!
    private var heightExtra = KeyboardHeight.defaultExtra
    private var sharedHeightExtra = UserDefaults.standard.object(forKey:"last-shared-height-extra") as? Double ?? KeyboardPreferences.keyboardHeightExtra
    private var sharedHeightRevision = UserDefaults.standard.string(forKey:"last-shared-height-revision")
    private let candidateBar = UIStackView()
    private let clipboardCandidate=ClipboardPasteCandidateView()
    private var clipboardState=ClipboardCandidateState()
    private var clipboardKnown:ClipboardCandidatePresentation.Snapshot?
    private var clipboardLoad=ClipboardCandidateLoadState()
    private var clipboardActivity=ClipboardCandidateActivity()

    private let expand = CandidateExpansionButton(type: .custom)
    private let toolbar = UIStackView()
    private weak var languageButton:UIButton?
    private var menuSignature=""
    private let keys = UIStackView()
    private let keyboardBody = UIStackView()
    private let footer = UIStackView()
    private weak var candidateRetainedActions: UIView?
    private weak var candidateDeleteButton: UIButton?
    private var appliedCandidatePanelExpanded: Bool?
    private var systemWordsLoading=false
    private var systemWords: SupplementaryLexicon?
    private var appliedSystemWords: Bool?
    private weak var returnButton: UIButton?
    private weak var clearButton: UIButton?
    private var learningStatus: String?
    private var predictionTimer:Timer?
    private var predictionTimerRevision = -1
    private var pinyinRankingRevision = -1
    private var predictionPausedRevision = -1
    private var activeDocument:UUID?
    private let archiveSession = UUID().uuidString
    private var archiveEpoch = UUID().uuidString
    private var archiveDocument: String?
    private var archiveTimer: Timer?
    private var clipboardTimer:Timer?
    private var clipboardObservers:[NSObjectProtocol]=[]
    private var ownCommitTracker=OwnCommitCorrectionTracker()
    private let predictionLog=Logger(subsystem:"live.linghe.privateinput",category:"prediction")
    // UIKit's nonoptional Swift accessor can bridge nil before the host proxy
    // attaches. Read the same public ObjC property without forcing the bridge.
    private var documentID:UUID? {
        guard let proxy=textDocumentProxy as? NSObject,proxy.responds(to:NSSelectorFromString("documentIdentifier")) else { return nil }
        return proxy.value(forKey:"documentIdentifier") as? UUID
    }
    private weak var sideScroll: KeyboardRailView?
    private var sideSignature = ""
    private var symbolRailContext=""
    private var symbolRailSnapshot:[String]=[]
    private var symbolCategory = 0
    private weak var categoryScroll: KeyboardRailView?
    private var deleteDelay: Timer?
    private var deleteRepeat: Timer?
    private var deletionGeneration = 0
    private var allSymbols: [String] { symbolPageValues }
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let strongImpact = UIImpactFeedbackGenerator(style: .medium)
    private var feedbackPreference = KeyboardPreferences.keyFeedback
    private let quickSymbols = ["、", "；", "：", "…", "—", "（", "）", "《", "》", "“", "”", "@", "#"]
    private lazy var strip = collection(horizontal: true)
    private lazy var grid: UICollectionView = {
        let result=collection(horizontal:false), layout=CandidateListLayout()
        layout.textAt = { [weak self] index in guard let self,self.choices.indices.contains(index) else { return "" };return self.choices[index].text }
        result.setCollectionViewLayout(layout,animated:false);return result
    }()
    private lazy var symbolGrid = collection(horizontal: false)
    #if DEBUG
    private var permissionProbe: SharedSnapshotProbe?
    #endif
    private func collection(horizontal: Bool) -> UICollectionView {
        let flow = UICollectionViewFlowLayout(); flow.scrollDirection = horizontal ? .horizontal : .vertical
        flow.minimumLineSpacing = 0; flow.minimumInteritemSpacing = 0
        // A consistent inset keeps the pressed rounded surface clear of the
        // outer edge in both collapsed and expanded candidate presentations.
        flow.sectionInset = UIEdgeInsets(top:0,left:6,bottom:0,right:6)
        let result = CandidateCollectionView(frame: .zero, collectionViewLayout: flow)
        // Keep a continuous, nearly transparent material surface. On the
        // keyboard host a fully clear collection can lose touches in cell
        // padding before UIKit delivers them to its native controls.
        result.backgroundColor = InputThemeColors.rail.withAlphaComponent(0.02); result.isOpaque=false; result.dataSource = self; result.delegate = self
        result.interactionBegan = { [weak self] in self?.pauseCandidateRankingForInteraction() }
        result.showsHorizontalScrollIndicator = false; result.showsVerticalScrollIndicator = !horizontal
        result.register(CandidateCell.self, forCellWithReuseIdentifier: "candidate")
        result.contentInsetAdjustmentBehavior = .never; result.clipsToBounds = true; clearEdges(result, horizontal: horizontal)
        return result
    }
    private func clearEdges(_ scroll: UIScrollView, horizontal: Bool = false) {
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        scroll.alwaysBounceHorizontal = horizontal
        scroll.alwaysBounceVertical = !horizontal
        scroll.decelerationRate = .fast
        if #available(iOS 26.0, *) {
            scroll.topEdgeEffect.isHidden = true; scroll.bottomEdgeEffect.isHidden = true
            scroll.leftEdgeEffect.isHidden = true; scroll.rightEdgeEffect.isHidden = true
        }
    }
    override func loadView() {
        Self.learningPresentationFence.advance()
        KeyboardRuntimeDiagnostics.record(.loadViewBegin, [.owner: Double(learningDiagnosticOwner)])
        heightExtra=KeyboardHeight.normalized(UserDefaults.standard.object(forKey:"local-height-extra") as? Double ?? KeyboardPreferences.keyboardHeightExtra)
        let keyboard=KeyboardInputView(contentHeight:desiredKeyboardHeight(width:UIScreen.main.bounds.width))
        // The host asks for intrinsic size during first presentation, before
        // engine startup and before viewDidLayoutSubviews can correct it.
        keyboard.isOpaque=false;keyboard.backgroundColor = .clear;keyboard.clipsToBounds=true
        // Scroll surfaces own their complete visible rectangles before the
        // keyboard's nearby button hit regions. Shared/hidden layers never route
        // touches into the keyboard underneath; footer and header controls retain
        // their normal native hit testing outside these exact collection bounds.
        keyboard.scrollHitTest = { [weak self] point,event in
            guard let self else { return nil }
            if self.expanded { return self.scrollSurfaceHit(self.grid, point: point, event: event, excluding: [self.expand, self.footer] + (self.candidateDeleteButton.map { [$0] } ?? [])) }
            let controls: [UIView] = [self.expand, self.footer]
            if let hit = self.scrollSurfaceHit(self.strip, point: point, event: event, excluding: controls) { return hit }
            if self.layout == .symbols,
               let hit = self.scrollSurfaceHit(self.symbolGrid, point: point, event: event, excluding: controls) { return hit }
            if let rail = self.sideScroll ?? self.categoryScroll {
                return self.scrollSurfaceHit(rail, point: point, event: event, excluding: controls)
            }
            return nil
        }
        keyboard.prepareAppearance = { [weak self] in self?.synchronizeAppearance() }
        view=keyboard;inputView=keyboard
        KeyboardRuntimeDiagnostics.record(.loadViewEnd, [.owner: Double(learningDiagnosticOwner)])
    }
    private func scrollSurfaceHit(_ scroll: UIScrollView, point: CGPoint, event: UIEvent?, excluding controls: [UIView] = []) -> UIView? {
        guard let hit = KeyboardScrollSurfaceRouting.hit(in: scroll, point: point, root: view, excluding: controls, event: event) else { return nil }
        #if targetEnvironment(simulator)
        (scroll as? KeyboardRailView)?.recordHit(scroll.convert(point, from: view))
        (scroll as? CandidateCollectionView)?.reportScroll(routed: true)
        #endif
        return hit
    }
    override func viewDidLoad() {
        KeyboardRuntimeDiagnostics.record(.viewLoadBegin, [.owner: Double(learningDiagnosticOwner)])
        super.viewDidLoad()
        loadSymbolUsage()
        privacyResetObserver=PersonalDataReset.observe {[weak self] in
            guard let self else {return}
            self.symbolUsage=SymbolUsage();self.symbolUsageWritable=true
            UserDefaults.standard.removeObject(forKey:"symbol-usage-v1")
            self.refreshSymbolPage();self.symbolGrid.reloadData()
        }
        let checker=englishChecker
        KeyboardRuntimeDiagnostics.record(.engineCreateBegin, [.owner: Double(learningDiagnosticOwner)])
        engine = NativeEngine(retainPredictionProbe: true,mixedEnglishProvider: { prefix in
            guard UITextChecker.availableLanguages.contains("en_US") else { return [] }
            let range=NSRange(location:0,length:prefix.utf16.count)
            var words:[String]=[]
            if checker.rangeOfMisspelledWord(in:prefix,range:range,startingAt:0,wrap:false,language:"en_US").location==NSNotFound { words.append(prefix) }
            words += checker.completions(forPartialWordRange:range,in:prefix,language:"en_US") ?? []
            words += checker.guesses(forWordRange:range,in:prefix,language:"en_US") ?? []
            return words
        })
        KeyboardRuntimeDiagnostics.record(.engineCreateEnd, [.ready: engine.ready ? 1 : 0, .owner: Double(learningDiagnosticOwner)])
        KeyboardPreferences.observeUpdates()
        preferenceObserver = NotificationCenter.default.addObserver(forName: KeyboardPreferences.updated, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.synchronizeAppearance(); self.preferencesPending = true; self.applyPreferences()
        }
        inputView?.allowsSelfSizing = true
        heightExtra = KeyboardHeight.normalized(UserDefaults.standard.object(forKey:"local-height-extra") as? Double ?? KeyboardPreferences.keyboardHeightExtra)
        heightConstraint = view.heightAnchor.constraint(equalToConstant: (inputView as? KeyboardInputView)?.contentHeight ?? desiredKeyboardHeight(width:UIScreen.main.bounds.width))
        heightConstraint.priority = .init(999); heightConstraint.isActive = true
        view.backgroundColor = .clear;view.isOpaque=false
        root.axis = .vertical; root.spacing = 0; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4), root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)])
        header.translatesAutoresizingMaskIntoConstraints=false;header.accessibilityIdentifier="keyboard-header";root.addArrangedSubview(header)
        headerHeight=header.heightAnchor.constraint(equalToConstant:KeyboardCandidatePanelGeometry.headerHeight(inline: compositionPosition == "inline"));headerHeight.isActive=true
        preeditRow.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(preeditRow)
        NSLayoutConstraint.activate([preeditRow.topAnchor.constraint(equalTo:header.topAnchor),preeditRow.leadingAnchor.constraint(equalTo:header.leadingAnchor),preeditRow.trailingAnchor.constraint(equalTo:header.trailingAnchor)])
        preeditHeight = preeditRow.heightAnchor.constraint(equalToConstant: 20); preeditHeight.priority = .init(999);preeditHeight.isActive = true
        preeditScroll.translatesAutoresizingMaskIntoConstraints = false; preeditScroll.showsHorizontalScrollIndicator = false; clearEdges(preeditScroll, horizontal: true)
        composition.font = .systemFont(ofSize: 14); composition.textColor = InputThemeColors.secondary
        composition.accessibilityIdentifier = "composition-preedit"
        composition.translatesAutoresizingMaskIntoConstraints = false; preeditScroll.addSubview(composition)
        preeditRow.addSubview(preeditScroll)
        preeditTrailing = preeditScroll.trailingAnchor.constraint(equalTo: preeditRow.trailingAnchor)
        NSLayoutConstraint.activate([preeditScroll.leadingAnchor.constraint(equalTo: preeditRow.leadingAnchor, constant: 6), preeditScroll.topAnchor.constraint(equalTo: preeditRow.topAnchor), preeditScroll.bottomAnchor.constraint(equalTo: preeditRow.bottomAnchor), preeditTrailing, composition.leadingAnchor.constraint(equalTo: preeditScroll.contentLayoutGuide.leadingAnchor), composition.trailingAnchor.constraint(equalTo: preeditScroll.contentLayoutGuide.trailingAnchor), composition.topAnchor.constraint(equalTo: preeditScroll.contentLayoutGuide.topAnchor), composition.bottomAnchor.constraint(equalTo: preeditScroll.contentLayoutGuide.bottomAnchor), composition.heightAnchor.constraint(equalTo: preeditScroll.frameLayoutGuide.heightAnchor)])
        candidateBar.axis = .horizontal; candidateBar.spacing = 0
        candidateBar.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(candidateBar)
        candidateTop=candidateBar.topAnchor.constraint(equalTo:header.topAnchor)
        candidateLeading=candidateBar.leadingAnchor.constraint(equalTo:header.leadingAnchor)
        NSLayoutConstraint.activate([candidateTop,candidateBar.bottomAnchor.constraint(equalTo:header.bottomAnchor),candidateLeading,candidateBar.trailingAnchor.constraint(equalTo:header.trailingAnchor)])
        fallbackCompositionScroll.translatesAutoresizingMaskIntoConstraints=false;fallbackCompositionScroll.showsHorizontalScrollIndicator=false
        clearEdges(fallbackCompositionScroll,horizontal:true)
        fallbackCompositionLabel.translatesAutoresizingMaskIntoConstraints=false;fallbackCompositionLabel.font = .systemFont(ofSize:14)
        fallbackCompositionLabel.accessibilityIdentifier="inline-fallback-preedit"
        fallbackCompositionScroll.addSubview(fallbackCompositionLabel);header.addSubview(fallbackCompositionScroll)
        fallbackCompositionWidth=fallbackCompositionScroll.widthAnchor.constraint(equalToConstant:104)
        NSLayoutConstraint.activate([fallbackCompositionScroll.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:6),fallbackCompositionScroll.topAnchor.constraint(equalTo:header.topAnchor),fallbackCompositionScroll.bottomAnchor.constraint(equalTo:header.bottomAnchor),fallbackCompositionWidth,
            fallbackCompositionLabel.leadingAnchor.constraint(equalTo:fallbackCompositionScroll.contentLayoutGuide.leadingAnchor),fallbackCompositionLabel.trailingAnchor.constraint(equalTo:fallbackCompositionScroll.contentLayoutGuide.trailingAnchor),fallbackCompositionLabel.topAnchor.constraint(equalTo:fallbackCompositionScroll.contentLayoutGuide.topAnchor),fallbackCompositionLabel.bottomAnchor.constraint(equalTo:fallbackCompositionScroll.contentLayoutGuide.bottomAnchor),fallbackCompositionLabel.heightAnchor.constraint(equalTo:fallbackCompositionScroll.frameLayoutGuide.heightAnchor)])
        fallbackCompositionScroll.isHidden=true
        strip.accessibilityIdentifier = "candidate-strip"; grid.accessibilityIdentifier = "candidate-list"
        candidateBar.addArrangedSubview(strip)
        expand.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expand.addTarget(self, action: #selector(pauseCandidateRankingForInteraction), for: .touchDown)
        expand.accessibilityIdentifier = "expand-candidates"; expand.accessibilityLabel = "展开全部候选"
        expand.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setCandidatesExpanded(!self.expanded)
        }, for: .touchUpInside)
        expand.addAction(UIAction { [weak self] _ in self?.resumeCandidatePageAfterInteraction() }, for:[.touchUpInside,.touchUpOutside,.touchCancel])
        let reserve = UIView(); reserve.widthAnchor.constraint(equalToConstant: CandidateExpansionButton.touchWidth).isActive = true
        candidateBar.addArrangedSubview(reserve)
        expand.translatesAutoresizingMaskIntoConstraints = false; expand.tintColor = InputThemeColors.accent
        var expandStyle=UIButton.Configuration.plain()
        expandStyle.contentInsets = .zero
        expandStyle.baseForegroundColor = InputThemeColors.accent
        expandStyle.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize:18,weight:.semibold)
        expand.configuration=expandStyle
        expand.configurationUpdateHandler = { button in
            var style=button.configuration
            style?.baseForegroundColor = button.isHighlighted ? InputThemeColors.selectedText : InputThemeColors.accent
            style?.background.backgroundColor=button.isHighlighted ? InputThemeColors.selection:.clear
            style?.background.cornerRadius=6
            button.configuration=style
        }
        view.addSubview(expand); expandTop = expand.topAnchor.constraint(equalTo: root.topAnchor)
        expandHeight=expand.heightAnchor.constraint(equalToConstant:60)
        NSLayoutConstraint.activate([expandTop, expand.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor), expand.widthAnchor.constraint(equalToConstant: CandidateExpansionButton.touchWidth), expandHeight])
        toolbar.tintColor = InputThemeColors.accent; toolbar.axis = .horizontal; toolbar.spacing = 12
        toolbar.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(toolbar)
        NSLayoutConstraint.activate([toolbar.leadingAnchor.constraint(equalTo:header.leadingAnchor),toolbar.trailingAnchor.constraint(equalTo:header.trailingAnchor),toolbar.topAnchor.constraint(equalTo:header.topAnchor),toolbar.bottomAnchor.constraint(equalTo:header.bottomAnchor)])
        toolbar.alignment = .center
        clipboardCandidate.translatesAutoresizingMaskIntoConstraints=false;candidateBar.insertArrangedSubview(clipboardCandidate,at:0)
        clipboardCandidate.isHidden=true
        clipboardCandidate.interactionBegan = { [weak self] in self?.cancelLearningForInteraction() }
        clipboardCandidate.requestForNativePress = { [weak self] in self?.clipboardRequest() }
        clipboardCandidate.providers = { [weak self] providers,request in self?.pasteClipboardProviders(providers,request:request) }
        clipboardCandidate.insertKnown = { [weak self] snapshot in
            guard let self,snapshot.permitsPresentation(readPaused:UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"automatic-clipboard-read-paused")==true) else{return}
            self.insertClipboardText(snapshot.text,request:snapshot.request)
        }

        // Keep the normal keyboard in Auto Layout while the candidate list
        // covers it. Removing it lets UIKit self-fit an almost zero-height
        // collection view, turning a swipe into a candidate tap.
        grid.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(grid)
        gridTop=grid.topAnchor.constraint(equalTo:root.topAnchor)
        gridTrailing=grid.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-(CandidateExpansionButton.touchWidth+4))
        NSLayoutConstraint.activate([gridTop,grid.leadingAnchor.constraint(equalTo:root.leadingAnchor),gridTrailing])
        keys.axis = .horizontal; keys.spacing = 4; keys.distribution = .fill
        keyboardBody.axis = .vertical; keyboardBody.spacing = 4; keyboardBody.accessibilityIdentifier = "keyboard-body"
        footer.axis = .horizontal; footer.spacing = 4; footerHeight=footer.heightAnchor.constraint(equalToConstant:44);footerHeight.priority = .init(999);footerHeight.isActive=true
        keyboardBody.addArrangedSubview(keys); keyboardBody.addArrangedSubview(footer); root.addArrangedSubview(keyboardBody)
        grid.bottomAnchor.constraint(equalTo:footer.topAnchor,constant:-4).isActive=true
        chineseLayout = configuredChineseLayout()
        english = startEnglish; layout = english ? .letters : chineseLayout
        _ = engine.nineKey(!english && chineseLayout == .nine); _ = engine.switchToEnglish(english)
        synchronizeAppearance();updateKeyboardGeometry(); buildKeys(); render()
        if KeyboardPreferences.systemLexicon { loadSystemWords() }
        KeyboardRuntimeDiagnostics.record(.viewLoadEnd, [.ready: engine.ready ? 1 : 0, .owner: Double(learningDiagnosticOwner)])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardGeometry()
    }
    private func desiredKeyboardHeight(width: CGFloat) -> CGFloat {
        let compact=traitCollection.verticalSizeClass == .compact || (traitCollection.userInterfaceIdiom == .phone && width>500)
        let screen=viewIfLoaded?.window?.screen.bounds.size ?? UIScreen.main.bounds.size
        let viewport=compact ? min(screen.width,screen.height):max(screen.width,screen.height)
        return CGFloat(KeyboardHeight.height(extra:heightExtra,compact:compact,tablet:traitCollection.userInterfaceIdiom == .pad,viewportHeight:Double(viewport)))+(compact ? 12:4)
    }
    private func updateKeyboardGeometry() {
        guard heightConstraint != nil else { return }
        let compact = traitCollection.verticalSizeClass == .compact || (traitCollection.userInterfaceIdiom == .phone && view.bounds.width > 500)
        let desired=desiredKeyboardHeight(width:view.bounds.width)
        if heightConstraint.constant != desired {
            heightConstraint.constant = desired
            (inputView as? KeyboardInputView)?.contentHeight = desired
            preferredContentSize = CGSize(width:view.bounds.width,height:desired)
        }
        let changed = geometrySize.width != view.bounds.width || geometryCompact != compact
        geometrySize=view.bounds.size;geometryCompact=compact
        let footer=(compact ? 32.0:44.0)+CGFloat(heightExtra)/(compact ? 8:4)
        if footerHeight?.constant != footer {footerHeight?.constant=footer}
        let header = KeyboardCandidatePanelGeometry.headerHeight(inline: compositionPosition == "inline")
        if headerHeight?.constant != header {headerHeight?.constant=header}
        let preedit = KeyboardCandidatePanelGeometry.preeditHeight
        if preeditHeight?.constant != preedit {preeditHeight?.constant=preedit}
        if candidateTop != nil { updateHeaderFrames() }
        if changed { [strip,grid,symbolGrid].forEach{$0.collectionViewLayout.invalidateLayout()} }
    }
    private func configureHeight(_ value:Double,persist:Bool=false) {
        // The App owns height settings; the keyboard only applies a snapshot.
        let normalized=KeyboardHeight.normalized(value)
        guard heightExtra != normalized else{return}
        heightExtra=normalized;updateKeyboardGeometry();view.setNeedsLayout()
    }
    private func updateHeaderFrames() {
        let top = KeyboardCandidatePanelGeometry.candidateTop(inline: compositionPosition == "inline")
        candidateTop.constant=top;expandTop.constant=top;gridTop.constant=top
        let header = KeyboardCandidatePanelGeometry.headerHeight(inline: compositionPosition == "inline")
        if headerHeight.constant != header { headerHeight.constant=header }
        expandHeight.constant=KeyboardCandidatePanelGeometry.candidateHeight
        (grid.collectionViewLayout as? CandidateListLayout)?.controlHeight=0
        let deleteFrame=candidateDeleteButton.map { $0.convert($0.bounds,to:root) }
        let reserve=KeyboardCandidatePanelGeometry.trailingReserve(width:root.bounds.width,deleteFrame:deleteFrame)
        if abs(gridTrailing.constant + reserve)>0.5 {gridTrailing.constant = -reserve}
    }
    private func loadSystemWords() {
        guard !systemWordsLoading,KeyboardPreferences.systemLexicon else { return };systemWordsLoading=true
        requestSupplementaryLexicon { [weak self] lexicon in
            // No system-provided strings enter disk, logs, or sync snapshots.
            let pairs=lexicon.entries.prefix(4096).map{(input:$0.userInput,text:$0.documentText)}
            DispatchQueue.global(qos:.utility).async {
                let words=SupplementaryLexicon(pairs:pairs)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.systemWordsLoading=false;self.systemWords=KeyboardPreferences.systemLexicon ? words:nil;self.appliedSystemWords=nil;self.applySystemWords()
                    self.render()
                }
            }
        }
    }
    private func applySystemWords() {
        guard engine.preedit.isEmpty else { return }
        let enabled=KeyboardPreferences.systemLexicon
        if !enabled { systemWords=nil }
        guard appliedSystemWords != enabled else { return }
        if enabled,systemWords==nil { return }
        if engine.setSupplementaryLexicon(enabled ? (systemWords ?? SupplementaryLexicon(pairs:[])):SupplementaryLexicon(pairs:[])) { appliedSystemWords=enabled }
    }
    override func viewWillAppear(_ animated: Bool) {
        Self.learningPresentationFence.advance()
        emptySymbolPair.invalidate()
        KeyboardRuntimeDiagnostics.record(.viewWillAppear, [.owner: Double(learningDiagnosticOwner)])
        super.viewWillAppear(animated);learningMaintenance.willAppear();cancelLearningForInteraction();keyboardPresentation &+= 1;keyboardAppeared=false;learningRefreshPending=true;learningRefreshFailures=0;pressedKeyboardControls.removeAll();synchronizeAppearance();applyPreferences()
        archiveEpoch = UUID().uuidString
        ActivityArchiveCapture.shared.refresh(permitted: hasFullAccess, force: true)
        if layout == .symbols { refreshSymbolPage();symbolGrid.reloadData() }
        if builtInputModeSwitchKey != needsInputModeSwitchKey { buildKeys() }
        loadSystemWords()
        #if DEBUG
        permissionProbe = SharedSnapshotProbe.runInKeyboard(fullAccess: hasFullAccess)
        composition.accessibilityIdentifier = "group-permission-probe"
        #endif
    }
    override func viewDidAppear(_ animated:Bool) {
        KeyboardRuntimeDiagnostics.record(.viewDidAppear, [.owner: Double(learningDiagnosticOwner)])
        super.viewDidAppear(animated);keyboardAppeared=true;refreshAutomaticClipboard()
        engine.stageCachedCloudLearningBootstrap(publish: learningPublisher)
        clipboardTimer?.invalidate()
        let clipboardTick=Timer(timeInterval:1,repeats:true) { [weak self] _ in
            guard let self,self.keyboardAppeared,self.viewIfLoaded?.window != nil else{return}
            self.refreshAutomaticClipboard()
            self.engine.stageCachedCloudLearningBootstrap(publish: self.learningPublisher)
        }
        clipboardTimer=clipboardTick;RunLoop.main.add(clipboardTick,forMode:.common)
        for observer in clipboardObservers {NotificationCenter.default.removeObserver(observer)};clipboardObservers=[]
        for name in [Notification.Name.clipboardLiveUpdated,UIPasteboard.changedNotification] {
            clipboardObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                guard let self,self.keyboardAppeared,self.viewIfLoaded?.window != nil else{return}
                self.refreshAutomaticClipboard()
            })
        }
        archiveTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self,self.keyboardAppeared,self.viewIfLoaded?.window != nil else { return }
            ActivityArchiveCapture.shared.refresh(permitted: self.hasFullAccess)
            if self.hasFullAccess,self.textDocumentProxy.isSecureTextEntry == false { ActivityArchiveCapture.shared.observeClipboardIfPermitted() };self.refreshAutomaticClipboard()
        }
        archiveTimer = timer; RunLoop.main.add(timer, forMode: .common)
        if engine.candidateBatchWasDeferred {requestCandidatePage()}
    }
    private func refreshAutomaticClipboard() {
        guard keyboardAppeared,viewIfLoaded?.window != nil else{return}
        refreshClipboardCandidateCache()
        ClipboardCacheCoordinator.automaticKeyboardPass(fullAccess:hasFullAccess,
            sensitive:textDocumentProxy.isSecureTextEntry != false,validating:{ [weak self] in
                guard let self else {return false}
                return self.keyboardAppeared && self.viewIfLoaded?.window != nil && self.hasFullAccess && self.textDocumentProxy.isSecureTextEntry == false
            })
    }
    // Metadata inspection cannot trigger Paste permission. Clipboard bodies are
    // read only by UIPasteControl's explicit user action or the existing opted-in
    // automatic cache, never by this candidate's reveal/render path.
    private var clipboardHasPrimary:Bool {engine == nil || !engine.preedit.isEmpty || (english && !englishWord().isEmpty)}
    private var clipboardPresentationIdle:Bool {
        clipboardActivity.mayPresent(at:Date.timeIntervalSinceReferenceDate,hasComposition:clipboardHasPrimary,
            hasInteraction:!pressedKeyboardControls.isEmpty || expanded || expand.isTracking || deleteDelay != nil || deleteRepeat != nil ||
            strip.isTracking || grid.isTracking || strip.isDragging || grid.isDragging || strip.isDecelerating || grid.isDecelerating)
    }
    private func observeClipboardVersion(_ version:Int) {
        clipboardState.observe(version:version,automaticEligible:clipboardPresentationIdle)
    }
    private func noteClipboardInput() {
        clipboardActivity.noteInput(at:Date.timeIntervalSinceReferenceDate)
        clipboardState.observe(version:UIPasteboard.general.changeCount);clipboardState.dismiss()
        clipboardKnown=nil;clipboardLoad.cancel()
    }
    private var clipboardScope:String {
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        return [prefs?.string(forKey:"automatic-clipboard-scope") ?? "",
                prefs?.string(forKey:"clipboard-group-id") ?? "",
                String(prefs?.bool(forKey:"clipboard-sharing-enabled") == true),
                String(prefs?.bool(forKey:"automatic-clipboard-enabled") == true)].joined(separator:"|")
    }
    private var clipboardCacheFingerprint:String {
        let p=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        return [p?.string(forKey:"automatic-clipboard-cache-generation") ?? "",
                p?.string(forKey:"clipboard-live-cache-generation") ?? "",
                p?.string(forKey:"clipboard-preview-generation") ?? "",
                String(p?.bool(forKey:"automatic-clipboard-read-paused")==true)].joined(separator:"|")
    }
    private var clipboardAllowed:Bool {
        guard keyboardAppeared,viewIfLoaded?.window != nil,hasFullAccess,documentID != nil,
              textDocumentProxy.isSecureTextEntry == false,!expanded else{return false}
        let board=UIPasteboard.general
        return board.numberOfItems==1 && board.hasStrings
    }
    private func clipboardRequest()->ClipboardCandidateState.Request? {
        guard let document=documentID else{return nil}
        return .init(version:UIPasteboard.general.changeCount,document:document,presentation:keyboardPresentation,
                     deletion:deletionPrediction.generation,scope:clipboardScope)
    }
    private func acceptsClipboard(_ request:ClipboardCandidateState.Request)->Bool {
        clipboardState.accepts(request,current:clipboardRequest(),allowed:clipboardAllowed,
                               hasPrimary:clipboardHasPrimary,deleting:!clipboardPresentationIdle)
    }
    private func updateClipboardCandidateVisibility() {
        let version=UIPasteboard.general.changeCount
        observeClipboardVersion(version)
        if let known=clipboardKnown,(!acceptsClipboard(known.request) || !known.permitsPresentation(readPaused:UserDefaults(suiteName:LocalLearningCoordinator.groupID)?.bool(forKey:"automatic-clipboard-read-paused")==true)) {clipboardKnown=nil}
        let visible=clipboardKnown != nil && clipboardState.available(version:version,allowed:clipboardAllowed,
                    hasPrimary:clipboardHasPrimary,deleting:!clipboardPresentationIdle)
        let wasVisible = !clipboardCandidate.isHidden
        // A sync arrival may wait one idle tick; it must not remove the
        // continuation cell or control currently held by the user.
        if visible,!wasVisible,(!pressedKeyboardControls.isEmpty || strip.isTracking || grid.isTracking || expand.isTracking) {return}
        clipboardCandidate.isHidden = !visible
        strip.isHidden=visible
        guard visible else {
            if wasVisible {
                let pending = !engine.preedit.isEmpty || !choices.isEmpty
                preeditRow.isHidden=engine.preedit.isEmpty || inlineComposition.active
                candidateBar.isHidden = !pending
                toolbar.isHidden=pending
                expand.isHidden = !pending || choices.isEmpty
            }
            return
        }
        clipboardCandidate.show(snapshot:clipboardKnown,request:clipboardRequest())
        preeditRow.isHidden=true;candidateBar.isHidden=false;toolbar.isHidden=true;expand.isHidden=true
    }
    private func refreshClipboardCandidateCache() {
        let version=UIPasteboard.general.changeCount
        observeClipboardVersion(version)
        if clipboardLoad.observe(version:version,scope:clipboardScope,generation:clipboardCacheFingerprint) {
            clipboardKnown=nil
        }
        updateClipboardCandidateVisibility()
        guard let request=clipboardRequest(),acceptsClipboard(request),clipboardKnown==nil,
              ClipboardCacheCoordinator.permitted(fullAccess:hasFullAccess) else{return}
        let p=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard p?.bool(forKey:"automatic-clipboard-enabled")==true,
              let scope=p?.string(forKey:"automatic-clipboard-scope"),!scope.isEmpty,
              let ticket=clipboardLoad.begin(request:request,eligible:true) else{return}
        let generation=AppleClipboardOnce.generation
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result=SharedClipboardCandidateReader.read(scope:scope,version:version,now:UInt64(Date().timeIntervalSince1970),generation:generation)
            DispatchQueue.main.async { [weak self] in
                guard let self,self.clipboardLoad.finish(ticket),self.acceptsClipboard(request),AppleClipboardOnce.generation==generation else{return}
                switch result {
                case .text(let text,let source):
                    guard ClipboardCandidateState.validText(text) else{return}
                    self.clipboardKnown = .init(request:request,text:text,receivedSystemWrite:source == .receivedWrite)
                case .consumed:self.clipboardState.dismiss();self.clipboardKnown=nil
                case .unavailable:return
                }
                self.updateClipboardCandidateVisibility()
            }
        }
    }
    private func pasteClipboardProviders(_ providers:[NSItemProvider],request:ClipboardCandidateState.Request) {
        guard providers.count==1,acceptsClipboard(request),
              providers[0].canLoadObject(ofClass:NSString.self) else{return}
        // UIKit invokes this only after the native Paste control grants access.
        providers[0].loadObject(ofClass:NSString.self) { [weak self] value,_ in
            DispatchQueue.main.async { [weak self] in
                guard let self,self.acceptsClipboard(request) else{return}
                guard let text=value as? String,ClipboardCandidateState.validText(text) else {
                    self.clipboardState.dismiss();self.clipboardKnown=nil;self.updateClipboardCandidateVisibility();return
                }
                self.insertClipboardText(text,request:request)
            }
        }
    }
    private func insertClipboardText(_ text:String,request:ClipboardCandidateState.Request) {
        emptySymbolPair.invalidate()
        guard acceptsClipboard(request),ClipboardCandidateState.validText(text) else{return}
        clipboardState.dismiss();clipboardKnown=nil;clipboardLoad.cancel()
        resumeAutomaticPredictionForUserInput();cancelPrediction();cancelCandidatePage()
        ownCommitTracker.invalidate();engine.resetPredictionContext()
        // Preview compaction never changes the exact inserted text.
        textDocumentProxy.insertText(text);archiveOutput(text,systemPaste:true)
        expanded=false;publishedCandidates.reset();lastRevision = -1;render()
    }
    private func cancelLearningForInteraction() {
        if deferredLearningRefresh != nil || learningPreparationID != nil {
            KeyboardRuntimeDiagnostics.record(.checkpointSkipped,
                KeyboardRuntimeDiagnostics.maintenanceMetrics(owner: learningDiagnosticOwner,
                    stage: .lifecycleCancellation, failure: .busy))
        }
        learningWorkGeneration &+= 1;deferredLearningRefresh?.cancel();deferredLearningRefresh=nil;learningPreparationID=nil
    }
    private func permitsHiddenLearning(_ token:UInt64) -> Bool {
        learningMaintenance.permits(token,hasComposition:engine == nil || !engine.rawInput.isEmpty || !engine.preedit.isEmpty,
            interacting:keyboardAppeared || !pressedKeyboardControls.isEmpty || expand.isTracking || clipboardCandidate.isTrackingPaste)
    }
    private func scheduleHiddenLearningRefresh(_ token:UInt64) {
        guard permitsHiddenLearning(token),learningRefreshPending,learningRefreshFailures<3,deferredLearningRefresh == nil,learningPreparationID == nil,engine != nil,engine.ready else{return}
        let presentation=keyboardPresentation,generation=learningWorkGeneration
        KeyboardRuntimeDiagnostics.record(.checkpointScheduled, [.owner: Double(learningDiagnosticOwner)])
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.learningWorkGeneration==generation,self.keyboardPresentation==presentation else{return}
            self.deferredLearningRefresh=nil
            guard self.learningRefreshPending,self.permitsHiddenLearning(token) else{return}
            self.prepareHiddenLearningRefresh(token:token,presentation:presentation,generation:generation)
        }
        // Best effort after dismissal, not an entitlement to background time.
        // Suspension leaves the native local learner intact for a later hide.
        deferredLearningRefresh=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:work)
    }
    private func prepareHiddenLearningRefresh(token:UInt64,presentation:UInt64,generation:UInt64) {
        guard learningRefreshPending, permitsHiddenLearning(token), keyboardPresentation == presentation,
              learningWorkGeneration == generation else { return }
        KeyboardRuntimeDiagnostics.record(.checkpointPreflight, KeyboardRuntimeDiagnostics.maintenanceMetrics(owner: learningDiagnosticOwner, stage: .controllerPreflight))
        let started=ProcessInfo.processInfo.systemUptime
        let identifier=UUID();learningPreparationID=identifier
        engine.prepareLearningRefresh(publish:learningPublisher) { [weak self] preparation in
            guard let self,self.learningPreparationID==identifier else{return}
            self.learningPreparationID=nil
            var endMetrics=KeyboardRuntimeDiagnostics.maintenanceMetrics(owner:self.learningDiagnosticOwner,stage:.controllerPreflight)
            endMetrics[.elapsedMilliseconds]=(ProcessInfo.processInfo.systemUptime-started)*1000
            KeyboardRuntimeDiagnostics.record(.checkpointPreflightEnd,endMetrics)
            var blocked:UInt64=0
            if self.keyboardPresentation != presentation {blocked |= 1}
            if self.learningWorkGeneration != generation {blocked |= 2}
            if !self.learningRefreshPending {blocked |= 4}
            if !self.permitsHiddenLearning(token) {blocked |= 8}
            // Presentation-only candidate/proxy revisions are not native
            // mutations. The engine validates its separate learning generation.
            if blocked==0 {blocked=self.engine.learningRefreshInvalidationReason(preparation,publish:self.learningPublisher)}
            if blocked != 0 {
                var metrics=KeyboardRuntimeDiagnostics.maintenanceMetrics(owner:self.learningDiagnosticOwner,stage:.sourceValidation,failure:.busy)
                metrics[.validationReasons]=Double(blocked)
                KeyboardRuntimeDiagnostics.record(.checkpointSkipped,metrics)
                return
            }
            self.refreshLearning(explicit:false,preparation:preparation,hiddenToken:token)
        }
    }
    private func synchronizeAppearance() {
        guard isViewLoaded, !syncingAppearance else { return }
        syncingAppearance = true; defer { syncingAppearance = false }
        let theme = KeyboardPreferences.appearanceTheme
        InputThemeColors.refresh(theme)
        KeyboardAppearanceSync.apply(to:self,mode:theme.mode)
        guard theme != appliedTheme || appliedAppearance != traitCollection.userInterfaceStyle else { return }
        appliedTheme = theme; appliedAppearance = traitCollection.userInterfaceStyle
        UIView.performWithoutAnimation {
            // UIInputViewStyle.keyboard owns the plate and its system corners.
            // An opaque inner rectangle would protrude beyond that curved edge.
            root.backgroundColor = .clear
            for collection in [strip,grid,symbolGrid] {
                collection.backgroundColor = InputThemeColors.rail.withAlphaComponent(0.02)
            }
            view.tintColor = InputThemeColors.accent
            composition.textColor = InputThemeColors.secondary
            fallbackCompositionLabel.textColor = InputThemeColors.secondary
            toolbar.tintColor = InputThemeColors.accent
            for label in toolbar.arrangedSubviews.compactMap({ $0 as? UILabel }) { label.textColor = InputThemeColors.secondary }
            var style = expand.configuration
            style?.baseForegroundColor = InputThemeColors.accent
            expand.configuration = style; expand.tintColor = InputThemeColors.accent
            expand.setNeedsUpdateConfiguration()
            applyKeyTheme(in: keys); applyKeyTheme(in: footer)
            sideScroll?.applyTheme(); categoryScroll?.applyTheme()
            for collection in [strip,grid,symbolGrid] {
                for cell in collection.visibleCells.compactMap({ $0 as? CandidateCell }) {
                    cell.applyTheme()
                }
            }
        }
    }
    private func applyKeyTheme(in container: UIView) {
        if let key = container as? FeedbackButton { key.applyTheme() }
        for child in container.subviews { applyKeyTheme(in: child) }
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews();synchronizeAppearance()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo:traitCollection) != false { synchronizeAppearance() }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            [strip,grid].forEach {$0.collectionViewLayout.invalidateLayout();$0.reloadData()}
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        KeyboardRuntimeDiagnostics.record(.viewWillDisappear, [.owner: Double(learningDiagnosticOwner)])
        defer { super.viewWillDisappear(animated) }
        // A repeated UIKit callback is not a second teardown. In particular it
        // must not cancel work queued by the completed didDisappear callback.
        guard learningMaintenance.willDisappear() else { return }
        emptySymbolPair.invalidate()
        cancelDiagnosticComposition(reason: "keyboard_disappeared")
        cancelLearningForInteraction()
        dismissCandidateMenus()
        archiveTimer?.invalidate(); archiveTimer = nil
        clipboardTimer?.invalidate();clipboardTimer=nil
        for observer in clipboardObservers {NotificationCenter.default.removeObserver(observer)};clipboardObservers=[]
        ActivityArchiveCapture.shared.suspendNetwork()
        keyboardPresentation &+= 1;keyboardAppeared=false;deferredLearningRefresh?.cancel();deferredLearningRefresh=nil
        clipboardLoad.leavePresentation();clipboardKnown=nil;clipboardCandidate.isHidden=true
        ClipboardCacheCoordinator.automaticKeyboardPass(fullAccess:false,sensitive:true,validating:{false})
        #if targetEnvironment(simulator)
        if inlineComposition.active { NSLog("INLINE_END disappearing draft=%d",inlineComposition.draft.utf16.count) }
        #endif
        if inlineComposition.active { inlineComposition.leave(host:compositionHost);engine.clear();expanded=false }
        cancelCandidatePage();cancelPrediction();ownCommitTracker.invalidate();engine.resetPredictionContext();cursorActive = false; keys.alpha = 1; stopDeletion()
    }
    override func viewDidDisappear(_ animated:Bool) {
        KeyboardRuntimeDiagnostics.record(.viewDidDisappear, [.owner: Double(learningDiagnosticOwner)])
        super.viewDidDisappear(animated)
        pressedKeyboardControls.removeAll()
        if let token=learningMaintenance.didDisappear() {scheduleHiddenLearningRefresh(token)}
    }
    private func configuredChineseLayout() -> Layout {
        let shared = KeyboardPreferences.chineseLayout
        if shared != sharedLayout { UserDefaults.standard.removeObject(forKey: "local-chinese-layout"); sharedLayout = shared }
        return (UserDefaults.standard.string(forKey: "local-chinese-layout") ?? shared) == "pinyin26" ? .letters : .nine
    }
    private func applyPreferences() {
        guard engine != nil, engine.preedit.isEmpty else { return }
        preferencesPending = false
        let sharedHeight=KeyboardPreferences.keyboardHeightExtra
        let heightRevision=KeyboardPreferences.keyboardHeightRevision
        if sharedHeight != sharedHeightExtra || heightRevision != sharedHeightRevision {
            UserDefaults.standard.removeObject(forKey:"local-height-extra");sharedHeightExtra=sharedHeight;sharedHeightRevision=heightRevision
        }
        if UserDefaults.standard.object(forKey:"last-shared-height-extra") as? Double != sharedHeight {UserDefaults.standard.set(sharedHeight,forKey:"last-shared-height-extra")}
        if UserDefaults.standard.string(forKey:"last-shared-height-revision") != heightRevision {UserDefaults.standard.set(heightRevision,forKey:"last-shared-height-revision")}
        configureHeight(UserDefaults.standard.object(forKey:"local-height-extra") as? Double ?? sharedHeight,persist:false)
        applySystemWords()
        if KeyboardPreferences.systemLexicon,systemWords==nil { loadSystemWords() }
        feedbackPreference = KeyboardPreferences.keyFeedback
        if hasFullAccess { UserDefaults.standard.removeObject(forKey: "local-key-feedback") }
        var changed = false
        let sharedMixed=KeyboardPreferences.mixedEnglish
        if sharedMixed != sharedMixedEnglish { UserDefaults.standard.removeObject(forKey:"local-mixed-english");sharedMixedEnglish=sharedMixed }
        UserDefaults.standard.set(sharedMixed,forKey:"last-shared-mixed-english")
        let desiredMixed=UserDefaults.standard.object(forKey:"local-mixed-english") as? Bool ?? sharedMixed
        if engine.setMixedEnglishEnabled(desiredMixed) { changed=true }
        let position=KeyboardPreferences.compositionPosition
        if position != sharedCompositionPosition { UserDefaults.standard.removeObject(forKey:"local-composition-position");sharedCompositionPosition=position }
        UserDefaults.standard.set(position,forKey:"last-shared-composition-position")
        let desiredPosition=UserDefaults.standard.string(forKey:"local-composition-position") ?? position
        if desiredPosition != compositionPosition { compositionPosition=desiredPosition;changed=true }
        let preferred = configuredChineseLayout()
        if preferred != chineseLayout { chineseLayout = preferred; if !english { layout = preferred; _ = engine.nineKey(preferred == .nine) }; changed = true }
        let initialEnglish = KeyboardPreferences.startInEnglish
        if initialEnglish != startEnglish { startEnglish = initialEnglish; setLanguage(initialEnglish); changed = true }
        let sharedRemember = KeyboardPreferences.rememberWords
        if sharedRemember != lastSharedRemember { UserDefaults.standard.removeObject(forKey: "local-remember"); lastSharedRemember = sharedRemember }
        let remember = UserDefaults.standard.object(forKey: "local-remember") as? Bool ?? sharedRemember
        if remember != lastRemember { _ = engine.privacy(!remember); lastRemember = remember; changed = true }
        let preferredSymbols = KeyboardPreferences.commonSymbols
        if symbols != preferredSymbols { symbols = preferredSymbols; changed = true }
        if changed { buildKeys(); render() }
    }
    private func configureChinese(_ value: Layout) {
        guard engine.preedit.isEmpty else { return }
        let name = value == .nine ? "nine" : "pinyin26"
        if hasFullAccess { KeyboardPreferences.chineseLayout = name; sharedLayout = name; UserDefaults.standard.removeObject(forKey: "local-chinese-layout") }
        else { UserDefaults.standard.set(name, forKey: "local-chinese-layout") }
        chineseLayout = value; setLanguage(false); buildKeys(); render()
    }
    private func refreshSettingsMenus() {
        let signature="\(chineseLayout)|\(compositionPosition)|\(engine.mixedEnglishEnabled)|\(lastRemember ?? true)|\(currentFeedback)|\(heightExtra)|\(hasFullAccess)"
        guard menuSignature != signature || languageButton?.menu==nil else { return }
        menuSignature=signature
        languageButton?.menu=settingsMenu()
    }
    private func settingsMenu() -> UIMenu {
        let layouts = [UIAction(title: "中文九宫格", state: chineseLayout == .nine ? .on : .off) { [weak self] _ in self?.configureChinese(.nine) }, UIAction(title: "中文26键", state: chineseLayout == .letters ? .on : .off) { [weak self] _ in self?.configureChinese(.letters) }]
        let remember = UIAction(title: "学习常用词", state: lastRemember == false ? .off : .on) { [weak self] _ in
            guard let self, self.engine.preedit.isEmpty else { return }
            let next = self.lastRemember == false
            if self.hasFullAccess { KeyboardPreferences.rememberWords = next; self.lastSharedRemember = next; UserDefaults.standard.removeObject(forKey: "local-remember") }
            else { UserDefaults.standard.set(next, forKey: "local-remember") }
            self.lastRemember = next; _ = self.engine.privacy(!next); self.render()
        }
        let refresh = UIAction(title: "刷新词库", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.refreshLearning(explicit: true) }
        let mixed=UIAction(title:"中英混输",state:engine.mixedEnglishEnabled ? .on:.off) { [weak self] _ in
            guard let self,self.engine.preedit.isEmpty else { return }
            let next = !self.engine.mixedEnglishEnabled
            if self.hasFullAccess {
                KeyboardPreferences.mixedEnglish=next;self.sharedMixedEnglish=next
                UserDefaults.standard.set(next,forKey:"last-shared-mixed-english");UserDefaults.standard.removeObject(forKey:"local-mixed-english")
            } else { UserDefaults.standard.set(next,forKey:"local-mixed-english") }
            _ = self.engine.setMixedEnglishEnabled(next);self.render()
        }
        let feedback = [("off", "关闭"), ("light", "轻"), ("strong", "强")].map { value in
            UIAction(title: value.1, state: currentFeedback == value.0 ? .on : .off) { [weak self] _ in
                guard let self else { return }
                if self.hasFullAccess { KeyboardPreferences.keyFeedback = value.0; self.feedbackPreference = value.0; UserDefaults.standard.removeObject(forKey: "local-key-feedback") }
                else { UserDefaults.standard.set(value.0, forKey: "local-key-feedback") }
            }
        }
        let positions=[("keyboard","拼音在键盘内"),("inline","拼音在文本框内")].map { value in
            UIAction(title:value.1,state:compositionPosition==value.0 ? .on:.off) { [weak self] _ in
                guard let self,self.engine.preedit.isEmpty else { return }
                if self.hasFullAccess { KeyboardPreferences.compositionPosition=value.0;self.sharedCompositionPosition=value.0;UserDefaults.standard.removeObject(forKey:"local-composition-position") }
                else { UserDefaults.standard.set(value.0,forKey:"local-composition-position") }
                self.compositionPosition=value.0;self.render()
            }
        }
        let access=UIAction(title:hasFullAccess ? "完全访问已开启":"完全访问未开启",image:UIImage(systemName:hasFullAccess ? "checkmark.shield":"shield"),attributes:.disabled) {_ in}
        let permissionHelp=UIMenu(title:"权限说明",children:[
            UIAction(title:"基础打字与本机纠错可用",attributes:.disabled) {_ in},
            UIAction(title:"共享设置和文本需完全访问",attributes:.disabled) {_ in},
            UIAction(title:"在主 App 查看开启方法",attributes:.disabled) {_ in},
            UIAction(title:"返回键盘") { [weak self] _ in self?.render() }
        ])
        return UIMenu(children: [UIMenu(title:"权限",children:[access,permissionHelp]),UIMenu(title:"布局与显示",children:layouts+[UIMenu(title:"拼音显示位置",children:positions)]), UIMenu(title:"词库与联想",children:[mixed,remember,refresh]), UIMenu(title:"按键触感",children:feedback)])
    }
    private var currentFeedback: String { UserDefaults.standard.string(forKey: "local-key-feedback") ?? feedbackPreference }
    private func pressFeedback(_ key: FeedbackButton, pressed: Bool) {
        guard pressed else { return }
        if currentFeedback == "strong" { strongImpact.impactOccurred(intensity: 0.8) }
        else if currentFeedback == "light" { lightImpact.impactOccurred(intensity: 0.5) }
    }

    private func button(_ title: String, activation:UIControl.Event = .touchUpInside, action: @escaping () -> Void) -> UIButton {
        let b = FeedbackButton(type: .system); b.setTitle(title, for: .normal); b.titleLabel?.font = .systemFont(ofSize: 20)
        b.applyTheme(); b.layer.cornerRadius = 4
        b.feedback = { [weak self] key,pressed in
            guard let self else{return}
            if pressed {self.pressedKeyboardControls.insert(ObjectIdentifier(key));self.cancelLearningForInteraction()}
            else {self.pressedKeyboardControls.remove(ObjectIdentifier(key));self.resumeCandidatePageAfterInteraction()}
            self.pressFeedback(key,pressed:pressed)
        }
        b.accessibilityIdentifier = "key-" + title; if activation == .touchDown { b.accessibilityAction=action };b.addAction(UIAction { _ in action() }, for: activation); return b
    }
    private func stack(_ axis: NSLayoutConstraint.Axis = .horizontal) -> UIStackView {
        let s = UIStackView(); s.axis = axis; s.spacing = 4; s.distribution = .fillEqually; return s
    }
    private func buildKeys() {
        builtInputModeSwitchKey=needsInputModeSwitchKey
        stopDeletion()
        for v in keys.arrangedSubviews { keys.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in footer.arrangedSubviews { footer.removeArrangedSubview(v); v.removeFromSuperview() }
        letterActionButton=nil;clearButton=nil
        candidateRetainedActions=nil;candidateDeleteButton=nil;appliedCandidatePanelExpanded=nil
        sideScroll = nil; sideSignature = "";symbolRailContext=""
        categoryScroll = nil
        if layout == .nine || layout == .numbers {
            let rail=KeyboardRailView();rail.widthAnchor.constraint(equalToConstant:48).isActive=true
            rail.accessibilityIdentifier="quick-symbols"
            rail.press = { [weak self] in self?.railPressFeedback() }
            sideScroll=rail;keys.addArrangedSubview(rail)
        } else if layout == .symbols {
            let rail=KeyboardRailView();rail.widthAnchor.constraint(equalToConstant:48).isActive=true
            rail.accessibilityIdentifier="symbol-categories"
            rail.press = { [weak self] in self?.railPressFeedback() }
            rail.select = { [weak self] index in self?.selectSymbolCategory(index) }
            categoryScroll=rail;keys.addArrangedSubview(rail);updateCategoryRail()
        }
        let center = UIStackView(); center.axis = .vertical; center.spacing = 4; center.distribution = .fill; keys.addArrangedSubview(center)
        let area = stack(.vertical); center.addArrangedSubview(area)
        if layout == .symbols {
            area.distribution = .fill; area.backgroundColor = .clear
            area.accessibilityIdentifier = "symbol-content-region"
            symbolGrid.accessibilityIdentifier = "symbol-items"
            // Like the symbol rail, a native drag must get a chance to cancel
            // symbol-cell selection before the keyboard handles a nearby key.
            symbolGrid.delaysContentTouches = true; symbolGrid.canCancelContentTouches = true
            area.addArrangedSubview(symbolGrid)
        }
        else if layout == .letters { buildLetterRows(in:area) }
        else {
            let rows: [[String]]
            switch layout {
            case .nine: rows = [["分词", "ABC", "DEF"], ["GHI", "JKL", "MNO"], ["PQRS", "TUV", "WXYZ"]]
            case .numbers: rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]
            default: rows = [Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init), Array("zxcvbnm").map(String.init)]
            }
            for (r, titles) in rows.enumerated() {
                let line = stack(); area.addArrangedSubview(line)
                if layout == .letters && english && r == 2 { line.addArrangedSubview(button("⇧") { [weak self] in self?.shift.toggle(); self?.buildKeys() }) }
                for (c, item) in titles.enumerated() {
                    let digit = String(r * 3 + c + 1), title = shift && english ? item.uppercased() : item
                    let key = button(title,activation:.touchDown) { [weak self] in
                        guard let self else { return }
                        if self.layout == .numbers { self.insertLiteral(digit) }
                        else if self.layout == .nine { if digit != "1" { self.type(digit) } else if !self.engine.preedit.isEmpty { self.type("'") } }
                        else { self.type(title) }
                    }
                    if layout == .nine { key.accessibilityIdentifier = "nine-" + digit }
                    if layout == .numbers { key.accessibilityIdentifier = "number-" + digit }
                    line.addArrangedSubview(key)
                }
            }
        }
        let bottom = footer
        let symbol = button(layout == .symbols ? "返回" : "符") { [weak self] in self?.togglePanel(.symbols) }
        symbol.accessibilityIdentifier = layout == .symbols ? "return-symbols" : "key-符"
        symbol.accessibilityLabel = layout == .symbols ? "返回上一个键盘" : "符号"
        symbol.widthAnchor.constraint(equalToConstant: 48).isActive = true; symbol.titleLabel?.font = .systemFont(ofSize: 16); bottom.addArrangedSubview(symbol)
        let digits = button(layout == .numbers ? "返回" : "123") { [weak self] in self?.togglePanel(.numbers) }
        digits.accessibilityIdentifier = layout == .numbers ? "return-numbers" : "key-123"
        digits.accessibilityLabel = layout == .numbers ? "返回上一个键盘" : "数字"
        digits.titleLabel?.font = .systemFont(ofSize: 16)
        let aligned = stack(); aligned.accessibilityIdentifier = "footer-main-columns"; bottom.addArrangedSubview(aligned)
        let numberSlot = stack(); numberSlot.addArrangedSubview(digits); aligned.addArrangedSubview(numberSlot)
        let languageSlot = stack(); aligned.addArrangedSubview(languageSlot)
        if needsInputModeSwitchKey {
            let globe = button("🌐") {}; globe.accessibilityIdentifier = "switch-system-keyboard"; globe.accessibilityLabel = "切换键盘"
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents); languageSlot.addArrangedSubview(globe)
        }
        let language = button(english ? "英" : "中") { [weak self] in guard let self else { return }; self.setLanguage(!self.english); self.buildKeys(); self.render() }; language.menu=settingsMenu();languageSlot.addArrangedSubview(language);languageButton=language
        let space = button(layout == .numbers ? "0" : "空格") { [weak self] in
            guard let self, !self.cursorActive, Date.timeIntervalSinceReferenceDate > self.suppressSpaceUntil else { return }
            if self.layout == .numbers { self.insertLiteral("0") }
            else if !self.english && !self.engine.preedit.isEmpty && !self.choices.isEmpty { self.choose(self.choices[0], method: "space") }
            else { self.type(" ") }
        }; space.titleLabel?.font = .systemFont(ofSize: 16); space.setContentHuggingPriority(.defaultLow, for: .horizontal); aligned.insertArrangedSubview(space, at: 1)
        if layout != .numbers {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
            gesture.minimumPressDuration = 0.35; gesture.allowableMovement = 14; gesture.cancelsTouchesInView = true
            space.addGestureRecognizer(gesture); space.accessibilityHint = "按住后左右滑动移动光标"
        }
        if layout == .letters {
            let action=button("清空") { [weak self] in
                self?.clearCurrentSuggestions()
            }
            action.titleLabel?.font = .systemFont(ofSize:15)
            action.menu=UIMenu(children:[UIAction(title:"收起键盘",image:UIImage(systemName:"keyboard.chevron.compact.down")) { [weak self] _ in self?.dismissKeyboard() }])
            letterActionButton=action;numberSlot.addArrangedSubview(action)
        } else {
        let right = UIStackView(); right.axis = .vertical; right.spacing = 4; right.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let actions = stack(.vertical)
        let delete = button("⌫") {}; delete.accessibilityLabel = "删除"; delete.accessibilityHint = "按住连续删除"
        candidateDeleteButton=delete;candidateRetainedActions=right
        (delete as? FeedbackButton)?.accessibilityAction = { [weak self] in self?.stopDeletion(); self?.backspace() }
        delete.addAction(UIAction { [weak self] _ in self?.startDeletion() }, for: .touchDown)
        delete.addAction(UIAction { [weak self] _ in self?.stopDeletion() }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        actions.addArrangedSubview(delete)
        let clear = button("清空") { [weak self] in self?.clearCurrentSuggestions() }; clear.titleLabel?.font = .systemFont(ofSize: 15); clear.accessibilityIdentifier = "clear-composition"; clear.accessibilityHint = "清除待选拼音并暂停联想，不删除正文"; clearButton = clear; actions.addArrangedSubview(clear)
        let hide = button("⌄") { [weak self] in self?.stopDeletion(); self?.dismissKeyboard() }; hide.setTitle(nil, for: .normal); hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal); hide.accessibilityLabel = "收起键盘"; hide.accessibilityIdentifier = "hide-keyboard"; actions.addArrangedSubview(hide)
        right.addArrangedSubview(actions)
            keys.addArrangedSubview(right)
        }
        let enter = button(returnTitle) { [weak self] in self?.insertLiteral("\n") }; enter.titleLabel?.font = .systemFont(ofSize: 15); enter.accessibilityIdentifier = "return-key"; returnButton = enter; enter.widthAnchor.constraint(equalToConstant: 48).isActive = true; bottom.addArrangedSubview(enter)
        updateSideRail()
        applyExpandedKeyboardControls()
    }
    private func buildLetterRows(in area:UIStackView) {
        let rows=[Array("qwertyuiop"),Array("asdfghjkl"),Array("zxcvbnm")]
        var unit:UIButton?
        for (index,row) in rows.enumerated() {
            let line=stack();line.distribution = .fill;line.accessibilityIdentifier="letter-row-\(index)";area.addArrangedSubview(line)
            if index==1,let unit {
                let spacer=UIView();spacer.isUserInteractionEnabled=false;line.addArrangedSubview(spacer)
                spacer.widthAnchor.constraint(equalTo:unit.widthAnchor,multiplier:0.5,constant:-2).isActive=true
            }
            if index==2,let unit {
                let leading=button(english ? "⇧":"分词") { [weak self] in
                    guard let self else { return }
                    if self.english { self.shift.toggle();self.buildKeys() } else if !self.engine.preedit.isEmpty { self.type("'") }
                }
                leading.titleLabel?.font = .systemFont(ofSize:16);line.addArrangedSubview(leading)
                leading.widthAnchor.constraint(equalTo:unit.widthAnchor,multiplier:1.5,constant:2).isActive=true
            }
            for letter in row {
                let title=shift && english ? String(letter).uppercased():String(letter)
                let key=button(title,activation:.touchDown) { [weak self] in self?.type(title) };line.addArrangedSubview(key)
                if let unit { key.widthAnchor.constraint(equalTo:unit.widthAnchor).isActive=true } else { unit=key }
            }
            if index==1,let unit {
                let spacer=UIView();spacer.isUserInteractionEnabled=false;line.addArrangedSubview(spacer)
                spacer.widthAnchor.constraint(equalTo:unit.widthAnchor,multiplier:0.5,constant:-2).isActive=true
            }
            if index==2,let unit {
                let delete=button("⌫") {};delete.accessibilityLabel="删除";delete.accessibilityHint="按住连续删除"
                candidateDeleteButton=delete
                (delete as? FeedbackButton)?.accessibilityAction = { [weak self] in self?.stopDeletion();self?.backspace() }
                delete.addAction(UIAction { [weak self] _ in self?.startDeletion() },for:.touchDown)
                delete.addAction(UIAction { [weak self] _ in self?.stopDeletion() },for:[.touchUpInside,.touchUpOutside,.touchCancel,.touchDragExit])
                line.addArrangedSubview(delete);delete.widthAnchor.constraint(equalTo:unit.widthAnchor,multiplier:1.5,constant:2).isActive=true
            }
        }
    }
    private func railPressFeedback() {
        if currentFeedback == "strong" { strongImpact.impactOccurred(intensity:0.8) }
        else if currentFeedback == "light" { lightImpact.impactOccurred(intensity:0.5) }
    }
    private func selectSymbolCategory(_ index:Int) {
        guard SymbolCatalog.categories.indices.contains(index) else { return }
        symbolCategory=index;refreshSymbolPage();symbolGrid.reloadData();symbolGrid.setContentOffset(.zero,animated:false);updateCategoryRail()
    }
    private func loadSymbolUsage() {
        guard let data=UserDefaults.standard.data(forKey:"symbol-usage-v1") else { return }
        do {
            guard data.count<=32768 else { throw InputDataError.oversized }
            let value=try JSONDecoder().decode(SymbolUsage.self,from:data);try value.validate();symbolUsage=value
        } catch { symbolUsageWritable=false }
    }
    private func refreshSymbolPage() {
        let category=SymbolCatalog.categories[symbolCategory]
        let remember=lastRemember ?? KeyboardPreferences.rememberWords
        symbolPageValues = category.id == "common" ? (remember ? symbolUsage:SymbolUsage()).ordered(seed:symbols+category.symbols,catalog:SymbolCatalog.categories.flatMap(\.symbols)) : category.symbols
    }
    private func insertSymbol(_ text:String) {
        if symbolUsageWritable,lastRemember ?? KeyboardPreferences.rememberWords {
            symbolUsage.record(text,allowed:Set(SymbolCatalog.categories.flatMap(\.symbols)+symbols+SymbolCatalog.numericRail))
            if let data=try? JSONEncoder().encode(symbolUsage),data.count<=32768 { UserDefaults.standard.set(data,forKey:"symbol-usage-v1") }
        }
        // Keep the displayed page stable until the next entry/category choice.
        let plan = SymbolPairing.plan(for: text, autoPair: KeyboardPreferences.autoPairSymbols, caretInside: KeyboardPreferences.caretInsidePairs)
        insertLiteral(plan.insertedText, caretBack: plan.caretBack, pairOpening: text)
    }
    private func updateCategoryRail() {
        categoryScroll?.update(SymbolCatalog.categories.enumerated().map { index,category in .init(id:"symbol-category-"+category.id,title:category.title,selected:index==symbolCategory) },height:44,font:14,reset:false)
    }
    private func updateSideRail() {
        guard let rail=sideScroll else { return }
        let readings = layout == .nine && !engine.preedit.isEmpty ? engine.nineSyllables : []
        let filtering = layout == .nine && !engine.preedit.isEmpty && (!readings.isEmpty || engine.canUndoNineSyllable)
        let context=filtering ? "pinyin":(layout == .numbers ? "numbers":"nine")
        if !filtering,(symbolRailContext != context || symbolRailSnapshot.isEmpty) {
            let remember=lastRemember ?? KeyboardPreferences.rememberWords
            let catalog=layout == .numbers ? SymbolCatalog.numericRail:SymbolCatalog.categories.flatMap(\.symbols)
            let seed=layout == .numbers ? SymbolCatalog.numericRail:symbols+quickSymbols
            symbolRailSnapshot=(remember ? symbolUsage:SymbolUsage()).ordered(seed:seed,catalog:catalog)
        }
        symbolRailContext=context
        let values=filtering ? readings:symbolRailSnapshot
        let revision=engine.revision
        // Refresh the action even when the same spellings stay on screen; a
        // held touch uses its captured action and cannot filter a newer draft.
        rail.select = { [weak self] index in
            guard let self,values.indices.contains(index) else { return }
            if filtering {
                guard self.engine.revision==revision else{return}
                self.resumeAutomaticPredictionForUserInput();_ = self.engine.selectNineSyllable(index);self.render()
            } else { self.insertSymbol(values[index]) }
        }
        let signature = String(filtering) + String(engine.canUndoNineSyllable) + values.joined(separator:"|")
        guard signature != sideSignature else { return };sideSignature=signature
        rail.accessibilityIdentifier=filtering ? "pinyin-filter":"quick-symbols"
        rail.update(values.map { .init(id:(filtering ? "pinyin-":"symbol-")+$0,title:$0) },height:filtering ? 44:32,font:filtering ? 15:19,glyphCentered:!filtering)
    }
    private var learningPublisher: SnapshotPublisher? {
        hasFullAccess && UserDefaults(suiteName: LocalLearningCoordinator.groupID)?.bool(forKey: "learning-sharing-enabled") == true ? .keyboard(fullAccess: hasFullAccess) : nil
    }
    private func manageCandidate(_ candidate: InputCandidate, revision: Int, pinned: Bool?) {
        guard engine.revision == revision, !english else { return }
        do { try engine.manage(candidate, pinned: pinned);learningRefreshPending=true;learningRefreshFailures=0;render() }
        catch { learningStatus = "候选设置失败，可重试" }
    }
    private func englishWord() -> String {
        guard english, layout == .letters, textDocumentProxy.selectedText == nil,
              textDocumentProxy.autocorrectionType != .no,
              ![UIKeyboardType.URL, .emailAddress, .numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad].contains(textDocumentProxy.keyboardType ?? .default),
              let before = textDocumentProxy.documentContextBeforeInput else { return "" }
        let tail = String(before.suffix(64)), word = String(tail.reversed().prefix { $0.isASCII && $0.isLetter }.reversed())
        guard word.count >= 2, word.count <= 48 else { return "" }
        // A cursor inside a word is not a prefix replacement opportunity.
        if let next = textDocumentProxy.documentContextAfterInput?.first, next.isASCII && next.isLetter { return "" }
        return word
    }
    private func refreshEnglishChoices() {
        if deletionPrediction.suppressed {
            englishPrefix="";englishDocument=documentID;lastRevision=engine.revision
            if !choices.isEmpty {choices=[];strip.reloadData();grid.reloadData()};hasMore=false;return
        }
        let prefix = englishWord(), document = documentID
        guard prefix != englishPrefix || document != englishDocument || lastRevision != engine.revision else { return }
        englishPrefix = prefix; englishDocument = document; lastRevision = engine.revision; hasMore = false
        let range = NSRange(location: 0, length: prefix.utf16.count)
        let completions=prefix.isEmpty ? []:(englishChecker.completions(forPartialWordRange:range,in:prefix.lowercased(),language:"en_US") ?? [])
        let guesses=prefix.count>=3 ? (englishChecker.guesses(forWordRange:range,in:prefix.lowercased(),language:"en_US") ?? []):[]
        choices=EnglishWordSuggestions.suggestions(prefix:prefix,completions:completions,guesses:guesses).enumerated().map { index,word in
            InputCandidate(text:word,comment:prefix,index:index)
        }
        loading = true; strip.collectionViewLayout.invalidateLayout();grid.collectionViewLayout.invalidateLayout();strip.reloadData(); grid.reloadData(); strip.setContentOffset(.zero, animated: false); grid.setContentOffset(.zero, animated: false); loading = false
    }
    @objc private func moveCursor(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            emptySymbolPair.invalidate()
            cancelPrediction();ownCommitTracker.invalidate();engine.resetPredictionContext()
            cursorEditsComposition = !engine.preedit.isEmpty
            cursorActive = true; cursorOrigin = gesture.location(in: view).x; cursorSteps = 0; cursorDocument = documentID
            keys.alpha = 0.65
        case .changed:
            guard cursorActive, cursorDocument == documentID else { return }
            let steps = Int((gesture.location(in: view).x - cursorOrigin) / 9)
            let delta = steps - cursorSteps
            if delta != 0 {
                if cursorEditsComposition {
                    for _ in 0..<min(abs(delta), 64) { _ = engine.key(delta < 0 ? 0xff51 : 0xff53) }
                    render()
                } else { textDocumentProxy.adjustTextPosition(byCharacterOffset: delta) }
                cursorSteps = steps
            }
        case .ended, .cancelled, .failed:
            cursorActive = false; suppressSpaceUntil = Date.timeIntervalSinceReferenceDate + 0.15; keys.alpha = 1; render()
        default: break
        }
    }
    private var returnTitle: String {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .send: return "发送"
        case .go: return "前往"
        case .search: return "搜索"
        case .done: return "完成"
        case .next: return "下一项"
        case .join: return "加入"
        default: return "换行"
        }
    }
    private var currentReading:String { choices.first(where:{$0.replacementInput == nil && $0.latinInput==nil})?.comment ?? "" }
    private func commitHostText(_ text:String) {
        guard !text.isEmpty else { return }
        emptySymbolPair.unrelatedEdit()
        let hadMark=inlineComposition.active
        if !inlineComposition.finish(text,host:compositionHost) {
            textDocumentProxy.insertText(text)
            if hadMark { inlineComposition.forget();textDocumentProxy.unmarkText() }
        }
        archiveOutput(text)
        expanded=false
    }
    private func archiveOutput(_ text: String, pasteEvent: UUID? = nil, pasteSender: UUID? = nil, systemPaste:Bool=false) {
        let currentScope = diagnosticScope()
        let selection = pendingDecisionSelection.flatMap { $0.state.scope == currentScope ? $0 : nil }; pendingDecisionSelection = nil
        let decisionState = selection?.state ?? (currentScope != nil ? decisionTrace?.state : nil)
        guard hasFullAccess else { ActivityArchiveCapture.shared.stop(); return }
        if let decisionState { emitReferencedDecisionSnapshot(decisionState) }
        ActivityArchiveCapture.shared.refresh(permitted: true)
        let document = documentID?.uuidString
        if document != archiveDocument { archiveDocument = document; archiveEpoch = UUID().uuidString }
        // A nil document identifier cannot prove continuity with the previous field.
        let epoch = document == nil ? UUID().uuidString : archiveEpoch
        let safe: ActivityFieldSafety = textDocumentProxy.isSecureTextEntry == false ? .safe : .unknown
        let sourceContext=ActivitySourceContext(platform:"ios",
                                                      inputMethodVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,
                                                      inputMethodBuild:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String,
                                                      fieldType:textDocumentProxy.keyboardType.map{"keyboard_type:\($0.rawValue)"},
                                                      returnKey:textDocumentProxy.returnKeyType.map{"return_key:\($0.rawValue)"},
                                                      layout:layout == .nine ? "nine":layout == .letters ? "letters":layout == .numbers ? "numbers":"symbols",
                                                      captureComponent:"keyboard_extension")
        if systemPaste {
            ActivityArchiveCapture.shared.recordSystemPaste(text,sourceApp:nil,document:document,session:archiveSession,epoch:epoch,safety:safe,sourceContext:sourceContext)
        } else {
            let capture = ActivityArchiveCapture.shared, session = archiveSession
            let link = selection?.link ?? decisionState.map { ["composition_id": $0.compositionID, "state_id": $0.stateID] }
            let completion: ((UUID?) -> Void)?
            if let state = decisionState {
                completion = { [weak self] eventID in
                    guard let self, state.matchesOwner(scope: self.diagnosticScope(), document: self.documentID?.uuidString, epoch: self.archiveEpoch) else { return }
                    guard let diagnostic = DecisionTrace.decision(state, stage: "commit", nowUS: Self.diagnosticNowUS(), selection: selection,
                        reason: "insert_requested", outputEventID: eventID) else { return }
                    capture.recordDecision(diagnostic, scope: state.scope, document: state.document, session: session, epoch: state.epoch)
                }
            } else { completion = nil }
            capture.recordInput(text,sourceApp:nil,document:document,session:session,epoch:epoch,safety:safe,pasteEvent:pasteEvent,pasteSender:pasteSender,sourceContext:sourceContext,
                decisionLink:link, diagnosticScope:decisionState?.scope, completion: completion)
        }
        decisionTrace?.endComposition()
    }
    private func settlePending() { let pending = engine.takeReadablePendingInput(reading: currentReading); if !pending.isEmpty { commitHostText(pending) } }
    private func setLanguage(_ value: Bool) {
        emptySymbolPair.invalidate()
        cancelPrediction();ownCommitTracker.invalidate();engine.resetPredictionContext()
        settlePending(); panelHistory.removeAll(); english = value; shift = false; layout = english ? .letters : chineseLayout
        _ = engine.nineKey(!english && chineseLayout == .nine); _ = engine.switchToEnglish(english)
    }
    private func togglePanel(_ target: Layout) {
        cancelPrediction();ownCommitTracker.invalidate()
        if target == .numbers,layout != target {
            validateInlineContext()
            finishPendingForLiteral()
        }
        if layout == target { layout = panelHistory.popLast() ?? (english ? .letters : chineseLayout) }
        else { panelHistory.append(layout); layout = target }
        if layout == .symbols { refreshSymbolPage() }
        lastRevision = -1;expanded=false
        buildKeys(); render()
    }
    private func resumeAutomaticPredictionForUserInput() {
        noteClipboardInput()
        deletionPrediction.beginUserInput();predictionPausedRevision = -1;lastRevision = -1
    }
    private func archiveDiagnostic(_ action:String,key:String,before:String) {
        guard let scope = diagnosticScope() else { return }
        let state = decisionTrace?.state.flatMap { $0.matchesOwner(scope: scope, document: documentID?.uuidString, epoch: archiveEpoch) ? $0 : nil }
        let decision = (action == "choose" || action == "clear") ? nil : state.flatMap { DecisionTrace.decision($0, stage: "input", nowUS: Self.diagnosticNowUS(), reason: action) }
        ActivityArchiveCapture.shared.recordDiagnostic(action:action,key:key,before:before,after:engine.rawInput,
            candidates:Array(choices.prefix(5)).map(\.text),sourceApp:nil,document:documentID?.uuidString,
            session:archiveSession,epoch:archiveEpoch,safety:.safe, decision: decision, diagnosticScope: scope)
    }
    private static func diagnosticNowUS() -> Int64 { Int64(min(9_007_199_254_740_991, ProcessInfo.processInfo.systemUptime * 1_000_000)) }
    private func diagnosticScope() -> ActivityArchiveCapture.DiagnosticScope? {
        guard ActivityArchiveCapture.shared.permits(ActivityInputDiagnostic.provider),
              hasFullAccess, textDocumentProxy.isSecureTextEntry == false else {
            decisionTrace = nil; pendingDecisionSelection = nil; decisionSnapshotIDs = []; diagnosticMarkedRequest = nil
            return nil
        }
        return ActivityArchiveCapture.shared.diagnosticScope
    }
    private func diagnosticCandidate(_ row: InputCandidate) -> DecisionTrace.Candidate {
        let source = row.personalID != nil ? "personal" : (row.pinyinRepair != nil || row.replacementInput != nil || row.preservedNinePath || row.preservedNinePrefix ? "correction" : (row.latinInput != nil ? "literal" : "unknown"))
        return .init(identity: "\(row.index)|\(row.generation ?? engine.revision)|\(row.text)|\(row.comment)", text: row.text, reading: row.comment, source: source)
    }
    private func publishDecisionSnapshot() {
        guard let scope = diagnosticScope() else { return }
        if decisionTrace == nil { decisionTrace = DecisionTrace() }
        let oldComposition = decisionTrace?.state?.compositionID
        // Metadata must describe this captured state. A newer preference token
        // does not prove which cloud model the live native snapshot adopted;
        // omit model_version/hash until the owner exposes that exact identity.
        var metadata: [String: ActivityJSONValue] = [:]
        if compositionPosition == "inline", !engine.preedit.isEmpty {
            if let marked = diagnosticMarkedRequest, marked.scope == scope, marked.text.utf8.count <= 4096 {
                metadata["marked_status"] = .string("insert_requested"); metadata["marked_text"] = .string(marked.text)
            } else { metadata["marked_status"] = .string("unknown") }
        } else { metadata["marked_status"] = .string("not_used") }
        for (key, info) in [("core_hash", "PrivateInputCoreSHA256"), ("resource_hash", "PrivateInputResourceSHA256"), ("policy_hash", "PrivateInputPolicySHA256")] {
            if let value = Bundle.main.object(forInfoDictionaryKey: info) as? String, value.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { metadata[key] = .string(value) }
        }
        guard let state = decisionTrace?.publish(scope: scope, document: documentID?.uuidString, epoch: archiveEpoch,
            revision: Int64(engine.revision), rows: Array(choices.prefix(5)).map(diagnosticCandidate), metadata: metadata) else { return }
        if oldComposition != state.compositionID { decisionSnapshotIDs = [] }
        // Keep only lightweight current values. A referenced state is emitted
        // once at an actual decision/cancel, never a new per-key candidate dump.
    }
    private func emitReferencedDecisionSnapshot(_ state: DecisionTrace.State) {
        guard state.matchesOwner(scope: diagnosticScope(), document: documentID?.uuidString, epoch: archiveEpoch), !decisionSnapshotIDs.contains(state.stateID),
              let value = DecisionTrace.decision(state, stage: "candidates", nowUS: Self.diagnosticNowUS(), includeCandidates: true) else { return }
        if decisionSnapshotIDs.count >= 64 { decisionSnapshotIDs.removeAll() }
        decisionSnapshotIDs.insert(state.stateID)
        ActivityArchiveCapture.shared.recordDecision(value, scope: state.scope, document: state.document, session: archiveSession, epoch: state.epoch)
    }
    private func diagnosticCandidatePress(_ candidate: InputCandidate, rank: Int) {
        guard let owner = decisionTrace?.state, owner.matchesOwner(scope: diagnosticScope(), document: documentID?.uuidString, epoch: archiveEpoch),
              let selection = decisionTrace?.press(diagnosticCandidate(candidate), rank: rank, nowUS: Self.diagnosticNowUS()),
              let value = DecisionTrace.decision(selection.state, stage: "press", nowUS: Self.diagnosticNowUS(), selection: selection) else { return }
        emitReferencedDecisionSnapshot(selection.state)
        ActivityArchiveCapture.shared.recordDecision(value, scope: selection.state.scope, document: selection.state.document, session: archiveSession, epoch: selection.state.epoch)
    }
    private func diagnosticCandidateRelease(_ candidate: InputCandidate, accepted: Bool) {
        guard let owner = decisionTrace?.state, owner.matchesOwner(scope: diagnosticScope(), document: documentID?.uuidString, epoch: archiveEpoch),
              let selection = decisionTrace?.release(diagnosticCandidate(candidate), accepted: accepted, nowUS: Self.diagnosticNowUS()),
              let state = decisionTrace?.state,
              let value = DecisionTrace.decision(state, stage: accepted ? "release" : "cancel", nowUS: Self.diagnosticNowUS(), selection: selection, reason: accepted ? nil : "touch_cancelled") else { return }
        ActivityArchiveCapture.shared.recordDecision(value, scope: state.scope, document: state.document, session: archiveSession, epoch: state.epoch)
    }
    private func stageDiagnosticSelection(_ candidate: InputCandidate, method: String = "unknown") {
        guard let owner = decisionTrace?.state, owner.matchesOwner(scope: diagnosticScope(), document: documentID?.uuidString, epoch: archiveEpoch) else { return }
        guard let rank = choices.firstIndex(where: { $0.index == candidate.index && $0.text == candidate.text && $0.generation == candidate.generation }) else { return }
        guard let selection = decisionTrace?.select(diagnosticCandidate(candidate), rank: rank, method: method),
              let value = DecisionTrace.decision(selection.state, stage: "selection", nowUS: Self.diagnosticNowUS(), selection: selection) else { return }
        pendingDecisionSelection = selection
        emitReferencedDecisionSnapshot(selection.state)
        ActivityArchiveCapture.shared.recordDecision(value, scope: selection.state.scope, document: selection.state.document, session: archiveSession, epoch: selection.state.epoch)
    }
    private func cancelDiagnosticComposition(reason: String) {
        defer { decisionTrace?.endComposition(); pendingDecisionSelection = nil; diagnosticMarkedRequest = nil }
        guard let state = decisionTrace?.state, state.matchesOwner(scope: diagnosticScope(), document: documentID?.uuidString, epoch: archiveEpoch),
              let value = DecisionTrace.decision(state, stage: "cancel", nowUS: Self.diagnosticNowUS(), reason: reason) else { return }
        emitReferencedDecisionSnapshot(state)
        ActivityArchiveCapture.shared.recordDecision(value, scope: state.scope, document: state.document, session: archiveSession, epoch: state.epoch)
    }
    private func type(_ text: String) {
        emptySymbolPair.invalidate()
        let diagnosticBefore=diagnosticScope() != nil ? engine.rawInput : ""
        defer { archiveDiagnostic("key",key:text,before:diagnosticBefore) }
        if !text.isEmpty {resumeAutomaticPredictionForUserInput()}
        cancelLearningForInteraction();validateInlineContext()
        validateOwnContext()
        if !english,engine.preedit.isEmpty,text.utf8.allSatisfy({(50...57).contains($0) || (97...122).contains($0)}),textDocumentProxy.selectedText?.isEmpty != false,
           let remaining=ownCommitTracker.expectedText(document:documentID?.uuidString ?? "",time:Date.timeIntervalSinceReferenceDate),
           let before=textDocumentProxy.documentContextBeforeInput,before.hasSuffix(remaining),
           let r=ownCommitTracker.partiallyDeleted(document:documentID?.uuidString ?? "",anchor:anchor(String(before.dropLast(remaining.count))),time:Date.timeIntervalSinceReferenceDate),let reading=r.reading {
            engine.notePartiallyDeletedOwnCommit(code:r.code,context:r.context,rejectedText:r.rejectedText,reading:reading)
        }
        ownCommitTracker.invalidate()
        if english || layout == .numbers || layout == .symbols || !engine.ready { commitHostText(text); render(); return }
        if engine.preedit.isEmpty {captureHostContext()}
        if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 {
            let result = engine.key(Int32(scalar.value))
            if !result.commit.isEmpty { commitHostText(result.commit) }
            if !result.handled { commitHostText(text) }
        }
        render()
    }
    private func finishPendingForLiteral() {
        if !engine.preedit.isEmpty {
            if let first=choices.first {
                stageDiagnosticSelection(first, method: "unknown")
                let commit=engine.chooseCandidate(first);if !commit.isEmpty {commitHostText(commit)}
                pendingDecisionSelection = nil
            }
            settlePending()
        }
    }
    private func insertLiteral(_ text: String, caretBack: Int = 0, pairOpening:String? = nil) {
        emptySymbolPair.invalidate()
        let diagnosticBefore=diagnosticScope() != nil ? engine.rawInput : ""
        defer { archiveDiagnostic("literal",key:text,before:diagnosticBefore) }
        if !text.isEmpty {resumeAutomaticPredictionForUserInput()}
        cancelPrediction()
        validateInlineContext()
        finishPendingForLiteral()
        let before=pairOpening != nil && engine.preedit.isEmpty && engine.rawInput.isEmpty ? symbolPairContext():nil
        let proxyBefore=pairOpening != nil && engine.preedit.isEmpty && engine.rawInput.isEmpty ? symbolPairProxyContext():nil
        ownCommitTracker.invalidate();engine.noteLiteralInput(text)
        let token=emptySymbolPair.performOwnMutation {
            commitHostText(text)
            if caretBack > 0 {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: -caretBack)
                // The closer is now after the caret, not part of preceding text.
                // Recapture native context on the next input instead of using
                // the full inserted pair as though the caret were at its end.
                engine.resetPredictionContext()
            }
        }
        if let opening=pairOpening {
            let insertion=SymbolPairing.Plan(insertedText:text,caretBack:caretBack)
            if !emptySymbolPair.arm(opening:opening,insertion:insertion,before:before,token:token) {
                emptySymbolPair.armVerifiedProxyInsertion(opening:opening,insertion:insertion,before:proxyBefore,after:symbolPairProxyContext(),token:token)
            }
        }
        render()
    }
    private func symbolPairContext()->SymbolPairing.EditContext? {
        guard textDocumentProxy.isSecureTextEntry == false else{return nil}
        return .init(document:documentID?.uuidString,selectionEmpty:textDocumentProxy.selectedText?.isEmpty != false,
                     before:textDocumentProxy.documentContextBeforeInput,after:textDocumentProxy.documentContextAfterInput)
    }
    private func symbolPairProxyContext()->SymbolPairing.ProxyContext? {
        guard textDocumentProxy.isSecureTextEntry == false else{return nil}
        return .init(document:documentID?.uuidString,selectionEmpty:textDocumentProxy.selectedText?.isEmpty != false,
                     before:textDocumentProxy.documentContextBeforeInput,after:textDocumentProxy.documentContextAfterInput,
                     hasText:textDocumentProxy.hasText)
    }
    private func observeSymbolPairContext() {
        guard emptySymbolPair.isArmed,!emptySymbolPair.isPerformingOwnMutation else{return}
        emptySymbolPair.observeProxy(symbolPairProxyContext())
    }
    private func anchor(_ prefix:String?) -> String? {
        prefix.map { SHA256.hash(data:Data($0.suffix(16).utf8)).map { String(format:"%02x",$0) }.joined() }
    }
    private func validateOwnContext() {
        guard engine.preedit.isEmpty,!inlineComposition.active,!engine.precedingOwnText.isEmpty else { return }
        if textDocumentProxy.documentContextBeforeInput?.hasSuffix(SentenceContextWindow.validationSuffix(engine.precedingOwnText)) != true {
            // Programmatic host edits and cached proxy callbacks can differ.
            // The own-commit correction tracker checks its own suffix,
            // field and time before it is ever used as a correction signal.
            cancelPrediction();engine.resetPredictionContext(preservingReplacement:true)
        }
    }
    /// One explicit cancellation for every layout. Only the next real input
    /// (or a confirmed new field) can re-enable automatic suggestions.
    private func clearCurrentSuggestions() {
        emptySymbolPair.invalidate()
        clipboardActivity.noteInput(at:Date.timeIntervalSinceReferenceDate)
        let diagnosticBefore=diagnosticScope() != nil ? engine.rawInput : ""
        cancelDiagnosticComposition(reason: "user_clear")
        defer { archiveDiagnostic("clear",key:"clear",before:diagnosticBefore) }
        let hadComposition = !engine.preedit.isEmpty || !engine.rawInput.isEmpty
        stopDeletion();deletionPrediction.observeDocument(documentID);deletionPrediction.beginClear()
        cancelCandidatePage();cancelPrediction();cancelLearningForInteraction()
        clipboardState.observe(version:UIPasteboard.general.changeCount);clipboardState.dismiss()
        clipboardKnown=nil;clipboardLoad.cancel()
        // Dismissing suggestions alone must keep the own-commit token: the
        // next Backspace may be correcting the word just committed.
        if hadComposition {ownCommitTracker.invalidate()}
        engine.resetPredictionContext(preservingReplacement:!hadComposition)
        if hadComposition {engine.clear()}
        publishedCandidates.reset();candidateSourceOffset=0;hasMore=false;expanded=false;lastRevision = -1
        render()
    }
    private func backspace() {
        clipboardActivity.noteInput(at:Date.timeIntervalSinceReferenceDate)
        let diagnosticBefore=diagnosticScope() != nil ? engine.rawInput : ""
        defer { archiveDiagnostic("delete",key:"backspace",before:diagnosticBefore) }
        let dismissClipboard = !clipboardCandidate.isHidden
        clipboardState.observe(version:UIPasteboard.general.changeCount);clipboardState.dismiss()
        clipboardKnown=nil;clipboardLoad.cancel()
        deletionPrediction.observeDocument(documentID);deletionPrediction.beginDeletion();cancelCandidatePage();cancelPrediction()
        cancelLearningForInteraction();validateInlineContext()
        if dismissClipboard,engine.preedit.isEmpty {emptySymbolPair.invalidate();publishedCandidates.reset();lastRevision = -1;expanded=false;render();return}
        if !engine.preedit.isEmpty {emptySymbolPair.invalidate(); ownCommitTracker.invalidate();_ = engine.key(0xff08);render();return }
        if !english,choices.contains(where:{$0.continuationContext != nil}) {
            cancelPrediction()
            // A continuation is only a suggestion. Backspace must also edit
            // the host text in this same press, with prediction suppressed.
            publishedCandidates.reset();lastRevision = -1;expanded=false
        }
        if emptySymbolPair.isArmed,let plan=emptySymbolPair.consumeProxy(symbolPairProxyContext()) {
            var handled=false
            emptySymbolPair.performOwnMutation {
                handled=SymbolPairing.deleteProxySequentially(plan,context:symbolPairProxyContext,
                    moveForward:{textDocumentProxy.adjustTextPosition(byCharacterOffset:$0)},deleteBackward:{textDocumentProxy.deleteBackward()})
            }
            if handled {ownCommitTracker.invalidate();engine.resetPredictionContext();publishedCandidates.reset();lastRevision = -1;expanded=false;render();return}
        }
        let document=documentID?.uuidString ?? "",time=Date.timeIntervalSinceReferenceDate
        var replacement:OwnCommitCorrectionTracker.Replacement?
        if let remaining=ownCommitTracker.expectedText(document:document,time:time),
           textDocumentProxy.selectedText?.isEmpty != false,
           let prefix=textDocumentProxy.documentContextBeforeInput,prefix.hasSuffix(remaining) {
            replacement=ownCommitTracker.deleted(document:document,anchor:anchor(String(prefix.dropLast(remaining.count))),time:time)
        } else { ownCommitTracker.invalidate() }
        // Clear the stale own context before UIKit sends synchronous change
        // callbacks; those callbacks must not discard the remaining own-commit token.
        engine.resetPredictionContext();textDocumentProxy.deleteBackward()
        if let replacement { engine.noteFullyDeletedOwnCommit(code:replacement.code,context:replacement.context,rejectedText:replacement.rejectedText,reading:replacement.reading) }
        render()
    }
    private func startDeletion() {
        stopDeletion(); let generation = deletionGeneration; backspace()
        guard deletionGeneration == generation else { return }
        let delay = Timer(timeInterval: 0.38, repeats: false) { [weak self] _ in
            guard let self, self.deletionGeneration == generation else { return }; self.backspace()
            guard self.deletionGeneration == generation else { return }
            let repeatTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] timer in
                guard let self, self.deletionGeneration == generation else { timer.invalidate(); return }; self.backspace()
            }
            self.deleteRepeat = repeatTimer; RunLoop.main.add(repeatTimer, forMode: .common)
        }
        deleteDelay = delay; RunLoop.main.add(delay, forMode: .common)
    }
    private func stopDeletion() { deletionGeneration &+= 1; deleteDelay?.invalidate(); deleteRepeat?.invalidate(); deleteDelay = nil; deleteRepeat = nil }
    private func choose(_ candidate: InputCandidate, method: String = "unknown") {
        emptySymbolPair.invalidate()
        stageDiagnosticSelection(candidate, method: method)
        defer { pendingDecisionSelection = nil }
        let diagnosticBefore=diagnosticScope() != nil ? engine.rawInput : ""
        defer { archiveDiagnostic("choose",key:candidate.text,before:diagnosticBefore) }
        if validateInlineContext() { render();return }
        if english {
            guard englishDocument == documentID, candidate.comment == englishWord(), !candidate.comment.isEmpty else { render(); return }
            resumeAutomaticPredictionForUserInput()
            for _ in candidate.comment { textDocumentProxy.deleteBackward() }
            commitHostText(candidate.text); render(); return
        }
        if let context=candidate.continuationContext {
            guard lastRevision==engine.revision,textDocumentProxy.selectedText?.isEmpty != false,
                  textDocumentProxy.documentContextBeforeInput?.hasSuffix(SentenceContextWindow.validationSuffix(context))==true else { render();return }
            resumeAutomaticPredictionForUserInput();let text=engine.chooseContinuation(candidate)
            if !text.isEmpty { ownCommitTracker.invalidate();commitHostText(text) }
            render();return
        }
        guard lastRevision == engine.revision else { render(); return }
        resumeAutomaticPredictionForUserInput()
        let originalInput=engine.rawInput
        let code=NineKeySpelling.rawCode(originalInput) ?? originalInput,context=engine.precedingOwnText
        let commit = engine.chooseCandidate(candidate)
        #if targetEnvironment(simulator)
        let probe=engine.candidateBatch(offset:0,limit:3)
        NSLog("INLINE_CHOICE text=%d commit=%d raw=%d preedit=%d first=%d",candidate.text.utf16.count,commit.utf16.count,engine.rawInput.utf16.count,engine.preedit.utf16.count,probe.first?.text.utf16.count ?? -1)
        #endif
        if !commit.isEmpty {
            commitHostText(commit)
            if !english {
                let current=textDocumentProxy.documentContextBeforeInput
                let prefix=current?.hasSuffix(commit)==true ? current.map{String($0.dropLast(commit.count))} : nil
                let validContext=prefix?.hasSuffix(SentenceContextWindow.validationSuffix(context))==true ? context : ""
                engine.confirmOwnCommitContext(previous:validContext,text:commit)
                if let document=documentID { ownCommitTracker.stage(document:document.uuidString,anchor:anchor(prefix),text:commit,code:code,context:validContext,time:Date.timeIntervalSinceReferenceDate,reading:commit==candidate.text && candidate.latinInput==nil && candidate.personalID==nil && candidate.supplementaryTrigger==nil ? candidate.comment:nil) }
            }
        }
        if commit.isEmpty && !engine.preedit.isEmpty { lastRevision = -1 }
        render()
        if commit.isEmpty && !engine.preedit.isEmpty {
            // A partial selection updates both the host's marked range and the
            // collection being tapped. Refresh bindings after UIKit's event.
            let revision=engine.revision,document=documentID,presentation=keyboardPresentation
            DispatchQueue.main.async { [weak self] in
                guard let self,self.engine?.revision==revision,self.documentID==document,self.keyboardPresentation==presentation else{return}
                // The synchronous selection render already queried this
                // revision. Only refresh UIKit bindings after its touch ends.
                self.render()
            }
        }
    }
    /// A touch freezes this revision's visible order, including late neural
    /// callbacks. New input changes revision and naturally permits ranking again.
    @objc private func pauseCandidateRankingForInteraction() {
        guard let engine else { return }
        predictionPausedRevision = engine.revision
        cancelLearningForInteraction();cancelCandidatePage(preservingRequest:true);cancelPrediction()
    }
    private func canApplyPrediction(revision: Int, document: UUID, generation:UInt64) -> Bool {
        deletionPrediction.acceptsPrediction(generation:generation) && engine.revision == revision && documentID == document && !expanded &&
        predictionPausedRevision != revision && !strip.isTracking && !grid.isTracking &&
        !strip.isDragging && !grid.isDragging && !strip.isDecelerating && !grid.isDecelerating
    }
    private func cancelPrediction() { predictionTimer?.invalidate();predictionTimer=nil;engine?.cancelNinePrediction() }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning();cancelPrediction();engine?.suspendPredictionForMemoryPressure();lastRevision = -1;render()
    }
    private func captureHostContext() {
        let started=ProcessInfo.processInfo.systemUptime
        defer {KeyboardRuntimeDiagnostics.recordSlow(.hostContextSlow,startedUptime:started)}
        guard !english,engine.preedit.isEmpty,!inlineComposition.active else{return}
        // Capture before creating marked text; never guess how much preedit
        // a host includes in its proxy, and never retain the selected text.
        let before=textDocumentProxy.documentContextBeforeInput,after=textDocumentProxy.documentContextAfterInput
        engine.setHostContext(before == nil && after == nil ? nil:SurroundingText(before:before ?? "",after:after ?? ""))
    }
    private func schedulePrediction() {
        guard !deletionPrediction.suppressed else {cancelPrediction();return}
        if layout == .letters,!english,!engine.preedit.isEmpty,!expanded,predictionPausedRevision != engine.revision {
            guard pinyinRankingRevision != engine.revision,let document=documentID else{return}
            cancelPrediction();let revision=engine.revision,generation=deletionPrediction.generation;pinyinRankingRevision=revision
            predictionTimer=Timer.scheduledTimer(withTimeInterval:0.12,repeats:false) { [weak self] _ in
                guard let self else{return};self.predictionTimer=nil
                guard self.canApplyPrediction(revision:revision,document:document,generation:generation) else{return}
                self.engine.rankPinyinCandidates(self.choices) { [weak self] ranked in
                    guard let self,self.canApplyPrediction(revision:revision,document:document,generation:generation) else{return}
                    self.appendPublishedCandidates(ranked);self.render()
                }
            };return
        }
        if engine.preedit.isEmpty,!english,(layout == .nine || layout == .letters) {
            guard !expanded,predictionPausedRevision != engine.revision,let document=documentID else { return }
            let revision=engine.revision,generation=deletionPrediction.generation
            engine.rankContinuations { [weak self] in
                guard let self,self.canApplyPrediction(revision:revision,document:document,generation:generation) else { return }
                self.lastRevision = -1;self.render()
            };return
        }
        guard layout == .nine,!english,!expanded,predictionPausedRevision != engine.revision else { cancelPrediction();return }
        if predictionTimer != nil && predictionTimerRevision==engine.revision { return }
        cancelPrediction()
        guard engine.needsNinePrediction else { return }
        guard let document=documentID else { return }
        let revision=engine.revision,generation=deletionPrediction.generation
        predictionTimerRevision=revision
        predictionTimer=Timer.scheduledTimer(withTimeInterval:0.12,repeats:false) { [weak self] _ in
            guard let self else { return };self.predictionTimer=nil
            guard self.canApplyPrediction(revision:revision,document:document,generation:generation),
                  self.layout == .nine,self.engine.beginNinePrediction() else { return }
            // Preparation and querying never run in the same run-loop turn.
            self.schedulePredictionSlice(revision:revision,document:document,generation:generation)
        }
    }
    private func advancePrediction(revision:Int,document:UUID,generation:UInt64) {
        guard canApplyPrediction(revision:revision,document:document,generation:generation),layout == .nine else { cancelPrediction();return }
        if engine.advanceNinePrediction(maxQueriesPerSlice: 1) {
            predictionLog.debug("completed elapsed_ms=\(self.engine.predictionElapsedMS,privacy:.public) max_slice_ms=\(self.engine.predictionMaxSliceMS,privacy:.public) footprint_mb=\(self.engine.predictionFootprintMB,privacy:.public)")
            lastRevision = -1;render();return
        }
        schedulePredictionSlice(revision:revision,document:document,generation:generation)
    }
    private func schedulePredictionSlice(revision:Int,document:UUID,generation:UInt64) {
        let interval:TimeInterval = engine.ninePredictionWaitingForBackground ? 0.008:0.002
        predictionTimer=Timer.scheduledTimer(withTimeInterval:interval,repeats:false) { [weak self] _ in
            self?.predictionTimer=nil;self?.advancePrediction(revision:revision,document:document,generation:generation)
        }
    }
    private func appendPublishedCandidates(_ rows: [InputCandidate]) {
        let start = choices.count
        choices = publishedCandidates.publish(rows, revision: engine.revision, document: documentID, identity: PublishedCandidateIdentity.init)
        // No reload, content-offset reset or changed action for an existing row.
        if choices.count > start {
            let added = (start..<choices.count).map { IndexPath(item: $0, section: 0) }
            UIView.performWithoutAnimation {strip.insertItems(at: added);grid.insertItems(at: added)}
        }
    }
    private func cancelCandidatePage(preservingRequest:Bool = false) {
        candidatePageGeneration &+= 1;candidatePageWork?.cancel();candidatePageWork=nil
        if !preservingRequest {candidatePageRequested=false}
    }
    private func dismissCandidateMenus() {
        for collection in [strip,grid] {for case let cell as CandidateCell in collection.visibleCells {cell.dismissCandidateMenu()}}
    }
    private func setCandidatesExpanded(_ value: Bool) {
        guard value != expanded,candidatePanelToggleAvailable else{return}
        cancelCandidatePage();cancelPrediction()
        dismissCandidateMenus()
        expanded=value;candidateExpansionFillRemaining=value ? 32:0
        // A panel toggle changes visibility only. It must not re-query Rime,
        // rewrite marked text, read preferences or ask the host to resize.
        UIView.performWithoutAnimation {
            CATransaction.begin();CATransaction.setDisableActions(true)
            applyCandidatePanelVisibility()
            view.layoutIfNeeded()
            CATransaction.commit()
        }
        if value {requestCandidatePage()}
    }
    private func applyCandidatePanelVisibility() {
        candidateBar.alpha=expanded ? 0:1;candidateBar.isUserInteractionEnabled = !expanded;candidateBar.accessibilityElementsHidden=expanded
        grid.isHidden = !expanded;grid.accessibilityElementsHidden = !expanded
        applyExpandedKeyboardControls()
        fallbackCompositionScroll.isHidden = !fallbackCompositionVisible || expanded
        candidateLeading.constant=fallbackCompositionVisible && !expanded ? fallbackCompositionWidth.constant+12:0
        updateHeaderFrames()
        expand.setImage(UIImage(systemName:expanded ? "chevron.up":"chevron.down"),for:.normal)
        expand.accessibilityIdentifier=expanded ? "collapse-candidates":"expand-candidates"
        expand.accessibilityLabel=expanded ? "返回键盘":"展开全部候选"
        if expanded {view.bringSubviewToFront(grid)}
        view.bringSubviewToFront(expand)
    }
    private func applyExpandedKeyboardControls() {
        guard appliedCandidatePanelExpanded != expanded else { return }
        keyboardBody.alpha=1;keyboardBody.isUserInteractionEnabled=true;keyboardBody.accessibilityElementsHidden=false
        KeyboardCandidatePanelGeometry.apply(expanded:expanded,keyRegions:keys.arrangedSubviews,
            retainedActions:candidateRetainedActions,delete:candidateDeleteButton,footer:footer)
        appliedCandidatePanelExpanded=expanded
    }
    private func requestCandidatePage() {
        guard keyboardAppeared,viewIfLoaded?.window != nil,hasMore,!english,!engine.preedit.isEmpty else{return}
        candidatePageRequested=true
        guard candidatePageWork == nil else{return}
        let revision=engine.revision,document=documentID,generation=candidatePageGeneration
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.candidatePageGeneration==generation else{return};self.candidatePageWork=nil
            guard self.engine.revision==revision,self.documentID==document else {self.candidatePageRequested=false;return}
            guard !self.expand.isTracking,self.pressedKeyboardControls.isEmpty,
                  ![self.strip,self.grid].contains(where:{$0.visibleCells.contains(where:{($0 as? CandidateCell)?.isHandlingControlTouch==true})}) else{return}
            self.candidatePageRequested=false
            let consumed=self.loadMore(limit:8)
            self.candidateExpansionFillRemaining=max(0,self.candidateExpansionFillRemaining-consumed)
            // Fill the newly exposed viewport a small slice at a time. Existing
            // cells and their tap actions stay intact; collapse cancels the rest.
            if self.engine.candidateBatchWasDeferred || (self.expanded && self.candidateExpansionFillRemaining>0 && self.grid.contentSize.height<self.grid.bounds.height) {
                self.requestCandidatePage()
            }
        }
        candidatePageWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.025,execute:work)
    }
    @discardableResult private func loadMore(limit: Int)->Int {
        guard !loading, hasMore, !english, !engine.preedit.isEmpty else { return 0 }
        loading = true
        let next = engine.candidateBatch(offset: candidateSourceOffset, limit: limit,incremental:true)
        candidateSourceOffset += next.count; hasMore = engine.candidateBatchCanContinue
        appendPublishedCandidates(next)
        updateCandidateExpansionAvailability()
        loading = false
        return next.count
    }
    private func updateCandidateExpansionAvailability() {
        expand.isEnabled=candidatePanelToggleAvailable
        expand.isHidden = !candidatePanelToggleAvailable
    }
    private var candidatePanelToggleAvailable:Bool {
        CandidateExpansionButton.canToggle(expanded:expanded,choicesAvailable:!choices.isEmpty,
            hasComposition:!engine.preedit.isEmpty,deferred:engine.candidateBatchWasDeferred,english:english)
    }
    private func resumeCandidatePageAfterInteraction() {
        guard let engine else{return}
        let revision=engine.revision,document=documentID,presentation=keyboardPresentation
        DispatchQueue.main.async { [weak self] in
            guard let self,self.keyboardAppeared,self.keyboardPresentation==presentation,
                  self.engine.revision==revision,self.documentID==document,
                  self.candidatePageRequested || self.engine.candidateBatchWasDeferred || (self.expanded && self.candidateExpansionFillRemaining>0) else{return}
            self.requestCandidatePage()
        }
    }
    @discardableResult private func validateInlineContext() -> Bool {
        guard inlineComposition.active,!inlineComposition.applying,inlineComposition.moved(in:compositionHost) else { return false }
        #if targetEnvironment(simulator)
        NSLog("INLINE_END context selected=%d before=%d after=%d draft=%d",textDocumentProxy.selectedText?.utf16.count ?? -1,textDocumentProxy.documentContextBeforeInput?.utf16.count ?? -1,textDocumentProxy.documentContextAfterInput?.utf16.count ?? -1,inlineComposition.draft.utf16.count)
        #endif
        inlineComposition.leave(host:compositionHost);engine.clear();expanded=false;ownCommitTracker.invalidate();engine.resetPredictionContext();return true
    }
    private func render() {
        guard engine != nil,!inlineComposition.applying else { return }
        deletionPrediction.observeDocument(documentID)
        if let currentDocument=documentID,activeDocument != currentDocument {
            emptySymbolPair.invalidate()
            if inlineComposition.active,inlineComposition.document != currentDocument {
                #if targetEnvironment(simulator)
                NSLog("INLINE_END document draft=%d",inlineComposition.draft.utf16.count)
                #endif
                inlineComposition.forget();engine.clear();expanded=false
            }
            cancelPrediction();ownCommitTracker.invalidate();engine.resetPredictionContext();activeDocument=currentDocument
        }
        validateInlineContext()
        validateOwnContext()
        if preferencesPending && engine.preedit.isEmpty { applyPreferences() }
        if engine.managementPending {learningRefreshPending=true}
        if engine.preedit.isEmpty,!deletionPrediction.suppressed {captureHostContext()}
        if layout == .numbers {
            publishedCandidates.reset(); candidateSourceOffset=0
            if !choices.isEmpty {choices=[];strip.reloadData();grid.reloadData()}
            hasMore=false;expanded=false;lastRevision=engine.revision
        } else if english { publishedCandidates.reset();candidateSourceOffset=0;refreshEnglishChoices() }
        else if lastRevision != engine.revision {
            cancelCandidatePage();lastRevision = engine.revision
            // Partial selections keep the panel open but should not block the
            // next touch on a synchronous 48-row query. Fill using small pages.
            let limit = 12
            let next:[InputCandidate]
            switch deletionPrediction.source(hasComposition:!engine.preedit.isEmpty) {
            case .primary:next=engine.candidateBatch(offset:0,limit:limit,incremental:true)
            case .continuation:next=(layout == .nine || layout == .letters) ? engine.continuationBatch():[]
            case .none:next=[]
            }
            let newInput = !publishedCandidates.matches(revision: engine.revision, document: documentID)
            candidateSourceOffset = next.count
            hasMore = !engine.preedit.isEmpty && engine.candidateBatchCanContinue
            loading = true
            if newInput {
                candidateExpansionFillRemaining=expanded ? 32:0
                choices = publishedCandidates.publish(next, revision: engine.revision, document: documentID, identity: PublishedCandidateIdentity.init)
                strip.reloadData(); grid.collectionViewLayout.invalidateLayout(); grid.reloadData()
                strip.setContentOffset(.zero, animated: false); grid.setContentOffset(.zero, animated: false)
            } else {
                // Background semantic/nine-key work may append newly found
                // alternatives, but never replace an already readable position.
                appendPublishedCandidates(next)
            }
            if expanded { grid.layoutIfNeeded() }
            loading = false
        }
        // Publication may freeze a different head from the engine's latest
        // async batch. Carry the path the user can actually see.
        if !english,layout == .nine,let first=choices.first { engine.rememberPublishedNineCandidate(first) }
        let chinesePending = !engine.preedit.isEmpty
        #if targetEnvironment(simulator)
        if compositionPosition=="inline" { NSLog("INLINE_STATE pending=%d expanded=%d choices=%d mark=%d",chinesePending ? 1:0,expanded ? 1:0,choices.count,inlineComposition.active ? 1:0) }
        #endif
        let pending = chinesePending || !choices.isEmpty
        updateSideRail()
        if !pending || (wasChinesePending && !chinesePending) { expanded = false }
        wasChinesePending=chinesePending
        composition.text = english ? englishPrefix : engine.displayedPreedit(reading: currentReading)
        let inlineShown:Bool
        if compositionPosition=="inline",chinesePending,!english {
            inlineShown=inlineComposition.update(composition.text ?? "",host:compositionHost)
        } else {
            _ = inlineComposition.finish(nil,host:compositionHost);inlineShown=false
        }
        #if DEBUG
        if !pending { composition.text = permissionProbe?.label }
        if let permissionProbe, let data = try? JSONEncoder().encode(permissionProbe) { composition.accessibilityValue = String(data: data, encoding: .utf8) }
        #endif
        #if targetEnvironment(simulator)
        if composition.accessibilityIdentifier=="composition-preedit" { composition.accessibilityValue=engine.rawInput };clearButton?.accessibilityValue=engine.rawInput;letterActionButton?.accessibilityValue=engine.rawInput
        #endif
        preeditHeight.constant = KeyboardCandidatePanelGeometry.preeditHeight
        preeditRow.isHidden = compositionPosition == "inline" || !chinesePending; preeditTrailing.constant = 0
        fallbackCompositionVisible = compositionPosition == "inline" && chinesePending && !english && !inlineShown
        fallbackCompositionScroll.isHidden = !fallbackCompositionVisible || expanded
        fallbackCompositionLabel.text = fallbackCompositionVisible ? composition.text : nil
        fallbackCompositionWidth.constant=min(112,max(72,view.bounds.width*0.28))
        candidateLeading.constant=fallbackCompositionVisible && !expanded ? fallbackCompositionWidth.constant+12:0
        candidateBar.isHidden = !pending; toolbar.isHidden = pending
        candidateBar.alpha=expanded ? 0:1;candidateBar.isUserInteractionEnabled = !expanded;candidateBar.accessibilityElementsHidden=expanded
        grid.isHidden = !expanded;grid.accessibilityElementsHidden = !expanded; keyboardBody.isHidden = false
        applyExpandedKeyboardControls()
        updateHeaderFrames();header.layoutIfNeeded();strip.collectionViewLayout.invalidateLayout()
        if expanded { view.bringSubviewToFront(grid) }
        updateCandidateExpansionAvailability()
        expand.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
        expand.accessibilityIdentifier = expanded ? "collapse-candidates" : "expand-candidates"
        expand.accessibilityLabel = expanded ? "返回键盘" : "展开全部候选"
        expand.accessibilityValue = !english && engine.hasPreparedNinePrediction ? "候选已更新":nil
        if pending { view.bringSubviewToFront(expand) }
        updateClipboardCandidateVisibility()
        letterActionButton?.setTitle("清空",for:.normal)
        let clearable=chinesePending || !choices.isEmpty || !clipboardCandidate.isHidden
        letterActionButton?.alpha=clearable ? 1:0.45
        letterActionButton?.accessibilityIdentifier="clear-composition"
        letterActionButton?.accessibilityLabel="清空候选并暂停联想"
        letterActionButton?.accessibilityHint="长按可收起键盘"
        clearButton?.alpha = clearable ? 1 : 0.45
        returnButton?.setTitle(returnTitle, for: .normal)
        refreshSettingsMenus()
        // iOS may keep visible collection cells through an input-view/marked-
        // text layout update. Refresh their content and actions as one snapshot.
        for collection in [strip,grid] {
            for index in collection.indexPathsForVisibleItems where index.item < choices.count {
                if let cell=collection.cellForItem(at:index) as? CandidateCell { configureCandidate(cell,in:collection,at:index) }
            }
        }
        #if targetEnvironment(simulator)
        if let probe=try? JSONSerialization.data(withJSONObject:["hostContext":engine.hasHostContext,"beforeCount":engine.modelContext.before.count,"afterCount":engine.modelContext.after.count,"available":engine.semanticLastMetrics.available,"semanticRevision":engine.semanticMetricsRevision,"revision":engine.revision]) {strip.accessibilityValue=String(data:probe,encoding:.utf8)}
        #endif
        publishDecisionSnapshot()
        schedulePrediction()
        if engine.candidateBatchWasDeferred || (expanded && candidateExpansionFillRemaining>0) {requestCandidatePage()}
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { collectionView === symbolGrid ? allSymbols.count : choices.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "candidate", for: indexPath) as! CandidateCell
        configureCandidate(cell,in:collectionView,at:indexPath)
        return cell
    }
    private func configureCandidate(_ cell:CandidateCell,in collectionView:UICollectionView,at indexPath:IndexPath) {
        let symbol = collectionView === symbolGrid
        let text = symbol ? allSymbols[indexPath.item] : choices[indexPath.item].text
        cell.pressBegan = { [weak self, weak collectionView] in
            (collectionView as? CandidateCollectionView)?.markControlEvent()
            self?.pauseCandidateRankingForInteraction()
            self?.railPressFeedback()
        }
        cell.label.centersVisibleGlyphs = symbol
        cell.label.text = text; cell.emphasizes = !symbol && indexPath.item == 0; cell.accessibilityLabel = text
        cell.accessibilityIdentifier = (symbol ? "symbol-" : "key-") + text
        cell.accessibilityValue = symbol ? nil : String(indexPath.item)
        cell.accessibilityHint = symbol ? nil : choices[indexPath.item].comment + (choices[indexPath.item].replacementInput != nil ? "，近键纠错候选" : "") + (!english && engine.isPinned(choices[indexPath.item]) ? "，已置顶" : "") + (!english && engine.canManage(choices[indexPath.item]) ? "，长按管理候选" : "")
        cell.normalBackground = .clear
        cell.applyTheme()
        cell.label.numberOfLines = collectionView === grid ? 0 : 1
        let latin=text.utf8.allSatisfy{(65...90).contains($0) || (97...122).contains($0)}
        cell.label.lineBreakMode = collectionView === grid ? .byWordWrapping:(latin ? .byClipping:.byTruncatingTail)
        cell.label.textAlignment = collectionView === grid && (text as NSString).size(withAttributes:[.font:CandidateListLayout.font(at:indexPath.item,traits:collectionView.traitCollection)]).width+20>max(1,collectionView.bounds.width/2) ? .left:.center
        cell.label.font = symbol ? .systemFont(ofSize:20):CandidateListLayout.font(at:indexPath.item,traits:collectionView.traitCollection)
        if symbol || english {cell.contextMenuProvider=nil}
        else {
            let choice=choices[indexPath.item],revision=engine.revision
            cell.contextMenuProvider = { [weak self, weak collectionView] in
                (collectionView as? CandidateCollectionView)?.markControlEvent()
                return self?.candidateMenu(for:choice,revision:revision)
            }
        }
        if symbol {
            cell.controlTouchBegan = nil; cell.controlTouchEnded = nil
            cell.activate = { [weak self, weak collectionView] in
                (collectionView as? CandidateCollectionView)?.markControlEvent()
                self?.insertSymbol(text)
            }
        } else {
            let choice = choices[indexPath.item],revision=engine.revision
            cell.controlTouchBegan = { [weak self] in self?.diagnosticCandidatePress(choice, rank: indexPath.item) }
            cell.controlTouchEnded = { [weak self] accepted in self?.diagnosticCandidateRelease(choice, accepted: accepted);self?.resumeCandidatePageAfterInteraction() }
            cell.activate = { [weak self, weak collectionView] in
                guard let self,self.engine.revision==revision else{return}
                (collectionView as? CandidateCollectionView)?.markControlEvent()
                self.choose(choice)
            }
        }
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        #if targetEnvironment(simulator)
        NSLog("CANDIDATE_TOUCH selected index=%d revision=%d shown=%d",indexPath.item,engine.revision,lastRevision)
        #endif
        collectionView.deselectItem(at: indexPath, animated: false)
        if (collectionView as? CandidateCollectionView)?.isHandlingControlEvent == true {return}
        if let cell=collectionView.cellForItem(at:indexPath) as? CandidateCell,cell.isHandlingControlTouch {return}
        if collectionView === symbolGrid {
            guard let cell=collectionView.cellForItem(at:indexPath) as? CandidateCell else { return };cell.activate?()
        } else {
            // Use the displayed cell's bound candidate, just like VoiceOver.
            // A model refresh must not redirect an already visible tap through
            // a newer array at the same index path.
            guard let cell=collectionView.cellForItem(at:indexPath) as? CandidateCell else { return }
            cell.activate?()
        }
    }
    func collectionView(_ collectionView:UICollectionView, shouldHighlightItemAt indexPath:IndexPath) -> Bool {
        #if targetEnvironment(simulator)
        NSLog("CANDIDATE_TOUCH should-highlight index=%d",indexPath.item)
        #endif
        pauseCandidateRankingForInteraction()
        return true
    }
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        if let cell=collectionView.cellForItem(at:indexPath) as? CandidateCell,cell.isHandlingControlTouch {return}
        pauseCandidateRankingForInteraction()
        if currentFeedback == "strong" { strongImpact.impactOccurred(intensity: 0.8) }
        else if currentFeedback == "light" { lightImpact.impactOccurred(intensity: 0.5) }
    }
    private func candidateMenu(for choice:InputCandidate,revision:Int)->UIMenu? {
        guard !english,engine.revision==revision,engine.canManage(choice) else{return nil}
        pauseCandidateRankingForInteraction()
        let pinned=engine.isPinned(choice)
        return UIMenu(children:[
            UIAction(title:pinned ? "取消置顶":"候选置顶",image:UIImage(systemName:pinned ? "pin.slash":"pin")) { [weak self] _ in self?.manageCandidate(choice,revision:revision,pinned:!pinned) },
            UIAction(title:"恢复默认词频",image:UIImage(systemName:"arrow.counterclockwise")) { [weak self] _ in self?.manageCandidate(choice,revision:revision,pinned:nil) }
        ])
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = max(collectionView.bounds.width - (collectionView === grid ? 48 : 0), 1)
        if collectionView === symbolGrid { return CGSize(width: floor(max(1,width-12) / 4), height: 44) }
        let text = choices[indexPath.item].text as NSString
        let needed = text.size(withAttributes: [.font: CandidateListLayout.font(at:indexPath.item,traits:collectionView.traitCollection)]).width + 24
        if collectionView === strip {
            let latin=(text as String).utf8.allSatisfy{(65...90).contains($0) || (97...122).contains($0)}
            let ceiling=latin ? max(320,collectionView.bounds.width*2):max(120,collectionView.bounds.width*0.85)
            return CGSize(width: min(max(48,ceil(needed)),ceiling), height: max(1,collectionView.bounds.height))
        }
        let slot = floor(width / 4), span = min(4, max(1, ceil(needed / max(slot, 1))))
        let cellWidth = slot * span, lines = max(1, ceil(needed / max(cellWidth - 16, 1)))
        return CGSize(width: cellWidth, height: min(4, lines) * 44)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        #if targetEnvironment(simulator)
        (scrollView as? CandidateCollectionView)?.reportScroll()
        #endif
        guard !loading, scrollView.bounds.width > 1, scrollView.bounds.height > 1 else { return }
        guard scrollView.isDragging || scrollView.isDecelerating else{return}
        if scrollView === strip && !expanded && scrollView.contentOffset.x + scrollView.bounds.width > scrollView.contentSize.width - 160 { requestCandidatePage() }
        if scrollView === grid && expanded && scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 160 { requestCandidatePage() }
    }
    func scrollViewWillBeginDragging(_ scrollView:UIScrollView) {
        if scrollView === strip || scrollView === grid {dismissCandidateMenus()}
        #if targetEnvironment(simulator)
        (scrollView as? CandidateCollectionView)?.reportScroll(began: true)
        #endif
        if scrollView === strip || scrollView === grid { pauseCandidateRankingForInteraction() }
    }
    func scrollViewDidEndDragging(_ scrollView:UIScrollView,willDecelerate decelerate:Bool) {
        if !decelerate && (scrollView === strip || scrollView === grid) {resumeCandidatePageAfterInteraction()}
    }
    func scrollViewDidEndDecelerating(_ scrollView:UIScrollView) {
        if scrollView === strip || scrollView === grid {resumeCandidatePageAfterInteraction()}
    }
    override func textWillChange(_ textInput: UITextInput?) { super.textWillChange(textInput);if keyboardAppeared {noteClipboardInput()};applyPreferences() }
    override func textDidChange(_ textInput: UITextInput?) { super.textDidChange(textInput);observeSymbolPairContext(); ActivityArchiveCapture.shared.refresh(permitted:hasFullAccess); synchronizeAppearance();applyPreferences(); render() }
    override func selectionDidChange(_ textInput:UITextInput?) {
        super.selectionDidChange(textInput)
        observeSymbolPairContext()
        if inlineComposition.active && !inlineComposition.applying,let selected=textDocumentProxy.selectedText,!selected.isEmpty,selected != inlineComposition.draft {
            #if targetEnvironment(simulator)
            NSLog("INLINE_END selection selected=%d draft=%d",selected.utf16.count,inlineComposition.draft.utf16.count)
            #endif
            inlineComposition.leave(host:compositionHost);engine.clear();expanded=false;ownCommitTracker.invalidate();engine.resetPredictionContext()
        }
        validateInlineContext()
        render()
    }
    private func refreshLearning(explicit: Bool,preparation:LearningRefreshPreparation? = nil,hiddenToken:UInt64? = nil) {
        if explicit {
            // The menu may request work while visible, but cannot run a native
            // session teardown under the next input/expand touch.
            learningRefreshPending=true;learningRefreshFailures=0
            learningStatus="收起键盘后更新词库";loadSystemWords();render();return
        }
        guard let hiddenToken,permitsHiddenLearning(hiddenToken) else{return}
        guard let preparation else { return }
        let generation = learningWorkGeneration, presentation = keyboardPresentation, fullAccess = hasFullAccess
        let processPresentation = Self.learningPresentationFence.generation
        engine.synchronizeHiddenLearning(publish: learningPublisher, preparation: preparation, diagnosticOwner: learningDiagnosticOwner,
            mayCommit: { [weak self] in
                guard let self else { return false }
                return Self.learningPresentationFence.permits(processPresentation) &&
                    self.learningWorkGeneration == generation && self.keyboardPresentation == presentation &&
                    self.hasFullAccess == fullAccess && self.permitsHiddenLearning(hiddenToken)
            }, completion: { [self] result in
                // Native and utility phases have separate admission. Keep this
                // owner until durable IO finish/publication, never cancelling it
                // merely because UIKit releases an old controller,
                // rather than losing the result on normal UIKit teardown.
                // A new presentation, input, reset, consent/file change still
                // cancels through the original guards plus the process fence.
                guard Self.learningPresentationFence.permits(processPresentation), self.learningWorkGeneration == generation,
                      self.keyboardPresentation == presentation else { return }
                switch result {
                case .success(let completed):
                    self.learningRefreshPending = !completed; self.learningRefreshFailures = 0
                    if completed { self.learningStatus = "词库已更新" }
                case .failure(LearningSyncFailure.busy), .failure(SnapshotStoreError.busy):
                    break // Expected contention/cancellation retains work for a later dismissal.
                case .failure:
                    self.learningRefreshFailures += 1; self.learningStatus = "词库更新失败，可重试"
                }
                if self.keyboardAppeared { self.render() }
            })
    }
    deinit { clipboardTimer?.invalidate();for observer in clipboardObservers {NotificationCenter.default.removeObserver(observer)};if let privacyResetObserver {PersonalDataReset.unobserve(privacyResetObserver)};deferredLearningRefresh?.cancel();deleteDelay?.invalidate(); deleteRepeat?.invalidate(); if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) } }
}
