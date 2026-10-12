package jp.universityschedule.notification

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.app.MainActivity
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.net.URLEncoder

data class LocalNotificationCapabilities(
    val permission: String,
    val exactAlarm: String,
    val scheduledCount: Int,
    val blockedReason: String? = null,
    val channel: String = "unknown",
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "permission" to permission,
        "exactAlarm" to exactAlarm,
        "scheduledCount" to scheduledCount,
        "blockedReason" to blockedReason,
        "channel" to channel,
    )
}

/** Durable desired projection and AlarmManager coordinator for ordinary reminders. */
object LocalNotificationCoordinator {
    private const val REGISTRY_VERSION = 2
    private const val REGISTRY_KEY = "registry"
    private const val REGISTRY_REGION = "region"
    private const val REGISTRY_OWNER = "ownerHash"
    private const val REGISTRY_TOKEN = "activationToken"
    private const val REGISTRY_GENERATION = "generation"
    private const val REGISTRY_PLANS = "plans"
    private const val REGISTRY_COVERED_UNTIL = "coveredUntilMs"
    private const val REGISTRY_FIRST_UNCOVERED = "firstUncoveredAtMs"
    private const val REGISTRY_CANDIDATE_COUNT = "candidateCount"
    private const val REGISTRY_BUCKET_COUNT = "bucketCount"
    private const val REGISTRY_DEFERRED_COUNT = "deferredCount"
    private const val REGISTRY_NEXT_REFILL = "nextRefillAtMs"
    private const val REGISTRY_INBOX = "inbox"
    private const val FIELD_STATE = "state"
    private const val FIELD_DELIVERED = "delivered"
    private const val FIELD_RETRIES = "retries"
    private const val FIELD_NEXT_ATTEMPT = "nextAttemptAtMs"
    private const val FIELD_RETRY_KIND = "retryKind"
    private const val STATE_DEFERRED = "deferred"
    private const val STATE_SCHEDULED = "scheduled"
    private const val STATE_DELIVERED = "delivered"
    private const val STATE_INVALID = "invalid"
    private const val STATE_RETRY_PENDING = "retry_pending"
    private const val MAX_OS_ALARMS = 200
    private const val HORIZON_MS = 45L * 24L * 60L * 60L * 1000L
    private const val MAX_RETRIES = 4
    private const val MIN_RETRY_MS = 15_000L
    private const val MAX_RETRY_MS = 5L * 60L * 1000L
    private const val NOTIFICATION_ID = LOCAL_NOTIFICATION_ID
    private const val RECEIPT_PREFS = "ordinary_notification_receipts_v1"
    private const val RECEIPT_KEY = "logicalIds"
    private const val RECEIPT_VERSION = "v1"
    private const val SUMMARY_TAG_PREFIX = "ordinary-summary:"
    private const val REFILL_CONTEXT_PREFS = "ordinary_notification_refill_context_v1"
    private const val REFILL_DATABASE_PATH = "databasePath"
    private const val REFILL_OWNER_USER_ID = "ownerUserId"
    @PublishedApi
    internal val registryLock = Any()
    // Unit tests may supply a real SQLite connection when Robolectric's host
    // path cannot be opened by Android's native SQLite. Production leaves this
    // null, so the strict scoped path below remains the only resolver.
    internal var scopedDatabaseProviderForTests: ((Context, String) -> CanonicalSqliteDatabase)? = null
    internal var scopedDatabaseFactoryForTests: ((Context, String, File) -> CanonicalSqliteDatabase)? = null

    /** Receiver/tap paths use scope → registry → SQLite lock ordering. */
    internal inline fun <T> withRegistryLock(block: () -> T): T = synchronized(registryLock, block)

    // Kept package-visible for native contract tests; production callers use
    // the parsed-plan path below.
    internal fun identityForTest(scope: NativeScope, planId: String, kind: String, source: String, occurrenceAtMs: Long, rule: String): String =
        "v1|r=${scope.regionId}|o=${scope.ownerHash}|g=${scope.generation}|s=${component(scope.activationToken.orEmpty())}|id=${component(planId)}|k=${component(kind)}|e=${component(source)}|t=$occurrenceAtMs|rule=${component(rule)}"

    fun reconcile(
        context: Context,
        @Suppress("UNUSED_PARAMETER") databasePath: String,
        scope: NativeScope,
        @Suppress("UNUSED_PARAMETER") plans: JSONArray,
    ): LocalNotificationCapabilities {
        requireValidScope(scope)
        val now = NotificationTime.now()
        val database = openScopedDatabase(context, scope.regionId!!)
        try {
            ensureSchema(database)
            return synchronized(NativeScopeFence) {
                check(NativeScopeFence.matchesExpected(context, scope)) { "ordinary notification scope changed" }
                synchronized(registryLock) {
                // Hold the SQLite writer reservation while reconstructing the
                // desired registry from committed rows. The caller's plans
                // argument is only a wakeup hint and is deliberately ignored.
                database.beginTransactionNonExclusive()
                try {
                val certifiedSourceEpoch = currentSourceEpoch(database)
                if (!projectionIsFresh(database, scope, certifiedSourceEpoch)) {
                    NotificationRefillScheduler.requestRefill(context, "source-changed")
                    val existing = readRoot(preferences(context))
                    val status = if (scopeMatches(existing, scope)) reserveBuckets(context, scope, existing)
                        else capabilityStatus(context)
                    return@synchronized status.copy(blockedReason = "stale_projection")
                }
                val desired = readCommittedPlans(database, scope, certifiedSourceEpoch)
                val prefs = preferences(context)
                val oldRoot = readRoot(prefs)
                migrateLegacyReceipts(context, oldRoot)
                val oldPlans = allPlans(oldRoot)
                val oldScopeMatches = scopeMatches(oldRoot, scope)
                val prior = if (oldScopeMatches) oldPlans else emptyMap()
                val root = JSONObject()
                    .put("version", REGISTRY_VERSION)
                    .put(REGISTRY_REGION, scope.regionId)
                    .put(REGISTRY_OWNER, scope.ownerHash)
                    .put(REGISTRY_TOKEN, scope.activationToken)
                    .put(REGISTRY_GENERATION, scope.generation)
                    .put(
                        REGISTRY_INBOX,
                        if (oldScopeMatches) {
                            oldRoot.optJSONArray(REGISTRY_INBOX)?.let { JSONArray(it.toString()) } ?: JSONArray()
                        } else JSONArray(),
                    )
                val nextPlans = JSONObject()
                desired.forEach { (id, plan) ->
                    val old = prior[id]
                    val unchanged = old != null && samePlan(old, plan)
                    val entry = if (unchanged) mergePlan(old!!, plan) else JSONObject(plan.toString())
                        .put(FIELD_STATE, initialState(plan, now))
                        .put(FIELD_DELIVERED, false)
                        .put(FIELD_RETRIES, 0)
                    if (isReceiptRecorded(context, scope, plan.optString("logicalId", plan.getString("planId")))) {
                        entry.put(FIELD_STATE, if (old?.optString(FIELD_STATE) == "represented_in_summary") "represented_in_summary" else STATE_DELIVERED)
                            .put(FIELD_DELIVERED, true)
                            .put("suppressedByReceipt", true)
                    }
                    // Receiver/cancellation code needs the active scope even
                    // when this registry is later recovered after a reboot.
                    entry.put("regionId", scope.regionId)
                        .put("ownerHash", scope.ownerHash)
                        .put("activationToken", scope.activationToken)
                        .put("generation", scope.generation)
                    nextPlans.put(id, entry)
                }
                // Keep cancellation tombstones until the corresponding OS
                // object has definitely been cancelled. This survives a
                // process death between registry publication and cancellation.
                val tombstones = linkedMapOf<String, JSONObject>()
                oldPlans.forEach { (id, old) ->
                    if (old.optString(FIELD_STATE) == "cancel_pending") return@forEach
                    val fresh = desired[id]
                    if (!oldScopeMatches || fresh == null || !samePlan(old, fresh)) {
                        tombstones["__cancel__${id}|${old.optString("fingerprint")}"] = JSONObject(old.toString()).put(FIELD_STATE, "cancel_pending")
                    }
                }
                oldPlans.filterValues { it.optString(FIELD_STATE) == "cancel_pending" }
                    .forEach { (id, entry) -> nextPlans.put(id, entry) }
                tombstones.forEach { (id, entry) -> nextPlans.put(id, entry) }
                root.put(REGISTRY_PLANS, nextPlans)

                // Registry first, OS effects second.  Stale OS intents are
                // harmless because the receiver performs the DB/scope fence.
                check(prefs.edit().putString(REGISTRY_KEY, root.toString()).commit())
                val changedOrRemoved = oldPlans.filter { (id, old) ->
                    if (old.optString(FIELD_STATE) == "cancel_pending") false
                    else {
                        val fresh = desired[id]
                        val sameBucketRemains = fresh == null && desired.values.any {
                            it.optLong("triggerAtMs", Long.MIN_VALUE) == old.optLong("triggerAtMs", Long.MAX_VALUE)
                        }
                        (fresh == null && !sameBucketRemains) || (fresh != null && !samePlan(old, fresh))
                    }
                }
                changedOrRemoved.values.forEach { cancelAlarmAndPosted(context, it) }
                if (!oldScopeMatches) oldPlans.values.forEach { cancelAlarmAndPosted(context, it) }
                oldPlans.filterValues { it.optString(FIELD_STATE) == "cancel_pending" }
                    .values.forEach { cancelAlarmAndPosted(context, it) }
                (tombstones.keys + oldPlans.filterValues { it.optString(FIELD_STATE) == "cancel_pending" }.keys)
                    .forEach { nextPlans.remove(it) }
                persistRootPlans(prefs, root, nextPlans)

                reserveBuckets(context, scope, root, oldPlans.values.toList())
                } finally {
                    database.endTransaction()
                }
            }
            }
        } finally {
            closeScopedDatabase(database)
        }
    }

