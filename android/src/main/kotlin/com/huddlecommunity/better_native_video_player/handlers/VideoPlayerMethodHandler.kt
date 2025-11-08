package com.huddlecommunity.better_native_video_player.handlers

import android.app.Activity
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager

/**
 * Handles method calls from Flutter for video player control
 * Equivalent to iOS VideoPlayerMethodHandler
 */
@UnstableApi
class VideoPlayerMethodHandler(
    private val context: Context,
    private val player: ExoPlayer,
    private val eventHandler: VideoPlayerEventHandler,
    private val notificationHandler: VideoPlayerNotificationHandler,
    private val updateMediaInfo: ((Map<String, Any>?) -> Unit)? = null,
    private val controllerId: Int? = null,
    private val enableHDR: Boolean = false
) {
    companion object {
        private const val TAG = "VideoPlayerMethod"
    }

    private var availableQualities: List<Map<String, Any>> = emptyList()
    private var isAutoQuality = false
    private var lastBitrateCheck = 0L
    private val bitrateCheckInterval = 5000L // 5 seconds
    private var currentVideoIsHls = false // Track if current video is HLS for quality switching

    // Callback to handle fullscreen requests from Flutter
    var onFullscreenRequest: ((Boolean) -> Unit)? = null

    // Callback to handle PiP requests from Flutter
    var onEnterPictureInPictureRequest: (() -> Boolean)? = null
    var onExitPictureInPictureRequest: (() -> Boolean)? = null

    /**
     * Handles incoming method calls from Flutter
     */
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "Handling method call: ${call.method}")

        when (call.method) {
            "load" -> handleLoad(call, result)
            "play" -> handlePlay(result)
            "pause" -> handlePause(result)
            "seekTo" -> handleSeekTo(call, result)
            "setVolume" -> handleSetVolume(call, result)
            "setSpeed" -> handleSetSpeed(call, result)
            "setLooping" -> handleSetLooping(call, result)
            "setQuality" -> handleSetQuality(call, result)
            "getAvailableQualities" -> handleGetAvailableQualities(result)
            "enterFullScreen" -> handleEnterFullScreen(result)
            "exitFullScreen" -> handleExitFullScreen(result)
            "isPictureInPictureAvailable" -> handleIsPictureInPictureAvailable(result)
            "enterPictureInPicture" -> handleEnterPictureInPicture(result)
            "exitPictureInPicture" -> handleExitPictureInPicture(result)
            "isAirPlayAvailable" -> handleIsAirPlayAvailable(result)
            "showAirPlayPicker" -> handleShowAirPlayPicker(result)
            "dispose" -> handleDispose(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Loads a video URL into the player
     */
    private fun handleLoad(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val url = args?.get("url") as? String

        if (url == null) {
            result.error("INVALID_URL", "URL is required", null)
            return
        }

        val autoPlay = args["autoPlay"] as? Boolean ?: false
        val headers = args["headers"] as? Map<String, String>
        val mediaInfo = args["mediaInfo"] as? Map<String, Any>

        // Store media info in the VideoPlayerView
        updateMediaInfo?.invoke(mediaInfo)
        mediaInfo?.let {
            val title = it["title"] as? String
            Log.d(TAG, "📱 Stored media info during load: $title")
        }

        Log.d(TAG, "Loading video: $url (autoPlay: $autoPlay)")

        eventHandler.sendEvent("loading")

        // Determine if this is a local file or remote URL
        val isLocalFile = url.startsWith("file://") || url.startsWith("/")
        val isHls = isHlsUrl(url)
        currentVideoIsHls = isHls // Track for quality switching

        Log.d(TAG, "Video source type - Local: $isLocalFile, HLS: $isHls")

        // Build data source factory
        // For remote URLs with custom headers, use HTTP-specific data source
        // For local files, use DefaultDataSource which supports file:// URIs
        val finalDataSourceFactory = if (!isLocalFile && headers != null) {
            DefaultHttpDataSource.Factory().apply {
                setDefaultRequestProperties(headers)
            }
        } else {
            DefaultDataSource.Factory(context)
        }

        // Build MediaItem with metadata
        val mediaItemBuilder = MediaItem.Builder()
            .setUri(url)

        // Add metadata if provided
        if (mediaInfo != null) {
            val metadataBuilder = androidx.media3.common.MediaMetadata.Builder()
            (mediaInfo["title"] as? String)?.let { metadataBuilder.setTitle(it) }
            (mediaInfo["subtitle"] as? String)?.let { metadataBuilder.setArtist(it) }
            (mediaInfo["album"] as? String)?.let { metadataBuilder.setAlbumTitle(it) }
            mediaItemBuilder.setMediaMetadata(metadataBuilder.build())
        }

        val mediaItem = mediaItemBuilder.build()

        // Create appropriate MediaSource based on URL type
        val mediaSource: MediaSource = if (isHls) {
            // HLS stream
            Log.d(TAG, "Creating HLS media source")
            HlsMediaSource.Factory(finalDataSourceFactory)
                .createMediaSource(mediaItem)
        } else {
            // Progressive download/playback (MP4, local files, etc.)
            Log.d(TAG, "Creating progressive media source")
            ProgressiveMediaSource.Factory(finalDataSourceFactory)
                .createMediaSource(mediaItem)
        }

        // Set media source
        player.setMediaSource(mediaSource)
        player.prepare()

        // Configure HDR settings for ExoPlayer using TrackSelectionParameters
        if (!enableHDR) {
            Log.d(TAG, "🎨 HDR disabled - ExoPlayer will use automatic tone-mapping for HDR content")
            // Note: ExoPlayer automatically tone-maps HDR content to SDR on devices
            // that don't support HDR or when the display doesn't support it.
            //
            // For more explicit control over track selection to avoid HDR tracks entirely,
            // we would need to:
            // 1. Implement a custom TrackSelector that filters based on Format.colorInfo.colorTransfer
            // 2. Check for COLOR_TRANSFER_HLG, COLOR_TRANSFER_ST2084 (HDR10), etc.
            // 3. Configure this at player creation time with a DefaultTrackSelector.Builder
            //
            // However, this is complex and may break adaptive streaming benefits.
            // ExoPlayer's automatic tone-mapping is generally sufficient for most use cases.
            //
            // See: https://github.com/androidx/media/issues/1074
        } else {
            Log.d(TAG, "🎨 HDR enabled - allowing native HDR playback")
        }

        // Set autoplay
        if (autoPlay) {
            player.play()
        }

        // Fetch qualities asynchronously for HLS streams
        if (url.contains(".m3u8")) {
            CoroutineScope(Dispatchers.Main).launch {
                availableQualities = VideoPlayerQualityHandler.fetchHLSQualities(url)
                Log.d(TAG, "Fetched ${availableQualities.size} qualities")

                // Store in SharedPlayerManager if this is a shared player
                if (controllerId != null) {
                    SharedPlayerManager.setQualities(controllerId, availableQualities)
                }
            }
        }

        // NOTE: Media session will be set up when playback starts (in VideoPlayerObserver)
        // This ensures the correct video's metadata is displayed even when switching between videos

        // Wait for player to be ready
        val listener = object : androidx.media3.common.Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == androidx.media3.common.Player.STATE_READY) {
                    eventHandler.sendEvent("loaded")
                    player.removeListener(this)
                    
                    // Check and send PiP availability after video is loaded
                    checkAndSendPipAvailability()
                    
                    // Send AirPlay availability (always false on Android)
                    checkAndSendAirPlayAvailability()
                    
                    result.success(null)
                }
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                player.removeListener(this)
                result.error("LOAD_ERROR", error.message ?: "Unknown error", null)
            }
        }
        player.addListener(listener)
    }

    /**
     * Starts playback
     */
    private fun handlePlay(result: MethodChannel.Result) {
        player.play()
        result.success(null)
    }

    /**
     * Pauses playback
     */
    private fun handlePause(result: MethodChannel.Result) {
        player.pause()
        result.success(null)
    }

    /**
     * Seeks to a specific position
     */
    private fun handleSeekTo(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val milliseconds = args?.get("milliseconds") as? Int
        if (milliseconds != null) {
            player.seekTo(milliseconds.toLong())
            eventHandler.sendEvent("seek", mapOf("position" to milliseconds))
        }
        result.success(null)
    }

    /**
     * Sets playback volume
     */
    private fun handleSetVolume(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val volume = args?.get("volume") as? Double
        if (volume != null) {
            player.volume = volume.toFloat()
        }
        result.success(null)
    }

    /**
     * Sets playback speed
     */
    private fun handleSetSpeed(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val speed = args?.get("speed") as? Double
        if (speed != null) {
            player.setPlaybackSpeed(speed.toFloat())
            eventHandler.sendEvent("speedChange", mapOf("speed" to speed))
        }
        result.success(null)
    }

    /**
     * Sets whether the video should loop
     */
    private fun handleSetLooping(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val looping = args?.get("looping") as? Boolean
        if (looping != null) {
            player.repeatMode = if (looping) {
                androidx.media3.common.Player.REPEAT_MODE_ONE
            } else {
                androidx.media3.common.Player.REPEAT_MODE_OFF
            }
            Log.d(TAG, "Looping set to: $looping")
        }
        result.success(null)
    }

    /**
     * Changes video quality (for HLS streams)
     */
    private fun handleSetQuality(call: MethodCall, result: MethodChannel.Result) {
        // Check if current video is HLS before attempting quality switch
        if (!currentVideoIsHls) {
            result.error("NOT_HLS", "Quality switching is only available for HLS streams", null)
            return
        }

        val args = call.arguments as? Map<*, *>
        val qualityInfo = args?.get("quality") as? Map<*, *>

        if (qualityInfo == null) {
            result.error("INVALID_QUALITY", "Invalid quality data", null)
            return
        }

        val isAuto = qualityInfo["isAuto"] as? Boolean ?: false
        isAutoQuality = isAuto

        if (isAuto) {
            // Start with the middle quality for auto mode
            val midIndex = (availableQualities.size / 2 - 1).coerceAtLeast(0)
            if (midIndex >= availableQualities.size) {
                result.error("NO_QUALITIES", "No qualities available", null)
                return
            }

            val initialQuality = availableQualities[midIndex]
            switchToQuality(initialQuality, result)

            // Start monitoring quality
            startQualityMonitoring()
        } else {
            val url = qualityInfo["url"] as? String
            val label = qualityInfo["label"] as? String

            if (url == null) {
                result.error("INVALID_QUALITY", "Quality URL is required", null)
                return
            }

            eventHandler.sendEvent("loading")

            // Save current state
            val wasPlaying = player.isPlaying
            val currentPosition = player.currentPosition

            // Build new media source
            // Use DefaultDataSource for consistency with load method
            val dataSourceFactory = DefaultDataSource.Factory(context)
            val mediaItem = MediaItem.fromUri(url)
            val mediaSource = HlsMediaSource.Factory(dataSourceFactory)
                .createMediaSource(mediaItem)

            // Switch to new quality
            player.setMediaSource(mediaSource)
            player.prepare()
            player.seekTo(currentPosition)
            
            // Only resume playback if it was playing before
            if (wasPlaying) {
                player.play()
            }

            eventHandler.sendEvent("qualityChange", mapOf(
                "url" to url,
                "label" to (label ?: ""),
                "isAuto" to false
            ))

            result.success(null)
        }
    }

    private fun startQualityMonitoring() {
        // Quality monitoring is simplified for now
        // In a production app, you would implement bandwidth monitoring here
        Log.d(TAG, "Auto quality monitoring enabled (simplified implementation)")
    }

    private fun switchToQuality(quality: Map<String, Any>, result: MethodChannel.Result?) {
        val url = quality["url"] as? String ?: return
        val label = quality["label"] as? String ?: "Unknown"

        eventHandler.sendEvent("loading")

        // Save current state
        val wasPlaying = player.isPlaying
        val currentPosition = player.currentPosition

        // Build new media source
        // Use DefaultDataSource for consistency with load method
        val dataSourceFactory = DefaultDataSource.Factory(context)
        val mediaItem = MediaItem.fromUri(url)
        val mediaSource = HlsMediaSource.Factory(dataSourceFactory)
            .createMediaSource(mediaItem)

        // Switch to new quality
        player.setMediaSource(mediaSource)
        player.prepare()
        player.seekTo(currentPosition)

        // Only resume playback if it was playing before
        if (wasPlaying) {
            player.play()
        }

        eventHandler.sendEvent("qualityChange", mapOf(
            "url" to url,
            "label" to label,
            "isAuto" to isAutoQuality
        ))

        result?.success(null)
    }

    /**
     * Returns available video qualities
     */
    private fun handleGetAvailableQualities(result: MethodChannel.Result) {
        // First check if we have qualities in this instance
        if (availableQualities.isNotEmpty()) {
            result.success(availableQualities)
        } else if (controllerId != null) {
            // If instance is empty but cache has qualities, restore them
            val cachedQualities = SharedPlayerManager.getQualities(controllerId)
            if (cachedQualities != null && cachedQualities.isNotEmpty()) {
                availableQualities = cachedQualities
                Log.d(TAG, "🔄 Restored ${cachedQualities.size} qualities from cache for controller $controllerId")
                result.success(cachedQualities)
            } else {
                result.success(availableQualities)
            }
        } else {
            result.success(availableQualities)
        }
    }

    /**
     * Disposes the player
     */
    private fun handleDispose(result: MethodChannel.Result) {
        player.stop()

        // Remove from shared manager if this is a shared player
        if (controllerId != null) {
            SharedPlayerManager.removePlayer(context, controllerId)
            Log.d(TAG, "Removed shared player for controller ID: $controllerId")
        }

        eventHandler.sendEvent("stopped")
        result.success(null)
    }

    /**
     * Enters fullscreen mode
     * Triggers the native fullscreen dialog
     */
    private fun handleEnterFullScreen(result: MethodChannel.Result) {
        Log.d(TAG, "Flutter requested enter fullscreen")
        onFullscreenRequest?.invoke(true)
        result.success(null)
    }

    /**
     * Exits fullscreen mode
     * Dismisses the native fullscreen dialog
     */
    private fun handleExitFullScreen(result: MethodChannel.Result) {
        Log.d(TAG, "Flutter requested exit fullscreen")
        onFullscreenRequest?.invoke(false)
        result.success(null)
    }

    /**
     * Checks if AirPlay is available (iOS only - always false on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleIsAirPlayAvailable(result: MethodChannel.Result) {
        Log.d(TAG, "AirPlay availability checked - not supported on Android")
        // AirPlay is not available on Android
        result.success(false)
    }

    /**
     * Shows AirPlay picker (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleShowAirPlayPicker(result: MethodChannel.Result) {
        Log.d(TAG, "AirPlay picker requested but not supported on Android")
        // Simply return success - AirPlay is not available on Android
        result.success(null)
    }

    /**
     * Helper method to get Activity from Context, handling ContextWrapper cases
     * Same pattern as used in VideoPlayerView
     */
    private fun getActivity(ctx: Context?): Activity? {
        if (ctx == null) {
            return null
        }

        if (ctx is Activity) {
            return ctx
        }

        if (ctx is android.content.ContextWrapper) {
            return getActivity(ctx.baseContext)
        }

        return null
    }

    /**
     * Checks if Picture-in-Picture is available on this device
     * PiP is available on Android 8.0 (API 26) and above
     */
    private fun handleIsPictureInPictureAvailable(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Try to get activity from plugin first, then unwrap context
            val pluginActivity = com.huddlecommunity.better_native_video_player.NativeVideoPlayerPlugin.getActivity()
            val activity = pluginActivity ?: getActivity(context)

            if (activity != null) {
                // Check if the device supports PiP mode
                val hasPipFeature = activity.packageManager.hasSystemFeature(
                    android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
                )
                Log.d(TAG, "PiP availability checked - supported: $hasPipFeature")
                result.success(hasPipFeature)
            } else {
                Log.d(TAG, "PiP availability checked - no Activity context")
                result.success(false)
            }
        } else {
            Log.d(TAG, "PiP availability checked - requires Android 8.0+")
            result.success(false)
        }
    }

    /**
     * Enters Picture-in-Picture mode
     * Only works on Android 8.0 (API 26) and above
     */
    private fun handleEnterPictureInPicture(result: MethodChannel.Result) {
        Log.d(TAG, "Flutter requested enter PiP")
        val success = onEnterPictureInPictureRequest?.invoke() ?: false
        result.success(success)
    }

    /**
     * Exits Picture-in-Picture mode
     * Only works on Android 8.0 (API 26) and above
     */
    private fun handleExitPictureInPicture(result: MethodChannel.Result) {
        Log.d(TAG, "Flutter requested exit PiP")
        val success = onExitPictureInPictureRequest?.invoke() ?: false
        result.success(success)
    }

    /**
     * Checks if PiP is available and sends an event to Flutter
     */
    private fun checkAndSendPipAvailability() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Try to get activity from plugin first, then unwrap context
            val pluginActivity = com.huddlecommunity.better_native_video_player.NativeVideoPlayerPlugin.getActivity()
            val activity = pluginActivity ?: getActivity(context)

            if (activity != null) {
                val hasPipFeature = activity.packageManager.hasSystemFeature(
                    android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
                )
                Log.d(TAG, "🎬 PiP availability check: $hasPipFeature")
                eventHandler.sendEvent("pipAvailabilityChanged", mapOf("isAvailable" to hasPipFeature))
            } else {
                Log.d(TAG, "🎬 PiP availability check: false (no activity)")
                eventHandler.sendEvent("pipAvailabilityChanged", mapOf("isAvailable" to false))
            }
        } else {
            Log.d(TAG, "🎬 PiP availability check: false (API < 26)")
            eventHandler.sendEvent("pipAvailabilityChanged", mapOf("isAvailable" to false))
        }
    }

    /**
     * Sends AirPlay availability (always false on Android)
     * AirPlay is an Apple-only technology
     */
    private fun checkAndSendAirPlayAvailability() {
        Log.d(TAG, "📡 AirPlay availability check: false (Android)")
        eventHandler.sendEvent("airPlayAvailabilityChanged", mapOf("isAvailable" to false))
    }

    /**
     * Determines if a URL is an HLS stream
     * Checks for .m3u8 extension or common HLS patterns
     */
    private fun isHlsUrl(url: String): Boolean {
        val lowerUrl = url.lowercase()
        // Check for .m3u8 extension (most reliable indicator)
        if (lowerUrl.contains(".m3u8")) {
            return true
        }
        // Check for /hls/ as a path segment (not substring to avoid false positives like "english")
        if (Regex("/hls/").containsMatchIn(lowerUrl)) {
            return true
        }
        // Check for manifest in path
        if (lowerUrl.contains("manifest.m3u8")) {
            return true
        }
        return false
    }
}
