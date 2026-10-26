package com.contentautomation.platform_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-arms the schedule after a reboot / app update by starting the scheduler
 * service once. The Dart side re-plans the exact alarm and stops the service
 * again when nothing is due soon.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in ACTIONS) return
        val started = SchedulerServiceLauncher.start(context.applicationContext)
        Log.i(PlatformBridgePlugin.TAG, "$action received; scheduler service start requested=$started")
    }

    private companion object {
        val ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
