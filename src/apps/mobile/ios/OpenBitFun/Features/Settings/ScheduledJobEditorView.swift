import SwiftUI
import Foundation
import OpenBitFunMobileCore

/// "新建 / 编辑定时任务" form.
///
/// The form is a draft, not a mirror of the host: nothing leaves this sheet
/// until Save dispatches a `CronJobDraft`. Every field is local state seeded
/// once from `model.scheduledJobEditorJob`, because re-renders (a store echo, a
/// keyboard change) must not overwrite what the user typed. `saving` and
/// `saveError` stay host state — the store closes this sheet when the save
/// outcome lands, so a failed save keeps the user's draft on screen.
struct ScheduledJobEditorView: View {
    @ObservedObject var model: MobileAppModel

    private static let minuteMs: Int64 = 60_000
    private static let hourMs: Int64 = 3_600_000
    private static let dayMs: Int64 = 86_400_000

    /// `every` | `cron` | `at`, exactly the words the host uses.
    @State private var scheduleKind = "every"
    @State private var name = ""
    @State private var everyValue = "30"
    /// `minute` | `hour` | `day`; the value sent is the matching millisecond count.
    @State private var everyUnit = "minute"
    @State private var cronExpr = ""
    @State private var cronTimeZone = ""
    @State private var atDate = Date().addingTimeInterval(3_600)
    @State private var instruction = ""
    @State private var enabled = true
    /// Only meaningful while creating: an edit keeps the host's target.
    @State private var workspaceIndex = 0
    /// Prefill is one-shot; `onAppear` also runs when the sheet is re-shown.
    @State private var prefilled = false
    /// Sticky for the life of the presentation: a landed save clears
    /// `scheduledJobEditorJob`, and the sheet must not flip to the create layout
    /// while it is still animating away.
    @State private var editingLayout = false

