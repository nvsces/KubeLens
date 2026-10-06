import SwiftUI
import AppKit

/// Контекст, для которого выполняется вход: имя плюс KUBECONFIG, при котором kubectl его видит.
struct AuthKey: Hashable, Sendable {
    var context: String
    var kubeconfig: String
}

/// exec-плагин пользователя контекста (doctl, gke-gcloud-auth-plugin, aws…) в том виде,
/// в каком его запустил бы kubectl.
struct ExecPlugin: Sendable {
    var command: String
    var args: [String]
    var env: [String: String]
    var interactiveMode: String
    var installHint: String
    /// Значение `KUBERNETES_EXEC_INFO`, которое плагин получил бы от kubectl.
    var execInfo: String

    var name: String { URL(fileURLWithPath: command).lastPathComponent }

    /// Конфиг берём у kubectl (`config view --minify --flatten`): он сливает файлы цепочки,
    /// разрешает относительные пути и встраивает сертификаты. nil — контекст без exec.
    static func resolve(_ key: AuthKey) async throws -> ExecPlugin? {
        guard let exe = Kubectl.shared.executable else { throw SubprocessError.notFound("kubectl") }
        let r = try await Subprocess.run(exe, ["--context", key.context, "config", "view", "--minify", "--flatten", "-o", "json"],
                                         env: ["KUBECONFIG": key.kubeconfig, "PATH": Kubectl.shared.searchPath], timeout: 10)
        guard r.status == 0 else { throw SubprocessError.failed("kubectl", r.status, r.stderr) }
        guard let cfg = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let user = (cfg["users"] as? [[String: Any]])?.first?["user"] as? [String: Any],
              let exec = user["exec"] as? [String: Any],
              let command = exec["command"] as? String, !command.isEmpty else { return nil }

        var env: [String: String] = [:]
        for e in exec["env"] as? [[String: Any]] ?? [] {
            if let n = e["name"] as? String { env[n] = e["value"] as? String ?? "" }
        }
        var spec: [String: Any] = ["interactive": false]
        if exec["provideClusterInfo"] as? Bool == true,
           let cluster = (cfg["clusters"] as? [[String: Any]])?.first?["cluster"] as? [String: Any] {
            var info: [String: Any] = [:]
            for k in ["server", "tls-server-name", "insecure-skip-tls-verify", "certificate-authority-data", "proxy-url", "disable-compression"] {
                info[k] = cluster[k]
            }
            let ext = (cluster["extensions"] as? [[String: Any]])?.first { $0["name"] as? String == "client.authentication.k8s.io/exec" }
            info["config"] = ext?["extension"]
            spec["cluster"] = info
        }
        let apiVersion = exec["apiVersion"] as? String ?? "client.authentication.k8s.io/v1beta1"
        let info = try JSONSerialization.data(withJSONObject: ["apiVersion": apiVersion, "kind": "ExecCredential", "spec": spec])
        return ExecPlugin(command: command, args: exec["args"] as? [String] ?? [], env: env,
                          interactiveMode: exec["interactiveMode"] as? String ?? "",
                          installHint: exec["installHint"] as? String ?? "",
                          execInfo: String(decoding: info, as: UTF8.self))
    }

