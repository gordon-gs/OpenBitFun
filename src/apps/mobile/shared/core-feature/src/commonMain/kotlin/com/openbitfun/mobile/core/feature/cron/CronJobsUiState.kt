package com.openbitfun.mobile.core.feature.cron

/**
 * One scheduled job as the host listed it.
 *
 * Every optional field is nullable and every string that the host did not send
 * is empty, because an older host may omit a field the apps already render.
 * Nothing here is a sentence: naming and formatting belong to the platform
 * surface.
 */
public data class CronJobRow public constructor(
    public val id: String,
    public val name: String,
    /** `at` | `every` | `cron`, or empty when the host sent no recognisable kind. */
    public val scheduleKind: String,
    public val everyMs: Long?,
    public val cronExpr: String?,
    public val cronTimeZone: String?,
    /** The one-shot instant exactly as the host wrote it; parsing is the surface's job. */
    public val atIso: String?,
    /** `payload.text`: what the job should do, as the host stored it. Empty when it sent none. */
    public val instruction: String,
    /** `session` | `workspace`, or empty when the host sent no recognisable kind. */
    public val targetKind: String,
    public val workspacePath: String?,
    public val sessionId: String?,
    public val agentType: String?,
    public val enabled: Boolean,
    public val nextRunAtMs: Long?,
    /** `queued` | `running` | `ok` | `error` | `cancelled`, or null when never run. */
    public val lastRunStatus: String?,
    public val lastRunFinishedAtMs: Long?,
    /** The host's own unlocalized diagnostic for the last failed run. */
    public val lastError: String?,
    /** True while this row's enable/delete command is in flight; other rows are unaffected. */
    public val busy: Boolean,
)

/**
 * One job as the surface wants it saved, before any host has seen it.
 *
 * Every value the editor collected is here, including the ones only a create
 * uses: an update never resends the target, so the target fields travel with
 * the draft and the store decides which of them belong in the request. The
 * parameter order is the cross-language constructor order, so it must not be
 * rearranged — Swift builds this positionally.
 */
public data class CronJobDraft public constructor(
    /** null = create a new job; non-null = edit that id. */
    public val jobId: String?,
    public val name: String,
    /** `every` | `cron` | `at`; only the matching value below is read. */
    public val scheduleKind: String,
    /** Milliseconds between runs; 0 when the draft is not an interval. */
    public val everyMs: Long,
    public val cronExpr: String?,
    public val cronTimeZone: String?,
    public val atIso: String?,
    public val instruction: String,
    public val enabled: Boolean,
    /** The only target this build can create: a workspace job. */
    public val workspacePath: String,
    public val workspaceId: String?,
    public val remoteConnectionId: String?,
    public val agentType: String,
)

public data class CronJobsUiState public constructor(
    public val loading: Boolean,
    /** True once a list has arrived; a later failure keeps it so the rows stay on screen. */
    public val loaded: Boolean,
    public val failed: Boolean,
    /** The host has no cron service or does not implement the command at all. */
    public val unsupported: Boolean,
    /** The host's raw error text for an ordinary failure; null means it sent none. */
    public val errorDetail: String?,
    public val jobs: List<CronJobRow>,
    /** True while a create/update is in flight; the list itself stays usable. */
    public val saving: Boolean,
    /** The host's raw error text for the last failed save; null means it sent none. */
    public val saveError: String?,
    /** `created` | `updated` for the last successful save, cleared once acknowledged. */
    public val saveOutcome: String?,
) {
    /**
     * The empty state. A secondary constructor rather than default arguments:
     * Kotlin defaults do not survive into Swift, so an iOS caller would be
     * forced to name fields it does not use — see the design doc §4.1.
     */
    public constructor() : this(false, false, false, false, null, emptyList(), false, null, null)
}

public sealed interface CronJobsIntent {
    public data object Load : CronJobsIntent
    public data object Refresh : CronJobsIntent
    public data class SetEnabled public constructor(public val jobId: String, public val enabled: Boolean) : CronJobsIntent
    public data class Delete public constructor(public val jobId: String) : CronJobsIntent
    public data class Save public constructor(public val draft: CronJobDraft) : CronJobsIntent
    /** Tells the store the surface has seen [CronJobsUiState.saveOutcome] and closed its editor. */
    public data object AcknowledgeSave : CronJobsIntent
    public data object Stop : CronJobsIntent
}
