package com.contentautomation.platform_bridge

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Starts / inspects the flutter_background_service foreground service without
 * a compile-time dependency on that plugin (looked up by class name).
 */
object SchedulerServiceLauncher {
    private const val SERVICE_CLASS = "id.flutter.flutter_background_service.BackgroundService"

    fun start(context: Context): Boolean {
        return try {
            val serviceClass = Class.forName(SERVICE_CLASS)
            ContextCompat.startForegroundService(context, Intent(context, serviceClass))
            true
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (Android 12+) lands here when
            // the app is in the background without an exemption.
            Log.w(PlatformBridgePlugin.TAG, "Could not start scheduler service", e)
            false
        }
    }

    fun isRunning(context: Context): Boolean {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return activityManager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == SERVICE_CLASS
        }
    }
}
