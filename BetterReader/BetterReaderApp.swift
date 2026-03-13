import AppKit
import Carbon
import SwiftUI

@main
struct BetterReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appController = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appController.start()
    }
}

@MainActor
final class AppController: NSObject {
    private var statusItem: NSStatusItem?
    private var hotKeyController: HotKeyController?
    private var accessibilityPollingTimer: Timer?
    private var isCapturingSelection = false
    private let textRetrieval = TextRetrievalService()
    private let debugWindowController = DebugWindowController()

    func start() {
        installStatusItem()
        prepareHotKey()
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "headphones",
            accessibilityDescription: "BetterReader"
        )
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()

        let openReader = NSMenuItem(title: "Open reader", action: nil, keyEquivalent: "")
        openReader.isEnabled = false
        menu.addItem(openReader)

        let selectVoice = NSMenuItem(title: "Select voice", action: nil, keyEquivalent: "")
        selectVoice.isEnabled = false
        menu.addItem(selectVoice)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func prepareHotKey() {
        guard hotKeyController == nil else {
            return
        }

        guard textRetrieval.ensureAccessibilityPermission(prompt: true) else {
            startAccessibilityPolling()
            return
        }

        registerHotKey()
    }

    private func startAccessibilityPolling() {
        guard accessibilityPollingTimer == nil else {
            return
        }

        accessibilityPollingTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(pollAccessibilityPermission),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func pollAccessibilityPermission(_ timer: Timer) {
        guard textRetrieval.ensureAccessibilityPermission(prompt: false) else {
            return
        }

        timer.invalidate()
        accessibilityPollingTimer = nil
        registerHotKey()
    }

    private func registerHotKey() {
        guard hotKeyController == nil else {
            return
        }

        let controller = HotKeyController { [weak self] in
            self?.handleOptionP()
        }
        guard controller.register() else {
            presentHotKeyInstallAlert()
            return
        }

        hotKeyController = controller
    }

    private func handleOptionP() {
        guard textRetrieval.ensureAccessibilityPermission(prompt: true) else {
            startAccessibilityPolling()
            return
        }

        guard isCapturingSelection == false else {
            return
        }

        isCapturingSelection = true

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let selectedText =
                await self.textRetrieval.selectedTextFromFocusedApp() ?? "No selected text found."
            self.isCapturingSelection = false
            self.debugWindowController.show(text: selectedText)
        }
    }

    private func presentHotKeyInstallAlert() {
        let alert = NSAlert()
        alert.messageText = "Global Hotkey Unavailable"
        alert.informativeText =
            "BetterReader could not install the global Option+P interceptor. Grant Accessibility access, then relaunch the app if needed."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
            let settingsURL = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class DebugWindowController {
    private let window: NSWindow
    private let textView: NSTextView

    init() {
        textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = "Press Option+P to print selected text."

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterReader Debug"
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
    }

    func show(text: String) {
        textView.string = text

        if window.isVisible == false {
            window.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

final class HotKeyController {
    private let handler: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    func register() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { _, type, event, userData in
                    guard let userData else {
                        return Unmanaged.passUnretained(event)
                    }

                    let controller = Unmanaged<HotKeyController>.fromOpaque(userData)
                        .takeUnretainedValue()
                    return controller.handleEvent(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            guard isHijackedHotKey(event) else {
                return Unmanaged.passUnretained(event)
            }

            let handler = self.handler
            Task { @MainActor in
                handler()
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func isHijackedHotKey(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let relevantFlags = event.flags.intersection([
            .maskShift,
            .maskControl,
            .maskCommand,
            .maskAlternate,
        ])

        return keyCode == Int64(kVK_ANSI_P) && relevantFlags == .maskAlternate
    }
}
