import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement
import Darwin

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: Int32 = -1
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            let directory = PreferencesStore.standard.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            instanceLock = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            if instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
                NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .first { $0.processIdentifier != getpid() }?.activate(options: .activateIgnoringOtherApps)
                NSApplication.shared.terminate(nil)
            }
        } catch {
            // The model reports settings-directory errors in the interface.
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.title == "Terminal Layout" }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        DirectoryScriptLifecycle.shared.terminate()
        if instanceLock >= 0 { close(instanceLock) }
    }
}

#if !TESTING
@main
struct TerminalLayoutApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = LayoutModel()
    var body: some Scene {
        Window("Terminal Layout", id: "main") {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: model.preferences.language))
                .environment(\.layoutDirection, model.preferences.language == "ar" ? .rightToLeft : .leftToRight)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 780)
        MenuBarExtra("Terminal Layout", systemImage: "rectangle.split.2x2") {
            BackgroundMenu().environmentObject(model)
        }
    }
}
#endif

@MainActor
final class LayoutModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            scanLease?.cancel()
            do { try store.save(preferences) }
            catch { statusKey = "error"; detail = error.localizedDescription }
        }
    }
    @Published var showWelcome = false
    @Published var showReset = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var busy = false
    @Published var statusKey = "ready"
    @Published var detail = ""
    @Published var promptInstalled = false
    @Published var canUndo = false
    @Published var showOverview = false
    @Published var observedWindows: [ManagedWindow] = []
    @Published var backgroundKey = "autoActive"
    @Published var pendingZoom = false
    @Published var pathAccessIssue = false
    @Published var loginEnabled = false
    private let coordinator: WindowCoordinator
    private let monitoringEnabled: Bool
    private var timer: Timer?
    private var scanning = false
    private var scanLease: AutomationLease?
    private var requestedForce = false
    private let store: PreferencesStore
    private let shellFile: URL

    init(store: PreferencesStore = .standard, shellFile: URL? = nil, monitoringEnabled: Bool = true) {
        self.store = store
        self.monitoringEnabled = monitoringEnabled
        self.coordinator = WindowCoordinator(ledgerFile: store.directory.appendingPathComponent("window-zoom.json"))
        self.shellFile = shellFile ?? PromptConfiguration.shellFile(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment)
        do { preferences = try store.load() }
        catch {
            preferences = Preferences()
            statusKey = "error"
            detail = error.localizedDescription
        }
        showWelcome = !preferences.completedWelcome
        refresh()
        // Once the user has completed setup, keep the compact prompt active for
        // every newly opened zsh terminal. Older builds required a second,
        // easy-to-miss button click here.
        if preferences.completedWelcome && (try? PromptConfiguration.read(self.shellFile).contains(PromptConfiguration.start)) != true {
            do {
                try PromptConfiguration.update(file: self.shellFile,
                    backupDirectory: store.directory.appendingPathComponent("Shell Backups"), install: true)
                refresh()
            } catch {
                statusKey = "error"
                detail = error.localizedDescription
            }
        }
        if monitoringEnabled {
            loginEnabled = SMAppService.mainApp.status == .enabled
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    // TCC can change while System Settings is open. Recheck
                    // independently of the welcome screen and current scan.
                    self?.refreshPermissions()
                    self?.updateBackground()
                }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func t(_ key: String) -> String { Translations.bundled.text(key, language: preferences.language) }
    var isRTL: Bool { preferences.language == "ar" }
    func refresh() {
        refreshPermissions()
        if monitoringEnabled { loginEnabled = SMAppService.mainApp.status == .enabled }
        do {
            let text = try PromptConfiguration.read(shellFile)
            promptInstalled = text.contains(PromptConfiguration.start)
                || text.contains(PromptConfiguration.legacy) || text.contains(PromptConfiguration.earlierLegacy)
        } catch {
            statusKey = "error"; detail = error.localizedDescription
        }
    }
    func refreshPermissions() {
        trusted = AXIsProcessTrusted()
        backgroundKey = trusted ? (preferences.automatic ? "autoActive" : "autoPaused") : "permissionNeeded"
    }
    func toggle(_ id: String, enabled: Bool) {
        if enabled {
            if !preferences.selectedApps.contains(id) { preferences.selectedApps.append(id) }
        } else {
            preferences.selectedApps.removeAll { $0 == id }
        }
    }
    func openPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // The TCC database is updated after the settings UI changes. Polling
        // here makes the green status appear without requiring a relaunch.
        for delay in [1.0, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                if self.trusted { self.updateBackground(force: true) }
            }
        }
    }
    func openTerminals(count: Int) {
        guard !busy, count == 2 || count == 4 else { return }
        refreshPermissions()
        guard trusted else { openPermissions(); return }
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        // Install before starting shells so the first prompt already uses the left edge.
        do {
            try PromptConfiguration.update(file: shellFile,
                backupDirectory: store.directory.appendingPathComponent("Shell Backups"), install: true)
            promptInstalled = true
        } catch { statusKey = "error"; detail = error.localizedDescription; return }
        scanLease?.cancel()
        busy = true
        statusKey = "arranging"
        detail = ""
        preferences.preset = count == 2 ? .columns : .grid
        if !preferences.selectedApps.contains("com.apple.Terminal") { preferences.selectedApps.append("com.apple.Terminal") }
        let usable = screen.visibleFrame
        let frame = CGRect(x: usable.minX, y: primary.frame.maxY - usable.maxY, width: usable.width, height: usable.height)
        let frames = preferences.preset.rectangles(in: frame, gap: preferences.gap)
        let steps = max(4, preferences.zoomSteps)
        Task {
            do {
                let numbers = try await Task.detached { try QuickTerminalLauncher.open(frames: frames, zoomSteps: steps) }.value
                guard numbers.count == count else { throw NSError(domain: "QuickTerminal", code: 3) }
                let processes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").map {
                    ManagedProcess(id: "com.apple.Terminal", pid: $0.processIdentifier, launched: $0.launchDate?.timeIntervalSince1970 ?? 0)
                }
                try await coordinator.adoptQuickWindows(numbers: numbers, processes: processes, zoomSteps: steps)
                statusKey = "arranged"
            } catch {
                statusKey = "error"
                detail = error.localizedDescription
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            busy = false
        }
    }

    func applyLayout() {
        refreshPermissions()
        updateBackground(force: true)
    }
    func updateBackground(force: Bool = false) {
        if scanning {
            if force { requestedForce = true; statusKey = "arranging" }
            return
        }
        // Always refresh TCC before checking setup state. Previously a failed
        // check during launch could leave the interface stuck forever.
        refreshPermissions()
        guard !busy && preferences.completedWelcome else { return }
        guard trusted else { backgroundKey = "permissionNeeded"; if force { statusKey = "permissionNeeded" }; return }
        guard !preferences.selectedApps.isEmpty else { backgroundKey = "noApps"; if force { statusKey = "noApps" }; return }
        let processes = preferences.selectedApps.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).map {
                ManagedProcess(id: id, pid: $0.processIdentifier, launched: $0.launchDate?.timeIntervalSince1970 ?? 0)
            }
        }
        guard let primary = NSScreen.screens.first else { return }
        let screens = NSScreen.screens.map { screen in
            func converted(_ frame: CGRect) -> CGRect {
                CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            }
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return ScreenGeometry(id: number?.stringValue ?? screen.localizedName, frame: converted(screen.frame),
                                  usable: converted(screen.visibleFrame))
        }
        scanning = true
        if force { busy = true; statusKey = "arranging"; detail = "" }
        let options = preferences
        let lease = AutomationLease()
        scanLease = lease
        Task {
            let report = await coordinator.refresh(processes: processes, screens: screens,
                                                  preferences: options, force: force, lease: lease)
            observedWindows = report.windows
            pendingZoom = report.pendingZoom
            pathAccessIssue = report.pathAccessIssue
            canUndo = report.canUndo
            backgroundKey = preferences.automatic ? "autoActive" : "autoPaused"
            if report.failed > 0 {
                statusKey = "partial"
            } else if force {
                statusKey = report.failed > 0 ? "partial" : report.windows.isEmpty ? "noWindows" : "arranged"
            } else if report.moved > 0 {
                statusKey = "arranged"
            }
            if let error = report.ledgerError {
                statusKey = "error"
                detail = error
                preferences.automatic = false
                backgroundKey = "autoPaused"
            }
            scanning = false
            if force { busy = false }
            if requestedForce {
                requestedForce = false
                updateBackground(force: true)
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { statusKey = "error"; detail = error.localizedDescription }
    }
    func openMissionControlSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
    func retryDirectories() {
        Task {
            await coordinator.retryDirectories()
            updateBackground()
        }
    }
    func focusWindow(_ id: String) {
        showOverview = false
        Task { await coordinator.focus(id: id) }
    }
    func changePrompt(install: Bool) {
        do {
            try PromptConfiguration.update(file: shellFile,
                backupDirectory: store.directory.appendingPathComponent("Shell Backups"), install: install)
            refresh(); detail = ""
            statusKey = install ? "newTerminal" : "promptRemoved"
        } catch { statusKey = "error"; detail = error.localizedDescription }
    }
    func undoLayout() {
        guard AXIsProcessTrusted() else { statusKey = "permissionNeeded"; return }
        preferences.automatic = false
        backgroundKey = "autoPaused"
        busy = true
        Task {
            let failed = await coordinator.restore()
            if failed == 0 { canUndo = false }
            statusKey = failed == 0 ? "restored" : "partial"
            busy = false
        }
    }
    func factoryReset() {
        scanLease?.cancel()
        do {
            if monitoringEnabled && SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            try PromptConfiguration.update(file: shellFile,
                backupDirectory: store.directory.appendingPathComponent("Shell Backups"), install: false)
            try store.save(Preferences())
        } catch { statusKey = "error"; detail = error.localizedDescription; return }
        preferences = Preferences()
        loginEnabled = false
        promptInstalled = false; statusKey = "resetDone"; detail = ""
        showWelcome = true
    }
}

