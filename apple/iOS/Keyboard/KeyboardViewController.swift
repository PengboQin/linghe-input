import UIKit
import PrivateInputKit
import CryptoKit
import OSLog

private struct KeyboardCompositionHost: InlineCompositionHost {
    let proxy: UITextDocumentProxy
    let compositionDocument: UUID?
    var compositionBefore:String? { proxy.documentContextBeforeInput }
    var compositionAfter:String? { proxy.documentContextAfterInput }
    var compositionSelection:String? { proxy.selectedText }
    func markComposition(_ text:String,selection:NSRange) { proxy.setMarkedText(text,selectedRange:selection) }
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
    private var compositionPosition = KeyboardPreferences.compositionPosition
    private var sharedCompositionPosition = UserDefaults.standard.string(forKey:"last-shared-composition-position") ?? KeyboardPreferences.compositionPosition
    private var compositionHost:KeyboardCompositionHost { .init(proxy:textDocumentProxy,compositionDocument:documentID) }
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
    private let root = UIStackView()
    private let header = UIView()
    private var headerHeight:NSLayoutConstraint!
    private var candidateTop:NSLayoutConstraint!
    private var letterActionButton:UIButton?
    private let preeditRow = UIView()
    private let preeditScroll = UIScrollView()
    private let composition = UILabel()
    private var expandTop: NSLayoutConstraint!
    private var gridTop: NSLayoutConstraint!
    private var preeditTrailing: NSLayoutConstraint!
    private var preeditHeight: NSLayoutConstraint!
    private var footerHeight: NSLayoutConstraint!
    private var expandHeight:NSLayoutConstraint!
    private var geometrySize = CGSize.zero
    private var geometryCompact = false
    private var heightConstraint: NSLayoutConstraint!
    private var heightExtra = KeyboardHeight.defaultExtra
    private var persistedHeightExtra: Double?
    private var sharedHeightExtra = UserDefaults.standard.object(forKey:"last-shared-height-extra") as? Double ?? KeyboardPreferences.keyboardHeightExtra
    private var sharedHeightRevision = UserDefaults.standard.string(forKey:"last-shared-height-revision")
    private let heightAdjustment = KeyboardHeightAdjustmentView()
    private var adjustingHeight = false
    private let candidateBar = UIStackView()
    private let clipboardCandidate=ClipboardPasteCandidateView()
    private var clipboardState=ClipboardCandidateState()
    private var clipboardKnown:ClipboardCandidatePresentation.Snapshot?
    private var clipboardCacheRequest:ClipboardCandidateState.Request?
    private var clipboardCacheAttempts=0
    private var clipboardCacheVersion:Int?
    private var clipboardCacheScope:String?
    private var clipboardCacheGeneration:String?
    private var clipboardCacheToken:UUID?

