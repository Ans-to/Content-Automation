package com.contentautomation.platform_bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * One exact alarm that wakes the device shortly before the next scheduled
 * upload and (through [WakeupReceiver]) starts the scheduler service.
 *
 * Exact alarms are the only mechanism Android guarantees to fire on time
 * while the phone is dozing. They need SCHEDULE_EXACT_ALARM (Android 12/12L,
 * pre-granted) or USE_EXACT_ALARM (Android 13+, granted at install).
 */
object Wakeups {
    const val ACTION = "com.contentautomation.platform_bridge.WAKEUP"
    private const val REQUEST_CODE = 4101

    /** Returns "exact" or "inexact" depending on what the OS allowed. */
    fun schedule(context: Context, atEpochMillis: Long): String {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pendingIntent = pendingIntent(context)
        val at = maxOf(atEpochMillis, System.currentTimeMillis() + 1_000L)
        val exactAllowed =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()
        if (exactAllowed) {
            try {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pendingIntent)
                return "exact"
            } catch (e: SecurityException) {
                Log.w(PlatformBridgePlugin.TAG, "Exact alarm refused, falling back to inexact", e)
            }
        }
        alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pendingIntent)
        return "inexact"
    }

    fun cancel(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, WakeupReceiver::class.java).setAction(ACTION)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}
