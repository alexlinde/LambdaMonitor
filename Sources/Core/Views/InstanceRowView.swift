import SwiftUI
import AppKit

public struct InstanceRowView: View {
    public let instance: OfferedInstanceType
    public var apiService: LambdaAPIService
    public var compact: Bool = false
    @Environment(\.openWindow) private var openWindow

    public init(instance: OfferedInstanceType, apiService: LambdaAPIService, compact: Bool = false) {
        self.instance = instance
        self.apiService = apiService
        self.compact = compact
    }

    private var isWatched: Bool {
        apiService.isWatched(instance.instanceType.name)
    }

    private var specsTooltip: String {
        let s = instance.instanceType.specs
        return "\(instance.instanceType.description)\n\(s.vcpus) vCPUs · \(s.memoryGib) GB RAM · \(s.storageGib) GB Storage"
    }

    private var regionsText: String {
        instance.regionsWithCapacityAvailable.map(\.description).joined(separator: " · ")
    }

    private var isAutoLaunch: Bool {
        apiService.isAutoLaunch(instance.instanceType.name)
    }

    private var accessibilityDescription: String {
        let name = instance.instanceType.description
        let price = instance.instanceType.formattedPrice
        if instance.isAvailable {
            let regions = instance.regionsWithCapacityAvailable.map(\.description).joined(separator: ", ")
            return "\(name), \(price), available in \(regions)"
        } else {
            let watched = isWatched ? ", watching" : ""
            let auto = isAutoLaunch ? ", auto-launch enabled" : ""
            return "\(name), \(price), unavailable\(watched)\(auto)"
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            leadingIcon

            if isWatched && !compact {
                watchedContent
            } else if instance.isAvailable && !compact {
                expandedContent
            } else {
                compactContent
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .opacity(instance.isAvailable || isWatched ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("instance-row-\(instance.instanceType.name)")
    }

    private var watchedContent: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.instanceType.description)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(specsTooltip)

                if instance.isAvailable {
                    Text(regionsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(instance.instanceType.formattedPrice)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if instance.isAvailable {
                launchControl
            } else {
                autoLaunchToggle
            }
        }
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.instanceType.description)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(specsTooltip)

                Text(regionsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(instance.instanceType.formattedPrice)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            launchControl
        }
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            Text(instance.instanceType.description)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(specsTooltip)

            Spacer(minLength: 4)

            Text(instance.instanceType.formattedPrice)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        Button {
            apiService.toggleWatch(for: instance.instanceType.name)
        } label: {
            Image(systemName: isWatched ? "bell.fill" : "bell")
                .font(.caption2)
                .foregroundStyle(isWatched ? .orange : .secondary)
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help(isWatched ? "Stop watching" : "Watch for availability")
        .accessibilityLabel(isWatched ? "Stop watching" : "Watch for availability")
        .accessibilityIdentifier("watch-toggle-\(instance.instanceType.name)")
    }

    @ViewBuilder
    private var launchControl: some View {
        Button("Launch") {
            launchOrShowDialog()
        }
        .font(.caption2)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(!instance.isAvailable || !apiService.launchingTypeNames.isEmpty)
        .help(instance.isAvailable ? "Launch instance" : "Unavailable")
        .accessibilityIdentifier("launch-button-\(instance.instanceType.name)")
    }

    /// Always present the launch dialog so the user can pick the SSH key and
    /// image (the dialog preselects the last-used values). The dialog lives in
    /// a dedicated Window, not an in-popover sheet — see DIALOG.md.
    private func launchOrShowDialog() {
        guard !apiService.sshKeys.isEmpty else {
            openSettingsWindow()
            return
        }
        apiService.pendingLaunch = instance
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "launch")
    }

    /// Enabling auto-launch opens the launch dialog so the user can choose the
    /// SSH key + image to use when the instance later becomes available.
    private func beginAutoLaunchConfig() {
        guard !apiService.sshKeys.isEmpty else {
            openSettingsWindow()
            return
        }
        apiService.pendingAutoLaunchConfig = instance
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "launch")
    }

