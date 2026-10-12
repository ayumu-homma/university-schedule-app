package jp.universityschedule.notification

import android.content.Context
import android.os.Build
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

/** Error returned by the bundled SQLite instance.  [code] is the SQLite
 * primary result code, so BUSY can be retried without string matching and
 * corruption can latch the region outside the database. */
internal class NativeSqliteException(
    val code: Int,
    message: String,
) : RuntimeException(message)

internal val NativeSqliteException.isBusy: Boolean
    get() = (code and 0xff) == 5

internal interface CanonicalSqliteCursor : AutoCloseable {
    fun moveToFirst(): Boolean
    fun moveToNext(): Boolean
    fun getString(index: Int): String
    fun getLong(index: Int): Long
    fun getDouble(index: Int): Double = getLong(index).toDouble()
    fun getBlob(index: Int): ByteArray? = null
    fun getInt(index: Int): Int = getLong(index).toInt()
    fun isNull(index: Int): Boolean
}

internal interface CanonicalSqliteDatabase : AutoCloseable {
    fun rawQuery(sql: String, args: Array<String>? = null): CanonicalSqliteCursor
    fun execSQL(sql: String, args: Array<Any?>? = null)
    fun delete(table: String, whereClause: String, whereArgs: Array<String>? = null): Int
    fun beginTransactionNonExclusive()
    fun setTransactionSuccessful()
    fun endTransaction()
    fun inTransaction(): Boolean
}

/** Region latch used when SQLite reports corruption/NOTADB/IO failure.  The
 * latch is intentionally outside SQLite, so recovery cannot recreate or
 * reseed a damaged canonical file on the next invocation. */
internal object CanonicalStorageHealth {
    private val failures = ConcurrentHashMap<String, String>()
    internal var directorySyncForTests: ((File) -> Unit)? = null

    fun ensureHealthy(context: Context, region: String) {
        validateRegion(region)
        if (File(context.noBackupFilesDir, "storage-health/$region.corrupt").isFile) {
            failures.putIfAbsent(region, "canonical_storage_unhealthy:$region")
        }
        failures[region]?.let { throw IllegalStateException(it) }
    }

    fun record(context: Context, region: String, error: NativeSqliteException) {
        val primary = error.code and 0xff
        if (primary == 10 || primary == 11 || error.code == 26) {
            recordMarker(context, region, "canonical_storage_unhealthy")
        }
    }

    fun recordMarker(context: Context, region: String, reason: String) {
        validateRegion(region)
        require(reason.matches(Regex("[A-Za-z0-9_.:-]{1,64}"))) { "invalid storage health reason" }
        failures.putIfAbsent(region, "canonical_storage_unhealthy:$region")
        try {
            val directory = File(context.noBackupFilesDir, "storage-health")
            check(directory.mkdirs() || directory.isDirectory) { "storage health directory unavailable" }
            val marker = File(directory, "$region.corrupt")
            val temporary = File(
                directory,
                "$region.corrupt.${Thread.currentThread().id}.${System.nanoTime()}.tmp",
            )
            FileOutputStream(temporary).use { output ->
                output.write(reason.toByteArray(Charsets.UTF_8))
                output.flush()
                output.fd.sync()
            }
            if (!temporary.renameTo(marker)) {
                check(marker.isFile) { "storage health marker publish failed" }
                temporary.delete()
            }
            directorySyncForTests?.invoke(directory) ?: run {
                val directoryFd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
                try {
                    Os.fsync(directoryFd)
                } finally {
                    Os.close(directoryFd)
                }
            }
        } catch (error: Throwable) {
            throw IllegalStateException("storage health marker unavailable", error)
        }
    }

    internal fun clearForTests() { failures.clear() }
    internal fun reasonForTests(region: String): String? = failures[region]

    private fun validateRegion(region: String) {
        require(region.matches(Regex("[0-9a-f]{64}"))) { "invalid storage region" }
    }
}

internal object NativeSqliteBridge {
    init { System.loadLibrary("storage_sqlite_jni") }

    @JvmStatic external fun identity(dartAddresses: LongArray, expectedLibraryPaths: Array<String>): Map<String, Any?>
    @JvmStatic external fun open(path: String, readOnly: Boolean, create: Boolean): Long
    @JvmStatic external fun exec(handle: Long, sql: String, args: Array<Any?>?): Int
    @JvmStatic external fun query(handle: Long, sql: String, args: Array<Any?>?): ArrayList<ArrayList<Any?>>?
    @JvmStatic external fun errorCode(handle: Long): Int
    @JvmStatic external fun errorMessage(handle: Long): String
    @JvmStatic external fun autocommit(handle: Long): Int
    @JvmStatic external fun close(handle: Long): Int
}

internal object NativeSqliteIdentity {
    const val SQLITE_OPEN_READONLY = 0x00000001

