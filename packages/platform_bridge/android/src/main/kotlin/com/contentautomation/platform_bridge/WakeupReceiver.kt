package com.contentautomation.platform_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

/** Fired by the exact alarm; brings the scheduler service up. */
class WakeupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Wakeups.ACTION) return
        // Keep the CPU awake until the service is up and holds its own wake
        // lock. The lock is time-limited and deliberately not released here:
        // startForegroundService() is asynchronous and the broadcast's own
        // wake lock ends as soon as onReceive() returns.
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK, "platform_bridge:wakeup"
        )
        wakeLock.acquire(60_000L)
        val started = SchedulerServiceLauncher.start(context.applicationContext)
        Log.i(PlatformBridgePlugin.TAG, "Wake-up alarm fired; service start requested=$started")
    }
}