    private let expand = CandidateExpansionButton(type: .custom)
    private let toolbar = UIStackView()
    private let settingsButton = UIButton(type: .system)
    private weak var languageButton:UIButton?
    private var menuSignature=""
    private let keys = UIStackView()
    private let keyboardBody = UIStackView()
    private let footer = UIStackView()
    private let sharedTextPanel = SharedTextPanel()
    private var systemRefreshRequested=false
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
    private var sharedTextRefreshTask:Task<Void,Never>?
    private var sharedTextRefreshPending=false
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
            guard let self,!self.sharedTextPanel.isShowing else { return nil }
            if self.expanded { return self.scrollSurfaceHit(self.grid, point: point, event: event, excluding: [self.expand]) }
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
        super.viewDidLoad()
        loadSymbolUsage()
        privacyResetObserver=PersonalDataReset.observe {[weak self] in
            guard let self else {return}
            self.symbolUsage=SymbolUsage();self.symbolUsageWritable=true
            UserDefaults.standard.removeObject(forKey:"symbol-usage-v1")
            self.refreshSymbolPage();self.symbolGrid.reloadData()
        }
        let checker=englishChecker
        engine = NativeEngine(retainPredictionProbe: true,mixedEnglishProvider: { prefix in
            guard UITextChecker.availableLanguages.contains("en_US") else { return [] }
            let range=NSRange(location:0,length:prefix.utf16.count)
            var words:[String]=[]
            if checker.rangeOfMisspelledWord(in:prefix,range:range,startingAt:0,wrap:false,language:"en_US").location==NSNotFound { words.append(prefix) }
            words += checker.completions(forPartialWordRange:range,in:prefix,language:"en_US") ?? []
            words += checker.guesses(forWordRange:range,in:prefix,language:"en_US") ?? []
            return words
        })
        KeyboardPreferences.observeUpdates()
        preferenceObserver = NotificationCenter.default.addObserver(forName: KeyboardPreferences.updated, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.synchronizeAppearance(); self.preferencesPending = true; self.applyPreferences()
        }
        inputView?.allowsSelfSizing = true
        heightExtra = KeyboardHeight.normalized(UserDefaults.standard.object(forKey:"local-height-extra") as? Double ?? KeyboardPreferences.keyboardHeightExtra)
        persistedHeightExtra=heightExtra
        heightConstraint = view.heightAnchor.constraint(equalToConstant: (inputView as? KeyboardInputView)?.contentHeight ?? desiredKeyboardHeight(width:UIScreen.main.bounds.width))
        heightConstraint.priority = .init(999); heightConstraint.isActive = true
        view.backgroundColor = .clear;view.isOpaque=false
        root.axis = .vertical; root.spacing = 0; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4), root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)])
        header.translatesAutoresizingMaskIntoConstraints=false;header.accessibilityIdentifier="keyboard-header";root.addArrangedSubview(header)
        headerHeight=header.heightAnchor.constraint(equalToConstant:60);headerHeight.isActive=true
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
        NSLayoutConstraint.activate([candidateTop,candidateBar.bottomAnchor.constraint(equalTo:header.bottomAnchor),candidateBar.leadingAnchor.constraint(equalTo:header.leadingAnchor),candidateBar.trailingAnchor.constraint(equalTo:header.trailingAnchor)])
        strip.accessibilityIdentifier = "candidate-strip"; grid.accessibilityIdentifier = "candidate-list"
        candidateBar.addArrangedSubview(strip)
        expand.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expand.addTarget(self, action: #selector(pauseCandidateRankingForInteraction), for: .touchDown)
        expand.accessibilityIdentifier = "expand-candidates"; expand.accessibilityLabel = "展开全部候选"
        expand.addAction(UIAction { [weak self] _ in
            guard let self, !self.choices.isEmpty else { return }
            self.setCandidatesExpanded(!self.expanded)
        }, for: .touchUpInside)
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
        clipboardCandidate.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(clipboardCandidate)
        NSLayoutConstraint.activate([clipboardCandidate.leadingAnchor.constraint(equalTo:header.leadingAnchor),clipboardCandidate.trailingAnchor.constraint(equalTo:header.trailingAnchor),clipboardCandidate.topAnchor.constraint(equalTo:header.topAnchor),clipboardCandidate.bottomAnchor.constraint(equalTo:header.bottomAnchor)])
        clipboardCandidate.isHidden=true
        clipboardCandidate.interactionBegan = { [weak self] in self?.cancelLearningForInteraction() }
        clipboardCandidate.requestForNativePress = { [weak self] in self?.clipboardRequest() }
        clipboardCandidate.providers = { [weak self] providers,request in self?.pasteClipboardProviders(providers,request:request) }
        clipboardCandidate.insertKnown = { [weak self] snapshot in
            self?.insertClipboardText(snapshot.text,request:snapshot.request)
        }

        heightAdjustment.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heightAdjustment)
        NSLayoutConstraint.activate([heightAdjustment.leadingAnchor.constraint(equalTo:header.leadingAnchor),heightAdjustment.trailingAnchor.constraint(equalTo:header.trailingAnchor),heightAdjustment.topAnchor.constraint(equalTo:header.topAnchor),heightAdjustment.bottomAnchor.constraint(equalTo:header.bottomAnchor)])
        heightAdjustment.isHidden = true
        heightAdjustment.change = { [weak self] value, persist in self?.configureHeight(value,persist:persist) }
        heightAdjustment.done = { [weak self] in self?.finishHeightAdjustment() }
        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.accessibilityLabel = "键盘设置"; settingsButton.accessibilityIdentifier = "keyboard-settings"
        settingsButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        settingsButton.showsMenuAsPrimaryAction = true
        toolbar.addArrangedSubview(settingsButton)
        let shared = UIButton(type: .system); shared.setImage(UIImage(systemName: "clipboard"), for: .normal)
        shared.accessibilityLabel = "共享文本"; shared.accessibilityIdentifier = "open-shared-text"
        shared.widthAnchor.constraint(equalToConstant: 40).isActive = true
        shared.heightAnchor.constraint(equalToConstant: 44).isActive = true
        shared.addAction(UIAction { [weak self] _ in self?.openSharedText() }, for: .touchUpInside)
        toolbar.addArrangedSubview(shared)
        let status = UILabel(); status.font = .systemFont(ofSize: 13); status.textColor = InputThemeColors.secondary; status.accessibilityIdentifier = "learning-status"
        toolbar.addArrangedSubview(status)
        // Keep the normal keyboard in Auto Layout while the candidate list
        // covers it. Removing it lets UIKit self-fit an almost zero-height
        // collection view, turning a swipe into a candidate tap.
        grid.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(grid)
        gridTop=grid.topAnchor.constraint(equalTo:root.topAnchor)
        NSLayoutConstraint.activate([gridTop,grid.leadingAnchor.constraint(equalTo:root.leadingAnchor),grid.trailingAnchor.constraint(equalTo:root.trailingAnchor),grid.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        keys.axis = .horizontal; keys.spacing = 4; keys.distribution = .fill
        keyboardBody.axis = .vertical; keyboardBody.spacing = 4; keyboardBody.accessibilityIdentifier = "keyboard-body"
        footer.axis = .horizontal; footer.spacing = 4; footerHeight=footer.heightAnchor.constraint(equalToConstant:44);footerHeight.priority = .init(999);footerHeight.isActive=true
        keyboardBody.addArrangedSubview(keys); keyboardBody.addArrangedSubview(footer); root.addArrangedSubview(keyboardBody)
        addChild(sharedTextPanel);sharedTextPanel.view.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(sharedTextPanel.view)
        NSLayoutConstraint.activate([sharedTextPanel.view.leadingAnchor.constraint(equalTo: root.leadingAnchor), sharedTextPanel.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), sharedTextPanel.view.topAnchor.constraint(equalTo: root.topAnchor), sharedTextPanel.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        sharedTextPanel.didMove(toParent:self)
        sharedTextPanel.select = { [weak self] id in self?.insertSharedText(id) }
        sharedTextPanel.refresh = { [weak self] in self?.openSharedText() }
        sharedTextPanel.didDismiss = { [weak self] in self?.render() }
        sharedTextPanel.availabilityIssue = { [weak self] in
            guard let self else { return "共享文本暂不可用" }
            guard self.hasFullAccess else { return "请允许完全访问，再使用共享文本。" }
            return ClipboardCacheCoordinator.permitted(fullAccess:true) ? nil:"共享文本已暂停，请在主 App 开启。"
        }
        chineseLayout = configuredChineseLayout()
        english = startEnglish; layout = english ? .letters : chineseLayout
        _ = engine.nineKey(!english && chineseLayout == .nine); _ = engine.switchToEnglish(english)
        synchronizeAppearance();updateKeyboardGeometry(); buildKeys(); render()
        if KeyboardPreferences.systemLexicon { loadSystemWords() }
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
        let header:CGFloat=adjustingHeight ? 64:(compact ? 62:64)
        if headerHeight?.constant != header {headerHeight?.constant=header}
        let preedit:CGFloat=compact ? 18:20
        if preeditHeight?.constant != preedit {preeditHeight?.constant=preedit}
        heightAdjustment.compact=compact
        if !adjustingHeight {heightAdjustment.update(heightExtra)}
        if candidateTop != nil { updateHeaderFrames() }
        if changed { [strip,grid,symbolGrid].forEach{$0.collectionViewLayout.invalidateLayout()} }
    }
    private func configureHeight(_ value:Double,persist:Bool = true) {
        let normalized=KeyboardHeight.normalized(value),changed=heightExtra != normalized
        guard changed || persist else{return}
        heightExtra=normalized
        if persist,persistedHeightExtra != heightExtra {
            if hasFullAccess {
                sharedHeightExtra=heightExtra
                UserDefaults.standard.set(heightExtra,forKey:"last-shared-height-extra")
                UserDefaults.standard.removeObject(forKey:"local-height-extra")
                KeyboardPreferences.keyboardHeightExtra=heightExtra
                sharedHeightRevision=KeyboardPreferences.keyboardHeightRevision
                UserDefaults.standard.set(sharedHeightRevision,forKey:"last-shared-height-revision")
            } else { UserDefaults.standard.set(heightExtra,forKey:"local-height-extra") }
            persistedHeightExtra=heightExtra
        }
        if persist {heightAdjustment.update(heightExtra)}
        if changed {updateKeyboardGeometry();view.setNeedsLayout()}
        if persist {refreshSettingsMenus()}
    }
    private func beginHeightAdjustment() {
        expanded=false;adjustingHeight=true;heightAdjustment.update(heightExtra);updateKeyboardGeometry();render()
    }
    private func finishHeightAdjustment() {
        configureHeight(heightExtra);adjustingHeight=false;updateKeyboardGeometry();render()
    }
    private func updateHeaderFrames() {
        let top=preeditRow.isHidden ? 0:preeditHeight.constant
        candidateTop.constant=top;expandTop.constant=top;gridTop.constant=top
        expandHeight.constant=max(44,headerHeight.constant-top)
        (grid.collectionViewLayout as? CandidateListLayout)?.controlHeight=expandHeight.constant
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
                    if self.systemRefreshRequested { self.systemRefreshRequested=false;self.learningStatus="词库已更新" };self.render()
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
        super.viewWillAppear(animated);keyboardPresentation &+= 1;keyboardAppeared=false;learningRefreshPending=true;learningRefreshFailures=0;pressedKeyboardControls.removeAll();synchronizeAppearance();applyPreferences()
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
        super.viewDidAppear(animated);keyboardAppeared=true;scheduleLearningAfterReveal();refreshAutomaticClipboard()
        clipboardTimer?.invalidate()
        let clipboardTick=Timer(timeInterval:1,repeats:true) { [weak self] _ in
            guard let self,self.keyboardAppeared,self.viewIfLoaded?.window != nil else{return}
            self.refreshAutomaticClipboard()
        }
        clipboardTimer=clipboardTick;RunLoop.main.add(clipboardTick,forMode:.common)
        for observer in clipboardObservers {NotificationCenter.default.removeObserver(observer)};clipboardObservers=[]
        for name in [Notification.Name.clipboardLiveUpdated,UIPasteboard.changedNotification] {
            clipboardObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                guard let self,self.keyboardAppeared,self.viewIfLoaded?.window != nil else{return}
                self.refreshAutomaticClipboard()
                if self.sharedTextPanel.isShowing {self.refreshVisibleSharedText()}
            })
        }
        archiveTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.view.window != nil else { return }
            ActivityArchiveCapture.shared.refresh(permitted: self.hasFullAccess)
            if self.hasFullAccess { ActivityArchiveCapture.shared.observeClipboardIfPermitted() };self.refreshAutomaticClipboard()
        }
        archiveTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func refreshAutomaticClipboard() {
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
                String(p?.bool(forKey:"automatic-clipboard-read-paused")==true)].joined(separator:"|")
    }
    private var clipboardAllowed:Bool {
        guard keyboardAppeared,viewIfLoaded?.window != nil,hasFullAccess,documentID != nil,
              textDocumentProxy.isSecureTextEntry == false,!adjustingHeight,!expanded,!sharedTextPanel.isShowing else{return false}
        let board=UIPasteboard.general
        let excluded=["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType","org.nspasteboard.AutoGeneratedType"]
        return board.numberOfItems==1 && board.hasStrings && !board.types.contains(where:excluded.contains)
    }
    private func clipboardRequest()->ClipboardCandidateState.Request? {
        guard let document=documentID else{return nil}
        return .init(version:UIPasteboard.general.changeCount,document:document,presentation:keyboardPresentation,
                     deletion:deletionPrediction.generation,scope:clipboardScope)
    }
    private func acceptsClipboard(_ request:ClipboardCandidateState.Request)->Bool {
        clipboardState.accepts(request,current:clipboardRequest(),allowed:clipboardAllowed,
                               hasPrimary:clipboardHasPrimary,deleting:deletionPrediction.suppressed)
    }
    private func updateClipboardCandidateVisibility() {
        let version=UIPasteboard.general.changeCount
        clipboardState.observe(version:version)
        let visible=clipboardState.available(version:version,allowed:clipboardAllowed,
                    hasPrimary:clipboardHasPrimary,deleting:deletionPrediction.suppressed)
        if let known=clipboardKnown,!acceptsClipboard(known.request) {clipboardKnown=nil}
        let wasVisible = !clipboardCandidate.isHidden
        clipboardCandidate.isHidden = !visible
        guard visible else {
            if wasVisible {
                let pending = !engine.preedit.isEmpty || !choices.isEmpty
                preeditRow.isHidden=engine.preedit.isEmpty || inlineComposition.active
                candidateBar.isHidden = !pending || adjustingHeight
                toolbar.isHidden=pending || adjustingHeight
                expand.isHidden = !pending || choices.isEmpty || adjustingHeight
            }
            return
        }
        clipboardCandidate.show(snapshot:clipboardKnown,request:clipboardRequest())
        preeditRow.isHidden=true;candidateBar.isHidden=true;toolbar.isHidden=true;expand.isHidden=true
        header.bringSubviewToFront(clipboardCandidate)
    }
    private func refreshClipboardCandidateCache() {
        let version=UIPasteboard.general.changeCount
        clipboardState.observe(version:version)
        let scopeFingerprint=clipboardScope,cacheFingerprint=clipboardCacheFingerprint
        if clipboardCacheVersion != version || clipboardCacheScope != scopeFingerprint {
            clipboardCacheVersion=version;clipboardCacheScope=scopeFingerprint;clipboardCacheAttempts=0
            clipboardKnown=nil;clipboardCacheRequest=nil;clipboardCacheToken=nil
        }
        if clipboardCacheGeneration != cacheFingerprint {
            clipboardCacheGeneration=cacheFingerprint;clipboardCacheAttempts=0;clipboardCacheRequest=nil;clipboardCacheToken=nil
        }
        updateClipboardCandidateVisibility()
        guard let request=clipboardRequest(),acceptsClipboard(request),clipboardKnown==nil,
              clipboardCacheRequest==nil,clipboardCacheAttempts<3,
              ClipboardCacheCoordinator.permitted(fullAccess:hasFullAccess) else{return}
        let prefs=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
        guard prefs?.bool(forKey:"automatic-clipboard-enabled")==true,
              prefs?.bool(forKey:"automatic-clipboard-read-paused") != true,
              let scope=prefs?.string(forKey:"automatic-clipboard-scope"),!scope.isEmpty else{return}
        let cacheToken=UUID();clipboardCacheToken=cacheToken;clipboardCacheRequest=request;clipboardCacheAttempts+=1
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let now=UInt64(Date().timeIntervalSince1970)
            let preferences=UserDefaults(suiteName:LocalLearningCoordinator.groupID)
            let consent=ClipboardCacheCoordinator.permitted(fullAccess:true) && preferences?.bool(forKey:"automatic-clipboard-enabled")==true &&
                preferences?.bool(forKey:"automatic-clipboard-read-paused") != true && preferences?.string(forKey:"automatic-clipboard-scope")==scope
            var text:String?
            if consent {text=(try? ClipboardCacheCoordinator.pendingAutomatic(scope:scope,version:version,now:now))?.text}
            if consent,text==nil,let clips=try? ClipboardCacheCoordinator.read(fullAccess:true,now:now) {
                text=clips.first(where:{clip in
                    guard let origin=AutomaticClipboardOrigin.receivedOrigin(version:version,text:clip.text) else{return false}
                    return origin.event==clip.eventID && origin.sender==clip.sender
                })?.text
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.clipboardCacheRequest==request,self.clipboardCacheToken==cacheToken else{return}
                self.clipboardCacheRequest=nil
                guard self.acceptsClipboard(request),let text,ClipboardCandidateState.validText(text) else{return}
                self.clipboardKnown = .init(request:request,text:text);self.updateClipboardCandidateVisibility()
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
        guard acceptsClipboard(request),ClipboardCandidateState.validText(text) else{return}
        clipboardState.dismiss();clipboardKnown=nil;clipboardCacheRequest=nil
        resumeAutomaticPredictionForUserInput();cancelPrediction();cancelCandidatePage()
        ownCommitTracker.invalidate();engine.resetPredictionContext()
        // Preview compaction never changes the exact inserted text.
        textDocumentProxy.insertText(text);archiveOutput(text,systemPaste:true)
        expanded=false;publishedCandidates.reset();lastRevision = -1;render()
    }
    private func cancelLearningForInteraction() {
        learningWorkGeneration &+= 1;deferredLearningRefresh?.cancel();deferredLearningRefresh=nil
    }
    private var learningRefreshWindowAvailable:Bool {
        keyboardAppeared && !expanded && !adjustingHeight && choices.isEmpty && pressedKeyboardControls.isEmpty &&
        (layout == .nine || layout == .letters) &&
        !strip.isTracking && !grid.isTracking && !strip.isDragging && !grid.isDragging &&
        !strip.isDecelerating && !grid.isDecelerating && !expand.isTracking && !clipboardCandidate.isTrackingPaste
    }
    private func scheduleLearningAfterReveal() {
        guard learningRefreshWindowAvailable,learningRefreshPending,learningRefreshFailures<3,deferredLearningRefresh == nil,learningPreparationID == nil,engine != nil,engine.ready,
              engine.rawInput.isEmpty,engine.preedit.isEmpty else{return}
        let presentation=keyboardPresentation,revision=engine.revision,generation=learningWorkGeneration
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.learningWorkGeneration==generation,self.keyboardPresentation==presentation else{return}
            self.deferredLearningRefresh=nil
            guard self.learningRefreshPending,self.learningRefreshWindowAvailable,self.view.window != nil,
                  self.engine.revision==revision,self.engine.rawInput.isEmpty,self.engine.preedit.isEmpty else {self.scheduleLearningAfterReveal();return}
            // Still a serialized main-thread checkpoint, not background work.
            // Wait for an actual quiet window; any input cancels the pending job.
            self.prepareIdleLearningRefresh(presentation:presentation,revision:revision,generation:generation)
        }
        deferredLearningRefresh=work;DispatchQueue.main.asyncAfter(deadline:.now()+1.5,execute:work)
    }
    private func prepareIdleLearningRefresh(presentation:UInt64,revision:Int,generation:UInt64) {
        let identifier=UUID();learningPreparationID=identifier
        engine.prepareLearningRefresh(publish:learningPublisher) { [weak self] preparation in
            guard let self,self.learningPreparationID==identifier else{return}
            self.learningPreparationID=nil
            guard self.keyboardPresentation==presentation,self.learningWorkGeneration==generation,
                  self.learningRefreshPending,self.learningRefreshWindowAvailable,self.view.window != nil,
                  self.engine.revision==revision,self.engine.rawInput.isEmpty,self.engine.preedit.isEmpty,
                  self.engine.isCurrentLearningRefreshPreparation(preparation,publish:self.learningPublisher) else {
                self.scheduleLearningAfterReveal();return
            }
            self.refreshLearning(explicit:false,preparation:preparation)
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
            sharedTextPanel.applyTheme()
            view.tintColor = InputThemeColors.accent
            composition.textColor = InputThemeColors.secondary
            toolbar.tintColor = InputThemeColors.accent
            for label in toolbar.arrangedSubviews.compactMap({ $0 as? UILabel }) { label.textColor = InputThemeColors.secondary }
            var style = expand.configuration
            style?.baseForegroundColor = InputThemeColors.accent
            expand.configuration = style; expand.tintColor = InputThemeColors.accent
            expand.setNeedsUpdateConfiguration()
            heightAdjustment.applyTheme()
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
        dismissCandidateMenus()
        archiveTimer?.invalidate(); archiveTimer = nil
        clipboardTimer?.invalidate();clipboardTimer=nil
        sharedTextRefreshTask?.cancel();sharedTextRefreshTask=nil;sharedTextRefreshPending=false
        for observer in clipboardObservers {NotificationCenter.default.removeObserver(observer)};clipboardObservers=[]
        ActivityArchiveCapture.shared.suspendNetwork()
        keyboardPresentation &+= 1;keyboardAppeared=false;deferredLearningRefresh?.cancel();deferredLearningRefresh=nil
        clipboardCacheRequest=nil;clipboardCacheToken=nil;clipboardKnown=nil;clipboardCandidate.isHidden=true
        ClipboardCacheCoordinator.automaticKeyboardPass(fullAccess:false,sensitive:true,validating:{false})
        #if targetEnvironment(simulator)
        if inlineComposition.active { NSLog("INLINE_END disappearing draft=%d",inlineComposition.draft.utf16.count) }
        #endif
        if inlineComposition.active { inlineComposition.leave(host:compositionHost);engine.clear();expanded=false }
        if adjustingHeight { configureHeight(heightExtra);adjustingHeight=false }
        cancelCandidatePage();cancelPrediction();ownCommitTracker.invalidate();engine.resetPredictionContext();cursorActive = false; keys.alpha = 1; stopDeletion(); sharedTextPanel.dismissPanel(); super.viewWillDisappear(animated)
    }
    private func configuredChineseLayout() -> Layout {
        let shared = KeyboardPreferences.chineseLayout
        if shared != sharedLayout { UserDefaults.standard.removeObject(forKey: "local-chinese-layout"); sharedLayout = shared }
        return (UserDefaults.standard.string(forKey: "local-chinese-layout") ?? shared) == "pinyin26" ? .letters : .nine
    }
    private func applyPreferences() {
        guard engine != nil, engine.preedit.isEmpty, !adjustingHeight else { return }
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
        guard menuSignature != signature || settingsButton.menu==nil else { return }
        menuSignature=signature
        let menu=settingsMenu();settingsButton.menu=menu;languageButton?.menu=menu
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
        let heights = KeyboardHeight.presets.map { preset in UIAction(title:preset.title,state:heightExtra==preset.extra ? .on:.off) { [weak self] _ in self?.configureHeight(preset.extra) } }
        let adjust = UIAction(title:"拖动微调…",image:UIImage(systemName:"arrow.up.and.down")) { [weak self] _ in self?.beginHeightAdjustment() }
        let access=UIAction(title:hasFullAccess ? "完全访问已开启":"完全访问未开启",image:UIImage(systemName:hasFullAccess ? "checkmark.shield":"shield"),attributes:.disabled) {_ in}
        let permissionHelp=UIMenu(title:"权限说明",children:[
            UIAction(title:"基础打字与本机纠错可用",attributes:.disabled) {_ in},
            UIAction(title:"共享设置和文本需完全访问",attributes:.disabled) {_ in},
            UIAction(title:"在主 App 查看开启方法",attributes:.disabled) {_ in},
            UIAction(title:"返回键盘") { [weak self] _ in self?.render() }
        ])
        return UIMenu(children: [UIMenu(title:"权限",children:[access,permissionHelp]),UIMenu(title:"布局与显示",children:layouts+[UIMenu(title:"键盘高度",children:heights+[adjust]),UIMenu(title:"拼音显示位置",children:positions)]), UIMenu(title:"词库与联想",children:[mixed,remember,refresh]), UIMenu(title:"按键触感",children:feedback)])
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
            else {self.pressedKeyboardControls.remove(ObjectIdentifier(key))}
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
            else if !self.english && !self.engine.preedit.isEmpty && !self.choices.isEmpty { self.choose(self.choices[0]) }
            else { self.type(" ") }
        }; space.titleLabel?.font = .systemFont(ofSize: 16); space.setContentHuggingPriority(.defaultLow, for: .horizontal); aligned.insertArrangedSubview(space, at: 1)
        if layout != .numbers {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
            gesture.minimumPressDuration = 0.35; gesture.allowableMovement = 14; gesture.cancelsTouchesInView = true
            space.addGestureRecognizer(gesture); space.accessibilityHint = "按住后左右滑动移动光标"
        }
        if layout == .letters {
            let action=button("清空") { [weak self] in
                guard let self else { return };self.stopDeletion()
                self.engine.clear();self.render()
            }
            action.titleLabel?.font = .systemFont(ofSize:15)
            action.menu=UIMenu(children:[UIAction(title:"收起键盘",image:UIImage(systemName:"keyboard.chevron.compact.down")) { [weak self] _ in self?.dismissKeyboard() }])
            letterActionButton=action;numberSlot.addArrangedSubview(action)
        } else {
        let right = UIStackView(); right.axis = .vertical; right.spacing = 4; right.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let actions = stack(.vertical)
        let delete = button("⌫") {}; delete.accessibilityLabel = "删除"; delete.accessibilityHint = "按住连续删除"
        (delete as? FeedbackButton)?.accessibilityAction = { [weak self] in self?.stopDeletion(); self?.backspace() }
        delete.addAction(UIAction { [weak self] _ in self?.startDeletion() }, for: .touchDown)
        delete.addAction(UIAction { [weak self] _ in self?.stopDeletion() }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        actions.addArrangedSubview(delete)
        let clear = button("清空") { [weak self] in self?.stopDeletion(); self?.engine.clear(); self?.render() }; clear.titleLabel?.font = .systemFont(ofSize: 15); clear.accessibilityIdentifier = "clear-composition"; clear.accessibilityHint = "仅清除待选拼音，不删除正文"; clearButton = clear; actions.addArrangedSubview(clear)
        let hide = button("⌄") { [weak self] in self?.stopDeletion(); self?.dismissKeyboard() }; hide.setTitle(nil, for: .normal); hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal); hide.accessibilityLabel = "收起键盘"; hide.accessibilityIdentifier = "hide-keyboard"; actions.addArrangedSubview(hide)
        right.addArrangedSubview(actions)
            keys.addArrangedSubview(right)
        }
        let enter = button(returnTitle) { [weak self] in self?.insertLiteral("\n") }; enter.titleLabel?.font = .systemFont(ofSize: 15); enter.accessibilityIdentifier = "return-key"; returnButton = enter; enter.widthAnchor.constraint(equalToConstant: 48).isActive = true; bottom.addArrangedSubview(enter)
        updateSideRail()
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
        insertLiteral(plan.insertedText, caretBack: plan.caretBack)
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
        do { try engine.manage(candidate, pinned: pinned); render() }
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
        let hadMark=inlineComposition.active
        if !inlineComposition.finish(text,host:compositionHost) {
            textDocumentProxy.insertText(text)
            if hadMark { inlineComposition.forget();textDocumentProxy.unmarkText() }
        }
        archiveOutput(text)
        expanded=false
    }
    private func archiveOutput(_ text: String, pasteEvent: UUID? = nil, pasteSender: UUID? = nil, systemPaste:Bool=false) {
        guard hasFullAccess else { ActivityArchiveCapture.shared.stop(); return }
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
            ActivityArchiveCapture.shared.recordInput(text,sourceApp:nil,document:document,session:archiveSession,epoch:epoch,safety:safe,pasteEvent:pasteEvent,pasteSender:pasteSender,sourceContext:sourceContext)
        }
    }
    private func settlePending() { let pending = engine.takeReadablePendingInput(reading: currentReading); if !pending.isEmpty { commitHostText(pending) } }
    private func setLanguage(_ value: Bool) {
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
        deletionPrediction.beginUserInput();predictionPausedRevision = -1;lastRevision = -1
    }
    private func type(_ text: String) {
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
            if let first=choices.first {let commit=engine.chooseCandidate(first);if !commit.isEmpty {commitHostText(commit)}}
            settlePending()
        }
    }
    private func insertLiteral(_ text: String, caretBack: Int = 0) {
        if !text.isEmpty {resumeAutomaticPredictionForUserInput()}
        cancelPrediction()
        validateInlineContext()
        finishPendingForLiteral()
        ownCommitTracker.invalidate();engine.noteLiteralInput(text)
        commitHostText(text)
        if caretBack > 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: -caretBack)
            // The closer is now after the caret, not part of the preceding text.
            // Recapture native context at the next input instead of predicting
            // from the full inserted pair as if the caret were at its end.
            engine.resetPredictionContext()
        }
        render()
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
    private func backspace() {
        let dismissClipboard = !clipboardCandidate.isHidden
        clipboardState.observe(version:UIPasteboard.general.changeCount);clipboardState.dismiss()
        clipboardKnown=nil;clipboardCacheRequest=nil
        deletionPrediction.observeDocument(documentID);deletionPrediction.beginDeletion();cancelCandidatePage();cancelPrediction()
        cancelLearningForInteraction();validateInlineContext()
        if dismissClipboard,engine.preedit.isEmpty {publishedCandidates.reset();lastRevision = -1;expanded=false;render();return}
        if !engine.preedit.isEmpty { ownCommitTracker.invalidate();_ = engine.key(0xff08);render();return }
        if !english,choices.contains(where:{$0.continuationContext != nil}) {
            cancelPrediction()
            publishedCandidates.reset();lastRevision = -1;expanded=false;render();return
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
    private func choose(_ candidate: InputCandidate) {
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
            // collection being tapped. Reload after UIKit finishes that event.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastRevision = -1;self.render()
            }
        }
    }
    /// A touch freezes this revision's visible order, including late neural
    /// callbacks. New input changes revision and naturally permits ranking again.
    @objc private func pauseCandidateRankingForInteraction() {
        guard let engine else { return }
        predictionPausedRevision = engine.revision
        cancelLearningForInteraction();cancelCandidatePage();cancelPrediction()
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
    private func cancelCandidatePage() {
        candidatePageGeneration &+= 1;candidatePageWork?.cancel();candidatePageWork=nil
    }
    private func dismissCandidateMenus() {
        for collection in [strip,grid] {for case let cell as CandidateCell in collection.visibleCells {cell.dismissCandidateMenu()}}
    }
    private func setCandidatesExpanded(_ value: Bool) {
        guard value != expanded,!choices.isEmpty else{return}
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
        keyboardBody.alpha=expanded ? 0:1;keyboardBody.isUserInteractionEnabled = !expanded;keyboardBody.accessibilityElementsHidden=expanded
        updateHeaderFrames()
        expand.setImage(UIImage(systemName:expanded ? "chevron.up":"chevron.down"),for:.normal)
        expand.accessibilityIdentifier=expanded ? "collapse-candidates":"expand-candidates"
        expand.accessibilityLabel=expanded ? "返回键盘":"展开全部候选"
        if expanded {view.bringSubviewToFront(grid)}
        view.bringSubviewToFront(expand)
    }
    private func requestCandidatePage() {
        guard candidatePageWork == nil,hasMore,!english,!engine.preedit.isEmpty else{return}
        let revision=engine.revision,document=documentID,generation=candidatePageGeneration
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.candidatePageGeneration==generation else{return};self.candidatePageWork=nil
            guard self.engine.revision==revision,self.documentID==document,!self.expand.isTracking else{return}
            self.loadMore(limit:8);self.candidateExpansionFillRemaining=max(0,self.candidateExpansionFillRemaining-8)
            // Fill the newly exposed viewport a small slice at a time. Existing
            // cells and their tap actions stay intact; collapse cancels the rest.
            if self.expanded,self.candidateExpansionFillRemaining>0,self.grid.contentSize.height<self.grid.bounds.height {
                self.requestCandidatePage()
            }
        }
        candidatePageWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.025,execute:work)
    }
    private func loadMore(limit: Int) {
        guard !loading, hasMore, !english, !engine.preedit.isEmpty else { return }
        loading = true
        let started=Date.timeIntervalSinceReferenceDate
        defer {predictionLog.debug("candidate_page_ms=\((Date.timeIntervalSinceReferenceDate-started)*1000,privacy:.public) requested=\(limit,privacy:.public)")}
        let next = engine.candidateBatch(offset: candidateSourceOffset, limit: limit)
        candidateSourceOffset += next.count; hasMore = next.count == limit
        appendPublishedCandidates(next)
        loading = false
    }
    @discardableResult private func validateInlineContext() -> Bool {
        guard inlineComposition.active,!inlineComposition.applying,inlineComposition.moved(in:compositionHost) else { return false }
        #if targetEnvironment(simulator)
        NSLog("INLINE_END context selected=%d before=%d after=%d draft=%d",textDocumentProxy.selectedText?.utf16.count ?? -1,textDocumentProxy.documentContextBeforeInput?.utf16.count ?? -1,textDocumentProxy.documentContextAfterInput?.utf16.count ?? -1,inlineComposition.draft.utf16.count)
        #endif
        inlineComposition.leave(host:compositionHost);engine.clear();expanded=false;ownCommitTracker.invalidate();engine.resetPredictionContext();return true
    }
    private func render() {
        scheduleLearningAfterReveal()
        guard engine != nil,!inlineComposition.applying else { return }
        deletionPrediction.observeDocument(documentID)
        if let currentDocument=documentID,activeDocument != currentDocument {
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
        if engine.preedit.isEmpty && engine.managementPending {
            do { try engine.synchronizeLearning(publish: learningPublisher) } catch { learningStatus = "词频更新失败，可重试" }
        }
        if engine.preedit.isEmpty {captureHostContext()}
        if layout == .numbers {
            publishedCandidates.reset(); candidateSourceOffset=0
            if !choices.isEmpty {choices=[];strip.reloadData();grid.reloadData()}
            hasMore=false;expanded=false;lastRevision=engine.revision
        } else if english { publishedCandidates.reset();candidateSourceOffset=0;refreshEnglishChoices() }
        else if lastRevision != engine.revision {
            cancelCandidatePage();lastRevision = engine.revision
            let limit = expanded ? 48 : 12
            let next:[InputCandidate]
            switch deletionPrediction.source(hasComposition:!engine.preedit.isEmpty) {
            case .primary:next=engine.candidateBatch(offset:0,limit:limit)
            case .continuation:next=(layout == .nine || layout == .letters) ? engine.continuationBatch():[]
            case .none:next=[]
            }
            let newInput = !publishedCandidates.matches(revision: engine.revision, document: documentID)
            candidateSourceOffset = next.count
            hasMore = !engine.preedit.isEmpty && next.count == limit
            loading = true
            if newInput {
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
        preeditHeight.constant = geometryCompact ? 18:20
        preeditRow.isHidden = !chinesePending || inlineShown; preeditTrailing.constant = 0
        candidateBar.isHidden = !pending; toolbar.isHidden = pending
        candidateBar.alpha=expanded ? 0:1;candidateBar.isUserInteractionEnabled = !expanded;candidateBar.accessibilityElementsHidden=expanded
        grid.isHidden = !expanded;grid.accessibilityElementsHidden = !expanded; keyboardBody.isHidden = false
        keyboardBody.alpha=expanded ? 0:1;keyboardBody.isUserInteractionEnabled = !expanded;keyboardBody.accessibilityElementsHidden=expanded
        updateHeaderFrames();header.layoutIfNeeded();strip.collectionViewLayout.invalidateLayout()
        if expanded { view.bringSubviewToFront(grid) }
        expand.isHidden = !pending || choices.isEmpty
        expand.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
        expand.accessibilityIdentifier = expanded ? "collapse-candidates" : "expand-candidates"
        expand.accessibilityLabel = expanded ? "返回键盘" : "展开全部候选"
        expand.accessibilityValue = !english && engine.hasPreparedNinePrediction ? "候选已更新":nil
        if pending { view.bringSubviewToFront(expand) }
        heightAdjustment.isHidden = !adjustingHeight
        if adjustingHeight {
            preeditRow.isHidden=true;candidateBar.isHidden=true;toolbar.isHidden=true;expand.isHidden=true
            header.bringSubviewToFront(heightAdjustment)
        }
        updateClipboardCandidateVisibility()
        letterActionButton?.setTitle("清空",for:.normal)
        letterActionButton?.alpha=chinesePending ? 1:0.45
        letterActionButton?.accessibilityIdentifier="clear-composition"
        letterActionButton?.accessibilityLabel="清空待选拼音"
        letterActionButton?.accessibilityHint="长按可收起键盘"
        clearButton?.alpha = chinesePending ? 1 : 0.45
        expand.isEnabled = !choices.isEmpty; returnButton?.setTitle(returnTitle, for: .normal)
        refreshSettingsMenus()
        if let status = toolbar.arrangedSubviews.last as? UILabel { status.text = !engine.ready ? "中文词库暂不可用" : (learningStatus ?? "") }
        // iOS may keep visible collection cells through an input-view/marked-
        // text layout update. Refresh their content and actions as one snapshot.
        for collection in [strip,grid] {
            for index in collection.indexPathsForVisibleItems where index.item < choices.count {
                if let cell=collection.cellForItem(at:index) as? CandidateCell { configureCandidate(cell,in:collection,at:index) }
            }
        }
        let sharing=sharedTextPanel.isShowing
        header.alpha=sharing ? 0:1;header.isUserInteractionEnabled = !sharing;header.accessibilityElementsHidden=sharing
        if sharing {
            keyboardBody.alpha=0;keyboardBody.isUserInteractionEnabled=false;keyboardBody.accessibilityElementsHidden=true
            grid.isHidden=true;grid.accessibilityElementsHidden=true;expand.isHidden=true
            view.bringSubviewToFront(sharedTextPanel.view)
        }
        #if targetEnvironment(simulator)
        if let probe=try? JSONSerialization.data(withJSONObject:["hostContext":engine.hasHostContext,"beforeCount":engine.modelContext.before.count,"afterCount":engine.modelContext.after.count,"available":engine.semanticLastMetrics.available,"semanticRevision":engine.semanticMetricsRevision,"revision":engine.revision]) {strip.accessibilityValue=String(data:probe,encoding:.utf8)}
        #endif
        schedulePrediction()
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
            cell.activate = { [weak self, weak collectionView] in
                (collectionView as? CandidateCollectionView)?.markControlEvent()
                self?.insertSymbol(text)
            }
        } else {
            let choice = choices[indexPath.item],revision=engine.revision
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
    override func textWillChange(_ textInput: UITextInput?) { super.textWillChange(textInput); applyPreferences() }
    override func textDidChange(_ textInput: UITextInput?) { super.textDidChange(textInput); ActivityArchiveCapture.shared.refresh(permitted:hasFullAccess); synchronizeAppearance();applyPreferences(); render() }
    override func selectionDidChange(_ textInput:UITextInput?) {
        super.selectionDidChange(textInput)
        if inlineComposition.active && !inlineComposition.applying,let selected=textDocumentProxy.selectedText,!selected.isEmpty,selected != inlineComposition.draft {
            #if targetEnvironment(simulator)
            NSLog("INLINE_END selection selected=%d draft=%d",selected.utf16.count,inlineComposition.draft.utf16.count)
            #endif
            inlineComposition.leave(host:compositionHost);engine.clear();expanded=false;ownCommitTracker.invalidate();engine.resetPredictionContext()
        }
        validateInlineContext()
        render()
    }
    private func refreshLearning(explicit: Bool,preparation:LearningRefreshPreparation? = nil) {
        let started=Date.timeIntervalSinceReferenceDate
        defer {predictionLog.debug("learning_checkpoint_ms=\((Date.timeIntervalSinceReferenceDate-started)*1000,privacy:.public) explicit=\(explicit,privacy:.public)")}
        if explicit { loadSystemWords() }
        do {
            try engine.synchronizeLearning(publish:learningPublisher,preparation:preparation)
            learningRefreshPending=false;learningRefreshFailures=0
            if explicit { systemRefreshRequested=systemWordsLoading;learningStatus = systemWordsLoading ? "正在更新词库":"词库已更新" }
        } catch LearningSyncFailure.busy {learningRefreshFailures+=1;if explicit { learningStatus = "先完成当前输入" } }
        catch {learningRefreshFailures+=1;if explicit { learningStatus = "词库更新失败，可重试" } }
        render()
    }
    deinit { sharedTextRefreshTask?.cancel();clipboardTimer?.invalidate();for observer in clipboardObservers {NotificationCenter.default.removeObserver(observer)};if let privacyResetObserver {PersonalDataReset.unobserve(privacyResetObserver)};deferredLearningRefresh?.cancel();deleteDelay?.invalidate(); deleteRepeat?.invalidate(); if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) } }
    private func refreshVisibleSharedText() {
        guard keyboardAppeared,hasFullAccess,sharedTextPanel.isShowing else{return}
        guard sharedTextRefreshTask==nil else {sharedTextRefreshPending=true;return}
        let presentation=keyboardPresentation,scope=clipboardScope,cache=clipboardCacheFingerprint
        sharedTextRefreshTask=Task { [weak self] in
            defer {
                self?.sharedTextRefreshTask=nil
                if self?.sharedTextRefreshPending==true {self?.sharedTextRefreshPending=false;self?.refreshVisibleSharedText()}
            }
            let clips=try? await Task.detached(priority:.utility) {try ClipboardCacheCoordinator.read(fullAccess:true,now:UInt64(Date().timeIntervalSince1970))}.value
            guard !Task.isCancelled,let self,self.keyboardAppeared,self.hasFullAccess,self.sharedTextPanel.isShowing,
                  self.keyboardPresentation==presentation,self.clipboardScope==scope,self.clipboardCacheFingerprint==cache,let clips else{return}
            self.sharedTextPanel.show(clips)
        }
    }
    private func openSharedText() {
        guard engine.preedit.isEmpty else { return }
        #if DEBUG
        sharedTextPanel.view.accessibilityIdentifier = "shared-text-panel"
        sharedTextPanel.diagnostic(hasFullAccess ? (ClipboardCacheCoordinator.privateIdentityAccessibleFromKeyboard() ? "main-identity-visible" : "main-identity-blocked") : "permission-denied")
        #endif
        do { sharedTextPanel.show(try ClipboardCacheCoordinator.read(fullAccess: hasFullAccess, now: UInt64(Date().timeIntervalSince1970))) }
        catch ClipboardCacheError.permissionRequired { sharedTextPanel.show([], status: hasFullAccess ? "共享文本已暂停，请在主 App 开启。" : "请允许完全访问，再使用共享文本。") }
        catch { sharedTextPanel.show([], status: "共享文本暂不可用，可在主 App 重试同步。") }
        render();view.bringSubviewToFront(sharedTextPanel.view)
    }
    private func insertSharedText(_ id: UUID) {
        guard engine.preedit.isEmpty else { return }
        do {
            let clips = try ClipboardCacheCoordinator.read(fullAccess: hasFullAccess, now: UInt64(Date().timeIntervalSince1970))
            guard let clip = clips.first(where: { $0.id == id }) else {
                sharedTextPanel.show(clips, status: "文本已过期或共享已暂停"); return
            }
            if !clip.text.isEmpty {resumeAutomaticPredictionForUserInput()}
            textDocumentProxy.insertText(clip.text)
            archiveOutput(clip.text, pasteEvent: clip.eventID, pasteSender: clip.sender)
            sharedTextPanel.dismissPanel()
        } catch ClipboardCacheError.permissionRequired { sharedTextPanel.show([], status: "共享已暂停或完全访问已关闭") }
        catch { sharedTextPanel.show([], status: "共享文本暂不可用") }
    }
}
