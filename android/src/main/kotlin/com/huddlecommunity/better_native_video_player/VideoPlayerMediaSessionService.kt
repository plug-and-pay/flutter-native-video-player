package com.huddlecommunity.better_native_video_player

import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that backs background video playback.
 *
 * Streaming (live + VOD) needs the app to keep network access while the screen
 * is off. A plain posted notification does NOT grant that — only a *running
 * foreground service* exempts the app from Android's Doze / app-standby
 * background-network restrictions. Without it the OS cuts the app's network
 * after a few minutes in the background and ExoPlayer fails with
 * `UnknownHostException (no network)`.
 *
 * The service runs (showing the media notification) only while the player is
 * actually playing, and is stopped on pause/stop. [VideoPlayerNotificationHandler]
 * drives [start]/[stop]; the notification itself is built there so its
 * appearance is unchanged.
 *
 * NOTE: this was previously a (never-started, never-given-a-session) Media3
 * MediaSessionService. It is now a plain foreground Service. The lock-screen
 * MediaSession lives independently in [VideoPlayerNotificationHandler].
 */
class VideoPlayerMediaSessionService : Service() {

    companion object {
        private const val TAG = "VideoPlayerMSS"

        // Must match VideoPlayerNotificationHandler.NOTIFICATION_ID so the
        // foreground notification and the handler's notify()/cancel() updates
        // operate on a single notification entry.
        const val NOTIFICATION_ID = 1001

        // The notification to promote to foreground with. Set just before the
        // service is started; same process, so a static handoff is safe.
        @Volatile
        private var pendingNotification: Notification? = null

        // false on pause (detach: keep the notification so the user can resume);
        // true on stop/idle/dispose (remove it).
        @Volatile
        private var removeNotificationOnStop: Boolean = true

        @Volatile
        private var isRunning: Boolean = false

        /**
         * Promotes playback to a foreground service showing [notification].
         * Safe to call repeatedly: while already running it just refreshes the
         * notification (e.g. when artwork finishes loading) instead of re-issuing
         * startForegroundService — which Android 12+ forbids from the background.
         */
        fun start(context: Context, notification: Notification) {
            pendingNotification = notification
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (isRunning) {
                nm.notify(NOTIFICATION_ID, notification)
                return
            }
            val intent = Intent(context, VideoPlayerMediaSessionService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    @Suppress("DEPRECATION")
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ throws ForegroundServiceStartNotAllowedException if
                // play is triggered while the app is in the background (e.g. a
                // programmatic resume or PiP transition). Fall back to a plain
                // posted notification so we never crash — background network may
                // still be limited until the next foreground play, but playback
                // that is already running keeps its notification.
                NpLog.w(TAG, "FGS start refused (${e.javaClass.simpleName}); posting notification only")
                nm.notify(NOTIFICATION_ID, notification)
            }
        }

        /**
         * Stops the foreground service. [removeNotification] = false detaches the
         * notification (keeps it visible, for resume on pause); true removes it.
         */
        fun stop(context: Context, removeNotification: Boolean) {
            removeNotificationOnStop = removeNotification
            context.stopService(Intent(context, VideoPlayerMediaSessionService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = pendingNotification
        if (notification == null) {
            // No notification to show — must not leave a started service that
            // never calls startForeground (crashes on O+). Bail cleanly.
            NpLog.w(TAG, "onStartCommand with no pending notification; stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isRunning = true
        NpLog.d(TAG, "Foreground service started (playback)")
        // Not sticky: a system-killed service should not auto-restart with a
        // stale notification; playback recreation is driven from Dart.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        val flags = if (removeNotificationOnStop) {
            Service.STOP_FOREGROUND_REMOVE
        } else {
            Service.STOP_FOREGROUND_DETACH
        }
        stopForeground(flags)
        isRunning = false
        NpLog.d(TAG, "Foreground service stopped (removeNotification=$removeNotificationOnStop)")
        super.onDestroy()
    }
}
