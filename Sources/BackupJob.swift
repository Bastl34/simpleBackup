import Foundation

/// A running 7zz process. Writes to "<target>.part" first and renames it at the end, so an aborted
/// backup never looks like a finished one (and "Overwrite" only replaces the old archive at the very end).
@MainActor
final class BackupJob {
    enum Outcome { case success, warnings(String), failed(String), stopped }

    let entry: BackupEntry
    let target: URL
    private(set) var progress = 0.0
    var onProgress: (() -> Void)?
    var onFinish: ((BackupJob, Outcome) -> Void)?

    private let process = Process()
    private let temp: URL
    private var errors = ""
    private var stopped = false

    init(entry: BackupEntry, target: URL, sevenZip: String) {
        self.entry = entry
        self.target = target
        temp = target.appendingPathExtension("part")
        // like `7zz a -p -mhe=on <target> <folder>`; the password goes through stdin instead of an argument (would be visible in `ps`)
        process.executableURL = URL(fileURLWithPath: sevenZip)
        process.arguments = ["a", "-t7z", "-p", "-mhe=on", "-bso0", "-bsp1", temp.path, entry.source]
        // force UTF-8 so non-ASCII passwords are encrypted exactly like in the terminal
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { $1 }
    }

    func start(password: String) throws {
        try? FileManager.default.removeItem(at: temp) // leftover from an aborted run – 7zz would add to it otherwise
        let input = Pipe(), output = Pipe(), errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(output: String(decoding: data, as: UTF8.self)) }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(error: String(decoding: data, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { self?.finish(status: status) }
        }
        try process.run()
        try? input.fileHandleForWriting.write(contentsOf: Data("\(password)\n\(password)\n".utf8))
        try? input.fileHandleForWriting.close()
    }

    func stop() {
        stopped = true
        if process.isRunning { process.interrupt() } // like Ctrl+C in the terminal
    }

    private func received(output text: String) {
        // 7zz prints progress as "  42% 12 + folder/file", separated by backspaces
        guard let match = text.matches(of: #/(\d+)%/#).last, let percent = Double(match.1) else { return }
        let value = min(percent / 100, 1)
        guard value > progress else { return } // max(), in case a number gets split across two reads
        progress = value
        onProgress?()
    }

    private func received(error text: String) {
        errors = String((errors + text).suffix(4000))
    }

    private func finish(status: Int32) {
        let fm = FileManager.default
        // 0 = ok, 1 = warnings (e.g. locked files), anything else = error
        guard !stopped, status == 0 || status == 1 else {
            try? fm.removeItem(at: temp)
            return done(stopped ? .stopped : .failed(errors.isEmpty ? String(localized: "7zz exited with code \(Int(status)).") : errors))
        }
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temp, to: target)
            done(status == 0 ? .success : .warnings(errors))
        } catch {
            done(.failed(String(localized: "The archive is at \(temp.path) but could not be renamed:\n\(error.localizedDescription)")))
        }
    }

    private func done(_ outcome: Outcome) {
        onFinish?(self, outcome)
        onFinish = nil
        onProgress = nil
    }
}
