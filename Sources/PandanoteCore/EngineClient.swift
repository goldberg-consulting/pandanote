import Foundation
import Darwin

public enum EngineFailure: LocalizedError {
    case unavailable, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The Inkwell engine or Node runtime is missing. Rebuild Pandanote or set the Node path in Settings."
        case .failed(let reason): return reason
        }
    }
}

public final class EngineClient: @unchecked Sendable {
    public let script: URL
    private let previewLimits: PreviewLimits
    struct PreviewLimits: Sendable {
        var timeout: TimeInterval = 20
        var maximumOutputBytes = 64 * 1024 * 1024
    }
    public init(script: URL) { self.script = script; self.previewLimits = PreviewLimits() }
    init(script: URL, previewLimits: PreviewLimits) { self.script = script; self.previewLimits = previewLimits }
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/Library/TinyTeX/bin/universal-darwin", "/Library/TeX/texbin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = directories.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        return env
    }
    public func call(action: String, root: URL, file: URL?, text: String, trusted: Bool = false, nodePath: String = "", parameters: [String: Any] = [:]) async throws -> Data {
        var request = parameters
        request.merge(["action": action, "root": root.path, "file": file?.path ?? root.appendingPathComponent("Untitled.md").path, "text": text, "trusted": trusted]) { _, new in new }
        let payload = request
        let script = self.script
        // Preview requests are replaced on every edit. They own no user work and
        // must stop when their task is cancelled. Explicit publishing jobs retain
        // their existing lifetime, including long-running Python and TeX work.
        let preview = action == "preview" ? PreviewProcess(limits: previewLimits) : nil
        return try await withTaskCancellationHandler {
          try await BackgroundWork.run {
            let input = try JSONSerialization.data(withJSONObject: payload)
            let fm = FileManager.default
            let node = ([nodePath] + ["/opt/homebrew/bin/node", "/usr/local/bin/node"]).first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
            guard let node, fm.fileExists(atPath: script.path) else { throw EngineFailure.unavailable }
            let process = Process()
            process.qualityOfService = .utility
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [script.path]
            process.currentDirectoryURL = root
            process.environment = Self.environment
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout
            if let preview {
                return try preview.run(process, input: input, stdin: stdin, stdout: stdout)
            }
            // A file prevents a full stderr pipe from deadlocking long TeX builds.
            let log = fm.temporaryDirectory.appendingPathComponent("pandanote-\(UUID().uuidString).log")
            fm.createFile(atPath: log.path, contents: nil)
            let errorHandle = try FileHandle(forWritingTo: log)
            defer { try? errorHandle.close(); try? fm.removeItem(at: log) }
            process.standardError = errorHandle
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !data.isEmpty else { throw EngineFailure.failed((try? String(contentsOf: log, encoding: .utf8)) ?? "Publishing engine exited unexpectedly.") }
            return data
          }
        } onCancel: {
            preview?.stop(.cancelled)
        }
    }
}

/// Owns exactly one read-only engine process. All stop paths share the same
/// lock, including cancellation that arrives before Process.run completes.
private final class PreviewProcess: @unchecked Sendable {
    enum StopReason { case cancelled, timedOut, outputLimit }
    private let lock = NSLock()
    private let limits: EngineClient.PreviewLimits
    private var process: Process?
    private var reason: StopReason?
    private var outputBytes = 0
    init(limits: EngineClient.PreviewLimits) { self.limits = limits }

    func stop(_ reason: StopReason) {
        lock.lock()
        if self.reason == nil { self.reason = reason }
        let target = process
        if let target, target.isRunning { target.terminate() }
        lock.unlock()
        guard let target else { return }
        // A stuck engine may not service SIGTERM. The identity check prevents a
        // delayed escalation from affecting a later request or completed process.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self, weak target] in
            guard let self, let target else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.process === target, target.isRunning { Darwin.kill(target.processIdentifier, SIGKILL) }
        }
    }

    private func failure() -> Error? {
        lock.lock(); defer { lock.unlock() }
        switch reason {
        case .cancelled: return CancellationError()
        case .timedOut: return EngineFailure.failed("Preview took too long. Reduce the document size or retry the preview.")
        case .outputLimit: return EngineFailure.failed("Preview output is too large. Reduce large embedded images or code output.")
        case nil: return nil
        }
    }

    private func accept(_ count: Int) -> Bool {
        lock.lock()
        let allowed = reason == nil && count <= limits.maximumOutputBytes - outputBytes
        if allowed { outputBytes += count }
        lock.unlock()
        if !allowed { stop(.outputLimit) }
        return allowed
    }

    func run(_ process: Process, input: Data, stdin: Pipe, stdout: Pipe) throws -> Data {
        let stderr = Pipe()
        process.standardError = stderr
        defer {
            for handle in [stdin.fileHandleForWriting, stdin.fileHandleForReading,
                           stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting] { try? handle.close() }
        }
        lock.lock()
        if reason != nil { lock.unlock(); throw failure()! }
        self.process = process
        do { try process.run(); lock.unlock() }
        catch { self.process = nil; lock.unlock(); throw error }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.01, limits.timeout))
        timer.setEventHandler { [weak self] in self?.stop(.timedOut) }
        timer.resume()
        defer {
            timer.cancel()
            lock.lock(); self.process = nil; lock.unlock()
        }

        // Feed input while draining both output streams. A child that writes a
        // diagnostic before reading stdin cannot fill a pipe and deadlock us.
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? stdin.fileHandleForWriting.close(); workers.leave() }
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
        let diagnostics = PreviewDiagnostics()
        workers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { workers.leave() }
            while let chunk = try? stderr.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if self.accept(chunk.count) { diagnostics.append(chunk) }
            }
        }
        var data = Data()
        var readError: Error?
        do {
            while let chunk = try stdout.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if accept(chunk.count) { data.append(chunk) }
            }
        } catch { readError = error; stop(.cancelled) }
        process.waitUntilExit()
        workers.wait()
        if let failure = failure() { throw failure }
        if let readError { throw readError }
        guard !data.isEmpty else {
            let message = String(decoding: diagnostics.data, as: UTF8.self)
            throw EngineFailure.failed(message.isEmpty ? "Preview engine exited unexpectedly." : message)
        }
        return data
    }
}

/// Only its worker writes; the owning thread reads after DispatchGroup.wait.
private final class PreviewDiagnostics: @unchecked Sendable {
    private(set) var data = Data()
    func append(_ chunk: Data) { data.append(chunk.prefix(max(0, 8_192 - data.count))) }
}
