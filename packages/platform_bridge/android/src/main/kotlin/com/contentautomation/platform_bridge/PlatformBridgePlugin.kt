package com.contentautomation.platform_bridge

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Native helpers that the Dart side (UI isolate, background service isolate
 * and WorkManager isolate alike) reaches through a single method channel.
 *
 * Because this is a regular Flutter plugin it is registered automatically in
 * every FlutterEngine the app creates, which is what makes it usable from the
 * background isolates.
 */
class PlatformBridgePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingNotificationPermission: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // --- ActivityAware -------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    // --- Method channel ------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getDeviceInfo" -> result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "brand" to Build.BRAND,
                        "model" to Build.MODEL,
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "release" to Build.VERSION.RELEASE,
                    )
                )

                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())
                "openBatteryOptimizationSettings" -> result.success(
                    launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                )

                "areNotificationsEnabled" -> result.success(
                    NotificationManagerCompat.from(context).areNotificationsEnabled()
                )
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "ensureNotificationChannels" -> {
                    @Suppress("UNCHECKED_CAST")
                    val channels = call.argument<List<Map<String, Any?>>>("channels") ?: emptyList()
                    Notifications.ensureChannels(context, channels)
                    result.success(null)
                }
                "showNotification" -> result.success(
                    Notifications.show(
                        context = context,
                        id = call.argument<Number>("id")!!.toInt(),
                        channelId = call.argument<String>("channelId")!!,
                        title = call.argument<String>("title") ?: "",
                        body = call.argument<String>("body") ?: "",
                        ongoing = call.argument<Boolean>("ongoing") ?: false,
                        progress = call.argument<Number>("progress")?.toInt(),
                        maxProgress = call.argument<Number>("maxProgress")?.toInt(),
                    )
                )
                "cancelNotification" -> {
                    Notifications.cancel(context, call.argument<Number>("id")!!.toInt())
                    result.success(null)
                }

                "canScheduleExactAlarms" -> result.success(canScheduleExactAlarms())
                "requestExactAlarmPermission" -> result.success(requestExactAlarmPermission())
                "scheduleWakeup" -> result.success(
                    Wakeups.schedule(context, call.argument<Number>("atEpochMillis")!!.toLong())
                )
                "cancelWakeup" -> {
                    Wakeups.cancel(context)
                    result.success(null)
                }

                "startSchedulerService" -> result.success(SchedulerServiceLauncher.start(context))
                "isSchedulerServiceRunning" -> result.success(SchedulerServiceLauncher.isRunning(context))

                "openAppSettings" -> result.success(
                    launch(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${context.packageName}"),
                        )
                    )
                )
                "openAutoStartSettings" -> result.success(openAutoStartSettings())

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Method ${call.method} failed", e)
            result.error("bridge_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // --- Battery optimisation ------------------------------------------------

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Shows the system "Let app always run in background?" dialog. Requires the
     * REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission (declared by the app).
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        )
        if (launch(direct)) return true
        // Some OEM builds hide the dialog; fall back to the list screen.
        return launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    // --- Notifications permission (Android 13+) ------------------------------

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(NotificationManagerCompat.from(context).areNotificationsEnabled())
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.success(false)
            return
        }
        if (pendingNotificationPermission != null) {
            result.error("in_progress", "A notification permission request is already showing", null)
            return
        }
        pendingNotificationPermission = result
        ActivityCompat.requestPermissions(
            currentActivity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermission?.success(granted)
        pendingNotificationPermission = null
        return true
    }

    // --- Exact alarms --------------------------------------------------------

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return alarmManager.canScheduleExactAlarms()
    }

    private fun requestExactAlarmPermission(): Boolean {
        if (canScheduleExactAlarms()) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return launch(
            Intent(
                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:${context.packageName}"),
            )
        )
    }

    // --- OEM "auto-start" / app-killer settings --------------------------------

    private fun openAutoStartSettings(): Boolean {
        for (component in AUTO_START_SCREENS) {
            val intent = Intent().setComponent(component)
            if (launch(intent, quiet = true)) return true
        }
        return false
    }

    // --- Helpers -------------------------------------------------------------

    /** Starts [intent] from the Activity when attached, otherwise as a new task. */
    private fun launch(intent: Intent, quiet: Boolean = false): Boolean {
        return try {
            val currentActivity = activity
            if (currentActivity != null) {
                currentActivity.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            true
        } catch (e: ActivityNotFoundException) {
            if (!quiet) Log.w(TAG, "No activity for ${intent.action ?: intent.component}", e)
            false
        } catch (e: SecurityException) {
            if (!quiet) Log.w(TAG, "Not allowed to start ${intent.action ?: intent.component}", e)
            false
        }
    }

    companion object {
        const val TAG = "PlatformBridge"
        const val CHANNEL_NAME = "com.contentautomation/platform_bridge"
        private const val NOTIFICATION_PERMISSION_REQUEST = 7301

        /** Known vendor screens where users must whitelist background apps. */
        private val AUTO_START_SCREENS = listOf(
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
            ComponentName("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.powersaver.PowerSaverSettings"),
            ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"),
            ComponentName("com.htc.pitroad", "com.htc.pitroad.landingpage.activity.LandingPageActivity"),
            ComponentName("com.transsion.phonemanager", "com.itel.autobootmanager.activity.AutoBootMgrActivity"),
        )
    }
}
