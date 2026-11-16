package com.huddlecommunity.better_native_video_player.handlers

import com.huddlecommunity.better_native_video_player.NpLog
import com.huddlecommunity.better_native_video_player.VideoPlayerMediaSessionService

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList

/**
 * The player's Media3 MediaSession: lock screen, notification, quick settings
 * media player, headset and Bluetooth buttons. Equivalent to iOS
 * VideoPlayerNowPlayingHandler.
 *
 * The notification itself is Media3's, shown by [VideoPlayerMediaSessionService]
 * while this player is the one that started playing last. It carries the
 * title, subtitle and artwork from the media info, with rewind 10 s,
 * play/pause and forward 10 s.
 */
@UnstableApi
class VideoPlayerNotificationHandler(
    private val context: Context,
    private val player: ExoPlayer,
    private var eventHandler: VideoPlayerEventHandler
) {
    companion object {
        private const val TAG = "VideoPlayerNotification"
        private var sessionCounter = 0

        /** Seek step of the notification's rewind and forward buttons. */
        const val SEEK_STEP_MS = 10_000L
    }

    private var mediaSession: MediaSession? = null

    // Media info last applied, to skip replacing the media item when nothing changed.
    private var currentTitle: String = "Video"
    private var currentSubtitle: String = ""
    private var currentArtworkUrl: String? = null

    // A mixing player (creation param `mixWithOthers`: muted feed tile,
    // background loop) shows no media notification and starts no media
    // session or foreground service: that would put it on the lock screen and
    // take the media controls from a real video. Play/pause events still go out.
    var mixWithOthers: Boolean = false

    /**
     * The status-bar small icon must be a flat, alpha-only drawable — Android tints it, so a
     * full-color launcher icon renders as a solid white square. Prefer a dedicated
     * notification icon from the host app and only fall back to the launcher icon when none
     * is provided:
     * 1. a drawable named `ic_notification` in the host app,
     * 2. the FCM default notification icon meta-data (most apps with push already set it),
     * 3. the launcher icon (previous behavior).
     */
    private fun resolveSmallIconRes(): Int {
        val byName = context.resources.getIdentifier("ic_notification", "drawable", context.packageName)
        if (byName != 0) {
            return byName
        }

        try {
            val appInfo = context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.GET_META_DATA
            )
            val fcmIcon = appInfo.metaData
                ?.getInt("com.google.firebase.messaging.default_notification_icon", 0) ?: 0
            if (fcmIcon != 0) {
                return fcmIcon
            }
        } catch (e: Exception) {
            NpLog.w(TAG, "Could not read notification icon meta-data: ${e.message}")
        }

        return context.applicationInfo.icon
    }

    private val playerListener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (playWhenReady) {
                // The player that starts playing takes the notification; Media3
                // runs the service in the foreground while it plays, which keeps
                // the app's network alive for background streaming.
                showInNotification()
                eventHandler.sendEvent("play")
            } else {
                // Pause: Media3 drops foreground status and keeps a dismissible
                // notification so the user can resume.
                eventHandler.sendEvent("pause")
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_ENDED, Player.STATE_IDLE -> hideFromNotification()
                Player.STATE_READY -> if (player.playWhenReady) showInNotification()
            }
        }
    }

    /**
     * Updates the event handler (needed when shared NotificationHandler is reused by new VideoPlayerView)
     */
    fun updateEventHandler(newEventHandler: VideoPlayerEventHandler) {
        eventHandler = newEventHandler
        NpLog.d(TAG, "Event handler updated for shared notification handler")
    }

    /**
     * Writes title, artist, album and artwork into the player's current
     * MediaItem, which the session (and so the notification) reads.
     */
    private fun updatePlayerMediaItemMetadata(mediaInfo: Map<String, Any>?) {
        if (mediaInfo == null) return

        val currentItem = player.currentMediaItem ?: return

        val metadataBuilder = MediaMetadata.Builder()
        (mediaInfo["title"] as? String)?.let { metadataBuilder.setTitle(it) }
        (mediaInfo["subtitle"] as? String)?.let { metadataBuilder.setArtist(it) }
        (mediaInfo["album"] as? String)?.let { metadataBuilder.setAlbumTitle(it) }
        (mediaInfo["artworkUrl"] as? String)?.let { metadataBuilder.setArtworkUri(Uri.parse(it)) }

        val updatedItem = currentItem.buildUpon()
            .setMediaMetadata(metadataBuilder.build())
            .build()

        // Replace the MediaItem without interrupting playback
        val wasPlaying = player.isPlaying
        val position = player.currentPosition
        player.replaceMediaItem(player.currentMediaItemIndex, updatedItem)
        player.seekTo(position)
        if (wasPlaying) player.play()

        NpLog.d(TAG, "Updated player MediaItem metadata - title: ${mediaInfo["title"]}, subtitle: ${mediaInfo["subtitle"]}")
    }

    /**
     * Sets up the MediaSession with metadata (title, subtitle, artwork).
     * Similar to iOS MPNowPlayingInfoCenter - shows on the lock screen and in
     * the media notification while playing.
     */
    fun setupMediaSession(mediaInfo: Map<String, Any>?) {
        if (mixWithOthers) return

        val newTitle = (mediaInfo?.get("title") as? String) ?: "Video"
        val newSubtitle = (mediaInfo?.get("subtitle") as? String) ?: ""
        val newArtworkUrl = mediaInfo?.get("artworkUrl") as? String
        val mediaInfoChanged = newTitle != currentTitle || newSubtitle != currentSubtitle ||
            newArtworkUrl != currentArtworkUrl
        currentTitle = newTitle
        currentSubtitle = newSubtitle
        currentArtworkUrl = newArtworkUrl
        NpLog.d(TAG, "📱 Media info - title: $currentTitle, subtitle: $currentSubtitle, changed: $mediaInfoChanged")

        if (mediaSession != null) {
            // Only replace the MediaItem when the info changed, to avoid playback interruptions
            if (mediaInfoChanged) updatePlayerMediaItemMetadata(mediaInfo)
            if (player.playWhenReady) showInNotification()
            return
        }

        // Tapping the notification opens the app
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        } ?: Intent()
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val sessionId = "huddle_video_player_${++sessionCounter}"
        mediaSession = MediaSession.Builder(context, player)
            .setId(sessionId)
            .setSessionActivity(pendingIntent)
            // Rewind 10 s / play-pause / forward 10 s, like the inline controls
            .setMediaButtonPreferences(
                ImmutableList.of(
                    CommandButton.Builder(CommandButton.ICON_SKIP_BACK_10)
                        .setPlayerCommand(Player.COMMAND_SEEK_BACK)
                        .setDisplayName("Rewind 10 seconds")
                        .setSlots(CommandButton.SLOT_BACK)
                        .build(),
                    CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_10)
                        .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
                        .setDisplayName("Forward 10 seconds")
                        .setSlots(CommandButton.SLOT_FORWARD)
                        .build()
                )
            )
            .build()

        player.addListener(playerListener)
        NpLog.d(TAG, "MediaSession created - lock screen and notification controls active")

        mediaInfo?.let { updatePlayerMediaItemMetadata(it) }

        if (player.playWhenReady) showInNotification()
    }

    /**
     * Kept for callers that update media info separately; artwork is now
     * loaded by Media3 from the MediaItem's artwork URI.
     */
    fun updateMediaMetadata(mediaInfo: Map<String, Any>) {
        if (mixWithOthers) return
        setupMediaSession(mediaInfo)
    }

    private fun showInNotification() {
        if (mixWithOthers) return
        val session = mediaSession ?: return
        VideoPlayerMediaSessionService.show(context, session, resolveSmallIconRes())
    }

    private fun hideFromNotification() {
        val session = mediaSession ?: return
        VideoPlayerMediaSessionService.hide(session)
    }

    /**
     * Releases the MediaSession; its notification goes with it. [removeNotification]
     * is kept for source compatibility: a released session can't stay in the
     * notification, and another player's notification is never touched.
     */
    fun release(@Suppress("UNUSED_PARAMETER") removeNotification: Boolean = true) {
        player.removeListener(playerListener)
        hideFromNotification()
        mediaSession?.release()
        mediaSession = null
        currentTitle = "Video"
        currentSubtitle = ""
        currentArtworkUrl = null
        NpLog.d(TAG, "MediaSession released")
    }
}