    /// Где плагин найдёт kubectl: команда с `/` — как есть, иначе поиск по PATH.
    var executablePath: String? {
        if command.contains("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        for dir in Kubectl.shared.searchPath.split(separator: ":") {
            let p = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Как поставить известные плагины; для остальных остаётся `installHint` из kubeconfig.
    var installCommand: String? {
        ["doctl": "brew install doctl",
         "aws": "brew install awscli",
         "aws-iam-authenticator": "brew install aws-iam-authenticator",
         "gke-gcloud-auth-plugin": "gcloud components install gke-gcloud-auth-plugin"][name]
    }

    /// doctl поднимает страницу входа на localhost и без `--verbose` ничего о ней не пишет.
    var knownLoginURL: URL? {
        guard name == "doctl", args.contains("--sso-client-id") else { return nil }
        let port = args.firstIndex(of: "--sso-local-server-port").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "8080"
        return URL(string: "http://localhost:\(port)/login")
    }

    /// Запуск так же, как это сделал бы kubectl, но с долгим таймаутом: вход в браузере
    /// занимает минуты. stderr построчно уходит в `onLog` — там бывают ссылки и коды устройств.
    /// Возвращает срок действия выданного токена, если плагин его сообщил.
    func run(kubeconfig: String, timeout: TimeInterval, onLog: @escaping @Sendable (String) -> Void) async throws -> Date? {
        guard let exe = executablePath else { throw AuthError.missing(plugin: name, install: installCommand) }
        var vars = ["PATH": Kubectl.shared.searchPath, "KUBECONFIG": kubeconfig]
        vars.merge(env) { _, new in new }
        vars["KUBERNETES_EXEC_INFO"] = execInfo
        let r = try await Subprocess.run(exe, args, env: vars, timeout: timeout, onStderr: onLog)
        guard r.status == 0 else {
            let line = SubprocessError.summary(r.stderr)
            throw AuthError.failed(plugin: name, message: line.isEmpty ? "код выхода \(r.status)" : line)
        }
        let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        let stamp = (json?["status"] as? [String: Any])?["expirationTimestamp"] as? String
        return stamp.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

enum AuthError: LocalizedError {
    case missing(plugin: String, install: String?)
    case needsTerminal(plugin: String)
    case failed(plugin: String, message: String)
    case cancelled(plugin: String)

    var errorDescription: String? {
        switch self {
        case .missing(let p, let install): return "Не установлен плагин авторизации «\(p)»" + (install.map { ". Установите: \($0)" } ?? "")
        case .needsTerminal(let p): return "\(p) запрашивает ввод в терминале — войдите через Terminal"
        case .failed(let p, let message): return "Не удалось войти через \(p): \(message)"
        case .cancelled(let p): return "Вход через \(p) отменён"
        }
    }
}

/// Вход через exec-плагины. kubectl запускает плагин на каждый вызов и убивается по своему
/// таймауту, а приложение делает вызовы параллельно — при входе через браузер это давало пачку
/// вкладок, занятый порт обратного вызова и обрыв посреди входа. Поэтому плагин сначала
/// запускаем здесь: один раз на контекст и с долгим таймаутом. Остальные вызовы ждут его,
/// а потом kubectl берёт токен из кэша плагина.
@MainActor
final class ClusterAuth: ObservableObject {
    static let shared = ClusterAuth()

    enum Status {
        case signingIn(log: [String])
        case ready(expires: Date?)
        case failed(AuthError)
    }

    struct Session {
        /// nil — контекст без exec-плагина, входить не нужно.
        var plugin: ExecPlugin?
        var status: Status
    }

    @Published private(set) var sessions: [AuthKey: Session] = [:]
    private var tasks: [AuthKey: Task<Void, Error>] = [:]

    /// Перед каждым вызовом kubectl. Действующий вход — сразу дальше, идущий — ждём его.
    /// После неудачи — ошибка без новой попытки: иначе автообновление открывало бы браузер раз за разом.
    func ensure(_ key: AuthKey) async throws {
        if let task = tasks[key] { return try await task.value }
        switch sessions[key]?.status {
        case .ready(let expires)?:
            if let expires, expires.timeIntervalSinceNow < 30 { try await signIn(key) }
        case .failed(let error)?:
            throw error
        case .signingIn?, nil:
            try await signIn(key)
        }
    }

    /// Войти заново: по кнопке, при проверке связи или когда токен истекает.
    func signIn(_ key: AuthKey) async throws {
        if let task = tasks[key] { return try await task.value }
        let task = Task {
            defer { tasks[key] = nil }
            try await perform(key)
        }
        tasks[key] = task
        try await task.value
    }

    func cancel(_ key: AuthKey) { tasks[key]?.cancel() }

    private func perform(_ key: AuthKey) async throws {
        // Если конфиг не разобрался, пусть дальше скажет kubectl — его сообщение точнее.
        guard let plugin = (try? await ExecPlugin.resolve(key)) ?? nil else {
            sessions[key] = Session(plugin: nil, status: .ready(expires: nil))
            return
        }
        do {
            guard plugin.executablePath != nil else { throw AuthError.missing(plugin: plugin.name, install: plugin.installCommand) }
            guard plugin.interactiveMode != "Always" else { throw AuthError.needsTerminal(plugin: plugin.name) }
            sessions[key] = Session(plugin: plugin, status: .signingIn(log: []))
            let expires = try await plugin.run(kubeconfig: key.kubeconfig, timeout: 300) { line in
                Task { @MainActor in self.log(line, key) }
            }
            sessions[key] = Session(plugin: plugin, status: .ready(expires: expires))
        } catch {
            let failure: AuthError
            if let e = error as? AuthError { failure = e }
            else if error is CancellationError { failure = .cancelled(plugin: plugin.name) }
            else if let e = error as? SubprocessError, case .timeout = e { failure = .failed(plugin: plugin.name, message: "вход не завершён за 5 минут") }
            else { failure = .failed(plugin: plugin.name, message: error.localizedDescription) }
            sessions[key] = Session(plugin: plugin, status: .failed(failure))
            throw failure
        }
    }

    private func log(_ line: String, _ key: AuthKey) {
        guard case .signingIn(var log)? = sessions[key]?.status else { return }
        log.append(line)
        sessions[key]?.status = .signingIn(log: Array(log.suffix(20)))
    }
}

/// Полоса над содержимым: идёт вход, плагин не установлен, вход не удался.
/// Для контекстов без exec-плагина и после успешного входа её нет.
struct AuthBanner: View {
    let key: AuthKey
    /// После успешного входа по кнопке — догрузить то, что не загрузилось.
    var onSignedIn: () -> Void = {}
    @ObservedObject private var auth = ClusterAuth.shared

    var body: some View {
        if let session = auth.sessions[key], let plugin = session.plugin {
            switch session.status {
            case .ready:
                EmptyView()
            case .signingIn(let log):
                // С токеном в кэше плагин отвечает мгновенно — не мигаем полосой зря.
                Delayed {
                    bar(icon: nil, tint: .accentColor, title: "Вход через \(plugin.name)…",
                        detail: log.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Завершите авторизацию в открывшемся окне браузера.") {
                        if let url = loginURL(log, plugin) {
                            Button("Открыть страницу входа") { NSWorkspace.shared.open(url) }
                        }
                        Button("Отмена") { auth.cancel(key) }
                    }
                }
            case .failed(let error):
                failure(plugin, error)
            }
        }
    }

    @ViewBuilder
    private func failure(_ plugin: ExecPlugin, _ error: AuthError) -> some View {
        switch error {
        case .missing(let p, let install):
            bar(icon: "puzzlepiece.extension", tint: .orange, title: "Не установлен плагин авторизации «\(p)»",
                detail: install.map { "Установите: \($0)" } ?? (plugin.installHint.isEmpty ? "Контекст получает токен через команду \(p), а её нет в PATH." : plugin.installHint)) {
                if let install { Button("Установить в Терминале") { terminal { try $0.openInstallTerminal(install) } } }
                Button("Проверить снова") { retry() }
            }
        case .needsTerminal(let p):
            bar(icon: "terminal", tint: .orange, title: "\(p) запрашивает ввод в терминале",
                detail: "Войдите в Терминале, затем нажмите «Проверить снова».") {
                Button("Войти в Терминале") { terminal { try $0.openSignInTerminal() } }
                Button("Проверить снова") { retry() }
            }
        case .cancelled(let p):
            bar(icon: "person.crop.circle.badge.xmark", tint: .secondary, title: "Вход через \(p) отменён", detail: nil) { signInButtons }
        case .failed(let p, let message):
            bar(icon: "xmark.octagon.fill", tint: .red, title: "Не удалось войти через \(p)", detail: message) { signInButtons }
        }
    }

    @ViewBuilder
    private var signInButtons: some View {
        Button("Войти") { retry() }.buttonStyle(.borderedProminent)
        Button("В Терминале") { terminal { try $0.openSignInTerminal() } }
            .help("Если плагину нужен ввод с клавиатуры")
    }

    private func bar<Actions: View>(icon: String?, tint: Color, title: String, detail: String?, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon { Image(systemName: icon).font(.title3).foregroundStyle(tint) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer(minLength: Theme.gap)
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ZStack { Theme.pageBackground; tint.opacity(0.1) } }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Последняя ссылка из вывода плагина, иначе известная страница входа.
    private func loginURL(_ log: [String], _ plugin: ExecPlugin) -> URL? {
        for line in log.reversed() {
            if let r = line.range(of: #"https?://\S+"#, options: .regularExpression), let url = URL(string: String(line[r])) { return url }
        }
        return plugin.knownLoginURL
    }

    private func retry() {
        Task { if (try? await auth.signIn(key)) != nil { onSignedIn() } }
    }

    private func terminal(_ open: (ClusterClient) throws -> Void) {
        try? open(ClusterClient(target: ClusterTarget(context: key.context, kubeconfig: key.kubeconfig)))
    }
}

/// Показывает содержимое с задержкой, если оно к тому времени ещё нужно.
private struct Delayed<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        if shown { content }
        else { Color.clear.frame(height: 0).task { try? await Task.sleep(for: .milliseconds(700)); shown = true } }
    }
}
