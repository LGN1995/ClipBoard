import AppKit
import SwiftUI
import Carbon.HIToolbox
import HotKey

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var floatingPanel: NSPanel!
    private var clipboardManager = ClipboardManager.shared

    // 全局鼠标点击监控
    private var clickMonitor: Any?

    // HotKey for global shortcut
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupKeyboardMonitoring()
    }

    // MARK: - Keyboard Monitoring

    private func setupKeyboardMonitoring() {
        hotKey = HotKey(key: .v, modifiers: [.command, .shift])
        hotKey?.keyDownHandler = { [weak self] in
            self?.togglePanel()
        }
    }

    private func checkAndRestoreTap() {}

    private func recreateEventTap() {}

    private func setupCGEventTap() {}
    
    private func cleanupKeyboardMonitoring() {
        hotKey = nil
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

        let panelHeight: CGFloat = 220
        let x = screenFrame.origin.x
        let y = screenFrame.origin.y + 1  // 底部留 1pt 边距
        let width = screenFrame.width
        floatingPanel.setFrame(NSRect(x: x, y: y, width: width, height: panelHeight), display: true)
        floatingPanel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            floatingPanel.animator().alphaValue = 1
        }

        startClickOutsideMonitor()
    }

    @objc private func hidePanel() {
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
        stopClickOutsideMonitor()
        
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.floatingPanel.isVisible else { return }
            
            let mouseLocation = NSEvent.mouseLocation
            let panelFrame = self.floatingPanel.frame
            
            if !NSPointInRect(mouseLocation, panelFrame) {
                DispatchQueue.main.async {
                    self.hidePanel()
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

    @objc private func clearHistory() {
        clipboardManager.clearHistory()
    }

    @objc private func quit() {
        cleanupKeyboardMonitoring()
        stopClickOutsideMonitor()
        NSApplication.shared.terminate(nil)
    }

    deinit {
        cleanupKeyboardMonitoring()
        stopClickOutsideMonitor()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                let rotatedImage = image.withSymbolConfiguration(config)?.rotated180()
                let tintedImage = rotatedImage?.tinted(with: .white)
                button.image = tintedImage
                button.imagePosition = .imageOnly
            } else {
                button.title = "✂"
            }
            button.action = #selector(togglePanel)
            button.target = self
        }
        statusItem.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示面板 (⌘⇧V)", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "清空历史", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    @objc private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "设置"
        alert.informativeText = ""
        alert.alertStyle = .informational

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))

        // 保留天数标签
        let daysLabel = NSTextField(labelWithString: "历史记录保留天数：")
        daysLabel.frame = NSRect(x: 0, y: 70, width: 130, height: 20)
        contentView.addSubview(daysLabel)

        // 保留天数选择
        let daysPopup = NSPopUpButton(frame: NSRect(x: 130, y: 68, width: 130, height: 26))
        let daysOptions = [7, 30, 90, 180]
        for days in daysOptions {
            daysPopup.addItem(withTitle: "\(days) 天")
        }
        daysPopup.selectItem(withTitle: "\(ClipboardManager.shared.retentionDays) 天")
        contentView.addSubview(daysPopup)

        // 开机自启标签
        let launchLabel = NSTextField(labelWithString: "开机自动启动：")
        launchLabel.frame = NSRect(x: 0, y: 35, width: 130, height: 20)
        contentView.addSubview(launchLabel)

        // 开机自启开关
        let launchSwitch = NSSwitch(frame: NSRect(x: 130, y: 35, width: 50, height: 20))
        launchSwitch.state = LaunchManager.shared.isEnabled ? .on : .off
        launchSwitch.target = self
        launchSwitch.action = #selector(launchSwitchChanged(_:))
        contentView.addSubview(launchSwitch)

        alert.accessoryView = contentView
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let title = daysPopup.selectedItem?.title,
               let days = Int(title.replacingOccurrences(of: " 天", with: "")) {
                ClipboardManager.shared.retentionDays = days
            }
        }
    }

    @objc private func launchSwitchChanged(_ sender: NSSwitch) {
        LaunchManager.shared.isEnabled = sender.state == .on
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
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.masksToBounds = true

        hostingView.frame = visualEffectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        visualEffectView.addSubview(hostingView)

        floatingPanel.contentView = visualEffectView
        floatingPanel.level = .floating
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.isFloatingPanel = true
        floatingPanel.becomesKeyOnlyIfNeeded = true
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.acceptsMouseMovedEvents = true
        floatingPanel.backgroundColor = .clear
        floatingPanel.isOpaque = false
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.isFloatingPanel = true
        floatingPanel.becomesKeyOnlyIfNeeded = true
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.acceptsMouseMovedEvents = true
        floatingPanel.backgroundColor = .clear
        floatingPanel.isOpaque = false

        // Hide traffic lights completely
        floatingPanel.standardWindowButton(.closeButton)?.isHidden = true
        floatingPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        floatingPanel.standardWindowButton(.zoomButton)?.isHidden = true

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
    @State private var hoveredItemId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if manager.items.isEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
        .frame(height: 220)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 8, height: 8)
                Text("历史剪切板")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("\(manager.items.count)")
                    .font(.system(size: 12, weight: .semibold))
                Text("条记录")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var contentView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(manager.items, id: \.id) { item in
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
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No clipboard history")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let isHovered: Bool
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    private var curledCorner: some View {
        ZStack {
            CornerCurvedShape()
                .fill(Color.black.opacity(0.15))
                .frame(width: 20, height: 20)
                .offset(x: 68, y: -62)

            CornerCutShape()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 20, height: 20)
                .offset(x: 68, y: -62)
        }
    }

    var body: some View {
        Button(action: onClick) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    previewArea
                        .frame(height: 100)

                    Divider()
                        .background(Color.secondary.opacity(0.2))

                    footerArea
                        .frame(height: 36)
                }
                .frame(width: 160, height: 136)
                .background(.regularMaterial)
                .clipShape(CornerCutShape())
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(isHovered ? 0.3 : 0.1), lineWidth: 1)
                )

                curledCorner
            }
            .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 8 : 4, x: 2, y: isHovered ? 4 : 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHover(hovering)
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var previewArea: some View {
        switch item.type {
        case .text:
            Text(item.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)

        case .image:
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.05))

                if let image = item.loadImage() {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                        .padding(6)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
            }

        case .file:
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.05))

                VStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.accentColor)

                    Text(item.content)
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    private var footerArea: some View {
        HStack(spacing: 6) {
            typeBadge

            Spacer()

            if isHovered {
                HStack(spacing: 3) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                    Text("Copy")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
    }

    private var typeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: typeIcon)
                .font(.system(size: 8))
            Text(typeLabel)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(typeColor)
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
        case .text: return .blue
        case .image: return .purple
        case .file: return .accentColor
        }
    }
}

