package com.openbitfun.mobile.core.feature.cron

import com.openbitfun.mobile.core.protocol.*
import com.openbitfun.mobile.core.transport.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CronJobsStoreTest {
    @Test fun listMapsEveryAndCronSchedules() = runTest {
        val host = CronHost()
        host.jobs = """[
            {"id":"job-every","name":"Every minute","schedule":{"kind":"every","everyMs":60000,"anchorMs":1700000000000},
             "payload":{"text":"check"},"enabled":true,
             "target":{"kind":"workspace","workspace":{"workspaceId":"ws-1","workspacePath":"/repo"},
                       "launch":{"agentType":"Standard","modelId":"m-1"}},
             "state":{"nextRunAtMs":1700000060000,"lastRunStatus":"ok","lastRunFinishedAtMs":1700000059000}},
            {"id":"job-cron","name":"Nine daily","schedule":{"kind":"cron","expr":"0 9 * * *","tz":"Asia/Shanghai"},
             "payload":{"text":"report"},"enabled":false,
             "target":{"kind":"session","sessionId":"session-1","workspace":{"workspacePath":"/repo2"}},
             "state":{"nextRunAtMs":1700003600000,"lastRunStatus":"error","lastRunFinishedAtMs":1700000000000,"lastError":"boom"}}
        ]"""
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        val state = store.state.value
        assertEquals(1, host.commands.size)
        assertEquals("host_invoke", host.commands.first().cmd)
        assertEquals("list_cron_jobs", host.commands.first().command)
        assertTrue(host.commands.first().args!!.jsonObject.getValue("request").jsonObject.isEmpty())
        assertFalse(state.loading)
        assertTrue(state.loaded)
        assertFalse(state.failed)
        assertFalse(state.unsupported)
        assertNull(state.errorDetail)
        assertEquals(2, state.jobs.size)

        val every = state.jobs[0]
        assertEquals("job-every", every.id)
        assertEquals("Every minute", every.name)
        assertEquals("every", every.scheduleKind)
        assertEquals(60000L, every.everyMs)
        assertNull(every.cronExpr)
        assertNull(every.cronTimeZone)
        assertNull(every.atIso)
        assertEquals("workspace", every.targetKind)
        assertEquals("/repo", every.workspacePath)
        assertNull(every.sessionId)
        assertEquals("Standard", every.agentType)
        assertTrue(every.enabled)
        assertEquals(1700000060000L, every.nextRunAtMs)
        assertEquals("ok", every.lastRunStatus)
        assertEquals(1700000059000L, every.lastRunFinishedAtMs)
        assertNull(every.lastError)
        assertFalse(every.busy)

        val cron = state.jobs[1]
        assertEquals("job-cron", cron.id)
        assertEquals("cron", cron.scheduleKind)
        assertNull(cron.everyMs)
        assertEquals("0 9 * * *", cron.cronExpr)
        assertEquals("Asia/Shanghai", cron.cronTimeZone)
        assertEquals("session", cron.targetKind)
        assertEquals("/repo2", cron.workspacePath)
        assertEquals("session-1", cron.sessionId)
        assertNull(cron.agentType)
        assertFalse(cron.enabled)
        assertEquals(1700003600000L, cron.nextRunAtMs)
        assertEquals("error", cron.lastRunStatus)
        assertEquals("boom", cron.lastError)
    }

    @Test fun uninitializedCronServiceIsUnsupportedRatherThanFailed() = runTest {
        val host = CronHost()
        host.accepted = false
        host.error = "Cron service is not initialized"
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        val state = store.state.value
        assertTrue(state.unsupported)
        assertFalse(state.failed)
        assertFalse(state.loading)
        assertFalse(state.loaded)
        assertNull(state.errorDetail)
        assertTrue(state.jobs.isEmpty())
    }

    @Test fun ordinaryErrorKeepsHostDetailAndFails() = runTest {
        val host = CronHost()
        host.accepted = false
        host.error = "cron store is unwritable"
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        val state = store.state.value
        assertTrue(state.failed)
        assertFalse(state.unsupported)
        assertFalse(state.loading)
        assertEquals("cron store is unwritable", state.errorDetail)
    }

    @Test fun setEnabledSendsUpdateCommandAndClearsOnlyThatRow() = runTest {
        val host = CronHost()
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        store.dispatch(CronJobsIntent.SetEnabled("job-every", false))
        advanceUntilIdle()

        val command = host.commands.last()
        assertEquals("host_invoke", command.cmd)
        assertEquals("update_cron_job", command.command)
        val request = command.args!!.jsonObject.getValue("request").jsonObject
        assertEquals("job-every", request.getValue("jobId").jsonPrimitive.content)
        assertFalse(request.getValue("enabled").jsonPrimitive.boolean)

        val state = store.state.value
        assertFalse(state.failed)
        assertFalse(state.jobs.single { it.id == "job-every" }.busy)
        assertFalse(state.jobs.single { it.id == "job-every" }.enabled)
        assertFalse(state.jobs.single { it.id == "job-cron" }.busy)
    }

    @Test fun deleteRemovesTheRowAndSendsTheJobId() = runTest {
        val host = CronHost()
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        store.dispatch(CronJobsIntent.Delete("job-cron"))
        advanceUntilIdle()

        val request = host.commands.last().args!!.jsonObject.getValue("request").jsonObject
        assertEquals("delete_cron_job", host.commands.last().command)
        assertEquals("job-cron", request.getValue("jobId").jsonPrimitive.content)
        assertEquals(listOf("job-every"), store.state.value.jobs.map { it.id })
    }

    @Test fun sparseJobsLoadWithoutCrashing() = runTest {
        val host = CronHost()
        host.jobs = """[
            {"id":"job-at","name":"Once","schedule":{"kind":"at","at":"2026-01-01T00:00:00Z"},"enabled":true,
             "target":{"kind":"workspace","workspace":{}}},
            {"id":"job-bare","name":"Bare","schedule":{},"enabled":false,"target":{}}
        ]"""
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        val state = store.state.value
        assertTrue(state.loaded)
        assertFalse(state.failed)
        assertEquals(2, state.jobs.size)

        val once = state.jobs[0]
        assertEquals("at", once.scheduleKind)
        assertEquals("2026-01-01T00:00:00Z", once.atIso)
        assertNull(once.everyMs)
        assertNull(once.cronExpr)
        assertNull(once.nextRunAtMs)
        assertNull(once.lastRunStatus)
        assertNull(once.workspacePath)
        assertTrue(once.enabled)

        val bare = state.jobs[1]
        assertEquals("job-bare", bare.id)
        assertEquals("Bare", bare.name)
        assertEquals("", bare.scheduleKind)
        assertEquals("", bare.targetKind)
        assertNull(bare.everyMs)
        assertNull(bare.cronExpr)
        assertNull(bare.cronTimeZone)
        assertNull(bare.atIso)
        assertNull(bare.workspacePath)
        assertNull(bare.sessionId)
        assertNull(bare.agentType)
        assertFalse(bare.enabled)
        assertNull(bare.nextRunAtMs)
        assertNull(bare.lastRunStatus)
        assertNull(bare.lastRunFinishedAtMs)
        assertNull(bare.lastError)
        assertFalse(bare.busy)
    }

    @Test fun saveCreatesEveryJobWithItsTargetAndPutsTheNewRowFirst() = runTest {
        val host = CronHost()
        host.replies["create_cron_job"] = """{"id":"job-new","name":"Half hourly",
            "schedule":{"kind":"every","everyMs":1800000},"payload":{"text":"archive"},
            "enabled":true,
            "target":{"kind":"workspace","workspace":{"workspacePath":"/repo"},"launch":{"agentType":"Claw"}}}"""
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        store.dispatch(CronJobsIntent.Save(draft(name = "Half hourly", everyMs = 1800000L)))
        advanceUntilIdle()

        val command = host.commands.last()
        assertEquals("host_invoke", command.cmd)
        assertEquals("create_cron_job", command.command)
        val request = command.args!!.jsonObject.getValue("request").jsonObject
        assertFalse("jobId" in request)
        assertFalse("reportPolicy" in request)
        assertEquals("Half hourly", request.getValue("name").jsonPrimitive.content)
        assertEquals("archive yesterday", request.getValue("payload").jsonObject.getValue("text").jsonPrimitive.content)
        assertTrue(request.getValue("enabled").jsonPrimitive.boolean)

        val schedule = request.getValue("schedule").jsonObject
        assertEquals("every", schedule.getValue("kind").jsonPrimitive.content)
        assertEquals(1800000L, schedule.getValue("everyMs").jsonPrimitive.long)

        val target = request.getValue("target").jsonObject
        assertEquals("workspace", target.getValue("kind").jsonPrimitive.content)
        val workspace = target.getValue("workspace").jsonObject
        assertEquals("/repo", workspace.getValue("workspacePath").jsonPrimitive.content)
        assertEquals("ws-1", workspace.getValue("workspaceId").jsonPrimitive.content)
        assertFalse("remoteConnectionId" in workspace)
        assertEquals("Standard", target.getValue("launch").jsonObject.getValue("agentType").jsonPrimitive.content)

        val state = store.state.value
        assertEquals(listOf("job-new", "job-every", "job-cron"), state.jobs.map { it.id })
        assertEquals("created", state.saveOutcome)
        assertNull(state.saveError)
        assertFalse(state.saving)
        assertEquals("Half hourly", state.jobs.first().name)
        assertEquals("archive", state.jobs.first().instruction)
        assertEquals("check", state.jobs.first { it.id == "job-every" }.instruction)
    }

    @Test fun saveSendsTheCronTimeZoneOnlyWhenTheDraftHasOne() = runTest {
        val host = CronHost()
        host.replies["create_cron_job"] = """{"id":"job-nine","name":"Nine daily",
            "schedule":{"kind":"cron","expr":"0 9 * * *","tz":"Asia/Shanghai"},
            "payload":{"text":"report"},"enabled":true,
            "target":{"kind":"workspace","workspace":{"workspacePath":"/repo"},"launch":{"agentType":"Standard"}}}"""
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        store.dispatch(CronJobsIntent.Save(draft(scheduleKind = "cron", everyMs = 0L,
            cronExpr = "0 9 * * *", cronTimeZone = "Asia/Shanghai")))
        advanceUntilIdle()

        assertEquals("create_cron_job", host.commands.last().command)
        val withZone = requestOf(host).getValue("schedule").jsonObject
        assertEquals("cron", withZone.getValue("kind").jsonPrimitive.content)
        assertEquals("0 9 * * *", withZone.getValue("expr").jsonPrimitive.content)
        assertEquals("Asia/Shanghai", withZone.getValue("tz").jsonPrimitive.content)

        store.dispatch(CronJobsIntent.Save(draft(scheduleKind = "cron", everyMs = 0L,
            cronExpr = "0 9 * * *", cronTimeZone = "   ")))
        advanceUntilIdle()

        val withoutZone = requestOf(host).getValue("schedule").jsonObject
        assertEquals("0 9 * * *", withoutZone.getValue("expr").jsonPrimitive.content)
        assertFalse("tz" in withoutZone)
        assertEquals("created", store.state.value.saveOutcome)
        assertFalse(store.state.value.saving)
    }

    @Test fun saveUpdatesTheJobInPlaceWithoutSendingATarget() = runTest {
        val host = CronHost()
        host.replies["update_cron_job"] = """{"id":"job-every","name":"Every half hour",
            "schedule":{"kind":"every","everyMs":1800000},"payload":{"text":"check"},"enabled":true,
            "target":{"kind":"workspace","workspace":{"workspacePath":"/repo"},"launch":{"agentType":"Standard"}}}"""
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()

        store.dispatch(CronJobsIntent.Save(draft(jobId = "job-every", name = "Every half hour", everyMs = 1800000L)))
        advanceUntilIdle()

        assertEquals("update_cron_job", host.commands.last().command)
        val request = requestOf(host)
        assertEquals("job-every", request.getValue("jobId").jsonPrimitive.content)
        assertEquals("Every half hour", request.getValue("name").jsonPrimitive.content)
        assertEquals(1800000L, request.getValue("schedule").jsonObject.getValue("everyMs").jsonPrimitive.long)
        // Retargeting stays on the desktop: an update must never rewrite the target.
        assertFalse("target" in request)

        val state = store.state.value
        assertEquals("updated", state.saveOutcome)
        assertNull(state.saveError)
        assertFalse(state.saving)
        assertEquals(listOf("job-every", "job-cron"), state.jobs.map { it.id })
        assertEquals("Every half hour", state.jobs.first { it.id == "job-every" }.name)
        assertEquals(1800000L, state.jobs.first { it.id == "job-every" }.everyMs)
        assertEquals("report", state.jobs.first { it.id == "job-cron" }.instruction)

        store.dispatch(CronJobsIntent.AcknowledgeSave)
        assertNull(store.state.value.saveOutcome)
    }

    @Test fun failedSaveKeepsTheRowsAndCarriesTheHostsOwnError() = runTest {
        val host = CronHost()
        val store = CronJobsStore.create(this, host)
        store.dispatch(CronJobsIntent.Load)
        advanceUntilIdle()
        val before = store.state.value.jobs

        host.accepted = false
        host.error = "cron store is unwritable"
        store.dispatch(CronJobsIntent.Save(draft()))
        advanceUntilIdle()

        val state = store.state.value
        assertEquals("cron store is unwritable", state.saveError)
        assertNull(state.saveOutcome)
        assertFalse(state.saving)
        assertEquals(before, state.jobs)
        // A save failing says nothing about the list the host already gave us.
        assertFalse(state.failed)
        assertTrue(state.loaded)
    }

    /** A complete draft; each case overrides only what it is about. */
    private fun draft(
        jobId: String? = null,
        name: String = "Archive",
        scheduleKind: String = "every",
        everyMs: Long = 60000L,
        cronExpr: String? = null,
        cronTimeZone: String? = null,
        atIso: String? = null,
    ): CronJobDraft = CronJobDraft(
        jobId = jobId,
        name = name,
        scheduleKind = scheduleKind,
        everyMs = everyMs,
        cronExpr = cronExpr,
        cronTimeZone = cronTimeZone,
        atIso = atIso,
        instruction = "archive yesterday",
        enabled = true,
        workspacePath = "/repo",
        workspaceId = "ws-1",
        remoteConnectionId = null,
        agentType = "Standard",
    )

    private fun requestOf(host: CronHost): JsonObject =
        host.commands.last().args!!.jsonObject.getValue("request").jsonObject

    private class CronHost : RemoteCommandTransport {
        var accepted = true
        var error: String? = null
        /** What a save command answers with; anything not listed keeps the defaults below. */
        val replies = mutableMapOf<String, String>()
        var jobs = """[
            {"id":"job-every","name":"Every minute","schedule":{"kind":"every","everyMs":60000},
             "payload":{"text":"check"},"enabled":true,
             "target":{"kind":"workspace","workspace":{"workspacePath":"/repo"},"launch":{"agentType":"Standard"}}},
            {"id":"job-cron","name":"Nine daily","schedule":{"kind":"cron","expr":"0 9 * * *"},
             "payload":{"text":"report"},"enabled":true,
             "target":{"kind":"session","sessionId":"session-1","workspace":{"workspacePath":"/repo2"}}}
        ]"""
        val commands = mutableListOf<RemoteCommand>()
        override suspend fun <T : CommandStatus> send(deserializer: DeserializationStrategy<T>, command: RemoteCommand, timeoutMs: Long): T {
            commands += command
            val value = command.command?.let { replies[it] } ?: when (command.command) {
                "list_cron_jobs" -> jobs
                "delete_cron_job" -> "true"
                else -> "null"
            }
            val response = buildJsonObject {
                put("resp", "host_invoke_result"); put("ok", accepted)
                put("value", RelayJson.parseToJsonElement(value))
                error?.let { put("error", it) }
            }
            return RelayJson.decodeFromJsonElement(deserializer, response)
        }
    }
}
