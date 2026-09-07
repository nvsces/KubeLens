import Foundation
import AppKit

/// Какой кластер открыт в окне: контекст и значение KUBECONFIG, при котором kubectl его видит.
struct ClusterTarget: Hashable, Codable {
    var context: String
    var kubeconfig: String
    var namespace: String?
}

/// Все обращения к кластеру идут через kubectl: он умеет все способы аутентификации из
/// kubeconfig (exec-плагины облаков, OIDC, сертификаты), которые своим клиентом
/// пришлось бы повторять. Читаем `-o json`, пишем `apply -f -`.
final class ClusterClient: @unchecked Sendable {
    let target: ClusterTarget
    init(target: ClusterTarget) { self.target = target }

    func run(_ args: [String], input: Data? = nil, timeout: TimeInterval = 20) async throws -> String {
        try await Kubectl.shared.run(["--context", target.context] + args, kubeconfig: target.kubeconfig, input: input, timeout: timeout)
    }

    private func nsArgs(_ kind: ResourceKind, _ namespace: String?) -> [String] {
        guard kind.namespaced else { return [] }
        return namespace.map { ["-n", $0] } ?? ["-A"]
    }
    private func nsArgs(_ r: KResource) -> [String] { r.namespace.map { ["-n", $0] } ?? [] }

    func list(_ kind: ResourceKind, namespace: String?) async throws -> [KResource] {
        let out = try await run(["get", kind.id, "-o", "json"] + nsArgs(kind, namespace), timeout: 40)
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        var result = items.compactMap { KResource(json: $0, kind: kind.kind) }
        if kind.id == "events" {
            result.sort { (ResourceKind.eventTime($0) ?? .distantPast) > (ResourceKind.eventTime($1) ?? .distantPast) }
        } else {
            result.sort { ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name) }
        }
        return result
    }

    func get(_ r: KResource) async throws -> [String: Any] {
        let out = try await run(["get", r.kind, r.name, "-o", "json"] + nsArgs(r))
        return try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] ?? [:]
    }

    /// `kubectl apply -f -` с JSON на stdin — kubectl принимает JSON так же, как YAML.
    @discardableResult
    func apply(_ object: Any) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await run(["apply", "-f", "-"], input: data, timeout: 60)
    }

    /// Текст манифеста от пользователя: разбираем своим YAML-парсером, отдаём JSON-ом.
    @discardableResult
    func apply(yaml: String) async throws -> String {
        let node = try YAML.parse(yaml)
        let obj = JSONYAML.json(from: node)
        return try await apply(obj)
    }

    /// Merge-патч: `null` в значении удаляет ключ.
    func patch(_ r: KResource, merge object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        _ = try await run(["patch", r.kind, r.name, "--type", "merge", "-p", String(decoding: data, as: UTF8.self)] + nsArgs(r))
    }

    /// Strategic-патч (по умолчанию у kubectl для встроенных типов): списки контейнеров и env
    /// сливаются по `name`, удаление элемента — `{"name": …, "$patch": "delete"}`.
    func strategicPatch(_ r: KResource, _ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        _ = try await run(["patch", r.kind, r.name, "--type", "strategic", "-p", String(decoding: data, as: UTF8.self)] + nsArgs(r))
    }

    func delete(_ r: KResource, force: Bool = false) async throws {
        var args = ["delete", r.kind, r.name] + nsArgs(r)
        if force { args += ["--grace-period=0", "--force"] }
        _ = try await run(args, timeout: 120)
    }

    func scale(_ r: KResource, replicas: Int) async throws {
        _ = try await run(["scale", "\(r.kind)/\(r.name)", "--replicas=\(replicas)"] + nsArgs(r))
    }

    func rolloutRestart(_ r: KResource) async throws {
        _ = try await run(["rollout", "restart", "\(r.kind)/\(r.name)"] + nsArgs(r))
    }

    func describe(_ r: KResource) async throws -> String {
        try await run(["describe", r.kind, r.name] + nsArgs(r), timeout: 40)
    }

    func events(for r: KResource) async throws -> [KResource] {
        var args = ["get", "events", "-o", "json", "--field-selector", "involvedObject.name=\(r.name),involvedObject.kind=\(r.kind)"]
        args += r.namespace.map { ["-n", $0] } ?? ["-A"]
        let out = try await run(args)
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { KResource(json: $0, kind: "Event") }
            .sorted { (ResourceKind.eventTime($0) ?? .distantPast) > (ResourceKind.eventTime($1) ?? .distantPast) }
    }

    func namespaces() async throws -> [String] {
        let out = try await run(["get", "namespaces", "-o", "name"])
        return out.split(separator: "\n").map { String($0).replacingOccurrences(of: "namespace/", with: "") }.sorted()
    }

    func cordon(_ node: KResource, on: Bool) async throws {
        _ = try await run([on ? "cordon" : "uncordon", node.name])
    }

    func drain(_ node: KResource) async throws {
        _ = try await run(["drain", node.name, "--ignore-daemonsets", "--delete-emptydir-data", "--force"], timeout: 300)
    }

    func suspendCronJob(_ r: KResource, _ suspend: Bool) async throws {
        _ = try await run(["patch", "cronjob", r.name, "-p", "{\"spec\":{\"suspend\":\(suspend)}}"] + nsArgs(r))
    }

    func triggerCronJob(_ r: KResource) async throws {
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        _ = try await run(["create", "job", "\(r.name)-manual-\(stamp)", "--from=cronjob/\(r.name)"] + nsArgs(r))
    }

    /// Интерактивная сессия в Terminal.app: пишем .command-скрипт и открываем его —
    /// так не нужно разрешение на Apple Events.
    func openExecTerminal(pod: KResource, container: String?, command: String = "sh -c 'command -v bash >/dev/null && exec bash || exec sh'") throws {
        guard let exe = Kubectl.shared.executable else { throw SubprocessError.notFound("kubectl") }
        var cmd = [shellQuote(exe), "--context", shellQuote(target.context), "exec", "-it", "-n", shellQuote(pod.namespace ?? "default"), shellQuote(pod.name)]
        if let container { cmd += ["-c", shellQuote(container)] }
        cmd += ["--", command]
        let script = """
        #!/bin/bash
        export KUBECONFIG=\(shellQuote(target.kubeconfig))
        export PATH=\(shellQuote(Kubectl.shared.searchPath))
        printf '\\033]0;%s\\007' \(shellQuote("\(pod.name) · \(target.context)"))
        \(cmd.joined(separator: " "))
        """
        try openInTerminal(script: script, name: "exec-\(pod.name)")
    }

    /// Открыть shell с уже выставленным KUBECONFIG и контекстом.
    func openShellTerminal(namespace: String?) throws {
        var ns = ""
        if let namespace { ns = "\nexport KUBECTL_NAMESPACE=\(shellQuote(namespace))\nalias k='kubectl -n \(shellQuote(namespace))'" }
        let script = """
        #!/bin/bash
        export KUBECONFIG=\(shellQuote(target.kubeconfig))
        export PATH=\(shellQuote(Kubectl.shared.searchPath))
        printf '\\033]0;%s\\007' \(shellQuote(target.context))
        echo "kubectl → контекст \(target.context)\(namespace.map { ", namespace \($0)" } ?? "")"\(ns)
        exec ${SHELL:-/bin/zsh} -i
        """
        try openInTerminal(script: script, name: "shell-\(target.context)")
    }

    private func openInTerminal(script: String, name: String) throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KubeLens/terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let url = dir.appendingPathComponent(safe + ".command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", url.path]
        try p.run()
    }
}