    var body: some View {
        VStack(spacing: 0) {
            OpenBitFunModalHeader(
                title: model.localized(isEditing ? "编辑定时任务" : "新建定时任务"),
                subtitle: model.localized("由连接的主机按计划执行"),
                onClose: { model.closeScheduledJobEditor() }
            )
            .padding(.horizontal, MobileDesignGeometry.sheetHorizontalPadding)
            Divider().overlay(OpenBitFunTheme.line)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    scheduleFields
                    workspaceField
                    instructionField
                    enabledField
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesignGeometry.sheetHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
        }
        .background(OpenBitFunTheme.page)
        .onAppear(perform: prefillOnce)
        // A save is a single round trip; closing the form mid-flight would leave
        // the user without the error text the host is about to send.
        .interactiveDismissDisabled(isSaving)
        .accessibilityIdentifier("scheduledJobEditor.sheet")
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("名称")
            OpenBitFunModalCard {
                TextField(model.localized("名称"), text: $name)
                    .textFieldStyle(.plain)
                    .font(MobileDesignTypography.bodyLarge.font)
                    .foregroundStyle(OpenBitFunTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("scheduledJobEditor.name")
            }
        }
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("计划")
            Picker(selection: $scheduleKind) {
                Text(model.localized("每 N")).tag("every")
                Text(model.localized("Cron")).tag("cron")
                Text(model.localized("一次")).tag("at")
            } label: {
                Text(model.localized("计划"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("scheduledJobEditor.scheduleKind")

            switch scheduleKind {
            case "cron":
                cronSection
            case "at":
                atSection
            default:
                everySection
            }
        }
    }

    private var everySection: some View {
        OpenBitFunModalCard {
            HStack(spacing: 10) {
                Text(model.localized("每"))
                    .font(MobileDesignTypography.bodyLarge.font)
                    .foregroundStyle(OpenBitFunTheme.muted)
                TextField("30", text: $everyValue)
                    .textFieldStyle(.plain)
                    .keyboardType(.numberPad)
                    .font(MobileDesignTypography.bodyLarge.font)
                    .foregroundStyle(OpenBitFunTheme.ink)
                    .frame(maxWidth: 80, alignment: .leading)
                    .accessibilityIdentifier("scheduledJobEditor.everyValue")
                Spacer(minLength: 8)
                Picker(selection: $everyUnit) {
                    Text(model.localized("分钟")).tag("minute")
                    Text(model.localized("小时")).tag("hour")
                    Text(model.localized("天")).tag("day")
                } label: {
                    Text(model.localized("间隔单位"))
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(OpenBitFunTheme.ink)
                .accessibilityIdentifier("scheduledJobEditor.everyUnit")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
        }
    }

    private var cronSection: some View {
        OpenBitFunModalCard {
            VStack(alignment: .leading, spacing: 10) {
                // The example is syntax, not copy: it stays verbatim.
                TextField("0 9 * * *", text: $cronExpr)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: MobileDesignTypography.bodyLarge.size, design: .monospaced))
                    .foregroundStyle(OpenBitFunTheme.ink)
                    .accessibilityIdentifier("scheduledJobEditor.cronExpr")
                Rectangle()
                    .fill(OpenBitFunTheme.line)
                    .frame(height: 1)
                TextField(model.localized("时区（可选，例如 Asia/Shanghai）"), text: $cronTimeZone)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(MobileDesignTypography.bodyMedium.font)
                    .foregroundStyle(OpenBitFunTheme.ink)
                    .accessibilityIdentifier("scheduledJobEditor.cronTimeZone")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        presetAction("每天 9:00", expression: "0 9 * * *")
                        presetAction("每小时", expression: "0 * * * *")
                        presetAction("每周一 9:00", expression: "0 9 * * 1")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var atSection: some View {
        OpenBitFunModalCard {
            DatePicker(
                selection: $atDate,
                in: Date()...Date.distantFuture,
                displayedComponents: [.date, .hourAndMinute]
            ) {
                Text(model.localized("执行时间"))
                    .font(MobileDesignTypography.bodyLarge.font)
                    .foregroundStyle(OpenBitFunTheme.ink)
            }
            .datePickerStyle(.compact)
            .tint(OpenBitFunTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .accessibilityIdentifier("scheduledJobEditor.atDate")
        }
    }

    /// Creating picks a target; editing shows the one the host already holds,
    /// because `update_cron_job` carries no target.
    @ViewBuilder
    private var workspaceField: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("工作区")
                OpenBitFunModalCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(targetSummary)
                            .font(MobileDesignTypography.bodyLarge.font)
                            .foregroundStyle(OpenBitFunTheme.ink)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(model.localized("目标只能在桌面端修改"))
                            .font(MobileDesignTypography.labelSmall.font)
                            .foregroundStyle(OpenBitFunTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        } else if model.workspaceCatalog.isEmpty {
            OpenBitFunModalCard {
                Text(model.localized("没有可用的工作区，请先在桌面端打开一个工作区再创建任务。"))
                    .font(MobileDesignTypography.labelSmall.font)
                    .foregroundStyle(OpenBitFunTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("scheduledJobEditor.workspaceEmpty")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("工作区")
                OpenBitFunModalCard {
                    Picker(selection: $workspaceIndex) {
                        ForEach(model.workspaceCatalog.indices, id: \.self) { index in
                            Text(workspaceTitle(at: index)).tag(index)
                        }
                    } label: {
                        Text(model.localized("工作区"))
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(OpenBitFunTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .accessibilityIdentifier("scheduledJobEditor.workspace")
                }
            }
        }
    }

    private var instructionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("指令")
            OpenBitFunModalCard {
                ZStack(alignment: .topLeading) {
                    if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(model.localized("告诉 OpenBitFun 要做什么"))
                            .font(MobileDesignTypography.bodyLarge.font)
                            .foregroundStyle(OpenBitFunTheme.muted)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $instruction)
                        .font(MobileDesignTypography.bodyLarge.font)
                        .foregroundStyle(OpenBitFunTheme.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("scheduledJobEditor.instruction")
                }
            }
        }
    }

    private var enabledField: some View {
        OpenBitFunModalCard {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.localized("启用"))
                        .font(MobileDesignTypography.bodyLarge.font)
                        .foregroundStyle(OpenBitFunTheme.ink)
                    Text(model.localized("关闭后任务保留，但不会按计划执行"))
                        .font(MobileDesignTypography.labelSmall.font)
                        .foregroundStyle(OpenBitFunTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(OpenBitFunTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .accessibilityIdentifier("scheduledJobEditor.enabled")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Text(saveError)
                    .font(MobileDesignTypography.labelSmall.font)
                    .foregroundStyle(OpenBitFunTheme.statusDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("scheduledJobEditor.saveError")
            }
            // The reason Save is dim, so a disabled button never reads as a bug.
            if let validationHint, !isSaving {
                Text(validationHint)
                    .font(MobileDesignTypography.labelSmall.font)
                    .foregroundStyle(OpenBitFunTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("scheduledJobEditor.validation")
            }
            Button(action: save) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OpenBitFunTheme.contentOnAction)
                    }
                    Text(model.localized(isEditing ? "保存修改" : "创建任务"))
                        .font(MobileDesignTypography.labelLarge.font)
                        .foregroundStyle(OpenBitFunTheme.contentOnAction)
                }
                .frame(maxWidth: .infinity, minHeight: MobileDesignGeometry.sheetActionHeight)
                .background(MobileDesignColors.primaryAction)
                .overlay(Capsule().stroke(MobileDesignColors.primaryAction, lineWidth: 1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSave || isSaving)
            .opacity(canSave && !isSaving ? 1 : 0.32)
            .accessibilityIdentifier("scheduledJobEditor.save")
            .padding(.top, 6)
        }
    }

    private func sectionLabel(_ key: String) -> some View {
        Text(model.localized(key))
            .font(MobileDesignTypography.labelSmall.font)
            .foregroundStyle(OpenBitFunTheme.muted)
    }

    /// A catalog entry may carry no display name; its path is then the name.
    private func workspaceTitle(at index: Int) -> String {
        let catalog = model.workspaceCatalog
        guard index >= 0, index < catalog.count else { return "" }
        let entry = catalog[index]
        return entry.name.isEmpty ? entry.path : entry.name
    }

    private func presetAction(_ title: String, expression: String) -> some View {
        Button {
            cronExpr = expression
        } label: {
            Text(model.localized(title))
                .font(MobileDesignTypography.labelLarge.font)
                .foregroundStyle(OpenBitFunTheme.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(OpenBitFunTheme.soft)
                .overlay(Capsule().stroke(OpenBitFunTheme.line, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scheduledJobEditor.preset.\(expression)")
    }

    // MARK: - Host state

    private var job: CronJobRow? { model.scheduledJobEditorJob }

    private var isEditing: Bool { job != nil || editingLayout }

    private var isSaving: Bool { model.cronJobs?.saving ?? false }

    private var saveError: String? {
        let text = (model.cronJobs?.saveError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var targetSummary: String {
        guard let job else { return "" }
        if job.targetKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "session" {
            return model.localized("会话目标")
        }
        let path = (job.workspacePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? model.localized("未指定工作区") : path
    }

    // MARK: - Validation

    /// The first unmet rule, or nil when the draft can be sent. Order follows
    /// the form so the line under the button names the field the user is on.
    private var validationHint: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.localized("请填写任务名称")
        }
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.localized("请填写要执行的指令")
        }
        switch scheduleKind {
        case "cron":
            if cronFields.count != 5 {
                return model.localized("Cron 表达式需要 5 段，例如 0 9 * * *")
            }
        case "at":
            if atDate <= Date() {
                return model.localized("执行时间必须晚于当前时间")
            }
        default:
            if everyCount == nil {
                return model.localized("间隔必须是大于 0 的整数")
            }
        }
        if !isEditing && !hasSelectedWorkspace {
            return model.localized("请选择要运行任务的工作区")
        }
        return nil
    }

    private var canSave: Bool { validationHint == nil }

    private var everyCount: Int64? {
        let raw = everyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(raw), value > 0 else { return nil }
        // An interval that overflows the millisecond field is not a schedule.
        let (_, overflow) = value.multipliedReportingOverflow(by: everyUnitMs)
        return overflow ? nil : value
    }

    private var cronFields: [String] {
        cronExpr.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private var hasSelectedWorkspace: Bool {
        let catalog = model.workspaceCatalog
        guard workspaceIndex >= 0, workspaceIndex < catalog.count else { return false }
        return !catalog[workspaceIndex].path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var everyUnitMs: Int64 {
        switch everyUnit {
        case "day": return Self.dayMs
        case "hour": return Self.hourMs
        default: return Self.minuteMs
        }
    }

    // MARK: - Prefill

    private func prefillOnce() {
        guard !prefilled else { return }
        prefilled = true
        editingLayout = job != nil
        guard let job else {
            // Creating: start on the workspace the user is already in.
            workspaceIndex = defaultWorkspaceIndex()
            return
        }
        name = job.name
        let hostKind = job.scheduleKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        scheduleKind = ["every", "cron", "at"].contains(hostKind) ? hostKind : "every"
        applyInterval(job.everyMs?.int64Value)
        cronExpr = job.cronExpr ?? ""
        cronTimeZone = job.cronTimeZone ?? ""
        if let date = Self.parseInstant(job.atIso) { atDate = date }
        instruction = job.instruction
        enabled = job.enabled
    }

    /// The host stores milliseconds only. Days win over hours over minutes so
    /// "86400000" opens as "每 1 天" rather than "每 1440 分钟".
    private func applyInterval(_ intervalMs: Int64?) {
        guard let intervalMs, intervalMs > 0 else { return }
        if intervalMs % Self.dayMs == 0 {
            everyUnit = "day"
            everyValue = String(intervalMs / Self.dayMs)
        } else if intervalMs % Self.hourMs == 0 {
            everyUnit = "hour"
            everyValue = String(intervalMs / Self.hourMs)
        } else {
            everyUnit = "minute"
            everyValue = String(max(1, (intervalMs + 30_000) / Self.minuteMs))
        }
    }

    private func defaultWorkspaceIndex() -> Int {
        let catalog = model.workspaceCatalog
        if let index = catalog.firstIndex(where: { $0.selected }) { return index }
        return 0
    }

    // MARK: - Save

    private func save() {
        guard canSave else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = cronExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = cronTimeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        // `CronJobDraft.everyMs` is a non-null Kotlin `Long`: 0 means "this draft
        // is not an interval", which keeps the field out of Swift's boxed
        // `KotlinLong` interop entirely.
        let everyMs: Int64 = scheduleKind == "every"
            ? (everyCount.map { $0 * everyUnitMs } ?? 0)
            : 0
        // Editing never re-targets: `update_cron_job` carries no target.
        var selected: MobileAppModel.WorkspaceCatalogEntry?
        if !isEditing && hasSelectedWorkspace {
            selected = model.workspaceCatalog[workspaceIndex]
        }

        let draft = CronJobDraft(
            jobId: job?.id,
            name: cleanName,
            scheduleKind: scheduleKind,
            everyMs: everyMs,
            cronExpr: scheduleKind == "cron" ? expression : nil,
            cronTimeZone: scheduleKind == "cron" && !zone.isEmpty ? zone : nil,
            atIso: scheduleKind == "at" ? Self.isoFormatter.string(from: atDate) : nil,
            instruction: cleanInstruction,
            enabled: enabled,
            workspacePath: isEditing
                ? (job?.workspacePath ?? "")
                : (selected?.path ?? ""),
            workspaceId: selected?.workspaceId,
            remoteConnectionId: selected?.remoteConnectionId,
            // An edit keeps the agent the job already runs with.
            agentType: job?.agentType ?? "Standard"
        )
        model.saveScheduledJob(draft)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Hosts may send fractional seconds; the plain form is the fallback.
    private static func parseInstant(_ iso: String?) -> Date? {
        let raw = (iso ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
