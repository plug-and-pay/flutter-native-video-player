package com.huddlecommunity.better_native_video_player.handlers

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.C

/**
 * Observes ExoPlayer state changes and reports them via EventHandler
 * Equivalent to iOS VideoPlayerObserver
 */
class VideoPlayerObserver(
    private val player: Player,
    private val eventHandler: VideoPlayerEventHandler,
    private val notificationHandler: com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler? = null,
    private val getMediaInfo: (() -> Map<String, Any>?)? = null,
    private val controllerId: Int? = null,
    private val viewId: Long? = null
) : Player.Listener {

    companion object {
        private const val TAG = "VideoPlayerObserver"
        private const val UPDATE_INTERVAL_MS = 500L // Update every 500ms
    }

    // Track if we've already sent a buffering event to avoid duplicates
    private var hasReportedBuffering = false

    // Track Cast/external playback connection state
    private var wasExternalPlaybackActive = false

    private val handler = Handler(Looper.getMainLooper())
    private val timeUpdateRunnable = object : Runnable {
        override fun run() {
            var position: Long
            var duration: Long

            // Check if this is a live stream (not just dynamic, but actually non-seekable live)
            val timeline = player.currentTimeline
            val window = Timeline.Window()

            val isLiveStream = !timeline.isEmpty &&
                timeline.getWindow(player.currentMediaItemIndex, window).isDynamic &&
                !window.isSeekable

            if (isLiveStream) {
                // For HLS live streams, use the seekable window to calculate relative position
                // Get the window information
                timeline.getWindow(player.currentMediaItemIndex, window)

                // Duration is the seekable window size
                duration = window.durationMs

                // Position is relative to the seekable window start
                // windowStartTimeMs gives us the absolute start time of the window
                position = player.currentPosition - window.windowStartTimeMs

                // Clamp position to valid range
                if (position < 0) position = 0
                if (position > duration) position = duration
            } else {
                // Regular VOD content - use direct position and duration
                position = player.currentPosition
                duration = player.duration
            }

            // Get buffered position
            val bufferedPosition = player.bufferedPosition.toInt() // milliseconds

            // Check if currently buffering
            val isBuffering = player.playbackState == Player.STATE_BUFFERING

            if (duration > 0) {
                eventHandler.sendEvent("timeUpdate", mapOf(
                    "position" to position.toInt(),
                    "duration" to duration.toInt(),
                    "bufferedPosition" to bufferedPosition,
                    "isBuffering" to isBuffering
                ))
            }

            // Schedule next update
            handler.postDelayed(this, UPDATE_INTERVAL_MS)
        }
    }

    init {
        // Start periodic time updates
        handler.post(timeUpdateRunnable)
    }

    fun release() {
        // Stop periodic updates
        handler.removeCallbacks(timeUpdateRunnable)
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        Log.d(TAG, "Playback state changed: $playbackState, isLoading: ${player.isLoading}")
        when (playbackState) {
            Player.STATE_IDLE -> {
                // Player is idle
            }
            Player.STATE_BUFFERING -> {
                // Send buffering event when entering BUFFERING state
                // Only send if we haven't already reported buffering
                if (!hasReportedBuffering) {
                    Log.d(TAG, "Entering BUFFERING state, sending buffering event")
                    eventHandler.sendEvent("buffering")
                    hasReportedBuffering = true
                }
            }
            Player.STATE_READY -> {
                // Reset buffering flag when we're ready
                hasReportedBuffering = false

                // Ready state is handled by onIsLoadingChanged when loading finishes
                // But send loaded event with duration here as it's state-specific
                val duration = player.duration.toInt()
                if (duration > 0 && !player.isLoading) {
                    eventHandler.sendEvent("loaded", mapOf("duration" to duration))
                }
            }
            Player.STATE_ENDED -> {
                // When looping is enabled with REPEAT_MODE_ONE, this state shouldn't be reached
                // as ExoPlayer handles looping internally. However, handle it for safety.
                // Check actual repeat mode instead of stale enableLooping parameter
                if (player.repeatMode != Player.REPEAT_MODE_ONE) {
                    // Reset video to the beginning and pause
                    player.seekTo(0)
                    player.pause()
                    eventHandler.sendEvent("completed")
                }
                // Don't send completed event when looping (repeat mode is ON)
                // This ensures consistent behavior even if setLooping() was called after observer init
            }
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        Log.d(TAG, "Is playing changed: $isPlaying, playbackState: ${player.playbackState}")
        if (isPlaying) {
            // ALWAYS update media session/notification when playback starts
            // This ensures media controls show the correct info whether in normal view or PiP
            val mediaInfo = getMediaInfo?.invoke()
            if (mediaInfo != null && notificationHandler != null) {
                val title = mediaInfo["title"] as? String
                Log.d(TAG, "📱 [Observer] Player started playing, updating media session for: $title")
                notificationHandler.setupMediaSession(mediaInfo)
                Log.d(TAG, "✅ [Observer] Media session updated - controls should now show correct info")
            } else {
                if (mediaInfo == null) {
                    Log.w(TAG, "⚠️ [Observer] No media info available when playing - media controls may not show correctly")
                }
                if (notificationHandler == null) {
                    Log.w(TAG, "⚠️ [Observer] No notification handler available")
                }
            }
            eventHandler.sendEvent("play")
        } else {
            // Only send pause event if not buffering
            // When seeking to unbuffered position, isPlaying becomes false but player is buffering
            // We should not report this as a pause - the buffering event will be sent instead
            if (player.playbackState != Player.STATE_BUFFERING) {
                eventHandler.sendEvent("pause")
            }
        }
    }

    override fun onIsLoadingChanged(isLoading: Boolean) {
        Log.d(TAG, "Is loading changed: $isLoading, playbackState: ${player.playbackState}, isPlaying: ${player.isPlaying}, playWhenReady: ${player.playWhenReady}")

        // Send buffering event when loading starts in BUFFERING state
        // This catches cases where isLoading changes before playbackState
        // Only send if we haven't already reported buffering
        if (isLoading && player.playbackState == Player.STATE_BUFFERING && !hasReportedBuffering) {
            Log.d(TAG, "Loading started while in BUFFERING state, sending buffering event")
            eventHandler.sendEvent("buffering")
            hasReportedBuffering = true
        } else if (!isLoading && player.playbackState == Player.STATE_READY) {
            // Reset buffering flag when loading finishes
            hasReportedBuffering = false

            // Send loading event when player becomes ready after loading
            eventHandler.sendEvent("loading")

            // Restore the playback state after buffering completes
            // This tells the UI whether the video is playing or paused
            // IMPORTANT: Only send play/pause if player is not currently buffering
            // During initial buffering, isPlaying might be true (playWhenReady=true)
            // but the video hasn't actually started playing yet
            if (player.playbackState != Player.STATE_BUFFERING) {
                if (player.isPlaying) {
                    eventHandler.sendEvent("play")
                } else {
                    eventHandler.sendEvent("pause")
                }
            }
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "Player error: ${error.message}", error)
        eventHandler.sendEvent(
            "error",
            mapOf("message" to (error.message ?: "Unknown error"))
        )
    }

    override fun onDeviceInfoChanged(deviceInfo: androidx.media3.common.DeviceInfo) {
        // Check if playing to a remote device (Cast)
        val isExternalPlaybackActive = deviceInfo.playbackType == androidx.media3.common.DeviceInfo.PLAYBACK_TYPE_REMOTE

        // Only send event if the state changed
        if (isExternalPlaybackActive != wasExternalPlaybackActive) {
            wasExternalPlaybackActive = isExternalPlaybackActive
            Log.d(TAG, "Cast/external playback changed: $isExternalPlaybackActive")
            eventHandler.sendEvent(
                "airPlayConnectionChanged",
                mapOf("isConnected" to isExternalPlaybackActive)
            )
        }
    }
}
