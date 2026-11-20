//
//  ScreenShareApproval.swift
//  FleetHub
//
//  Asks the person at a Mac whether a technician may share its screen.
//
//  When the features profile turns `computers.screenSharePrompt` on, and
//  the technician's roles do not exempt them (`screenShareWithoutPrompt`),
//  Screen Share first shows an Allow / Deny prompt on the target Mac and
//  opens the session only on Allow.
//
//  The prompt is shown by a tool on the target Mac, run over SSH with the
//  Jamf management account: the FleetHub Prompt app, swiftDialog, or
//  jamfHelper (the profile picks one). This file builds that command and
//  reads its answer; DeviceCommandExecutor runs it.
//
//  ENFORCED BY FLEETHUB, NOT BY macOS. Someone who holds the management
//  account's password can still open Screen Sharing directly.
//

import Foundation

enum ScreenShareApproval {

    typealias Method = FeaturesConfiguration.ScreenSharePromptMethod

    /// What the prompt on the target Mac came back with.
    enum Outcome: Equatable {
        case allowed
        case denied
        case timedOut
        /// Nobody is logged in at the Mac, so there was nobody to ask.
        case noUserLoggedIn
        /// The prompt tool is not installed on the target Mac.
        case toolMissing
        /// The management account could not get administrator rights.
        case adminRightsRefused
        case failed(String)
    }

    struct Request {
        let method: Method
        let title: String
        /// Already has the technician's and the device's names filled in.
        let message: String
        let iconPath: String?
        let timeoutSeconds: Int
    }

    /// Where each tool lives on a managed Mac.
    static func toolPath(for method: Method) -> String {
        switch method {
        case .fleethubPrompt:
            "/Library/Application Support/FleetHub/FleetHubPrompt.app/Contents/MacOS/FleetHubPrompt"
        case .swiftDialog:
            "/usr/local/bin/dialog"
        case .jamfHelper:
            "/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
        }
    }

    /// The name a failure message uses for the tool.
    static func toolName(for method: Method) -> String {
        switch method {
        case .fleethubPrompt: "The FleetHub Prompt app"
        case .swiftDialog: "swiftDialog"
        case .jamfHelper: "jamfHelper"
        }
    }

    /// Fills `{technician}` and `{device}` in the configured message.
    static func message(template: String, technician: String, device: String) -> String {
        let name = technician.trimmingCharacters(in: .whitespacesAndNewlines)
        return template
            .replacingOccurrences(of: "{technician}", with: name.isEmpty ? "A technician" : name)
            .replacingOccurrences(of: "{device}", with: device)
    }

    // MARK: - Command

    private static let marker = "FLEETHUB_PROMPT="

    /// One argument, quoted so a shell passes it through untouched whatever
    /// it contains. Every value that reaches the target Mac goes through
    /// this: titles and names come from a profile and from Entra.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func toolArguments(_ request: Request) -> [String] {
        let timeout = String(request.timeoutSeconds)
        switch request.method {
        case .fleethubPrompt:
            var arguments = ["--title", request.title, "--message", request.message, "--timeout", timeout]
            if let icon = request.iconPath { arguments += ["--icon", icon] }
            return arguments
        case .swiftDialog:
            var arguments = ["--title", request.title, "--message", request.message,
                             "--button1text", "Allow", "--button2text", "Deny",
                             "--timer", timeout, "--ontop", "--moveable", "--small"]
            if let icon = request.iconPath { arguments += ["--icon", icon] }
            return arguments
        case .jamfHelper:
            // Deny is the default and the cancel button, so Return, Escape
            // and the timeout all refuse.
            var arguments = ["-windowType", "utility", "-title", request.title,
                             "-description", request.message,
                             "-button1", "Allow", "-button2", "Deny",
                             "-defaultButton", "2", "-cancelButton", "2", "-timeout", timeout]
            if let icon = request.iconPath { arguments += ["-icon", icon] }
            return arguments
        }
    }

    /// The command to run on the target Mac. It prints one line starting
    /// with `FLEETHUB_PROMPT=`; `parse` reads it. The management account's
    /// password is expected on standard input, for sudo: showing a window
    /// in another person's session needs administrator rights.
    static func remoteCommand(for request: Request) -> String {
        let tool = shellQuote(toolPath(for: request.method))
        let invocation = ([tool] + toolArguments(request).map(shellQuote)).joined(separator: " ")
        // jamfHelper reports the button on standard output; the others by
        // exit status. Both are passed back.
        let report = #"echo "FLEETHUB_PROMPT=exit:$c:$(printf %s "$r" | /usr/bin/tr -cd 0-9 | /usr/bin/cut -c1-4)""#
        let asConsoleUser = #"r=$(/bin/launchctl asuser "$1" /usr/bin/sudo -u "$2" "# + invocation + #" 2>/dev/null); c=$?; "# + report
        let direct = "r=$(" + invocation + " 2>/dev/null); c=$?; " + report
        let script = """
        u=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
        case "$u" in ''|root|loginwindow|_mbsetupuser) echo \(marker)nouser; exit 0;; esac
        i=$(/usr/bin/id -u "$u" 2>/dev/null) || { echo \(marker)nouser; exit 0; }
        [ -x \(tool) ] || { echo \(marker)missing; exit 0; }
        if [ "$(/usr/bin/id -u)" = "$i" ]; then
        \(direct)
        else
        o=$(/usr/bin/sudo -S -p '' /bin/sh -c \(shellQuote(asConsoleUser)) fleethub-prompt "$i" "$u" 2>/dev/null)
        case "$o" in *\(marker)*) echo "$o";; *) echo \(marker)sudo;; esac
        fi
        """
        return "/bin/sh -c " + shellQuote(script)
    }

    // MARK: - Answer

    /// Reads the command's output. Anything that is not a clear Allow is
    /// some kind of refusal: the session never opens on an unreadable answer.
    static func parse(output: String, method: Method) -> Outcome {
        guard let line = output.split(whereSeparator: \.isNewline).map(String.init)
            .last(where: { $0.hasPrefix(marker) }) else {
            return .failed("the Mac did not report an answer")
        }
        let value = String(line.dropFirst(marker.count))
        switch value {
        case "nouser": return .noUserLoggedIn
        case "missing": return .toolMissing
        case "sudo": return .adminRightsRefused
        default: break
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "exit", let status = Int(parts[1]) else {
            return .failed("the Mac reported an answer FleetHub does not understand")
        }
        let printed = parts.count > 2 ? Int(parts[2]) : nil

        switch method {
        case .fleethubPrompt:
            switch status {
            case 0: return .allowed
            case 2: return .denied
            case 4: return .timedOut
            default: return .failed("the FleetHub Prompt app ended with code \(status)")
            }
        case .swiftDialog:
            switch status {
            case 0: return .allowed
            case 2, 10: return .denied
            case 4: return .timedOut
            default: return .failed("swiftDialog ended with code \(status)")
            }
        case .jamfHelper:
            // The printed button wins when there is one.
            switch printed ?? status {
            case 0: return status == 0 ? .allowed : .failed("jamfHelper ended with code \(status)")
            case 2: return .denied
            default: return .failed("jamfHelper ended with code \(status)")
            }
        }
    }
}
