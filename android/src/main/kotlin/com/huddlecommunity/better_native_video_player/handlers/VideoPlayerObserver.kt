package com.huddlecommunity.better_native_video_player.handlers

import com.huddlecommunity.better_native_video_player.NpLog

import android.os.Handler
import android.os.Looper
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer

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
    private val viewId: Long? = null,
    private val updateIntervalMs: Long = 500L,
    private val prioritizeActivePlayback: Boolean = false
) : Player.Listener {

    companion object {
        private const val TAG = "VideoPlayerObserver"
    }

    // Track if we've already sent a buffering event to avoid duplicates
    private var hasReportedBuffering = false

    // Track Cast/external playback connection state
    private var wasExternalPlaybackActive = false

    private val handler = Handler(Looper.getMainLooper())

    // The ticker only runs while the player is actually playing: paused/idle
    // players don't change position, so ticking them is wasted channel
    // traffic and main-thread wakeups (multiplied by the number of players in
    // a feed). One final update is sent on pause/seek so UIs stay correct.
    private var isTickerRunning = false

    private val timeUpdateRunnable = object : Runnable {
        override fun run() {
            sendTimeUpdate()
            if (isTickerRunning) {
                handler.postDelayed(this, updateIntervalMs)
            }
        }
    }

    /** Sends a single timeUpdate event with the current position/duration. */
    fun sendTimeUpdate() {
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
    }

    private fun startTicker() {
        if (isTickerRunning) return
        isTickerRunning = true
        handler.post(timeUpdateRunnable)
    }

    private fun stopTicker() {
        if (!isTickerRunning) return
        isTickerRunning = false
        handler.removeCallbacks(timeUpdateRunnable)
    }

    init {
        // A shared player may already be playing when this observer attaches
        // (view reattachment with the same controller ID)
        if (player.isPlaying) {
            startTicker()
        }
    }

    fun release() {
        // Stop periodic updates
        stopTicker()
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        NpLog.d(TAG, "Playback state changed: $playbackState, isLoading: ${player.isLoading}")
        when (playbackState) {
            Player.STATE_IDLE -> {
                // Player is idle
            }
            Player.STATE_BUFFERING -> {
                // Send buffering event when entering BUFFERING state
                // Only send if we haven't already reported buffering
                if (!hasReportedBuffering) {
                    NpLog.d(TAG, "Entering BUFFERING state, sending buffering event")
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
        NpLog.d(TAG, "Is playing changed: $isPlaying, playbackState: ${player.playbackState}")
        if (isPlaying) {
            startTicker()
        } else {
            // One final update so paused UIs show the exact position
            sendTimeUpdate()
            stopTicker()
        }

        // With prioritizeActivePlayback, playing players win network/IO
        // contention over paused ones (shared PriorityTaskManager attached in
        // SharedPlayerManager.buildPlayer)
        if (prioritizeActivePlayback) {
            (player as? ExoPlayer)?.setPriority(
                if (isPlaying) C.PRIORITY_PLAYBACK else C.PRIORITY_PLAYBACK_PRELOAD
            )
            NpLog.d(
                TAG,
                "Playback priority -> ${if (isPlaying) "PLAYBACK" else "PLAYBACK_PRELOAD"} (view $viewId)"
            )
        }

        if (isPlaying) {
            // ALWAYS update media session/notification when playback starts
            // This ensures media controls show the correct info whether in normal view or PiP
            val mediaInfo = getMediaInfo?.invoke()
            if (mediaInfo != null && notificationHandler != null) {
                val title = mediaInfo["title"] as? String
                NpLog.d(TAG, "📱 [Observer] Player started playing, updating media session for: $title")
                notificationHandler.setupMediaSession(mediaInfo)
                NpLog.d(TAG, "✅ [Observer] Media session updated - controls should now show correct info")
            } else {
                if (mediaInfo == null) {
                    NpLog.w(TAG, "⚠️ [Observer] No media info available when playing - media controls may not show correctly")
                }
                if (notificationHandler == null) {
                    NpLog.w(TAG, "⚠️ [Observer] No notification handler available")
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
        NpLog.d(TAG, "Is loading changed: $isLoading, playbackState: ${player.playbackState}, isPlaying: ${player.isPlaying}, playWhenReady: ${player.playWhenReady}")

        // Send buffering event when loading starts in BUFFERING state
        // This catches cases where isLoading changes before playbackState
        // Only send if we haven't already reported buffering
        if (isLoading && player.playbackState == Player.STATE_BUFFERING && !hasReportedBuffering) {
            NpLog.d(TAG, "Loading started while in BUFFERING state, sending buffering event")
            eventHandler.sendEvent("buffering")
            hasReportedBuffering = true
        } else if (!isLoading && player.playbackState == Player.STATE_READY) {
            // Reset buffering flag when loading finishes
            hasReportedBuffering = false

            // Note: "loaded" event is already sent by onPlaybackStateChanged when STATE_READY is reached
            // No need to send it again here

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

    override fun onPositionDiscontinuity(
        oldPosition: Player.PositionInfo,
        newPosition: Player.PositionInfo,
        reason: Int
    ) {
        // Seeking while paused must still update the UI position (the ticker
        // only runs during playback)
        if (reason == Player.DISCONTINUITY_REASON_SEEK) {
            sendTimeUpdate()
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        NpLog.e(TAG, "Player error: ${error.message}", error)
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
            NpLog.d(TAG, "Cast/external playback changed: $isExternalPlaybackActive")
            eventHandler.sendEvent(
                "airPlayConnectionChanged",
                mapOf("isConnected" to isExternalPlaybackActive)
            )
        }
    }
}