/// Долгоживущий процесс kubectl (logs -f, port-forward), вывод которого читается построчно.
final class StreamingProcess {
    private let process = Process()
    private let pipe = Pipe()
    private(set) var isRunning = false
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private var buffer = Data()

    init(args: [String], env: [String: String]) throws {
        guard let exe = Kubectl.shared.executable else { throw SubprocessError.notFound("kubectl") }
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        process.environment = e
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            self.buffer.append(data)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: self.buffer[..<nl], as: UTF8.self)
                self.buffer.removeSubrange(...nl)
                DispatchQueue.main.async { self.onLine?(line) }
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            let rest = self.pipe.fileHandleForReading.readDataToEndOfFile()
            let tail = String(decoding: self.buffer + rest, as: UTF8.self)
            DispatchQueue.main.async {
                if !tail.isEmpty { self.onLine?(tail) }
                self.isRunning = false
                self.onExit?(p.terminationStatus)
            }
        }
        try process.run()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        process.terminate()
    }

    deinit { if process.isRunning { process.terminate() } }
}

/// Поток логов одного контейнера.
@MainActor
final class LogStream: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    @Published var error: String?
    private var proc: StreamingProcess?
    private let maxLines = 5000

    func start(client: ClusterClient, pod: KResource, container: String?, previous: Bool, tail: Int, follow: Bool, timestamps: Bool) {
        stop()
        lines = []
        error = nil
        var args = ["--context", client.target.context, "logs", pod.name, "-n", pod.namespace ?? "default", "--tail=\(tail)"]
        if let container { args += ["-c", container] }
        if previous { args.append("--previous") }
        if follow { args.append("-f") }
        if timestamps { args.append("--timestamps") }
        do {
            let p = try StreamingProcess(args: args, env: ["KUBECONFIG": client.target.kubeconfig, "PATH": Kubectl.shared.searchPath])
            p.onLine = { [weak self] line in
                guard let self else { return }
                self.lines.append(line)
                if self.lines.count > self.maxLines { self.lines.removeFirst(self.lines.count - self.maxLines) }
            }
            p.onExit = { [weak self] code in
                self?.running = false
                if code != 0, let last = self?.lines.last { self?.error = last }
            }
            try p.start()
            proc = p
            running = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        proc?.stop()
        proc = nil
        running = false
    }
}

/// Активный `kubectl port-forward`.
@MainActor
final class PortForward: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let localPort: Int
    let remotePort: Int
    @Published private(set) var status = "запуск…"
    @Published private(set) var running = false
    @Published private(set) var log: [String] = []
    private var proc: StreamingProcess?

    init(client: ClusterClient, resource: KResource, localPort: Int, remotePort: Int) throws {
        self.localPort = localPort
        self.remotePort = remotePort
        title = "\(resource.kind.lowercased())/\(resource.name)"
        let args = ["--context", client.target.context, "port-forward", "-n", resource.namespace ?? "default",
                    "\(resource.kind.lowercased())/\(resource.name)", "\(localPort):\(remotePort)"]
        let p = try StreamingProcess(args: args, env: ["KUBECONFIG": client.target.kubeconfig, "PATH": Kubectl.shared.searchPath])
        p.onLine = { [weak self] line in
            guard let self else { return }
            self.log.append(line)
            if self.log.count > 200 { self.log.removeFirst() }
            if line.contains("Forwarding from") { self.status = "localhost:\(localPort) → \(remotePort)" }
            else if line.lowercased().contains("error") { self.status = line }
        }
        p.onExit = { [weak self] code in
            self?.running = false
            self?.status = code == 0 ? "остановлен" : "завершился (\(code)): \(self?.log.last ?? "")"
        }
        try p.start()
        proc = p
        running = true
    }

    func stop() {
        proc?.stop()
        running = false
        status = "остановлен"
    }
}
