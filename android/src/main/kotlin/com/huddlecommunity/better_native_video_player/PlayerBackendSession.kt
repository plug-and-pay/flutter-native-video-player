package com.huddlecommunity.better_native_video_player

import android.content.Context
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerEventHandler
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerMethodHandler
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerObserver
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager
import com.huddlecommunity.better_native_video_player.manager.VideoCacheManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * The display-independent half of a player backend: creation-arg parsing,
 * (shared) ExoPlayer acquisition, event/notification/method handlers, the
 * per-view EventChannel with its initial-state callback, viewport quality
 * capping, and the common disposal sequence.
 *
 * [VideoPlayerView] (platform views) and the texture backend compose this;
 * the display path (PlayerView/SurfaceView/SurfaceProducer, fullscreen)
 * stays in the backend. Extracted verbatim from VideoPlayerView so the
 * initialization ORDER is unchanged — in particular the EventChannel
 * handler is registered before the platform returns to Dart, which the
 * subscribe-retry on the Dart side relies on.
 *
 * [onSiblingDisposed] runs when another backend of the same shared
 * controller is disposed (rebind the video output, then emit state).
 */
@UnstableApi
class PlayerBackendSession(
    private val context: Context,
    private val viewId: Long,
    args: Map<String, Any>?,
    binaryMessenger: BinaryMessenger,
    private val onSiblingDisposed: () -> Unit
) {
    companion object {
        private const val TAG = "PlayerBackendSession"
    }

    val controllerId: Int? = args?.get("controllerId") as? Int
    val enableHDR: Boolean = args?.get("enableHDR") as? Boolean ?: false
    val showNativeControls: Boolean = args?.get("showNativeControls") as? Boolean ?: true
    val isSharedPlayer: Boolean

    val player: ExoPlayer
    val eventHandler: VideoPlayerEventHandler
    val notificationHandler: VideoPlayerNotificationHandler
    val methodHandler: VideoPlayerMethodHandler
    val observer: VideoPlayerObserver

    var currentMediaInfo: Map<String, Any>? = null
        private set

    private val eventChannel: EventChannel

    // Viewport-based quality capping (NativeVideoPlayerConfig.qualityForViewportSize)
    private val qualityForViewport: Boolean = args?.get("qualityForViewport") as? Boolean ?: false
    private var lastViewportWidth: Int = 0
    private var lastViewportHeight: Int = 0

    init {
        // Extract and store media info from args (if provided during initialization)
        // This ensures we have the correct media info even for shared players
        currentMediaInfo = args?.get("mediaInfo") as? Map<String, Any>
        currentMediaInfo?.let { mediaInfo ->
            val title = mediaInfo["title"] as? String
            NpLog.d(TAG, "📱 Stored media info during init: $title")
        }

        // Get or create shared player. The optional buffer config and
        // playback prioritization (from the Dart NativeVideoPlayerConfig)
        // only apply at first creation.
        val bufferConfig = args?.get("androidBufferConfig") as? Map<*, *>
        val prioritizeActivePlayback =
            args?.get("prioritizeActivePlayback") as? Boolean ?: false
        val sharedFlag: Boolean
        player = if (controllerId != null) {
            val (sharedPlayer, alreadyExisted) = SharedPlayerManager.getOrCreatePlayer(
                context,
                controllerId,
                bufferConfig,
                prioritizeActivePlayback
            )
            sharedFlag = alreadyExisted
            if (alreadyExisted) {
                NpLog.d(TAG, "Using existing shared player for controller ID: $controllerId")
            } else {
                NpLog.d(TAG, "Creating new shared player for controller ID: $controllerId")
            }
            sharedPlayer
        } else {
            NpLog.d(TAG, "No controller ID provided, creating new player")
            sharedFlag = false
            SharedPlayerManager.buildPlayer(context, bufferConfig, prioritizeActivePlayback)
        }
        isSharedPlayer = sharedFlag

        // Set repeat mode for looping
        val enableLooping = args?.get("enableLooping") as? Boolean ?: false
        player.repeatMode = if (enableLooping) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }
        NpLog.d(TAG, "Repeat mode set to: ${if (enableLooping) "REPEAT_MODE_ONE (looping enabled)" else "REPEAT_MODE_OFF (looping disabled)"}")

        // Setup event handler (pass isSharedPlayer flag)
        eventHandler = VideoPlayerEventHandler(isSharedPlayer = isSharedPlayer)

        // Setup notification handler (shared for shared players)
        notificationHandler = if (controllerId != null) {
            val handler = SharedPlayerManager.getOrCreateNotificationHandler(
                context, controllerId, player, eventHandler
            )
            // Update event handler for shared notification handler (in case it's being reused)
            handler.updateEventHandler(eventHandler)
            handler
        } else {
            VideoPlayerNotificationHandler(context, player, eventHandler)
        }

        // Setup method handler with callback to update media info
        methodHandler = VideoPlayerMethodHandler(
            context = context,
            player = player,
            eventHandler = eventHandler,
            notificationHandler = notificationHandler,
            updateMediaInfo = { mediaInfo -> currentMediaInfo = mediaInfo },
            controllerId = controllerId,
            enableHDR = enableHDR,
            enableDiskCache = args?.get("androidEnableDiskCache") as? Boolean ?: false,
            diskCacheMaxBytes = (args?.get("androidDiskCacheMaxBytes") as? Number)?.toLong()
                ?: VideoCacheManager.DEFAULT_MAX_BYTES
        )

        // Setup observer with notification handler and media info getter
        val timeUpdateIntervalMs =
            (args?.get("timeUpdateIntervalMs") as? Number)?.toLong() ?: 500L
        observer = VideoPlayerObserver(
            player = player,
            eventHandler = eventHandler,
            notificationHandler = notificationHandler,
            getMediaInfo = { currentMediaInfo },
            controllerId = controllerId,
            viewId = viewId,
            updateIntervalMs = timeUpdateIntervalMs,
            prioritizeActivePlayback = prioritizeActivePlayback
        )
        player.addListener(observer)

        // Register this backend with SharedPlayerManager if using a shared player
        // This allows other backends to notify us when they're disposed
        if (controllerId != null) {
            SharedPlayerManager.registerView(controllerId, viewId) {
                onSiblingDisposed()
            }
        }

        // Setup event channel
        val eventChannelName = "native_video_player_$viewId"
        eventChannel = EventChannel(binaryMessenger, eventChannelName)
        eventChannel.setStreamHandler(eventHandler)

        // Set up callback to send the current playback state when the event listener is attached
        // This ensures the Flutter side knows the initial state (idle, playing, paused, etc.)
        // This applies to both new and shared players
        eventHandler.setInitialStateCallback {
            NpLog.d(TAG, "Sending initial state - isPlaying: ${player.isPlaying}, playbackState: ${player.playbackState}, duration: ${player.duration}")

            // For shared players or players with media already loaded, send loaded event first
            if (player.playbackState != ExoPlayer.STATE_IDLE && player.duration >= 0) {
                NpLog.d(TAG, "Sending loaded event with duration: ${player.duration}")
                eventHandler.sendEvent("loaded", mapOf(
                    "duration" to player.duration.toInt()
                ), synchronous = true)
            }

            // Send buffering event if currently buffering
            if (player.playbackState == Player.STATE_BUFFERING) {
                NpLog.d(TAG, "Sending buffering event")
                eventHandler.sendEvent("buffering", synchronous = true)
            }
            // Then send the current playback state, but only if not buffering
            // During initial buffering, isPlaying might be true (playWhenReady=true)
            // but the video hasn't actually started playing yet
            else if (player.isPlaying) {
                NpLog.d(TAG, "Sending play event")
                eventHandler.sendEvent("play", synchronous = true)
            } else if (player.playbackState != Player.STATE_IDLE) {
                NpLog.d(TAG, "Sending pause event")
                eventHandler.sendEvent("pause", synchronous = true)
            } else {
                // Player is in IDLE state - send idle event to ensure UI shows correct state
                // Use synchronous=true to ensure this is the first event received
                NpLog.d(TAG, "Player is in IDLE state, sending idle event (synchronous)")
                eventHandler.sendEvent("idle", synchronous = true)
            }
        }
    }

    /**
     * Caps adaptive quality selection to the backend's physical pixel size
     * (qualityForViewport config). Without this, DefaultTrackSelector's
     * viewport defaults to the physical DISPLAY size, so every feed tile
     * selects full-screen quality. The cap is player-level and the player can
     * be shared by multiple backends: the most recent reporter wins, which is
     * correct for list→detail (the larger detail view reports later).
     *
     * [isFullScreen] suppresses the cap while in native fullscreen.
     */
    fun setViewportSize(width: Int, height: Int, isFullScreen: Boolean) {
        if (!qualityForViewport || width <= 0 || height <= 0) return
        lastViewportWidth = width
        lastViewportHeight = height
        if (!isFullScreen) {
            applyViewportConstraints(width, height)
        }
    }

    private fun applyViewportConstraints(width: Int, height: Int) {
        NpLog.d(TAG, "Applying viewport quality cap: ${width}x$height")
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setViewportSize(width, height, true)
            .build()
    }

    /** Lifts the viewport quality cap (used while in native fullscreen). */
    fun clearViewportConstraints() {
        if (!qualityForViewport) return
        NpLog.d(TAG, "Clearing viewport quality cap (fullscreen)")
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .clearViewportSizeConstraints()
            .build()
    }

    /** Re-applies the last reported viewport cap (after leaving fullscreen). */
    fun restoreViewportConstraints() {
        if (!qualityForViewport) return
        if (lastViewportWidth > 0 && lastViewportHeight > 0) {
            applyViewportConstraints(lastViewportWidth, lastViewportHeight)
        }
    }

    /**
     * Emits all current player states to ensure UI is in sync
     * This is useful after events like exiting PiP where the UI needs to refresh
     */
    fun emitCurrentState() {
        NpLog.d(TAG, "Emitting current state after PiP exit")

        // Emit current time and duration
        val currentPosition = player.currentPosition
        val duration = player.duration

        if (duration > 0) {
            // Get buffered position
            val bufferedPosition = player.bufferedPosition

            eventHandler.sendEvent("timeUpdate", mapOf(
                "position" to currentPosition.toInt(),
                "duration" to duration.toInt(),
                "bufferedPosition" to bufferedPosition.toInt(),
                "isBuffering" to (player.playbackState == ExoPlayer.STATE_BUFFERING)
            ))
            NpLog.d(TAG, "Emitted timeUpdate with duration: ${duration}ms")
        }

        // Emit current playback state
        if (player.isPlaying) {
            NpLog.d(TAG, "Emitting play state")
            eventHandler.sendEvent("play")
        } else if (player.playbackState != ExoPlayer.STATE_IDLE) {
            NpLog.d(TAG, "Emitting pause state")
            eventHandler.sendEvent("pause")
        }
    }

    /**
     * The display-independent disposal sequence, extracted verbatim from
     * VideoPlayerView.dispose. [detachOutput] runs the backend-specific
     * surface detach for shared players (another backend may still display
     * this player) before unregistering from SharedPlayerManager.
     */
    fun disposeCommon(detachOutput: () -> Unit) {
        // Remove listeners and stop periodic updates
        player.removeListener(observer)
        observer.release()

        // Clean up channels
        // First call onCancel to properly clean up the event sink
        // This prevents MissingPluginException when Flutter tries to cancel the subscription
        try {
            eventHandler.onCancel(null)
        } catch (e: Exception) {
            NpLog.w(TAG, "Error calling onCancel on event handler: ${e.message}")
        }
        // Then set the stream handler to null
        eventChannel.setStreamHandler(null)

        // Clear media info
        currentMediaInfo = null

        // Note: player and notification handler are NOT released here if they're shared
        // The shared player and notification handler will be kept alive for reuse
        if (controllerId != null) {
            NpLog.d(TAG, "Backend disposed but player and notification handler kept alive for controller ID: $controllerId")

            // IMPORTANT: For shared players, detach the player from this backend's display
            // surface to prevent disconnecting it. Another backend may still be
            // using the player.
            detachOutput()

            // Unregister this backend and notify remaining backends to reconnect their surfaces
            SharedPlayerManager.unregisterView(controllerId, viewId)
        } else {
            // Only release if not shared (for non-shared players, fully clean up media session)
            notificationHandler.release()
            player.release()
        }
    }
}
