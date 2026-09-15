import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var pairing = PairingRecordStore()
    @StateObject private var loop = Stage8FullLoopController()
    @StateObject private var runnerPackage = RunnerPackageStore()
    @StateObject private var tunnel = PikminTunnelManager.shared

    @AppStorage("PikminPilot.RunMode") private var runMode = "5"
    @AppStorage("PikminPilot.CustomRunCount") private var customRunCount = 10
    @AppStorage("PikminPilot.PikminType") private var pikminTypeRaw = PilotPikminType.pink.rawValue
    @AppStorage("PikminPilot.PikminCount") private var pikminCount = 12
    @AppStorage("PikminPilot.CargoMode") private var cargoModeRaw = PilotCargoMode.fruit.rawValue
    @AppStorage("PikminPilot.SpeedMode") private var speedMode = "stable"

    private enum FileImportTarget {
        case pairing
        case runner
    }

    @State private var showFileImporter = false
    @State private var fileImportTarget: FileImportTarget = .pairing
    @State private var status = UserDefaults.standard.string(forKey: Stage8FullLoopController.persistedStatusKey) ?? "尚未執行"
    @State private var busy = false
    @State private var screenshotImage: UIImage?
    @State private var statusCopied = false
    @State private var showDiagnostics = false
    @State private var rsdReady = false
    @State private var pendingStartAfterPairingImport = false

    private var selectedTargetDispatches: Int? {
        switch runMode {
        case "1": return 1
        case "5": return 5
        case "10": return 10
        case "20": return 20
        case "custom": return max(1, customRunCount)
        default: return nil
        }
    }

    private var runGoalLabel: String {
        selectedTargetDispatches.map { "\($0) 顆" } ?? "無限循環"
    }

    private var isFastMode: Bool { speedMode == "fast" }

    private var selectedPikminType: PilotPikminType {
        PilotPikminType(rawValue: pikminTypeRaw) ?? .pink
    }

    private var selectedCargoMode: PilotCargoMode {
        PilotCargoMode(rawValue: cargoModeRaw) ?? .fruit
    }

    private var pikminCountBinding: Binding<Int> {
        Binding(
            get: { max(selectedPikminType.minimumCount, min(12, pikminCount)) },
            set: { pikminCount = max(selectedPikminType.minimumCount, min(12, $0)) }
        )
    }

    private var runSummaryLabel: String {
        "\(runGoalLabel) • \(selectedCargoMode.displayName) • \(selectedPikminType.shortName)×\(max(selectedPikminType.minimumCount, pikminCount)) • \(isFastMode ? "快速" : "穩定")"
    }

    private var progressLabel: String {
        if let target = loop.targetDispatches ?? selectedTargetDispatches {
            return "\(min(loop.completedDispatches, target)) / \(target)"
        }
        return "已完成 \(loop.completedDispatches) 顆"
    }

    private var progressFraction: Double? {
        guard let target = loop.targetDispatches ?? selectedTargetDispatches, target > 0 else { return nil }
        return min(1, Double(loop.completedDispatches) / Double(target))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    runControlCard
                    liveStatusCard

                    if let screenshotImage {
                        screenshotCard(image: screenshotImage)
                    }

                    setupCard
                    diagnosticsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Pikmin Pilot")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                pairing.refresh()
                await tunnel.refresh()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    switch fileImportTarget {
                    case .pairing:
                        do {
                            try pairing.importRecord(from: url)
                            screenshotImage = nil
                            let shouldResumeStart = pendingStartAfterPairingImport
                            pendingStartAfterPairingImport = false
                            if shouldResumeStart {
                                status = "STAGE 11.5.4.6 FIRST SETUP ✅ • Pairing Record saved • continuing START PILOT automatically…"
                                Task { await startStage101Auto() }
                            } else {
                                status = "Pairing Record 已匯入 ✅ • 正在自動 Validate + probe RSD 10.7.0.1:49152…"
                                Task { await validatePairingAndProbeRSD() }
                            }
                        } catch {
                            pendingStartAfterPairingImport = false
                            status = "Pairing Record 匯入失敗：\(error.localizedDescription)"
                        }
                    case .runner:
                        do {
                            try runnerPackage.importIPA(from: url)
                            status = "SIGNED RUNNER OVERRIDE IMPORTED ✅ • START PILOT will prefer override"
                        } catch {
                            status = "Runner IPA 匯入失敗：\(error.localizedDescription)"
                        }
                    }
                case .failure(let error):
                    if fileImportTarget == .pairing { pendingStartAfterPairingImport = false }
                    status = fileImportTarget == .pairing
                        ? "Pairing Record 匯入取消/失敗：\(error.localizedDescription)"
                        : "Runner IPA 匯入失敗：\(error.localizedDescription)"
                }
            }
            }
        }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pikmin Pilot")
                        .font(.title2.bold())
                    Text("Stage 11.5.4.6 • 11.5.3 baseline + Classic CoreDevice Cellular Escape")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                readinessBadge(
                    pairing.pairingURL != nil ? "Pairing ✓" : "Pairing !",
                    ok: pairing.pairingURL != nil
                )
                readinessBadge(tunnel.state == .connected ? "Tunnel ✓" : "Tunnel …", ok: tunnel.state == .connected)
                readinessBadge(rsdReady ? "RSD ✓" : "RSD …", ok: rsdReady)
                readinessBadge("Runner 內建", ok: runnerPackage.runnerURL != nil)
            }

            Text("正常使用只需要 START PILOT。它會自動處理 Integrated Tunnel → RSD → DDI → Runner → automation；Pairing Record 僅在全新安裝且沒有 recovery 時要求選一次。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.green.opacity(0.16), Color.teal.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.green.opacity(0.12), lineWidth: 1)
        )
    }

    private var runControlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Pilot 設定", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text(isFastMode ? "FAST" : "STABLE")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((isFastMode ? Color.orange : Color.green).opacity(0.14), in: Capsule())
                    .foregroundStyle(isFastMode ? Color.orange : Color.green)
            }

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("搬運次數")
                            .fontWeight(.semibold)
                        Text("完成一顆並回列表 = 1 次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("搬運次數", selection: $runMode) {
                        Text("1").tag("1")
                        Text("5").tag("5")
                        Text("10").tag("10")
                        Text("20").tag("20")
                        Text("自訂").tag("custom")
                        Text("∞").tag("infinite")
                    }
                    .labelsHidden()
                    .disabled(loop.isRunning || busy)
                }

                if runMode == "custom" {
                    Stepper(value: $customRunCount, in: 1...100) {
                        HStack {
                            Text("自訂次數")
                            Spacer()
                            Text("\(customRunCount) 顆")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                    .disabled(loop.isRunning || busy)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("搬運目標")
                        .fontWeight(.semibold)
                    Picker("搬運目標", selection: $cargoModeRaw) {
                        ForEach(PilotCargoMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(loop.isRunning || busy)
                    Text(selectedCargoMode == .seedling
                         ? "花苗只接受「某色花苗」文字（必須含「色花苗」）；上方單獨的「花苗」分頁永遠不點。"
                         : selectedCargoMode == .both
                         ? "水果＋花苗模式只接受 OCR 含「色花苗」的盆栽；上方單獨「花苗」分頁永遠排除。"
                         : "沿用已驗證的水果 card-first AVAILABLE 判定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("皮克敏種類")
                        .fontWeight(.semibold)
                    HStack(spacing: 8) {
                        ForEach(PilotPikminType.allCases) { type in
                            pikminTypeButton(type)
                        }
                    }

                    Stepper(value: pikminCountBinding, in: selectedPikminType.minimumCount...12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("每輪 \(selectedPikminType.displayName)皮克敏")
                                    .fontWeight(.semibold)
                                Text("最低 \(selectedPikminType.minimumCount) 隻；每次 Run 固定同一數量")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(max(selectedPikminType.minimumCount, pikminCount)) 隻")
                                .font(.title3.bold())
                                .monospacedDigit()
                                .foregroundStyle(pikminAccentColor(selectedPikminType))
                        }
                    }
                    .disabled(loop.isRunning || busy)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("速度")
                        .fontWeight(.semibold)
                    Picker("速度", selection: $speedMode) {
                        Text("穩定").tag("stable")
                        Text("快速").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    .disabled(loop.isRunning || busy)
                    Text(isFastMode
                         ? "快速模式只縮短已驗證的等待與選取間隔；辨識重試與安全判定仍保留。"
                         : "穩定模式沿用目前已驗證成功的 Stage 8.2.2 節奏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 8) {
                summaryPill(runGoalLabel, icon: "shippingbox")
                summaryPill(selectedCargoMode.displayName, icon: selectedCargoMode == .seedling ? "leaf.arrow.circlepath" : "apple.logo")
                summaryPill("\(selectedPikminType.shortName)×\(max(selectedPikminType.minimumCount, pikminCount))", icon: "leaf.fill")
            }

            if loop.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("進度")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(progressLabel)
                            .font(.headline.monospacedDigit())
                    }
                    if let progressFraction {
                        ProgressView(value: progressFraction)
                            .tint(.green)
                    } else {
                        ProgressView()
                            .tint(.green)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        loop.stopAfterCurrent()
                    } label: {
                        Label("本輪後停止", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(loop.stopAfterCurrentRequested)

                    Button(role: .destructive) {
                        loop.stopNow()
                    } label: {
                        Label("立即停止", systemImage: "xmark.octagon.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("立即停止會阻止新的動作；若「顏色篩選→選取→GO→X」已送進單一 Runner session，該批次可能先完成才停止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await startPilotOneTap() }
                } label: {
                    VStack(spacing: 3) {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 4) }
                            Label(busy ? "準備中…" : "START PILOT", systemImage: "play.fill")
                                .font(.headline)
                        }
                        if !busy {
                            Text(runSummaryLabel)
                                .font(.caption)
                                .opacity(0.9)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(busy)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.04), radius: 12, y: 5)
    }

    private var liveStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("目前狀態", systemImage: loop.isRunning ? "waveform.path.ecg" : "checkmark.circle")
                    .font(.headline)
                Spacer()
                if loop.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(loop.currentPhase)
                .font(.title3.bold())

            HStack {
                Text("已完成")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(loop.completedDispatches) 顆")
                    .font(.headline.monospacedDigit())
            }

            DisclosureGroup("技術紀錄 / COPY LOG") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            copyStatusToClipboard()
                        } label: {
                            Label(statusCopied ? "COPIED" : "COPY LOG", systemImage: statusCopied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text(status)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func screenshotCard(image: UIImage) -> some View {
        DisclosureGroup("最近一次辨識畫面") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var setupCard: some View {
        DisclosureGroup("進階 / 維修（正常使用不用打開）") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Integrated tunnel", value: tunnel.state.rawValue)
                Text(tunnel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("RSD target", value: "10.7.0.1:49152")
                LabeledContent("RSD state", value: rsdReady ? "CONNECTED" : (pairing.pairingURL == nil ? "WAITING FOR PAIRING" : "NOT PROBED"))

                HStack {
                    Button("ENABLE / START INTEGRATED TUNNEL") {
                        Task { await startIntegratedTunnelOnly() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(loop.isRunning || busy)

                    Button("STOP TUNNEL") { tunnel.stop() }
                        .buttonStyle(.bordered)
                        .disabled(loop.isRunning || busy)
                }

                Button("HARD RESTART INTEGRATED TUNNEL") {
                    Task { await restartIntegratedTunnel() }
                }
                .buttonStyle(.bordered)
                .disabled(loop.isRunning || busy)

                Text("START PILOT 會自動啟動 Tunnel、建立 RSD、掛 DDI、確認/安裝 Runner。Pairing Record 只需要首次提供一次；後續正常覆蓋更新會沿用本機副本，11.4.0 另做 best-effort secure recovery。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                LabeledContent("Pairing", value: pairing.status)
                Button("匯入 RPPairing Record") {
                    fileImportTarget = .pairing
                    showFileImporter = true
                }
                    .disabled(loop.isRunning || busy)

                Button("VALIDATE PAIRING") {
                    Task { await validatePairing() }
                }
                .disabled(loop.isRunning || busy || pairing.pairingURL == nil)

                Divider()

                LabeledContent("Runner package", value: runnerPackage.status)
                LabeledContent("Runner source", value: runnerPackage.sourceLabel)
                LabeledContent("Runner signing", value: runnerPackage.provisioningStatus)

                Text("Stage 10.3 的白/粉紅 6–12、紫/岩 2–12 與多目標模式使用同一個 Runner；10.3.1 只修花苗 OCR 安全條件，已安裝的 Stage 10.3 Runner 直接沿用，不需 BAT、不需重新簽。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("INSTALL / UPDATE EMBEDDED RUNNER") {
                    Task { await installAvailableRunner() }
                }
                .disabled(loop.isRunning || busy || pairing.pairingURL == nil || runnerPackage.runnerURL == nil)

                Button("IMPORT SIGNED RUNNER OVERRIDE") {
                    fileImportTarget = .runner
                    showFileImporter = true
                }
                .disabled(loop.isRunning || busy)

                if runnerPackage.source == .importedOverride {
                    Button("移除 Runner override", role: .destructive) {
                        try? runnerPackage.removeImportedOverride()
                        status = "Runner override 已移除；已回到內建 Runner"
                    }
                    .disabled(loop.isRunning || busy)
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var diagnosticsCard: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(spacing: 10) {
                Button("NO-VPN SELF PROBE • 127.0.0.1 / SELF-IP :62078") {
                    Task { await runNoVPNSelfProbe() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || loop.isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)

                diagnosticButton("CONNECT PHONE-LOCAL RSD") { await connectRSD() }
                diagnosticButton("PHONE-LOCAL → TAKE SCREENSHOT") { await takeScreenshot() }
                diagnosticButton("PROBE PHONE-LOCAL XCTEST SERVICES") { await probeXCTestServices() }
                diagnosticButton("BOOTSTRAP PHONE-LOCAL XCTEST DTX") { await bootstrapXCTestDTX() }
                diagnosticButton("FIND INSTALLED XCTEST RUNNER") { await discoverXCTestRunner() }
                diagnosticButton("PHONE-LOCAL → LAUNCH XCTEST RUNNER") { await launchDiscoveredXCTestRunner() }
                diagnosticButton("PREPARE XCTEST SESSION METADATA") { await prepareXCTestMetadata() }
                diagnosticButton("RUN XCTEST → ACTIVATE + CENTER TAP") { await runXCTestCenterTap() }
                diagnosticButton("STAGE 8.0 → DVT AVAILABLE FRUIT TAP") { await runStage8AvailableFruitTap() }
                diagnosticButton("PHONE-LOCAL → LAUNCH PIKMIN") { await launchPikmin() }

                Button("DEBUG → START LOOP DIRECT") {
                    startStage81Loop()
                }
                .buttonStyle(.bordered)
                .disabled(busy || loop.isRunning || pairing.pairingURL == nil)
            }
            .padding(.top, 8)
        } label: {
            Label("Diagnostics", systemImage: "wrench.and.screwdriver")
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func pikminAccentColor(_ type: PilotPikminType) -> Color {
        switch type {
        case .pink: return .pink
        case .white: return Color(uiColor: .systemGray)
        case .purple: return .purple
        case .rock: return Color(uiColor: .darkGray)
        }
    }

    @ViewBuilder
    private func pikminTypeButton(_ type: PilotPikminType) -> some View {
        let selected = selectedPikminType == type
        Button {
            pikminTypeRaw = type.rawValue
            if pikminCount < type.minimumCount {
                pikminCount = type.minimumCount
            }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(type == .white ? Color.white : pikminAccentColor(type))
                    .overlay(
                        Circle().stroke(type == .white ? Color.gray.opacity(0.6) : Color.clear, lineWidth: 1.5)
                    )
                    .frame(width: 22, height: 22)
                Text(type.shortName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                (selected ? pikminAccentColor(type).opacity(0.16) : Color(uiColor: .tertiarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? pikminAccentColor(type).opacity(0.65) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(loop.isRunning || busy)
    }

    @ViewBuilder
    private func summaryPill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
    }

    @ViewBuilder
    private func readinessBadge(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(ok ? Color.green.opacity(0.13) : Color.orange.opacity(0.13), in: Capsule())
            .foregroundStyle(ok ? Color.green : Color.orange)
    }

    private func diagnosticButton(
        _ title: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button(title) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
        .disabled(busy || loop.isRunning || pairing.pairingURL == nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isBootstrapFailure: Bool {
        let lower = status.lowercased()
        return lower.contains("test runner failed to bootstrap")
            || lower.contains("step=execute-test-plan")
            || lower.contains("archiveStrings=")
    }

    @MainActor
    private func copyStatusToClipboard() {
        UIPasteboard.general.string = status
        statusCopied = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            statusCopied = false
        }
    }

    @MainActor
    private func installAvailableRunner() async {
        guard let pairingURL = pairing.pairingURL,
              let runnerURL = runnerPackage.runnerURL else { return }

        busy = true
        defer { busy = false }
        status = "STAGE 10.3.1 RUNNER BOOTSTRAP • source=\(runnerPackage.sourceLabel) • AFC upload → InstallationProxy install…"

        let engine = IDeviceEngine(pairingPath: pairingURL.path)
        let rsd = await engine.probeRSD()
        guard rsd.ok else {
            status = "STAGE 10.3.1 RUNNER INSTALL FAILED • RSD offline • \(rsd.message)"
            return
        }

        let install = await engine.installXCTestRunnerIPA(localPath: runnerURL.path)
        guard install.ok else {
            status = install.message
            return
        }

        let verify = await engine.discoverXCTestRunner()
        status = verify.ok
            ? "\(install.message) • verify=\(verify.message)"
            : "\(install.message) • POST-INSTALL VERIFY FAILED • \(verify.message)"
    }

    @MainActor
    private func startPilotOneTap() async {
        guard !busy else { return }

        if pairing.pairingURL == nil {
            if pairing.ensureAvailableFromRecoverySources(), pairing.pairingURL != nil {
                status = "STAGE 11.5.4.6 ONE-TAP • Pairing recovered automatically ✅ • continuing…"
                await startStage101Auto()
                return
            }

            pendingStartAfterPairingImport = true
            fileImportTarget = .pairing
            status = "STAGE 11.5.4.6 FIRST SETUP • select the RPPairing Record once; after import START PILOT will continue automatically"
            showFileImporter = true
            return
        }

        await startStage101Auto()
    }

    @MainActor
    private func startStage101Auto() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        status = "STAGE 11.5.4.6 START • \(runSummaryLabel) • integrated tunnel → RSD → DDI preflight → Runner → stable 10.3.1 loop"

        var tunnelNote = "integrated=not-attempted"
        do {
            try await tunnel.ensureStarted(timeoutSeconds: 10.0)
            tunnelNote = "integrated=connected"
            status = "STAGE 11.5.4.6 • integrated tunnel ✅ • probing phone-local RSD…"
        } catch {
            let diag = tunnel.diagnostics(for: error)
            tunnelNote = "integrated=unavailable"
            status = "STAGE 11.5.4.6 • integrated tunnel unavailable (\(diag)) • trying existing external LocalDevVPN path…"
        }

        var activeHost = "10.7.0.1"
        var transportNote = "peer=10.7.0.1:49152"
        var engine = IDeviceEngine(pairingPath: url.path, host: activeHost, port: 49152)
        var rsd = await engine.probeRSD()
        rsdReady = rsd.ok

        // Stage 11.5.4.6: PPCreateTunnel itself now owns the transport decision.
        // It always tries the proven raw RPPairing path first, then (only if a
        // separately bootstrapped classic sidecar exists) tries CoreDeviceProxy.
        // The 11.5.4.3-.5 loopback/interface scans are intentionally retired.
        if rsd.ok {
            if rsd.message.localizedCaseInsensitiveContains("CLASSIC COREDEVICE RSD READY") {
                transportNote = "CLASSIC-COREDEVICE cellular escape"
            } else if rsd.message.localizedCaseInsensitiveContains("CLASSIC SIDECAR READY") {
                transportNote = "peer=10.7.0.1:49152 • classicSidecar=minted"
            } else if rsd.message.localizedCaseInsensitiveContains("classicSidecar=ready") {
                transportNote = "peer=10.7.0.1:49152 • classicSidecar=ready"
            } else if rsd.message.localizedCaseInsensitiveContains("CLASSIC BOOTSTRAP FAILED") {
                transportNote = "peer=10.7.0.1:49152 • classicBootstrap=needs-attention"
            }
        }

        guard rsd.ok else {
            busy = false
            status = "STAGE 11.5.4.6 CLASSIC COREDEVICE CELLULAR ESCAPE • \(tunnelNote) • RSD offline • \(rsd.message)"
            return
        }
        _ = pairing.backupCurrentRecordToKeychain()

        status = "STAGE 11.5.4.6 PREFLIGHT • RSD ✅ • \(transportNote) • checking developer services…"
        var services = await engine.probeXCTestServices()
        if !services.ok {
            status = "STAGE 11.5.4.6 PREFLIGHT • developer services missing after reboot • preparing Personalized DDI 27A5228h…"

            let assets: DeveloperDiskImageStore.Assets
            do {
                assets = try await DeveloperDiskImageStore().ensureAssets { assetProgress in
                    status = assetProgress.statusText
                }
            } catch {
                busy = false
                status = "STAGE 11.5.4.6 FAILED • phase=ddi-assets • \(error.localizedDescription)"
                return
            }

            status = "STAGE 11.5.4.6 DDI • source=\(assets.sourceLabel) • build=\(assets.buildID) • mounting through phone-local RSD…"
            let mount = await engine.mountPersonalizedDDI(
                imagePath: assets.imageURL.path,
                buildManifestPath: assets.buildManifestURL.path,
                trustCachePath: assets.trustCacheURL.path
            )
            guard mount.ok else {
                busy = false
                status = "STAGE 11.5.4.6 FAILED • phase=ddi-mount • \(mount.message)"
                return
            }

            status = "STAGE 11.5.4.6 DDI ✅ • \(mount.message) • rebuilding RSD…"
            let postMountRSD = await engine.probeRSD()
            guard postMountRSD.ok else {
                busy = false
                status = "STAGE 11.5.4.6 FAILED • phase=post-ddi-rsd • \(postMountRSD.message)"
                return
            }

            services = await engine.probeXCTestServices()
            guard services.ok else {
                busy = false
                status = "STAGE 11.5.4.6 FAILED • phase=post-ddi-service-probe • DDI mount returned success but developer services are still absent • \(services.message)"
                return
            }
        }

        status = "STAGE 11.5.4.6 PREFLIGHT ✅ • RSD + DDI developer services ready • \(tunnelNote) • synchronizing XCTest Runner…"
        var runner = await engine.discoverXCTestRunner()

        if runnerPackage.source == .embedded && runnerPackage.isEmbeddedRunnerExpired {
            busy = false
            status = "STAGE 11.5.4.6 RUNNER EXPIRED • embedded provisioning expired • \(runnerPackage.provisioningStatus)"
            return
        }

        // Stage 11.5.3: an installed Runner is not enough. Previous builds only
        // installed when the Runner was missing, so a host update could keep
        // executing an older Runner forever. Synchronize once per host build.
        let hostBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let runnerSyncKey = "PikminPilot.syncedRunnerHostBuild"
        let needsRunnerSync = !runner.ok || UserDefaults.standard.string(forKey: runnerSyncKey) != hostBuild

        if needsRunnerSync {
            guard let package = runnerPackage.runnerURL else {
                busy = false
                status = "STAGE 11.5.4.6 PACKAGING ERROR • embedded signed Runner missing"
                return
            }
            status = "STAGE 11.5.4.6 RUNNER SYNC • hostBuild=\(hostBuild) • source=\(runnerPackage.sourceLabel) • installing/upgrading…"
            let install = await engine.installXCTestRunnerIPA(localPath: package.path)
            guard install.ok else {
                busy = false
                status = "STAGE 11.5.4.6 FAILED • phase=runner-sync • \(install.message)"
                return
            }
            runner = await engine.discoverXCTestRunner()
            guard runner.ok else {
                busy = false
                status = "STAGE 11.5.4.6 FAILED • phase=runner-sync-verify • \(runner.message)"
                return
            }
            UserDefaults.standard.set(hostBuild, forKey: runnerSyncKey)
            status = "STAGE 11.5.4.6 RUNNER SYNC ✅ • hostBuild=\(hostBuild) • verified current embedded Runner"
        } else {
            status = "STAGE 11.5.4.6 RUNNER ✅ • hostBuild=\(hostBuild) • current Runner already synchronized"
        }

        busy = false
        loop.start(
            pairingPath: url.path,
            host: activeHost,
            targetDispatches: selectedTargetDispatches,
            pikminType: selectedPikminType,
            pikminCount: max(selectedPikminType.minimumCount, pikminCount),
            cargoMode: selectedCargoMode,
            fastMode: isFastMode,
            onStatus: { newStatus in
                status = newStatus
            },
            onScreenshot: { image in
                screenshotImage = image
            }
        )
    }


    @MainActor
    private func startIntegratedTunnelOnly() async {
        busy = true
        defer { busy = false }
        status = "STAGE 11.5.4.6 TUNNEL • creating/loading paid PacketTunnelProvider configuration…"
        do {
            try await tunnel.ensureStarted(timeoutSeconds: 12.0)
            status = "STAGE 11.5.4.6 TUNNEL CONNECTED ✅ • peer=10.7.0.1 • next=RSD 10.7.0.1:49152"
        } catch {
            let diag = tunnel.diagnostics(for: error)
            status = "STAGE 11.5.4.6 TUNNEL FAILED • \(diag) • paid-signed tunnel failed; COPY LOG and keep external LocalDevVPN only as a temporary fallback"
        }
    }

    @MainActor
    private func restartIntegratedTunnel() async {
        busy = true
        defer { busy = false }
        rsdReady = false
        status = "STAGE 11.2.3 • hard-restarting PacketTunnelProvider session…"
        do {
            try await tunnel.restartFresh(timeoutSeconds: 15.0)
            status = "STAGE 11.2.3 TUNNEL FRESH ✅ • device=10.7.0.0 • fake=10.7.0.1 • next=RSD 10.7.0.1:49152"
        } catch {
            status = "STAGE 11.2.3 TUNNEL RESTART FAILED • \(tunnel.diagnostics(for: error))"
        }
    }

    @MainActor
    private func validatePairing() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }
        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.validatePairing()
        status = result.message
    }

    @MainActor
    private func runNoVPNSelfProbe() async {
        if tunnel.state == .connected || tunnel.state == .connecting {
            status = "NO-VPN PROBE BLOCKED • 請先 STOP Pikmin Pilot Integrated Tunnel，等狀態變成 DISCONNECTED；第一輪也請關掉外部 LocalDevVPN / 其他 VPN，確保測到的是純本機路徑。"
            return
        }

        busy = true
        defer { busy = false }
        rsdReady = false
        status = "NO-VPN SELF PROBE • tunnel=OFF • testing 127.0.0.1:62078 + self IPv4:62078…"
        let report = await NoVPNSelfTransportProbe.run()
        status = report.summary
    }

    @MainActor
    private func connectRSD() async {
        guard let url = pairing.pairingURL else {
            status = "RSD 尚未測試 • 請先匯入 RPPairing Record"
            return
        }
        busy = true
        defer { busy = false }

        let engine = IDeviceEngine(pairingPath: url.path)
        var result = await engine.probeRSD()

        // A provider can remain reported as CONNECTED after an IPA replacement while
        // its old extension process/session is stale. Recover once, automatically.
        if !result.ok,
           tunnel.state == .connected,
           result.message.localizedCaseInsensitiveContains("device socket io failed") {
            status = "RSD first attempt hit stale device socket • hard-restarting integrated tunnel once…"
            do {
                try await tunnel.restartFresh(timeoutSeconds: 15.0)
                result = await engine.probeRSD()
            } catch {
                rsdReady = false
                status = "PHONE-LOCAL RSD FAILED • tunnel recovery failed • \(tunnel.diagnostics(for: error)) • original=\(result.message)"
                return
            }
        }

        rsdReady = result.ok
        status = result.ok
            ? "PHONE-LOCAL RSD CONNECTED ✅ • 10.7.0.1:49152 • \(result.message)"
            : "PHONE-LOCAL RSD FAILED • 10.7.0.1:49152 • \(result.message)"
    }

    @MainActor
    private func validatePairingAndProbeRSD() async {
        guard let url = pairing.pairingURL else {
            status = "Pairing Record 匯入後找不到本機副本"
            return
        }
        busy = true
        defer { busy = false }

        let engine = IDeviceEngine(pairingPath: url.path)
        let validation = await engine.validatePairing()
        guard validation.ok else {
            rsdReady = false
            status = "PAIRING VALIDATE FAILED • \(validation.message)"
            return
        }

        status = "PAIRING VALIDATED ✅ • probing RSD 10.7.0.1:49152…"
        let rsd = await engine.probeRSD()
        rsdReady = rsd.ok
        status = rsd.ok
            ? "PAIRING + RSD READY ✅ • 10.7.0.1:49152 • \(rsd.message)"
            : "PAIRING VALIDATED ✅ • RSD FAILED • 10.7.0.1:49152 • \(rsd.message)"
    }

    @MainActor
    private func takeScreenshot() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PikminPilot-Stage7.4-Screenshot.png")
        try? FileManager.default.removeItem(at: outputURL)

        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.takeScreenshot(outputPath: outputURL.path)
        status = result.message

        if result.ok,
           let data = try? Data(contentsOf: outputURL),
           let image = UIImage(data: data) {
            screenshotImage = image
        } else {
            screenshotImage = nil
            if result.ok {
                status = "Screenshot bytes received, but UIKit could not decode image"
            }
        }
    }

    @MainActor
    private func prepareXCTestMetadata() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }
        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.prepareXCTestMetadata()
        status = result.message
    }


    @MainActor
    private func runXCTestCenterTap() async {
        guard let url = pairing.pairingURL else { return }

        busy = true
        status = "PHONE-LOCAL XCTEST CENTER TAP STARTING • mode=activate-no-relaunch • Pikmin must already be running…"

        // Runner/Pikmin will take foreground. Keep Pikmin Pilot alive long
        // enough to maintain testmanagerd/DTX until this short test finishes.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "PikminPilot-XCTest-CenterTap",
            expirationHandler: nil
        )

        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            busy = false
        }

        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.runXCTestCenterTap()
        status = result.message
    }

    @MainActor
    private func runStage8AvailableFruitTap() async {
        guard let url = pairing.pairingURL else { return }

        busy = true
        status = "STAGE 8.0 STARTING • activate → DVT screenshot → card-first detect → dynamic XCTest tap"

        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "PikminPilot-Stage8-AvailableFruitTap",
            expirationHandler: nil
        )

        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            busy = false
        }

        let engine = IDeviceEngine(pairingPath: url.path)

        let activate = await engine.runXCTestActivateOnly()
        guard activate.ok else {
            status = "STAGE 8.0 FAILED • phase=activate • \(activate.message)"
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PikminPilot-Stage8-AvailableFruit.png")
        try? FileManager.default.removeItem(at: outputURL)

        let shot = await engine.takeScreenshot(outputPath: outputURL.path)
        guard shot.ok,
              let data = try? Data(contentsOf: outputURL),
              let image = UIImage(data: data),
              let cg = image.cgImage else {
            status = "STAGE 8.0 FAILED • phase=dvt-screenshot • \(shot.message)"
            return
        }

        let detection = await FruitDetector.detect(in: image)
        screenshotImage = FruitDetector.annotated(image: image, result: detection)

        let available = detection.fruits.sorted {
            if abs($0.center.y - $1.center.y) > 12 {
                return $0.center.y < $1.center.y
            }
            return $0.center.x < $1.center.x
        }

        let busyCards = detection.cards.filter { $0.state == .busy }.count
        let completeCards = detection.cards.filter { $0.state == .complete }.count

        guard let fruit = available.first else {
            status = "STAGE 8.0 STOPPED SAFELY • no AVAILABLE fruit • busyCards=\(busyCards) • completeCards=\(completeCards) • blockedObjects=\(detection.blockedObjects.count) • no tap sent"
            return
        }

        let normalizedX = Double(fruit.center.x) / Double(cg.width)
        let normalizedY = Double(fruit.center.y) / Double(cg.height)

        guard normalizedX >= 0, normalizedX <= 1,
              normalizedY >= 0, normalizedY <= 1 else {
            status = "STAGE 8.0 FAILED • detector produced invalid normalized coordinate x=\(normalizedX) y=\(normalizedY)"
            return
        }

        status = String(
            format: "STAGE 8.0 DETECTED AVAILABLE • label=%@ • pixel=(%.1f, %.1f) • normalized=(%.5f, %.5f) • busyCards=%d • completeCards=%d • sending XCTest tap…",
            fruit.labelText,
            fruit.center.x,
            fruit.center.y,
            normalizedX,
            normalizedY,
            busyCards,
            completeCards
        )

        let tap = await engine.runXCTestTap(
            normalizedX: normalizedX,
            normalizedY: normalizedY
        )

        if tap.ok {
            status = String(
                format: "STAGE 8.0 AVAILABLE FRUIT TAP COMPLETED • card-first=PASS • label=%@ • normalized=(%.5f, %.5f) • busyCards=%d • completeCards=%d • %@",
                fruit.labelText,
                normalizedX,
                normalizedY,
                busyCards,
                completeCards,
                tap.message
            )
        } else {
            status = "STAGE 8.0 FAILED • phase=xctest-dynamic-tap • \(tap.message)"
        }
    }

    @MainActor
    private func startStage81Loop() {
        guard let url = pairing.pairingURL else { return }

        loop.start(
            pairingPath: url.path,
            targetDispatches: selectedTargetDispatches,
            pikminType: selectedPikminType,
            pikminCount: max(selectedPikminType.minimumCount, pikminCount),
            cargoMode: selectedCargoMode,
            fastMode: isFastMode,
            onStatus: { newStatus in
                status = newStatus
            },
            onScreenshot: { image in
                screenshotImage = image
            }
        )
    }

    @MainActor
    private func launchDiscoveredXCTestRunner() async {
        guard let url = pairing.pairingURL else { return }

        busy = true
        defer { busy = false }

        let engine = IDeviceEngine(pairingPath: url.path)

        let discovery = await engine.discoverXCTestRunner()
        guard discovery.ok else {
            status = discovery.message
            return
        }

        // Stage 7.6 discovery format:
        // PHONE-LOCAL XCTEST RUNNER FOUND • bundle.id[ | bundle.id...] • N user apps scanned
        let parts = discovery.message.components(separatedBy: " • ")
        guard parts.count >= 2 else {
            status = "RUNNER FOUND but bundle ID parse failed • \(discovery.message)"
            return
        }

        let firstCandidate = parts[1]
            .components(separatedBy: " | ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let bundleID = firstCandidate, !bundleID.isEmpty else {
            status = "RUNNER FOUND but bundle ID is empty • \(discovery.message)"
            return
        }

        let launch = await engine.launchBundleID(bundleID)
        status = launch.message
    }

    @MainActor
    private func discoverXCTestRunner() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }
        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.discoverXCTestRunner()
        status = result.message
    }

    @MainActor
    private func bootstrapXCTestDTX() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }
        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.bootstrapXCTestDTX()
        status = result.message
    }

    @MainActor
    private func probeXCTestServices() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }
        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.probeXCTestServices()
        status = result.message
    }

    @MainActor
    private func launchPikmin() async {
        guard let url = pairing.pairingURL else { return }
        busy = true
        defer { busy = false }
        let engine = IDeviceEngine(pairingPath: url.path)
        let result = await engine.launchPikmin()
        status = result.message
    }
}