    /** All AlarmManager wakeups, including retries, share one 200-bucket budget.
     * Call only under scope -> registry. Durable intent is saved before OS calls;
     * acknowledgements are saved afterward, so replay only updates stable PIs. */
    private fun reserveBuckets(
        context: Context,
        scope: NativeScope,
        root: JSONObject,
        previous: List<JSONObject> = allPlans(root).values.map { JSONObject(it.toString()) },
    ): LocalNotificationCapabilities {
        val now = NotificationTime.now()
        val prefs = preferences(context)
        val status = capabilityStatus(context)
        val plans = root.getJSONObject(REGISTRY_PLANS)
        val candidates = allPlans(root).values.filter {
            !it.optBoolean(FIELD_DELIVERED) && eligibleForScheduling(it, now)
        }.sortedWith(compareBy({ wakeAt(it, now) }, { it.getString("identity") }))
        val buckets = candidates.groupBy { wakeAt(it, now) }.toSortedMap()
        val selected = if (status.blockedReason == null) buckets.entries.take(MAX_OS_ALARMS) else emptyList()
        val selectedTimes = selected.map { it.key }.toSet()
        allPlans(root).values.forEach {
            val awaitingDueDelivery = status.blockedReason == null && awaitingDueDelivery(it, now)
            if (!it.optBoolean(FIELD_DELIVERED) && it.optString(FIELD_STATE) != "cancel_pending" && !awaitingDueDelivery) {
                it.put(FIELD_STATE, STATE_DEFERRED)
            }
        }
        persistRootPlans(prefs, root, plans)
        previous.forEach { cancelLegacyAlarm(context, it) }
        // Cancel only obsolete wakeup times. A selected same-time bucket is
        // reinstalled below even if a former representative was deleted.
        previous.filter { it.has("identity") && it.has("ownerUserId") }
            .distinctBy { it.optLong("scheduledAtMs", it.optLong("triggerAtMs")) }
            .filter { it.optLong("scheduledAtMs", it.optLong("triggerAtMs")) !in selectedTimes }
            .forEach { cancelAlarmOnly(context, it) }
        val successful = mutableSetOf<Long>()
        selected.forEach { bucket ->
            try {
                // A previously acknowledged due wakeup may still be waiting
                // for OS delivery. Keep its slot/PI until handled or expired;
                // never cancel it just to admit a future bucket.
                if (bucket.key > now) scheduleAlarm(context, scope, bucket.value.first(), bucket.key)
                bucket.value.forEach { it.put(FIELD_STATE, STATE_SCHEDULED).put("scheduledAtMs", bucket.key) }
                successful += bucket.key
            } catch (_: RuntimeException) {
                // Pending intent and OS acknowledgement remain distinct.
            }
        }
        val uncovered = buckets.keys.filter { it !in successful }
        val firstUncovered = uncovered.firstOrNull() ?: 0L
        val covered = successful.filter { firstUncovered == 0L || it < firstUncovered }.maxOrNull() ?: now
        val nextRefill = if (firstUncovered == 0L) now + 24L * 60L * 60L * 1000L
            else minOf(now + 24L * 60L * 60L * 1000L, (firstUncovered - 60L * 60L * 1000L).coerceAtLeast(now + 15L * 60L * 1000L))
        root.put(REGISTRY_CANDIDATE_COUNT, candidates.size)
            .put(REGISTRY_BUCKET_COUNT, buckets.size)
            .put(REGISTRY_DEFERRED_COUNT, candidates.count { it.optString(FIELD_STATE) != STATE_SCHEDULED })
            .put(REGISTRY_COVERED_UNTIL, covered)
            .put(REGISTRY_FIRST_UNCOVERED, firstUncovered)
            .put(REGISTRY_NEXT_REFILL, nextRefill)
        persistRootPlans(prefs, root, plans)
        NotificationRefillScheduler.ensureDaily(context)
        if (firstUncovered != 0L && status.blockedReason == null) {
            NotificationRefillScheduler.scheduleCoverage(context, nextRefill, "coverage")
        }
        return status.copy(scheduledCount = successful.size,
            blockedReason = status.blockedReason ?: if (selected.isNotEmpty() && successful.size < selected.size) "os_schedule_failed" else null)
    }

    private fun wakeAt(entry: JSONObject, now: Long): Long =
        if (awaitingDueDelivery(entry, now)) entry.optLong("scheduledAtMs", entry.getLong("triggerAtMs"))
        else if (entry.optInt(FIELD_RETRIES) > 0 && entry.optString(FIELD_RETRY_KIND).isNotBlank() &&
            entry.optLong(FIELD_NEXT_ATTEMPT) > now && entry.optLong(FIELD_NEXT_ATTEMPT) < entry.getLong("occurrenceAtMs"))
            entry.optLong(FIELD_NEXT_ATTEMPT, entry.getLong("triggerAtMs"))
        else entry.getLong("triggerAtMs")

