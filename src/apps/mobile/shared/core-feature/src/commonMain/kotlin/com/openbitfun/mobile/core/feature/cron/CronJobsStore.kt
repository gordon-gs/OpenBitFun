package com.openbitfun.mobile.core.feature.cron

import com.openbitfun.mobile.core.protocol.*
import com.openbitfun.mobile.core.transport.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable
private data class CronHostResult(override val resp: String? = null, override val message: String? = null,
    val ok: Boolean = false, val value: JsonElement = JsonNull, val error: String? = null) : CommandStatus

/**
 * [detail] is the host's own diagnostic, carried to the surface unchanged.
 * [unsupported] marks a host that has no cron service or no such command, which
 * is a shape the panel can explain without a retry — never an app-written string.
 */
private class CronHostFailure(val detail: String?, val unsupported: Boolean) : Exception()

/**
 * The scheduled jobs of one controlled host.
 *
 * Reads are serialized through a single load gate and every state write is
 * fenced by [epoch], so a reply that arrives after [stop] cannot republish a
 * host the app has already left. Enable/delete act on one row at a time: the
 * affected row is busy, the rest of the list is untouched.
 */
public class CronJobsStore internal constructor(
    private val scope: CoroutineScope,
    private val transport: RemoteCommandTransport,
) {
    private val _state: MutableStateFlow<CronJobsUiState> = MutableStateFlow(CronJobsUiState())
    public val state: StateFlow<CronJobsUiState> = _state.asStateFlow()

    private var loadJob: Job? = null
    /** The one create/update in flight; a save is list-wide, so a second waits its turn. */
    private var saveJob: Job? = null
    /** Changes only when this store is stopped; an older generation never writes state. */
    private var epoch = 0L
    /** One in-flight action per job: two rows may be busy at once, one row never twice. */
    private val rowActions: MutableMap<String, Job> = mutableMapOf()

    public fun dispatch(intent: CronJobsIntent) {
        when (intent) {
            CronJobsIntent.Load -> load()
            CronJobsIntent.Refresh -> load()
            is CronJobsIntent.SetEnabled -> setEnabled(intent.jobId, intent.enabled)
            is CronJobsIntent.Delete -> delete(intent.jobId)
            is CronJobsIntent.Save -> save(intent.draft)
            CronJobsIntent.AcknowledgeSave -> _state.value = _state.value.copy(saveOutcome = null)
            CronJobsIntent.Stop -> stop()
        }
    }

    public fun stop() {
        epoch += 1
        loadJob?.cancel()
        loadJob = null
        saveJob?.cancel()
        saveJob = null
        rowActions.values.forEach { it.cancel() }
        rowActions.clear()
        // The reset also clears an in-flight save's `saving` flag; the epoch fence
        // keeps the cancelled coroutine from writing anything after it.
        _state.value = CronJobsUiState()
    }

    private fun load() {
        if (_state.value.loading) return
        val ticket = epoch
        loadJob?.cancel()
        _state.value = _state.value.copy(loading = true, failed = false, unsupported = false, errorDetail = null)
        loadJob = scope.launch {
            try {
                val jobs = fetchJobs()
                if (ticket != epoch) return@launch
                _state.value = _state.value.copy(loading = false, loaded = true, failed = false,
                    unsupported = false, errorDetail = null, jobs = jobs, saveError = null, saveOutcome = null)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (ticket != epoch) return@launch
                val failure = error as? CronHostFailure
                val unsupported = failure?.unsupported == true
                _state.value = _state.value.copy(loading = false, unsupported = unsupported,
                    failed = !unsupported, errorDetail = if (unsupported) null else failure?.detail)
            }
        }
    }

    private fun setEnabled(jobId: String, enabled: Boolean) {
        val existing = _state.value.jobs.firstOrNull { it.id == jobId } ?: return
        if (existing.busy) return
        val ticket = epoch
        updateRow(jobId) { it.copy(busy = true) }
        launchRowAction(jobId, ticket) {
            val updated = invoke("update_cron_job", buildJsonObject {
                put("jobId", jobId)
                put("enabled", enabled)
            })
            if (ticket != epoch) return@launchRowAction
            // A host that answers with the updated job is authoritative; one that
            // answers with a bare `true` or nothing still leaves a truthful row.
            val authoritative = (updated as? JsonObject)?.let { parseRow(it) }?.takeIf { it.id == jobId }
            _state.value = _state.value.copy(failed = false, errorDetail = null,
                jobs = _state.value.jobs.map { current ->
                    when {
                        current.id != jobId -> current
                        authoritative != null -> authoritative
                        else -> current.copy(enabled = enabled, busy = false)
                    }
                })
        }
    }

    private fun delete(jobId: String) {
        val existing = _state.value.jobs.firstOrNull { it.id == jobId } ?: return
        if (existing.busy) return
        val ticket = epoch
        updateRow(jobId) { it.copy(busy = true) }
        launchRowAction(jobId, ticket) {
            invoke("delete_cron_job", buildJsonObject { put("jobId", jobId) })
            if (ticket != epoch) return@launchRowAction
            _state.value = _state.value.copy(failed = false, errorDetail = null,
                jobs = _state.value.jobs.filterNot { it.id == jobId })
        }
    }

    /**
     * Creates or updates one job from [draft].
     *
     * A save is list-wide rather than per-row: a created job has no id until the
     * host names one, so there is no row to mark busy, and two saves at once
     * would race for the same list. One in flight is enough for the editor,
     * which disables its own button on [CronJobsUiState.saving].
     *
     * A failed save lands on [CronJobsUiState.saveError] only. The rows on
     * screen are still the host's last list, so [CronJobsUiState.failed] and
     * [CronJobsUiState.unsupported] keep describing that read; only the editor
     * has something to say about the save.
     */
    private fun save(draft: CronJobDraft) {
        if (_state.value.saving) return
        // A draft this build cannot express (unknown kind, or the value that kind
        // needs left empty) is dropped rather than sent half-formed: a guessed
        // schedule would run a job the user never described. The surface
        // validates before it gets here, so nothing reachable is lost.
        val schedule = scheduleRequest(draft) ?: return
        val jobId = draft.jobId
        val payload = buildJsonObject { put("text", draft.instruction) }
        val ticket = epoch
        _state.value = _state.value.copy(saving = true, saveError = null, saveOutcome = null)
        saveJob?.cancel()
        saveJob = scope.launch {
            try {
                val value = if (jobId == null) {
                    // Only a create carries a target; an update keeps the one the
                    // desktop already stored, so it must not send one.
                    invoke("create_cron_job", buildJsonObject {
                        put("name", draft.name)
                        put("schedule", schedule)
                        put("payload", payload)
                        put("enabled", draft.enabled)
                        put("target", buildJsonObject {
                            put("kind", "workspace")
                            put("workspace", buildJsonObject {
                                put("workspacePath", draft.workspacePath)
                                // An absent identity is an absent key, not a null one:
                                // the host reads a zero-length or null id as "not given".
                                draft.workspaceId?.let { put("workspaceId", it) }
                                draft.remoteConnectionId?.let { put("remoteConnectionId", it) }
                            })
                            put("launch", buildJsonObject { put("agentType", draft.agentType) })
                        })
                    })
                } else {
                    invoke("update_cron_job", buildJsonObject {
                        put("jobId", jobId)
                        put("name", draft.name)
                        put("schedule", schedule)
                        put("payload", payload)
                        put("enabled", draft.enabled)
                    })
                }
                if (ticket != epoch) return@launch
                _state.value = _state.value.copy(
                    saving = false,
                    saveError = null,
                    saveOutcome = if (jobId == null) SAVE_CREATED else SAVE_UPDATED,
                    // The host's answer is the authoritative row; a reply that is not
                    // a job object still counts as saved, it just cannot update the list.
                    jobs = (value as? JsonObject)?.let { upsert(parseRow(it)) } ?: _state.value.jobs,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (ticket != epoch) return@launch
                _state.value = _state.value.copy(saving = false,
                    saveError = (error as? CronHostFailure)?.detail, saveOutcome = null)
            }
        }
    }

    /**
     * The wire schedule for [draft], or null when this build cannot send it.
     *
     * The host accepts exactly three kinds, each with its own required field, so
     * anything else is refused here rather than serialised into a request the
     * host would reject with a message the user cannot act on.
     */
    private fun scheduleRequest(draft: CronJobDraft): JsonObject? = when (draft.scheduleKind) {
        "every" -> if (draft.everyMs > 0) {
            buildJsonObject { put("kind", "every"); put("everyMs", draft.everyMs) }
        } else null
        "cron" -> draft.cronExpr?.let { expr ->
            buildJsonObject {
                put("kind", "cron")
                put("expr", expr)
                // A blank zone means "the host's default", which is an absent key.
                draft.cronTimeZone?.takeIf { it.isNotBlank() }?.let { zone -> put("tz", zone) }
            }
        }
        "at" -> draft.atIso?.let { at ->
            buildJsonObject { put("kind", "at"); put("at", at) }
        }
        else -> null
    }

    /**
     * The list with [row] in it: the same id replaces in place, a new id joins at
     * the top, where the host lists its newest job.
     */
    private fun upsert(row: CronJobRow): List<CronJobRow> {
        val jobs = _state.value.jobs
        if (jobs.none { it.id == row.id }) return listOf(row) + jobs
        return jobs.map { if (it.id == row.id) row else it }
    }

    /**
     * Runs one row's command. [action] may leave early on a stale ticket; the
     * finally block still clears the row's flag, but only for this generation.
     */
    private fun launchRowAction(jobId: String, ticket: Long, action: suspend () -> Unit) {
        rowActions.remove(jobId)?.cancel()
        val work = scope.launch {
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (ticket == epoch) fail(error)
            } finally {
                if (ticket == epoch) updateRow(jobId) { it.copy(busy = false) }
            }
        }
        rowActions[jobId] = work
        // Completed entries are dropped so a host that drops the job does not
        // keep a dead reference; a finished Job is harmless to cancel anyway.
        work.invokeOnCompletion { if (rowActions[jobId] === work) rowActions.remove(jobId) }
    }

    private fun fail(error: Throwable) {
        val failure = error as? CronHostFailure
        val unsupported = failure?.unsupported == true
        _state.value = _state.value.copy(
            unsupported = unsupported || _state.value.unsupported,
            failed = if (unsupported) _state.value.failed else true,
            errorDetail = if (unsupported) _state.value.errorDetail else failure?.detail,
        )
    }

    private fun updateRow(jobId: String, transform: (CronJobRow) -> CronJobRow) {
        _state.value = _state.value.copy(jobs = _state.value.jobs.map { if (it.id == jobId) transform(it) else it })
    }

    private suspend fun invoke(command: String, request: JsonObject): JsonElement {
        val response = transport.send<CronHostResult>(RemoteCommand(cmd = "host_invoke", command = command,
            args = buildJsonObject { put("request", request) }))
        if (!response.ok) throw CronHostFailure(response.error?.takeIf { it.isNotBlank() }, isUnsupported(response.error))
        return response.value
    }

    private fun isUnsupported(error: String?): Boolean {
        val text = error.orEmpty().lowercase()
        return text.contains(UNSUPPORTED_SERVICE) || text.contains(UNSUPPORTED_COMMAND)
    }

    private suspend fun fetchJobs(): List<CronJobRow> {
        val value = invoke("list_cron_jobs", buildJsonObject { })
        val items = value as? JsonArray ?: return emptyList()
        return items.mapNotNull { item -> (item as? JsonObject)?.let { parseRow(it) } }
    }

    /**
     * Reads one host job. Every field is optional on the wire: a host that adds
     * or drops one must still produce a row rather than a failed load.
     */
    private fun parseRow(item: JsonObject): CronJobRow {
        val schedule = item["schedule"] as? JsonObject
        val payload = item["payload"] as? JsonObject
        val target = item["target"] as? JsonObject
        val workspace = target?.get("workspace") as? JsonObject
        val launch = target?.get("launch") as? JsonObject
        val runtime = item["state"] as? JsonObject
        return CronJobRow(
            id = item["id"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            name = item["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            scheduleKind = schedule?.get("kind")?.jsonPrimitive?.contentOrNull.orEmpty().lowercase(),
            everyMs = schedule?.get("everyMs")?.jsonPrimitive?.longOrNull,
            cronExpr = schedule?.get("expr")?.jsonPrimitive?.contentOrNull,
            cronTimeZone = schedule?.get("tz")?.jsonPrimitive?.contentOrNull,
            atIso = schedule?.get("at")?.jsonPrimitive?.contentOrNull,
            instruction = payload?.get("text")?.jsonPrimitive?.contentOrNull.orEmpty(),
            targetKind = target?.get("kind")?.jsonPrimitive?.contentOrNull.orEmpty().lowercase(),
            workspacePath = workspace?.get("workspacePath")?.jsonPrimitive?.contentOrNull,
            sessionId = target?.get("sessionId")?.jsonPrimitive?.contentOrNull,
            agentType = launch?.get("agentType")?.jsonPrimitive?.contentOrNull,
            enabled = item["enabled"]?.jsonPrimitive?.booleanOrNull == true,
            nextRunAtMs = runtime?.get("nextRunAtMs")?.jsonPrimitive?.longOrNull,
            lastRunStatus = runtime?.get("lastRunStatus")?.jsonPrimitive?.contentOrNull,
            lastRunFinishedAtMs = runtime?.get("lastRunFinishedAtMs")?.jsonPrimitive?.longOrNull,
            lastError = runtime?.get("lastError")?.jsonPrimitive?.contentOrNull,
            busy = false,
        )
    }

    public companion object {
        internal fun create(scope: CoroutineScope, transport: RemoteCommandTransport): CronJobsStore =
            CronJobsStore(scope, transport)

        /** Host wording for "this build has no cron service". */
        private const val UNSUPPORTED_SERVICE = "cron service is not initialized"

        /** Host wording for "this build does not implement the command at all". */
        private const val UNSUPPORTED_COMMAND = "unknown"

        /** [CronJobsUiState.saveOutcome] words; the surface words them itself. */
        private const val SAVE_CREATED = "created"
        private const val SAVE_UPDATED = "updated"
    }
}
