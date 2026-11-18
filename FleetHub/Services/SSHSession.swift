//
//  SSHSession.swift
//  FleetHub
//
//  One SSH connection to a managed Mac, made with the Mac's own /usr/bin/ssh.
//
//  How it works
//  ------------
//  1. A background "master" ssh signs in once, with the password handed to
//     it through SSH_ASKPASS. Nothing is typed and no terminal is involved,
//     so success or failure is known before any window opens.
//  2. The terminal window then runs a second ssh that reuses the master's
//     connection (OpenSSH connection sharing). It needs no password.
//
//  The password
//  ------------
//  It is never written to disk, put in an argument list, or placed in the
//  environment. ssh asks for it by running FleetHub's own binary as the
//  ask-pass helper; the helper reads it from a one-shot named pipe in a
//  folder only this user can open. The pipe is served once and removed.
//
//  Host keys
//  ---------
//  FleetHub keeps its own known-hosts file and never touches ~/.ssh. A key
//  is stored under the device's serial number rather than its address, so a
//  reused IP address is not mistaken for a changed Mac. A first connection
//  is accepted and remembered; a key that later changes stops the
//  connection until the operator removes the saved one.
//

import Foundation
import Network

struct SSHTarget {
    let host: String
    let port: Int
    let username: String
    /// Name the host key is saved under (the device's serial number).
    let hostKeyAlias: String
}

enum SSHFailure: Error, Equatable {
    case hostKeyChanged
    case permissionDenied
    case connectionRefused
    case timedOut
    case other(String)

    /// Reads ssh's own error text.
    static func classify(_ output: String) -> SSHFailure {
        let text = output.lowercased()
        if text.contains("remote host identification has changed") || text.contains("host key verification failed")
            || text.contains("offending") {
            return .hostKeyChanged
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return .permissionDenied
        }
        if text.contains("connection refused") { return .connectionRefused }
        if text.contains("timed out") || text.contains("no route to host") || text.contains("network is unreachable") {
            return .timedOut
        }
        let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return .other(lastLine.isEmpty ? "ssh ended without saying why." : lastLine)
    }
}

final class SSHSession: @unchecked Sendable {
    let target: SSHTarget
    private let workDirectory: URL
    private let controlPath: String
    private var master: Process?
    private let lock = NSLock()
    private var closed = false

    static let sshPath = "/usr/bin/ssh"
    /// Environment variable that tells a FleetHub process it was started by
    /// ssh as the ask-pass helper, and where to read the password.
    static let askPassPipeVariable = "FLEETHUB_ASKPASS_PIPE"

    init(target: SSHTarget) throws {
        self.target = target
        // Short path: a control socket path has a hard length limit.
        let name = "fh-ssh-" + String(UUID().uuidString.prefix(8)).lowercased()
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        controlPath = workDirectory.appendingPathComponent("cm").path
    }

    deinit { close() }

    // MARK: - Known hosts

