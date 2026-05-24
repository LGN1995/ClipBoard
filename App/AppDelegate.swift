import AppKit
import SwiftUI
import Carbon.HIToolbox
import CoreGraphics

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var floatingPanel: NSPanel!
    private var clipboardManager = ClipboardManager.shared
    
    // 全局事件监控
    private var eventMonitor: Any?
    private var clickMonitor: Any?
    
    // CGEventTap for hotkey
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // 定时器用于检查/重连 event tap
    private var hotkeyTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupGlobalHotKey()
        startHotkeyHealthCheck()
    }

    // MARK: - Hotkey Setup
    
    private func setupGlobalHotKey() {
        setupCGEventTap()
        
        // 本地监控作为备用
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func setupCGEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

            // 处理 keyDown 事件
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                if flags.contains(.maskControl) && keyCode == kVK_ANSI_V {
                    DispatchQueue.main.async {
                        appDelegate.togglePanel()
                    }
                    // 消费掉这个事件，不传递给其他应用
                    return nil
                }
            }
            
            // 其他事件正常传递
            return Unmanaged.passRetained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("✅ CGEventTap 创建成功")
        } else {
            print("⚠️ CGEventTap 创建失败")
            queryAccessibilityPermissions()
        }
    }
    
    // 健康检查：定期确保 event tap 处于启用状态
    private func startHotkeyHealthCheck() {
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkAndRestoreEventTap()
        }
    }
    
    private func checkAndRestoreEventTap() {
        guard let tap = eventTap else { return }
        
        // 检查 tap 是否启用
        let isEnabled = CGEvent.tapIsEnabled(tap: tap)
        
        if !isEnabled {
            print("⚠️ EventTap 被禁用，尝试重新启用...")
            CGEvent.tapEnable(tap: tap, enable: true)
            
            // 如果重新启用失败，尝试重新创建
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("⚠️ 重新启用失败，尝试重建 EventTap...")
                cleanupEventTap()
                setupCGEventTap()
            }
        }
    }
    
    private func cleanupEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func queryAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()
        print("辅助功能权限状态: \(trusted)")

        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)
        if controlPressed && event.keyCode == kVK_ANSI_V {
            DispatchQueue.main.async {
                self.togglePanel()
            }
        }
    }

    // MARK: - Panel Show/Hide

    @objc private func togglePanel() {
        if floatingPanel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    @objc private func showPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        floatingPanel.setContentSize(NSSize(width: screenFrame.width, height: 300))
        floatingPanel.setFrameOrigin(NSPoint(x: screenFrame.origin.x, y: screenFrame.origin.y - 300))
        floatingPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            floatingPanel.animator().alphaValue = 1
        }
        
        // 显示时开启点击监控
        startClickOutsideMonitor()
    }

    private func hidePanel() {
        // 隐藏前先停止点击监控
        stopClickOutsideMonitor()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            floatingPanel.animator().alphaValue = 0
        } completionHandler: {
            self.floatingPanel.orderOut(nil)
        }
    }
    
    // MARK: - Click Outside Detection
    
    private func startClickOutsideMonitor() {
        // 使用 NSEvent global monitor 检测鼠标点击
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.floatingPanel.isVisible else { return }
            
            // 获取点击位置（屏幕坐标）
            let clickLocation = event.locationInWindow
            
            // 将点击位置转换到屏幕坐标
            guard let window = event.window else {
                // 如果 event.window 为 nil，说明点击不在任何窗口内
                // 这种情况可能是点击在桌面上或其他应用上
                // 检查是否点击在面板外
                if self.isClickOutsidePanel(event) {
                    self.hidePanel()
                }
                return
            }
            
            // 获取点击的窗口在屏幕上的 frame
            if let windowFrame = window.convertToScreen(NSRect(origin: clickLocation, size: NSSize(width: 1, height: 1))) as NSRect? {
                // 检查点击位置是否在面板范围内
                let panelFrame = self.floatingPanel.frame
                
                // 如果点击不在面板内，则关闭面板
                if !NSPointInRect(windowFrame.origin, panelFrame) {
                    // 进一步验证：确保不是点击在面板本身
                    let panelScreenFrame = self.floatingPanel.convertToScreen(NSRect(origin: .zero, size: panelFrame.size))
                    if !NSPointInRect(windowFrame.origin, panelScreenFrame) {
                        self.hidePanel()
                    }
                }
            }
        }
    }
    
    private func stopClickOutsideMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
    
    private func isClickOutsidePanel(_ event: NSEvent) -> Bool {
        guard let screen = NSScreen.main else { return false }
        
        // 获取鼠标在屏幕上的位置
        let mouseLocation = NSEvent.mouseLocation
        
        // 检查鼠标位置是否在面板范围内
        let panelFrame = floatingPanel.frame
        
        // 如果鼠标不在面板内，则认为是点击外面
        return !NSPointInRect(mouseLocation, panelFrame)
    }

    @objc private func clearHistory() {
        clipboardManager.clearHistory()
    }

    @objc private func quit() {
        stopClickOutsideMonitor()
        hotkeyTimer?.invalidate()
        cleanupEventTap()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NSApplication.shared.terminate(nil)
    }

    deinit {
        hotkeyTimer?.invalidate()
        cleanupEventTap()
        stopClickOutsideMonitor()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "📋"
            button.action = #selector(togglePanel)
            button.target = self
        }
        statusItem.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show (⌃V)", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        let contentView = ClipboardContentView(onSelect: { [weak self] item in
            self?.clipboardManager.copyItem(item)
            self?.hidePanel()
        })

        let hostingView = NSHostingView(rootView: contentView)

        floatingPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        floatingPanel.contentView = hostingView
        floatingPanel.title = "ClipBoard"
        floatingPanel.level = .floating
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.titlebarAppearsTransparent = true
        floatingPanel.titleVisibility = .hidden
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.isFloatingPanel = true
        floatingPanel.becomesKeyOnlyIfNeeded = true
        floatingPanel.hidesOnDeactivate = false
        // 允许点击事件穿透（用于检测外部点击）
        floatingPanel.acceptsMouseMovedEvents = true
        floatingPanel.ignoresMouseEvents = false

        floatingPanel.alphaValue = 0
    }
}

