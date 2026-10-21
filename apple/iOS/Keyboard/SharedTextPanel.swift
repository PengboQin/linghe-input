import UIKit
import PrivateInputKit

// A child navigation controller inside the keyboard, sharing its native
// background and height. Rows insert directly; accessories open the full text.
final class SharedTextPanel: UINavigationController {
    private let inbox = SharedTextListController()
    private var expirationTimer: Timer?
    var select: ((UUID) -> Void)?
    var refresh: (() -> Void)?
    var didDismiss: (() -> Void)?
    var availabilityIssue: (() -> String?)?
    private(set) var isShowing = false
    init() {
        super.init(nibName: nil, bundle: nil)
        setViewControllers([inbox], animated: false)
        inbox.open = { [weak self] clip in self?.showDetail(clip) }
        inbox.insert = { [weak self] id in self?.select?(id) }
        inbox.close = { [weak self] in self?.dismissPanel() }
        inbox.refresh = { [weak self] in self?.refresh?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.accessibilityIdentifier = "shared-text-panel"
        let appearance = UINavigationBarAppearance(); appearance.configureWithTransparentBackground()
        navigationBar.standardAppearance = appearance; navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance; navigationBar.isTranslucent = true
        view.isHidden = true; applyTheme()
    }
    func applyTheme() {
        guard isViewLoaded else { return }
        view.backgroundColor = .clear
        navigationBar.tintColor = InputThemeColors.accent
        let appearance = UINavigationBarAppearance(); appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: InputThemeColors.text]
        navigationBar.standardAppearance = appearance; navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        inbox.applyTheme()
        for controller in viewControllers.compactMap({ $0 as? SharedTextDetailController }) { controller.applyTheme() }
    }
    func show(_ values: [ReceivedClipboard], status: String? = nil) {
        loadViewIfNeeded(); isShowing = true; view.isHidden = false
        inbox.update(values, status: status)
        let ids = Set(values.map(\.id))
        for controller in viewControllers.compactMap({ $0 as? SharedTextDetailController }) {
            if !ids.contains(controller.clip.id) { controller.invalidate(status ?? "共享文本已过期") }
            controller.updateAvailability()
        }
        expirationTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let issue = self.availabilityIssue?() {
                self.inbox.update([], status:issue)
                for controller in self.viewControllers.compactMap({ $0 as? SharedTextDetailController }) { controller.invalidate(issue) }
                return
            }
            self.inbox.removeExpired()
            for controller in self.viewControllers.compactMap({ $0 as? SharedTextDetailController }) { controller.updateAvailability() }
        }
        expirationTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }
    func dismissPanel() {
        expirationTimer?.invalidate(); expirationTimer = nil
        isShowing = false; view.isHidden = true
        setViewControllers([inbox], animated: false); inbox.update([], status: nil)
        didDismiss?()
    }
    #if DEBUG
    func diagnostic(_ value: String) { inbox.loadViewIfNeeded(); inbox.navigationItem.leftBarButtonItem?.accessibilityValue = value }
    #endif
    private func showDetail(_ clip: ReceivedClipboard) {
        guard clip.expiresAt > UInt64(Date().timeIntervalSince1970) else { inbox.removeExpired(); return }
        let detail = SharedTextDetailController(clip: clip)
        detail.insert = { [weak self] in self?.select?(clip.id) }
        pushViewController(detail, animated: true)
    }
    deinit { expirationTimer?.invalidate() }
}