    private fun cancelAlarmOnly(context: Context, entry: JSONObject) {
        if (!entry.has("identity") || !entry.has("ownerUserId")) return
        val scope = NativeScope(entry.optString("regionId"), entry.optString("ownerHash"),
            entry.optString("activationToken"), entry.optLong("generation"), true)
        val pending = broadcastPendingIntent(context, receiverIntent(context, scope, entry), entry, true) ?: return
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending)
        pending.cancel()
    }

    private fun cancelLegacyAlarm(context: Context, entry: JSONObject) {
        if (!entry.has("identity")) return
        val legacy = Intent(context, LocalNotificationReceiver::class.java).apply {
            action = LOCAL_NOTIFICATION_ACTION
            data = identityUri(entry.getString("identity"))
        }
        val pending = PendingIntent.getBroadcast(context, 0, legacy,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE) ?: return
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending)
        pending.cancel()
    }

    /** Publish a complete planner result with a source/projection CAS. The
     * method is shared by foreground and headless callers; callers must pass
     * the previous projection epoch, never a value read after planning. */
    fun publishFromBackground(
        context: Context,
        scope: NativeScope,
        raw: JSONObject,
        runToken: String? = null,
    ): Boolean {
        requireValidScope(scope)
        val request = runCatching {
            NotificationRefillRequest.fromJson(raw)
        }.getOrNull() ?: return false
        if (!request.scope.matches(scope) || request.context.ownerUserId.let { ownerHash(it) } != scope.ownerHash) return false
        if (runToken != null && !NotificationRefillScheduler.ownsActiveRun(context, runToken)) return false
        // Capture the validated canonical owner/path before the first native
        // open or writer reservation. A busy failure can happen at BEGIN, so
        // waiting until reconciliation would leave the headless retry without
        // the context it needs. Keep this write inside the same scope fence
        // used by the publication boundary and reject paths before persisting.
        persistValidatedRefillContext(context, scope, request, raw)
        val database = openScopedDatabase(context, scope.regionId!!)
        val normalized = JSONArray()
        try {
            synchronized(NativeScopeFence) {
                if (!NativeScopeFence.matchesExpected(context, scope)) return false
                synchronized(registryLock) {
                    if (runToken != null && !NotificationRefillScheduler.ownsActiveRun(context, runToken)) return false
                    database.beginTransactionNonExclusive()
                    try {
                        val source = currentSourceEpoch(database)
                        val currentProjection = projectionEpoch(database, request.context.ownerUserId)
                        if (source != request.sourceEpoch || currentProjection != request.expectedProjectionEpoch) return false
                        validateContextIfPresent(database, request.context)
                        for (index in 0 until request.plans.length()) {
                            val parsed = parsePlan(request.plans.optJSONObject(index) ?: error("invalid notification plan"), scope)
                                ?: error("invalid notification plan")
                            parsed.put("sourceEpoch", source)
                                .put("projectionEpoch", currentProjection + 1)
                            normalized.put(parsed)
                        }
                        val now = request.planningNowMs
                        val capped = (0 until normalized.length()).map { normalized.getJSONObject(it) }
                            .filter { it.optString("reason") == "eligible" && it.getLong("triggerAtMs") > now }
                            .map { it.getLong("triggerAtMs") }.distinct().size > MAX_OS_ALARMS
                        database.delete("local_notification_occurrences", "owner_user_id = ?", arrayOf(request.context.ownerUserId))
                        for (index in 0 until normalized.length()) {
                            val plan = normalized.getJSONObject(index)
                            database.execSQL(
                                "INSERT INTO local_notification_occurrences " +
                                    "(id, owner_user_id, kind, source_entity_id, occurrence_at, trigger_at, target_path, title, body, rule, fingerprint, source_epoch, projection_epoch, status, reason, updated_at) " +
                                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'desired', ?, ?)",
                                arrayOf<Any?>(
                                    plan.getString("planId"), request.context.ownerUserId,
                                    plan.getString("kind"), plan.getString("sourceEntityId"),
                                    plan.getLong("occurrenceAtMs"), plan.getLong("triggerAtMs"),
                                    plan.getString("targetPath"), plan.getString("title"), plan.getString("body"),
                                    plan.getString("rule"), plan.getString("fingerprint"), source, currentProjection + 1,
                                    plan.optString("reason", "eligible"), now,
                                ),
                            )
                        }
                        database.execSQL(
                            "INSERT INTO local_notification_projection_states " +
                                "(owner_user_id, source_epoch, projection_epoch, capped, blocked_reason, planned_at) VALUES (?, ?, ?, ?, NULL, ?) " +
                                "ON CONFLICT(owner_user_id) DO UPDATE SET source_epoch=excluded.source_epoch, projection_epoch=excluded.projection_epoch, capped=excluded.capped, blocked_reason=NULL, planned_at=excluded.planned_at",
                            arrayOf<Any?>(request.context.ownerUserId, source, currentProjection + 1, if (capped) 1 else 0, now),
                        )
                        val committed = NotificationRefillScheduler.withActiveRun(context, runToken) {
                            database.setTransactionSuccessful()
                            database.endTransaction()
                            true
                        } ?: false
                        if (!committed) return false
                    } finally {
                        if (database.inTransaction()) database.endTransaction()
                    }
                }
            }
        } finally {
            closeScopedDatabase(database)
        }
        // Registry/AlarmManager reconciliation rereads the committed rows;
        // it cannot replace the registry from the stale Dart snapshot.
        return try {
            reconcile(context, "", scope, normalized)
            true
        } catch (error: NativeSqliteException) {
            // Let SQLITE_BUSY reach foreground/headless callers after the
            // reconcile/database finally blocks have closed their handles.
            // Foreground maps it to one bounded refill; JobService uses its
            // existing failed-operation backoff.
            if (error.isBusy) throw error
            false
        } catch (_: RuntimeException) {
            false
        }
    }

    /** Context captured from the foreground publication boundary. The path is
     * accepted only as an already verified canonical path; the headless
     * loader still rejects paths outside its prepared region. */
    internal fun refillContextForJob(context: Context): Map<String, String>? {
        val prefs = context.getSharedPreferences(REFILL_CONTEXT_PREFS, Context.MODE_PRIVATE)
        val path = prefs.getString(REFILL_DATABASE_PATH, null)?.takeIf { it.isNotBlank() }
        val owner = prefs.getString(REFILL_OWNER_USER_ID, null)?.takeIf { it.isNotBlank() }
        return if (path == null || owner == null) null else mapOf(
            REFILL_DATABASE_PATH to path,
            REFILL_OWNER_USER_ID to owner,
        )
    }

    internal fun clearRefillContext(context: Context) {
        check(
            context.getSharedPreferences(REFILL_CONTEXT_PREFS, Context.MODE_PRIVATE)
                .edit().clear().commit(),
        ) { "Could not clear notification refill context." }
    }

    /** Reconcile from the persisted registry on boot/time/package/permission recovery. */
    fun recover(context: Context, forceReinstall: Boolean = true) {
        val scope = NativeScopeFence.current(context)
        if (!scope.active || scope.regionId == null || scope.ownerHash == null) return
        synchronized(NativeScopeFence) outer@{
            if (!NativeScopeFence.matchesExpected(context, scope)) return@outer
            synchronized(registryLock) registry@{
                val prefs = preferences(context)
                val root = readRoot(prefs)
                if (!scopeMatches(root, scope)) {
                    // A crash may commit SQLite before the first registry
                    // acknowledgement. Reconstruct from that committed state.
                    runCatching { reconcile(context, "", scope, JSONArray()) }
                    return@registry
                }
                val all = allPlans(root)
                val tombstones = all.filter { it.value.optString(FIELD_STATE) == "cancel_pending" }
                tombstones.values.forEach { cancelAlarmAndPosted(context, it) }
                tombstones.keys.forEach { root.optJSONObject(REGISTRY_PLANS)?.remove(it) }
                if (tombstones.isNotEmpty()) persistRootPlans(prefs, root, root.optJSONObject(REGISTRY_PLANS)!!)
                val persisted = allPlans(root).filterValues { it.optString(FIELD_STATE) != "cancel_pending" }
                // OS alarms are not guaranteed to survive package replacement
                // and reboot. Requeue every undelivered row; displayed rows
                // remain a durable suppression marker until their cutoff.
                val now = NotificationTime.now()
                persisted.values.forEach { entry ->
                    if (!forceReinstall || entry.optBoolean(FIELD_DELIVERED, false)) return@forEach
                    // A process can die after markPosting() commits and before
                    // the NotificationManager call/failure handler. Preserve a
                    // bounded retry before resetting the state; otherwise a
                    // past trigger becomes permanently unschedulable on boot.
                    if (entry.optString(FIELD_STATE) == "posting" &&
                        entry.optInt(FIELD_RETRIES, 0) < MAX_RETRIES
                    ) {
                        val attempts = entry.optInt(FIELD_RETRIES, 0)
                        val retryAt = now + (MIN_RETRY_MS shl attempts.coerceAtMost(3)).coerceAtMost(MAX_RETRY_MS)
                        if (retryAt < entry.optLong("occurrenceAtMs", Long.MIN_VALUE)) {
                            entry.put(FIELD_RETRIES, attempts + 1)
                                .put(FIELD_NEXT_ATTEMPT, retryAt)
                                .put(FIELD_RETRY_KIND, "posting")
                        }
                    }
                    entry.put(FIELD_STATE, STATE_DEFERRED)
                }
                if (persisted.isNotEmpty()) {
                    persistRootPlans(prefs, root, root.optJSONObject(REGISTRY_PLANS)!!)
                }
                // An empty registry can also precede an acknowledged SQLite
                // publication. Always read the committed projection.
                runCatching { reconcile(context, "", scope, JSONArray()) }
            }
        }
    }

    /** Mark after NotificationManager succeeds; return false on a lost claim. */
    fun markDelivered(context: Context, identity: String, fingerprint: String): Boolean = synchronized(NativeScopeFence) { synchronized(registryLock) {
        runCatching {
            val prefs = preferences(context)
            val root = readRoot(prefs)
            val plans = root.optJSONObject(REGISTRY_PLANS) ?: return@runCatching false
            val entry = plans.optJSONObject(identity) ?: return@runCatching false
            if (entry.optString("fingerprint") != fingerprint) return@runCatching false
            entry.put(FIELD_DELIVERED, true).put(FIELD_STATE, STATE_DELIVERED)
                .put("deliveredAtMs", NotificationTime.now())
            if (!prefs.edit().putString(REGISTRY_KEY, root.toString()).commit()) return@runCatching false
            val scope = NativeScopeFence.current(context)
            if (!recordReceipt(context, scope, entry.optString("logicalId", entry.optString("planId")))) return@runCatching false
            true
        }.getOrDefault(false)
    } }

    /** Permanent logical suppression survives registry replacement, logout,
     * owner reactivation and wall-clock rollback. */
    internal fun recordReceiptForTest(context: Context, scope: NativeScope, logicalId: String): Boolean =
        synchronized(registryLock) { recordReceipt(context, scope, logicalId) }

    internal fun receiptRecordedForTest(context: Context, scope: NativeScope, logicalId: String): Boolean =
        synchronized(registryLock) { isReceiptRecorded(context, scope, logicalId) }

    internal fun isReceiptRecordedForDelivery(context: Context, scope: NativeScope, logicalId: String): Boolean =
        synchronized(registryLock) { isReceiptRecorded(context, scope, logicalId) }

    /** Persist canonical references before a summary is posted. The inbox is
     * scoped and ephemeral; each navigation still revalidates the SQLite row
     * through [validateTap]. */
    internal fun recordInboxReferences(context: Context, intents: List<Intent>, representedInSummary: Boolean) =
        synchronized(registryLock) {
            val scope = NativeScopeFence.current(context)
            if (!scope.active || intents.isEmpty()) return@synchronized
            val prefs = preferences(context)
            val root = readRoot(prefs)
            if (!scopeMatches(root, scope)) return@synchronized
            val inbox = root.optJSONArray(REGISTRY_INBOX) ?: JSONArray()
            intents.forEach { intent ->
                val identity = intent.getStringExtra(EXTRA_IDENTITY) ?: return@forEach
                val existing = (0 until inbox.length()).firstOrNull {
                    inbox.optJSONObject(it)?.optString("identity") == identity
                }
                val ref = JSONObject()
                    .put("identity", identity)
                    .put("planId", intent.getStringExtra(EXTRA_PLAN_ID))
                    .put("fingerprint", intent.getStringExtra(EXTRA_FINGERPRINT))
                    .put("logicalId", intent.getStringExtra(EXTRA_LOGICAL_ID))
                    .put("ownerUserId", intent.getStringExtra(EXTRA_OWNER_USER_ID))
                    .put("targetPath", intent.getStringExtra(EXTRA_TARGET_PATH))
                    .put("title", safePublicTitle(intent.getStringExtra(EXTRA_TITLE).orEmpty()))
                    .put("representedInSummary", representedInSummary)
                    .put("createdAtMs", NotificationTime.now())
                if (existing == null) inbox.put(ref) else inbox.put(existing, ref)
            }
            root.put(REGISTRY_INBOX, inbox)
            check(prefs.edit().putString(REGISTRY_KEY, root.toString()).commit())
        }

    internal fun prepareSummary(context: Context, scope: NativeScope, intents: List<Intent>): List<Intent> {
        val root = readRoot(preferences(context))
        if (!scopeMatches(root, scope)) return emptyList()
        val plans = root.getJSONObject(REGISTRY_PLANS)
        val accepted = intents.filter {
            val entry = plans.optJSONObject(it.getStringExtra(EXTRA_IDENTITY).orEmpty())
            entry != null && entry.optString("fingerprint") == it.getStringExtra(EXTRA_FINGERPRINT) &&
                !entry.optBoolean(FIELD_DELIVERED) && entry.optString(FIELD_STATE) in setOf(STATE_SCHEDULED, "posting")
        }
        accepted.forEach { plans.getJSONObject(it.getStringExtra(EXTRA_IDENTITY)!!).put(FIELD_STATE, "posting") }
        persistRootPlans(preferences(context), root, plans)
        recordInboxReferences(context, accepted, representedInSummary = true)
        return accepted
    }

    internal fun markSummaryDelivered(context: Context, scope: NativeScope, intents: List<Intent>): Boolean {
        val root = readRoot(preferences(context))
        if (!scopeMatches(root, scope)) return false
        val plans = root.getJSONObject(REGISTRY_PLANS)
        val receipts = receiptPreferences(context)
        val values = receipts.getStringSet(RECEIPT_KEY, emptySet()).orEmpty().toMutableSet()
        intents.forEach {
            val entry = plans.optJSONObject(it.getStringExtra(EXTRA_IDENTITY).orEmpty()) ?: return false
            if (entry.optString("fingerprint") != it.getStringExtra(EXTRA_FINGERPRINT)) return false
            values += receiptKey(scope, entry.getString("planId"))
            entry.put(FIELD_DELIVERED, true).put(FIELD_STATE, "represented_in_summary")
                .put("deliveredAtMs", NotificationTime.now())
        }
        if (!receipts.edit().putStringSet(RECEIPT_KEY, values).commit()) return false
        return preferences(context).edit().putString(REGISTRY_KEY, root.toString()).commit()
    }

    internal fun readInbox(context: Context): List<Map<String, Any?>> = synchronized(NativeScopeFence) {
        withRegistryLock {
            val scope = NativeScopeFence.current(context)
            val root = readRoot(preferences(context))
            if (!scope.active || !scopeMatches(root, scope)) return@withRegistryLock emptyList()
            val inbox = root.optJSONArray(REGISTRY_INBOX) ?: return@withRegistryLock emptyList()
            val db = runCatching { openScopedDatabase(context, scope.regionId!!) }.getOrNull()
                ?: return@withRegistryLock emptyList()
            try {
                db.beginTransactionNonExclusive()
                (0 until inbox.length()).mapNotNull { index ->
                    val row = inbox.optJSONObject(index) ?: return@mapNotNull null
                    val owner = row.optString("ownerUserId")
                    val id = row.optString("identity")
                    val fingerprint = row.optString("fingerprint")
                    if (ownerHash(owner) != scope.ownerHash || !isRegistered(context, id, fingerprint) ||
                        !readValidation(db, row.optString("planId"), owner, fingerprint, id,
                            NotificationTime.now(), isDelivered(context, id, fingerprint))) return@mapNotNull null
                    mapOf("identity" to id, "planId" to row.optString("planId"),
                        "fingerprint" to fingerprint, "logicalId" to row.optString("logicalId"),
                        "targetPath" to row.optString("targetPath"), "title" to row.optString("title"),
                        "representedInSummary" to row.optBoolean("representedInSummary"))
                }
            } finally {
                if (db.inTransaction()) db.endTransaction()
                closeScopedDatabase(db)
            }
        }
    }

    internal fun summaryTag(scope: NativeScope): String =
        "$SUMMARY_TAG_PREFIX${scope.regionId}:${scope.ownerHash}:${scope.generation}"

    internal fun cancelSummary(context: Context, scope: NativeScope) {
        context.getSystemService(NotificationManager::class.java)
            ?.cancel(summaryTag(scope), LOCAL_NOTIFICATION_SUMMARY_ID)
    }

    /** Claim the durable posting state before calling NotificationManager. */
    fun markPosting(context: Context, identity: String, fingerprint: String): Boolean = synchronized(registryLock) {
        runCatching {
            val prefs = preferences(context)
            val root = readRoot(prefs)
            val plans = root.optJSONObject(REGISTRY_PLANS) ?: return@runCatching false
            val entry = plans.optJSONObject(identity) ?: return@runCatching false
            if (entry.optString("fingerprint") != fingerprint ||
                entry.optBoolean(FIELD_DELIVERED, false) ||
                entry.optString(FIELD_STATE) !in setOf(STATE_SCHEDULED, STATE_RETRY_PENDING, "posting")
            ) return@runCatching false
            entry.put(FIELD_STATE, "posting").put(FIELD_DELIVERED, false)
            if (!prefs.edit().putString(REGISTRY_KEY, root.toString()).commit()) return@runCatching false
            true
        }.getOrDefault(false)
    }

    /** Schedule a bounded retry after NotificationManager failed. */
    fun retryPosting(context: Context, intent: Intent, untilMs: Long, reallocate: Boolean = true): Boolean {
        val identity = intent.getStringExtra(EXTRA_IDENTITY) ?: return false
        val fingerprint = intent.getStringExtra(EXTRA_FINGERPRINT) ?: return false
        val scope = NativeScopeFence.current(context)
        synchronized(NativeScopeFence) {
            if (!NativeScopeFence.matchesIntent(context, intent)) return false
            synchronized(registryLock) {
                val prefs = preferences(context)
                val root = readRoot(prefs)
                val plans = root.optJSONObject(REGISTRY_PLANS) ?: return false
                val entry = plans.optJSONObject(identity) ?: return false
                if (entry.optString("fingerprint") != fingerprint || entry.optString(FIELD_STATE) != "posting") return false
                val attempts = entry.optInt(FIELD_RETRIES, 0)
                val now = NotificationTime.now()
                if (attempts >= MAX_RETRIES || now >= untilMs) return false
                val retryAt = now + (MIN_RETRY_MS shl attempts.coerceAtMost(3)).coerceAtMost(MAX_RETRY_MS)
                if (retryAt >= untilMs) return false
                entry.put(FIELD_RETRIES, attempts + 1)
                    .put(FIELD_NEXT_ATTEMPT, retryAt)
                    .put(FIELD_RETRY_KIND, "posting")
                    .put(FIELD_STATE, STATE_RETRY_PENDING)
                // Registry first; only then expose the bounded retry to OS.
                if (!prefs.edit().putString(REGISTRY_KEY, root.toString()).commit()) return false
                if (reallocate) reserveBuckets(context, scope, root)
                return !reallocate || entry.optString(FIELD_STATE) == STATE_SCHEDULED

            }
        }
        // The receiver invokes recover after releasing its SQLite writer
        // reservation so promotion cannot lengthen the final side-effect
        // critical section.
    }

    fun isDelivered(context: Context, identity: String, fingerprint: String): Boolean = synchronized(registryLock) {
        val entry = readRoot(preferences(context)).optJSONObject(REGISTRY_PLANS)?.optJSONObject(identity)
        entry?.let { it.optString("fingerprint") == fingerprint && it.optBoolean(FIELD_DELIVERED, false) } == true
    }

    /** A stale OS PendingIntent must not publish after its durable plan was
     * removed or its registry became unreadable. */
    fun isRegistered(context: Context, identity: String, fingerprint: String): Boolean = synchronized(registryLock) {
        val entry = readRoot(preferences(context)).optJSONObject(REGISTRY_PLANS)?.optJSONObject(identity)
        entry != null && entry.optString("fingerprint") == fingerprint &&
            entry.optString(FIELD_STATE) in setOf(STATE_SCHEDULED, "posting", STATE_DELIVERED, "represented_in_summary")
    }

    fun isRetryDue(context: Context, identity: String, fingerprint: String, now: Long, untilMs: Long): Boolean = synchronized(registryLock) {
        val entry = readRoot(preferences(context)).optJSONObject(REGISTRY_PLANS)?.optJSONObject(identity) ?: return@synchronized false
        entry.optString("fingerprint") == fingerprint &&
            entry.optInt(FIELD_RETRIES, 0) > 0 &&
            entry.optString(FIELD_RETRY_KIND).isNotBlank() &&
            entry.optLong(FIELD_NEXT_ATTEMPT, Long.MAX_VALUE) <= now &&
            now < untilMs &&
            entry.optString(FIELD_STATE) in setOf(STATE_SCHEDULED, "posting")
    }

    fun retryIfTemporarilyStale(context: Context, intent: Intent, untilMs: Long, reallocate: Boolean = true): Boolean =
        retryProjectionBatch(context, listOf(intent to untilMs), reallocate)

    /** Preserve transient members in one durable update, then allocate once. */
    internal fun retryProjectionBatch(context: Context, members: List<Pair<Intent, Long>>, reallocate: Boolean = true): Boolean =
        synchronized(NativeScopeFence) {
            val scope = NativeScopeFence.current(context)
            synchronized(registryLock) {
                val prefs = preferences(context)
                val root = readRoot(prefs)
                if (!scopeMatches(root, scope)) return@synchronized false
                val plans = root.optJSONObject(REGISTRY_PLANS) ?: return@synchronized false
                val now = NotificationTime.now()
                val accepted = mutableListOf<JSONObject>()
                members.forEach { (intent, untilMs) ->
                    if (!NativeScopeFence.matchesIntent(context, intent)) return@forEach
                    val identity = intent.getStringExtra(EXTRA_IDENTITY) ?: return@forEach
                    val entry = plans.optJSONObject(identity) ?: return@forEach
                    if (entry.optString("fingerprint") != intent.getStringExtra(EXTRA_FINGERPRINT) ||
                        entry.optBoolean(FIELD_DELIVERED)) return@forEach
                    val attempts = entry.optInt(FIELD_RETRIES)
                    if (attempts >= MAX_RETRIES || now >= untilMs) return@forEach
                    val retryAt = now + (MIN_RETRY_MS shl attempts.coerceAtMost(3)).coerceAtMost(MAX_RETRY_MS)
                    if (retryAt >= untilMs) return@forEach
                    entry.put(FIELD_RETRIES, attempts + 1).put(FIELD_NEXT_ATTEMPT, retryAt)
                        .put(FIELD_RETRY_KIND, "projection").put(FIELD_STATE, STATE_RETRY_PENDING)
                    accepted += entry
                }
                if (accepted.isEmpty()) return@synchronized false
                persistRootPlans(prefs, root, plans)
                NotificationRefillScheduler.requestRefill(context, "projection-retry")
                if (reallocate) reserveBuckets(context, scope, root)
                !reallocate || accepted.any { it.optString(FIELD_STATE) == STATE_SCHEDULED }
            }
        }

    fun validateTap(context: Context, intent: Intent): Boolean {
        if (!NativeScopeFence.matchesIntent(context, intent)) return false
        val scope = NativeScopeFence.current(context)
        val owner = intent.getStringExtra(EXTRA_OWNER_USER_ID) ?: return false
        if (ownerHash(owner) != scope.ownerHash) return false
        val identity = intent.getStringExtra(EXTRA_IDENTITY) ?: return false
        val fingerprint = intent.getStringExtra(EXTRA_FINGERPRINT) ?: return false
        if (!isRegistered(context, identity, fingerprint)) return false
        val db = runCatching { openScopedDatabase(context, scope.regionId!!) }.getOrNull() ?: return false
        return try {
            ensureSchema(db)
            synchronized(NativeScopeFence) {
                LocalNotificationCoordinator.withRegistryLock {
                    db.beginTransactionNonExclusive()
                    val valid = readValidation(
                        db,
                        intent.getStringExtra(EXTRA_PLAN_ID) ?: "",
                        owner,
                        fingerprint,
                        identity,
                        NotificationTime.now(),
                        isDelivered(context, identity, fingerprint),
                    )
                    if (valid) db.setTransactionSuccessful()
                    db.endTransaction()
                    valid && NativeScopeFence.matchesIntent(context, intent)
                }
            }
        } catch (_: RuntimeException) { false } finally { closeScopedDatabase(db) }
    }

    fun clearForScope(context: Context, previousToken: String?) {
        synchronized(registryLock) {
            val prefs = preferences(context)
            val root = readRoot(prefs)
            val plans = root.optJSONObject(REGISTRY_PLANS) ?: return
            if (previousToken != null && root.optString(REGISTRY_TOKEN) != previousToken) return
            // Preserve Phase 7 delivered markers before the old scoped
            // registry is cleared during A→B/A activation.
            migrateLegacyReceipts(context, root)
            allPlans(root).values.forEach { cancelAlarmAndPosted(context, it) }
            check(prefs.edit().remove(REGISTRY_KEY).commit())
        }
    }

    /** Debug-only fixture seam. It accepts one exact Phase71 exam title and
     * removes only that exam's native-derived occurrences/reservations. The
     * canonical exam, sync queue, source revisions, projection receipt ledger,
     * and every other entity remain untouched. */
    internal fun clearPhase71ExamDerived(
        context: Context,
        scope: NativeScope,
        ownerUserId: String,
        exactTitle: String,
    ): Map<String, Any> {
        require(scope.active && scope.ownerHash == ownerHash(ownerUserId)) { "fixture scope is not active" }
        require(exactTitle.startsWith("Phase71-")) { "fixture title prefix is required" }
        val database = openScopedDatabase(context, scope.regionId!!)
        try {
            return synchronized(NativeScopeFence) {
                check(NativeScopeFence.matchesExpected(context, scope)) { "fixture scope changed" }
                synchronized(registryLock) {
                    database.beginTransactionNonExclusive()
                    val examId = database.rawQuery(
                        "SELECT id FROM exams WHERE owner_user_id=? AND title=? AND deleted_at IS NULL LIMIT 2",
                        arrayOf(ownerUserId, exactTitle),
                    ).use { c ->
                        check(c.moveToFirst()) { "fixture exam not found" }
                        val id = c.getString(0)
                        check(!c.moveToNext()) { "fixture title is not unique for owner" }
                        id
                    }
                    val deleted = database.delete(
                        "local_notification_occurrences",
                        "owner_user_id=? AND kind=? AND source_entity_id=?",
                        arrayOf(ownerUserId, "exam", examId),
                    )
                    database.setTransactionSuccessful()
                    database.endTransaction()

                    val prefs = preferences(context)
                    val root = readRoot(prefs)
                    check(scopeMatches(root, scope)) { "fixture registry scope changed" }
                    val plans = root.optJSONObject(REGISTRY_PLANS) ?: JSONObject()
                    val removed = mutableListOf<JSONObject>()
                    val removeIds = mutableListOf<String>()
                    plans.keys().asSequence().toList().forEach { identity ->
                        val entry = plans.optJSONObject(identity) ?: return@forEach
                        if (entry.optString("ownerUserId") == ownerUserId &&
                            entry.optString("kind") == "exam" &&
                            entry.optString("sourceEntityId") == examId
                        ) {
                            removed += entry
                            removeIds += identity
                        }
                    }
                    removeIds.forEach(plans::remove)
                    val inbox = root.optJSONArray(REGISTRY_INBOX)
                    if (inbox != null) {
                        for (index in inbox.length() - 1 downTo 0) {
                            if (removeIds.contains(inbox.optJSONObject(index)?.optString("identity"))) inbox.remove(index)
                        }
                    }
                    root.put(REGISTRY_PLANS, plans)
                    check(prefs.edit().putString(REGISTRY_KEY, root.toString()).commit())
                    removed.forEach { cancelAlarmAndPosted(context, it) }
                    mapOf("examId" to examId, "occurrencesDeleted" to deleted, "reservationsDeleted" to removed.size)
                }
            }
        } finally {
            if (database.inTransaction()) database.endTransaction()
            closeScopedDatabase(database)
        }
    }

    fun openExactAlarmSettings(context: Context) {
        if (Build.VERSION.SDK_INT >= 31) context.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:${context.packageName}")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    fun openNotificationSettings(context: Context) {
        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    fun tapIntent(context: Context, source: Intent): Intent = Intent(context, MainActivity::class.java).apply {
        action = Intent.ACTION_VIEW
        data = source.getStringExtra(EXTRA_TARGET_PATH)?.let { target ->
            Uri.parse("${BuildConfig.DEEP_LINK_SCHEME}://${target.trim().trimStart('/')}")
                .buildUpon()
                .appendQueryParameter("notification", source.getStringExtra(EXTRA_IDENTITY).orEmpty())
                .appendQueryParameter("plan", source.getStringExtra(EXTRA_PLAN_ID).orEmpty())
                .appendQueryParameter("fingerprint", source.getStringExtra(EXTRA_FINGERPRINT).orEmpty())
                .build()
        }
        putExtras(source)
        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }

    private fun capabilityStatus(context: Context): LocalNotificationCapabilities {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val permission = if (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) "granted" else "denied"
        createChannel(context)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = if (manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(LOCAL_NOTIFICATION_CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)) "enabled" else "disabled"
        val exact = if (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) "granted" else "blocked"
        val blocked = when {
            permission != "granted" -> "notification_permission"
            channel != "enabled" -> "notification_channel"
            exact != "granted" -> "exact_alarm_permission"
            else -> null
        }
        return LocalNotificationCapabilities(permission, exact, 0, blocked, channel)
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(LOCAL_NOTIFICATION_CHANNEL) == null) manager.createNotificationChannel(
            NotificationChannel(LOCAL_NOTIFICATION_CHANNEL, "予定の通知", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "授業・課題・試験・予定の通知"
            },
        )
    }

    private fun scheduleAlarm(context: Context, scope: NativeScope, entry: JSONObject, bucketAtMs: Long = entry.getLong("triggerAtMs")) {
        val now = NotificationTime.now()
        val alarmAt = bucketAtMs
        check(alarmAt > now)
        val pending = broadcastPendingIntent(context, receiverIntent(context, scope, entry, bucketAtMs), entry)
            ?: error("could not create notification PendingIntent")
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP, alarmAt, pending,
        )
    }

    private fun cancelAlarmAndPosted(context: Context, entry: JSONObject) {
        if (!entry.has("identity") || !entry.has("ownerUserId")) return
        cancelLegacyAlarm(context, entry)
        cancelAlarmOnly(context, entry)
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(
            entry.optString("identity"), NOTIFICATION_ID,
        )
    }

    internal fun receiverIntentForTest(context: Context, scope: NativeScope, entry: JSONObject, bucketAtMs: Long = entry.optLong("scheduledAtMs", entry.getLong("triggerAtMs"))): Intent = receiverIntent(context, scope, entry, bucketAtMs)

    internal fun bucketMemberIntents(context: Context, intent: Intent): List<Intent> = synchronized(NativeScopeFence) { withRegistryLock {
        val bucketAt = intent.getLongExtra(EXTRA_BUCKET_AT, Long.MIN_VALUE)
        val scope = NativeScopeFence.current(context)
        if (bucketAt == Long.MIN_VALUE || !NativeScopeFence.matchesIntent(context, intent)) return@withRegistryLock emptyList()
        val root = readRoot(preferences(context))
        if (!scopeMatches(root, scope)) return@withRegistryLock emptyList()
        allPlans(root).values
            .filter {
                it.optLong("scheduledAtMs", it.optLong("triggerAtMs", Long.MIN_VALUE)) == bucketAt
            }
            .filter { it.optString(FIELD_STATE) in setOf(STATE_SCHEDULED, "posting") }
            .map { receiverIntent(context, scope, it, bucketAt) }
    } }

    private fun receiverIntent(context: Context, scope: NativeScope, entry: JSONObject, bucketAtMs: Long = entry.optLong("scheduledAtMs", entry.getLong("triggerAtMs"))): Intent = Intent(context, LocalNotificationReceiver::class.java).apply {
        action = LOCAL_NOTIFICATION_ACTION
        data = Uri.parse("${BuildConfig.DEEP_LINK_SCHEME}://ordinary-bucket/${Uri.encode(bucketKey(scope, bucketAtMs))}")
        putExtra(EXTRA_PLAN_ID, entry.getString("planId"))
        putExtra(EXTRA_OWNER_USER_ID, entry.getString("ownerUserId"))
        putExtra(EXTRA_IDENTITY, entry.getString("identity"))
        putExtra(EXTRA_FINGERPRINT, entry.getString("fingerprint"))
        putExtra(EXTRA_TARGET_PATH, entry.getString("targetPath"))
        putExtra(EXTRA_TITLE, safePublicTitle(entry.optString("title")))
        putExtra(EXTRA_BODY, safePublicBody(entry))
        putExtra(EXTRA_OCCURRENCE_AT, entry.getLong("occurrenceAtMs"))
        putExtra(EXTRA_TRIGGER_AT, entry.getLong("triggerAtMs"))
        putExtra(EXTRA_RULE, entry.getString("rule"))
        putExtra(EXTRA_SOURCE_EPOCH, entry.getLong("sourceEpoch"))
        putExtra(EXTRA_PROJECTION_EPOCH, entry.getLong("projectionEpoch"))
        putExtra(EXTRA_ATTEMPT, entry.optInt(FIELD_RETRIES, 0))
        putExtra(EXTRA_BUCKET_AT, bucketAtMs)
        putExtra(EXTRA_BUCKET_KEY, bucketKey(scope, bucketAtMs))
        putExtra(EXTRA_LOGICAL_ID, entry.optString("logicalId", entry.getString("planId")))
        putScope(this, scope)
    }

    internal fun bucketKeyForTest(scope: NativeScope, triggerAtMs: Long): String = bucketKey(scope, triggerAtMs)

    private fun bucketKey(scope: NativeScope, triggerAtMs: Long): String =
        "v2|r=${scope.regionId}|o=${scope.ownerHash}|g=${scope.generation}|s=${component(scope.activationToken.orEmpty())}|t=$triggerAtMs"

    private fun broadcastPendingIntent(context: Context, intent: Intent, entry: JSONObject, noCreate: Boolean = false): PendingIntent? {
        val flags = PendingIntent.FLAG_IMMUTABLE or if (noCreate) PendingIntent.FLAG_NO_CREATE else PendingIntent.FLAG_UPDATE_CURRENT
        return PendingIntent.getBroadcast(context, 0, intent, flags)
    }

    private fun putScope(target: Intent, scope: NativeScope) {
        target.putExtra(EXTRA_SCOPE_REGION, scope.regionId)
            .putExtra(EXTRA_SCOPE_OWNER, scope.ownerHash)
            .putExtra(EXTRA_SCOPE_TOKEN, scope.activationToken)
            .putExtra(EXTRA_SCOPE_GENERATION, scope.generation)
    }

    private fun readValidation(db: CanonicalSqliteDatabase, planId: String, owner: String, fingerprint: String, identity: String, now: Long, delivered: Boolean): Boolean = db.rawQuery(
        "SELECT o.fingerprint,o.source_epoch,o.projection_epoch,o.reason,o.status,o.trigger_at,o.occurrence_at,p.source_epoch,p.projection_epoch,r.epoch FROM local_notification_occurrences o JOIN local_notification_projection_states p ON p.owner_user_id=o.owner_user_id JOIN local_notification_source_revisions r ON r.id=1 WHERE o.id=? AND o.owner_user_id=? LIMIT 1",
        arrayOf(planId, owner),
    ).use { c ->
        if (!c.moveToFirst()) return@use false
        c.getString(0) == fingerprint && identityMatches(identity, planId) && (c.getString(3) == "eligible" || delivered) && c.getString(4) == "desired" && c.getLong(1) == c.getLong(9) && c.getLong(7) == c.getLong(9) && c.getLong(2) == c.getLong(8) && c.getLong(5) <= now && now < c.getLong(6)
    }

    private fun readCommittedPlans(
        db: CanonicalSqliteDatabase,
        scope: NativeScope,
        sourceEpoch: Long,
    ): LinkedHashMap<String, JSONObject> {
        val desired = linkedMapOf<String, JSONObject>()
        db.rawQuery(
            "SELECT o.id,o.owner_user_id,o.kind,o.source_entity_id,o.trigger_at,o.occurrence_at,o.target_path,o.title,o.body,o.rule,o.fingerprint,o.reason,o.source_epoch,o.projection_epoch " +
                        "FROM local_notification_occurrences o JOIN local_notification_projection_states p ON p.owner_user_id=o.owner_user_id " +
                "WHERE o.source_epoch=? AND p.source_epoch=o.source_epoch AND o.projection_epoch=p.projection_epoch AND o.status='desired' ORDER BY o.trigger_at,o.id",
            arrayOf(sourceEpoch.toString()),
        ).use { c ->
            while (c.moveToNext()) {
                val owner = c.getString(1)
                if (ownerHash(owner) != scope.ownerHash) continue
                val raw = JSONObject()
                    .put("id", c.getString(0))
                    .put("logicalId", c.getString(0))
                    .put("ownerUserId", owner)
                    .put("kind", c.getString(2))
                    .put("sourceEntityId", c.getString(3))
                    .put("triggerAtMs", c.getLong(4))
                    .put("occurrenceAtMs", c.getLong(5))
                    .put("targetPath", c.getString(6))
                    .put("title", c.getString(7))
                    .put("body", c.getString(8))
                    .put("rule", c.getString(9))
                    .put("fingerprint", c.getString(10))
                    .put("reason", c.getString(11))
                    .put("sourceEpoch", c.getLong(12))
                    .put("projectionEpoch", c.getLong(13))
                val parsed = parsePlan(raw, scope) ?: error("invalid committed notification plan")
                val id = identity(scope, parsed)
                parsed.put("identity", id)
                desired[id] = parsed
            }
        }
        return desired
    }

    private fun isCurrentProjection(db: CanonicalSqliteDatabase, plan: JSONObject, epoch: Long): Boolean = db.rawQuery(
        "SELECT o.fingerprint,o.source_epoch,o.projection_epoch,o.reason,o.status,o.trigger_at,o.occurrence_at,p.source_epoch,p.projection_epoch FROM local_notification_occurrences o JOIN local_notification_projection_states p ON p.owner_user_id=o.owner_user_id WHERE o.id=? AND o.owner_user_id=? LIMIT 1",
        arrayOf(plan.getString("planId"), plan.getString("ownerUserId")),
    ).use { c ->
        if (!c.moveToFirst()) return@use false
        c.getString(0) == plan.getString("fingerprint") && c.getLong(1) == epoch && c.getLong(7) == epoch && c.getLong(2) == c.getLong(8) && c.getString(3) == "eligible" && c.getString(4) == "desired" && c.getLong(5) == plan.getLong("triggerAtMs") && c.getLong(6) == plan.getLong("occurrenceAtMs")
    }

    private fun projectionIsFresh(db: CanonicalSqliteDatabase, scope: NativeScope, epoch: Long): Boolean =
        db.rawQuery("SELECT owner_user_id,source_epoch FROM local_notification_projection_states", null).use { c ->
            while (c.moveToNext()) {
                if (ownerHash(c.getString(0)) == scope.ownerHash) return@use c.getLong(1) == epoch
            }
            false
        }

    private fun ensureSchema(db: CanonicalSqliteDatabase) {
        listOf("local_notification_occurrences", "local_notification_projection_states", "local_notification_source_revisions").forEach { table ->
            db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", arrayOf(table)).use { c -> check(c.moveToFirst()) { "ordinary notification schema missing" } }
        }
    }

    private fun currentSourceEpoch(db: CanonicalSqliteDatabase): Long = db.rawQuery("SELECT epoch FROM local_notification_source_revisions WHERE id=1", null).use { c -> if (c.moveToFirst()) c.getLong(0) else error("source epoch missing") }

    private fun projectionEpoch(db: CanonicalSqliteDatabase, owner: String): Long = db.rawQuery(
        "SELECT projection_epoch FROM local_notification_projection_states WHERE owner_user_id=? LIMIT 1",
        arrayOf(owner),
    ).use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }

    /** Schema 18 context is part of the CAS boundary. Every persisted tuple
     * field must be present and agree with the canonical profile/term rows. */
    private fun validateContextIfPresent(db: CanonicalSqliteDatabase, context: NotificationRefillContext) {
        val requiredFlags = listOf(
            "profileOnboardingStatus", "profileActive", "profileDeleted", "termOwnerUserId",
            "termStatus", "termIsTemplate", "termDeleted", "calendarDeleted",
        )
        requiredFlags.forEach { check(context.rawFlags.has(it)) { "notification context flag '$it' is required" } }
        check(tableExists(db, "terms")) { "notification context terms table missing" }
        check(tableExists(db, "profiles")) { "notification context profiles table missing" }
        check(tableExists(db, "calendars")) { "notification context calendars table missing" }
        db.rawQuery("SELECT university_id, academic_year, owner_user_id, status, is_template, deleted_at FROM terms WHERE id=? LIMIT 1", arrayOf(context.termId)).use { c ->
            if (!c.moveToFirst()) error("notification context term missing")
            check(c.getString(0) == context.universityId) { "notification context university changed" }
            check(c.getInt(1) == context.academicYear) { "notification context academic year changed" }
            check(c.getString(2) == context.rawFlags.getString("termOwnerUserId")) { "notification context term owner changed" }
            check(c.getString(2) == context.ownerUserId) { "notification context term owner changed" }
            check(c.getString(3) == context.rawFlags.getString("termStatus")) { "notification context term status changed" }
            check((c.getInt(4) != 0) == context.rawFlags.getBoolean("termIsTemplate")) { "notification context template flag changed" }
            check(c.isNull(5) == !context.rawFlags.getBoolean("termDeleted")) { "notification context term deletion changed" }
        }
        db.rawQuery("SELECT university_id, active_term_id, primary_calendar_id, onboarding_status FROM profiles WHERE user_id=? LIMIT 1", arrayOf(context.ownerUserId)).use { c ->
            if (!c.moveToFirst()) error("notification context profile missing")
            check(c.getString(0) == context.universityId) { "notification context profile university changed" }
            check(c.getString(1) == context.termId) { "notification context active term changed" }
            check(c.getString(2) == context.primaryCalendarId) { "notification context primary calendar changed" }
            check(c.getString(3) == context.rawFlags.getString("profileOnboardingStatus")) { "notification context onboarding status changed" }
            check(context.rawFlags.getBoolean("profileActive")) { "notification context profile inactive" }
            check(!context.rawFlags.getBoolean("profileDeleted")) { "notification context profile deleted" }
        }
        db.rawQuery("SELECT owner_user_id FROM calendars WHERE id=? LIMIT 1", arrayOf(context.primaryCalendarId)).use { c ->
            if (!c.moveToFirst() || c.getString(0) != context.ownerUserId) error("notification context calendar changed")
            check(!context.rawFlags.getBoolean("calendarDeleted")) { "notification context calendar deleted" }
        }
    }

    private fun tableExists(db: CanonicalSqliteDatabase, table: String): Boolean = db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", arrayOf(table),
    ).use { it.moveToFirst() }

    private fun tableHasColumn(db: CanonicalSqliteDatabase, table: String, column: String): Boolean =
        db.rawQuery("PRAGMA table_info($table)", null).use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(1) == column) return@use true
            false
        }

    internal fun openScopedDatabase(context: Context, region: String): CanonicalSqliteDatabase {
        scopedDatabaseProviderForTests?.let { return it(context, region) }
        check(region.matches(Regex("^[a-f0-9]{64}$"))) { "invalid region" }
        val expected = File(File(File(context.applicationInfo.dataDir, "app_flutter"), "spaces"), "$region/app.sqlite")
        val canonical = expected.canonicalFile
        check(canonical.path == expected.absoluteFile.canonicalPath && canonical.isFile) { "scoped database unavailable" }
        validateCommittedManifest(File(canonical.parentFile, "committed-v1.json"), region)
        scopedDatabaseFactoryForTests?.let { return it(context, region, canonical) }
        return NativeSqliteDatabase.open(context, region, canonical)
    }

    private fun persistValidatedRefillContext(
        context: Context,
        scope: NativeScope,
        request: NotificationRefillRequest,
        raw: JSONObject,
    ) {
        val databasePath = raw.optString("databasePath").takeIf { it.isNotBlank() } ?: return
        synchronized(NativeScopeFence) {
            check(NativeScopeFence.matchesExpected(context, scope)) {
                "ordinary notification scope changed"
            }
            val canonicalPath = canonicalDatabasePath(context, scope.regionId!!, databasePath)
                ?: error("notification database path is not canonical")
            check(
                context.getSharedPreferences(REFILL_CONTEXT_PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putString(REFILL_DATABASE_PATH, canonicalPath)
                    .putString(REFILL_OWNER_USER_ID, request.context.ownerUserId)
                    .commit(),
            ) { "Could not persist notification refill context." }
        }
    }

    /** Validates only the publication manifest. It deliberately does not read
     * or hash app.sqlite, whose locks and journal lifecycle belong to SQLite. */
    internal fun validateCommittedManifest(manifestFile: File, region: String) {
        check(region.matches(Regex("^[a-f0-9]{64}$"))) { "invalid region" }
        check(manifestFile.isFile) { "storage_not_committed" }
        val manifest = try {
            JSONObject(manifestFile.readText(Charsets.UTF_8))
        } catch (error: Throwable) {
            throw IllegalStateException("storage_manifest_invalid", error)
        }
        check(manifest.optString("format") == "storage-publication-v1" &&
            manifest.optString("phase") == "COMMITTED" &&
            manifest.optString("regionId") == region) { "storage_manifest_mismatch" }
        val importedLegacy = manifest.opt("importedLegacy")
        check(importedLegacy is Boolean) { "storage_manifest_mismatch" }
        val candidateHash = manifest.opt("candidateSha256")
        check(candidateHash is String && candidateHash.matches(Regex("^[a-f0-9]{64}$"))) {
            "storage_manifest_mismatch"
        }
        val receipt = when {
            !manifest.has("sourceReceiptSha256") || manifest.isNull("sourceReceiptSha256") -> null
            else -> manifest.opt("sourceReceiptSha256")
        }
        check(receipt == null || (receipt is String && receipt.matches(Regex("^[a-f0-9]{64}$")))) {
            "storage_receipt_invalid"
        }
        check((importedLegacy as Boolean) == (receipt != null)) {
            "storage_provenance_mismatch"
        }
    }

    private fun canonicalDatabasePath(context: Context, region: String, path: String): String? =
        runCatching {
            val expected = File(File(File(context.applicationInfo.dataDir, "app_flutter"), "spaces"), "$region/app.sqlite")
            val canonical = File(path).canonicalFile
            if (canonical.path == expected.canonicalPath && expected.isFile) canonical.path else null
        }.getOrNull()

    internal fun closeScopedDatabase(database: CanonicalSqliteDatabase) {
        database.close()
    }

    private fun parsePlan(raw: JSONObject, scope: NativeScope): JSONObject? {
        val owner = raw.optString("ownerUserId")
        val kind = raw.optString("kind")
        val source = raw.optString("sourceEntityId")
        val rule = raw.optString("rule")
        val planId = raw.optString("id", raw.optString("planId"))
        // The Dart plan ID hashes the stable logical reminder identity. It is
        // persisted in SQLite, unlike optional caller-only identity fields.
        val logicalId = planId
        val fingerprint = raw.optString("fingerprint")
        if (owner.isBlank() || kind.isBlank() || source.isBlank() || rule.isBlank() || planId.isBlank() || fingerprint.isBlank() || ownerHash(owner) != scope.ownerHash) return null
        val occurrence = if (raw.has("occurrenceAtMs")) raw.optLong("occurrenceAtMs", Long.MIN_VALUE)
        else parseInstantMs(raw.optString("occurrenceAt")) ?: return null
        val trigger = if (raw.has("triggerAtMs")) raw.optLong("triggerAtMs", Long.MIN_VALUE)
        else parseInstantMs(raw.optString("triggerAt")) ?: return null
        if (occurrence == Long.MIN_VALUE || trigger == Long.MIN_VALUE) return null
        if (trigger > occurrence) return null
        // Preserve the existing strict before-occurrence delivery cutoff. A
        // zero-offset import must not reject unrelated valid reminders in the
        // same atomic publication; retain it with an explicit ineligible reason.
        val reason = if (trigger == occurrence) "at_start_cutoff" else raw.optString("reason", "eligible")
        return JSONObject().put("planId", planId).put("logicalId", logicalId.take(512)).put("ownerUserId", owner).put("kind", kind).put("sourceEntityId", source).put("rule", rule).put("fingerprint", fingerprint).put("reason", reason).put("targetPath", safeTargetPath(raw.optString("targetPath"))).put("title", raw.optString("title").take(256)).put("body", raw.optString("body").take(256)).put("sourceEpoch", raw.optLong("sourceEpoch", -1L)).put("projectionEpoch", raw.optLong("projectionEpoch", -1L)).put("occurrenceAtMs", occurrence).put("triggerAtMs", trigger)
    }

    private fun identity(scope: NativeScope, plan: JSONObject): String = identityForTest(scope, plan.getString("planId"), plan.getString("kind"), plan.getString("sourceEntityId"), plan.getLong("occurrenceAtMs"), plan.getString("rule"))
    private fun identityMatches(identity: String, planId: String): Boolean = identity.startsWith("v1|r=") && identity.contains("|o=") && identity.contains("|id=${component(planId)}|") && identity.contains("|k=") && identity.contains("|e=") && identity.contains("|t=") && identity.contains("|rule=")
    private fun component(value: String): String = URLEncoder.encode(value, "UTF-8")
    private fun identityUri(identity: String): Uri = Uri.parse("${BuildConfig.DEEP_LINK_SCHEME}://ordinary-notification/${Uri.encode(identity)}")
    private fun ownerHash(owner: String): String = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    private fun parseInstantMs(value: String): Long? = runCatching { Instant.parse(value).toEpochMilli() }.getOrNull()
    private fun safeTargetPath(value: String): String = value.trim().take(256).let { if (it.startsWith("/") && !it.contains("//") && !it.contains("..")) it else "/today" }
    private fun safePublicTitle(value: String): String = value.filter { !it.isISOControl() }.trim().take(128).ifBlank { "予定の通知" }
    private fun safePublicBody(entry: JSONObject): String = "${label(entry.optString("kind"))} · ${jstLabel(entry.getLong("occurrenceAtMs"))}"
    private fun label(kind: String): String = when (kind) { "course" -> "授業"; "assignment" -> "課題"; "exam" -> "試験"; "routine" -> "ルーティン"; else -> "予定" }
    private fun jstLabel(epochMs: Long): String = java.time.ZonedDateTime.ofInstant(Instant.ofEpochMilli(epochMs), java.time.ZoneId.of("Asia/Tokyo")).let { "${it.monthValue}/${it.dayOfMonth} ${it.hour.toString().padStart(2, '0')}:${it.minute.toString().padStart(2, '0')}" }
    private fun initialState(plan: JSONObject, now: Long): String = if (plan.optString("reason", "eligible") != "eligible" || plan.getLong("triggerAtMs") <= now) STATE_INVALID else STATE_DEFERRED
    private fun eligibleForScheduling(plan: JSONObject, now: Long): Boolean {
        if (plan.optString(FIELD_STATE) == STATE_INVALID) return false
        if (awaitingDueDelivery(plan, now)) return true
        val retryAt = plan.optLong(FIELD_NEXT_ATTEMPT, Long.MIN_VALUE)
        val retry = plan.optInt(FIELD_RETRIES, 0) > 0 &&
            plan.optString(FIELD_RETRY_KIND).isNotBlank() &&
            retryAt > now && retryAt < plan.getLong("occurrenceAtMs")
        if (retry) return true
        return plan.optString("reason", "eligible") == "eligible" &&
            plan.getLong("triggerAtMs") > now &&
            plan.getLong("triggerAtMs") <= now + HORIZON_MS &&
            plan.getLong("triggerAtMs") < plan.getLong("occurrenceAtMs")
    }

    internal fun hasAcknowledgedDueWakeup(context: Context, identity: String, fingerprint: String, now: Long): Boolean = synchronized(registryLock) {
        val entry = readRoot(preferences(context)).optJSONObject(REGISTRY_PLANS)?.optJSONObject(identity)
            ?: return@synchronized false
        entry.optString("fingerprint") == fingerprint && !entry.optBoolean(FIELD_DELIVERED) && awaitingDueDelivery(entry, now)
    }
    private fun awaitingDueDelivery(plan: JSONObject, now: Long): Boolean =
        plan.optString(FIELD_STATE) in setOf(STATE_SCHEDULED, "posting") &&
            plan.optLong("scheduledAtMs", plan.optLong("triggerAtMs")) <= now &&
            now < plan.optLong("occurrenceAtMs") &&
            (plan.optString("reason") == "eligible" ||
                (plan.optString("reason") == "past" && plan.has("scheduledAtMs")) || plan.optInt(FIELD_RETRIES) > 0)
    private fun samePlan(a: JSONObject, b: JSONObject): Boolean {
        if (a.optString("fingerprint") != b.optString("fingerprint") ||
            a.optLong("triggerAtMs") != b.optLong("triggerAtMs") ||
            a.optLong("occurrenceAtMs") != b.optLong("occurrenceAtMs") ||
            a.optString("targetPath") != b.optString("targetPath") ||
            a.optString("ownerUserId") != b.optString("ownerUserId")
        ) return false
        val oldReason = a.optString("reason", "eligible")
        val newReason = b.optString("reason", "eligible")
        if (oldReason == newReason) return true
        // A displayed notification may remain tappable after its trigger turns
        // past. A bounded retry may also cross that planner transition; keep
        // only that registered retry alive. A never-fired scheduled plan is
        // cancelled when it becomes ineligible.
        return newReason == "past" &&
            (a.optBoolean(FIELD_DELIVERED, false) ||
                awaitingDueDelivery(a, NotificationTime.now()) ||
                (a.optInt(FIELD_RETRIES, 0) > 0 &&
                    a.optString(FIELD_STATE) in setOf(STATE_SCHEDULED, "posting", STATE_RETRY_PENDING, STATE_DEFERRED)))
    }

    private fun mergePlan(old: JSONObject, fresh: JSONObject): JSONObject = JSONObject(fresh.toString()).apply {
        // Projection fields come from the fresh Dart/SQLite snapshot. Only
        // native OS acknowledgement and bounded retry bookkeeping survives.
        put(FIELD_STATE, old.optString(FIELD_STATE, STATE_DEFERRED))
        put(FIELD_DELIVERED, old.optBoolean(FIELD_DELIVERED, false))
        put(FIELD_RETRIES, old.optInt(FIELD_RETRIES, 0))
        if (old.has("deliveredAtMs")) put("deliveredAtMs", old.optLong("deliveredAtMs"))
        if (old.has(FIELD_NEXT_ATTEMPT)) put(FIELD_NEXT_ATTEMPT, old.optLong(FIELD_NEXT_ATTEMPT))
        if (old.has(FIELD_RETRY_KIND)) put(FIELD_RETRY_KIND, old.optString(FIELD_RETRY_KIND))
        if (old.has("scheduledAtMs")) put("scheduledAtMs", old.getLong("scheduledAtMs"))
    }
    private fun preferences(context: Context) = context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
    private fun receiptPreferences(context: Context) = context.getSharedPreferences(RECEIPT_PREFS, Context.MODE_PRIVATE)

    private fun receiptKey(scope: NativeScope, logicalId: String): String {
        val raw = "$RECEIPT_VERSION|${scope.regionId}|${scope.ownerHash}|$logicalId"
        return MessageDigest.getInstance("SHA-256")
            .digest(raw.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun isReceiptRecorded(context: Context, scope: NativeScope, logicalId: String): Boolean {
        if (logicalId.isBlank() || scope.regionId == null || scope.ownerHash == null) return false
        return receiptPreferences(context)
            .getStringSet(RECEIPT_KEY, emptySet())
            ?.contains(receiptKey(scope, logicalId)) == true
    }

    private fun recordReceipt(context: Context, scope: NativeScope, logicalId: String): Boolean {
        if (logicalId.isBlank() || !scope.active || scope.regionId == null || scope.ownerHash == null) return false
        val prefs = receiptPreferences(context)
        val values = prefs.getStringSet(RECEIPT_KEY, emptySet()).orEmpty().toMutableSet()
        values += receiptKey(scope, logicalId)
        return prefs.edit().putStringSet(RECEIPT_KEY, values).commit()
    }

    private fun migrateLegacyReceipts(context: Context, root: JSONObject) {
        val scope = NativeScope(
            root.optString(REGISTRY_REGION).takeIf { it.isNotBlank() },
            root.optString(REGISTRY_OWNER).takeIf { it.isNotBlank() },
            root.optString(REGISTRY_TOKEN).takeIf { it.isNotBlank() },
            root.optLong(REGISTRY_GENERATION, Long.MIN_VALUE),
            true,
        )
        if (scope.regionId == null || scope.ownerHash == null || scope.activationToken == null || scope.generation == Long.MIN_VALUE) return
        allPlans(root).values.forEach { entry ->
            if (entry.optBoolean(FIELD_DELIVERED, false)) {
                recordReceipt(context, scope, entry.optString("logicalId", entry.optString("planId")))
            }
        }
    }

    private fun readRoot(preferences: android.content.SharedPreferences): JSONObject = runCatching { JSONObject(preferences.getString(REGISTRY_KEY, "{}") ?: "{}") }.getOrDefault(JSONObject())
    private fun allPlans(root: JSONObject): Map<String, JSONObject> {
        val plans = root.optJSONObject(REGISTRY_PLANS) ?: return emptyMap()
        val result = linkedMapOf<String, JSONObject>()
        plans.keys().forEach { key ->
            // A corrupt individual row is ignored fail-closed. The remaining
            // valid rows can still be cancelled/recovered on the next pass.
            plans.optJSONObject(key)?.let { result[key] = it }
        }
        return result
    }
    private fun plansOf(root: JSONObject, scope: NativeScope): Map<String, JSONObject> = allPlans(root).takeIf { scopeMatches(root, scope) } ?: emptyMap()
    private fun scopeMatches(root: JSONObject, scope: NativeScope): Boolean = root.optString(REGISTRY_REGION) == scope.regionId && root.optString(REGISTRY_OWNER) == scope.ownerHash && root.optString(REGISTRY_TOKEN) == scope.activationToken && root.optLong(REGISTRY_GENERATION, Long.MIN_VALUE) == scope.generation
    private fun persistRootPlans(preferences: android.content.SharedPreferences, root: JSONObject, plans: JSONObject) { root.put(REGISTRY_PLANS, plans); check(preferences.edit().putString(REGISTRY_KEY, root.toString()).commit()) }
    private fun requireValidScope(scope: NativeScope) { check(scope.active && scope.regionId?.matches(Regex("^[a-f0-9]{64}$")) == true && scope.ownerHash?.matches(Regex("^[a-f0-9]{64}$")) == true && !scope.activationToken.isNullOrBlank()) }
}
