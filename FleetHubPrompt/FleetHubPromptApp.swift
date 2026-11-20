//
//  FleetHubPromptApp.swift
//  FleetHubPrompt
//
//  The approval prompt FleetHub shows on a managed Mac before a technician
//  shares its screen.
//
//  This small app is installed on the Macs being supported, not on the
//  technician's Mac. FleetHub starts it over SSH, in the logged-in person's
//  session, with the text to show. It asks one question and ends; the exit
//  status is the answer:
//
//      0   Allow
//      2   Deny (also: the window was closed, or Escape was pressed)
//      4   Nobody answered before the time ran out
//      64  It was started with arguments it does not understand
//
//  Arguments:
//      --title <text>      Heading. Default "Screen Sharing Request".
//      --message <text>    The request, in a sentence or two.
//      --timeout <seconds> Time to answer. Default 60, between 5 and 600.
//      --icon <path>       An image to show instead of the FleetHub icon.
//      --version           Prints the version and build, then ends.
//
//  It reads no settings, stores nothing, and talks to nothing. Neither
//  button is the default, so pressing Return never answers by accident.
//

import AppKit
import SwiftUI

// MARK: - Arguments

struct PromptRequest {
    var title = "Screen Sharing Request"
    var message = "A technician from IT is asking to view and control this Mac\u{2019}s screen. Allow only if you are expecting this."
    var timeout = 60
    var iconPath: String?

    enum ParseResult {
        case request(PromptRequest)
        case version
        case invalid(String)
    }

    static func parse(_ arguments: [String]) -> ParseResult {
        var request = PromptRequest()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--version":
                return .version
            case "--title":
                guard let text = value() else { return .invalid("--title needs a value") }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { request.title = text }
            case "--message":
                guard let text = value() else { return .invalid("--message needs a value") }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { request.message = text }
            case "--timeout":
                guard let text = value(), let seconds = Int(text) else { return .invalid("--timeout needs a number") }
                request.timeout = min(600, max(5, seconds))
            case "--icon":
                guard let text = value() else { return .invalid("--icon needs a path") }
                request.iconPath = text
            default:
                // macOS adds its own arguments (-NSDocumentRevisionsDebugMode
                // and the like) to some launches; anything else is a mistake.
                if flag.hasPrefix("-NS") || flag.hasPrefix("-Apple") {
                    index += 1
                } else {
                    return .invalid("unknown argument \(flag)")
                }
            }
            index += 1
        }
        return .request(request)
    }
}

enum PromptExit: Int32 {
    case allow = 0
    case deny = 2
    case timedOut = 4
    case usage = 64
}

// MARK: - Theme (FleetHub's palette; this app stands alone)

private enum PromptTheme {
    static let surface = Color(light: 0xFFFFFF, dark: 0x171B24)
    static let border = Color(light: 0xE3E7EF, dark: 0x262C38)
    static let ink = Color(light: 0x111827, dark: 0xF2F4F8)
    static let muted = Color(light: 0x5B6475, dark: 0xA3ACBD)
    static let accentFill = Color(light: 0x2952E3, dark: 0x3D63F0)
    static let accentSoft = Color(light: 0xE7EDFF, dark: 0x1A2347)
    static let accentInk = Color(light: 0x1E3A9E, dark: 0xAFC1FF)
    static let fieldBorder = Color(light: 0xD5DBE6, dark: 0x343C4C)
    static let trough = Color(light: 0xE9EDF4, dark: 0x0A0D13)
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - View

@MainActor
final class PromptModel: ObservableObject {
    let request: PromptRequest
    let icon: NSImage
    @Published var secondsLeft: Int
    private var timer: Timer?
    private let finish: (PromptExit) -> Void

