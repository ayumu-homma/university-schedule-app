package jp.universityschedule.alarm

import android.content.Context
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence

internal class MorningAlarmCoordinator(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = MorningAlarmPreferences(appContext)
    private val scheduler = MorningAlarmScheduler(appContext, preferences)
    private val notifier = MorningAlarmNotifier(appContext)

    @Synchronized
    fun synchronizeOwner(
        ownerId: String?,
        expectedScope: NativeScope?,
    ): NativeScope {
        require(expectedScope != null) { "Alarm scope is required." }
        val nextOwnerHash = ownerId?.let(::ownerHash)
        val previousOwnerHash = preferences.activeOwnerHash()
        val postScope = NativeScopeFence.transitionOwner(
            appContext,
            expectedScope!!,
            nextOwnerHash,
        )
        if (previousOwnerHash != nextOwnerHash) {
            previousOwnerHash?.let { preferences.setNextOccurrence(it, null) }
            preferences.setActiveOwnerHash(nextOwnerHash)
        }
        if (nextOwnerHash == null) {
            return postScope
        }
        val settings = preferences.read(nextOwnerHash)
        scheduler.scheduleNext(settings)
        return postScope
    }

    @Synchronized
    fun readActive(
        ownerId: String,
        reconcile: Boolean,
        expectedScope: NativeScope?,
    ): MorningAlarmSettings {
        requireExpectedScope(expectedScope)
        val hash = ownerHash(ownerId)
        require(preferences.activeOwnerHash() == hash) { "Alarm owner is not active." }
        requireActiveScope(hash)
        val settings = preferences.read(hash)
        if (reconcile) scheduler.scheduleNext(settings)
        return settings
    }

    @Synchronized
    fun save(
        ownerId: String,
        arguments: Map<*, *>,
        expectedScope: NativeScope?,
    ): MorningAlarmSettings {
        val scope = requireExpectedScope(expectedScope)
        val hash = ownerHash(ownerId)
        require(preferences.activeOwnerHash() == hash) { "Alarm owner is not active." }
        requireActiveScope(hash)
        val settings = MorningAlarmSettings.fromPlatformMap(hash, arguments).copy(
            regionId = scope.regionId,
            generation = scope.generation,
            activationToken = scope.activationToken,
        )
        preferences.save(settings)
        scheduler.cancelTransient()
        notifier.cancel()
        scheduler.scheduleNext(settings)
        return settings
    }

    @Synchronized
    fun scheduleDebug(
        ownerId: String,
        delaySeconds: Int,
        expectedScope: NativeScope?,
    ): MorningAlarmSettings {
        val settings = readActive(
            ownerId,
            reconcile = false,
            expectedScope = expectedScope,
        )
        require(MorningAlarmCapabilities.read(appContext).debugTestAllowed) {
            "Debug alarm testing is unavailable."
        }
        scheduler.scheduleDebug(settings, delaySeconds)
        return settings
    }

    @Synchronized
    fun handleFire(ownerHash: String?, mode: String?, isTest: Boolean) {
        val settings = activeSettings(ownerHash) ?: return
        val supportedMode = mode in setOf(
            ALARM_MODE_REGULAR,
            ALARM_MODE_SNOOZE,
            ALARM_MODE_DEBUG,
        )
        if (!supportedMode) return
        if (!settings.enabled && !isTest) return
        if (mode == ALARM_MODE_REGULAR) {
            scheduler.scheduleNext(settings)
        }
        notifier.show(settings, isTest)
    }

    @Synchronized
    fun handleStop(ownerHash: String?, isTest: Boolean): MorningAlarmSettings? {
        val settings = activeSettings(ownerHash) ?: return null
        scheduler.cancelTransient()
        notifier.cancel()
        if (!isTest || settings.enabled) scheduler.scheduleNext(settings)
        return settings
    }

    @Synchronized
    fun handleSnooze(ownerHash: String?, isTest: Boolean) {
        val settings = activeSettings(ownerHash) ?: return
        if (!settings.enabled && !isTest) return
        notifier.cancel()
        scheduler.scheduleSnooze(settings, isTest)
    }

    @Synchronized
    fun rescheduleActive() {
        val scope = NativeScopeFence.current(appContext)
        if (!scope.active || scope.regionId == null || scope.ownerHash == null) return
        scheduler.cancelAll()
        notifier.cancel()
        val settings = preferences.readActive() ?: return
        require(settings.regionId == scope.regionId)
        require(settings.ownerHash == scope.ownerHash)
        require(settings.generation == scope.generation)
        require(settings.activationToken == scope.activationToken)
        scheduler.scheduleNext(settings)
    }

    fun nextOccurrence(settings: MorningAlarmSettings): Long? =
        preferences.nextOccurrence(settings.ownerHash)

    fun isActiveOwnerHash(ownerHash: String?): Boolean =
        ownerHash != null &&
            preferences.activeOwnerHash() == ownerHash &&
            NativeScopeFence.current(appContext).let {
                it.active && it.ownerHash == ownerHash
            }

    private fun activeSettings(ownerHash: String?): MorningAlarmSettings? {
        if (!isActiveOwnerHash(ownerHash)) return null
        return preferences.read(ownerHash!!)
    }

    private fun requireExpectedScope(expectedScope: NativeScope?): NativeScope {
        val scope = requireNotNull(expectedScope) { "Alarm scope is required." }
        require(NativeScopeFence.matchesExpected(appContext, scope)) {
            "Alarm scope is no longer active."
        }
        return scope
    }

    private fun requireActiveScope(ownerHash: String) {
        val scope = NativeScopeFence.current(appContext)
        require(scope.active && scope.ownerHash == ownerHash) {
            "Alarm scope is no longer active."
        }
    }
}
