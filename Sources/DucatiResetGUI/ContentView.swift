import SwiftUI
import UniformTypeIdentifiers
import DucatiResetKit

struct ContentView: View {
    @ObservedObject var vm: ResetViewModel
    @State private var showImporter = false
    @State private var showResetConfirm = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                TabView {
                    controls
                        .padding(14)
                        .tabItem { Label("Service", systemImage: "wrench.and.screwdriver") }
                    liveTab
                        .padding(14)
                        .tabItem { Label("Live Data", systemImage: "gauge.with.dots.needle.bottom.50percent") }
                }
                .frame(width: 380)
                Divider()
                logPane
                    .padding(14)
            }
            Divider()
            footer
        }
        .onAppear { vm.refreshPorts() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .log, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first { vm.importCapture(u) }
        }
        .alert("Reset the service indicator?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Service", role: .destructive) { vm.serviceReset() }
        } message: {
            Text("This writes to the dashboard ECU (7E3) using the standard annual-service routine, then reads the records back to verify.\n\nMake sure the bike's ignition is ON and the engine is OFF. Use at your own risk.")
        }
    }

    // MARK: footer (disclaimer)

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Use at your own risk. The author takes no responsibility for any damage. Not affiliated with Ducati.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("Created by V-twin Fanatics")
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Moto Service Tool").font(.headline)
                Text("for Panigale V2 · ELM327 · \(vm.connected ? "connected" : "offline")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(vm.connected ? .green : .secondary).frame(width: 9, height: 9)
                if !vm.voltage.isEmpty { Text(vm.voltage).font(.caption.monospaced()) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionCard
                connectivityCard
                serviceResetCard
                advancedSection
                if vm.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    // MARK: connection

    private var connectionCard: some View {
        group("Connection") {
            HStack {
                Picker("Port", selection: $vm.selectedPort) {
                    ForEach(vm.ports, id: \.self) { Text(short($0)).tag($0) }
                    if vm.ports.isEmpty { Text("— none —").tag("") }
                }
                Button { vm.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan serial ports")
            }
            HStack {
                if vm.connected {
                    Button("Disconnect") { vm.disconnect() }
                } else {
                    Button("Connect") { vm.connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(vm.selectedPort.isEmpty || vm.busy)
                }
                Button("Refresh status") { vm.refreshConnectivity() }
                    .disabled(!vm.connected || vm.busy)
            }
        }
    }

    // MARK: connectivity

    private var connectivityCard: some View {
        group("Connectivity") {
            statusRow("Adapter", vm.connected,
                      vm.connected ? (vm.adapterInfo.isEmpty ? "connected" : vm.adapterInfo) : "not connected")
            statusRow("Battery", vm.voltageValue >= 11.5,
                      vm.voltage.isEmpty ? "—" : vm.voltage,
                      warn: vm.voltageValue > 0 && vm.voltageValue < 11.5)
            statusRow("Engine ECU (7E0)", vm.engineReachable,
                      vm.engineReachable ? "responding" : "no response")
            statusRow("Dashboard ECU (7E3)", vm.dashReachable,
                      vm.dashReachable ? "responding" : "asleep / no response")
        }
    }

    private func statusRow(_ label: String, _ ok: Bool, _ detail: String, warn: Bool = false) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(warn ? Color.orange : (ok ? Color.green : Color.secondary.opacity(0.5)))
                .frame(width: 10, height: 10)
            Text(label).font(.callout)
            Spacer()
            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: service reset (the main feature)

    private var serviceResetCard: some View {
        group("Service Reset") {
            Text("Resets the service indicator on the dashboard ECU, then verifies the change.")
                .font(.caption).foregroundStyle(.secondary)

            // Model / profile selector
            Picker("Model", selection: $vm.selectedProfileID) {
                ForEach(vm.profiles) { Text($0.name).tag($0.id) }
                Text("Custom…").tag("custom")
            }
            if vm.isCustomProfile {
                HStack {
                    Text("ECU").font(.caption)
                    TextField("7E3", text: $vm.customHeaderHex).frame(width: 60).textFieldStyle(.roundedBorder)
                    Text("Routine").font(.caption)
                    TextField("09", text: $vm.customRoutineHex).frame(width: 50).textFieldStyle(.roundedBorder)
                }
            }
            if !vm.effectiveProfile.validated {
                Label("Experimental — unverified for this model. It self-verifies and won't change anything if the routine isn't accepted.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }

            Button {
                showResetConfirm = true
            } label: {
                HStack {
                    if vm.resetting { ProgressView().controlSize(.small) }
                    Image(systemName: "checkmark.seal.fill")
                    Text(vm.resetting ? "Resetting…" : "Reset Service Indicator")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!vm.connected || vm.busy || !vm.dashReachable)

            if !vm.connected {
                hint("Connect the adapter first.")
            } else if !vm.dashReachable {
                hint("Dashboard ECU not responding — ignition ON (engine off), then “Refresh status”.")
            }

            if let r = vm.lastReset { resetResultView(r) }
        }
    }

    @ViewBuilder
    private func resetResultView(_ r: ServiceResetResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.success ? .green : .orange)
                Text(r.success ? "Reset confirmed" : "Check result")
                    .fontWeight(.semibold)
            }
            ackBadge("routine started (0x71)", r.routineStarted)
            ackBadge("routine completed (0x72)", r.routineStopped)
            ackBadge("records changed", r.recordsChanged)
            Text("record 91: \(r.before91.hexCompact) → \(r.after91.hexCompact)")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text("record 93: \(r.before93.hexCompact) → \(r.after93.hexCompact)")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            if r.success {
                Text("✅ Cycle the ignition (OFF 15 s, ON) to confirm on the dash.")
                    .font(.caption2).foregroundStyle(.green)
            }
        }
    }

    private func ackBadge(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.caption)
            Text(label).font(.caption)
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: advanced (capture / replay / manual)

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                group("Diagnostics") {
                    HStack {
                        Button("Scan ECUs") { vm.scan() }.disabled(!vm.connected || vm.busy)
                        Picker("Protocol", selection: $vm.protocolCode) {
                            Text("6 · HS-CAN").tag("6"); Text("7 · 29-bit").tag("7"); Text("0 · auto").tag("0")
                        }.labelsHidden().frame(width: 120)
                    }
                }
                group("Learn a reset (capture from MelcoDiag / dealer tool)") {
                    Text("Capture an unknown reset once, then replay it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(vm.capturing ? "Stop Capture" : "Start Capture") { vm.toggleCapture() }
                        .tint(vm.capturing ? .orange : .accentColor)
                    if !vm.virtualPort.isEmpty {
                        Text("MelcoDiag port:\n\(vm.virtualPort)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Import capture log…") { showImporter = true }
                }
                group("Manual command script") {
                    TextEditor(text: $vm.resetScript)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Button("Dry run") { vm.runReset(dryRun: true) }.disabled(!vm.connected || vm.busy)
                        Button("Send") { vm.runReset(dryRun: false) }.tint(.red).disabled(!vm.connected || vm.busy)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced").font(.subheadline.weight(.semibold))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: live data tab

    private var liveTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !vm.connected {
                    group("Live Data") {
                        hint("Connect on the Service tab first, ignition ON.")
                    }
                }

                group("Vehicle Info") {
                    HStack {
                        Text("VIN").frame(width: 44, alignment: .leading).font(.callout)
                        Text(vm.vin ?? "—").font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                    }
                    Button("Read Vehicle Info") { vm.readVehicleInfo() }
                        .disabled(!vm.connected || vm.busy)
                }

                group("Live Data") {
                    Button {
                        vm.toggleLive()
                    } label: {
                        HStack {
                            Image(systemName: vm.polling ? "stop.fill" : "play.fill")
                            Text(vm.polling ? "Stop" : "Start live data")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.polling ? .orange : .accentColor)
                    .disabled(!vm.connected)

                    let d = vm.live
                    metric("RPM", d?.rpm.map { "\($0)" }, "gauge.with.needle")
                    metric("Coolant", d?.coolantC.map { "\($0) °C" }, "thermometer.medium")
                    metric("Intake air", d?.intakeC.map { "\($0) °C" }, "wind")
                    metric("Throttle", d?.throttlePct.map { "\($0) %" }, "dial.medium")
                    metric("Engine load", d?.loadPct.map { "\($0) %" }, "engine.combustion")
                    metric("Speed", d?.speedKmh.map { "\($0) km/h" }, "speedometer")
                    metric("Battery", d?.batteryV.map { String(format: "%.1f V", $0) }, "bolt.fill")
                }

                group("Fault Codes (DTC)") {
                    Button("Read Fault Codes") { vm.readDTCs() }
                        .disabled(!vm.connected || vm.busy)
                    if vm.dtcRead {
                        if vm.dtcs.isEmpty {
                            Label("No stored fault codes", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        } else {
                            ForEach(vm.dtcs, id: \.self) { code in
                                Label(code, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.callout.monospaced())
                            }
                        }
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String?, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(label).font(.callout)
            Spacer()
            Text(value ?? "—")
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    // MARK: log

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Text(vm.status).font(.caption).foregroundStyle(.secondary)
                Button { vm.log = "" } label: { Image(systemName: "trash") }
                    .help("Clear log")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.log.isEmpty ? "—" : vm.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logEnd")
                }
                .onChange(of: vm.log) { _ in proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    // MARK: helpers

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func short(_ path: String) -> String {
        path.replacingOccurrences(of: "/dev/cu.", with: "").replacingOccurrences(of: "/dev/", with: "")
    }
}

extension UTType {
    static let log = UTType(filenameExtension: "log") ?? .plainText
}
