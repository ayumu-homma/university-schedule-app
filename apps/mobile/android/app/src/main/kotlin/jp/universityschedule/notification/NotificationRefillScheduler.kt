package jp.universityschedule.notification

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.os.PersistableBundle
import android.os.Process
import org.json.JSONObject
import java.util.UUID

/** Owns the two and only two OS jobs used by ordinary notification refill. */
internal object NotificationRefillScheduler {
    private const val FIELD_RUNNING = "running"
    private const val FIELD_TOKEN = "runToken"
    private const val FIELD_ATTEMPTS = "attempts"
    private const val FIELD_NEXT_RUN = "nextRunAtMs"
    private const val FIELD_LAST_ERROR = "lastError"
    private const val FIELD_PID = "pid"
    private const val FIELD_STARTED_AT = "startedAtMs"
    private const val FIELD_COALESCED = "coalesced"
    private const val FIELD_INVALIDATED = "invalidated"
    private const val FIELD_COALESCED_KIND = "coalescedKind"
    private const val FIELD_RELEASE_PENDING = "releasePending"
    private const val FIELD_RETRY = "retry"
    private const val MAX_RETRY_MS = 30L * 60L * 1000L
    private const val MIN_COVERAGE_DELAY_MS = 60L * 1000L
    private const val KIND_SOURCE = "source"
    private const val KIND_COVERAGE = "coverage"
    private const val EXTRA_DUE_AT_MS = "notification_refill_due_at_ms"
    internal const val MAX_ATTEMPTS = 3