// MARK: - ClipboardManager

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var items: [ClipboardItem] = []

    private var lastChangeCount: Int
    private var timer: Timer?
    private let maxRetentionDays = 7
    private let maxItems = 200
    private let userDefaultsKey = "ClipboardHistory"
    private let retentionDaysKey = "ClipboardRetentionDays"
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

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            DispatchQueue.main.async {
                self.addFile(fileURLs.first!)
            }
            return
        }

        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: imageData),
           image.tiffRepresentation != nil {
            DispatchQueue.main.async {
                self.addImage(image)
            }
            return
        }

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
        // 按条数限制
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        // 按天数清理
        let retentionDays = UserDefaults.standard.integer(forKey: retentionDaysKey)
        let actualDays = retentionDays > 0 ? retentionDays : maxRetentionDays
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -actualDays, to: Date()) ?? Date()
        items = items.filter { $0.timestamp > cutoffDate }
    }

    private func cleanupOldImages() {
        // 清理不再被引用的图片文件
        let usedFilenames = Set(items.compactMap { $0.imagePath })
        let imageFiles = (try? FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in imageFiles where !usedFilenames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    var retentionDays: Int {
        get {
            let days = UserDefaults.standard.integer(forKey: retentionDaysKey)
            return days > 0 ? days : maxRetentionDays
        }
        set {
            UserDefaults.standard.set(newValue, forKey: retentionDaysKey)
            trimItems()
            saveHistory()
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
    let timestamp: Date

    init(type: ClipboardItemType, content: String, imagePath: String? = nil, filePath: String? = nil) {
        self.id = UUID()
        self.type = type
        self.content = content
        self.imagePath = imagePath
        self.filePath = filePath
        self.timestamp = Date()
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

// MARK: - Shape Definitions

// 右上角裁剪形状（翻页卷角效果）
struct CornerCutShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let cornerSize: CGFloat = 20

        path.move(to: CGPoint(x: cornerSize, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.height))

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: cornerSize))

        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width - cornerSize, y: 0))

        path.closeSubpath()

        return path
    }
}

// 卷角曲线形状（翻页卷起的弧度）
struct CornerCurvedShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let cornerSize: CGFloat = 20

        path.move(to: CGPoint(x: rect.width, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - cornerSize, y: cornerSize),
            control: CGPoint(x: rect.width - 4, y: 4)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: 0),
            control: CGPoint(x: rect.width, y: 0)
        )

        return path
    }
}

// MARK: - NSImage Extension

extension NSImage {
    func rotated180() -> NSImage {
        let rotated = NSImage(size: self.size)
        rotated.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: self.size.width, yBy: self.size.height)
        transform.rotate(byDegrees: 180)
        transform.concat()
        self.draw(in: NSRect(origin: .zero, size: self.size),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .sourceOver,
                  fraction: 1.0)
        rotated.unlockFocus()
        return rotated
    }

    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: - Launch Manager

class LaunchManager {
    static let shared = LaunchManager()

    private let launchAgentKey = "LaunchAtLogin"
    private let bundleIdentifier = "com.clipboard.app"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: launchAgentKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: launchAgentKey)
            if newValue {
                enableLaunchAtLogin()
            } else {
                disableLaunchAtLogin()
            }
        }
    }

    private func enableLaunchAtLogin() {
        guard let appPath = Bundle.main.executablePath else { return }
        let plistContent: [String: Any] = [
            "Label": bundleIdentifier,
            "ProgramArguments": [appPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plistPath = launchAgentsDir.appendingPathComponent("\(bundleIdentifier).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try data.write(to: plistPath)
        } catch {
            // 忽略错误
        }
    }

    private func disableLaunchAtLogin() {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("\(bundleIdentifier).plist")
        try? FileManager.default.removeItem(at: plistPath)
    }
}