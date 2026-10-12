package jp.universityschedule.alarm

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import jp.universityschedule.app.MainActivity
import jp.universityschedule.app.R
import jp.universityschedule.scope.NativeScopeFence

class MorningAlarmRingingActivity : Activity() {
    private var handled = false
    private lateinit var capturedScopeIntent: Intent

    override fun onResume() {
        super.onResume()
        if (::capturedScopeIntent.isInitialized && !isCapturedScopeActive()) {
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        capturedScopeIntent = Intent(intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val ownerHash = intent?.getStringExtra(EXTRA_OWNER_HASH)
        if (!isCapturedScopeActive()) {
            finish()
            return
        }
        setContentView(buildContent())
    }

    private fun buildContent(): LinearLayout {
        val spacing = (resources.displayMetrics.density * 16).toInt()
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(spacing * 2, spacing * 2, spacing * 2, spacing * 2)
            addView(TextView(context).apply {
                text = getString(R.string.morning_alarm_ringing_title)
                textSize = 28f
                gravity = Gravity.CENTER
                setTypeface(typeface, Typeface.BOLD)
            })
            addView(TextView(context).apply {
                text = getString(R.string.morning_alarm_body)
                textSize = 18f
                gravity = Gravity.CENTER
                setPadding(0, spacing, 0, spacing * 2)
            })
            addView(actionButton(getString(R.string.morning_alarm_snooze, snoozeMinutes())) {
                act(ACTION_ALARM_SNOOZE)
            })
            addView(actionButton(getString(R.string.morning_alarm_stop)) {
                act(ACTION_ALARM_STOP)
            })
            addView(actionButton(getString(R.string.morning_alarm_today)) {
                act(ACTION_ALARM_OPEN_TODAY)
            })
        }
    }

    private fun actionButton(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            contentDescription = label
            isAllCaps = false
            minHeight = (resources.displayMetrics.density * 56).toInt()
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                bottomMargin = (resources.displayMetrics.density * 8).toInt()
            }
            setOnClickListener { action() }
        }

    private fun snoozeMinutes(): Int {
        val ownerHash = intent?.getStringExtra(EXTRA_OWNER_HASH) ?: return 10
        return MorningAlarmPreferences(this).read(ownerHash).snoozeMinutes
    }

    private fun act(action: String) {
        if (handled) return
        handled = true
        val ownerHash = capturedScopeIntent.getStringExtra(EXTRA_OWNER_HASH)
        if (!isCapturedScopeActive()) {
            finish()
            return
        }
        val isTest = capturedScopeIntent.getBooleanExtra(EXTRA_IS_TEST, false)
        val coordinator = MorningAlarmCoordinator(this)
        runCatching {
            when (action) {
                ACTION_ALARM_SNOOZE -> coordinator.handleSnooze(ownerHash, isTest)
                ACTION_ALARM_STOP -> {
                    val settings = coordinator.handleStop(ownerHash, isTest)
                    if (settings?.openTodayOnStop == true && isCapturedScopeActive()) {
                        openToday()
                    }
                }
                ACTION_ALARM_OPEN_TODAY -> {
                    coordinator.handleStop(ownerHash, isTest)
                    if (isCapturedScopeActive()) openToday()
                }
            }
        }
        finish()
    }

    private fun isCapturedScopeActive(): Boolean {
        val ownerHash = capturedScopeIntent.getStringExtra(EXTRA_OWNER_HASH)
        return NativeScopeFence.matchesIntent(this, capturedScopeIntent) &&
            MorningAlarmCoordinator(this).isActiveOwnerHash(ownerHash)
    }

    private fun openToday() {
        val scope = NativeScopeFence.current(this)
        if (!scope.active) return
        startActivity(
            Intent(
                Intent.ACTION_VIEW,
                Uri.parse("${morningAlarmTodayUri()}&scope=${scope.activationToken}"),
                this,
                MainActivity::class.java,
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_SCOPE_REGION_ID, scope.regionId)
                putExtra(EXTRA_SCOPE_OWNER_HASH, scope.ownerHash)
                putExtra(EXTRA_SCOPE_GENERATION, scope.generation)
                putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, scope.activationToken)
            },
        )
    }
}
