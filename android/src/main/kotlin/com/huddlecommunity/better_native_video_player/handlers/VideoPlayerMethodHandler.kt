package com.huddlecommunity.better_native_video_player.handlers

import android.app.Activity
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Timeline
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
            "getAvailableSubtitleTracks" -> handleGetAvailableSubtitleTracks(result)
            "setSubtitleTrack" -> handleSetSubtitleTrack(call, result)
            "enterFullScreen" -> handleEnterFullScreen(result)
            "exitFullScreen" -> handleExitFullScreen(result)
            "isAirPlayAvailable" -> handleIsAirPlayAvailable(result)
            "showAirPlayPicker" -> handleShowAirPlayPicker(result)
            "startAirPlayDetection" -> handleStartAirPlayDetection(result)
            "stopAirPlayDetection" -> handleStopAirPlayDetection(result)
            "disconnectAirPlay" -> handleDisconnectAirPlay(result)
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

        // Fetch qualities asynchronously for HLS streams
        if (url.contains(".m3u8")) {
            CoroutineScope(Dispatchers.Main).launch {
                availableQualities = VideoPlayerQualityHandler.fetchHLSQualities(url)
                Log.d(TAG, "Fetched ${availableQualities.size} qualities")

                // Store in SharedPlayerManager if this is a shared player
                if (controllerId != null) {
                    SharedPlayerManager.setQualities(controllerId, availableQualities)
                }

                // Send qualityChange event to notify Flutter that qualities are loaded
                if (availableQualities.isNotEmpty()) {
                    val defaultQuality = availableQualities.first()
                    eventHandler.sendEvent("qualityChange", mapOf(
                        "url" to (defaultQuality["url"] ?: ""),
                        "label" to (defaultQuality["label"] ?: "Auto"),
                        "isAuto" to (defaultQuality["isAuto"] ?: true)
                    ))
                    Log.d(TAG, "Sent qualityChange event with ${availableQualities.size} available qualities")
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

                    // Send AirPlay availability (always false on Android)
                    checkAndSendAirPlayAvailability()

                    // Auto play if requested - MUST be done after player is ready
                    if (autoPlay) {
                        Log.d(TAG, "Auto-playing video after ready")
                        player.play()
                        // Play event will be sent automatically by VideoPlayerObserver
                    }

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
     * Starts AirPlay device detection (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleStartAirPlayDetection(result: MethodChannel.Result) {
        Log.d(TAG, "AirPlay detection start requested but not supported on Android")
        // Simply return success - AirPlay is not available on Android
        result.success(null)
    }

    /**
     * Stops AirPlay device detection (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleStopAirPlayDetection(result: MethodChannel.Result) {
        Log.d(TAG, "AirPlay detection stop requested but not supported on Android")
        // Simply return success - AirPlay is not available on Android
        result.success(null)
    }

    /**
     * Disconnects from AirPlay device (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleDisconnectAirPlay(result: MethodChannel.Result) {
        Log.d(TAG, "AirPlay disconnect requested but not supported on Android")
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

    // MARK: - Subtitle Track Handling

    /**
     * Gets available subtitle tracks from the current player
     */
    private fun handleGetAvailableSubtitleTracks(result: MethodChannel.Result) {
        try {
            val tracks = mutableListOf<Map<String, Any>>()

            // Get the current tracks from the player
            val currentTracks = player.currentTracks

            // Get track selection parameters to find the selected track
            val trackSelectionParameters = player.trackSelectionParameters

            // Iterate through all track groups
            for (groupIndex in 0 until currentTracks.groups.size) {
                val group = currentTracks.groups[groupIndex]

                // Only process text (subtitle) tracks
                if (group.type == C.TRACK_TYPE_TEXT) {
                    // Iterate through all tracks in this group
                    for (trackIndex in 0 until group.length) {
                        val format = group.getTrackFormat(trackIndex)
                        val isSelected = group.isTrackSelected(trackIndex)

                        // Get language code (e.g., "en", "es", "fr")
                        val languageCode = format.language ?: "unknown"

                        // Get display name (use label if available, otherwise language code)
                        val displayName = format.label?.takeIf { it.isNotEmpty() }
                            ?: languageCode.let { code ->
                                // Try to get localized language name
                                try {
                                    val locale = java.util.Locale(code)
                                    locale.getDisplayLanguage(java.util.Locale.getDefault())
                                        .takeIf { it.isNotEmpty() } ?: code
                                } catch (e: Exception) {
                                    code
                                }
                            }

                        val trackInfo = mapOf(
                            "index" to trackIndex,
                            "language" to languageCode,
                            "displayName" to displayName,
                            "isSelected" to isSelected
                        )

                        tracks.add(trackInfo)
                        Log.d(TAG, "📝 Found subtitle track: $displayName ($languageCode) - Selected: $isSelected")
                    }
                }
            }

            Log.d(TAG, "📝 Total subtitle tracks found: ${tracks.size}")
            result.success(tracks)
        } catch (e: Exception) {
            Log.e(TAG, "Error getting subtitle tracks: ${e.message}", e)
            result.success(emptyList<Map<String, Any>>())
        }
    }

    /**
     * Sets the subtitle track
     */
    private fun handleSetSubtitleTrack(call: MethodCall, result: MethodChannel.Result) {
        try {
            val args = call.arguments as? Map<*, *>
            val trackInfo = args?.get("track") as? Map<*, *>
            val index = trackInfo?.get("index") as? Int

            if (index == null) {
                result.error("INVALID_TRACK", "Invalid subtitle track data", null)
                return
            }

            // Index -1 means disable subtitles
            if (index == -1) {
                Log.d(TAG, "📝 Disabling subtitles")

                // Disable text track selection
                val newParameters = player.trackSelectionParameters
                    .buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                    .build()

                player.trackSelectionParameters = newParameters

                eventHandler.sendEvent("subtitleChange", mapOf(
                    "index" to -1,
                    "language" to "off",
                    "displayName" to "Off",
                    "isSelected" to false
                ))

                result.success(null)
                return
            }

            // Enable text tracks first
            var parametersBuilder = player.trackSelectionParameters
                .buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)

            // Find the track format for the requested index
            val currentTracks = player.currentTracks
            var trackFound = false
            var selectedLanguage = "unknown"
            var selectedDisplayName = "Unknown"

            for (groupIndex in 0 until currentTracks.groups.size) {
                val group = currentTracks.groups[groupIndex]

                if (group.type == C.TRACK_TYPE_TEXT && index < group.length) {
                    val format = group.getTrackFormat(index)
                    selectedLanguage = format.language ?: "unknown"
                    selectedDisplayName = format.label?.takeIf { it.isNotEmpty() }
                        ?: selectedLanguage

                    // Set preferred text language to the selected track's language
                    parametersBuilder = parametersBuilder
                        .setPreferredTextLanguage(selectedLanguage)

                    trackFound = true
                    break
                }
            }

            if (!trackFound) {
                result.error("INVALID_INDEX", "Invalid subtitle track index", null)
                return
            }

            player.trackSelectionParameters = parametersBuilder.build()

            Log.d(TAG, "📝 Selected subtitle track: $selectedDisplayName ($selectedLanguage)")

            eventHandler.sendEvent("subtitleChange", mapOf(
                "index" to index,
                "language" to selectedLanguage,
                "displayName" to selectedDisplayName,
                "isSelected" to true
            ))

            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "Error setting subtitle track: ${e.message}", e)
            result.error("ERROR", "Failed to set subtitle track: ${e.message}", null)
        }
    }
}
