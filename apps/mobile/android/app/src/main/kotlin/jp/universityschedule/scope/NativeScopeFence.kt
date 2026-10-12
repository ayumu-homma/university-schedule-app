package jp.universityschedule.scope

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.alarm.MorningAlarmScheduler
import jp.universityschedule.alarm.MorningAlarmNotifier
import jp.universityschedule.notification.LocalNotificationCoordinator
import jp.universityschedule.notification.NotificationRefillScheduler
import jp.universityschedule.widget.WeeklyTimetableWidget
import java.security.MessageDigest
import java.util.UUID

/**
 * The process-independent boundary for all native derived work.
 *
 * Receivers and widgets call [current] or [matches] at their final side effect
 * boundary. A new activation token is created for every owner or region
 * transition, including a return to a previous owner.
 */
data class NativeScope(
    val regionId: String?,
    val ownerHash: String?,
    val activationToken: String?,
    val generation: Long,
    val active: Boolean,
)

object NativeScopeFence {
    private const val preferencesName = "native_scope_v1"
    private const val keyStamp = "build_stamp"
    private const val keyRegion = "region_id"
    private const val keyOwner = "owner_hash"
    private const val keyToken = "activation_token"
    private const val keyGeneration = "generation"
    private const val keyActive = "active"
    private const val inactiveRegion = ""

    @Synchronized
    fun prepare(context: Context, regionId: String): NativeScope {
        require(regionId.matches(Regex("^[a-f0-9]{64}$")))
        val preferences = preferences(context)
        ensureBuildStamp(context, preferences)
        val current = read(preferences)
        if (current.regionId != regionId || current.active) {
            return persist(
                context,
                preferences,
                regionId = regionId,
                ownerHash = null,
                active = false,
                generation = current.generation + 1,
            )
        }
        return current
    }

    @Synchronized
    fun activate(context: Context, regionId: String, ownerHash: String): NativeScope {
        require(regionId.matches(Regex("^[a-f0-9]{64}$")))
        require(ownerHash.matches(Regex("^[a-f0-9]{64}$")))
        val preferences = preferences(context)
        ensureBuildStamp(context, preferences)
        val current = read(preferences)
        if (current.active && current.regionId == regionId && current.ownerHash == ownerHash) {
            return current
        }
        // Revoke every derived artifact before an identity transition. The
        // next activation gets a new token, so old callbacks cannot relabel
        // the cleared widget/alarm state for the new owner.
        clearDerived(context, current.activationToken, current)
        return persist(
            context,
            preferences,
            regionId = regionId,
            ownerHash = ownerHash,
            active = true,
            generation = current.generation + 1,
        )
    }

    @Synchronized
    fun activateOwner(context: Context, regionId: String, ownerId: String): NativeScope {
        val normalized = ownerId.trim()
        require(normalized.isNotEmpty() && normalized.length <= 256)
        val hash = MessageDigest.getInstance("SHA-256")
            .digest(normalized.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }
        return activate(context, regionId, hash)
    }

    /**
     * Atomically compares the complete pre-transition scope and activates the
     * next owner under the same monitor. Every caller must use the returned
     * post-transition scope for subsequent derived work.
     */
    @Synchronized
    fun transitionOwner(
        context: Context,
        expected: NativeScope,
        ownerHash: String?,
    ): NativeScope {
        require(ownerHash == null || ownerHash.matches(Regex("^[a-f0-9]{64}$")))
        val preferences = preferences(context)
        ensureBuildStamp(context, preferences)
        val current = read(preferences)
        check(current == expected) { "Native scope changed before owner transition." }
        val regionId = current.regionId
        if (ownerHash == null) {
            return persist(
                context,
                preferences,
                regionId = regionId,
                ownerHash = null,
                active = false,
                generation = current.generation + 1,
            )
        }
        require(regionId != null) { "Native storage region is not prepared." }
        if (current.active && current.ownerHash == ownerHash) return current
        clearDerived(context, current.activationToken, current)
        return persist(
            context,
            preferences,
            regionId = regionId,
            ownerHash = ownerHash,
            active = true,
            generation = current.generation + 1,
        )
    }

    @Synchronized
    fun deactivate(context: Context): NativeScope {
        val preferences = preferences(context)
        ensureBuildStamp(context, preferences)
        val current = read(preferences)
        return persist(
            context,
            preferences,
            regionId = current.regionId,
            ownerHash = null,
            active = false,
            generation = current.generation + 1,
        )
    }

    @Synchronized
    fun current(context: Context): NativeScope {
        val preferences = preferences(context)
        ensureBuildStamp(context, preferences)
        return read(preferences)
    }

