import OpenBitFunMobileCore

/// Scheduled jobs (`list_cron_jobs` / `update_cron_job` / `delete_cron_job`).
///
/// The panel's published state (`scheduledJobsOpen`, `cronJobs`) lives on
/// `MobileAppModel` itself; this file only drives the store and applies its
/// stream. Jobs belong to the selected host, not to a workspace, so nothing
/// here filters by workspace.
@MainActor
extension MobileAppModel {
    func openScheduledJobs() {
        scheduledJobsOpen = true
        guard let adapter = coreAdapter, adapter.hasCronJobsTarget else {
            // No store is bound to a host yet: drop whatever the previous host
            // published instead of showing its rows under the new title.
            cronJobs = nil
            return
        }
        adapter.loadCronJobs()
    }

    func closeScheduledJobs() {
        scheduledJobsOpen = false
    }

    func refreshScheduledJobs() {
        coreAdapter?.refreshCronJobs()
    }

    func setScheduledJobEnabled(_ job: CronJobRow, enabled: Bool) {
        guard job.enabled != enabled else { return }
        coreAdapter?.setCronJobEnabled(jobId: job.id, enabled: enabled)
    }

    func deleteScheduledJob(_ job: CronJobRow) {
        coreAdapter?.deleteCronJob(jobId: job.id)
    }

    /// Nil opens the editor on a blank draft; a row opens it prefilled and its
    /// id turns the save into `update_cron_job`.
    func openScheduledJobEditor(_ job: CronJobRow?) {
        scheduledJobEditorJob = job
        scheduledJobEditorOpen = true
    }

    func closeScheduledJobEditor() {
        scheduledJobEditorOpen = false
        scheduledJobEditorJob = nil
    }

    /// The draft is not kept here: the store owns `saving`/`saveError`, and a
    /// failed save keeps the form open so the user still has their input.
    func saveScheduledJob(_ draft: CronJobDraft) {
        coreAdapter?.saveCronJob(draft)
    }

    /// Store callbacks carry the target they were bound to. The epoch moves on
    /// every rebind, so a slow answer for a host the user already left is
    /// dropped instead of landing on the new host's list.
    func apply(cronJobsState state: CronJobsUiState, targetKey: String, epoch: UInt64) {
        guard !localActionPreview, !accountLoginPreview,
              RemoteAuthorityGate.callbackMatchesAuthority(
                  targetKey: targetKey,
                  epoch: epoch,
                  expectedTargetKey: remoteExpectedDeviceKey,
                  expectedEpoch: remoteTargetEpoch
              ) else { return }
        cronJobs = state
        // A completed save closes the form: the list already carries the row the
        // host returned, and leaving the sheet open would let a second Save
        // re-send it. The acknowledgement clears `saveOutcome` so this runs once.
        if state.saveOutcome != nil {
            scheduledJobEditorOpen = false
            scheduledJobEditorJob = nil
            coreAdapter?.acknowledgeCronSave()
        }
    }
}