struct BackgroundMenu: View {
    @EnvironmentObject private var model: LayoutModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Terminal Layout")
        Text(model.t(model.trusted ? (model.preferences.automatic ? "autoActive" : "autoPaused") : "permissionNeeded"))
        Divider()
        Button(model.t("newFourTerminals")) { model.openTerminals(count: 4) }.disabled(model.busy)
        Button(model.t("newTwoTerminals")) { model.openTerminals(count: 2) }.disabled(model.busy)
        if !model.detail.isEmpty { Text(model.detail) }
        Divider()
        Button(model.t("settings")) { openSettings() }
        Toggle(model.t("automatic"), isOn: $model.preferences.automatic)
        Button(model.t("arrange")) { model.applyLayout() }.disabled(model.busy)
        Button(model.t("folderOverview")) {
            openSettings()
            if model.preferences.completedWelcome {
                model.preferences.groupByDirectory = true
                model.showOverview = true
                model.updateBackground()
            }
        }
        Divider()
        Button(model.t("quit")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
    private func openSettings() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LayoutModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.trusted { permissionBanner }
                    automationCard
                    layoutCard
                    appsCard
                    folderCard
                    promptCard
                }
                .padding(28)
                .disabled(model.busy)
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .frame(minWidth: 710, minHeight: 640)
        .sheet(isPresented: $model.showWelcome) { WelcomeView().environmentObject(model) }
        .sheet(isPresented: $model.showOverview) { FolderOverview().environmentObject(model) }
        .alert(model.t("resetTitle"), isPresented: $model.showReset) {
            Button(model.t("cancel"), role: .cancel) {}
            Button(model.t("reset"), role: .destructive) { model.factoryReset() }
        } message: { Text(model.t("resetDetail")) }
        .onChange(of: phase) { value in if value == .active { model.refresh() } }
    }
    private var header: some View {
        HStack(spacing: 14) {
            AppMark(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Terminal Layout").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(model.t("tagline")).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(Language.all) { language in
                    Button { model.preferences.language = language.id } label: {
                        if language.id == model.preferences.language { Label(language.name, systemImage: "checkmark") }
                        else { Text(language.name) }
                    }
                }
            } label: {
                Label(Language.all.first { $0.id == model.preferences.language }?.name ?? "English", systemImage: "globe")
            }
            .fixedSize()
            .accessibilityLabel(model.t("language"))
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22)
        .background(.regularMaterial)
    }
    private var permissionBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("permissionTitle")).font(.headline)
                Text(model.t("permissionDetail")).font(.caption).foregroundStyle(.secondary)
                Text(model.t("permissionExact") + "\n" + Bundle.main.bundlePath)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(model.t("openSettings")) { model.openPermissions() }.buttonStyle(.bordered)
                Button(model.t("recheck")) { model.refreshPermissions(); model.applyLayout() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
    private var layoutCard: some View {
        SettingsCard(title: model.t("layout"), subtitle: model.t("layoutDetail")) {
            HStack(spacing: 12) {
                ForEach(LayoutPreset.allCases, id: \.self) { preset in
                    Button { model.preferences.preset = preset } label: {
                        VStack(spacing: 10) {
                            LayoutPreview(preset: preset, selected: model.preferences.preset == preset).frame(height: 65)
                            Text(model.t(preset.rawValue)).font(.subheadline.weight(.medium))
                        }
                        .padding(12).frame(maxWidth: .infinity)
                        .background(model.preferences.preset == preset ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(model.preferences.preset == preset ? Color.accentColor : Color.primary.opacity(0.08),
                                    lineWidth: model.preferences.preset == preset ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.preferences.preset == preset ? .isSelected : [])
                }
            }
            HStack {
                Text(model.t("gap")).font(.subheadline)
                Slider(value: $model.preferences.gap, in: 0...32, step: 1)
                    .accessibilityLabel(model.t("gap")).frame(maxWidth: 260)
                Spacer()
                Text("\(Int(model.preferences.gap)) pt").monospacedDigit().foregroundStyle(.secondary)
            }.padding(.top, 4)
        }
    }
    private var automationCard: some View {
        SettingsCard(title: model.t("background"), subtitle: model.t("backgroundHint")) {
            Toggle(model.t("automatic"), isOn: $model.preferences.automatic)
                .toggleStyle(.switch).help(model.t("automaticHint"))
            HStack(spacing: 8) {
                Circle().fill(model.trusted && model.preferences.automatic ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.t(model.backgroundKey)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Toggle(model.t("enlargeText"), isOn: $model.preferences.enlargeText).toggleStyle(.switch)
                Stepper(value: $model.preferences.zoomSteps, in: 0...8) {
                    Text("\(model.preferences.zoomSteps) × ⌘+").monospacedDigit()
                }
                .fixedSize().disabled(!model.preferences.enlargeText)
                .accessibilityLabel(model.t("enlargeText"))
            }
            Text(model.t("zoomHint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.pendingZoom {
                Label(model.t("zoomPending"), systemImage: "textformat.size")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(model.t("openAtLogin"), isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                .toggleStyle(.switch).help(model.t("loginHint"))
            Label(model.t("startHint"), systemImage: "lightbulb")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var folderCard: some View {
        SettingsCard(title: model.t("folders"), subtitle: model.t("folderHint")) {
            Toggle(model.t("groupFolders"), isOn: $model.preferences.groupByDirectory).toggleStyle(.switch)
            HStack {
                Button(model.t("folderOverview")) {
                    model.showOverview = true
                    model.updateBackground()
                }
                .buttonStyle(.bordered).disabled(!model.preferences.groupByDirectory)
                Spacer()
                Button(model.t("missionSettings")) { model.openMissionControlSettings() }
                    .buttonStyle(.borderless)
            }
            Label(model.t("missionHint"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.pathAccessIssue {
                Text(model.t("pathAccess")).font(.caption).foregroundStyle(.orange)
                HStack {
                    Button(model.t("openSettings")) { model.openAutomationSettings() }
                    Button(model.t("retry")) { model.retryDirectories() }
                }.controlSize(.small)
            }
        }
    }
    private var appsCard: some View {
        SettingsCard(title: model.t("apps"), subtitle: model.t("appsDetail")) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(AppTarget.all) { app in
                    Toggle(isOn: Binding(get: { model.preferences.selectedApps.contains(app.id) },
                                         set: { model.toggle(app.id, enabled: $0) })) {
                        Label(app.name, systemImage: app.symbol).font(.subheadline)
                    }
                    .toggleStyle(.switch).controlSize(.small).padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    private var promptCard: some View {
        SettingsCard(title: model.t("prompt"), subtitle: model.t("promptDetail")) {
            HStack {
                Text("❯").foregroundStyle(.mint)
                Text("ls -la").foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("user@Mac ~").foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 13, design: .monospaced)).padding(16)
            .background(Color(red: 0.075, green: 0.09, blue: 0.12), in: RoundedRectangle(cornerRadius: 10))
            .environment(\.layoutDirection, .leftToRight)
            HStack(spacing: 14) {
                Text(model.t("promptBackup")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(model.t(model.promptInstalled ? "removePrompt" : "installPrompt")) {
                    model.changePrompt(install: !model.promptInstalled)
                }.buttonStyle(.bordered).fixedSize()
            }
            Text(model.t("fontHint")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var resetRow: some View {
        HStack {
            Label(model.t("privacy"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(model.t("reset")) { model.showReset = true }
                .buttonStyle(.borderless).foregroundStyle(.red).font(.caption)
        }.padding(.horizontal, 3)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.trusted ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.t(model.statusKey)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
                Spacer()
                if model.canUndo {
                    Button(model.t("undoLayout")) { model.undoLayout() }.disabled(model.busy)
                }
                Button { model.applyLayout() } label: {
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.t("arrange"))
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command).disabled(model.busy)
            }
            if !model.detail.isEmpty {
                Text(model.detail).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            resetRow
        }
        .padding(.horizontal, 28).padding(.vertical, 18).background(.regularMaterial)
        .disabled(model.busy)
    }
}

struct FolderOverview: View {
    @EnvironmentObject private var model: LayoutModel
    private var groups: [(String, [ManagedWindow])] {
        let terminals = model.observedWindows.filter(\.isTerminal)
        let grouped = Dictionary(grouping: terminals) { $0.directory ?? "" }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.t("folderOverview"), systemImage: "folder").font(.title2.weight(.semibold))
                Spacer()
                Button(model.t("done")) { model.showOverview = false }.keyboardShortcut(.cancelAction)
            }
            Text(model.t("overviewHint")).font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if groups.isEmpty {
                        Text(model.t(model.trusted ? "noWindows" : "permissionNeeded"))
                            .foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    ForEach(groups, id: \.0) { path, windows in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(path.isEmpty ? model.t("unknownFolder") : path)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight)
                            ForEach(windows) { window in
                                Button { model.focusWindow(window.id) } label: {
                                    HStack {
                                        Image(systemName: "terminal")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(window.title.isEmpty ? "Terminal" : window.title).lineLimit(2)
                                            Text(AppTarget.all.first { $0.id == window.app }?.name ?? window.app)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.forward")
                                    }
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Label(model.t("missionHint"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 640, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: model.preferences.language))
        .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: LayoutModel
    var body: some View {
        VStack(spacing: 20) {
            AppMark(size: 70).padding(.top, 12)
            VStack(spacing: 8) {
                Text(model.t("welcome")).font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(model.t("welcomeDetail")).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("chooseLanguage")).font(.subheadline.weight(.medium))
                Picker(model.t("language"), selection: $model.preferences.language) {
                    ForEach(Language.all) { language in Text(language.name).tag(language.id) }
                }
                .labelsHidden().controlSize(.large).frame(maxWidth: .infinity)
            }
            .padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            Button {
                model.preferences.completedWelcome = true
                model.showWelcome = false
            } label: {
                Text(model.t("continue")).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            Text(model.t("privacy")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(36).frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .environment(\.locale, Locale(identifier: model.preferences.language))
        .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
        .interactiveDismissDisabled()
    }
}

struct AppMark: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "rectangle.split.2x2").font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct LayoutPreview: View {
    let preset: LayoutPreset
    let selected: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04))
                ForEach(Array(preset.rectangles(in: CGRect(origin: .zero, size: proxy.size), gap: 4).enumerated()),
                        id: \.offset) { index, rect in
                    RoundedRectangle(cornerRadius: 3)
                        .fill((selected ? Color.accentColor : Color.secondary).opacity(0.55 - Double(index) * 0.08))
                        .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight).accessibilityHidden(true)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06)))
    }
}