    @Synchronized
    fun matches(
        context: Context,
        regionId: String?,
        ownerHash: String?,
        generation: Long,
        activationToken: String?,
    ): Boolean {
        val current = current(context)
        return current.active &&
            current.regionId == regionId &&
            current.ownerHash == ownerHash &&
            current.generation == generation &&
            current.activationToken == activationToken
    }

    @Synchronized
    fun matchesExpected(context: Context, expected: NativeScope): Boolean {
        val current = current(context)
        return current == expected
    }

    fun matchesIntent(context: Context, intent: Intent?): Boolean {
        if (intent == null) return false
        val regionId = intent.getStringExtra("scope_region_id")
        val ownerHash = intent.getStringExtra("scope_owner_hash")
        val token = intent.getStringExtra("scope_activation_token")
        val generation = if (intent.hasExtra("scope_generation")) {
            intent.getLongExtra("scope_generation", Long.MIN_VALUE)
        } else {
            Long.MIN_VALUE
        }
        return generation != Long.MIN_VALUE && matches(
            context,
            regionId,
            ownerHash,
            generation,
            token,
        )
    }

    private fun ensureBuildStamp(context: Context, preferences: SharedPreferences) {
        val stamp = BuildConfig.STORAGE_CONFIG_STAMP
        if (preferences.getString(keyStamp, null) == stamp) return
        val previousScope = read(preferences)
        val previousToken = preferences.getString(keyToken, null)
        val committed = preferences.edit()
            .putString(keyStamp, stamp)
            .putString(keyRegion, inactiveRegion)
            .remove(keyOwner)
            .remove(keyToken)
            .putLong(keyGeneration, preferences.getLong(keyGeneration, 0L) + 1L)
            .putBoolean(keyActive, false)
            .commit()
        check(committed) { "Could not persist the native build fence." }
        clearDerived(context, previousToken, previousScope)
    }

    private fun persist(
        context: Context,
        preferences: SharedPreferences,
        regionId: String?,
        ownerHash: String?,
        active: Boolean,
        generation: Long,
    ): NativeScope {
        val previousScope = read(preferences)
        val previousToken = preferences.getString(keyToken, null)
        val token = if (active) UUID.randomUUID().toString() else null
        check(
            preferences.edit()
                .putString(keyStamp, BuildConfig.STORAGE_CONFIG_STAMP)
                .putString(keyRegion, regionId ?: inactiveRegion)
                .apply { if (ownerHash == null) remove(keyOwner) else putString(keyOwner, ownerHash) }
                .apply { if (token == null) remove(keyToken) else putString(keyToken, token) }
                .putLong(keyGeneration, generation)
                .putBoolean(keyActive, active)
                .commit(),
        ) { "Could not persist native scope fence." }
        if (!active) {
            NotificationRefillScheduler.cancelRefill(context)
            clearDerived(context, previousToken, previousScope)
        } else {
            NotificationRefillScheduler.ensureDaily(context)
        }
        return NativeScope(regionId, ownerHash, token, generation, active)
    }

    private fun preferences(context: Context): SharedPreferences =
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)

    private fun clearDerived(
        context: Context,
        previousToken: String? = null,
        previousScope: NativeScope? = null,
    ) {
        // Ordinary notifications have their own registry and tags. Clear that
        // registry while the scope fence is held so an A→B→A callback cannot
        // revive a plan from the previous activation.
        LocalNotificationCoordinator.clearForScope(context, previousToken)
        LocalNotificationCoordinator.clearRefillContext(context)
        previousScope?.let { LocalNotificationCoordinator.cancelSummary(context, it) }
        NotificationRefillScheduler.cancelRefill(context)
        MorningAlarmScheduler(context).cancelAll(previousToken)
        // The morning alarm owns one ongoing notification which must not
        // survive an owner transition. Cancel it by its stable id instead of
        // clearing notifications belonging to other coordinators.
        MorningAlarmNotifier(context).cancel()
        context.getSharedPreferences(
            "weekly_timetable_widget",
            Context.MODE_PRIVATE,
        ).edit().clear().commit()
        // Ordinary notifications are cancelled by the scoped coordinator;
        // leave morning-alarm and other channels owned by their coordinators.
        // Replace already-published RemoteViews immediately, instead of
        // waiting for the next periodic widget callback.
        WeeklyTimetableWidget.updateAll(context)
    }

    private fun read(preferences: SharedPreferences): NativeScope = NativeScope(
        regionId = preferences.getString(keyRegion, null)?.takeIf { it.isNotEmpty() },
        ownerHash = preferences.getString(keyOwner, null),
        activationToken = preferences.getString(keyToken, null),
        generation = preferences.getLong(keyGeneration, 0L),
        active = preferences.getBoolean(keyActive, false),
    )
}
