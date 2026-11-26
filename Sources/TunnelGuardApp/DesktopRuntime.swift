import Darwin
import Foundation

struct DesktopSession: Decodable, Equatable, Sendable {
    let pid: Int
    let appPid: Int32
}

struct DesktopSnapshot: Sendable {
    let pid: Int?
    let session: DesktopSession?
}

struct DesktopRuntime: Sendable {
    private let label = "app.tunnelguard.native"
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TunnelGuard", isDirectory: true)

    private var driver: URL { Bundle.main.resourceURL!.appendingPathComponent("Scripts/tunnelguard-native.py") }
    private var sessionFile: URL { support.appendingPathComponent("native-session.json") }
    private var jobFile: URL { support.appendingPathComponent("native-job.plist") }
    private var domain: String { "gui/\(getuid())" }
    var logFile: URL { support.appendingPathComponent("native-session.log") }

    func snapshot() throws -> DesktopSnapshot {
        let jobs = try command("/bin/launchctl", ["list"], capture: true)
        let pid = jobs.split(separator: "\n").compactMap { line -> Int? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[2] == label, let pid = Int(fields[0]), pid > 1 else { return nil }
            return pid
        }.first
        let record = try? JSONDecoder().decode(DesktopSession.self, from: Data(contentsOf: sessionFile))
        if let record, record.pid == pid, record.appPid > 1 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let count = proc_pidpath(record.appPid, &path, UInt32(path.count))
            if count > 0, String(cString: path) == "/Applications/Claude.app/Contents/MacOS/Claude" {
                return DesktopSnapshot(pid: pid, session: record)
            }
        }
        return DesktopSnapshot(pid: pid, session: nil)
    }

    func start(expectedIPv4: String) throws -> DesktopSession {
        guard try snapshot().pid == nil else { throw DesktopError.alreadyRunning }
        guard FileManager.default.fileExists(atPath: driver.path) else { throw DesktopError.missingResources }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(logFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DesktopError.startFailed }
        Darwin.close(descriptor)
        let job: [String: Any] = [
            "Label": label, "RunAtLoad": true,
            "ProgramArguments": ["/usr/bin/python3", "-B", driver.path, "--expected-egress", expectedIPv4,
                                 "--ready-file", sessionFile.path],
            "StandardOutPath": logFile.path, "StandardErrorPath": logFile.path,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try plist.write(to: jobFile, options: .atomic)
        _ = try? command("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        _ = try command("/bin/launchctl", ["bootstrap", domain, jobFile.path])
        let start = Date()
        while Date().timeIntervalSince(start) < 35 {
            let snapshot = try snapshot()
            if let session = snapshot.session { return session }
            if snapshot.pid == nil && Date().timeIntervalSince(start) > 2 { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw DesktopError.startFailed
    }

    func stop() throws {
        guard let pid = try snapshot().pid else { return }
        _ = try command("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if Darwin.kill(Int32(pid), 0) == -1 && errno == ESRCH { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw DesktopError.stopFailed
    }

    func check(expectedIPv4: String) -> Bool {
        let arguments = ["-B", driver.path, "--probe", "--expected-egress", expectedIPv4]
        return (try? command("/usr/bin/python3", arguments)) != nil
    }

    private func command(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = capture ? Pipe() : nil
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DesktopError.commandFailed }
        return String(decoding: data, as: UTF8.self)
    }
}

enum DesktopError: LocalizedError {
    case alreadyRunning, missingResources, startFailed, stopFailed, commandFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Защищённый сеанс Claude уже запущен."
        case .missingResources: "В сборке отсутствует запускатор Claude."
        case .startFailed: "Claude не открылся. Проверь, закрыт ли обычный Claude и активен ли сетевой фильтр."
        case .stopFailed: "Не удалось подтвердить остановку сеанса."
        case .commandFailed: "Команда завершилась с ошибкой."
        }
    }
}