// MARK: - Design System Colors

struct ClipBoardColors {
    static let primary = Color(hex: "2563EB")
    static let secondary = Color(hex: "3B82F6")
    static let accent = Color(hex: "F97316")
    static let background = Color(hex: "F8FAFC")
    static let text = Color(hex: "1E293B")
    static let textSecondary = Color(hex: "64748B")
    static let cardBackground = Color.white
    static let border = Color(hex: "E2E8F0")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - SwiftUI Views

struct ClipboardContentView: View {
    let onSelect: (ClipboardItem) -> Void

    @ObservedObject private var manager = ClipboardManager.shared
    @State private var searchText = ""
    @State private var hoveredItemId: UUID?

    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty {
            return manager.items
        }
        return manager.items.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if manager.items.isEmpty {
                emptyStateView
            } else if filteredItems.isEmpty {
                noResultsView
            } else {
                contentView
            }
        }
        .frame(height: 300)
        .background(ClipBoardColors.background)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 16))
                    .foregroundColor(ClipBoardColors.primary)
                Text("ClipBoard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ClipBoardColors.text)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(ClipBoardColors.textSecondary)

                TextField("Search...", text: $searchText)
                    .font(.system(size: 13))
                    .frame(width: 160)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(ClipBoardColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ClipBoardColors.cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ClipBoardColors.border, lineWidth: 1)
            )

            Spacer()

            HStack(spacing: 4) {
                Text("\(manager.items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ClipBoardColors.primary)
                Text("items")
                    .font(.system(size: 12))
                    .foregroundColor(ClipBoardColors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ClipBoardColors.primary.opacity(0.1))
            .cornerRadius(12)

            Button(action: { NSApp.keyWindow?.orderOut(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ClipBoardColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(ClipBoardColors.cardBackground)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var contentView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(filteredItems, id: \.id) { item in
                    ClipboardCard(
                        item: item,
                        isHovered: hoveredItemId == item.id,
                        onClick: { onSelect(item) },
                        onHover: { hovered in
                            hoveredItemId = hovered ? item.id : nil
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(ClipBoardColors.primary.opacity(0.1))
                    .frame(width: 64, height: 64)

                Image(systemName: "clipboard")
                    .font(.system(size: 28))
                    .foregroundColor(ClipBoardColors.primary)
            }

            VStack(spacing: 4) {
                Text("No Clipboard History")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ClipBoardColors.text)

                Text("Copy something to get started")
                    .font(.system(size: 12))
                    .foregroundColor(ClipBoardColors.textSecondary)
            }

            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(ClipBoardColors.textSecondary)

            Text("No results for \"\(searchText)\"")
                .font(.system(size: 13))
                .foregroundColor(ClipBoardColors.textSecondary)

            Spacer()
        }
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let isHovered: Bool
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                previewArea
                    .frame(height: 130)

                Rectangle()
                    .fill(ClipBoardColors.border)
                    .frame(height: 1)

                footerArea
                    .frame(height: 50)
            }
            .frame(width: 200, height: 180)
            .background(ClipBoardColors.cardBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? ClipBoardColors.primary.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHover(hovering)
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var previewArea: some View {
        switch item.type {
        case .text:
            Text(item.content)
                .font(.system(size: 12))
                .foregroundColor(ClipBoardColors.text)
                .lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

        case .image:
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.05))

                if let image = item.loadImage() {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundColor(ClipBoardColors.textSecondary)
                        Text("Image")
                            .font(.system(size: 11))
                            .foregroundColor(ClipBoardColors.textSecondary)
                    }
                }
            }

        case .file:
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.05))

                VStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 28))
                        .foregroundColor(ClipBoardColors.secondary)

                    Text(item.content)
                        .font(.system(size: 11))
                        .foregroundColor(ClipBoardColors.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private var footerArea: some View {
        HStack(spacing: 8) {
            typeBadge

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                Text("Copy")
                    .font(.system(size: 11))
            }
            .foregroundColor(ClipBoardColors.textSecondary)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: typeIcon)
                .font(.system(size: 10))
            Text(typeLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(typeColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(typeColor.opacity(0.1))
        .cornerRadius(6)
    }

    private var typeIcon: String {
        switch item.type {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private var typeLabel: String {
        switch item.type {
        case .text: return "Text"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    private var typeColor: Color {
        switch item.type {
        case .text: return ClipBoardColors.primary
        case .image: return Color.purple
        case .file: return ClipBoardColors.secondary
        }
    }
}

// MARK: - ClipboardManager

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var items: [ClipboardItem] = []

    private var lastChangeCount: Int
    private var timer: Timer?
    private let maxItems = 30
    private let userDefaultsKey = "ClipboardHistory"
    private var imageDirectory: URL

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        imageDirectory = appSupport.appendingPathComponent("ClipBoard/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        loadHistory()
        startMonitoring()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let pasteboard = NSPasteboard.general

        // 优先检查文件类型
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            DispatchQueue.main.async {
                self.addFile(fileURLs.first!)
            }
            return
        }

        // 检查图片
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: imageData),
           image.tiffRepresentation != nil {
            DispatchQueue.main.async {
                self.addImage(image)
            }
            return
        }

        // 检查纯文本
        if let content = pasteboard.string(forType: .string), !content.isEmpty {
            DispatchQueue.main.async {
                self.addText(content)
            }
        }
    }

    private func addText(_ content: String) {
        if let index = items.firstIndex(where: { $0.type == .text && $0.content == content }) {
            items.remove(at: index)
        }
        items.insert(ClipboardItem(type: .text, content: content), at: 0)
        trimItems()
        saveHistory()
    }

    private func addImage(_ image: NSImage) {
        let hash = image.tiffRepresentation?.hashValue ?? Int.random(in: 0...999999999)
        let filename = "\(hash).png"
        let fileURL = imageDirectory.appendingPathComponent(filename)

        if let data = image.pngData() {
            try? data.write(to: fileURL)
        }

        if items.contains(where: { $0.type == .image && $0.imagePath == filename }) {
            return
        }

        items.insert(ClipboardItem(type: .image, content: "Image", imagePath: filename), at: 0)
        trimItems()
        saveHistory()
    }

    private func addFile(_ url: URL) {
        if items.contains(where: { $0.type == .file && $0.filePath == url.path }) {
            return
        }
        items.insert(ClipboardItem(type: .file, content: url.lastPathComponent, filePath: url.path), at: 0)
        trimItems()
        saveHistory()
    }

    private func trimItems() {
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    func clearHistory() {
        items.removeAll()
        saveHistory()
    }

    func copyItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            pasteboard.setString(item.content, forType: .string)
        case .image:
            if let image = item.loadImage() {
                pasteboard.writeObjects([image])
            }
        case .file:
            if let path = item.filePath {
                pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            items = decoded
        }
    }
}

// MARK: - Models

enum ClipboardItemType: String, Codable {
    case text
    case image
    case file
}

struct ClipboardItem: Identifiable, Codable {
    let id: UUID
    let type: ClipboardItemType
    let content: String
    var imagePath: String?
    var filePath: String?

    init(type: ClipboardItemType, content: String, imagePath: String? = nil, filePath: String? = nil) {
        self.id = UUID()
        self.type = type
        self.content = content
        self.imagePath = imagePath
        self.filePath = filePath
    }

    func loadImage() -> NSImage? {
        guard type == .image, let path = imagePath else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let imageURL = appSupport.appendingPathComponent("ClipBoard/Images").appendingPathComponent(path)
        return NSImage(contentsOf: imageURL)
    }
}

// MARK: - NSImage Extension

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }
}