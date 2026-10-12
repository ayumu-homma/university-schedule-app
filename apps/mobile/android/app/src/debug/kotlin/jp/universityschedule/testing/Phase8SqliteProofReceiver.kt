package jp.universityschedule.testing

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.notification.CanonicalSqliteDatabase
import jp.universityschedule.notification.NativeSqliteDatabase
import jp.universityschedule.notification.NativeSqliteException
import jp.universityschedule.notification.NativeSqliteIdentity
import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** Bounded debug proof over disposable cache SQLite files only. */
class Phase8SqliteProofReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        setResultCode(Activity.RESULT_CANCELED)
        if (!BuildConfig.DEBUG || BuildConfig.FLAVOR != "staging" || intent.action != ACTION) return
        val scenario = intent.getStringExtra(EXTRA_SCENARIO)?.lowercase() ?: return
        if (scenario !in SCENARIOS) return
        val pending = goAsync()
        proofExecutor.execute {
            val startedAtMs = SystemClock.elapsedRealtime()
            val root = File(context.cacheDir, "phase8-sqlite-proof-${System.currentTimeMillis()}")
            val artifact = File(root, "proof.json")
            val result = linkedMapOf<String, Any?>(
                "status" to "FAIL", "scenario" to scenario,
                "databaseFilesCacheOnly" to true, "canonicalAccessed" to false,
                "driverContract" to "one cold stopped staging process per scenario; background broadcast accepted",
                "proofTimeoutMs" to 50000L,
                "deadlineEnforced" to true,
            )
            try {
                check(root.mkdirs() || root.isDirectory) { "proof cache root unavailable" }
                runScenario(context, root, scenario, result)
                result["status"] = "PASS"
            } catch (error: Throwable) {
                result["errorType"] = error.javaClass.name
                result["error"] = error.message ?: error.toString()
            }
            result["elapsedMs"] = SystemClock.elapsedRealtime() - startedAtMs
            try {
                artifact.writeText(toJson(result), StandardCharsets.UTF_8)
                pending.setResultCode(if (result["status"] == "PASS") Activity.RESULT_OK else Activity.RESULT_CANCELED)
                pending.setResultExtras(Bundle().apply {
                    putString(EXTRA_ARTIFACT, artifact.path)
                    putString(EXTRA_SCENARIO, scenario)
                    putString("status", result["status"].toString())
                })
            } finally {
                pending.finish()
            }
        }
    }

    private fun runScenario(
        context: Context,
        root: File,
        scenario: String,
        result: MutableMap<String, Any?>,
    ) {
        val deadline = ProofDeadline()
        result["scenario"] = scenario
        if (scenario != "dart-first") addNativeIdentity(context, result, deadline)
        when (scenario) {
            "native-first" -> runNativeFirst(context, root, result, deadline)
            "dart-first" -> runDartFirst(context, root, result, deadline)
            "concurrent" -> runConcurrent(context, root, result, deadline)
            "health-contention" -> runHealthContention(context, root, result, deadline)
        }
        result.putAll(runCorruptionProof(context, root, deadline))
        deadline.check()
    }

    private fun addNativeIdentity(context: Context, result: MutableMap<String, Any?>, deadline: ProofDeadline) {
        deadline.check()
        val nativeIdentity = NativeSqliteIdentity.verifyNativeOnly(context)
        result["nativeIdentity"] = nativeIdentity
        result["nativeLibraryPath"] = nativeIdentity["libraryPath"]
        result["nativeSourceId"] = nativeIdentity["sourceId"]
        result["nativeVfsAddress"] = nativeIdentity["vfsAddress"]
        result["nativeThreadsafe"] = nativeIdentity["threadsafe"]
    }

    private fun runNativeFirst(context: Context, root: File, result: MutableMap<String, Any?>, deadline: ProofDeadline) {
        deadline.check()
        val path = File(root, "native-first.sqlite")
        val database = NativeSqliteDatabase.openScratch(context, "phase8-proof-native-first", path)
        try {
            createFixture(database)
            insertNative(database, "native-seed\u0000🎓")
            rollbackMustNotChange(database, 1L)
            result["nativeOpenedBeforeDart"] = true
        } finally { database.close() }
        val dart = runDartEngine(context, path, createSchema = false, holdForNative = false, deadline = deadline)
        result.putAll(dart.asProof("single-dart"))
        check(dart.ok) { dart.error ?: "native-first Dart proof failed" }
        check(dart.rows == 2L) { "native-first expected exactly 2 rows, got ${dart.rows}" }
        val reopened = NativeSqliteDatabase.openScratch(context, "phase8-proof-native-first-reopen", path)
        try {
            verifyTypedRow(reopened, "native-seed\u0000🎓", 9223372036854775807L)
            verifyTypedRow(reopened, "dart-engine\u0000🎓", 9223372036854775807L)
            verifyExactTexts(reopened, setOf("native-seed\u0000🎓", "dart-engine\u0000🎓"))
            verifyIntegrity(reopened, result)
            check(countRows(reopened) == 2L) { "native-first reopen row count mismatch" }
            verifyInvalidNullBindRange(reopened, 2L, result)
        } finally { reopened.close() }
        result["expectedRows"] = 2L
        result["actualRows"] = 2L
        result["rollback"] = true
        result["deterministicClose"] = true
        result["order"] = "native-first"
    }

    private fun runDartFirst(context: Context, root: File, result: MutableMap<String, Any?>, deadline: ProofDeadline) {
        val path = File(root, "dart-first.sqlite")
        val dart = runDartEngine(context, path, createSchema = true, holdForNative = false, deadline = deadline)
        result.putAll(dart.asProof("single-dart"))
        check(dart.ok) { dart.error ?: "dart-first proof failed" }
        check(dart.rows == 1L) { "dart-first expected exactly 1 Dart row, got ${dart.rows}" }
        // Dart's verified binding is the first SQLite load in this scenario.
        addNativeIdentity(context, result, deadline)
        val reopened = NativeSqliteDatabase.openScratch(context, "phase8-proof-dart-first-reopen", path)
        try {
            verifyTypedRow(reopened, "dart-engine\u0000🎓", 9223372036854775807L)
            verifyExactTexts(reopened, setOf("dart-engine\u0000🎓"))
            verifyIntegrity(reopened, result)
            check(countRows(reopened) == 1L) { "dart-first native reopen row count mismatch" }
            verifyInvalidNullBindRange(reopened, 1L, result)
        } finally { reopened.close() }
        result["expectedRows"] = 1L
        result["actualRows"] = 1L
        result["deterministicClose"] = true
        result["nativeOpenedAfterDart"] = true
        result["order"] = "dart-first"
    }

    private fun runConcurrent(context: Context, root: File, result: MutableMap<String, Any?>, deadline: ProofDeadline) {
        deadline.check()
        val path = File(root, "concurrent.sqlite")
        val seed = NativeSqliteDatabase.openScratch(context, "phase8-proof-concurrent-seed", path)
        try { createFixture(seed); insertNative(seed, "native-seed\u0000🎓") } finally { seed.close() }

        val first = createDartEngine(context, path, 0, deadline)
        val second = createDartEngine(context, path, 1, deadline)
        val nativeBusy = CountDownLatch(1)
        val nativeBusyCode = intArrayOf(-1)
        var nativeWriter: java.util.concurrent.Future<*>? = null
        try {
            check(first.awaitReady()) { "first Dart engine ready timeout" }
            check(second.awaitReady()) { "second Dart engine ready timeout" }
            first.invokeRun(createSchema = true, holdForNative = true)
            check(first.awaitLock()) { "Dart BEGIN IMMEDIATE rendezvous timeout" }
            nativeWriter = nativeExecutor.submit {
                val contender = NativeSqliteDatabase.openScratch(context, "phase8-proof-concurrent-contender", path)
                try {
                    try {
                        contender.beginTransactionNonExclusive()
                        error("native contender acquired lock before Dart release")
                    } catch (error: NativeSqliteException) {
                        nativeBusyCode[0] = error.code
                        check(error.code == 5) { "expected SQLITE_BUSY=5, got ${error.code}" }
                        nativeBusy.countDown()
                    }
                } finally { contender.close() }
            }
            second.invokeRun(createSchema = false, holdForNative = false)
            check(nativeBusy.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)) { "native SQLITE_BUSY observation timeout" }
            // Keep Dart's first transaction open until the second engine has
            // actually observed SQLITE_BUSY; otherwise it could win the lock
            // after the native contender's timeout and make the proof flaky.
            val secondResult = second.awaitResult()
            first.release()
            val firstResult = first.awaitResult()
            check(firstResult.ok) { firstResult.error ?: "first Dart writer failed" }
            check(!secondResult.ok && secondResult.busy) {
                "second Dart engine did not report SQLITE_BUSY: ${secondResult.error}"
            }
            result.putAll(firstResult.asProof("dart-engine-0"))
            result["dartEngine1Identity"] = secondResult.raw?.get("identity")
            result["dartEngine1Addresses"] = secondResult.raw?.get("dartAddresses")
            result["dartEngine1VfsAddress"] = secondResult.raw?.get("dartVfsAddress")
            result["dartEngine1ResultCode"] = secondResult.raw?.get("resultCode")
            result["dartEngineCount"] = 2
            result["dartEngineLifecycleOverlap"] = first.lifecycleStarted && second.lifecycleStarted
            result["dartWriterHeldBeginImmediate"] = true
            result["nativeWriterContendedWhileDartHeld"] = true
            result["nativeWriterBeginImmediateAttempted"] = true
            result["nativeBusyBeforeDartRelease"] = true
            result["nativeBusyObserved"] = nativeBusyCode[0] == 5
            result["nativeBusyCode"] = nativeBusyCode[0]
            result["dartBusyObserved"] = secondResult.busy
            check(firstResult.rows == 2L) { "concurrent Dart writer expected exactly 2 rows, got ${firstResult.rows}" }
        } finally {
            first.destroy(); second.destroy()
            nativeWriter?.get(deadline.remainingMillis(), TimeUnit.MILLISECONDS)
        }
        val retry = NativeSqliteDatabase.openScratch(context, "phase8-proof-concurrent-retry", path)
        try {
            retry.beginTransactionNonExclusive()
            insertNative(retry, "native-after-dart", 7L)
            retry.setTransactionSuccessful(); retry.endTransaction()
            verifyTypedRow(retry, "native-seed\u0000🎓", 9223372036854775807L)
            verifyTypedRow(retry, "dart-engine-0\u0000🎓", 9223372036854775807L)
            verifyTypedRow(retry, "native-after-dart", 7L)
            verifyIntegrity(retry, result)
            verifyExactTexts(retry, setOf("native-seed\u0000🎓", "dart-engine-0\u0000🎓", "native-after-dart"))
            check(countRows(retry) == 3L) { "concurrent expected exactly 3 rows, got ${countRows(retry)}" }
            verifyInvalidNullBindRange(retry, 3L, result)
            result["nativeRetryCommitted"] = true
        } finally { retry.close() }
        result["expectedRows"] = 3L
        result["actualRows"] = 3L
        result["rollback"] = true
        result["deterministicClose"] = true
        result["order"] = "concurrent"
    }

    /**
     * Holds a production Drift transaction in its background SQLite worker
     * while a native BEGIN runs on the main looper. The main contender uses
     * busy_timeout=0, so it must return SQLITE_BUSY promptly and leave the
     * root/worker callback free to perform its health check and commit. A
     * fresh native connection retries after the worker commit.
     */
    private fun runHealthContention(
        context: Context,
        root: File,
        result: MutableMap<String, Any?>,
        deadline: ProofDeadline,
    ) {
        deadline.check()
        val path = File(root, "health-contention.sqlite")
        val seed = NativeSqliteDatabase.openScratch(context, "phase8-proof-health-seed", path)
        try {
            createFixture(seed)
            insertNative(seed, "native-seed\u0000🎓")
        } finally {
            seed.close()
        }

        val region = sha256Text("phase8-proof:health:${root.canonicalPath}")
        val marker = File(context.noBackupFilesDir, "storage-health/$region.corrupt")
        check(!marker.exists()) { "healthy contention region unexpectedly latched" }
        val nativeBeginAttempted = AtomicBoolean(false)
        val nativeCompleted = AtomicBoolean(false)
        val dart = createDartEngine(
            context,
            path,
            0,
            deadline,
            nativeBeginAttempted,
            nativeCompleted,
        )
        val nativeStarted = CountDownLatch(1)
        val nativeFinished = CountDownLatch(1)
        val nativeFailure = arrayOfNulls<Throwable>(1)
        val nativeWaitMs = longArrayOf(-1L)
        val nativeStartedAtMs = longArrayOf(-1L)
        val nativeFinishedAtMs = longArrayOf(-1L)
        val nativeStage = AtomicReference("queued")
        val nativeBusyCode = AtomicReference<Int?>(null)
        val nativeBusyObserved = AtomicBoolean(false)
        val nativeNoSideEffect = AtomicBoolean(false)
        val nativeRowsBefore = AtomicReference<Long?>(null)
        val nativeRowsAfter = AtomicReference<Long?>(null)
        val mainHandler = Handler(Looper.getMainLooper())
        try {
            check(dart.awaitReady()) { "health contention Dart engine ready timeout" }
            dart.invokeRun(
                createSchema = false,
                holdForNative = true,
                healthContention = true,
                healthRegion = region,
            )
            val dartLockAcquired = dart.awaitLock()
            if (!dartLockAcquired) {
                // A completed Dart error must be captured before starting any
                // native contender; otherwise a worker failure is hidden by a
                // second 50-second rendezvous timeout.
                val failedDartResult = dart.awaitResult()
                result.putAll(failedDartResult.asProof("health-contention-dart-rendezvous-failure"))
                result["healthRendezvous"] = false
                check(failedDartResult.ok) {
                    failedDartResult.error ?: "health contention Dart writer failed before rendezvous"
                }
                error("health contention Dart BEGIN rendezvous was not reached")
            }
            result["healthRendezvous"] = true

            // This callback enters beginTransactionNonExclusive on the main
            // looper. The native zero-timeout contract must unwind promptly
            // while the Drift worker still owns its write transaction.
            mainHandler.post {
                var contender: CanonicalSqliteDatabase? = null
                var rowsBefore = -1L
                var rowsAfter = -1L
                try {
                    nativeStage.set("opening")
                    contender = NativeSqliteDatabase.openScratch(
                        context,
                        "phase8-proof-health-main-contender",
                        path,
                    )
                    contender.rawQuery("PRAGMA busy_timeout", null).use { cursor ->
                        check(cursor.moveToFirst()) { "native contender busy_timeout row missing" }
                        check(cursor.getLong(0) == 0L) { "native contender timeout was not zero" }
                    }
                    rowsBefore = countRows(contender)
                    nativeRowsBefore.set(rowsBefore)
                    nativeStage.set("ready-to-begin")
                    nativeStarted.countDown()
                    nativeBeginAttempted.set(true)
                    dart.notifyNativeContenderStartedOnMain()
                    val startedAt = SystemClock.elapsedRealtime()
                    nativeStartedAtMs[0] = startedAt
                    nativeStage.set("begin-attempted")
                    try {
                        contender.beginTransactionNonExclusive()
                        nativeStage.set("begin-acquired-unexpectedly")
                        error("native contender acquired the worker writer lock")
                    } catch (busy: NativeSqliteException) {
                        nativeBusyCode.set(busy.code)
                        nativeBusyObserved.set(busy.code == 5)
                        nativeStage.set("busy-returned")
                    }
                    nativeWaitMs[0] = SystemClock.elapsedRealtime() - startedAt
                    rowsAfter = countRows(contender)
                    nativeRowsAfter.set(rowsAfter)
                    nativeNoSideEffect.set(rowsBefore == rowsAfter)
                } catch (error: Throwable) {
                    nativeFailure[0] = error
                    nativeStage.set("failed")
                    nativeStarted.countDown()
                } finally {
                    contender?.close()
                    nativeFinishedAtMs[0] = SystemClock.elapsedRealtime()
                    nativeCompleted.set(true)
                    if (nativeStage.get() != "failed") nativeStage.set("finished")
                    nativeFinished.countDown()
                }
            }

            result["nativeStageBeforeStartWait"] = nativeStage.get()
            check(nativeStarted.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)) {
                "main native contender did not start"
            }
            val dartResult = dart.awaitResult()
            val nativeFinishedBeforeDiagnostics = nativeFinished.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)
            // Preserve diagnostics before any acceptance assertion can throw.
            result.putAll(dartResult.asProof("health-contention-dart"))
            result["healthRegion"] = region
            result["healthChecked"] = dartResult.raw?.get("healthChecked") == true
            result["healthHandlerOffMain"] = dartResult.raw?.get("healthHandlerOffMain") == true
            result["healthHandlerObservedNativeWait"] = dartResult.raw?.get("healthHandlerObservedNativeWait") == true
            result["healthElapsedMs"] = dartResult.raw?.get("healthElapsedMs")
            result["dartExecutionLocation"] = dartResult.raw?.get("dartExecutionLocation")
            result["driftExecutorLocation"] = dartResult.raw?.get("driftExecutorLocation")
            result["driftDatabaseFactory"] = dartResult.raw?.get("driftDatabaseFactory")
            result["driftStorageRegionId"] = dartResult.raw?.get("driftStorageRegionId")
            result["driftDatabasePathScope"] = dartResult.raw?.get("driftDatabasePathScope")
            result["driftTransactionWriter"] = dartResult.raw?.get("driftTransactionWriter")
            result["writerReservedByDriftTransaction"] = dartResult.raw?.get("writerReservedByDriftTransaction")
            result["nativeBeginAttemptedOnMain"] = nativeBeginAttempted.get()
            result["nativeContenderStartedOnMain"] = nativeStarted.count == 0L
            result["nativeStage"] = nativeStage.get()
            result["nativeContenderWaitMs"] = nativeWaitMs[0]
            result["nativeBusyCode"] = nativeBusyCode.get()
            result["nativeBusyObserved"] = nativeBusyObserved.get()
            result["nativeRowsBeforeBegin"] = nativeRowsBefore.get()
            result["nativeRowsAfterBusy"] = nativeRowsAfter.get()
            result["nativeNoSideEffect"] = nativeNoSideEffect.get()
            result["nativeFinished"] = nativeFinishedBeforeDiagnostics
            result["nativeContenderDurationMs"] = if (nativeStartedAtMs[0] >= 0L && nativeFinishedAtMs[0] >= 0L) nativeFinishedAtMs[0] - nativeStartedAtMs[0] else null
            result["nativeErrorType"] = nativeFailure[0]?.javaClass?.name
            result["nativeError"] = nativeFailure[0]?.message ?: nativeFailure[0]?.toString()
            check(dartResult.ok) { dartResult.error ?: "health contention Dart proof failed" }
            check(dartResult.raw?.get("healthChecked") == true) {
                "Dart health check did not complete"
            }
            check(dartResult.raw?.get("healthHandlerOffMain") == true) {
                "Dart health handler was not observed off main"
            }
            check(nativeFinishedBeforeDiagnostics) {
                "main native contender did not finish after Dart commit"
            }
            nativeFailure[0]?.let { throw it }
            check(nativeBusyObserved.get()) {
                "native contender did not return SQLITE_BUSY: code=${nativeBusyCode.get()}"
            }
            check(nativeBusyCode.get() == 5) { "expected SQLITE_BUSY=5, got ${nativeBusyCode.get()}" }
            check(nativeWaitMs[0] in 0L until 500L) {
                "native main busy return exceeded 500ms: ${nativeWaitMs[0]}"
            }
            check(nativeNoSideEffect.get()) { "busy native BEGIN changed fixture rows" }
            result["healthChecked"] = true
            check(result["healthHandlerOffMain"] == true) { "health handler ran on main" }
            result["healthAndCommitAfterNativeBusy"] = true
            result["nativeContenderStartedOnMain"] = true
            result["nativeCommittedAfterDartRelease"] = false
            result["nativeContenderWaitMs"] = nativeWaitMs[0]
            result["nativeContenderTimeoutMs"] = 0L
        } finally {
            dart.destroy()
        }

        val retry = nativeExecutor.submit<Throwable?> {
            var fresh: CanonicalSqliteDatabase? = null
            try {
                val freshConnection = NativeSqliteDatabase.openScratch(
                    context,
                    "phase8-proof-health-native-retry",
                    path,
                )
                fresh = freshConnection
                freshConnection.beginTransactionNonExclusive()
                insertNative(freshConnection, "native-after-health", 7L)
                freshConnection.setTransactionSuccessful()
                freshConnection.endTransaction()
                null
            } catch (error: Throwable) {
                error
            } finally {
                fresh?.close()
            }
        }
        val retryFailure = retry.get(deadline.remainingMillis(), TimeUnit.MILLISECONDS)
        result["nativeRetryLocation"] = "fresh native connection on nativeExecutor"
        result["nativeRetryCommitted"] = retryFailure == null
        result["nativeRetryErrorType"] = retryFailure?.javaClass?.name
        result["nativeRetryError"] = retryFailure?.message ?: retryFailure?.toString()
        retryFailure?.let { throw it }
        runNativeCommitBusyProof(context, root, result, deadline)

        val verified = NativeSqliteDatabase.openScratch(context, "phase8-proof-health-verify", path)
        try {
            verifyTypedRow(verified, "native-seed\u0000🎓", 9223372036854775807L)
            verifyTypedRow(verified, "dart-health-0\u0000🎓", 9223372036854775807L)
            verifyTypedRow(verified, "native-after-health", 7L)
            verifyExactTexts(verified, setOf("native-seed\u0000🎓", "dart-health-0\u0000🎓", "native-after-health"))
            verifyIntegrity(verified, result)
            check(countRows(verified) == 3L) { "health contention expected exactly 3 rows" }
            verifyInvalidNullBindRange(verified, 3L, result)
        } finally {
            verified.close()
        }
        result["expectedRows"] = 3L
        result["actualRows"] = 3L
        result["rollback"] = false
        result["rollbackTested"] = false
        result["deterministicClose"] = true
        result["order"] = "health-contention"
    }

    /**
     * Proves the JNI wrapper's COMMIT failure path against a real rollback
     * journal lock. A deferred reader holds SHARED while the writer obtains
     * RESERVED, inserts, and then receives SQLITE_BUSY at COMMIT. The wrapper
     * must rollback that failed transaction and close cleanly before a fresh
     * native transaction succeeds exactly once.
     */
    private fun runNativeCommitBusyProof(
        context: Context,
        root: File,
        result: MutableMap<String, Any?>,
        deadline: ProofDeadline,
    ) {
        deadline.check()
        val path = File(root, "native-commit-busy.sqlite")
        val seed = NativeSqliteDatabase.openScratch(context, "phase8-proof-commit-seed", path)
        try {
            createFixture(seed)
            seed.rawQuery("PRAGMA journal_mode = DELETE", null).use { cursor ->
                check(cursor.moveToFirst()) { "commit seed journal_mode row missing" }
                check(cursor.getString(0).equals("delete", ignoreCase = true)) {
                    "commit seed journal mode was not DELETE"
                }
            }
            insertNative(seed, "commit-seed", 1L)
        } finally {
            seed.close()
        }

        var reader: CanonicalSqliteDatabase? = null
        var writer: CanonicalSqliteDatabase? = null
        var readerHeld = false
        var writerRowsBefore = -1L
        var writerRowsAfter = -1L
        var commitBusyCode: Int? = null
        var commitElapsedMs = -1L
        var writerInTransactionAfter = true
        var writerCloseError: Throwable? = null
        var readerCloseError: Throwable? = null
        var failure: Throwable? = null
        try {
            val readerConnection = NativeSqliteDatabase.openScratch(context, "phase8-proof-commit-reader", path)
            reader = readerConnection
            readerConnection.rawQuery("PRAGMA journal_mode = DELETE", null).use { cursor ->
                check(cursor.moveToFirst()) { "commit reader journal_mode row missing" }
                check(cursor.getString(0).equals("delete", ignoreCase = true)) {
                    "commit reader journal mode was not DELETE"
                }
            }
            readerConnection.execSQL("BEGIN")
            readerConnection.rawQuery("SELECT COUNT(*) FROM values_fixture", null).use { cursor ->
                check(cursor.moveToFirst()) { "commit reader count row missing" }
            }
            readerHeld = true

            val writerConnection = NativeSqliteDatabase.openScratch(context, "phase8-proof-commit-writer", path)
            writer = writerConnection
            writerConnection.rawQuery("PRAGMA busy_timeout", null).use { cursor ->
                check(cursor.moveToFirst()) { "commit writer busy_timeout row missing" }
                check(cursor.getLong(0) == 0L) { "commit writer timeout was not zero" }
            }
            writerRowsBefore = countRows(writerConnection)
            writerConnection.beginTransactionNonExclusive()
            insertNative(writerConnection, "commit-failed", 2L)
            writerConnection.setTransactionSuccessful()
            val commitStartedAt = SystemClock.elapsedRealtime()
            try {
                writerConnection.endTransaction()
                failure = IllegalStateException("busy COMMIT unexpectedly succeeded")
            } catch (busy: NativeSqliteException) {
                commitBusyCode = busy.code
            }
            commitElapsedMs = SystemClock.elapsedRealtime() - commitStartedAt
            writerRowsAfter = countRows(writerConnection)
            writerInTransactionAfter = writerConnection.inTransaction()
        } catch (error: Throwable) {
            failure = error
        } finally {
            try {
                writer?.close()
            } catch (error: Throwable) {
                writerCloseError = error
            }
            try {
                reader?.close()
            } catch (error: Throwable) {
                readerCloseError = error
            }
        }

        result["jniCommitBusyDatabase"] = path.canonicalPath
        result["jniCommitBusyJournalMode"] = "delete"
        result["jniCommitBusyReaderLocation"] = "native scratch connection (deferred BEGIN + SELECT)"
        result["jniCommitBusyWriterLocation"] = "native scratch connection (BEGIN IMMEDIATE)"
        result["jniCommitBusyReaderHeldSharedLock"] = readerHeld
        result["jniCommitBusyCode"] = commitBusyCode
        result["jniCommitBusyElapsedMs"] = commitElapsedMs
        result["jniCommitBusyRowsBefore"] = writerRowsBefore
        result["jniCommitBusyRowsAfterRollback"] = writerRowsAfter
        result["jniCommitBusyWriterInTransactionAfter"] = writerInTransactionAfter
        result["jniCommitBusyWriterCloseError"] = writerCloseError?.message
        result["jniCommitBusyReaderCloseError"] = readerCloseError?.message
        result["jniCommitBusyFailure"] = failure?.message ?: failure?.toString()

        failure?.let { throw it }
        writerCloseError?.let { throw it }
        readerCloseError?.let { throw it }
        check(commitBusyCode == 5) { "expected COMMIT SQLITE_BUSY=5, got $commitBusyCode" }
        check(commitElapsedMs in 0L until 500L) {
            "busy COMMIT exceeded 500ms: $commitElapsedMs"
        }
        check(writerRowsBefore == 1L && writerRowsAfter == 1L) {
            "failed COMMIT changed writer rows: $writerRowsBefore -> $writerRowsAfter"
        }
        check(!writerInTransactionAfter) { "failed COMMIT left writer transaction active" }
        result["jniCommitBusyRolledBack"] = true
        result["jniCommitBusyCloseSucceeded"] = true

        val fresh = NativeSqliteDatabase.openScratch(context, "phase8-proof-commit-retry", path)
        try {
            fresh.beginTransactionNonExclusive()
            insertNative(fresh, "native-after-commit-busy", 3L)
            fresh.setTransactionSuccessful()
            fresh.endTransaction()
        } finally {
            fresh.close()
        }
        val verified = NativeSqliteDatabase.openScratch(context, "phase8-proof-commit-verify", path)
        try {
            val exact = setOf("commit-seed", "native-after-commit-busy")
            verifyExactTexts(verified, exact)
            verifyTypedRow(verified, "native-after-commit-busy", 3L)
            check(countRows(verified) == 2L) { "commit retry expected exactly 2 rows" }
            result["jniCommitBusyFreshRetryCommitted"] = true
            result["jniCommitBusyFailedInsertAbsent"] = true
            result["jniCommitBusyExpectedRows"] = 2L
            result["jniCommitBusyActualRows"] = countRows(verified)
        } finally {
            verified.close()
        }
    }

    private fun createFixture(database: CanonicalSqliteDatabase) {
        database.rawQuery("PRAGMA journal_mode", null).use { cursor -> check(cursor.moveToFirst()) { "journal_mode row missing" } }
        database.execSQL("CREATE TABLE IF NOT EXISTS values_fixture(id INTEGER PRIMARY KEY, text_value TEXT NOT NULL, int_value INTEGER, real_value REAL, blob_value BLOB, null_value TEXT)")
    }

    private fun insertNative(database: CanonicalSqliteDatabase, text: String, integer: Long = 9223372036854775807L) {
        database.execSQL("INSERT INTO values_fixture(text_value,int_value,real_value,blob_value,null_value) VALUES(?,?,?,?,?)", arrayOf(text, integer, 3.25, byteArrayOf(0, 1, 2, 127, -1), null))
    }

    private fun rollbackMustNotChange(database: CanonicalSqliteDatabase, expected: Long) {
        database.beginTransactionNonExclusive()
        try { database.execSQL("INSERT INTO values_fixture(text_value) VALUES(?)", arrayOf("rollback")) } finally { database.endTransaction() }
        check(countRows(database) == expected) { "rollback changed fixture row count" }
    }

    private fun countRows(database: CanonicalSqliteDatabase): Long = database.rawQuery("SELECT COUNT(*) FROM values_fixture", null).use { cursor ->
        check(cursor.moveToFirst()) { "count row missing" }; cursor.getLong(0)
    }

    private fun verifyTypedRow(database: CanonicalSqliteDatabase, expectedText: String, expectedInteger: Long) {
        database.rawQuery("SELECT text_value,int_value,real_value,blob_value,null_value FROM values_fixture WHERE text_value = ?", arrayOf(expectedText)).use { cursor ->
            check(cursor.moveToFirst()) { "typed row missing" }
            check(cursor.getString(0) == expectedText) { "unicode/NUL mismatch" }
            check(cursor.getLong(1) == expectedInteger) { "integer mismatch" }
            check(abs(cursor.getDouble(2) - 3.25) < 0.0001) { "float mismatch" }
            check(cursor.getBlob(3)?.contentEquals(byteArrayOf(0, 1, 2, 127, -1)) == true) { "blob mismatch" }
            check(cursor.isNull(4)) { "NULL mismatch" }
        }
    }

    private fun verifyExactTexts(database: CanonicalSqliteDatabase, expected: Set<String>) {
        val actual = linkedSetOf<String>()
        database.rawQuery("SELECT text_value FROM values_fixture ORDER BY id", null).use { cursor ->
            var hasRow = cursor.moveToFirst()
            while (hasRow) {
                actual += cursor.getString(0)
                hasRow = cursor.moveToNext()
            }
        }
        check(actual == expected) { "fixture text set mismatch: expected=$expected actual=$actual" }
    }

    private fun verifyIntegrity(database: CanonicalSqliteDatabase, result: MutableMap<String, Any?>) {
        val integrity = database.rawQuery("PRAGMA integrity_check", null).use { cursor ->
            check(cursor.moveToFirst()) { "integrity_check row missing" }; cursor.getString(0)
        }
        check(integrity == "ok") { "integrity=$integrity" }
        result["integrity"] = integrity
    }

    private fun verifyInvalidNullBindRange(
        database: CanonicalSqliteDatabase,
        expectedRows: Long,
        result: MutableMap<String, Any?>,
    ) {
        val before = countRows(database)
        check(before == expectedRows) { "bind-range precondition row count mismatch" }
        var rejected = false
        try {
            database.execSQL(
                "INSERT INTO values_fixture(text_value) VALUES(?)",
                arrayOf<Any?>(null, "extra-argument"),
            )
        } catch (error: NativeSqliteException) {
            check(error.code == 25) { "expected SQLITE_RANGE=25, got ${error.code}" }
            rejected = true
        }
        check(rejected) { "invalid NULL bind arity was accepted" }
        val after = countRows(database)
        check(after == before) { "invalid NULL bind changed rows: $before -> $after" }
        result["invalidNullBindRangeRejected"] = true
        result["invalidNullBindRangeCode"] = 25
        result["invalidNullBindRowsBefore"] = before
        result["invalidNullBindRowsAfter"] = after
    }

    private fun runCorruptionProof(context: Context, root: File, deadline: ProofDeadline): Map<String, Any?> {
        deadline.check()
        val corrupt = File(root, "corrupt.sqlite")
        val journal = File("${corrupt.path}-journal")
        corrupt.writeBytes(byteArrayOf(0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x00))
        journal.writeBytes("preserve-journal".toByteArray(StandardCharsets.UTF_8))
        var rejected = false
        try {
            val damaged = NativeSqliteDatabase.openScratch(context, "phase8-proof-corrupt", corrupt)
            try { damaged.rawQuery("PRAGMA integrity_check", null).use { it.moveToFirst() } } finally { damaged.close() }
        } catch (error: NativeSqliteException) {
            check(error.code == 26) { "unexpected malformed-header code=${error.code}" }
            rejected = true
        }
        check(rejected) { "malformed cache file was accepted" }
        check(corrupt.isFile) { "malformed database file was removed" }
        val journalPresentAfterClose = journal.isFile
        val result = linkedMapOf<String, Any?>(
            "malformedSqliteRejected" to true,
            "malformedSqliteCode" to 26,
            "corruptionRejected" to true,
            "malformedDatabasePresentAfterHandleClose" to true,
            "malformedJournalPresentAfterHandleClose" to journalPresentAfterClose,
            "malformedJournalSha256AfterHandleClose" to if (journalPresentAfterClose) sha256(journal) else null,
        )
        val validCorrupt = createValidHeaderCorruption(context, root, deadline)
        result.putAll(runDurableHealthProof(context, root, validCorrupt.file, validCorrupt.beforeHash, null, deadline))
        return result
    }

    private data class ValidHeaderCorruption(val file: File, val beforeHash: String)

    private fun createValidHeaderCorruption(context: Context, root: File, deadline: ProofDeadline): ValidHeaderCorruption {
        deadline.check()
        val file = File(root, "valid-header-page-corrupt.sqlite")
        val database = NativeSqliteDatabase.openScratch(context, "phase8-proof-valid-corrupt-create", file)
        try {
            createFixture(database)
        } finally {
            database.close()
        }
        check(file.length() >= 101L) { "valid fixture did not reach page-one payload" }
        val beforeHash = sha256(file)
        RandomAccessFile(file, "rw").use { raf ->
            raf.seek(100L)
            raf.write(0xff)
            raf.fd.sync()
        }
        check(file.isFile) { "valid-header corruption fixture disappeared" }
        return ValidHeaderCorruption(file, beforeHash)
    }

    private fun runDurableHealthProof(
        context: Context,
        root: File,
        corrupt: File,
        corruptBefore: String,
        journalBefore: String?,
        deadline: ProofDeadline,
    ): Map<String, Any?> {
        deadline.check()
        val syntheticRegion = sha256Text("phase8-proof:${root.canonicalPath}")
        val marker = File(context.noBackupFilesDir, "storage-health/$syntheticRegion.corrupt")
        check(!marker.exists()) { "synthetic health marker unexpectedly exists" }
        var rejected = false
        try {
            val damaged = NativeSqliteDatabase.open(context, syntheticRegion, corrupt)
            try {
                damaged.rawQuery("PRAGMA integrity_check", null).use { it.moveToFirst() }
                error("production cache corruption was accepted")
            } finally {
                damaged.close()
            }
        } catch (error: NativeSqliteException) {
            val primary = error.code and 0xff
            check(primary == 11 || error.code == 26) {
                "unexpected production corruption code=${error.code}"
            }
            rejected = true
        }
        check(rejected) { "production cache corruption was not rejected" }
        check(marker.isFile) { "durable synthetic health marker missing" }
        val markerHash = sha256(marker)
        var healthRejected = false
        try {
            NativeSqliteIdentity.checkHealth(context, syntheticRegion)
        } catch (_: IllegalStateException) {
            healthRejected = true
        }
        check(healthRejected) { "health gate accepted synthetic corrupt region" }
        var reopenRejected = false
        try {
            NativeSqliteDatabase.open(context, syntheticRegion, corrupt).close()
        } catch (_: IllegalStateException) {
            reopenRejected = true
        }
        check(reopenRejected) { "production reopen bypassed durable health latch" }
        check(markerHash == sha256(marker)) { "synthetic health marker changed" }
        check(corrupt.isFile) { "valid-header corrupt file was removed" }
        val corruptAfter = sha256(corrupt)
        if (journalBefore != null) {
            check(journalBefore == sha256(File("${corrupt.path}-journal"))) {
                "journal changed during health proof"
            }
        }
        return mapOf(
            "syntheticHealthRegion" to syntheticRegion,
            "syntheticHealthMarkerLocation" to "noBackupFilesDir/storage-health",
            "validHeaderCorruptFileSha256Before" to corruptBefore,
            "validHeaderCorruptFileSha256After" to corruptAfter,
            "syntheticHealthMarkerCreated" to true,
            "syntheticHealthMarkerSha256" to markerHash,
            "syntheticHealthCheckRejected" to true,
            "syntheticHealthReopenRejected" to true,
            "syntheticHealthMarkerDurable" to true,
        )
    }

    private fun createDartEngine(
        context: Context,
        path: File,
        engineIndex: Int,
        deadline: ProofDeadline,
        nativeBeginAttempted: AtomicBoolean? = null,
        nativeCompleted: AtomicBoolean? = null,
    ): DartEngineController = DartEngineController(
        context,
        path,
        engineIndex,
        deadline,
        nativeBeginAttempted,
        nativeCompleted,
    ).also { it.create() }

    private fun runDartEngine(context: Context, path: File, createSchema: Boolean, holdForNative: Boolean, deadline: ProofDeadline): DartResult {
        val controller = createDartEngine(context, path, 0, deadline)
        return try {
            check(controller.awaitReady()) { "Dart engine ready timeout" }
            controller.invokeRun(createSchema, holdForNative)
            controller.awaitResult()
        } finally { controller.destroy() }
    }

    /** One monotonic budget covers engine startup, contention, and evidence. */
    private class ProofDeadline {
        private val startedAtNanos = System.nanoTime()

        fun remainingMillis(): Long {
            val elapsed = (System.nanoTime() - startedAtNanos) / 1_000_000L
            return (50_000L - elapsed).also { check(it > 0L) { "phase8 proof deadline exceeded" } }
        }

        fun check() { remainingMillis() }
    }

    private class DartEngineController(
        private val context: Context,
        private val path: File,
        private val engineIndex: Int,
        private val deadline: ProofDeadline,
        private val nativeBeginAttempted: AtomicBoolean? = null,
        private val nativeCompleted: AtomicBoolean? = null,
    ) {
        private val mainHandler = Handler(Looper.getMainLooper())
        private val ready = CountDownLatch(1); private val lock = CountDownLatch(1); private val result = CountDownLatch(1)
        private var engine: FlutterEngine? = null; private var channel: MethodChannel? = null
        private var resultValue = DartResult(false, 0L, false, "result missing", false, null)
        @Volatile private var healthHandlerOffMain = false
        @Volatile private var healthHandlerObservedNativeWait = false
        @Volatile var lifecycleStarted = false
            private set

        fun create() {
            mainHandler.post {
                try {
                    val loader = FlutterLoader(); loader.startInitialization(context.applicationContext); loader.ensureInitializationComplete(context.applicationContext, emptyArray())
                    val created = FlutterEngine(context.applicationContext, null, false); engine = created; lifecycleStarted = true
                    val identityMessenger = created.dartExecutor.binaryMessenger
                    val identityQueue = identityMessenger.makeBackgroundTaskQueue()
                    val identity = MethodChannel(
                        identityMessenger,
                        "jp.universityschedule.app/sqlite_identity",
                        StandardMethodCodec.INSTANCE,
                        identityQueue,
                    )
                    identity.setMethodCallHandler { call, methodResult ->
                        try {
                            when (call.method) {
                                "verify" -> {
                                    val args = call.arguments as? Map<*, *> ?: error("identity args missing")
                                    val pointers = (args["dartAddresses"] as? List<*>)?.map { (it as? Number)?.toLong() ?: error("identity pointer invalid") }?.toLongArray() ?: error("identity pointers missing")
                                    methodResult.success(NativeSqliteIdentity.verify(context, pointers))
                                }
                                "checkHealth" -> {
                                    val args = call.arguments as? Map<*, *> ?: error("health args missing")
                                    val region = args["region"]?.toString() ?: error("health region missing")
                                    healthHandlerOffMain = Looper.myLooper() != Looper.getMainLooper()
                                    healthHandlerObservedNativeWait = nativeBeginAttempted?.get() == true && nativeCompleted?.get() != true
                                    NativeSqliteIdentity.checkHealth(context, region)
                                    methodResult.success(null)
                                }
                                else -> methodResult.notImplemented()
                            }
                        } catch (error: Throwable) { methodResult.error("sqlite_identity_rejected", error.message, null) }
                    }
                    channel = MethodChannel(created.dartExecutor.binaryMessenger, "jp.universityschedule.app/phase8_sqlite_proof")
                    channel!!.setMethodCallHandler { call, methodResult ->
                        when (call.method) {
                            "ready" -> { methodResult.success(null); ready.countDown() }
                            "dartLockAcquired" -> { methodResult.success(null); lock.countDown() }
                            "result" -> {
                                methodResult.success(null)
                                val raw = ((call.arguments as? Map<*, *>)?.entries?.associate { it.key to it.value } ?: emptyMap<Any?, Any?>()).toMutableMap()
                                if (healthHandlerOffMain) raw["healthHandlerOffMain"] = true
                                if (healthHandlerObservedNativeWait) raw["healthHandlerObservedNativeWait"] = true
                                resultValue = DartResult.from(raw, engineIndex)
                                result.countDown()
                            }
                            else -> methodResult.notImplemented()
                        }
                    }
                    created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "phase8SqliteProofEntryPoint"))
                } catch (error: Throwable) {
                    resultValue = DartResult(false, 0L, false, error.message ?: error.toString(), false, null); ready.countDown(); result.countDown()
                }
            }
        }
        fun awaitReady(): Boolean = ready.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)
        fun awaitLock(): Boolean {
            while (true) {
                if (lock.count == 0L) return true
                if (result.count == 0L) return false
                if (lock.await(minOf(25L, deadline.remainingMillis()), TimeUnit.MILLISECONDS)) return true
                if (result.count == 0L) return false
            }
        }
        fun invokeRun(createSchema: Boolean, holdForNative: Boolean, healthContention: Boolean = false, healthRegion: String? = null) = mainHandler.post { channel?.invokeMethod("run", mapOf("databasePath" to path.canonicalPath, "createSchema" to createSchema, "holdForNative" to holdForNative, "healthContention" to healthContention, "healthRegion" to healthRegion, "engineIndex" to engineIndex), null) }
        fun release() = mainHandler.post { channel?.invokeMethod("release", null, null) }
        fun notifyNativeContenderStartedOnMain() { channel?.invokeMethod("nativeContenderStarted", null, null) }
        fun awaitResult(): DartResult { check(result.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)) { "Dart proof result timeout" }; return resultValue }
        fun destroy() = mainHandler.post { engine?.destroy(); engine = null }
    }

    private data class DartResult(val ok: Boolean, val rows: Long, val busy: Boolean, val error: String?, val heldBeginImmediate: Boolean, val raw: Map<*, *>?) {
        companion object {
            fun from(raw: Map<*, *>?, engineIndex: Int): DartResult {
                val map = raw ?: emptyMap<String, Any?>()
                return DartResult(map["ok"] == true, (map["dartRows"] as? Number)?.toLong() ?: 0L, map["busy"] == true, map["error"]?.toString(), map["heldBeginImmediate"] == true, map + ("engineIndex" to engineIndex))
            }
        }
        fun asProof(label: String): Map<String, Any?> {
            val identity = raw?.get("identity") as? Map<*, *>
                return mapOf(
                    "dartResult" to label,
                    "dartOk" to ok,
                    "dartRows" to rows,
                    "dartBusy" to busy,
                    "dartHeldBeginImmediate" to heldBeginImmediate,
                    "dartRollback" to raw?.get("rollback"),
                    "dartError" to error,
                    "dartIdentity" to raw?.get("identity"),
                    "dartAddresses" to raw?.get("dartAddresses"),
                    "dartVfsAddress" to raw?.get("dartVfsAddress"),
                    "dartExecutionLocation" to raw?.get("dartExecutionLocation"),
                    "driftExecutorLocation" to raw?.get("driftExecutorLocation"),
                    "driftDatabaseFactory" to raw?.get("driftDatabaseFactory"),
                    "driftStorageRegionId" to raw?.get("driftStorageRegionId"),
                    "driftDatabasePathScope" to raw?.get("driftDatabasePathScope"),
                    "driftTransactionWriter" to raw?.get("driftTransactionWriter"),
                    "writerReservedByDriftTransaction" to raw?.get("writerReservedByDriftTransaction"),
                    "vfsMatch" to identity?.get("vfsMatch"),
                    "pointersMatch" to identity?.get("pointersMatch"),
                )
        }
    }

    private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    private fun sha256Text(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(StandardCharsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private fun toJson(value: Any?): String = when (value) {
        null -> "null"
        is Boolean, is Number -> value.toString()
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { (key, entry) -> "${toJson(key.toString())}:${toJson(entry)}" }
        is Iterable<*> -> value.joinToString(",", "[", "]", transform = ::toJson)
        is ByteArray -> value.joinToString(",", "[", "]")
        else -> "\"${value.toString().replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\u0000", "\\u0000")}\""
    }

    companion object {
        const val ACTION = "jp.universityschedule.app.action.PHASE8_SQLITE_PROOF"
        const val EXTRA_SCENARIO = "scenario"
        const val EXTRA_ARTIFACT = "artifact"
        private val SCENARIOS = setOf("native-first", "dart-first", "concurrent", "health-contention")
        private val proofExecutor: ExecutorService = Executors.newFixedThreadPool(2)
        private val nativeExecutor: ExecutorService = Executors.newCachedThreadPool()
    }
}
