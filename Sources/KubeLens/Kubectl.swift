import Foundation

/// Переменные из логин-шелла пользователя. GUI-приложение стартует с системным окружением,
/// где нет ни `KUBECONFIG`, ни homebrew в `PATH`, поэтому спрашиваем шелл один раз.
struct ShellEnv: Sendable {
    var kubeconfig = ""
    var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    static func load() async -> ShellEnv {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "printf '__KL_KC=%s\\n__KL_PATH=%s\\n' \"$KUBECONFIG\" \"$PATH\""
        var env = ShellEnv()
        guard let r = try? await Subprocess.run(shell, ["-ilc", script], timeout: 6) else { return env }
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix("__KL_KC=") { env.kubeconfig = String(line.dropFirst(8)) }
            if line.hasPrefix("__KL_PATH=") { env.path = String(line.dropFirst(10)) }
        }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !env.path.split(separator: ":").map(String.init).contains(extra) {
            env.path += ":" + extra
        }
        return env
    }
}

struct SubprocessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum SubprocessError: LocalizedError {
    case timeout(String)
    case failed(String, Int32, String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let cmd): return "\(cmd): превышено время ожидания"
        case .failed(let cmd, let code, let err):
            let tail = err.split(separator: "\n").last.map(String.init) ?? ""
            return "\(cmd) завершился с кодом \(code)\(tail.isEmpty ? "" : ": \(tail)")"
        case .notFound(let cmd): return "\(cmd) не найден. Укажите путь в настройках."
        }
    }
}

enum Subprocess {
    /// Запуск с таймаутом; stdout/stderr читаются целиком в фоне, чтобы процесс не завис на полном pipe.
    static func run(_ executable: String, _ args: [String], env: [String: String] = [:], input: Data? = nil, timeout: TimeInterval) async throws -> SubprocessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        proc.environment = e
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        if let input {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
        } else {
            proc.standardInput = FileHandle.nullDevice
        }

        let state = RunState()
        return try await withCheckedThrowingContinuation { cont in
            let group = DispatchGroup()
            group.enter(); group.enter()
            DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); state.lock.withLock { state.out = d }; group.leave() }
            DispatchQueue.global().async { let d = err.fileHandleForReading.readDataToEndOfFile(); state.lock.withLock { state.err = d }; group.leave() }
            proc.terminationHandler = { p in
                group.wait()
                guard state.finish() else { return }
                cont.resume(returning: SubprocessResult(status: p.terminationStatus,
                                                        stdout: String(decoding: state.out, as: UTF8.self),
                                                        stderr: String(decoding: state.err, as: UTF8.self)))
            }
            do { try proc.run() } catch {
                _ = state.finish()
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.finish() else { return }
                proc.terminate()
                cont.resume(throwing: SubprocessError.timeout(URL(fileURLWithPath: executable).lastPathComponent))
            }
        }
    }

    /// Общее состояние обработчиков завершения и таймаута: continuation можно резюмировать один раз.
    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var out = Data()
        var err = Data()
        func finish() -> Bool { lock.withLock { if finished { return false }; finished = true; return true } }
    }
}

/// kubectl нужен только для того, чего нет в файле: список namespaces и проверка связи.
/// Всё остальное приложение делает само, поэтому без kubectl оно тоже работает.
final class Kubectl: @unchecked Sendable {
    static let shared = Kubectl()
    var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""

    var overridePath: String? {
        let p = UserDefaults.standard.string(forKey: "kubectlPath") ?? ""
        return p.isEmpty ? nil : p
    }

    var executable: String? {
        if let o = overridePath { return FileManager.default.isExecutableFile(atPath: o) ? o : nil }
        for dir in searchPath.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = dir + "/kubectl"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func run(_ args: [String], kubeconfig: String, input: Data? = nil, timeout: TimeInterval = 20) async throws -> String {
        guard let exe = executable else { throw SubprocessError.notFound("kubectl") }
        let r = try await Subprocess.run(exe, args, env: ["KUBECONFIG": kubeconfig, "PATH": searchPath], input: input, timeout: timeout)
        guard r.status == 0 else { throw SubprocessError.failed("kubectl", r.status, r.stderr) }
        return r.stdout
    }

    func namespaces(context: String, kubeconfig: String) async throws -> [String] {
        let out = try await run(["--context", context, "get", "namespaces", "-o", "name", "--request-timeout=10s"], kubeconfig: kubeconfig)
        return out.split(separator: "\n").map { String($0).replacingOccurrences(of: "namespace/", with: "") }.sorted()
    }

    struct Probe {
        var serverVersion: String
        var elapsed: TimeInterval
    }

    /// `kubectl version` — самый дешёвый запрос, который проверяет адрес, TLS и аутентификацию.
    func probe(context: String, kubeconfig: String) async throws -> Probe {
        let start = Date()
        let out = try await run(["--context", context, "version", "-o", "json", "--request-timeout=10s"], kubeconfig: kubeconfig)
        let elapsed = Date().timeIntervalSince(start)
        let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let ver = (json?["serverVersion"] as? [String: Any])?["gitVersion"] as? String ?? "?"
        return Probe(serverVersion: ver, elapsed: elapsed)
    }
}