    static var knownHostsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("FleetHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ssh_known_hosts")
    }

    /// Forgets the saved host key for a device, so the next connection
    /// accepts and saves whatever key the Mac presents.
    @discardableResult
    static func removeSavedHostKey(alias: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-R", alias, "-f", knownHostsURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            // ssh-keygen leaves a ".old" copy holding the removed key.
            try? FileManager.default.removeItem(atPath: knownHostsURL.path + ".old")
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Reachability

    /// True when something accepts a TCP connection on the SSH port. This
    /// is a better test than ping: many networks drop ping, and a ping
    /// reply does not mean Remote Login is on.
    static func isReachable(host: String, port: Int, timeout: TimeInterval = 6) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let finish: @Sendable (Bool) -> Void = { result in
                guard resumed.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: - Connecting

    private var commonOptions: [String] {
        [
            "-F", "/dev/null",
            "-S", controlPath,
            "-p", String(target.port),
            "-l", target.username,
            // Quoted: ssh splits this value on spaces, and the path has one.
            "-o", "UserKnownHostsFile=\"\(Self.knownHostsURL.path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(target.hostKeyAlias)",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
    }

    /// Signs in. Returns when the connection is up, or throws why it is not.
    /// `password` is used once and not kept.
    func connect(password: String, timeout: TimeInterval = 30) async throws {
        let pipePath = workDirectory.appendingPathComponent("pw").path
        guard mkfifo(pipePath, 0o600) == 0 else {
            throw SSHFailure.other("Could not prepare the sign-in (error \(errno)).")
        }
        servePasswordOnce(password, pipePath: pipePath)

        var authentication = [
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no"
        ]
        #if DEBUG
        // Test aid (DEBUG builds only): sign in with a throwaway key, so the
        // connection sharing and the terminal window can be exercised
        // against a test server that cannot check passwords.
        if let identity = ProcessInfo.processInfo.environment["FLEETHUB_SSH_TEST_IDENTITY"] {
            authentication = ["-i", identity, "-o", "IdentitiesOnly=yes",
                              "-o", "PreferredAuthentications=publickey"]
        }
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = commonOptions + authentication + [
            "-M", "-N",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            target.host
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment[Self.askPassPipeVariable] = pipePath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let errorText = LockedText()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorText.append(String(decoding: data, as: UTF8.self)) }
        }

        defer {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            Self.releasePipe(pipePath)
        }

        do {
            try process.run()
        } catch {
            throw SSHFailure.other("Could not start ssh: \(error.localizedDescription)")
        }
        lock.withLock { master = process }
        Self.startWatchdog(for: process)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            if !process.isRunning {
                throw SSHFailure.classify(errorText.value)
            }
            if await isMasterUp() { return }
        }
        process.terminate()
        throw SSHFailure.timedOut
    }

    /// Ends the signed-in connection if FleetHub goes away without closing
    /// it (a crash or a force quit). A child process outlives its parent, so
    /// a small shell loop watches both: it stops the connection once
    /// FleetHub's process is gone, and stops itself once the connection is.
    private static func startWatchdog(for master: Process) {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null && kill -0 \"$2\" 2>/dev/null; do sleep 2; done; kill \"$2\" 2>/dev/null",
            "fleethub-ssh-watchdog",
            String(ProcessInfo.processInfo.processIdentifier),
            String(master.processIdentifier)
        ]
        watchdog.standardInput = FileHandle.nullDevice
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()
    }

    /// Asks the master connection whether it is up.
    private func isMasterUp() async -> Bool {
        await withCheckedContinuation { continuation in
            let check = Process()
            check.executableURL = URL(fileURLWithPath: Self.sshPath)
            check.arguments = ["-F", "/dev/null", "-S", controlPath, "-O", "check", target.host]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            check.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do { try check.run() } catch { continuation.resume(returning: false) }
        }
    }

    /// The command for the terminal window: a second ssh that rides the
    /// connection already signed in.
    var terminalCommand: (executable: String, arguments: [String]) {
        (Self.sshPath, ["-F", "/dev/null", "-S", controlPath, "-o", "ControlMaster=no",
                        "-p", String(target.port), "-l", target.username, target.host])
    }

    /// Ends the connection and removes every temporary file. Safe to call twice.
    func close() {
        let process: Process? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            let current = master
            master = nil
            return current
        }
        guard let process else {
            try? FileManager.default.removeItem(at: workDirectory)
            return
        }
        let exit = Process()
        exit.executableURL = URL(fileURLWithPath: Self.sshPath)
        exit.arguments = ["-F", "/dev/null", "-S", controlPath, "-O", "exit", target.host]
        exit.standardOutput = FileHandle.nullDevice
        exit.standardError = FileHandle.nullDevice
        try? exit.run()
        exit.waitUntilExit()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - Password hand-over

    /// Writes the password to the named pipe for the first reader, then
    /// removes the pipe. Runs on its own thread because opening a pipe for
    /// writing waits for a reader.
    private func servePasswordOnce(_ password: String, pipePath: String) {
        let bytes = Array((password + "\n").utf8)
        Thread.detachNewThread {
            let descriptor = open(pipePath, O_WRONLY)
            guard descriptor >= 0 else { return }
            // A reader that goes away must not kill the app with SIGPIPE.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            _ = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
            Darwin.close(descriptor)
            unlink(pipePath)
        }
    }

    /// Unblocks the writer thread if ssh never asked for the password, and
    /// removes the pipe.
    private static func releasePipe(_ pipePath: String) {
        let descriptor = open(pipePath, O_RDONLY | O_NONBLOCK)
        if descriptor >= 0 {
            var scratch = [UInt8](repeating: 0, count: 512)
            // Give the writer a moment to finish, then discard what it wrote.
            usleep(50_000)
            _ = read(descriptor, &scratch, scratch.count)
            Darwin.close(descriptor)
        }
        unlink(pipePath)
    }

    // MARK: - Ask-pass helper (runs in a separate FleetHub process)

    /// If this process was started by ssh to supply the password, do that
    /// and return an exit code. Returns nil for a normal app launch.
    ///
    /// ssh also uses the helper for questions such as "continue connecting?".
    /// Only a password prompt is answered; anything else is refused, so the
    /// helper can never approve a host key on the operator's behalf.
    static func runAskPassIfRequested() -> Int32? {
        guard let pipePath = ProcessInfo.processInfo.environment[askPassPipeVariable], !pipePath.isEmpty else {
            return nil
        }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        guard prompt.contains("password") else { return 1 }

        let descriptor = open(pipePath, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return 1 }
        defer { Darwin.close(descriptor) }

        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorSet, 1, 250)
            if ready > 0 {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    collected.append(contentsOf: buffer[0..<count])
                    if collected.last == UInt8(ascii: "\n") { break }
                } else if count == 0, !collected.isEmpty {
                    break
                }
            }
        }
        guard !collected.isEmpty else { return 1 }
        FileHandle.standardOutput.write(Data(collected))
        return 0
    }
}

/// Lets exactly one caller win; used to resume a continuation once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ more: String) { lock.withLock { text += more } }
    var value: String { lock.withLock { text } }
}
