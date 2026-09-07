import SwiftUI
import AppKit

/// Окно кластера: виды ресурсов → таблица → карточка объекта.
struct ClusterWindow: View {
    @StateObject private var store: ClusterStore

    init(target: ClusterTarget) {
        _store = StateObject(wrappedValue: ClusterStore(target: target))
    }

    var body: some View {
        ClusterView()
            .environmentObject(store)
            .navigationTitle(store.target.context)
            .navigationSubtitle(store.namespace ?? "все namespaces")
            .onDisappear { store.shutdown() }
    }
}

struct ClusterView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var showCreate = false
    @State private var kindSelection: String? = ResourceKind.all[0].id
    /// Стек страниц как в Rancher: таблица → объект → связанный объект (под из деплоймента).
    @State private var path: [KResource] = []

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            NavigationStack(path: $path) {
                ResourceTable(showCreate: $showCreate, onOpen: { path.append($0) })
                    .navigationDestination(for: KResource.self) { r in
                        ResourcePage(initial: r, onOpen: { path.append($0) })
                    }
            }
        }
        .onChange(of: store.kind) { _, _ in path = [] }
        .task {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--open"), i + 3 < args.count, let k = ResourceKind.find(args[i + 1]) else { return }
            store.namespace = args[i + 2]
            store.kind = k
            kindSelection = k.id
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if let r = store.items.first(where: { $0.name == args[i + 3] }) { path = [r]; break }
            }
        }
        .sheet(isPresented: $showCreate) { CreateSheet() }
        .alert("Ошибка", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: kindSelection) { _, id in if let id, let k = ResourceKind.find(id) { store.kind = k } }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if store.notice == notice { store.notice = nil }
                    }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $kindSelection) {
            ForEach(ResourceKind.groups, id: \.self) { group in
                Section {
                    ForEach(ResourceKind.all.filter { $0.group == group }) { k in
                        HStack(spacing: 8) {
                            Image(systemName: k.icon).frame(width: 18).foregroundStyle(kindSelection == k.id ? Color.accentColor : Color.secondary)
                            Text(k.title)
                            Spacer(minLength: 4)
                            if let n = store.counts[k.id] {
                                Text("\(n)").font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.vertical, 1)
                        .tag(k.id)
                    }
                } header: {
                    Text(group).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
                }
            }
            if !store.forwards.isEmpty {
                Section {
                    ForEach(store.forwards) { f in ForwardRow(forward: f) }
                } header: {
                    Text("Port-forward").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Button {
                        do { try store.client.openShellTerminal(namespace: store.namespace) } catch { store.error = error.localizedDescription }
                    } label: { Label("Terminal", systemImage: "terminal").font(.callout) }
                    .buttonStyle(.borderless).help("Открыть Terminal с этим контекстом")
                    Spacer()
                    if let busy = store.busy {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}

struct ForwardRow: View {
    @EnvironmentObject var store: ClusterStore
    @ObservedObject var forward: PortForward

    var body: some View {
        HStack {
            Image(systemName: forward.running ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
                .foregroundStyle(forward.running ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(forward.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(forward.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { store.removeForward(forward) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Открыть http://localhost:\(forward.localPort)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(forward.localPort)")!) }
            Button("Скопировать localhost:\(forward.localPort)") { copy("localhost:\(forward.localPort)") }
            Button("Остановить") { store.removeForward(forward) }
        }
        .help(forward.log.suffix(5).joined(separator: "\n"))
    }
}

struct ResourceTable: View {
    @EnvironmentObject var store: ClusterStore
    @Binding var showCreate: Bool
    var onOpen: (KResource) -> Void
    @State private var confirmDelete: KResource?

    var body: some View {
        Table(store.filtered, selection: $store.selection) {
            TableColumnForEach(store.kind.columns) { col in
                TableColumn(col.title) { (r: KResource) in
                    cell(col, r).padding(.vertical, 5)
                }
                .width(min: 40, ideal: col.width ?? 120)
            }
        }
        .id(store.kind.id + (store.namespace ?? "*"))
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: KResource.ID.self) { ids in
            if let id = ids.first, let r = store.items.first(where: { $0.id == id }) {
                Button("Открыть") { onOpen(r) }
                Divider()
                ResourceActions(resource: r, confirmDelete: $confirmDelete)
            }
        } primaryAction: { ids in
            if let id = ids.first, let r = store.items.first(where: { $0.id == id }) { onOpen(r) }
        }
        .overlay {
            if store.filtered.isEmpty {
                if store.loading && store.items.isEmpty { ProgressView() }
                else { ContentUnavailableView(store.search.isEmpty ? "Нет объектов" : "Ничего не найдено", systemImage: store.kind.icon) }
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Фильтр")
        .toolbar { toolbar }
        .confirmationDialog("Удалить \(confirmDelete?.kind ?? "") «\(confirmDelete?.name ?? "")»?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { r in
            Button("Удалить", role: .destructive) { store.perform("Удаление \(r.name)") { try await store.client.delete(r) } }
            Button("Удалить принудительно (--force)", role: .destructive) { store.perform("Удаление \(r.name)") { try await store.client.delete(r, force: true) } }
            Button("Отмена", role: .cancel) {}
        } message: { r in
            Text(r.namespace.map { "Namespace \($0). " } ?? "" + "Действие необратимо.")
        }
        .onDeleteCommand { if let r = store.selected { confirmDelete = r } }
    }

    @ViewBuilder
    private func cell(_ col: ResourceColumn, _ r: KResource) -> some View {
        let v = col.value(r)
        switch col.title {
        case "Статус":
            if v.isEmpty { Text("") } else { StateBadge(text: v, compact: true) }
        case "Тип" where r.kind == "Event":
            StateBadge(text: v, color: v == "Warning" ? .orange : .secondary, compact: true)
        case "Имя":
            LinkText(text: v) { onOpen(r) }
        case "Возраст", "Namespace", "Узел", "IP", "Образы", "Ключи":
            Text(v).foregroundStyle(.secondary)
        case "Ready", "Рестарты":
            Text(v).monospacedDigit().foregroundStyle(v.hasPrefix("0") && v.count == 1 ? .secondary : .primary)
        default:
            Text(v)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if store.kind.namespaced {
                Picker("Namespace", selection: $store.namespace) {
                    Text("Все namespaces").tag(String?.none)
                    Divider()
                    ForEach(store.namespaces, id: \.self) { Text($0).tag(String?.some($0)) }
                    if let ns = store.namespace, !store.namespaces.contains(ns) { Text(ns).tag(String?.some(ns)) }
                }
                .frame(minWidth: 180)
                .help("Namespace")
            }
        }
        ToolbarItemGroup {
            if store.loading { ProgressView().controlSize(.small) }
            Text(store.lastRefresh.map { "обновлено \(Self.time.string(from: $0))" } ?? "")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { Task { await store.refresh() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r").disabled(store.loading)
            Toggle(isOn: $store.autoRefresh) { Label("Авто", systemImage: "arrow.triangle.2.circlepath") }
                .help("Автообновление каждые \(Int(store.refreshInterval)) с")
            Button { showCreate = true } label: { Label("Создать", systemImage: "plus") }
                .help("Создать объект из YAML")
        }
    }

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}

/// Пункты действий — общие для контекстного меню таблицы и кнопки в карточке.
struct ResourceActions: View {
    @EnvironmentObject var store: ClusterStore
    let resource: KResource
    @Binding var confirmDelete: KResource?
    var onScale: (() -> Void)? = nil
    var onForward: (() -> Void)? = nil

    var body: some View {
        let r = resource
        Button("Скопировать имя") { copy(r.name) }
        Button("Скопировать kubectl get …") {
            copy("kubectl --context=\(shellQuote(store.target.context))\(r.namespace.map { " -n \(shellQuote($0))" } ?? "") get \(r.kind.lowercased()) \(shellQuote(r.name)) -o yaml")
        }
        Divider()
        switch r.kind {
        case "Deployment", "StatefulSet", "ReplicaSet":
            if let onScale { Button("Масштабировать…") { onScale() } }
            if r.kind != "ReplicaSet" {
                Button("Rollout restart") { store.perform("Перезапуск \(r.name)") { try await store.client.rolloutRestart(r) } }
            }
        case "DaemonSet":
            Button("Rollout restart") { store.perform("Перезапуск \(r.name)") { try await store.client.rolloutRestart(r) } }
        case "Pod":
            Menu("Shell в контейнере") {
                ForEach(r.list("spec.containers").compactMap { $0["name"] as? String }, id: \.self) { c in
                    Button(c) { do { try store.client.openExecTerminal(pod: r, container: c) } catch { store.error = error.localizedDescription } }
                }
            }
            if let onForward { Button("Port-forward…") { onForward() } }
        case "Service":
            if let onForward { Button("Port-forward…") { onForward() } }
        case "Node":
            if r.get("spec.unschedulable") as? Bool == true {
                Button("Uncordon") { store.perform("Uncordon \(r.name)") { try await store.client.cordon(r, on: false) } }
            } else {
                Button("Cordon") { store.perform("Cordon \(r.name)") { try await store.client.cordon(r, on: true) } }
            }
            Button("Drain…") { store.perform("Drain \(r.name)") { try await store.client.drain(r) } }
        case "CronJob":
            Button("Запустить сейчас") { store.perform("Запуск \(r.name)") { try await store.client.triggerCronJob(r) } }
            if r.get("spec.suspend") as? Bool == true {
                Button("Возобновить") { store.perform("Возобновление \(r.name)") { try await store.client.suspendCronJob(r, false) } }
            } else {
                Button("Приостановить") { store.perform("Приостановка \(r.name)") { try await store.client.suspendCronJob(r, true) } }
            }
        case "Ingress":
            ForEach(ingressURLs(r), id: \.self) { u in Button("Открыть \(u)") { if let url = URL(string: u) { NSWorkspace.shared.open(url) } } }
        default: EmptyView()
        }
        Divider()
        Button("Удалить…", role: .destructive) { confirmDelete = r }
    }
}

func ingressURLs(_ r: KResource) -> [String] {
    let tlsHosts = Set(r.list("spec.tls").flatMap { ($0["hosts"] as? [String]) ?? [] })
    return r.list("spec.rules").compactMap { rule in
        guard let host = rule["host"] as? String else { return nil }
        let path = ((rule["http"] as? [String: Any])?["paths"] as? [[String: Any]])?.first?["path"] as? String ?? "/"
        return (tlsHosts.contains(host) ? "https://" : "http://") + host + (path.hasPrefix("/") ? path : "/" + path)
    }
}

/// Создание объекта из YAML (или JSON) — `kubectl apply -f -`.
struct CreateSheet: View {
    @EnvironmentObject var store: ClusterStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?
    @State private var error: String?
    @State private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Создать или обновить объект").font(.headline)
            Text("Манифест применяется через kubectl apply\(store.namespace.map { "; namespace по умолчанию — \($0)" } ?? "").")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: example\ndata:\n  key: value")
                            .font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                    }
                }
            HStack {
                Menu("Шаблон") {
                    ForEach(Templates.all, id: \.0) { t in Button(t.0) { text = t.1 } }
                }.fixedSize()
                if let result { Text(result).font(.caption).foregroundStyle(.green).lineLimit(2) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(applying ? "Применяю…" : "Применить") { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(applying || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 680, height: 520)
    }

    private func apply() {
        applying = true; error = nil; result = nil
        Task {
            defer { applying = false }
            do {
                var yaml = text
                // Namespace из тулбара — если в манифесте не указан.
                if let ns = store.namespace, var node = try? YAML.parse(yaml), var meta = node["metadata"], meta["namespace"] == nil, node["kind"]?.string != "Namespace" {
                    let kindName = node["kind"]?.string ?? ""
                    let clusterScoped = ResourceKind.all.first { $0.kind == kindName }?.namespaced == false
                    if !clusterScoped { meta["namespace"] = .string(ns); node["metadata"] = meta; yaml = YAML.emit(node) }
                }
                result = try await store.client.apply(yaml: yaml).trimmingCharacters(in: .whitespacesAndNewlines)
                await store.refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}

enum Templates {
    static let all: [(String, String)] = [
        ("Deployment", """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: example
          labels:
            app: example
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: example
          template:
            metadata:
              labels:
                app: example
            spec:
              containers:
              - name: app
                image: nginx:1.27
                ports:
                - containerPort: 80
                resources:
                  requests:
                    cpu: 50m
                    memory: 64Mi
                  limits:
                    memory: 128Mi
        """),
        ("Service", """
        apiVersion: v1
        kind: Service
        metadata:
          name: example
        spec:
          selector:
            app: example
          ports:
          - port: 80
            targetPort: 80
        """),
        ("Ingress", """
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: example
        spec:
          ingressClassName: nginx
          rules:
          - host: example.local
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: example
                    port:
                      number: 80
        """),
        ("ConfigMap", """
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: example
        data:
          key: value
        """),
        ("Secret", """
        apiVersion: v1
        kind: Secret
        metadata:
          name: example
        type: Opaque
        stringData:
          password: change-me
        """),
        ("Namespace", """
        apiVersion: v1
        kind: Namespace
        metadata:
          name: example
        """),
        ("CronJob", """
        apiVersion: batch/v1
        kind: CronJob
        metadata:
          name: example
        spec:
          schedule: "*/5 * * * *"
          jobTemplate:
            spec:
              template:
                spec:
                  restartPolicy: OnFailure
                  containers:
                  - name: job
                    image: busybox:1.36
                    command: ["sh", "-c", "date"]
        """),
    ]
}
