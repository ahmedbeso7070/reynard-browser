//
//  ToolbarController.swift
//  Reynard
//
//  Created by Minh Ton on 4/8/26.
//

import UIKit

final class ToolbarController {
    enum LockReason: Hashable {
        case addressBarTransition
        case addressBarEditing
        case historyNavigation
        case pageNavigation
        case homepageOverlay
        case searchOverlay
        case tabOverview
        case viewPresentation
        case addonPopover
    }
    
    private enum UX {
        static let toolbarScrollFactor: CGFloat = 0.8
        static let snapDelay: TimeInterval = 0.1
        static let snapDuration: TimeInterval = 0.15
    }
    
    private unowned let browserChrome: BrowserChrome
    private unowned let tabBar: TabBar
    private unowned let contentView: ContentView
    private unowned let rootView: UIView
    
    private var chromeMode: BrowserChromeMode = .phone
    private var toolbarOffset: CGFloat = 0
    private var maxToolbarOffset: CGFloat = 0
    private var maxTopToolbarOffset: CGFloat = 0
    private var scrollPosition: CGFloat = 0
    private var snapOrigin: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var snapStartTime: CFTimeInterval = 0
    private var pendingSnap: DispatchWorkItem?
    private var snapDisplayLink: CADisplayLink?
    private var isBottomToolbarCollapsed = false
    private var lockReasons = Set<LockReason>()
    
    // MARK: - Lifecycle
    
    init(
        browserChrome: BrowserChrome,
        tabBar: TabBar,
        contentView: ContentView,
        rootView: UIView
    ) {
        self.browserChrome = browserChrome
        self.tabBar = tabBar
        self.contentView = contentView
        self.rootView = rootView
        
        let historySwipeHandler = contentView.onHistorySwipeBegan
        contentView.onHistorySwipeBegan = { [weak self] in
            self?.lock(for: .historyNavigation)
            historySwipeHandler?()
        }
        
        contentView.onHistorySwipeEnded = { [weak self] in
            self?.unlock(for: .historyNavigation)
        }
        
        contentView.onVerticalScroll = { [weak self] scrollDelta, position in
            self?.handleScroll(delta: scrollDelta, position: position)
        }
    }
    
    deinit {
        cancelSnap()
    }
    
    // MARK: - Layout
    
    func updateLayout(
        chromeMode: BrowserChromeMode,
        isToolbarEnabled: Bool,
        extendsContentBehindToolbar: Bool
    ) {
        let offsetLimits = toolbarOffsetLimits(for: chromeMode)
        let canHideToolbar = isToolbarEnabled
        && Prefs.AppearanceSettings.scrollToHideToolbarEnabled
        && !(chromeMode == .compact && rootView.traitCollection.userInterfaceIdiom == .pad)
        let maxToolbarOffset = canHideToolbar ? offsetLimits.total : 0
        let maxTopToolbarOffset = canHideToolbar ? offsetLimits.top : 0
        
        let webContentBottomOffset = isToolbarEnabled && !canHideToolbar && !extendsContentBehindToolbar
        ? offsetLimits.top - offsetLimits.total
        : 0
        
        if self.chromeMode != chromeMode
            || abs(maxToolbarOffset - self.maxToolbarOffset) > 0.5
            || abs(maxTopToolbarOffset - self.maxTopToolbarOffset) > 0.5 {
            reset(animated: false)
            self.chromeMode = chromeMode
            self.maxToolbarOffset = maxToolbarOffset
            self.maxTopToolbarOffset = maxTopToolbarOffset
        }
        contentView.setToolbarLimits(
            maxHeight: maxToolbarOffset,
            contentTopInset: maxTopToolbarOffset,
            webContentBottomOffset: webContentBottomOffset
        )
    }
    
    private func toolbarOffsetLimits(
        for chromeMode: BrowserChromeMode
    ) -> (total: CGFloat, top: CGFloat) {
        let topToolbarHeight = browserChrome.topToolbarTransitionFrame(in: rootView).height
        let bottomToolbarHeight = browserChrome.bottomToolbarTransitionFrame(in: rootView).height
        switch chromeMode {
        case .phone:
            return (bottomToolbarHeight, 0)
        case .compact:
            return (topToolbarHeight + bottomToolbarHeight, topToolbarHeight)
        case .pad:
            let topChromeHeight = topToolbarHeight + (tabBar.visibility != .hidden ? tabBar.bounds.height : 0)
            return (topChromeHeight, topChromeHeight)
        }
    }
    