    fun expectedLibraryPaths(context: Context): Array<String> {
        val applicationInfo = context.applicationInfo
        val paths = linkedSetOf<String>()
        paths += File(applicationInfo.nativeLibraryDir, "libsqlite3.so").absolutePath
        val abis = Build.SUPPORTED_ABIS.ifEmpty { arrayOf(Build.CPU_ABI) }
        val apkPaths = buildList {
            add(applicationInfo.sourceDir)
            addAll(applicationInfo.splitSourceDirs.orEmpty())
        }
        for (apk in apkPaths) {
            for (abi in abis) {
                paths += "$apk!/lib/$abi/libsqlite3.so"
            }
        }
        return paths.toTypedArray()
    }

    fun verify(context: Context, dartAddresses: LongArray): Map<String, Any?> {
        require(dartAddresses.size == 6) { "six Dart SQLite binding addresses are required" }
        val result = NativeSqliteBridge.identity(dartAddresses, expectedLibraryPaths(context))
        val ok = result["ok"] == true || result["ok"] == "true"
        val pointers = result["pointersMatch"] == true || result["pointersMatch"] == "true"
        check(ok && pointers && result["reason"] == "ok") {
            "sqlite_identity_failed:${result["reason"] ?: "unknown"}"
        }
        check((result["threadsafe"] as? Number)?.toInt() == 1) {
            "sqlite_threadsafe_unavailable"
        }
        check((result["vfsAddress"] as? Number)?.toLong()?.let { it != 0L } == true) {
            "sqlite_vfs_unavailable"
        }
        return result
    }

    fun verifyNativeOnly(context: Context): Map<String, Any?> {
        val result = NativeSqliteBridge.identity(LongArray(0), expectedLibraryPaths(context))
        check(result["ok"] == true || result["ok"] == "true") {
            "sqlite_native_identity_failed:${result["reason"] ?: "unknown"}"
        }
        check((result["threadsafe"] as? Number)?.toInt() == 1) {
            "sqlite_native_threadsafe_unavailable"
        }
        check((result["vfsAddress"] as? Number)?.toLong()?.let { it != 0L } == true) {
            "sqlite_native_vfs_unavailable"
        }
        return result
    }

    fun checkHealth(context: Context, region: String) {
        CanonicalStorageHealth.ensureHealthy(context, region)
    }

    fun recordCorruption(context: Context, region: String, reason: String) {
        CanonicalStorageHealth.recordMarker(context, region, reason)
    }
}