private final class SharedTextListController: UITableViewController {
    private var clips: [ReceivedClipboard] = []
    private let statusLabel = UILabel()
    var open: ((ReceivedClipboard) -> Void)?
    var insert: ((UUID) -> Void)?
    var close: (() -> Void)?
    var refresh: (() -> Void)?
    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "共享文本"; edgesForExtendedLayout = []
        navigationItem.largeTitleDisplayMode = .never
        let back = UIBarButtonItem(title: "键盘", image: UIImage(systemName: "chevron.left"), primaryAction: UIAction { [weak self] _ in self?.close?() })
        if #available(iOS 26.0, *) { back.hidesSharedBackground = true }
        back.accessibilityLabel = "返回键盘"; back.accessibilityIdentifier = "close-shared-text"
        navigationItem.leftBarButtonItem = back
        let reload = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refresh?() })
        if #available(iOS 26.0, *) { reload.hidesSharedBackground = true }
        reload.accessibilityLabel = "刷新共享文本"; reload.accessibilityIdentifier = "refresh-shared-text"
        navigationItem.rightBarButtonItem = reload
        tableView.accessibilityIdentifier = "shared-text-list"
        tableView.backgroundColor = .clear; tableView.isOpaque = false
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 62
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        statusLabel.font = .preferredFont(forTextStyle: .callout); statusLabel.textColor = InputThemeColors.secondary
        statusLabel.textAlignment = .center; statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "shared-text-status"
    }
    func applyTheme() {
        guard isViewLoaded else { return }
        statusLabel.textColor = InputThemeColors.secondary
        for cell in tableView.visibleCells {
            if var content = cell.contentConfiguration as? UIListContentConfiguration {
                content.textProperties.color = InputThemeColors.text
                cell.contentConfiguration = content
            }
        }
    }
    func update(_ values: [ReceivedClipboard], status: String?) {
        loadViewIfNeeded()
        clips = values.filter { $0.expiresAt > UInt64(Date().timeIntervalSince1970) }.reversed()
        statusLabel.text = status ?? (clips.isEmpty ? "尚未收到共享文本" : nil)
        tableView.tableHeaderView = nil; tableView.backgroundView = nil
        tableView.backgroundView = clips.isEmpty ? statusLabel : nil
        if !clips.isEmpty, let status, !status.isEmpty {
            statusLabel.frame = CGRect(x: 16, y: 0, width: max(1,tableView.bounds.width-32), height: 54)
            tableView.tableHeaderView = statusLabel
        } else { tableView.tableHeaderView = nil }
        tableView.reloadData()
    }
    func removeExpired() {
        let valid = clips.filter { $0.expiresAt > UInt64(Date().timeIntervalSince1970) }
        guard valid.count != clips.count else { return }
        update(Array(valid.reversed()), status: valid.isEmpty ? "共享文本已过期" : nil)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { clips.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "shared") as? SharedTextCell ?? SharedTextCell(style: .default, reuseIdentifier: "shared")
        let clip = clips[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = String(clip.text.prefix(160)); content.textProperties.font = .preferredFont(forTextStyle: .callout)
        content.textProperties.numberOfLines = 2; content.textProperties.color = InputThemeColors.text
        cell.contentConfiguration = content; cell.backgroundColor = .clear; cell.clipID = clip.id
        cell.accessibilityIdentifier = "shared-text-" + clip.id.uuidString
        cell.accessibilityHint = "插入当前输入框"
        cell.details.accessibilityIdentifier = "shared-text-detail-" + clip.id.uuidString
        cell.open = { [weak self] in self?.open?(clip) }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at:indexPath) as? SharedTextCell, let id = cell.clipID else { return }
        tableView.deselectRow(at: indexPath, animated: true); insert?(id)
    }
}

private final class SharedTextCell: UITableViewCell {
    let details = UIButton(type: .detailDisclosure)
    var clipID: UUID?
    var open: (() -> Void)?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style:style,reuseIdentifier:reuseIdentifier)
        details.frame = CGRect(x:0,y:0,width:44,height:44); details.accessibilityLabel = "查看全文"
        details.addAction(UIAction { [weak self] _ in self?.open?() },for:.touchUpInside)
        accessoryView = details
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class SharedTextDetailController: UIViewController {
    let clip: ReceivedClipboard
    var insert: (() -> Void)?
    private let text = UITextView()
    private var invalidated = false
    init(clip: ReceivedClipboard) { self.clip=clip;super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "全文"; view.backgroundColor = .clear; edgesForExtendedLayout = []
        text.translatesAutoresizingMaskIntoConstraints = false; text.backgroundColor = .clear; text.isOpaque = false
        text.font = .preferredFont(forTextStyle:.callout); text.adjustsFontForContentSizeCategory = true; text.textColor = InputThemeColors.text
        text.isEditable = false; text.isSelectable = true; text.text = clip.text
        text.textContainerInset = UIEdgeInsets(top:12,left:12,bottom:12,right:12)
        text.accessibilityIdentifier = "shared-text-full-content"; view.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:view.leadingAnchor),text.trailingAnchor.constraint(equalTo:view.trailingAnchor),text.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),text.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        let commit = UIBarButtonItem(title:"插入",primaryAction:UIAction { [weak self] _ in self?.insert?() })
        commit.accessibilityIdentifier = "insert-shared-text-detail"; navigationItem.rightBarButtonItem = commit
        updateAvailability()
    }
    func applyTheme() { guard isViewLoaded else { return }; text.textColor = InputThemeColors.text }
    func updateAvailability() {
        guard isViewLoaded else { return }
        let valid = !invalidated && clip.expiresAt > UInt64(Date().timeIntervalSince1970)
        navigationItem.rightBarButtonItem?.isEnabled = valid
        if !valid && !invalidated { invalidate("共享文本已过期") }
    }
    func invalidate(_ message: String) {
        loadViewIfNeeded(); invalidated=true; text.text=message; text.isSelectable=false
        navigationItem.rightBarButtonItem?.isEnabled=false
    }
}