    private func setToolbarOffset(_ requestedOffset: CGFloat, refresh: Bool = false) {
        let clampedToolbarOffset = min(max(0, requestedOffset), maxToolbarOffset)
        guard refresh || clampedToolbarOffset != toolbarOffset else {
            return
        }
        toolbarOffset = clampedToolbarOffset
        let bottomToolbarHeight = browserChrome.bottomToolbarTransitionFrame(in: rootView).height
        let topToolbarOffset: CGFloat
        let topContentOffset: CGFloat
        let topToolbarContentAlpha: CGFloat
        var bottomToolbarOffset: CGFloat
        var bottomToolbarContentAlpha: CGFloat
        let tabBarOffset: CGFloat
        switch chromeMode {
        case .phone:
            topToolbarOffset = 0
            topContentOffset = 0
            topToolbarContentAlpha = 1
            bottomToolbarOffset = toolbarOffset
            bottomToolbarContentAlpha = 1 - (bottomToolbarOffset / max(bottomToolbarHeight, 1))
            tabBarOffset = 0
        case .compact:
            let progress = toolbarOffset / max(maxToolbarOffset, 1)
            let topToolbarTravel = max(0, maxTopToolbarOffset - rootView.safeAreaInsets.top)
            topContentOffset = maxTopToolbarOffset * progress
            topToolbarOffset = min(topContentOffset, topToolbarTravel)
            topToolbarContentAlpha = 1 - (topToolbarOffset / max(topToolbarTravel, 1))
            bottomToolbarOffset = bottomToolbarHeight * progress
            bottomToolbarContentAlpha = 1 - (bottomToolbarOffset / max(bottomToolbarHeight, 1))
            tabBarOffset = 0
        case .pad:
            let topToolbarTravel = max(0, maxTopToolbarOffset - rootView.safeAreaInsets.top)
            topToolbarOffset = min(toolbarOffset, topToolbarTravel)
            topContentOffset = toolbarOffset
            topToolbarContentAlpha = 1 - (topToolbarOffset / max(topToolbarTravel, 1))
            bottomToolbarOffset = 0
            bottomToolbarContentAlpha = 1
            tabBarOffset = topToolbarOffset
        }
        if isBottomToolbarCollapsed {
            bottomToolbarOffset = chromeMode == .pad ? 0 : bottomToolbarHeight
            bottomToolbarContentAlpha = bottomToolbarHeight > 0 ? 0 : 1
        }
        browserChrome.setToolbarTransition(
            topOffset: -topToolbarOffset,
            bottomOffset: bottomToolbarOffset,
            topContentAlpha: topToolbarContentAlpha,
            bottomContentAlpha: bottomToolbarContentAlpha
        )
        if chromeMode == .pad {
            tabBar.setPresentationAlpha(topToolbarContentAlpha)
        }
        tabBar.transform = CGAffineTransform(translationX: 0, y: -tabBarOffset)
        contentView.applyToolbarOffsets(
            top: topContentOffset,
            bottom: bottomToolbarOffset,
            refresh: refresh
        )
    }
    
    // MARK: - Locking
    
    func lock(for reason: LockReason) {
        guard lockReasons.insert(reason).inserted else { return }
        reset()
    }
    
    func unlock(for reason: LockReason) {
        lockReasons.remove(reason)
    }
    
    // MARK: - Scroll Handling
    
    private func handleScroll(delta: CGFloat, position: CGFloat) {
        scrollPosition = max(0, position)
        guard Prefs.AppearanceSettings.scrollToHideToolbarEnabled,
              maxToolbarOffset > 0,
              lockReasons.isEmpty else {
            return
        }
        cancelSnap()
        var maximumOffset = maxToolbarOffset
        if scrollPosition < maxTopToolbarOffset {
            maximumOffset *= scrollPosition / maxTopToolbarOffset
        }
        setToolbarOffset(min(toolbarOffset + delta * UX.toolbarScrollFactor, maximumOffset))
        scheduleSnap()
    }
    
    // MARK: - Snapping
    
    private func scheduleSnap() {
        let snap = DispatchWorkItem { [weak self] in
            self?.beginSnap()
        }
        pendingSnap = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + UX.snapDelay, execute: snap)
    }
    
    private func beginSnap(to destination: CGFloat? = nil) {
        pendingSnap = nil
        snapOrigin = toolbarOffset
        let shouldExpand = scrollPosition < maxTopToolbarOffset || snapOrigin < maxToolbarOffset / 2
        targetOffset = destination ?? (shouldExpand ? 0 : maxToolbarOffset)
        guard snapOrigin != targetOffset else {
            setToolbarOffset(targetOffset, refresh: true)
            return
        }
        snapStartTime = CACurrentMediaTime()
        let snapDisplayLink = CADisplayLink(target: self, selector: #selector(updateSnap))
        snapDisplayLink.add(to: .main, forMode: .common)
        self.snapDisplayLink = snapDisplayLink
    }
    
    @objc private func updateSnap() {
        let elapsed = CACurrentMediaTime() - snapStartTime
        let progress = min(CGFloat(elapsed / UX.snapDuration), 1)
        let easedProgress = 1 - pow(1 - progress, 2)
        let requestedOffset = snapOrigin + (targetOffset - snapOrigin) * easedProgress
        setToolbarOffset(requestedOffset)
        if progress == 1 {
            snapDisplayLink?.invalidate()
            snapDisplayLink = nil
        }
    }
    
    private func cancelSnap() {
        pendingSnap?.cancel()
        pendingSnap = nil
        snapDisplayLink?.invalidate()
        snapDisplayLink = nil
    }
    
    // MARK: - Reset
    
    func collapseBottomToolbar() {
        cancelSnap()
        isBottomToolbarCollapsed = true
        setToolbarOffset(toolbarOffset, refresh: true)
    }
    
    func restoreBottomToolbar() {
        cancelSnap()
        isBottomToolbarCollapsed = false
        setToolbarOffset(toolbarOffset, refresh: true)
    }
    
    func collapse(animated: Bool = true) {
        cancelSnap()
        isBottomToolbarCollapsed = false
        guard animated else {
            setToolbarOffset(maxToolbarOffset, refresh: true)
            return
        }
        beginSnap(to: maxToolbarOffset)
    }
    
    func reset(animated: Bool = true) {
        cancelSnap()
        isBottomToolbarCollapsed = false
        guard animated else {
            setToolbarOffset(0, refresh: true)
            return
        }
        beginSnap(to: 0)
    }
}
