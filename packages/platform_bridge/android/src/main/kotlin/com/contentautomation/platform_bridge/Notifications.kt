package com.contentautomation.platform_bridge

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** Plain local notifications ("Time reached", "Upload failed", ...). */
object Notifications {
    fun ensureChannels(context: Context, channels: List<Map<String, Any?>>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (spec in channels) {
            val id = spec["id"] as? String ?: continue
            val name = spec["name"] as? String ?: id
            val importance = when (spec["importance"] as? String) {
                "min" -> NotificationManager.IMPORTANCE_MIN
                "low" -> NotificationManager.IMPORTANCE_LOW
                "high" -> NotificationManager.IMPORTANCE_HIGH
                else -> NotificationManager.IMPORTANCE_DEFAULT
            }
            val channel = NotificationChannel(id, name, importance).apply {
                description = spec["description"] as? String
                setShowBadge(importance >= NotificationManager.IMPORTANCE_DEFAULT)
            }
            manager.createNotificationChannel(channel)
        }
    }

    fun show(
        context: Context,
        id: Int,
        channelId: String,
        title: String,
        body: String,
        ongoing: Boolean,
        progress: Int?,
        maxProgress: Int?,
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                context,
                id,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_upload)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(contentIntent)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setPriority(if (ongoing) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setCategory(if (ongoing) NotificationCompat.CATEGORY_PROGRESS else NotificationCompat.CATEGORY_STATUS)

        if (progress != null) {
            builder.setProgress(maxProgress ?: 100, progress, false).setOnlyAlertOnce(true)
        }

        return try {
            NotificationManagerCompat.from(context).notify(id, builder.build())
            true
        } catch (e: SecurityException) {
            Log.w(PlatformBridgePlugin.TAG, "Notification blocked", e)
            false
        }
    }

    fun cancel(context: Context, id: Int) {
        NotificationManagerCompat.from(context).cancel(id)
    }
}
