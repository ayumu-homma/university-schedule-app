package jp.universityschedule.notification

/** Production uses the wall clock. Native fixtures inject elapsed time without
 * mutating canonical notification rows or the device's authentication clock. */
internal object NotificationTime {
    internal var nowForTests: (() -> Long)? = null
    fun now(): Long = nowForTests?.invoke() ?: System.currentTimeMillis()
}
