import AppKit
import PrivateInputKit

private final class CandidateTable:NSTableView {
    var candidateMenu:((NSEvent)->NSMenu?)?
    var candidatePress:((Int,Int)->(() -> Void)?)?
    private var pendingPress:(point:NSPoint,row:Int,column:Int,commit:() -> Void)?
    override var acceptsFirstResponder:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    // The labels are display-only. Receive the whole cell's first click even
    // while the actual text client remains the key window in another process.
    override func hitTest(_ point:NSPoint)->NSView? {super.hitTest(point) == nil ? nil:self}
    override func menu(for event:NSEvent)->NSMenu? {cancelCandidatePress();return candidateMenu?(event)}
    func cancelCandidatePress() {pendingPress=nil}
    override func mouseDown(with event:NSEvent) {
        cancelCandidatePress()
        guard event.buttonNumber==0,!event.modifierFlags.contains(.control) else{super.mouseDown(with:event);return}
        let point=convert(event.locationInWindow,from:nil),row=row(at:point),column=column(at:point)
        guard row>=0,column>=0,let commit=candidatePress?(row,column) else{return}
        pendingPress=(point,row,column,commit)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let press=pendingPress else{return}
        let point=convert(event.locationInWindow,from:nil)
        if hypot(point.x-press.point.x,point.y-press.point.y)>4 {cancelCandidatePress()}
    }
    override func mouseUp(with event:NSEvent) {
        guard let press=pendingPress else{return}
        cancelCandidatePress()
        let point=convert(event.locationInWindow,from:nil)
        guard event.buttonNumber==0,!event.modifierFlags.contains(.control),
              hypot(point.x-press.point.x,point.y-press.point.y)<=4,
              row(at:point)==press.row,column(at:point)==press.column else{return}
        press.commit()
    }
    override func scrollWheel(with event:NSEvent) {cancelCandidatePress();super.scrollWheel(with:event)}
}
private final class CandidateWindow:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}
private enum CandidateColors {
    static var palette:MacThemePalette {MacThemePreferences.current.palette(dark:NSAppearance.currentDrawing().bestMatch(from:[.aqua,.darkAqua]) == .darkAqua)}
    static var background:NSColor {palette.background}
    static var selection:NSColor {palette.selection}
    static var selectedText:NSColor {palette.selectedText}
}
private final class CandidateSurface:NSView {
    let content=NSView()
    private var glass:NSView?
    private let frost=NSVisualEffectView()
    private(set) var usesGlass=false
    private var optionsObserver:NSObjectProtocol?
    var appearanceDidChange:(()->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true;layer?.cornerRadius=8;layer?.masksToBounds=true
        // Candidate panels deliberately never become key. An explicit active
        // behind-window material keeps the actual frost live in that state.
        frost.material = .popover;frost.blendingMode = .behindWindow;frost.state = .active
        frost.autoresizingMask=[.width,.height];addSubview(frost)
        if #available(macOS 26.0, *) {
            let effect=NSGlassEffectView();effect.style = .clear;effect.cornerRadius=8
            // The list is one surface; no per-cell glass passes or geometry changes.
            if #available(macOS 27.0, *) {effect.effectIsInteractive=true}
            effect.autoresizingMask=[.width,.height];addSubview(effect);glass=effect
        }
        content.autoresizingMask=[.width,.height]
        refreshColors()
        optionsObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.refreshColors() }
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {if let optionsObserver {NSWorkspace.shared.notificationCenter.removeObserver(optionsObserver)}}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();refreshColors();appearanceDidChange?()}
    func refreshColors(reduceTransparency:Bool?=nil,increaseContrast:Bool?=nil) {
        let opaque=(reduceTransparency ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) || (increaseContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        usesGlass = !opaque
        // One native material at a time: layering popover frost beneath glass
        // turns a light candidate surface into a solid gray slab.
        frost.isHidden=opaque || glass != nil
        if #available(macOS 26.0, *),let effect=glass as? NSGlassEffectView {
            effect.isHidden = !usesGlass
            if usesGlass {
                if effect.contentView !== content {content.removeFromSuperview();effect.contentView=content}
            } else if content.superview !== self {effect.contentView=nil;addSubview(content)}
        } else if content.superview !== self {addSubview(content)}
        glass?.frame=bounds;frost.frame=bounds;content.frame=bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor=CandidateColors.background.withAlphaComponent(usesGlass ? 0.94:1).cgColor
            if #available(macOS 26.0, *),let effect=glass as? NSGlassEffectView {
                effect.tintColor=CandidateColors.background.withAlphaComponent(0.85)
            }
            layer?.borderWidth=0.5
            layer?.borderColor=NSColor.separatorColor.withAlphaComponent(opaque ? 0.7:0.28).cgColor
        }
    }
}
/// Candidate-only content in one native panel, with natural row widths and placement
/// at the active host's current input anchor by the shared placement policy.
final class MacCandidatePanel:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    private let window=CandidateWindow(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    private let material=CandidateSurface(),scroll=NSScrollView(),table=CandidateTable()
    private let collapse=NSButton()
    private var themeObserver:NSObjectProtocol?
    private var items:[InputCandidate]=[],selected=0,offset=0,reloading=false,opened=false
    private var layout=DesktopCandidateLayout(),clipboardMode=false
    private var desiredSize=NSSize.zero,referenceHeight:CGFloat=0
    private var expandedNaturalWidths:[CGFloat]?
    private var columns:Int {clipboardMode ? 1:layout.columns(expanded:opened)}
    private var dataOffset:Int {opened ? 0:offset}
    var choose:((InputCandidate)->Void)?,highlight:((InputCandidate)->Void)?,toggle:(()->Void)?,loadMore:(()->Void)?
    var managementMenu:((InputCandidate)->NSMenu?)?
    // Stable two-line cells expose ordinary sentence candidates directly. All
    // rows keep this height, independent of the highlighted word or async work.
    private let expandedRowHeight:CGFloat=46
    private let expandedLabelHeight:CGFloat=40
    private var rowHeight:CGFloat {opened ? expandedRowHeight:28}
    private var candidateFont:NSFont {.systemFont(ofSize:15)}
    override init() {
        super.init()
        window.title="灵鹤输入法候选词";window.setAccessibilityTitle("灵鹤输入法候选词")
        window.level = .popUpMenu;window.isOpaque=false;window.backgroundColor = .clear
        window.hasShadow=true;window.hidesOnDeactivate=false;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        MacThemePreferences.apply(to:window)
        window.contentView=material;material.refreshColors()
        themeObserver=NotificationCenter.default.addObserver(forName:MacThemePreferences.updated,object:nil,queue:.main) { [weak self] _ in
            guard let self else{return}
            MacThemePreferences.apply(to:self.window);self.material.refreshColors();self.table.reloadData()
        }
        collapse.bezelStyle = .inline;collapse.isBordered=false;collapse.target=self;collapse.action=#selector(collapsePressed)
        collapse.image=NSImage(systemSymbolName:"chevron.up",accessibilityDescription:"收起候选词")
        collapse.setAccessibilityLabel("收起候选词")
        collapse.contentTintColor = .secondaryLabelColor;collapse.focusRingType = .none
        collapse.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:11,weight:.medium)
        table.style = .fullWidth
        table.headerView=nil;table.backgroundColor = .clear;table.intercellSpacing=NSSize(width:4,height:2)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .none;table.dataSource=self;table.delegate=self;table.rowHeight=rowHeight
        material.appearanceDidChange = { [weak self] in self?.table.reloadData() }
        rebuildColumns()
        table.candidatePress={ [weak self] row,column in
            guard let self,let candidate=self.candidate(row:row,column:column) else{return nil}
            // A delayed mouse-up must not choose a different word after an
            // asynchronous list refresh or after changing to another page.
            return { [weak self] in
                guard let self,self.window.isVisible,
                      let current=self.candidate(row:row,column:column),
                      current.index==candidate.index,current.text==candidate.text,
                      current.generation==candidate.generation else{return}
                self.choose?(current)
            }
        }
        table.candidateMenu={ [weak self] event in
            guard let self else{return nil}
            let point=self.table.convert(event.locationInWindow,from:nil)
            let row=self.table.row(at:point),column=self.table.column(at:point)
            guard row>=0,column>=0 else{return nil}
            let index=self.dataOffset+row*self.columns+column
            guard self.items.indices.contains(index) else{return nil}
            return self.managementMenu?(self.items[index])
        }
        // Wheel/trackpad scrolling remains native, but no scroller appears
        // halfway through typing and steals width from the last candidate.
        scroll.documentView=table;scroll.hasVerticalScroller=false;scroll.hasHorizontalScroller=false
        scroll.autohidesScrollers=false;scroll.drawsBackground=false
        scroll.contentView.postsBoundsChangedNotifications=true
        NotificationCenter.default.addObserver(self,selector:#selector(scrolled),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        for v in [collapse,scroll] {material.content.addSubview(v)}
    }
    deinit {NotificationCenter.default.removeObserver(self);if let themeObserver {NotificationCenter.default.removeObserver(themeObserver)}}
    var isVisible:Bool {window.isVisible}
    var frame:NSRect {window.frame}
    var takesKeyFocus:Bool {window.canBecomeKey || window.isKeyWindow}
    var columnCount:Int {columns}
    var panelIdentifier:Int {window.windowNumber}
    private func rebuildColumns() {
        table.tableColumns.forEach{table.removeTableColumn($0)}
        for c in 0..<columns {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(String(c)));column.resizingMask = [];table.addTableColumn(column)
        }
    }
    #if PRIVATE_INPUT_DEVELOPMENT_DIAGNOSTICS
    func appearanceForAcceptance(_ name:NSAppearance.Name) {window.appearance=NSAppearance(named:name);material.refreshColors();table.reloadData()}
    var usesGlassForAcceptance:Bool {material.usesGlass}
    func accessibilityForAcceptance(reduceTransparency:Bool,increaseContrast:Bool) {material.refreshColors(reduceTransparency:reduceTransparency,increaseContrast:increaseContrast)}
    var columnsFitViewportForAcceptance:Bool {table.rect(ofColumn:columns-1).maxX<=scroll.contentView.bounds.width+0.5}
    var columnWidthsForAcceptance:[CGFloat] {table.tableColumns.map(\.width)}
    var selectionIsVisible:Bool {
        let visible=table.rows(in:scroll.documentVisibleRect)
        return visible.length>0 && (visible.location..<visible.location+visible.length).contains(opened ? selected/columns:0)
    }
    func scrollForAcceptance(toRow row:Int) {table.scrollRowToVisible(row);scrolled()}
    func saveAcceptanceSnapshot(_ url:URL) throws {
        guard let image=material.bitmapImageRepForCachingDisplay(in:material.bounds) else{throw CocoaError(.fileWriteUnknown)}
        material.cacheDisplay(in:material.bounds,to:image)
        guard let data=image.representation(using:.png,properties:[:]) else{throw CocoaError(.fileWriteUnknown)}
        try data.write(to:url)
    }
    #endif
    func hide() {table.cancelCandidatePress();expandedNaturalWidths=nil;window.orderOut(nil)}
    private func expandedWidth(for text:String)->CGFloat {
        // Measure both selection weights so moving the highlight never needs
        // more room. Include the shortcut slot, label insets and table padding.
        let fonts=[candidateFont,NSFont.systemFont(ofSize:15,weight:.medium)]
        func fits(_ width:Int)->Bool {
            fonts.allSatisfy { font in
                let bounds=(text as NSString).boundingRect(with:NSSize(width:CGFloat(width),height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font])
                return ceil(bounds.height)<=expandedLabelHeight
            }
        }
        if fits(62) {return 88}
        guard fits(298) else{return 324}
        var low=63,high=298
        while low<high {
            let middle=(low+high)/2
            if fits(middle) {high=middle} else{low=middle+1}
        }
        return CGFloat(low)+26
    }
    func show(items:[InputCandidate],selected:Int,offset:Int,expanded:Bool,caret:NSRect,layout:DesktopCandidateLayout = .init(),clipboard:Bool=false) {
        guard !items.isEmpty else{hide();return}
        reloading=true;defer{reloading=false}
        let wasOpen=opened,oldColumns=columns
        let measureExpanded = !wasOpen || self.layout != layout || clipboardMode != clipboard || expandedNaturalWidths == nil
        let moveToSelection = !window.isVisible || self.selected != selected || opened != expanded || self.layout != layout
        let origin=scroll.contentView.bounds.origin
        self.items=items;self.selected=selected;self.offset=offset
        self.layout=layout;clipboardMode=clipboard;opened=expanded;table.rowHeight=rowHeight
        if oldColumns != columns {rebuildColumns()}
        // Collapsed candidates use the same text measurement in every slot:
        // a short first word stays compact, while a phrase gets more room.
        // Measure only the first screen when opening, then freeze the grid
        // through highlight changes, async replacements and lazy tail loading.
        let visible=Array(items.dropFirst(dataOffset).prefix(columns))
        if opened,measureExpanded {
            var widths=Array(repeating:CGFloat(84),count:columns)
            for (index,item) in items.prefix(columns*layout.expandedRows).enumerated() {
                widths[index%columns]=max(widths[index%columns],expandedWidth(for:item.text))
            }
            expandedNaturalWidths=widths
        } else if !opened {expandedNaturalWidths=nil}
        let naturalWidths:[CGFloat]=opened ? (expandedNaturalWidths ?? Array(repeating:84,count:columns)):
            (0..<columns).map { index in
                guard index<visible.count else{return 42}
                let measured=ceil((visible[index].text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:15,weight:.medium)]).width+28)
                return min(320,max(42,measured))
            }
        let naturalWidth=naturalWidths.reduce(0,+)+CGFloat(columns)*4+36
        // Long phrases can widen the row without recreating an enormous
        // desktop-spanning panel; placement also clamps to smaller screens.
        let width=opened ? naturalWidth:min(650,naturalWidth)
        referenceHeight=clipboard ? rowHeight+14:CGFloat(layout.expandedRows)*(expandedRowHeight+2)+12
        desiredSize=NSSize(width:width,height:opened ? referenceHeight:rowHeight+14)
        guard let frame=MacCandidatePlacement.frame(caret:caret,size:desiredSize,referenceHeight:referenceHeight,screens:NSScreen.screens.map(\.visibleFrame)) else{hide();return}
        let height=frame.height,actualWidth=frame.width
        material.frame=NSRect(x:0,y:0,width:actualWidth,height:height)
        collapse.frame=NSRect(x:actualWidth-28,y:height-18-rowHeight/2,width:24,height:24)
        collapse.image=NSImage(systemSymbolName:opened ? "chevron.up":"chevron.down",accessibilityDescription:opened ? "收起候选词":"展开候选词")
        collapse.setAccessibilityLabel(opened ? "收起候选词":"展开候选词")
        collapse.isHidden=clipboard
        scroll.frame=NSRect(x:6,y:6,width:actualWidth-36,height:max(1,height-12));scroll.hasVerticalScroller=false
        let count=opened ? (items.count+columns-1)/columns:1
        table.frame=NSRect(x:0,y:0,width:scroll.frame.width,height:CGFloat(count)*(rowHeight+2))
        scroll.tile()
        // Fit the real clip view when the row reaches its width cap or the
        // screen is narrower than the user's configured grid. Hidden scrollers
        // never take width away from the last candidate.
        let documentWidth=scroll.contentView.bounds.width
        let room=max(1,documentWidth-CGFloat(columns)*4),scale=min(1,room/max(1,naturalWidths.reduce(0,+)))
        var fitted=naturalWidths.map{max(30,floor($0*scale))}
        let activeColumn=selected-dataOffset
        if !opened,naturalWidths.indices.contains(activeColumn),scale<1 {
            // A long alternative must not shrink the current selection into
            // an ellipsis. Reserve its measured width, fit the other cells in
            // the remaining room, and retain the same bounded panel width.
            let wanted=min(naturalWidths[activeColumn],max(30,room-CGFloat(columns-1)*30))
            let others=naturalWidths.enumerated().filter{$0.offset != activeColumn}.map(\.element).reduce(0,+)
            let otherScale=min(1,max(0,room-wanted)/max(1,others))
            fitted=naturalWidths.enumerated().map{index,value in index==activeColumn ? floor(wanted):max(30,floor(value*otherScale))}
        }
        for (index,column) in table.tableColumns.enumerated() {column.width=fitted[index]}
        table.setFrameSize(NSSize(width:documentWidth,height:CGFloat(count)*(rowHeight+2)))
        table.reloadData()
        if moveToSelection {table.scrollRowToVisible(opened ? max(0,selected)/columns:0)}
        else if wasOpen {scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView)}
        window.setFrame(frame,display:true);window.orderFrontRegardless()
        // AppKit's table style adds edge padding beyond column widths. Use
        // its measured final extent so the last cell cannot be clipped.
        for _ in 0..<2 {
            let excess=table.rect(ofColumn:columns-1).maxX-scroll.contentView.bounds.width
            if excess<=0.5 {break}
            let reduction=ceil(excess/CGFloat(columns))
            for column in table.tableColumns {column.width=max(30,column.width-reduction)}
            table.reloadData();scroll.tile()
        }
    }
    func reposition(caret:NSRect) {
        guard let frame=MacCandidatePlacement.frame(caret:caret,size:desiredSize,referenceHeight:referenceHeight,screens:NSScreen.screens.map(\.visibleFrame)) else{hide();return}
        if window.frame != frame {window.setFrame(frame,display:true)}
    }
    @objc private func collapsePressed() {toggle?()}
    private func candidate(row:Int,column:Int)->InputCandidate? {
        guard row>=0,column>=0,column<columns else{return nil}
        let index=dataOffset+row*columns+column
        return items.indices.contains(index) ? items[index]:nil
    }
    @objc private func scrolled() {
        table.cancelCandidatePress()
        guard !reloading,opened,!items.isEmpty else{return}
        let visible=table.rows(in:scroll.documentVisibleRect)
        if visible.length>0,!(visible.location..<visible.location+visible.length).contains(selected/columns) {
            let row=max(visible.location,min(visible.location+visible.length-1,selected/columns))
            selected=min(items.count-1,row*columns+selected%columns)
            reloading=true;table.reloadData();reloading=false;highlight?(items[selected])
        }
        if items.count>=layout.pageSize,scroll.documentVisibleRect.maxY>=table.bounds.maxY-80 {loadMore?()}
    }
    func numberOfRows(in tableView:NSTableView)->Int {opened ? (items.count+columns-1)/columns:1}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let c=tableColumn,let column=Int(c.identifier.rawValue) else{return nil}
        let index=dataOffset+row*columns+column;guard items.indices.contains(index) else{return NSView()}
        let cell=NSTableCellView();cell.wantsLayer=true;cell.layer?.cornerRadius=4
        let active=index==selected
        material.effectiveAppearance.performAsCurrentDrawingAppearance {
            cell.layer?.backgroundColor=active ? CandidateColors.selection.cgColor:NSColor.clear.cgColor
            cell.layer?.borderWidth=active ? 1:0
            cell.layer?.borderColor=CandidateColors.palette.accent.cgColor
        }
        let number=NSTextField(labelWithString:String(column+1)),label=NSTextField(wrappingLabelWithString:items[index].text)
        // Keep the number's existing constrained slot even when hidden, so
        // moving the cursor to another row never shifts any candidate text.
        number.identifier=NSUserInterfaceItemIdentifier("candidate-shortcut")
        number.isHidden=items[index].index == -2 || (opened && row != selected/columns)
        number.font = .monospacedDigitSystemFont(ofSize:10.5,weight:.regular);number.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize:15,weight:active ? .medium:.regular)
        material.effectiveAppearance.performAsCurrentDrawingAppearance {
            let palette=CandidateColors.palette
            label.textColor=active ? palette.selectedText:palette.text
            number.textColor=active ? palette.selectedText:palette.secondary
        }
        label.maximumNumberOfLines=opened ? 2:1
        label.lineBreakMode=opened ? .byWordWrapping:.byTruncatingTail
        if opened {label.preferredMaxLayoutWidth=max(1,c.width-22)}
        for v in [number,label] {v.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(v)}
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),number.widthAnchor.constraint(equalToConstant:10),number.centerYAnchor.constraint(equalTo:cell.centerYAnchor),label.leadingAnchor.constraint(equalTo:number.trailingAnchor,constant:4),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor),label.heightAnchor.constraint(lessThanOrEqualToConstant:opened ? expandedLabelHeight:22)])
        cell.toolTip=items[index].text;cell.setAccessibilityHelp(items[index].index == -2 ? "点击粘贴；删除键隐藏":"右键管理候选词频");cell.setAccessibilityLabel("第\(row+1)行，第\(column+1)列，\(items[index].text)")
        return cell
    }
}