    fun ensureDaily(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        if (scheduler.allPendingJobs.none { it.id == NotificationRefillContract.DAILY_JOB_ID }) {
            val info = JobInfo.Builder(
                NotificationRefillContract.DAILY_JOB_ID,
                ComponentName(context, NotificationRefillJobService::class.java),
            )
                .setPersisted(true)
                .setPeriodic(24L * 60L * 60L * 1000L)
                .setBackoffCriteria(15L * 60L * 1000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
                .build()
            scheduler.schedule(info)
        }
    }

    /** Coalesces wakeups. An executing refill is allowed to finish; a second
     * request is represented by the durable nextRunAtMs state. */
    fun requestRefill(context: Context, reason: String) {
        ensureDaily(context)
        synchronized(this) {
            val state = readState(context)
            val now = System.currentTimeMillis()
            if (state.optBoolean(FIELD_RUNNING, false)) {
                state.put(FIELD_NEXT_RUN, minOf(state.optLong(FIELD_NEXT_RUN, Long.MAX_VALUE), now))
                state.put(FIELD_COALESCED, true)
                state.put(FIELD_COALESCED_KIND, KIND_SOURCE)
                state.put(FIELD_LAST_ERROR, "coalesced:$reason")
                persistState(context, state)
                return
            }
            val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
            val pending = scheduler.allPendingJobs.firstOrNull { it.id == NotificationRefillContract.REFILL_JOB_ID }
            // JobScheduler replaces a pending job with the same fixed id. A
            // future coverage wakeup therefore gets expedited by this source
            // request, while an executing run is protected by the state check
            // above and is never replaced.
            val pendingDue = pendingDueAt(pending)
            if (pending != null && pendingDue <= now) return
            val info = oneShot(context, 0L, now)
            if (scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS) {
                state.put(FIELD_NEXT_RUN, now).put(FIELD_LAST_ERROR, JSONObject.NULL)
                    .put(FIELD_ATTEMPTS, 0)
                persistState(context, state)
            }
        }
    }

    internal fun scheduleCoverage(context: Context, atMs: Long, reason: String) {
        ensureDaily(context)
        val now = System.currentTimeMillis()
        // Coverage wakeups are deliberately suppressed when they are already
        // due or inside the one-minute guard. The daily safety job and the
        // next foreground/source request provide recovery; only explicit
        // source requests are allowed to enqueue an immediate one-shot.
        if (atMs <= now + MIN_COVERAGE_DELAY_MS) return
        val delay = atMs - now
        synchronized(this) {
            val state = readState(context)
            if (state.optBoolean(FIELD_RUNNING, false)) {
                val prior = if (state.optBoolean(FIELD_COALESCED, false)) {
                    state.optLong(FIELD_NEXT_RUN, Long.MAX_VALUE)
                } else {
                    Long.MAX_VALUE
                }
                state.put(FIELD_COALESCED, true)
                    .put(FIELD_COALESCED_KIND,
                        if (state.optString(FIELD_COALESCED_KIND) == KIND_SOURCE) KIND_SOURCE else KIND_COVERAGE)
                    .put(FIELD_NEXT_RUN, minOf(prior, atMs))
                persistState(context, state)
                return
            }
            val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
            val pending = scheduler.allPendingJobs.firstOrNull { it.id == NotificationRefillContract.REFILL_JOB_ID }
            // Keep the earliest due time when several future projections are
            // requested. Scheduling the same id is a replacement only while
            // the job is pending; running jobs were returned above.
            val requestedDue = atMs
            val pendingDue = pendingDueAt(pending)
            if (pending != null && pendingDue <= requestedDue) return
            val info = oneShot(context, delay, requestedDue)
            if (scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS) {
                val prior = state.optLong(FIELD_NEXT_RUN, Long.MAX_VALUE)
                state.put(FIELD_NEXT_RUN, minOf(prior.takeIf { it > 0L } ?: atMs, atMs))
                    .put(FIELD_LAST_ERROR, "scheduled:$reason")
                persistState(context, state)
            }
        }
    }

    internal fun begin(context: Context, jobId: Int, requestedToken: String?): String? = synchronized(this) {
        if (jobId != NotificationRefillContract.DAILY_JOB_ID &&
            jobId != NotificationRefillContract.REFILL_JOB_ID
        ) return@synchronized null
        val state = readState(context)
        val running = state.optBoolean(FIELD_RUNNING, false)
        val stale = running && (
            state.optInt(FIELD_PID, -1) != Process.myPid() ||
                System.currentTimeMillis() - state.optLong(FIELD_STARTED_AT, 0L) > 2L * 60L * 1000L
            )
        val releasePending = state.optBoolean(FIELD_RELEASE_PENDING, false)
        // A release marker means the previous JobService already acknowledged
        // its execution (or crashed in that narrow window). It is safe for the
        // next scheduler entry to recover it even when the process/PID is the
        // same; without this branch a failed replacement schedule could leave
        // the fixed slot occupied until the two-minute stale timeout.
        if (running && !stale && !releasePending) return@synchronized null
        // A process can die after finish() records the durable release marker
        // but before JobService acknowledges/releases the fixed job. The next
        // scheduler entry consumes that marker. Coverage due times remain
        // attached to the new run; an immediate source request is represented
        // by this very entry and must not be replayed after it succeeds.
        val pendingKind = state.optString(FIELD_COALESCED_KIND)
        if (releasePending && pendingKind == KIND_SOURCE) {
            state.put(FIELD_COALESCED, false).put(FIELD_COALESCED_KIND, JSONObject.NULL)
                .put(FIELD_NEXT_RUN, System.currentTimeMillis())
        }
        state.put(FIELD_RELEASE_PENDING, false).put(FIELD_RETRY, false)
        // JobScheduler retries can reuse the same PersistableBundle. A fresh
        // execution token prevents a late callback from an older process from
        // publishing into the new run.
        // The JobInfo token identifies the scheduled request, while this new
        // token identifies this execution. Never reuse either token across a
        // process restart or JobScheduler retry.
        @Suppress("UNUSED_VARIABLE") val ignoredRequestedToken = requestedToken
        val now = System.currentTimeMillis()
        val previousDue = state.optLong(FIELD_NEXT_RUN, 0L)
        val preserveCoalesced = state.optBoolean(FIELD_COALESCED, false) &&
            (state.optString(FIELD_COALESCED_KIND) == KIND_SOURCE || previousDue > now)
        val token = UUID.randomUUID().toString()
        state.put(FIELD_RUNNING, true)
            .put(FIELD_TOKEN, token)
            .put(FIELD_PID, Process.myPid())
            .put(FIELD_STARTED_AT, now)
            .put(FIELD_COALESCED, preserveCoalesced)
            .put(FIELD_COALESCED_KIND, if (preserveCoalesced) state.optString(FIELD_COALESCED_KIND) else JSONObject.NULL)
            .put(FIELD_INVALIDATED, false)
            .put(FIELD_ATTEMPTS, state.optInt(FIELD_ATTEMPTS, 0) + 1)
            .put(FIELD_NEXT_RUN, if (preserveCoalesced) previousDue else now)
        persistState(context, state)
        token
    }

    /** Records completion and returns whether JobScheduler may retry it.
     * The fixed job remains logically occupied until releaseAfterFinish runs
     * after JobService.jobFinished, so no source request can replace it in the
     * acknowledgement window. */
    internal fun finish(context: Context, token: String, success: Boolean, error: String? = null): Boolean {
        var retry = false
        synchronized(this) {
            val state = readState(context)
            if (!state.optBoolean(FIELD_RUNNING, false) ||
                state.optBoolean(FIELD_INVALIDATED, false) ||
                state.optString(FIELD_TOKEN) != token
            ) return false
            val attempts = state.optInt(FIELD_ATTEMPTS, 1)
            val terminalFailure = !success && attempts >= MAX_ATTEMPTS
            val keepFutureCoverage = !success && state.optBoolean(FIELD_COALESCED, false) &&
                state.optString(FIELD_COALESCED_KIND) == KIND_COVERAGE &&
                state.optLong(FIELD_NEXT_RUN, 0L) > System.currentTimeMillis()
            val nextRetryAt = System.currentTimeMillis() + retryDelay(attempts)
            state.put(FIELD_RELEASE_PENDING, true)
                .put(FIELD_RETRY, !success && !terminalFailure)
                .put(
                    FIELD_NEXT_RUN,
                    when {
                        success && state.optBoolean(FIELD_COALESCED, false) -> state.optLong(FIELD_NEXT_RUN, 0L)
                        keepFutureCoverage -> state.optLong(FIELD_NEXT_RUN, 0L)
                        success || terminalFailure -> 0L
                        else -> nextRetryAt
                    },
                )
            if (success) state.put(FIELD_ATTEMPTS, 0).put(FIELD_LAST_ERROR, JSONObject.NULL)
            else {
                state.put(
                    FIELD_LAST_ERROR,
                    if (terminalFailure) "max_attempts:${error?.take(220) ?: "background refill failed"}"
                    else error?.take(256) ?: "background refill failed",
                )
                retry = !terminalFailure
            }
            persistState(context, state)
        }
        return retry
    }

    /** Releases the fixed job after jobFinished and acknowledges its durable
     * pending marker only after a replacement wakeup has been accepted. */
    internal fun releaseAfterFinish(context: Context, token: String) = synchronized(this) {
        val state = readState(context)
        if (state.optString(FIELD_TOKEN) != token || !state.optBoolean(FIELD_RELEASE_PENDING, false)) return@synchronized
        val now = System.currentTimeMillis()
        val kind = state.optString(FIELD_COALESCED_KIND)
        val dueAt = state.optLong(FIELD_NEXT_RUN, 0L)
        val retry = state.optBoolean(FIELD_RETRY, false)
        val needsFutureSchedule = kind == KIND_COVERAGE && dueAt > now + MIN_COVERAGE_DELAY_MS
        val needsSourceSchedule = kind == KIND_SOURCE
        val shouldSchedule = !retry && (needsFutureSchedule || needsSourceSchedule)
        val scheduler = context.getSystemService(JobScheduler::class.java)
        var accepted = true
        if (shouldSchedule && scheduler != null) {
            val pending = scheduler.allPendingJobs.firstOrNull { it.id == NotificationRefillContract.REFILL_JOB_ID }
            val pendingDue = pendingDueAt(pending)
            // A due-now entry is commonly the just-finished fixed job and
            // cannot satisfy a coalesced follow-up. Retain an already pending
            // future entry only when its persisted absolute due is earlier.
            val pendingSatisfies = pending != null &&
                pendingDue > now + MIN_COVERAGE_DELAY_MS && pendingDue <= dueAt
            if (!pendingSatisfies) {
                val delay = if (needsSourceSchedule) 0L else (dueAt - now).coerceAtLeast(0L)
                accepted = scheduler.schedule(oneShot(context, delay, if (needsSourceSchedule) now else dueAt)) ==
                    JobScheduler.RESULT_SUCCESS
            }
        }
        if (accepted) {
            val retainCoverageForRetry = retry && kind == KIND_COVERAGE && dueAt > now
            state.put(FIELD_RUNNING, false)
                .put(FIELD_RELEASE_PENDING, false)
                .put(FIELD_RETRY, false)
                .put(FIELD_INVALIDATED, false)
                .put(FIELD_COALESCED, retainCoverageForRetry)
                .put(FIELD_COALESCED_KIND, if (retainCoverageForRetry) KIND_COVERAGE else JSONObject.NULL)
                .put(FIELD_NEXT_RUN, if (retainCoverageForRetry) dueAt else 0L)
            persistState(context, state)
        }
    }

    internal fun invalidate(context: Context, token: String) = synchronized(this) {
        val state = readState(context)
        if (state.optString(FIELD_TOKEN) == token) {
            // Keep the fixed id logically occupied until ActiveRun.cancel has
            // linearized. This blocks a source request from replacing the
            // still-executing JobScheduler entry while invalidating its token
            // for the publisher fence.
            state.put(FIELD_INVALIDATED, true)
            persistState(context, state)
        }
    }

    internal fun releaseAfterStop(context: Context, token: String) = synchronized(this) {
        val state = readState(context)
        if (state.optString(FIELD_TOKEN) == token && state.optBoolean(FIELD_INVALIDATED, false)) {
            state.put(FIELD_RUNNING, false).put(FIELD_INVALIDATED, false)
                .put(FIELD_RELEASE_PENDING, state.optBoolean(FIELD_RELEASE_PENDING, false))
            persistState(context, state)
        }
    }

    internal fun retryAfterStop(context: Context): Boolean = synchronized(this) {
        readState(context).optInt(FIELD_ATTEMPTS, 0) < MAX_ATTEMPTS
    }

    internal fun cancelRefill(context: Context) = synchronized(this) {
        context.getSystemService(JobScheduler::class.java)?.cancel(NotificationRefillContract.REFILL_JOB_ID)
        val state = readState(context)
        state.put(FIELD_RUNNING, false).put(FIELD_INVALIDATED, false)
            .put(FIELD_RELEASE_PENDING, false).put(FIELD_RETRY, false)
            .put(FIELD_COALESCED, false).put(FIELD_COALESCED_KIND, JSONObject.NULL).put(FIELD_NEXT_RUN, 0L)
        persistState(context, state)
    }

    internal fun stateForTest(context: Context): JSONObject = synchronized(this) { readState(context) }

    internal fun ownsActiveRun(context: Context, token: String): Boolean = synchronized(this) {
        val state = readState(context)
        state.optBoolean(FIELD_RUNNING, false) &&
            !state.optBoolean(FIELD_INVALIDATED, false) && state.optString(FIELD_TOKEN) == token
    }

    /**
     * Short publication fence shared by foreground and headless writers.
     *
     * Callers must do all database reads/inserts before entering this gate;
     * only the final validation plus SQLite transaction-success/end sequence
     * belongs in [block]. Holding this mutex linearizes that short commit with
     * [invalidate], so a stopped background run either commits before stop or
     * is rejected without entering the block.
     */
    internal fun <T> withActiveRun(
        context: Context,
        token: String?,
        block: () -> T,
    ): T? = synchronized(this) {
        if (token != null) {
            val state = readState(context)
            if (!state.optBoolean(FIELD_RUNNING, false) ||
                state.optBoolean(FIELD_INVALIDATED, false) ||
                state.optString(FIELD_TOKEN) != token
            ) return@synchronized null
        }
        block()
    }

    private fun retryDelay(attempts: Int): Long =
        (15L * 60L * 1000L * (1L shl attempts.coerceIn(0, 5))).coerceAtMost(MAX_RETRY_MS)

    private fun oneShot(context: Context, delayMs: Long, dueAtMs: Long): JobInfo =
        JobInfo.Builder(
            NotificationRefillContract.REFILL_JOB_ID,
            ComponentName(context, NotificationRefillJobService::class.java),
        )
            .setMinimumLatency(delayMs.coerceAtLeast(0L))
            .setOverrideDeadline(delayMs.coerceAtLeast(0L) + 5L * 60L * 1000L)
            .setBackoffCriteria(15L * 60L * 1000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .setExtras(PersistableBundle().apply {
                putString(NotificationRefillContract.EXTRA_RUN_TOKEN, UUID.randomUUID().toString())
                putInt(NotificationRefillContract.EXTRA_JOB_ID, NotificationRefillContract.REFILL_JOB_ID)
                putLong(EXTRA_DUE_AT_MS, dueAtMs)
            })
            .build()

    private fun pendingDueAt(job: JobInfo?): Long {
        val extras = job?.extras ?: return Long.MAX_VALUE
        return if (extras.containsKey(EXTRA_DUE_AT_MS)) extras.getLong(EXTRA_DUE_AT_MS) else Long.MAX_VALUE
    }

    private fun readState(context: Context): JSONObject = runCatching {
        JSONObject(context.getSharedPreferences(NotificationRefillContract.PREFS, Context.MODE_PRIVATE)
            .getString(NotificationRefillContract.JOB_STATE_KEY, "{}") ?: "{}")
    }.getOrDefault(JSONObject())

    private fun persistState(context: Context, state: JSONObject) {
        check(context.getSharedPreferences(NotificationRefillContract.PREFS, Context.MODE_PRIVATE)
            .edit().putString(NotificationRefillContract.JOB_STATE_KEY, state.toString()).commit())
    }
}
