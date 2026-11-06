import SwiftUI
import Foundation
import OpenBitFunMobileCore

/// "定时任务" panel: every job the connected host runs on a schedule.
///
/// The rows are host state, not local state. The switch reads `job.enabled` and
/// only dispatches, so it never claims a value the host has not confirmed yet;
/// the store echoes the new row back through `MobileAppModel.cronJobs`.
struct ScheduledJobsView: View {
    @ObservedObject var model: MobileAppModel

    /// The row whose "…" menu is open. One dialog serves the whole list: the
    /// panel is already a sheet, and stacking one dialog modifier per row makes
    /// iOS choose between them by gesture order.
    @State private var actionJob: CronJobRow?

    var body: some View {
        VStack(spacing: 0) {
            OpenBitFunModalHeader(
                title: model.localized("定时任务"),
                subtitle: model.localized("由连接的主机按计划执行"),
                onClose: { model.closeScheduledJobs() }
            )
            .padding(.horizontal, MobileDesignGeometry.sheetHorizontalPadding)
            Divider().overlay(OpenBitFunTheme.line)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    inlineAction("新建任务") { model.openScheduledJobEditor(nil) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The refresh gesture returns as soon as the intent is dispatched, so
                    // its own spinner stops before the host answers. This line is the
                    // panel's feedback for a refresh still in flight over rows we already
                    // have; the cold load keeps the centred spinner instead.
                    if isRefreshing { refreshIndicator }
                    stateContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesignGeometry.sheetHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            // The action closure of `refreshable` is `@Sendable`, so it does not
            // inherit this view's main-actor isolation; hop back before touching
            // the model.
            .refreshable { await MainActor.run { model.refreshScheduledJobs() } }
        }
        .background(OpenBitFunTheme.page)
        .confirmationDialog(
            model.localized("任务操作"),
            isPresented: Binding(
                get: { actionJob != nil },
                set: { presented in if !presented { actionJob = nil } }
            ),
            titleVisibility: .visible,
            presenting: actionJob
        ) { job in
            Button(model.localized("编辑")) {
                actionJob = nil
                model.openScheduledJobEditor(job)
            }
            Button(model.localized("删除"), role: .destructive) {
                actionJob = nil
                model.deleteScheduledJob(job)
            }
            Button(model.localized("立即刷新")) {
                actionJob = nil
                model.refreshScheduledJobs()
            }
            Button(model.localized("取消"), role: .cancel) { actionJob = nil }
        } message: { job in
            Text(job.name.isEmpty ? model.localized("未命名任务") : job.name)
        }
        // Presented from the panel rather than the shell: closing the panel must
        // also close the editor, and a plain sheet layers correctly over one.
        .sheet(isPresented: $model.scheduledJobEditorOpen) {
            ScheduledJobEditorView(model: model)
        }
    }

    /// Nil means the host has not answered for this target yet, which is the
    /// only state that separates "still loading" from "no jobs".
    @ViewBuilder
    private var stateContent: some View {
        if let state = model.cronJobs {
            if state.unsupported {
                notice(
                    "这台主机不支持定时任务",
                    "连接的宿主版本过旧，或是 CLI 宿主：请升级桌面端后再试。"
                )
            } else if state.failed && (state.jobs.isEmpty || !state.loaded) {
                failureContent(detail: state.errorDetail)
            } else if !state.loaded {
                loadingContent
            } else if state.jobs.isEmpty {
                emptyContent
            } else {
                // A refresh that failed after a good list keeps `loaded`, so the
                // rows the user is reading stay put and the failure is a banner.
                if state.failed {
                    refreshFailureBanner(detail: state.errorDetail)
                }
                ForEach(state.jobs, id: \.id) { job in
                    row(job)
                }
            }
        } else if model.remoteConnected {
            loadingContent
        } else {
            notice(
                "尚未连接主机",
                "连接桌面端后，这里会列出它按计划执行的任务。"
            )
        }
    }

    /// A refresh over rows the user already has. A cold load publishes
    /// `loading` with `loaded` still false, and `loadingContent` owns that case.
    private var isRefreshing: Bool {
        guard let state = model.cronJobs else { return false }
        return state.loading && state.loaded
    }

    private var refreshIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(OpenBitFunTheme.muted)
            Text(model.localized("正在刷新"))
                .font(MobileDesignTypography.labelSmall.font)
                .foregroundStyle(OpenBitFunTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("scheduledJobs.refreshing")
    }

    private func refreshFailureBanner(detail: String?) -> some View {
        let message = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 10) {
            Text(message.isEmpty ? model.localized("刷新失败，显示的是上次结果。") : message)
                .font(MobileDesignTypography.labelSmall.font)
                .foregroundStyle(OpenBitFunTheme.statusDanger)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            inlineAction("重试") { model.refreshScheduledJobs() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OpenBitFunTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: MobileDesignGeometry.settingsCardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: MobileDesignGeometry.settingsCardRadius)
                .stroke(OpenBitFunTheme.line, lineWidth: 1)
        )
    }