internal class NativeSqliteDatabase private constructor(
    private val context: Context?,
    private val region: String?,
    private val handle: Long,
) : CanonicalSqliteDatabase {
    private var transaction = false
    private var transactionSuccessful = false
    private var closed = false

    companion object {
        fun open(context: Context, region: String, path: File): NativeSqliteDatabase {
            NativeSqliteIdentity.verifyNativeOnly(context)
            CanonicalStorageHealth.ensureHealthy(context, region)
            check(path.canonicalFile == path.absoluteFile.canonicalFile && path.isFile) {
                "scoped database unavailable"
            }
            val handle = try {
                NativeSqliteBridge.open(path.canonicalPath, false, false)
            } catch (error: RuntimeException) {
                val wrapped = NativeSqliteException(NativeSqliteBridge.errorCode(0L), error.message ?: "sqlite open failed")
                try {
                    CanonicalStorageHealth.record(context, region, wrapped)
                } catch (markerFailure: RuntimeException) {
                    wrapped.addSuppressed(markerFailure)
                }
                wrapped.addSuppressed(error)
                throw wrapped
            }
            return NativeSqliteDatabase(context, region, handle)
        }

        internal fun openScratch(context: Context, region: String, path: File): NativeSqliteDatabase {
            NativeSqliteIdentity.verifyNativeOnly(context)
            val handle = NativeSqliteBridge.open(path.canonicalPath, false, true)
            return NativeSqliteDatabase(null, null, handle)
        }

        /** Isolated test seam. Production code never calls this. */
    }

    override fun rawQuery(sql: String, args: Array<String>?): CanonicalSqliteCursor {
        ensureOpen()
        val converted = args?.map { it as Any? }?.toTypedArray()
        val rows = try { NativeSqliteBridge.query(handle, sql, converted) }
        catch (error: RuntimeException) { throw checked(error) }
        if (rows == null) throw checked(null)
        return NativeSqliteCursor(rows)
    }

    override fun execSQL(sql: String, args: Array<Any?>?) {
        ensureOpen()
        val result = try { NativeSqliteBridge.exec(handle, sql, args) }
        catch (error: RuntimeException) { throw checked(error) }
        if (result != 0) throw checked(null)
    }

    override fun delete(table: String, whereClause: String, whereArgs: Array<String>?): Int {
        require(table.matches(Regex("[A-Za-z_][A-Za-z0-9_]*"))) { "invalid table" }
        execSQL("DELETE FROM $table WHERE $whereClause", whereArgs?.map { it as Any? }?.toTypedArray())
        return rawQuery("SELECT changes()", null).use { cursor ->
            cursor.moveToFirst(); cursor.getLong(0)
        }.toInt().coerceAtLeast(0)
    }

    override fun beginTransactionNonExclusive() {
        check(!transaction) { "transaction already active" }
        execSQL("BEGIN IMMEDIATE")
        transaction = true
        transactionSuccessful = false
    }

    override fun setTransactionSuccessful() {
        check(transaction) { "transaction not active" }
        transactionSuccessful = true
    }

    override fun endTransaction() {
        check(transaction) { "transaction not active" }
        val shouldCommit = transactionSuccessful
        var failure = if (shouldCommit) executeCommit() else executeUnchecked("ROLLBACK")
        if (failure != null && shouldCommit) {
            val rollbackFailure = executeUnchecked("ROLLBACK")
            if (rollbackFailure != null) failure.addSuppressed(rollbackFailure)
        }
        refreshTransactionState()
        if (failure != null) transactionSuccessful = false
        if (failure != null) throw failure
    }

    override fun inTransaction(): Boolean {
        if (closed) return false
        refreshTransactionState()
        return transaction
    }

    override fun close() {
        if (closed) return
        refreshTransactionState()
        val unfinished = transaction
        val rollbackFailure = if (unfinished) executeUnchecked("ROLLBACK") else null
        refreshTransactionState()
        val result = NativeSqliteBridge.close(handle)
        if (result != 0) {
            val closeFailure = NativeSqliteException(result, "sqlite close failed")
            if (rollbackFailure != null) closeFailure.addSuppressed(rollbackFailure)
            throw closeFailure
        }
        closed = true
        transaction = false
        transactionSuccessful = false
        if (rollbackFailure != null) throw rollbackFailure
    }

    private fun ensureOpen() {
        check(!closed) { "sqlite database is closed" }
        if (context != null && region != null) CanonicalStorageHealth.ensureHealthy(context, region)
    }

    private fun executeUnchecked(sql: String): NativeSqliteException? {
        val result = try {
            NativeSqliteBridge.exec(handle, sql, null)
        } catch (error: RuntimeException) {
            return checked(error, recordHealth = false)
        }
        return if (result == 0) null else checked(null, recordHealth = false)
    }

    private fun executeCommit(): RuntimeException? {
        return try {
            ensureOpen()
            val result = NativeSqliteBridge.exec(handle, "COMMIT", null)
            if (result == 0) null else checked(null)
        } catch (error: RuntimeException) {
            error
        }
    }

    private fun refreshTransactionState() {
        val autocommit = NativeSqliteBridge.autocommit(handle)
        when (autocommit) {
            0 -> {
                transaction = true
            }
            1 -> {
                transaction = false
                transactionSuccessful = false
            }
        }
    }

    private fun checked(cause: RuntimeException?, recordHealth: Boolean = true): NativeSqliteException {
        val error = NativeSqliteException(
            NativeSqliteBridge.errorCode(handle),
            NativeSqliteBridge.errorMessage(handle),
        )
        if (recordHealth && context != null && region != null) {
            try {
                CanonicalStorageHealth.record(context, region, error)
            } catch (markerFailure: RuntimeException) {
                error.addSuppressed(markerFailure)
            }
        }
        if (cause != null) error.addSuppressed(cause)
        return error
    }
}

private class NativeSqliteCursor(
    private val rows: List<List<Any?>>,
) : CanonicalSqliteCursor {
    private var index = -1
    private var closed = false

    override fun moveToFirst(): Boolean { checkOpen(); index = if (rows.isEmpty()) -1 else 0; return index >= 0 }
    override fun moveToNext(): Boolean { checkOpen(); index++; return index in rows.indices }
    override fun getString(index: Int): String = value(index)?.toString() ?: throw IllegalStateException("null sqlite text")
    override fun getLong(index: Int): Long = (value(index) as? Number)?.toLong() ?: value(index)?.toString()?.toLongOrNull() ?: throw IllegalStateException("invalid sqlite integer")
    override fun isNull(index: Int): Boolean = value(index) == null
    override fun getDouble(index: Int): Double = (value(index) as? Number)?.toDouble() ?: super.getDouble(index)
    override fun getBlob(index: Int): ByteArray? = value(index) as? ByteArray
    override fun close() { closed = true }
    private fun value(column: Int): Any? { checkOpen(); check(this.index in rows.indices) { "cursor is not positioned" }; return rows[this.index][column] }
    private fun checkOpen() { check(!closed) { "cursor is closed" } }
}
