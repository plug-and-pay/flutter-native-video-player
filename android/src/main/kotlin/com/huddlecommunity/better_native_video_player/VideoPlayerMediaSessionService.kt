package com.huddlecommunity.better_native_video_player

import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.lang.ref.WeakReference

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

    private enum class State {
        IDLE,

        // startForegroundService issued, onStartCommand not reached yet.
        // Stopping the service in this window makes Android throw
        // ForegroundServiceDidNotStartInTimeException (fast feed scrolling:
        // play on the new page, then pause/dispose before the service started).
        STARTING,
        RUNNING,

        // stopService/stopSelf issued, onDestroy not reached yet. A start()
        // here must start the service again instead of only refreshing the
        // notification of a service that is going away.
        STOPPING,
    }

    companion object {
        private const val TAG = "VideoPlayerMSS"

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
        private var state: State = State.IDLE

        // stop() requested while STARTING; honoured right after startForeground.
        @Volatile
        private var stopRequested: Boolean = false

        // The player whose notification is shown: the last one to start, or to
        // post while nothing plays. All players share one service and one
        // notification, so another player's pause or dispose must not stop the
        // service or replace the notification of the player that is playing.
        @Volatile
        private var owner: WeakReference<Any>? = null

        // Id of the instance that ran onStartCommand last. A restart while
        // STOPPING creates a new instance; the old one's onDestroy must not
        // reset the new one's state.
        @Volatile
        private var activeInstanceId: Int = 0

        private var lastInstanceId: Int = 0

        private val isForeground: Boolean
            get() = state == State.STARTING || state == State.RUNNING

        private fun isOwnedByOther(player: Any): Boolean {
            val current = owner?.get() ?: return false
            return current !== player
        }

        private fun setOwner(player: Any) {
            if (owner?.get() !== player) owner = WeakReference(player)
        }

        private fun notificationManager(context: Context): NotificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        /**
         * Promotes [player]'s playback to a foreground service showing
         * [notification]. Safe to call repeatedly: while already running it just
         * refreshes the notification (e.g. when artwork finishes loading) instead
         * of re-issuing startForegroundService, which Android 12+ forbids from
         * the background.
         */
        fun start(context: Context, player: Any, notification: Notification) {
            setOwner(player)
            pendingNotification = notification
            when (state) {
                State.RUNNING -> {
                    notificationManager(context).notify(NOTIFICATION_ID, notification)
                    return
                }
                State.STARTING -> {
                    // onStartCommand picks up the latest pendingNotification.
                    // A newer start cancels a pending stop.
                    stopRequested = false
                    return
                }
                // The old instance is going away; keep the notification it
                // detaches from so the new instance takes it over.
                State.STOPPING -> removeNotificationOnStop = false
                State.IDLE -> {}
            }
            val intent = Intent(context, VideoPlayerMediaSessionService::class.java)
            try {
                state = State.STARTING
                stopRequested = false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    @Suppress("DEPRECATION")
                    context.startService(intent)
                }
            } catch (e: Exception) {
                state = State.IDLE
                // Android 12+ throws ForegroundServiceStartNotAllowedException if
                // play is triggered while the app is in the background (e.g. a
                // programmatic resume or PiP transition). Fall back to a plain
                // posted notification so we never crash — background network may
                // still be limited until the next foreground play, but playback
                // that is already running keeps its notification.
                NpLog.w(TAG, "FGS start refused (${e.javaClass.simpleName}); posting notification only")
                notificationManager(context).notify(NOTIFICATION_ID, notification)
            }
        }

        /**
         * Stops the foreground service for [player]; ignored while another
         * player owns it. A null [player] stops it regardless (all players gone).
         * [removeNotification] = false detaches the notification (keeps it
         * visible, for resume on pause); true removes it.
         */
        fun stop(context: Context, player: Any?, removeNotification: Boolean) {
            if (player != null && isOwnedByOther(player)) return
            removeNotificationOnStop = removeNotification
            when (state) {
                State.STARTING -> {
                    // Can't stop before startForeground ran; defer to onStartCommand.
                    stopRequested = true
                    return
                }
                State.RUNNING -> state = State.STOPPING
                State.IDLE, State.STOPPING -> {}
            }
            try {
                context.stopService(Intent(context, VideoPlayerMediaSessionService::class.java))
            } catch (e: Exception) {
                if (state == State.STOPPING) state = State.RUNNING
                NpLog.w(TAG, "Stopping the service failed (${e.javaClass.simpleName})")
            }
        }

        /**
         * Posts [player]'s [notification] without foreground status (e.g. the
         * paused state); ignored while another player is playing. While a start
         * is in flight, onStartCommand would otherwise promote the older
         * (playing) notification over this one, and a pending stop must keep it
         * visible instead of removing it.
         */
        fun postNotification(context: Context, player: Any, notification: Notification) {
            if (isForeground && isOwnedByOther(player)) return
            setOwner(player)
            removeNotificationOnStop = false
            if (state == State.STARTING) pendingNotification = notification
            notificationManager(context).notify(NOTIFICATION_ID, notification)
        }

        /**
         * Drops [player]'s ownership when it is released, so the remaining
         * players can stop the service and update the notification again. The
         * notification shown is [player]'s, so it goes too (with the service if
         * [player] was playing).
         */
        fun releaseOwner(context: Context, player: Any) {
            if (owner?.get() !== player) return
            if (isForeground) {
                owner = null
                stop(context, player = null, removeNotification = true)
            } else {
                cancelNotification(context, player)
            }
        }

        /**
         * Removes [player]'s notification; ignored while another player owns it.
         */
        fun cancelNotification(context: Context, player: Any) {
            if (isOwnedByOther(player)) return
            owner = null
            // A pending stop would otherwise detach the notification that
            // onStartCommand re-posts.
            removeNotificationOnStop = true
            notificationManager(context).cancel(NOTIFICATION_ID)
        }
    }

    private val instanceId: Int = ++lastInstanceId

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = pendingNotification
        if (notification == null) {
            // No notification to show — must not leave a started service that
            // never calls startForeground (crashes on O+). Bail cleanly.
            NpLog.w(TAG, "onStartCommand with no pending notification; stopping")
            state = State.IDLE
            stopRequested = false
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
        activeInstanceId = instanceId
        state = State.RUNNING
        NpLog.d(TAG, "Foreground service started (playback)")
        if (stopRequested) {
            stopRequested = false
            state = State.STOPPING
            NpLog.d(TAG, "Stop was requested during start; stopping now")
            stopSelf()
        }
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
        // A newer start may already be in flight; only the active instance
        // resets the shared state, and never a pending start.
        if (activeInstanceId == instanceId) {
            activeInstanceId = 0
            if (state != State.STARTING) state = State.IDLE
        }
        NpLog.d(TAG, "Foreground service stopped (removeNotification=$removeNotificationOnStop)")
        super.onDestroy()
    }
}