    private var loadingContent: some View {
        ProgressView()
            .tint(OpenBitFunTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
            .accessibilityLabel(model.localized("正在读取定时任务"))
    }

    private var emptyContent: some View {
        VStack(spacing: 10) {
            Text(model.localized("暂无定时任务"))
                .font(MobileDesignTypography.titleSmall.font)
                .foregroundStyle(OpenBitFunTheme.ink)
            Text(model.localized("在桌面端创建任务后，这里会显示它。"))
                .font(MobileDesignTypography.labelSmall.font)
                .foregroundStyle(OpenBitFunTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            inlineAction("刷新") { model.refreshScheduledJobs() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func failureContent(detail: String?) -> some View {
        let message = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 10) {
            Text(model.localized("无法读取定时任务"))
                .font(MobileDesignTypography.titleSmall.font)
                .foregroundStyle(OpenBitFunTheme.ink)
            Text(message.isEmpty ? model.localized("请检查连接后重试。") : message)
                .font(MobileDesignTypography.labelSmall.font)
                .foregroundStyle(OpenBitFunTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            inlineAction("重试") { model.refreshScheduledJobs() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityIdentifier("scheduledJobs.failure")
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        OpenBitFunModalCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.localized(title))
                    .font(MobileDesignTypography.titleSmall.font)
                    .foregroundStyle(OpenBitFunTheme.ink)
                Text(model.localized(detail))
                    .font(MobileDesignTypography.labelSmall.font)
                    .foregroundStyle(OpenBitFunTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func inlineAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(model.localized(title))
                .font(MobileDesignTypography.labelLarge.font)
                .foregroundStyle(OpenBitFunTheme.ink)
                .padding(.horizontal, 20)
                .frame(minHeight: MobileDesignGeometry.sheetActionHeight)
                .background(OpenBitFunTheme.soft)
                .overlay(Capsule().stroke(OpenBitFunTheme.line, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ job: CronJobRow) -> some View {
        let title = job.name.isEmpty ? model.localized("未命名任务") : job.name
        return OpenBitFunModalCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(MobileDesignTypography.titleSmall.font)
                        .foregroundStyle(OpenBitFunTheme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if job.busy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OpenBitFunTheme.muted)
                    }

                    Toggle(isOn: enabledBinding(job)) { EmptyView() }
                        .labelsHidden()
                        .tint(OpenBitFunTheme.ink)
                        .disabled(job.busy)
                        .accessibilityLabel(model.localizedFormat("启用「%@」", title))

                    Button { actionJob = job } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(OpenBitFunTheme.ink)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(job.busy)
                    .accessibilityLabel(model.localized("任务操作"))
                }

                Text(model.scheduleText(job: job))
                    .font(MobileDesignTypography.labelSmall.font)
                    .foregroundStyle(OpenBitFunTheme.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let nextRun = model.nextRunText(job: job) {
                    Text(model.localizedFormat("下次运行：%@", nextRun))
                        .font(MobileDesignTypography.labelSmall.font)
                        .foregroundStyle(OpenBitFunTheme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 4) {
                    Text(model.targetText(job: job))
                        .lineLimit(1)
                    // Separator only; the words around it are localized.
                    Text(verbatim: "·")
                    Text(model.statusText(job: job))
                        .foregroundStyle(resultColor(job.lastRunStatus))
                        .lineLimit(1)
                }
                .font(MobileDesignTypography.labelSmall.font)
                .foregroundStyle(OpenBitFunTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let lastError = job.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !lastError.isEmpty {
                    Text(lastError)
                        .font(MobileDesignTypography.labelSmall.font)
                        .foregroundStyle(OpenBitFunTheme.statusDanger)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .opacity(job.enabled ? 1 : 0.55)
        .accessibilityIdentifier("scheduledJobs.row.\(job.id)")
    }

    /// The host owns `enabled`; the setter dispatches and the store publishes
    /// the value the host accepted, so the switch stays truthful while a round
    /// trip is in flight.
    private func enabledBinding(_ job: CronJobRow) -> Binding<Bool> {
        Binding(
            get: { job.enabled },
            set: { enabled in model.setScheduledJobEnabled(job, enabled: enabled) }
        )
    }

    private func resultColor(_ status: String?) -> Color {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok": return OpenBitFunTheme.statusSuccess
        case "error": return OpenBitFunTheme.statusDanger
        default: return OpenBitFunTheme.muted
        }
    }
}

/// Copy comes from the host as structure only, so every human-readable string
/// in a row is assembled here: schedule, next run, target and last result.
private extension MobileAppModel {
    func scheduleText(job: CronJobRow) -> String {
        switch job.scheduleKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "every":
            guard let everyMs = job.everyMs?.int64Value, everyMs > 0 else {
                return localized("周期计划")
            }
            if everyMs % 86_400_000 == 0 { return localizedFormat("每 %lld 天", everyMs / 86_400_000) }
            if everyMs % 3_600_000 == 0 { return localizedFormat("每 %lld 小时", everyMs / 3_600_000) }
            if everyMs % 60_000 == 0 { return localizedFormat("每 %lld 分钟", everyMs / 60_000) }
            if everyMs < 60_000 { return localizedFormat("每 %lld 秒", max(1, everyMs / 1_000)) }
            // Hosts may hand back an interval that is not a whole unit.
            return localizedFormat("每 %lld 分钟", (everyMs + 30_000) / 60_000)
        case "cron":
            let expression = (job.cronExpr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else { return localized("Cron 计划") }
            let zone = (job.cronTimeZone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return zone.isEmpty
                ? localizedFormat("Cron：%@", expression)
                : localizedFormat("Cron：%@（%@）", expression, zone)
        case "at":
            return atTimeText(job.atIso) ?? localized("单次计划")
        default:
            return localized("未提供计划")
        }
    }

    /// Nil when the host reports no next run and the job may still fire again,
    /// so the row simply omits the line. A spent one-shot says so explicitly.
    func nextRunText(job: CronJobRow) -> String? {
        if let nextRunAtMs = job.nextRunAtMs?.int64Value {
            let date = Date(timeIntervalSince1970: Double(nextRunAtMs) / 1_000)
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_Hans")
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        // A one-shot job that already fired has no next run at all.
        return job.scheduleKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "at"
            ? localized("不再重复")
            : nil
    }

    func statusText(job: CronJobRow) -> String {
        switch (job.lastRunStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued": return localized("排队中")
        case "running": return localized("运行中")
        case "ok": return localized("上次成功")
        case "error": return localized("上次失败")
        case "cancelled": return localized("已取消")
        default: return localized("尚未运行")
        }
    }

    func targetText(job: CronJobRow) -> String {
        switch job.targetKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "workspace":
            let path = (job.workspacePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return localized("工作区") }
            let name = (path as NSString).lastPathComponent
            return localizedFormat("工作区 %@", name.isEmpty ? path : name)
        case "session":
            return localized("会话")
        default:
            return localized("未指定目标")
        }
    }

    /// ISO-8601 from the host rendered in the device's own zone.
    func atTimeText(_ iso: String?) -> String? {
        let raw = (iso ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
