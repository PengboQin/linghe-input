import AppKit
import SwiftUI

/// Window geometry belongs to AppKit, never to the selected page's ideal size.
@MainActor enum MacSettingsWindowLayout {
    static let initialContentSize = NSSize(width: 760, height: 560)
    static let minimumContentSize = NSSize(width: 650, height: 460)

    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: host)
        // Publish only the shell's fixed minimum, never a page's preferred size.
        host.sizingOptions = [.minSize]
        MacThemePreferences.apply(to: window)
        window.title = "灵鹤输入法"
        // Keep the native title and toolbar visible for every settings page.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .line
        window.setContentSize(initialContentSize)
        window.contentMinSize = minimumContentSize
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Keep navigation chrome and the detail proposal alive as page roots change.
struct MacSettingsShell<Sidebar: View, Detail: View>: View {
    let title: String
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar()
                .navigationSplitViewColumnWidth(min: 155, ideal: 165, max: 190)
        } detail: {
            GeometryReader { geometry in
                detail()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: MacSettingsWindowLayout.minimumContentSize.width, maxWidth: .infinity,
               minHeight: MacSettingsWindowLayout.minimumContentSize.height, maxHeight: .infinity)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                } label: {
                    Label("侧栏", systemImage: "sidebar.left")
                }.accessibilityLabel("显示或隐藏侧栏")
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
    }
}

/// A compact master/detail region that fits inside the settings detail column.
/// Nested NSSplitView minimum thicknesses can otherwise overflow a small window.
struct MacSettingsListDetail<ListContent: View, Reader: View>: View {
    @ViewBuilder let list: () -> ListContent
    @ViewBuilder let reader: () -> Reader

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                list()
                    .frame(width: min(205, geometry.size.width * 0.4))
                    .clipped()
                Divider()
                reader()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
    }
}