    init(request: PromptRequest, finish: @escaping (PromptExit) -> Void) {
        self.request = request
        self.finish = finish
        secondsLeft = request.timeout
        if let path = request.iconPath, let image = NSImage(contentsOfFile: path) {
            icon = image
        } else {
            icon = NSApp.applicationIconImage
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        secondsLeft -= 1
        if secondsLeft <= 0 { answer(.timedOut) }
    }

    func answer(_ result: PromptExit) {
        timer?.invalidate()
        timer = nil
        finish(result)
    }
}

struct PromptView: View {
    @ObservedObject var model: PromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: model.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("FLEETHUB")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(PromptTheme.accentInk)
                    Text(model.request.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(PromptTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(model.request.message)
                .font(.system(size: 14))
                .foregroundStyle(PromptTheme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PromptTheme.trough)
                        Capsule().fill(PromptTheme.accentFill)
                            .frame(width: proxy.size.width * fraction)
                            .animation(.linear(duration: 1), value: model.secondsLeft)
                    }
                }
                .frame(height: 5)
                Text("If you do not answer in \(model.secondsLeft) second\(model.secondsLeft == 1 ? "" : "s"), the request is declined.")
                    .font(.system(size: 12))
                    .foregroundStyle(PromptTheme.muted)
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                Spacer()
                Button { model.answer(.deny) } label: {
                    Text("Deny")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PromptTheme.ink)
                        .frame(minWidth: 96, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(PromptTheme.fieldBorder, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button { model.answer(.allow) } label: {
                    Text("Allow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 96, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(PromptTheme.accentFill))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(PromptTheme.surface)
    }

    private var fraction: CGFloat {
        guard model.request.timeout > 0 else { return 0 }
        return max(0, min(1, CGFloat(model.secondsLeft) / CGFloat(model.request.timeout)))
    }
}

// MARK: - App

@MainActor
final class PromptAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let request: PromptRequest
    private var window: NSWindow?
    private var model: PromptModel?

    init(request: PromptRequest) {
        self.request = request
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = PromptModel(request: request) { result in
            exit(result.rawValue)
        }
        self.model = model

        let hosting = NSHostingController(rootView: PromptView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "FleetHub"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Above ordinary windows and on every Space, so it is seen wherever
        // the person is working, full-screen apps included.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // No button starts with keyboard focus: Return and Space do nothing
        // until the person chooses.
        window.makeFirstResponder(nil)
        model.start()
    }

    /// Closing the window is a refusal.
    func windowWillClose(_ notification: Notification) {
        model?.answer(.deny)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting (Command-Q) is a refusal too.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        exit(PromptExit.deny.rawValue)
    }
}

@main
enum FleetHubPromptMain {
    @MainActor
    static func main() {
        switch PromptRequest.parse(Array(CommandLine.arguments.dropFirst())) {
        case .version:
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            print("FleetHub Prompt \(version) (\(build))")
            exit(0)
        case .invalid(let reason):
            FileHandle.standardError.write(Data("FleetHubPrompt: \(reason)\n".utf8))
            exit(PromptExit.usage.rawValue)
        case .request(let request):
            let application = NSApplication.shared
            #if DEBUG
            // Development only: FLEETHUB_PROMPT_RENDER=<file.png> draws the
            // prompt to a picture and ends, so its look can be checked
            // without a person at the screen.
            if let path = ProcessInfo.processInfo.environment["FLEETHUB_PROMPT_RENDER"] {
                if ProcessInfo.processInfo.environment["FLEETHUB_PROMPT_DARK"] != nil {
                    application.appearance = NSAppearance(named: .darkAqua)
                }
                let model = PromptModel(request: request) { _ in }
                let renderer = ImageRenderer(content: PromptView(model: model)
                    .environment(\.colorScheme, application.appearance == nil ? .light : .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            #endif
            let delegate = PromptAppDelegate(request: request)
            application.delegate = delegate
            // No Dock icon and no menu bar: it is one window.
            application.setActivationPolicy(.accessory)
            application.run()
            _ = delegate
        }
    }
}