    private var autoLaunchToggle: some View {
        Toggle(isOn: Binding(
            get: { isAutoLaunch },
            set: { newValue in
                if newValue {
                    beginAutoLaunchConfig()
                } else {
                    apiService.toggleAutoLaunch(for: instance.instanceType.name)
                }
            }
        )) {
            Text("Auto")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Automatically launch when available")
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if instance.isAvailable {
            Button {
                launchOrShowDialog()
            } label: {
                Label("Launch…", systemImage: "play.fill")
            }
        }

        Button {
            apiService.toggleWatch(for: instance.instanceType.name)
        } label: {
            if isWatched {
                Label("Stop Watching", systemImage: "bell.slash")
            } else {
                Label("Watch", systemImage: "bell")
            }
        }

        if isWatched {
            Button {
                if isAutoLaunch {
                    apiService.toggleAutoLaunch(for: instance.instanceType.name)
                } else {
                    beginAutoLaunchConfig()
                }
            } label: {
                if isAutoLaunch {
                    Label("Disable Auto-launch", systemImage: "bolt.slash")
                } else {
                    Label("Enable Auto-launch", systemImage: "bolt")
                }
            }
        }
    }
}

// MARK: - Launch window
//
// Hosted as a dedicated `Window` scene (see `LambdaMonitorApp`), NOT a
// `.sheet` inside the `MenuBarExtra` popover. A sheet presented inside the
// menu-bar panel is torn down when the panel resigns key (which a button
// click triggers), dropping the action and hiding the spinner. A real window
// is stable. See DIALOG.md for the full rationale.
//
// The window renders from `LambdaAPIService` state:
//   - `activeLaunchProgress != nil` -> spinner
//   - `pendingLaunch != nil`        -> region/SSH configuration form
//   - both nil                      -> operation finished, dismiss self

public struct LaunchWindowView: View {
    public var apiService: LambdaAPIService
    @Environment(\.dismiss) private var dismiss

    public init(apiService: LambdaAPIService) {
        self.apiService = apiService
    }

    private var isFinished: Bool {
        apiService.pendingLaunch == nil
            && apiService.pendingAutoLaunchConfig == nil
            && apiService.activeLaunchProgress == nil
    }

