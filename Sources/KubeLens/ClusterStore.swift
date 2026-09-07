import Foundation
import Combine

/// Состояние окна «Кластер»: выбранный вид ресурса, namespace, список, автообновление,
/// активные port-forward. Один экземпляр на окно.
@MainActor
final class ClusterStore: ObservableObject {
    let target: ClusterTarget
    let client: ClusterClient

    @Published var kind: ResourceKind = ResourceKind.all[0] { didSet { if kind != oldValue { kindChanged() } } }
    @Published var namespace: String? { didSet { if namespace != oldValue { counts = [:]; Task { await refresh(); await loadCounts() } } } }
    @Published private(set) var namespaces: [String] = []
    @Published private(set) var items: [KResource] = []
    @Published var selection: KResource.ID?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var notice: String?
    @Published var search = ""
    @Published var autoRefresh = true { didSet { if autoRefresh { startTimer() } else { timer?.cancel() } } }
    @Published var forwards: [PortForward] = []
    @Published private(set) var lastRefresh: Date?
    @Published var busy: String?
    /// Счётчики для сайдбара: сколько объектов каждого вида в текущем namespace.
    @Published private(set) var counts: [String: Int] = [:]

    private var timer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return v == 0 ? 5 : max(v, 2)
    }

    init(target: ClusterTarget) {
        self.target = target
        client = ClusterClient(target: target)
        namespace = target.namespace
        Task {
            await loadNamespaces()
            await refresh()
            await loadCounts()
        }
        startTimer()
    }

    var filtered: [KResource] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { r in
            r.name.lowercased().contains(q) || (r.namespace?.lowercased().contains(q) ?? false)
                || kind.columns.contains { $0.value(r).lowercased().contains(q) }
        }
    }

    var selected: KResource? { items.first { $0.id == selection } }

    private func kindChanged() {
        items = []
        selection = nil
        Task { await refresh() }
    }

    func loadNamespaces() async {
        do { namespaces = try await client.namespaces() } catch { self.error = error.localizedDescription }
    }

    /// Счётчики основных видов — одним `kubectl get` на вид, только для сайдбара.
    func loadCounts() async {
        let wanted = ["pods", "deployments.apps", "statefulsets.apps", "daemonsets.apps", "jobs.batch",
                      "cronjobs.batch", "services", "ingresses.networking.k8s.io", "configmaps", "secrets",
                      "persistentvolumeclaims", "nodes", "namespaces"]
        for id in wanted {
            guard let k = ResourceKind.find(id), !Task.isCancelled else { continue }
            if let list = try? await client.list(k, namespace: namespace) { counts[id] = list.count }
        }
    }

    func refresh() async {
        refreshTask?.cancel()
        let task = Task { [kind, namespace] in
            loading = true
            defer { loading = false }
            do {
                let list = try await client.list(kind, namespace: namespace)
                guard !Task.isCancelled, kind == self.kind, namespace == self.namespace else { return }
                items = list
                counts[kind.id] = list.count
                lastRefresh = Date()
                if error?.hasPrefix("kubectl") == true { error = nil }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        refreshTask = task
        await task.value
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 5))
                guard let self, !Task.isCancelled, self.autoRefresh, !self.loading else { continue }
                await self.refresh()
            }
        }
    }

    /// Действие над кластером: индикатор занятости, ошибка в алерт, обновление списка после.
    func perform(_ label: String, refreshAfter: Bool = true, _ op: @escaping () async throws -> Void) {
        Task {
            busy = label
            defer { busy = nil }
            do {
                try await op()
                notice = "\(label): готово"
                if refreshAfter { await refresh() }
            } catch {
                self.error = "\(label): \(error.localizedDescription)"
            }
        }
    }

    func addForward(_ r: KResource, localPort: Int, remotePort: Int) {
        do {
            forwards.append(try PortForward(client: client, resource: r, localPort: localPort, remotePort: remotePort))
        } catch { self.error = error.localizedDescription }
    }

    func removeForward(_ f: PortForward) {
        f.stop()
        forwards.removeAll { $0.id == f.id }
    }

    func shutdown() {
        timer?.cancel()
        refreshTask?.cancel()
        for f in forwards { f.stop() }
    }
}
