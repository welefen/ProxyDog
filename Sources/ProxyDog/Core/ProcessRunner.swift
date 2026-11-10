import Foundation

/// Result of running an external command-line tool.
struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }

    var combinedOutput: String {
        (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Small wrapper around `Process` used by the proxy core.
///
/// All callers that sit on a NIO event loop must dispatch here from their own serial
/// queue (see `CertificateAuthority`), because `Process.waitUntilExit()` blocks.
enum ProcessRunner {
    /// Runs an executable and captures stdout/stderr.
    ///
    /// Both pipes are drained concurrently with the process lifetime so a chatty tool
    /// cannot dead-lock on a full pipe buffer.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let drainQueue = DispatchQueue(label: "com.proxydog.process.drain", attributes: .concurrent)
        let group = DispatchGroup()
        let captured = OutputCapture()

        group.enter()
        drainQueue.async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            captured.stdoutData = data
            group.leave()
        }
        group.enter()
        drainQueue.async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            captured.stderrData = data
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: captured.stdoutData, as: UTF8.self),
            stderr: String(decoding: captured.stderrData, as: UTF8.self)
        )
    }

    /// Runs a shell command with administrator privileges. macOS shows the standard
    /// authorization dialog because of `with administrator privileges`.
    @discardableResult
    static func runAdminShell(_ command: String) throws -> ProcessResult {
        let escaped = appleScriptStringLiteral(command)
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = try run("/usr/bin/osascript", ["-e", script])
        guard result.succeeded else {
            throw ProxyError.authorizationFailed(readableFailure(result))
        }
        return result
    }

    /// Single-quotes a string for `/bin/sh`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Turns a failed command into a short human readable message.
    static func readableFailure(_ result: ProcessResult) -> String {
        let output = result.combinedOutput
        let lowered = output.lowercased()
        if lowered.contains("user canceled")
            || lowered.contains("user cancelled")
            || output.contains("(-128)") {
            return "Authorization was cancelled."
        }
        if output.isEmpty {
            return "Command failed with exit code \(result.status)."
        }
        // osascript prefixes errors with "execution error: ". Keep the useful part.
        var message = output
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Locking box because the two pipe drains run on different threads.
private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdoutData = Data()
    private var _stderrData = Data()

    var stdoutData: Data {
        get { lock.lock(); defer { lock.unlock() }; return _stdoutData }
        set { lock.lock(); _stdoutData = newValue; lock.unlock() }
    }

    var stderrData: Data {
        get { lock.lock(); defer { lock.unlock() }; return _stderrData }
        set { lock.lock(); _stderrData = newValue; lock.unlock() }
    }
}