    public var body: some View {
        Group {
            // The configuration form stays mounted for the whole launch — it
            // shows its progress spinner inline once the request starts — so
            // the user sees a single launch dialog, not a form followed by a
            // separate spinner window.
            if let instance = apiService.pendingLaunch {
                LaunchConfigurationForm(instance: instance, apiService: apiService, mode: .launch)
            } else if let instance = apiService.pendingAutoLaunchConfig {
                LaunchConfigurationForm(instance: instance, apiService: apiService, mode: .autoLaunch)
            } else if let progress = apiService.activeLaunchProgress {
                // Fallback for any launch not driven by the dialog (e.g. a
                // direct call); the dialog path clears `pendingLaunch` last.
                LaunchInProgressView(progress: progress)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onChange(of: isFinished) { _, finished in
            if finished { dismiss() }
        }
    }
}

private struct LaunchConfigurationForm: View {
    enum Mode {
        /// Configure and launch an available instance right now.
        case launch
        /// Configure the SSH key + image to use when a watched type later
        /// auto-launches; confirming stores the choice instead of launching.
        case autoLaunch
    }

    let instance: OfferedInstanceType
    var apiService: LambdaAPIService
    let mode: Mode

    @State private var selectedRegionName: String
    @State private var selectedKeyName: String
    @State private var selectedImageFamily: String

    init(instance: OfferedInstanceType, apiService: LambdaAPIService, mode: Mode) {
        self.instance = instance
        self.apiService = apiService
        self.mode = mode

        let regions = instance.regionsWithCapacityAvailable
        _selectedRegionName = State(initialValue: regions.first?.name ?? "")

        // Preselect the last-used SSH key when it still exists, otherwise the
        // first available key.
        let keys = apiService.sshKeys
        let storedKey = apiService.selectedSSHKeyName
        let initialKey: String
        if !storedKey.isEmpty, keys.contains(where: { $0.name == storedKey }) {
            initialKey = storedKey
        } else {
            initialKey = keys.first?.name ?? ""
        }
        _selectedKeyName = State(initialValue: initialKey)

        // Preselect the last-used image family when it still exists; "" maps to
        // the default Lambda Stack image.
        let storedImage = apiService.selectedImageFamily
        let initialImage = (storedImage.isEmpty || apiService.imageFamilies.contains(storedImage))
            ? storedImage : ""
        _selectedImageFamily = State(initialValue: initialImage)
    }

    private var selectedRegionDescription: String {
        instance.regionsWithCapacityAvailable
            .first { $0.name == selectedRegionName }?
            .description ?? selectedRegionName
    }

    private var title: String {
        switch mode {
        case .launch: return "Launch \(instance.instanceType.description)"
        case .autoLaunch: return "Auto-launch \(instance.instanceType.description)"
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .launch: return "Launch"
        case .autoLaunch: return "Enable Auto-launch"
        }
    }

    private var confirmDisabled: Bool {
        if selectedKeyName.isEmpty { return true }
        // The region picker only matters for an immediate launch; an
        // auto-launch picks its region when capacity appears.
        return mode == .launch && selectedRegionName.isEmpty
    }

    /// True once this instance's launch request is in flight, so the dialog
    /// swaps its action buttons for an inline spinner instead of opening a
    /// separate progress window.
    private var isLaunching: Bool {
        apiService.activeLaunchProgress?.typeName == instance.instanceType.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Headline row. While launching, the spinner + "Launching…" take
            // the title's place, matching the terminate dialog's size and
            // placement (regular spinner, headline font, same line).
            HStack(spacing: 12) {
                if isLaunching {
                    ProgressView()
                        .controlSize(.regular)
                }
                Text(isLaunching ? "Launching…" : title)
                    .font(.headline)
                    .accessibilityIdentifier(isLaunching ? "launch-progress-title" : "launch-sheet-title")
            }
            .frame(maxWidth: .infinity, alignment: isLaunching ? .center : .leading)

            if mode == .autoLaunch {
                Text("These settings will be used when this instance type becomes available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                LabeledContent("Price") {
                    Text(instance.instanceType.formattedPrice)
                }
                .accessibilityIdentifier("launch-sheet-price")

                if mode == .launch && instance.regionsWithCapacityAvailable.count > 1 {
                    Picker("Region", selection: $selectedRegionName) {
                        ForEach(instance.regionsWithCapacityAvailable) { region in
                            Text(region.description).tag(region.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("launch-sheet-region")
                }

                // Always shown as a dropdown, even with a single option, so the
                // active SSH key is explicit at launch time.
                Picker("SSH Key", selection: $selectedKeyName) {
                    ForEach(apiService.sshKeys) { key in
                        Text(key.name).tag(key.name)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("launch-sheet-ssh-key")

                // Always shown as a dropdown, even with a single option.
                Picker("Image", selection: $selectedImageFamily) {
                    Text("Lambda Stack (latest)").tag("")
                    ForEach(apiService.imageFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("launch-sheet-image")
            }
            // Columns style (not grouped): grouped forms are backed by a
            // scroll view that collapses to zero height in a content-sized
            // window, leaving the pickers cramped and unhittable.
            .formStyle(.columns)
            .frame(maxWidth: .infinity)
            .disabled(isLaunching)

            if !isLaunching {
                HStack {
                    Button("Cancel") { cancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("launch-sheet-cancel")
                    Spacer()
                    Button(confirmTitle) { confirm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(confirmDisabled)
                        .accessibilityIdentifier("launch-sheet-confirm")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 300)
        // No `.accessibilityIdentifier` at the root: SwiftUI propagates a root
        // identifier down to descendants and overrides the per-control
        // identifiers (`launch-sheet-confirm`, etc.) tests need to query.
    }

    private func cancel() {
        switch mode {
        case .launch: apiService.pendingLaunch = nil
        case .autoLaunch: apiService.pendingAutoLaunchConfig = nil
        }
    }

    private func confirm() {
        switch mode {
        case .launch:
            // Persist the choices as the new last-used values so the next
            // dialog preselects them.
            if !selectedKeyName.isEmpty {
                apiService.selectedSSHKeyName = selectedKeyName
            }
            apiService.selectedImageFamily = selectedImageFamily
            // Keep `pendingLaunch` set so this same dialog stays mounted and
            // shows its spinner inline; the service clears it when the launch
            // finishes, which dismisses the window. Pass the picked SSH key and
            // image explicitly so the dialog's selection — not just the global
            // last-used value — drives this launch.
            apiService.launchInstance(
                typeName: instance.instanceType.name,
                regionName: selectedRegionName,
                instanceDescription: instance.instanceType.description,
                regionDescription: selectedRegionDescription,
                sshKeyName: selectedKeyName,
                imageFamily: selectedImageFamily
            )

        case .autoLaunch:
            apiService.configureAutoLaunch(
                typeName: instance.instanceType.name,
                sshKeyName: selectedKeyName,
                imageFamily: selectedImageFamily
            )
            apiService.pendingAutoLaunchConfig = nil
        }
    }
}

// MARK: - Previews

#Preview("Available (expanded)") {
    let service = PreviewService.populated()
    InstanceRowView(instance: MockData.h100x1Available, apiService: service)
        .padding()
}

#Preview("Unavailable (compact)") {
    let service = PreviewService.populated()
    InstanceRowView(instance: MockData.a100x1Unavailable, apiService: service, compact: true)
        .padding()
}

#Preview("Watched - Available") {
    let service = PreviewService.populated()
    InstanceRowView(instance: MockData.h100x1Available, apiService: service)
        .padding()
}

#Preview("Watched - Unavailable") {
    let service = PreviewService.populated()
    let instance = MockData.h200x1Unavailable
    service.watchedTypes.insert(instance.instanceType.name)
    return InstanceRowView(instance: instance, apiService: service)
        .padding()
}
