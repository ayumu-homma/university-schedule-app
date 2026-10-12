package jp.universityschedule.notification

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.net.Uri
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.app.MainActivity
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Exact alarm receiver. All mutable state is checked under the native scope
 * monitor and a short SQLite writer-reservation transaction immediately before
 * the notification side effect. */
class LocalNotificationReceiver internal constructor(
    private val deliveryExecutor: Executor,
) : BroadcastReceiver() {
    constructor() : this(defaultDeliveryExecutor)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != LOCAL_NOTIFICATION_ACTION || !NativeScopeFence.matchesIntent(context, intent)) return
        val pending = goAsync()
        deliveryExecutor.execute {
            try {
                deliver(context, intent)
            } finally {
                pending?.finish()
            }
        }
    }

    private fun deliver(context: Context, intent: Intent) {
        val bucketMembers = LocalNotificationCoordinator.bucketMemberIntents(context, intent)
        if (bucketMembers.isNotEmpty()) {
            if (shouldConsolidate(context, bucketMembers)) {
                deliverSummary(context, bucketMembers)
            } else {
                try {
                    bucketMembers.forEach { member -> deliverSingle(context, member, recoverAfter = false) }
                } finally {
                    // Reallocation between members would invalidate the
                    // remaining due members of this same OS wakeup.
                    LocalNotificationCoordinator.recover(context, forceReinstall = false)
                }
            }
            return
        }
        deliverSingle(context, intent)
    }

    private fun shouldConsolidate(context: Context, members: List<Intent>): Boolean {
        if (members.size > 6) return true
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return if (Build.VERSION.SDK_INT >= 23) manager.activeNotifications.size + members.size > 40 else false
    }

    private fun deliverSummary(context: Context, members: List<Intent>) {
        val scope = NativeScopeFence.current(context)
        if (!scope.active) return
        val db = runCatching { LocalNotificationCoordinator.openScopedDatabase(context, scope.regionId!!) }.getOrNull()
        if (db == null) {
            LocalNotificationCoordinator.retryProjectionBatch(context, members.map {
                it to it.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE)
            })
            return
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        var posting = emptyList<Intent>()
        val transient = mutableListOf<Pair<Intent, Long>>()
        var delivered = false
        try {
            synchronized(NativeScopeFence) {
                if (!NativeScopeFence.matches(context, scope.regionId, scope.ownerHash, scope.generation, scope.activationToken)) return
                LocalNotificationCoordinator.withRegistryLock {
                    db.beginTransactionNonExclusive()
                    try {
                        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return@withRegistryLock
                        if (!manager.areNotificationsEnabled() || (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(LOCAL_NOTIFICATION_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE)) return@withRegistryLock
                        val now = NotificationTime.now()
                        val valid = members.filter { member ->
                            val identity = member.getStringExtra(EXTRA_IDENTITY).orEmpty()
                            val fingerprint = member.getStringExtra(EXTRA_FINGERPRINT).orEmpty()
                            val registered = NativeScopeFence.matchesIntent(context, member) &&
                                ownerHash(member.getStringExtra(EXTRA_OWNER_USER_ID).orEmpty()) == scope.ownerHash &&
                                LocalNotificationCoordinator.isRegistered(context, identity, fingerprint) &&
                                !LocalNotificationCoordinator.isReceiptRecordedForDelivery(context, scope, member.getStringExtra(EXTRA_PLAN_ID).orEmpty())
                            if (!registered) false else {
                                val validation = validateRow(context, db, member, now)
                                if (validation.transientStale) transient += member to validation.occurrenceAtMs
                                validation.valid
                            }
                        }.filter { NotificationTime.now() < it.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE) }
                        if (valid.isEmpty()) return@withRegistryLock
                        posting = LocalNotificationCoordinator.prepareSummary(context, scope, valid)
                        if (posting.isEmpty()) return@withRegistryLock
                        val target = Intent(context, MainActivity::class.java).apply {
                            action = Intent.ACTION_VIEW
                            data = Uri.parse("${BuildConfig.DEEP_LINK_SCHEME}://notifications/inbox")
                            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            putExtra(EXTRA_SCOPE_REGION, scope.regionId)
                            putExtra(EXTRA_SCOPE_OWNER, scope.ownerHash)
                            putExtra(EXTRA_SCOPE_TOKEN, scope.activationToken)
                            putExtra(EXTRA_SCOPE_GENERATION, scope.generation)
                        }
                        val pending = PendingIntent.getActivity(context, 0, target,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, LOCAL_NOTIFICATION_CHANNEL)
                            else @Suppress("DEPRECATION") Notification.Builder(context)
                        val notification = builder
                            .setSmallIcon(context.applicationInfo.icon)
                            .setContentTitle("予定の通知")
                            .setContentText("新しい通知が${posting.size}件あります")
                            .setSubText("通知一覧で各予定を確認")
                            .setNumber(posting.size).setAutoCancel(true).setOnlyAlertOnce(true)
                            .setVisibility(Notification.VISIBILITY_PRIVATE).setContentIntent(pending).build()
                        // Scope, registry, and canonical writer reservation remain held
                        // through the sole OS side effect and its durable acknowledgement.
                        manager.notify(LocalNotificationCoordinator.summaryTag(scope), LOCAL_NOTIFICATION_SUMMARY_ID, notification)
                        delivered = LocalNotificationCoordinator.markSummaryDelivered(context, scope, posting)
                        if (delivered) {
                            manager.activeNotifications.filter {
                                it.id == LOCAL_NOTIFICATION_ID && it.tag?.startsWith("v1|r=${scope.regionId}|o=${scope.ownerHash}|") == true
                            }.forEach { manager.cancel(it.tag, it.id) }
                        }
                        db.setTransactionSuccessful()
                    } finally {
                        if (db.inTransaction()) db.endTransaction()
                    }
                }
            }
        } catch (error: RuntimeException) {
            // Receipt/registry state distinguishes posted from retryable work.
            if (error is NativeSqliteException && posting.isEmpty()) {
                transient.clear()
                transient += members.map { it to it.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE) }
            }
        } finally {
            LocalNotificationCoordinator.closeScopedDatabase(db)
            if (!delivered) posting.forEach {
                LocalNotificationCoordinator.retryPosting(context, it, it.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE), reallocate = false)
            }
            LocalNotificationCoordinator.retryProjectionBatch(context, transient, reallocate = false)
            LocalNotificationCoordinator.recover(context, forceReinstall = false)
        }
    }

    private fun deliverSingle(context: Context, intent: Intent, recoverAfter: Boolean = true) {
        val scope = NativeScopeFence.current(context)
        if (!NativeScopeFence.matchesIntent(context, intent)) return
        val owner = intent.getStringExtra(EXTRA_OWNER_USER_ID) ?: return
        if (ownerHash(owner) != scope.ownerHash) return
        val identity = intent.getStringExtra(EXTRA_IDENTITY) ?: return
        val fingerprint = intent.getStringExtra(EXTRA_FINGERPRINT) ?: return
        if (!LocalNotificationCoordinator.isRegistered(context, identity, fingerprint)) return
        if (LocalNotificationCoordinator.isReceiptRecordedForDelivery(context, scope, intent.getStringExtra(EXTRA_LOGICAL_ID).orEmpty())) return
        if (LocalNotificationCoordinator.isDelivered(context, identity, fingerprint)) {
            if (recoverAfter) LocalNotificationCoordinator.recover(context, forceReinstall = false)
            return
        }
        val occurrence = intent.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE)
        if (occurrence == Long.MIN_VALUE) return
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled() || (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(LOCAL_NOTIFICATION_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE)) return
        val db = runCatching {
            // Coordinator owns the validated path policy. No intent-supplied
            // path is opened here.
            LocalNotificationCoordinator.openScopedDatabase(context, scope.regionId!!)
        }.getOrElse {
            // A missing/temporarily locked projection is retryable while the
            // persisted plan is still registered. The retry helper enforces
            // the bounded attempt/deadline policy and never opens an
            // arbitrary path from the alarm intent.
            LocalNotificationCoordinator.retryIfTemporarilyStale(context, intent, occurrence, reallocate = recoverAfter)
            return
        }
        var posting = false
        var retryDeadline = occurrence
        try {
            synchronized(NativeScopeFence) {
                if (!NativeScopeFence.matchesIntent(context, intent)) return
                LocalNotificationCoordinator.withRegistryLock {
                    db.beginTransactionNonExclusive()
                    val lockedNow = NotificationTime.now()
                    val validation = validateRow(context, db, intent, lockedNow)
                    retryDeadline = validation.occurrenceAtMs
                    if (!validation.valid) {
                        if (validation.transientStale) LocalNotificationCoordinator.retryIfTemporarilyStale(context, intent, validation.occurrenceAtMs, reallocate = recoverAfter)
                        db.endTransaction()
                        return@withRegistryLock
                    }
                    // The writer reservation can outlive the initial alarm
                    // timestamp. Re-read the clock after acquiring it and just
                    // before the OS side effect; never fire after cutoff.
                    if (lockedNow >= validation.occurrenceAtMs || NotificationTime.now() >= validation.occurrenceAtMs) {
                        db.endTransaction()
                        return@withRegistryLock
                    }
                    // Persist an in-flight marker before the OS call. If the
                    // process dies, recovery reuses the same tag/ID and
                    // setOnlyAlertOnce prevents a second alert.
                    if (!LocalNotificationCoordinator.markPosting(context, identity, fingerprint) ||
                        !LocalNotificationCoordinator.isRegistered(context, identity, fingerprint) ||
                        LocalNotificationCoordinator.isDelivered(context, identity, fingerprint)
                    ) {
                        db.endTransaction()
                        return@withRegistryLock
                    }
                    posting = true
                    val tap = LocalNotificationCoordinator.tapIntent(context, intent)
                    val tapPending = PendingIntent.getActivity(
                        context, 0, tap, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, LOCAL_NOTIFICATION_CHANNEL)
                    else @Suppress("DEPRECATION") Notification.Builder(context)
                    val publicBuilder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, LOCAL_NOTIFICATION_CHANNEL)
                    else @Suppress("DEPRECATION") Notification.Builder(context)
                    val publicVersion = publicBuilder
                        .setSmallIcon(context.applicationInfo.icon)
                        .setContentTitle("予定の通知")
                        .setContentText("予定があります")
                        .build()
                    val notification = builder
                        .setSmallIcon(context.applicationInfo.icon)
                        .setContentTitle(intent.getStringExtra(EXTRA_TITLE) ?: "予定の通知")
                        .setContentText(intent.getStringExtra(EXTRA_BODY) ?: "予定")
                        .setVisibility(Notification.VISIBILITY_PRIVATE)
                        .setPublicVersion(publicVersion)
                        .setOnlyAlertOnce(true)
                        .setAutoCancel(true)
                        .setContentIntent(tapPending)
                        .build()
                    if (NotificationTime.now() >= validation.occurrenceAtMs) {
                        db.endTransaction()
                        return@withRegistryLock
                    }
                    LocalNotificationCoordinator.recordInboxReferences(context, listOf(intent), representedInSummary = false)
                    manager.notify(identity, LOCAL_NOTIFICATION_ID, notification)
                    if (!LocalNotificationCoordinator.markDelivered(context, identity, fingerprint)) {
                        db.endTransaction()
                        return@withRegistryLock
                    }
                    db.setTransactionSuccessful()
                    db.endTransaction()
                }
            }
        } catch (error: RuntimeException) {
            runCatching { if (db.inTransaction()) db.endTransaction() }
            if (!posting && error is NativeSqliteException) {
                LocalNotificationCoordinator.retryIfTemporarilyStale(context, intent, retryDeadline, reallocate = recoverAfter)
            }
        } finally {
            LocalNotificationCoordinator.closeScopedDatabase(db)
            if (posting) {
                if (!LocalNotificationCoordinator.isDelivered(context, identity, fingerprint)) {
                    LocalNotificationCoordinator.retryPosting(context, intent, retryDeadline, reallocate = recoverAfter)
                }
                if (recoverAfter) LocalNotificationCoordinator.recover(context, forceReinstall = false)
            }
        }
    }

    private data class Validation(val valid: Boolean, val transientStale: Boolean, val occurrenceAtMs: Long = Long.MIN_VALUE)

    private fun validateRow(context: Context, db: CanonicalSqliteDatabase, intent: Intent, now: Long): Validation {
        val id = intent.getStringExtra(EXTRA_PLAN_ID) ?: return Validation(false, false)
        val owner = intent.getStringExtra(EXTRA_OWNER_USER_ID) ?: return Validation(false, false)
        val expected = intent.getStringExtra(EXTRA_FINGERPRINT) ?: return Validation(false, false)
        return db.rawQuery(
            "SELECT o.fingerprint,o.source_epoch,o.projection_epoch,o.reason,o.status,o.trigger_at,o.occurrence_at,p.source_epoch,p.projection_epoch,r.epoch FROM local_notification_occurrences o JOIN local_notification_projection_states p ON p.owner_user_id=o.owner_user_id JOIN local_notification_source_revisions r ON r.id=1 WHERE o.id=? AND o.owner_user_id=? LIMIT 1",
            arrayOf(id, owner),
        ).use { c ->
            if (!c.moveToFirst()) return@use Validation(false, false)
            val identity = intent.getStringExtra(EXTRA_IDENTITY).orEmpty()
            // The identity is canonicalized with the same form used by the
            // coordinator (URLEncoder, including its handling of spaces).
            // Do not use Uri.encode here: a tap/alarm for a plan id containing
            // reserved characters must validate against the exact plan key.
            val encodedId = java.net.URLEncoder.encode(id, "UTF-8")
            if (c.getString(0) != expected || !identity.startsWith("v1|r=") ||
                !identity.contains("|id=$encodedId|") || c.getString(4) != "desired") {
                return@use Validation(false, false, c.getLong(6))
            }
            val retryPast = c.getString(3) == "past" &&
                (LocalNotificationCoordinator.isRetryDue(context, identity, expected, now, c.getLong(6)) ||
                    LocalNotificationCoordinator.hasAcknowledgedDueWakeup(context, identity, expected, now))
            if (c.getString(3) != "eligible" && !retryPast) return@use Validation(false, false, c.getLong(6))
            val stable = c.getLong(1) == c.getLong(9) && c.getLong(7) == c.getLong(9) && c.getLong(2) == c.getLong(8)
            val timing = c.getLong(5) <= now && now < c.getLong(6)
            Validation(stable && timing, !stable && c.getString(3) == "eligible" && c.getString(4) == "desired", c.getLong(6))
        }
    }

    private fun ownerHash(owner: String): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(owner.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    companion object {
        private val defaultDeliveryExecutor = Executors.newCachedThreadPool()
    }
}
