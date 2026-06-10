package com.huddlecommunity.better_native_video_player

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import androidx.media3.common.Player
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * MediaSessionService for native video player
 * Provides automatic media notification controls with play/pause buttons
 * Based on: https://developer.android.com/media/implement/surfaces/mobile
 *
 * IMPORTANT: MediaSessionService automatically creates and manages the notification
 * when there's an active MediaSession and the system calls onGetSession()
 * The notification appears automatically when media is playing
 */
class VideoPlayerMediaSessionService : MediaSessionService() {

    companion object {
        private const val TAG = "VideoPlayerMSS"

        // The MediaSession is stored here so it can be accessed by the service
        private var mediaSession: MediaSession? = null

        /**
         * Gets the current media session
         */
        fun getMediaSession(): MediaSession? = mediaSession

        /**
         * Sets the media session (called by VideoPlayerNotificationHandler)
         * This must be called before starting the service
         */
        fun setMediaSession(session: MediaSession?) {
            NpLog.d(TAG, "MediaSession ${if (session != null) "set" else "cleared"}, hasPlayer=${session?.player != null}")
            mediaSession = session
        }
    }

    override fun onCreate() {
        super.onCreate()
        NpLog.d(TAG, "VideoPlayerMediaSessionService onCreate, mediaSession=${mediaSession != null}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NpLog.d(TAG, "onStartCommand called, mediaSession=${mediaSession != null}, player=${mediaSession?.player != null}")

        // Important: Call super to trigger the Media3 notification framework
        val result = super.onStartCommand(intent, flags, startId)

        // Log player state for debugging
        mediaSession?.player?.let { player ->
            NpLog.d(TAG, "Player state: playWhenReady=${player.playWhenReady}, playbackState=${player.playbackState}, mediaItemCount=${player.mediaItemCount}")
        }

        return result
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        NpLog.d(TAG, "onGetSession called for ${controllerInfo.packageName}, returning session=${mediaSession != null}")

        // Return the MediaSession - this triggers the notification to appear
        return mediaSession
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        NpLog.d(TAG, "Task removed")
        val session = mediaSession
        if (session != null) {
            if (!session.player.playWhenReady || session.player.mediaItemCount == 0) {
                // Stop the service if not playing
                NpLog.d(TAG, "Stopping service - not playing")
                stopSelf()
            }
        } else {
            stopSelf()
        }
    }

    override fun onDestroy() {
        NpLog.d(TAG, "VideoPlayerMediaSessionService onDestroy")
        // Don't release the player or session here - they're managed by the notification handler
        super.onDestroy()
    }
}