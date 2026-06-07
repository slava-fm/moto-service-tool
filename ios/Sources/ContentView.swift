import SwiftUI

struct ContentView: View {
    @ObservedObject var vm: BikeViewModel
    @State private var showResetConfirm = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { serviceTab }
                .tabItem { Label("Service", systemImage: "wrench.and.screwdriver") }
                .tag(0)
            NavigationStack { liveTab }
                .tabItem { Label("Live Data", systemImage: "gauge.with.dots.needle.bottom.50percent") }
                .tag(1)
        }
        .alert("Reset the service indicator?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Service", role: .destructive) { vm.serviceReset() }
        } message: {
            Text("This writes to the dashboard ECU using the \(vm.effectiveProfile.name) routine, then reads back to verify.\n\nIgnition ON, engine OFF. Use at your own risk.")
        }
    }

    // MARK: Service tab

    private var serviceTab: some View {
        Form {
            Section("Connection") {
                Button {
                    vm.scanning ? vm.stopScan() : vm.scan()
                } label: {
                    Label(vm.scanning ? "Stop scanning" : "Scan for Bluetooth adapter",
                          systemImage: vm.scanning ? "stop.circle" : "dot.radiowaves.left.and.right")
                }
                ForEach(vm.devices) { d in
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(d.name)
                        Spacer()
                        if vm.selectedDeviceID == d.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.selectedDeviceID = d.id }
                }
                HStack {
                    if vm.connected {
                        Button("Disconnect", role: .destructive) { vm.disconnect() }
                    } else {
                        Button("Connect") { vm.connect() }
                            .disabled(vm.selectedDeviceID == nil || vm.busy)
                    }
                    Spacer()
                    if vm.busy { ProgressView() }
                }
            }

            Section("Connectivity") {
                statusRow("Adapter", vm.connected, vm.connected ? (vm.adapterInfo.isEmpty ? "connected" : vm.adapterInfo) : "not connected")
                statusRow("Battery", vm.voltageValue >= 11.5, vm.voltage.isEmpty ? "—" : vm.voltage, warn: vm.voltageValue > 0 && vm.voltageValue < 11.5)
                statusRow("Engine ECU (7E0)", vm.engineReachable, vm.engineReachable ? "responding" : "no response")
                statusRow("Dashboard ECU (7E3)", vm.dashReachable, vm.dashReachable ? "responding" : "asleep / no response")
                if vm.connected { Button("Refresh status") { vm.refreshConnectivity() }.disabled(vm.busy) }
            }

            Section("Service Reset") {
                Picker("Model", selection: $vm.selectedProfileID) {
                    ForEach(vm.profiles) { Text($0.name).tag($0.id) }
                    Text("Custom…").tag("custom")
                }
                if vm.isCustom {
                    HStack {
                        TextField("ECU 7E3", text: $vm.customHeaderHex).textInputAutocapitalization(.characters)
                        TextField("Routine 09", text: $vm.customRoutineHex).textInputAutocapitalization(.characters)
                    }.font(.body.monospaced())
                }
                if !vm.effectiveProfile.validated {
                    Label("Experimental — unverified for this model. Self-verifies; changes nothing if the routine isn't accepted.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    showResetConfirm = true
                } label: {
                    HStack {
                        if vm.resetting { ProgressView() }
                        Image(systemName: "checkmark.seal.fill")
                        Text(vm.resetting ? "Resetting…" : "Reset Service Indicator").bold()
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(!vm.connected || vm.busy || !vm.dashReachable)
                if let r = vm.lastReset { resetResult(r) }
            }

            disclaimerSection
        }
        .navigationTitle("Moto Service Tool")
    }

    @ViewBuilder
    private func resetResult(_ r: ServiceResetResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(r.success ? "Reset confirmed" : "Check result",
                  systemImage: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.success ? .green : .orange).bold()
            Text("routine started: \(r.routineStarted ? "✓" : "✗")  ·  completed: \(r.routineStopped ? "✓" : "✗")  ·  records changed: \(r.recordsChanged ? "✓" : "✗")")
                .font(.footnote).foregroundStyle(.secondary)
            if r.success { Text("Cycle the ignition (OFF 15s, ON) to confirm.").font(.footnote).foregroundStyle(.green) }
        }
    }

    // MARK: Live tab

    private var liveTab: some View {
        Form {
            Section("Vehicle Info") {
                HStack { Text("VIN"); Spacer(); Text(vm.vin ?? "—").font(.body.monospaced()).textSelection(.enabled) }
                Button("Read Vehicle Info") { vm.readVehicleInfo() }.disabled(!vm.connected || vm.busy)
            }
            Section("Live Data") {
                Button {
                    vm.toggleLive()
                } label: {
                    Label(vm.polling ? "Stop" : "Start live data", systemImage: vm.polling ? "stop.fill" : "play.fill")
                }.disabled(!vm.connected)
                metric("RPM", vm.live?.rpm.map { "\($0)" })
                metric("Coolant", vm.live?.coolantC.map { "\($0) °C" })
                metric("Intake air", vm.live?.intakeC.map { "\($0) °C" })
                metric("Throttle", vm.live?.throttlePct.map { "\($0) %" })
                metric("Engine load", vm.live?.loadPct.map { "\($0) %" })
                metric("Speed", vm.live?.speedKmh.map { "\($0) km/h" })
                metric("Battery", vm.live?.batteryV.map { String(format: "%.1f V", $0) })
            }
            Section("Fault Codes") {
                Button("Read Fault Codes") { vm.readDTCs() }.disabled(!vm.connected || vm.busy)
                if vm.dtcRead {
                    if vm.dtcs.isEmpty {
                        Label("No stored fault codes", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        ForEach(vm.dtcs, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.body.monospaced()) }
                    }
                }
            }
            disclaimerSection
        }
        .navigationTitle("Live Data")
    }

    // MARK: helpers

    private var disclaimerSection: some View {
        Section {
            Text("Use at your own risk. The author takes no responsibility for any damage. Not affiliated with Ducati. Created by V-twin Fanatics.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func statusRow(_ label: String, _ ok: Bool, _ detail: String, warn: Bool = false) -> some View {
        HStack {
            Circle().fill(warn ? Color.orange : (ok ? Color.green : Color.gray.opacity(0.5))).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(detail).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, _ value: String?) -> some View {
        HStack { Text(label); Spacer(); Text(value ?? "—").font(.title3.monospacedDigit().weight(.medium)).foregroundStyle(value == nil ? .secondary : .primary) }
    }
}
