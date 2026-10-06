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
            let line = Self.summary(err)
            return "\(cmd) завершился с кодом \(code)\(line.isEmpty ? "" : ": \(line)")"
        case .notFound(let cmd): return "\(cmd) не найден. Укажите путь в настройках."
        }
    }

    /// Первая содержательная строка stderr. kubectl перед ошибкой пишет строки журнала
    /// (`E1006 12:00:00.000000 …`) и предупреждения, а после неё — справку со ссылкой.
    static func summary(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let noise: (String) -> Bool = { l in
            l.isEmpty || l.hasPrefix("Warning:") || l.range(of: #"^[IWEF]\d{4} \d"#, options: .regularExpression) != nil
        }
        return lines.first { !noise($0) } ?? lines.last { !$0.isEmpty } ?? ""
    }
}

enum Subprocess {
    /// Запуск с таймаутом; stdout/stderr читаются целиком в фоне, чтобы процесс не завис на полном pipe.
    /// Отмена задачи завершает процесс. `onStderr` получает stderr построчно, пока процесс работает.
    static func run(_ executable: String, _ args: [String], env: [String: String] = [:], input: Data? = nil, timeout: TimeInterval,
                    onStderr: (@Sendable (String) -> Void)? = nil) async throws -> SubprocessResult {
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                state.lock.withLock { state.cont = cont }
                if Task.isCancelled { state.take()?.resume(throwing: CancellationError()); return }
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); state.lock.withLock { state.out = d }; group.leave() }
                DispatchQueue.global().async {
                    let d = readLines(err.fileHandleForReading, onStderr)
                    state.lock.withLock { state.err = d }
                    group.leave()
                }
                proc.terminationHandler = { p in
                    group.wait()
                    state.take()?.resume(returning: SubprocessResult(status: p.terminationStatus,
                                                                     stdout: String(decoding: state.out, as: UTF8.self),
                                                                     stderr: String(decoding: state.err, as: UTF8.self)))
                }
                do { try proc.run() } catch {
                    state.take()?.resume(throwing: error)
                    return
                }
                // Отмена могла прийти между сохранением continuation и запуском.
                if state.lock.withLock({ state.abandoned }) { proc.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    state.abandon(proc, SubprocessError.timeout(URL(fileURLWithPath: executable).lastPathComponent))
                }
            }
        } onCancel: {
            state.abandon(proc, CancellationError())
        }
    }

    /// Читает до конца, по пути отдавая готовые строки в `onLine`.
    private static func readLines(_ h: FileHandle, _ onLine: (@Sendable (String) -> Void)?) -> Data {
        guard let onLine else { return h.readDataToEndOfFile() }
        var all = Data(), pending = Data()
        while case let chunk = h.availableData, !chunk.isEmpty {
            all.append(chunk)
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending[..<nl], as: UTF8.self))
                pending.removeSubrange(...nl)
            }
        }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        return all
    }

    /// Общее состояние обработчиков завершения, таймаута и отмены: continuation резюмируется один раз.
    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var cont: CheckedContinuation<SubprocessResult, Error>?
        var abandoned = false
        var out = Data()
        var err = Data()

        func take() -> CheckedContinuation<SubprocessResult, Error>? {
            lock.withLock { defer { cont = nil }; return cont }
        }

        /// Таймаут или отмена: процесс завершаем, ждущему отдаём ошибку.
        func abandon(_ proc: Process, _ error: Error) {
            guard let c = take() else { return }
            lock.withLock { abandoned = true }
            if proc.isRunning { proc.terminate() }
            c.resume(throwing: error)
        }
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

    /// Перед вызовом — вход через exec-плагин контекста, если он нужен (см. `ClusterAuth`).
    func run(context: String, _ args: [String], kubeconfig: String, input: Data? = nil, timeout: TimeInterval = 20) async throws -> String {
        guard let exe = executable else { throw SubprocessError.notFound("kubectl") }
        try await ClusterAuth.shared.ensure(AuthKey(context: context, kubeconfig: kubeconfig))
        let r = try await Subprocess.run(exe, ["--context", context] + args, env: ["KUBECONFIG": kubeconfig, "PATH": searchPath], input: input, timeout: timeout)
        guard r.status == 0 else { throw SubprocessError.failed("kubectl", r.status, r.stderr) }
        return r.stdout
    }

    func namespaces(context: String, kubeconfig: String) async throws -> [String] {
        let out = try await run(context: context, ["get", "namespaces", "-o", "name", "--request-timeout=10s"], kubeconfig: kubeconfig)
        return out.split(separator: "\n").map { String($0).replacingOccurrences(of: "namespace/", with: "") }.sorted()
    }

    struct Probe {
        var serverVersion: String
        var elapsed: TimeInterval
    }

    /// `kubectl version` — самый дешёвый запрос, который проверяет адрес, TLS и аутентификацию.
    func probe(context: String, kubeconfig: String) async throws -> Probe {
        let start = Date()
        let out = try await run(context: context, ["version", "-o", "json", "--request-timeout=10s"], kubeconfig: kubeconfig)
        let elapsed = Date().timeIntervalSince(start)
        let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let ver = (json?["serverVersion"] as? [String: Any])?["gitVersion"] as? String ?? "?"
        return Probe(serverVersion: ver, elapsed: elapsed)
    }
}
