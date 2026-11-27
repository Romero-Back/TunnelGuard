import Darwin
import Foundation

struct DesktopSession: Decodable, Equatable, Sendable {
    let pid: Int
    let appPid: Int32
    let verifiedIPv4: String?
}

struct DesktopSnapshot: Sendable {
    let pid: Int?
    let session: DesktopSession?
    let exitStatus: Int?
}

enum DesktopGateState: Sendable {
    case off, invalid, installed
}

struct DesktopRuntime: Sendable {
    private let ordinaryBundle = "/Applications/Claude.app"
    private let gateDirectory = "/private/var/db/tunnelguard-desktop"
    private let label = "app.tunnelguard.native"
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TunnelGuard", isDirectory: true)

    private var resources: URL { Bundle.main.resourceURL! }
    private var launcher: [String] {
        let binary = resources.appendingPathComponent("NativeLauncher/tunnelguard-native").path
        if FileManager.default.isExecutableFile(atPath: binary) { return [binary] }
        return ["/usr/bin/python3", "-B", resources.appendingPathComponent("Scripts/tunnelguard-native.py").path]
    }
    private var sessionFile: URL { support.appendingPathComponent("native-session.json") }
    private var jobFile: URL { support.appendingPathComponent("native-job.plist") }
    private var domain: String { "gui/\(getuid())" }
    var filterConfigured: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/app.tunnelguard.native-filter.plist")
    }

    var desktopGateState: DesktopGateState {
        var directory = stat()
        if lstat(gateDirectory, &directory) != 0 {
            return errno == ENOENT ? .off : .invalid
        }

        let target = gateDirectory + "/Claude.app"
        var bundle = stat()
        var helper = stat()
        var rule = stat()
        guard directory.st_uid == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_mode & 0o022 == 0,
              lstat(target, &bundle) == 0, bundle.st_uid == 0,
              bundle.st_mode & S_IFMT == S_IFDIR, bundle.st_mode & 0o027 == 0,
              lstat(gateDirectory + "/launch", &helper) == 0, helper.st_uid == 0,
              helper.st_mode & S_IFMT == S_IFREG, helper.st_mode & 0o022 == 0,
              lstat("/private/etc/sudoers.d/tunnelguard-desktop", &rule) == 0, rule.st_uid == 0,
              rule.st_mode & S_IFMT == S_IFREG, rule.st_mode & 0o022 == 0 else {
            return .invalid
        }
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ordinaryBundle),
           destination != target { return .invalid }
        let executable = ordinaryBundle + "/Contents/MacOS/Claude"
        return access(executable, X_OK) == -1 && errno == EACCES ? .installed : .invalid
    }

    func configureDesktopGate(_ enabled: Bool) throws {
        let scripts = resources.appendingPathComponent("Scripts")
        let script = try String(contentsOf: scripts.appendingPathComponent("install-desktop-gate.sh"), encoding: .utf8)
        if enabled && !FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("tunnelguard-desktop-gate").path) {
            throw DesktopError.missingResources
        }
        try authorize(
            script, [enabled ? "enable" : "disable", NSUserName(), resources.path],
            prompt: enabled ? "TunnelGuard ограничит прямой запуск установленной копии Claude Desktop." :
                "TunnelGuard восстановит обычный запуск Claude Desktop."
        )
    }

    func snapshot() throws -> DesktopSnapshot {
        let jobs = try command("/bin/launchctl", ["list"], capture: true)
        let job = jobs.split(separator: "\n").lazy.compactMap { line -> (pid: Int?, status: Int?)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[2] == label else { return nil }
            return (Int(fields[0]), Int(fields[1]))
        }.first
        let pid = job?.pid
        let record = try? JSONDecoder().decode(DesktopSession.self, from: Data(contentsOf: sessionFile))
        if let record, record.pid == pid, record.appPid > 1 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let count = proc_pidpath(record.appPid, &path, UInt32(path.count))
            let expected = desktopGateState != .off ? "/private/var/db/tunnelguard-desktop/Claude.app/Contents/MacOS/Claude" :
                "/Applications/Claude.app/Contents/MacOS/Claude"
            if count > 0, String(cString: path) == expected {
                return DesktopSnapshot(pid: pid, session: record, exitStatus: job?.status)
            }
        }
        return DesktopSnapshot(pid: pid, session: nil, exitStatus: job?.status)
    }

    func start(expectedIPv4: [String]) throws -> (session: DesktopSession, address: String) {
        guard desktopGateState == .installed else { throw DesktopError.gateUnverified }
        guard try snapshot().pid == nil else { throw DesktopError.alreadyRunning }
        let program = launcher
        guard let executable = program.first, FileManager.default.fileExists(atPath: executable) else {
            throw DesktopError.missingResources
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let job: [String: Any] = [
            "Label": label, "RunAtLoad": true,
            "ProgramArguments": program + expectedIPv4.flatMap { ["--expected-egress", $0] }
                + ["--require-gate", "--ready-file", sessionFile.path],
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try plist.write(to: jobFile, options: .atomic)
        _ = try? command("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        _ = try command("/bin/launchctl", ["bootstrap", domain, jobFile.path])
        var ready = false
        defer {
            if !ready { _ = try? command("/bin/launchctl", ["bootout", "\(domain)/\(label)"]) }
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 35 {
            let snapshot = try snapshot()
            if let session = snapshot.session,
               let address = session.verifiedIPv4, expectedIPv4.contains(address) {
                ready = true
                return (session, address)
            }
            // The native launcher uses EX_TEMPFAIL when preflight refuses network access.
            if snapshot.pid == nil && snapshot.exitStatus == Int(EX_TEMPFAIL) { throw DesktopError.networkBlocked }
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

    func check(expectedIPv4: [String], requireGate: Bool = false) throws -> String {
        if requireGate && desktopGateState != .installed { throw DesktopError.gateUnverified }
        let program = launcher + ["--probe"] + (requireGate ? ["--require-gate"] : [])
            + expectedIPv4.flatMap { ["--expected-egress", $0] }
        guard let executable = program.first,
              let output = try? command(executable, Array(program.dropFirst()), capture: true),
              let address = output.split(whereSeparator: \.isNewline).last.map(String.init),
              expectedIPv4.contains(address) else { throw DesktopError.networkBlocked }
        return address
    }

    func observe() -> NetworkObservation {
        (try? JSONDecoder().decode(NetworkObservation.self, from: Data(control(["status"]).utf8))) ?? .unavailable
    }

    func diagnose(_ diagnostic: Diagnostic, addresses: [String]) throws -> String {
        let output = try control([diagnostic.rawValue] + addresses.flatMap { ["--expected-egress", $0] })
        if diagnostic == .fingerprint {
            let data = try JSONDecoder().decode(VPNFingerprint.self, from: Data(output.utf8))
            guard addresses.contains(data.egress) else { throw DesktopError.networkBlocked }
            return "\(data.vpnName) · \(data.interface) · IPv4 \(data.egress)"
        }
        guard let address = output.split(whereSeparator: \.isNewline).last.map(String.init),
              addresses.contains(address) else { throw DesktopError.networkBlocked }
        return "Прямой TCP по IPv4 и IPv6 к контрольным локальным портам заблокирован. TCP через выбранный VPN прошёл."
    }

    func setPaused(_ paused: Bool) throws {
        _ = try control([paused ? "panic" : "resume"])
    }

    func terminalCommand() throws -> URL {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = support.appendingPathComponent("Claude Code Secure Launch.command")
        let arguments = (launcher + ["cli", "launch-code"]).map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        try Data("#!/bin/sh\nexec \(arguments)\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func control(_ arguments: [String]) throws -> String {
        let program = launcher
        return try command(program[0], Array(program.dropFirst()) + ["cli"] + arguments, capture: true)
    }

    func installFilter(vpnName: String?) throws {
        guard let vpnName = vpnName ?? observe().vpnName else { throw DesktopError.networkBlocked }
        let scripts = resources.appendingPathComponent("Scripts")
        let installer = try String(contentsOf: scripts.appendingPathComponent("install-native-filter.sh"), encoding: .utf8)
        let refresh = try String(contentsOf: scripts.appendingPathComponent("refresh-native-pf.sh"), encoding: .utf8)
        let job: [String: Any] = ["Label": "app.tunnelguard.native-filter", "RunAtLoad": true, "StartInterval": 10,
                                  "ProgramArguments": ["/bin/sh", "-c", refresh, "sh", vpnName]]
        let definition = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try authorize(installer, [NSUserName(), definition.base64EncodedString(), resources.path],
                      prompt: "TunnelGuard настроит системный фильтр только для Claude.")
    }

    private func authorize(_ script: String, _ arguments: [String], prompt: String) throws {
        let authorization = """
            on run argv
                set commandText to "/usr/bin/lockf -k -t 0 /private/var/db/tunnelguard-install.lock /bin/sh -c " & quoted form of item 1 of argv & " sh"
                repeat with i from 3 to count of argv
                    set commandText to commandText & " " & quoted form of (item i of argv)
                end repeat
                do shell script commandText with administrator privileges with prompt (item 2 of argv)
            end run
            """
        _ = try command("/usr/bin/osascript", ["-e", authorization, script, prompt] + arguments)
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
    case alreadyRunning, missingResources, networkBlocked, gateUnverified, startFailed, openFailed, stopFailed, commandFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Защищённый сеанс Claude уже запущен."
        case .missingResources: "В сборке отсутствует запускатор Claude."
        case .networkBlocked: "Проверь подключение выбранного VPN и разрешённые IPv4, затем попробуй снова."
        case .gateUnverified: "Ограничение прямого запуска не подтверждено. Проверь настройки Claude Desktop."
        case .startFailed: "Claude не открылся. Проверь, закрыт ли обычный Claude и активен ли сетевой фильтр."
        case .openFailed: "Не удалось открыть окно Claude. Проверь состояние сеанса и попробуй снова."
        case .stopFailed: "Не удалось подтвердить остановку сеанса."
        case .commandFailed: "Команда завершилась с ошибкой."
        }
    }
}
