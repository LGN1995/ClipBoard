import AppKit
import SwiftUI
import Carbon.HIToolbox
import CoreGraphics

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var floatingPanel: NSPanel!
    private var clipboardManager = ClipboardManager.shared
    private var eventMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupGlobalHotKey()
    }

    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            print("⚠️ 需要辅助功能权限才能使用全局快捷键")
            print("请在 系统设置 > 隐私与安全性 > 辅助功能 中添加此应用")
        }
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

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

        floatingPanel.alphaValue = 0
    }

    private func setupGlobalHotKey() {
        // 方法1: 本地监控（不需要辅助功能权限，但只在app focus时生效）
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }

        // 方法2: CGEventTap（需要更高级权限）
        setupCGEventTap()
    }

    private func setupCGEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                if flags.contains(.maskControl) && keyCode == kVK_ANSI_V {
                    DispatchQueue.main.async {
                        appDelegate.togglePanel()
                    }
                }
            }

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
        } else {
            print("⚠️ CGEventTap 创建失败，尝试使用权限查询...")
            queryAccessibilityPermissions()
        }
    }

    private func queryAccessibilityPermissions() {
        // 检查辅助功能权限状态
        let trusted = AXIsProcessTrusted()
        print("辅助功能权限状态: \(trusted)")

        if !trusted {
            // 提示用户需要授权
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

        floatingPanel.setContentSize(NSSize(width: screenFrame.width, height: 260))
        floatingPanel.setFrameOrigin(NSPoint(x: screenFrame.origin.x, y: screenFrame.origin.y - 260))
        floatingPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            floatingPanel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            floatingPanel.animator().alphaValue = 0
        } completionHandler: {
            self.floatingPanel.orderOut(nil)
        }
    }

    @objc private func clearHistory() {
        clipboardManager.clearHistory()
    }

    @objc private func quit() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - SwiftUI Views

struct ClipboardContentView: View {
    let onSelect: (ClipboardItem) -> Void

    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("📋 ClipBoard")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { NSApp.keyWindow?.orderOut(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if manager.items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No clipboard history")
                        .foregroundColor(.secondary)
                    Text("Press ⌃V to open")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(manager.items, id: \.id) { item in
                            ClipboardCard(item: item) {
                                onSelect(item)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(height: 260)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 8) {
                if item.type == .image {
                    if let image = item.loadImage() {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 180, height: 160)
                    } else {
                        ZStack {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                            Text("Image")
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 180, height: 160)
                    }
                } else if item.type == .file {
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                        VStack {
                            Image(systemName: "doc")
                                .font(.largeTitle)
                            Text(item.content)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                    }
                    .frame(width: 180, height: 160)
                } else {
                    Text(item.content)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(8)
                        .frame(width: 180, height: 160, alignment: .topLeading)
                }

                Spacer()

                Text(item.type == .image ? "Image" : item.content)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 204, height: 220)
            .background(Color.white)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
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

        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: imageData) {
            DispatchQueue.main.async {
                self.addImage(image)
            }
            return
        }

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            DispatchQueue.main.async {
                self.addFile(fileURLs.first!)
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