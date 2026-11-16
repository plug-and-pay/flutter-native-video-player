package com.huddlecommunity.better_native_video_player

import android.content.Context
import android.content.Intent
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.huddlecommunity.native_video_player.R
import java.lang.ref.WeakReference

/**
 * Media3 MediaSessionService that backs the media notification and background
 * playback.
 *
 * Media3 builds the notification from the session (title, artwork, play/pause
 * and the seek buttons), keeps the service in the foreground while the
 * session plays (which is what keeps the app's network alive with the screen
 * off), drops to a dismissible notification when it pauses, and handles the
 * Android 12+ rule that a foreground service can't start from the background.
 *
 * All players share one service and one notification, so the service holds
 * one session at a time: the player that started playing last. Another
 * player starting takes it over; another player pausing, ending or being
 * released can't touch it. That keeps the 1.8.1 ownership rules.
 *
 * Main thread only.
 */
@UnstableApi
class VideoPlayerMediaSessionService : MediaSessionService() {

    companion object {
        private const val TAG = "VideoPlayerMSS"

        const val NOTIFICATION_ID = 1001
        const val CHANNEL_ID = "video_player_channel"

        private var instance: WeakReference<VideoPlayerMediaSessionService>? = null

        // The session that should be in the service. Set before the service
        // exists; onCreate adds it.
        private var wanted: MediaSession? = null

        // Small icon for the notification, resolved by the handler.
        private var smallIcon: Int = 0

        private fun service(): VideoPlayerMediaSessionService? = instance?.get()

        /**
         * Shows [session] in the notification (and lets Media3 run the service
         * in the foreground while it plays), replacing any other player's.
         */
        fun show(context: Context, session: MediaSession, smallIconRes: Int) {
            smallIcon = smallIconRes
            wanted = session
            val running = service()
            if (running != null) {
                running.attach(session)
                return
            }
            try {
                context.startService(Intent(context, VideoPlayerMediaSessionService::class.java))
            } catch (e: Exception) {
                // Background start refused (Android 8+): without a running
                // service there is no notification until the next foreground play.
                NpLog.w(TAG, "Could not start the media service (${e.javaClass.simpleName})")
                wanted = null
            }
        }

        /**
         * Removes [session] from the notification; ignored when another
         * player's session is the one shown.
         */
        fun hide(session: MediaSession) {
            if (wanted === session) wanted = null
            val running = service() ?: return
            if (running.isSessionAdded(session)) {
                running.removeSession(session)
            }
            running.stopIfEmpty()
        }

        /** Removes whatever is shown and stops the service (all players gone). */
        fun stopAll() {
            wanted = null
            val running = service() ?: return
            running.sessions.toList().forEach { running.removeSession(it) }
            running.stopIfEmpty()
        }

        /** Whether [session] is the one in the notification (tests, diagnostics). */
        fun isShowing(session: MediaSession): Boolean = service()?.isSessionAdded(session) == true
    }

    override fun onCreate() {
        super.onCreate()
        instance = WeakReference(this)
        val provider = DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(CHANNEL_ID)
            .setChannelName(R.string.bnvp_notification_channel_name)
            .setNotificationId(NOTIFICATION_ID)
            .build()
        if (smallIcon != 0) provider.setSmallIcon(smallIcon)
        setMediaNotificationProvider(provider)
        wanted?.let { attach(it) }
        NpLog.d(TAG, "Media service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        // Media3 asks to be restarted (START_STICKY). A restart after the
        // process died has no player and no Flutter engine to play, so it
        // would only bring back a stale notification: stay stopped instead.
        if (wanted == null && sessions.isEmpty()) stopSelf()
        return START_NOT_STICKY
    }

    // The plugin's own players are in-process; external controllers (other
    // apps) get no session. System UI reads the platform session token.
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        if (controllerInfo.packageName == packageName) wanted else null

    private fun attach(session: MediaSession) {
        // One session at a time: the notification belongs to the player that
        // started last.
        sessions.filter { it !== session }.forEach { removeSession(it) }
        if (!isSessionAdded(session)) addSession(session)
    }

    private fun stopIfEmpty() {
        if (sessions.isEmpty()) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        if (instance?.get() === this) instance = null
        NpLog.d(TAG, "Media service destroyed")
        super.onDestroy()
    }
}
