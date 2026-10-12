package jp.universityschedule.notification

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import jp.universityschedule.scope.NativeScopeFence
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Starts the retained Dart planner without an Activity or automatic plugin
 * registration. The service never computes recurrence rules itself. */
class NotificationRefillJobService : JobService() {
    private val main = Handler(Looper.getMainLooper())
    private var active: ActiveRun? = null

    override fun onStartJob(params: JobParameters): Boolean {
        val jobId = params.jobId
        val requestedToken = params.extras?.getString(NotificationRefillContract.EXTRA_RUN_TOKEN)
        val token = NotificationRefillScheduler.begin(this, jobId, requestedToken)
            ?: return false
        val run = ActiveRun(params, token)
        active = run
        // Return from the JobService callback before cold Flutter engine
        // initialization. The engine work is still serialized on the service
        // main looper and is cancellable by onStopJob.
        main.post {
            if (active === run) run.start()
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        val run = active ?: return false
        if (run.params.jobId != params.jobId) return false
        // Invalidate the run before stopping Dart/engine work. The publisher
        // checks this same fence immediately before and through its SQLite
        // commit, so a late worker cannot publish after JobScheduler stops us.
        NotificationRefillScheduler.invalidate(this, run.token)
        val retry = NotificationRefillScheduler.retryAfterStop(this)
        try {
            run.cancel()
        } finally {
            NotificationRefillScheduler.releaseAfterStop(this, run.token)
        }
        active = null
        // Returning true asks JobScheduler for a bounded retry. The durable
        // scheduler state prevents a second refill from being added.
        return retry
    }

    private inner class ActiveRun(
        val params: JobParameters,
        val token: String,
    ) {
        private val completed = AtomicBoolean(false)
        private val resultAccepted = AtomicBoolean(false)
        private var engine: FlutterEngine? = null
        private var timeout: Runnable? = null
        private val worker = Executors.newSingleThreadExecutor()

        fun start() {
            try {
                val loader = FlutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, emptyArray())
                val flutter = FlutterEngine(applicationContext, null, false)
                engine = flutter
                val sqliteIdentityMessenger = flutter.dartExecutor.binaryMessenger
                val sqliteIdentityQueue = sqliteIdentityMessenger.makeBackgroundTaskQueue()
                MethodChannel(
                    sqliteIdentityMessenger,
                    "jp.universityschedule.app/sqlite_identity",
                    StandardMethodCodec.INSTANCE,
                    sqliteIdentityQueue,
                ).setMethodCallHandler { call, result ->
                    if (call.method == "checkHealth") {
                        try {
                            val region = call.argument<String>("region") ?: error("storage region is required")
                            NativeSqliteIdentity.checkHealth(this@NotificationRefillJobService, region)
                            result.success(null)
                        } catch (error: Throwable) {
                            result.error("sqlite_health_unavailable", error.message, null)
                        }
                        return@setMethodCallHandler
                    }
                    if (call.method == "recordCorruption") {
                        try {
                            val region = call.argument<String>("region") ?: error("storage region is required")
                            val reason = call.argument<String>("reason") ?: "dart_sqlite_corruption"
                            NativeSqliteIdentity.recordCorruption(this@NotificationRefillJobService, region, reason)
                            result.success(null)
                        } catch (error: Throwable) {
                            result.error("sqlite_health_latch_failed", error.message, null)
                        }
                        return@setMethodCallHandler
                    }
                    if (call.method != "verify") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    try {
                        val values = call.argument<List<Any?>>("dartAddresses")
                            ?: error("dart SQLite binding addresses are required")
                        val addresses = values.map {
                            (it as? Number)?.toLong() ?: error("invalid dart SQLite binding address")
                        }.toLongArray()
                        result.success(
                            NativeSqliteIdentity.verify(
                                this@NotificationRefillJobService,
                                addresses,
                            ),
                        )
                    } catch (error: Throwable) {
                        result.error("sqlite_identity_rejected", error.message, null)
                    }
                }
                val channel = MethodChannel(
                    flutter.dartExecutor.binaryMessenger,
                    NotificationRefillContract.CHANNEL,
                )
                var refillSent = false
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        NotificationRefillContract.METHOD_READY -> {
                            result.success(null)
                            if (!completed.get() && !refillSent) {
                                refillSent = true
                                sendRefill(channel)
                            }
                        }
                        NotificationRefillContract.METHOD_RESULT -> {
                            result.success(null)
                            val value = call.arguments as? Map<*, *>
                            acceptResult(value)
                        }
                        else -> result.notImplemented()
                    }
                }
                flutter.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), NotificationRefillContract.ENTRYPOINT),
                )
                timeout = Runnable { complete(false, "headless planner timeout") }.also {
                    main.postDelayed(it, 45_000L)
                }
            } catch (error: Throwable) {
                complete(false, error.message ?: "headless planner start failed")
            }
        }

        private fun sendRefill(channel: MethodChannel) {
            val scope = NativeScopeFence.current(this@NotificationRefillJobService)
            val refillContext = LocalNotificationCoordinator.refillContextForJob(this@NotificationRefillJobService)
            if (refillContext == null) {
                complete(false, "headless_refill_context_missing")
                return
            }
            val request = mutableMapOf<String, Any?>(
                "schemaVersion" to NotificationRefillContract.VERSION,
                "runToken" to token,
                "jobId" to params.jobId,
                "databasePath" to refillContext["databasePath"],
                "ownerUserId" to refillContext["ownerUserId"],
                "scope" to mapOf(
                    "regionId" to scope.regionId,
                    "ownerHash" to scope.ownerHash,
                    "activationToken" to scope.activationToken,
                    "generation" to scope.generation,
                ),
            )
            channel.invokeMethod(NotificationRefillContract.METHOD_REFILL, request,
                object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        // Current Dart sends the payload through METHOD_RESULT;
                        // accepting a direct return keeps the boundary tolerant
                        // during rolling upgrades.
                        val direct = value as? Map<*, *>
                        if (direct != null) acceptResult(direct)
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        complete(false, errorMessage ?: errorCode)
                    }

                    override fun notImplemented() {
                        complete(false, "headless refill method not implemented")
                    }
                },
            )
        }

        fun cancel() {
            if (!completed.compareAndSet(false, true)) return
            timeout?.let(main::removeCallbacks)
            worker.shutdownNow()
            engine?.destroy()
            engine = null
        }

        private fun handleResult(value: Map<*, *>) {
            if (completed.get()) return
            try {
                worker.execute {
                    try {
                        val raw = value["request"] ?: value["payload"] ?: value
                        val requestMap = raw as? Map<*, *> ?: error("background refill payload missing")
                        val root = JSONObject(requestMap.mapKeys { it.key.toString() })
                        val scope = NativeScopeFence.current(this@NotificationRefillJobService)
                        val result = LocalNotificationCoordinator.publishFromBackground(
                            this@NotificationRefillJobService,
                            scope,
                            root,
                            token,
                        )
                        main.post { complete(result, if (result) null else "native publication rejected") }
                    } catch (error: Throwable) {
                        main.post { complete(false, error.message ?: "invalid background refill payload") }
                    }
                }
            } catch (_: RejectedExecutionException) {
                // onStopJob may shut down the worker after the result was
                // accepted but before this callback queues its publication.
            }
        }

        private fun acceptResult(value: Map<*, *>?) {
            if (completed.get() || !resultAccepted.compareAndSet(false, true)) return
            if (value == null) complete(false, "background result must be a map")
            else if (value["error"] != null) complete(false, value["error"].toString())
            else handleResult(value)
        }

        private fun complete(success: Boolean, error: String?) {
            if (!completed.compareAndSet(false, true)) return
            val shouldRetry = NotificationRefillScheduler.finish(
                this@NotificationRefillJobService,
                token,
                success,
                error,
            )
            timeout?.let(main::removeCallbacks)
            worker.shutdownNow()
            engine?.destroy()
            engine = null
            active = null
            try {
                // A terminal failure is deliberately acknowledged. The
                // persisted daily job remains the recovery path instead of an
                // infinite JobScheduler retry loop.
                jobFinished(params, !success && shouldRetry)
            } finally {
                // The scheduler acknowledges and, when necessary, replaces
                // the durable pending due only after JobScheduler releases
                // this execution slot.
                NotificationRefillScheduler.releaseAfterFinish(
                    this@NotificationRefillJobService,
                    token,
                )
            }
        }
    }
}
