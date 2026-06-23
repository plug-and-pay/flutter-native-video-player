package com.huddlecommunity.better_native_video_player.handlers

import com.huddlecommunity.better_native_video_player.NpLog

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.MimeTypes
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.SingleSampleMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager
import com.huddlecommunity.better_native_video_player.manager.VideoCacheManager

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
    private val enableHDR: Boolean = false,
    private val enableDiskCache: Boolean = false,
    private val diskCacheMaxBytes: Long = VideoCacheManager.DEFAULT_MAX_BYTES
) {
    companion object {
        private const val TAG = "VideoPlayerMethod"

        /**
         * Determines if a URL is an HLS stream (.m3u8 extension or common
         * HLS patterns). Shared with VideoCacheManager.precache, which must
         * warm playlists+segments for HLS rather than raw bytes.
         */
        internal fun isHlsUrl(url: String): Boolean {
            val lowerUrl = url.lowercase()
            // .m3u8 extension (most reliable indicator)
            if (lowerUrl.contains(".m3u8")) {
                return true
            }
            // /hls/ as a path segment (not substring, avoiding false
            // positives like "english")
            return Regex("/hls/").containsMatchIn(lowerUrl)
        }
    }

    /**
     * Wraps [upstream] with the shared disk cache when enabled. DRM streams
     * and non-http sources (file://, content://, extracted assets) always
     * bypass the cache.
     */
    private fun maybeWrapWithCache(
        upstream: DataSource.Factory,
        url: String,
        hasDrm: Boolean
    ): DataSource.Factory {
        if (!enableDiskCache || hasDrm || !url.startsWith("http", ignoreCase = true)) {
            NpLog.d(TAG, "Disk cache bypass (enabled=$enableDiskCache, drm=$hasDrm) for $url")
            return upstream
        }
        NpLog.d(TAG, "Disk cache wrap for $url")
        return VideoCacheManager.buildCacheFactory(context, upstream, diskCacheMaxBytes)
    }

    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var audioFocusRequest: AudioFocusRequest? = null
    private val legacyAudioFocusListener = AudioManager.OnAudioFocusChangeListener { }

    private val audioFocusPlaybackListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) {
                requestAudioFocusForPlayback()
            } else {
                abandonAudioFocusForPlayback()
            }
        }
    }

    init {
        player.addListener(audioFocusPlaybackListener)
    }

    private var availableQualities: List<Map<String, Any>> = emptyList()
    private var isAutoQuality = false
    private var lastBitrateCheck = 0L
    private val bitrateCheckInterval = 5000L // 5 seconds
    private var currentVideoIsHls = false // Track if current video is HLS for quality switching

    // Ingredients of the last load, kept so sidecar subtitles can be attached
    // after the fact (the media source must be rebuilt fresh; Media3 forbids
    // reusing prepared MediaSource instances)
    private var lastMediaItem: MediaItem? = null
    private var lastDataSourceFactory: DataSource.Factory? = null

    // Sidecar subtitle configurations attached to the current media source.
    // They load UNSELECTED: the Flutter overlay renders inline captions; the
    // native track is only selected during PiP/native fullscreen, where the
    // Flutter UI is not visible (see setNativeSidecarActive).
    private var sidecarSubtitleConfigs: List<MediaItem.SubtitleConfiguration> = emptyList()

    // Callback to handle fullscreen requests from Flutter
    var onFullscreenRequest: ((Boolean) -> Unit)? = null

    private fun requestAudioFocusForPlayback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (audioFocusRequest == null) {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs)
                    .build()
            }
            audioFocusRequest?.let { request ->
                val result = audioManager.requestAudioFocus(request)
                if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    NpLog.d(TAG, "Audio focus requested and granted")
                }
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                legacyAudioFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
    }

    private fun abandonAudioFocusForPlayback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { request ->
                audioManager.abandonAudioFocusRequest(request)
                audioFocusRequest = null
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(legacyAudioFocusListener)
        }
    }

    /**
     * Handles incoming method calls from Flutter
     */
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        NpLog.d(TAG, "Handling method call: ${call.method}")

        when (call.method) {
            "load" -> handleLoad(call, result)
            "setSidecarSubtitles" -> handleSetSidecarSubtitles(call, result)
            "setNativeSidecarActive" -> handleSetNativeSidecarActive(call, result)
            "setSubtitlesSuppressedForPip" -> handleSetSubtitlesSuppressedForPip(call, result)
            "getAvailableAudioTracks" -> handleGetAvailableAudioTracks(result)
            "setAudioTrack" -> handleSetAudioTrack(call, result)
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
        val drmConfig = args["drmConfig"] as? Map<*, *>
        val startAtMs = (args["startAtMs"] as? Number)?.toLong() ?: 0L

        // Store media info in the VideoPlayerView
        updateMediaInfo?.invoke(mediaInfo)
        mediaInfo?.let {
            val title = it["title"] as? String
            NpLog.d(TAG, "📱 Stored media info during load: $title")
        }

        NpLog.d(TAG, "Loading video: $url (autoPlay: $autoPlay)")
        NpLog.d(TAG, "Current player state - playbackState: ${player.playbackState}, duration: ${player.duration}, hasMedia: ${player.currentMediaItem != null}")

        // Only send "loading" event if player is actually starting to load new media
        // Don't send if player is already in IDLE state with no media loaded
        // This prevents incorrect "loading" state when player is already idle
        // Check: STATE_IDLE means no media is loaded, and duration < 0 means C.TIME_UNSET (no duration)
        // Also check if player has a current media item - if not, it's truly idle with no media
        val isPlayerIdleWithNoMedia = player.playbackState == Player.STATE_IDLE && 
                                      player.duration < 0 && 
                                      player.currentMediaItem == null
        if (isPlayerIdleWithNoMedia) {
            NpLog.d(TAG, "Player is already idle with no media (playbackState=${player.playbackState}, duration=${player.duration}, hasMedia=${player.currentMediaItem != null}), skipping loading event")
            // Don't send loading event - the initial state should have already sent "idle"
            // If initial state wasn't sent yet, it will be sent when EventChannel connects
        } else {
            // Player has media or is in a different state, send loading event
            NpLog.d(TAG, "Sending loading event - player is not idle or has media")
            eventHandler.sendEvent("loading")
        }

        // Determine if this is a local file or remote URL
        val isLocalFile = url.startsWith("file://") || url.startsWith("/")
        val isHls = isHlsUrl(url)
        currentVideoIsHls = isHls // Track for quality switching

        NpLog.d(TAG, "Video source type - Local: $isLocalFile, HLS: $isHls")

        // Build data source factory
        // For remote URLs with custom headers, use HTTP-specific data source
        // For local files, use DefaultDataSource which supports file:// URIs
        val upstreamDataSourceFactory = if (!isLocalFile && headers != null) {
            DefaultHttpDataSource.Factory().apply {
                setDefaultRequestProperties(headers)
            }
        } else {
            DefaultDataSource.Factory(context)
        }
        // Opt-in disk cache wrap. hasDrm mirrors the condition under which a
        // DrmConfiguration is set on the MediaItem below — protected content
        // must never be written to the cache.
        val hasDrm = drmConfig?.get("licenseUrl") != null
        val finalDataSourceFactory =
            maybeWrapWithCache(upstreamDataSourceFactory, url, hasDrm)

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

        // Configure DRM if provided
        if (drmConfig != null) {
            val drmType = drmConfig["type"] as? String
            val licenseUrl = drmConfig["licenseUrl"] as? String
            val drmHeaders = drmConfig["headers"] as? Map<String, String>

            if (licenseUrl != null) {
                val uuid = when (drmType?.lowercase()) {
                    "widevine" -> C.WIDEVINE_UUID
                    "clearkey", "aes-128" -> C.CLEARKEY_UUID
                    else -> {
                        NpLog.w(TAG, "Unknown DRM type: $drmType, defaulting to Widevine")
                        C.WIDEVINE_UUID
                    }
                }

                val drmBuilder = MediaItem.DrmConfiguration.Builder(uuid)
                    .setLicenseUri(android.net.Uri.parse(licenseUrl))

                if (drmHeaders != null) {
                    drmBuilder.setLicenseRequestHeaders(drmHeaders)
                }

                mediaItemBuilder.setDrmConfiguration(drmBuilder.build())
                NpLog.d(TAG, "DRM configured - Type: $drmType, License URL: $licenseUrl")
            } else {
                NpLog.w(TAG, "DRM config provided but licenseUrl is missing")
            }
        }

        val mediaItem = mediaItemBuilder.build()

        // Remember the ingredients so sidecar subtitles can be (re)attached
        // later without re-passing the load parameters
        lastMediaItem = mediaItem
        lastDataSourceFactory = finalDataSourceFactory
        sidecarSubtitleConfigs = parseSidecarSubtitleConfigs(args["sidecarSubtitles"] as? List<*>)

        // Set media source (main source merged with any sidecar subtitles).
        // A resume position (startAtMs) is handed to ExoPlayer up front so
        // playback begins there directly — no visible seek after start.
        val mediaSource = buildMediaSourceWithSidecars(mediaItem, finalDataSourceFactory)
        if (startAtMs > 0) {
            player.setMediaSource(mediaSource, startAtMs)
        } else {
            player.setMediaSource(mediaSource)
        }
        player.prepare()

        // Configure HDR settings for ExoPlayer using TrackSelectionParameters
        if (!enableHDR) {
            NpLog.d(TAG, "🎨 HDR disabled - ExoPlayer will use automatic tone-mapping for HDR content")
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
            NpLog.d(TAG, "🎨 HDR enabled - allowing native HDR playback")
        }

        // Fetch qualities asynchronously for HLS streams
        if (url.contains(".m3u8")) {
            CoroutineScope(Dispatchers.Main).launch {
                availableQualities = VideoPlayerQualityHandler.fetchHLSQualities(url)
                NpLog.d(TAG, "Fetched ${availableQualities.size} qualities")

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
                    NpLog.d(TAG, "Sent qualityChange event with ${availableQualities.size} available qualities")
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
                        NpLog.d(TAG, "Auto-playing video after ready")
                        requestAudioFocusForPlayback()
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
        requestAudioFocusForPlayback()
        player.play()
        result.success(null)
    }

    /**
     * Pauses playback
     */
    private fun handlePause(result: MethodChannel.Result) {
        player.pause()
        abandonAudioFocusForPlayback()
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
            NpLog.d(TAG, "Looping set to: $looping")
        }
        result.success(null)
    }

    /**
     * Changes video quality (for HLS streams)
     */
    /**
     * Lists the alternate audio tracks (languages, audio description,
     * commentary) of the current media — the audio mirror of the subtitle
     * track API (issues #23/#16). Index is the track's position within its
     * audio track group, matching what handleSetAudioTrack expects.
     */
    private fun handleGetAvailableAudioTracks(result: MethodChannel.Result) {
        try {
            val tracks = mutableListOf<Map<String, Any>>()
            for (group in player.currentTracks.groups) {
                if (group.type != C.TRACK_TYPE_AUDIO) continue
                for (trackIndex in 0 until group.length) {
                    val format = group.getTrackFormat(trackIndex)
                    val languageCode = format.language ?: "unknown"
                    val displayName = format.label?.takeIf { it.isNotEmpty() }
                        ?: try {
                            java.util.Locale(languageCode)
                                .getDisplayLanguage(java.util.Locale.getDefault())
                                .takeIf { it.isNotEmpty() } ?: languageCode
                        } catch (e: Exception) {
                            languageCode
                        }
                    tracks.add(
                        mapOf(
                            "index" to tracks.size,
                            "language" to languageCode,
                            "displayName" to displayName,
                            "isSelected" to group.isTrackSelected(trackIndex)
                        )
                    )
                }
            }
            NpLog.d(TAG, "🔊 Total audio tracks found: ${tracks.size}")
            result.success(tracks)
        } catch (e: Exception) {
            NpLog.e(TAG, "Error getting audio tracks: ${e.message}", e)
            result.success(emptyList<Map<String, Any>>())
        }
    }

    /**
     * Selects an alternate audio track by flat index (the enumeration order
     * of handleGetAvailableAudioTracks). Uses a TrackSelectionOverride —
     * unlike a preferred-language hint, this distinguishes multiple tracks
     * of the same language (e.g. "English" vs "English audio description").
     */
    private fun handleSetAudioTrack(call: MethodCall, result: MethodChannel.Result) {
        try {
            val args = call.arguments as? Map<*, *>
            val trackInfo = args?.get("track") as? Map<*, *>
            val requestedIndex = trackInfo?.get("index") as? Int
            if (requestedIndex == null) {
                result.error("INVALID_TRACK", "Invalid audio track data", null)
                return
            }

            var flatIndex = 0
            for (group in player.currentTracks.groups) {
                if (group.type != C.TRACK_TYPE_AUDIO) continue
                for (trackIndex in 0 until group.length) {
                    if (flatIndex == requestedIndex) {
                        player.trackSelectionParameters = player.trackSelectionParameters
                            .buildUpon()
                            .setOverrideForType(
                                TrackSelectionOverride(group.mediaTrackGroup, trackIndex)
                            )
                            .build()

                        val format = group.getTrackFormat(trackIndex)
                        val languageCode = format.language ?: "unknown"
                        val displayName = format.label?.takeIf { it.isNotEmpty() } ?: languageCode
                        NpLog.d(TAG, "🔊 Selected audio track: $displayName ($languageCode)")
                        eventHandler.sendEvent(
                            "audioTrackChange",
                            mapOf(
                                "index" to requestedIndex,
                                "language" to languageCode,
                                "displayName" to displayName,
                                "isSelected" to true
                            )
                        )
                        result.success(null)
                        return
                    }
                    flatIndex++
                }
            }
            result.error("INVALID_INDEX", "Invalid audio track index", null)
        } catch (e: Exception) {
            NpLog.e(TAG, "Error setting audio track: ${e.message}", e)
            result.error("AUDIO_TRACK_ERROR", e.message, null)
        }
    }

    /**
     * Parses the Dart-side sidecar subtitle maps (URL sources only) into
     * Media3 SubtitleConfigurations. Loaded UNSELECTED by design — see the
     * sidecarSubtitleConfigs field comment.
     */
    private fun parseSidecarSubtitleConfigs(raw: List<*>?): List<MediaItem.SubtitleConfiguration> {
        if (raw == null) return emptyList()
        return raw.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            val url = map["url"] as? String ?: return@mapNotNull null
            val mimeType = when ((map["format"] as? String)?.lowercase()) {
                "srt" -> MimeTypes.APPLICATION_SUBRIP
                else -> MimeTypes.TEXT_VTT
            }
            MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(url))
                .setMimeType(mimeType)
                .setLanguage(map["language"] as? String)
                .setLabel(map["label"] as? String)
                .setSelectionFlags(0)
                .build()
        }
    }

    /**
     * Builds the playback MediaSource: the type-specific main source merged
     * with one SingleSampleMediaSource per sidecar subtitle (the documented
     * Media3 pattern for sideloading when not using DefaultMediaSourceFactory).
     */
    private fun buildMediaSourceWithSidecars(
        mediaItem: MediaItem,
        dataSourceFactory: DataSource.Factory
    ): MediaSource {
        val mainSource: MediaSource = if (currentVideoIsHls) {
            NpLog.d(TAG, "Creating HLS media source")
            HlsMediaSource.Factory(dataSourceFactory).createMediaSource(mediaItem)
        } else {
            NpLog.d(TAG, "Creating progressive media source")
            ProgressiveMediaSource.Factory(dataSourceFactory).createMediaSource(mediaItem)
        }
        if (sidecarSubtitleConfigs.isEmpty()) return mainSource

        NpLog.d(TAG, "Merging ${sidecarSubtitleConfigs.size} sidecar subtitle source(s)")
        val subtitleSources = sidecarSubtitleConfigs.map { config ->
            SingleSampleMediaSource.Factory(dataSourceFactory)
                .createMediaSource(config, C.TIME_UNSET)
        }
        return MergingMediaSource(mainSource, *subtitleSources.toTypedArray())
    }

    /**
     * Attaches sidecar subtitles after a load: rebuilds the media source with
     * the merged subtitle tracks, preserving position and play state.
     */
    private fun handleSetSidecarSubtitles(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        sidecarSubtitleConfigs = parseSidecarSubtitleConfigs(args?.get("sidecarSubtitles") as? List<*>)

        val mediaItem = lastMediaItem
        val dataSourceFactory = lastDataSourceFactory
        if (mediaItem == null || dataSourceFactory == null) {
            // Nothing loaded yet: the configs apply at the next load
            result.success(null)
            return
        }

        val position = player.currentPosition
        val wasPlaying = player.playWhenReady
        player.setMediaSource(buildMediaSourceWithSidecars(mediaItem, dataSourceFactory))
        player.prepare()
        player.seekTo(position)
        player.playWhenReady = wasPlaying
        NpLog.d(TAG, "Rebuilt media source with sidecar subtitles at ${position}ms")
        result.success(null)
    }

    /**
     * Selects/deselects the native sidecar text track. Driven by the Dart
     * controller when entering/leaving PiP or native fullscreen — contexts
     * where the Flutter subtitle overlay is not visible, so the platform's
     * SubtitleView must take over rendering.
     */
    private fun handleSetNativeSidecarActive(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val active = args?.get("active") as? Boolean ?: false
        val language = args?.get("language") as? String

        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .apply {
                if (active && language != null) {
                    setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    setPreferredTextLanguage(language)
                } else {
                    setPreferredTextLanguage(null)
                    setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                }
            }
            .build()
        NpLog.d(TAG, "Native sidecar track active=$active language=$language")
        result.success(null)
    }

    // Remembers whether the text track type was disabled before entering PiP, so
    // the prior subtitle selection (sidecar preferred-language or embedded
    // TrackSelectionOverride) is restored on exit.
    private var textDisabledBeforePip: Boolean? = null

    /**
     * Suppresses all subtitle rendering while in Android PiP and restores it on
     * exit. In PiP the Flutter overlay is gone and the native SubtitleView
     * renders captions at the system default size, which is oversized in the tiny
     * PiP window. Disabling the player's text track type hides every subtitle
     * source (embedded and sidecar) at once; the TrackSelectionOverride in
     * `overrides` survives buildUpon(), so the exact track resumes on restore.
     */
    private fun handleSetSubtitlesSuppressedForPip(call: MethodCall, result: MethodChannel.Result) {
        val suppressed = (call.arguments as? Map<*, *>)?.get("suppressed") as? Boolean ?: false
        val params = player.trackSelectionParameters
        if (suppressed) {
            // Snapshot the baseline only once so repeated suppress calls don't
            // overwrite it with the already-disabled state.
            if (textDisabledBeforePip == null) {
                textDisabledBeforePip = params.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
            }
            player.trackSelectionParameters = params.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .build()
        } else {
            val wasDisabled = textDisabledBeforePip
            textDisabledBeforePip = null
            if (wasDisabled != null) {
                player.trackSelectionParameters = params.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, wasDisabled)
                    .build()
            }
        }
        NpLog.d(TAG, "PiP subtitle suppression=$suppressed (restoreDisabled=$textDisabledBeforePip)")
        result.success(null)
    }

    /**
     * Pins or releases the HLS video quality.
     *
     * Crucially this does NOT reload a variant playlist. Each QualityLevel.url
     * is a single video-only variant; on adaptive HLS the audio lives in a
     * separate `#EXT-X-MEDIA:TYPE=AUDIO` rendition referenced only by the
     * master. Calling setMediaSource(HlsMediaSource(variantUrl)) therefore
     * dropped the audio. Instead we keep the master source loaded and constrain
     * the *video* track via trackSelectionParameters — audio is untouched and
     * the switch is instant (no buffering reload).
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
            // Lift the manual ceiling so ABR resumes. Use MAX rather than
            // clearVideoSizeConstraints() — the latter would also wipe the
            // separate viewport cap (setViewportSize) applied by
            // PlayerBackendSession, which is an independent constraint.
            player.trackSelectionParameters = player.trackSelectionParameters
                .buildUpon()
                .setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE)
                .setMaxVideoBitrate(Int.MAX_VALUE)
                .build()

            eventHandler.sendEvent("qualityChange", mapOf(
                "url" to (qualityInfo["url"] as? String ?: ""),
                "label" to (qualityInfo["label"] as? String ?: "Auto"),
                "isAuto" to true
            ))
            result.success(null)
        } else {
            val width = (qualityInfo["width"] as? Number)?.toInt()
            val height = (qualityInfo["height"] as? Number)?.toInt()
            val bitrate = (qualityInfo["bitrate"] as? Number)?.toInt()

            player.trackSelectionParameters = player.trackSelectionParameters
                .buildUpon()
                .apply {
                    if (width != null && height != null && width > 0 && height > 0) {
                        setMaxVideoSize(width, height)
                    }
                    if (bitrate != null && bitrate > 0) {
                        setMaxVideoBitrate(bitrate)
                    }
                }
                .build()

            eventHandler.sendEvent("qualityChange", mapOf(
                "url" to (qualityInfo["url"] as? String ?: ""),
                "label" to (qualityInfo["label"] as? String ?: ""),
                "isAuto" to false
            ))
            result.success(null)
        }
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
                NpLog.d(TAG, "🔄 Restored ${cachedQualities.size} qualities from cache for controller $controllerId")
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
        player.removeListener(audioFocusPlaybackListener)
        abandonAudioFocusForPlayback()
        player.stop()

        // Remove from shared manager if this is a shared player
        if (controllerId != null) {
            SharedPlayerManager.removePlayer(context, controllerId)
            NpLog.d(TAG, "Removed shared player for controller ID: $controllerId")
        }

        eventHandler.sendEvent("stopped")
        result.success(null)
    }

    /**
     * Enters fullscreen mode
     * Triggers the native fullscreen dialog
     */
    private fun handleEnterFullScreen(result: MethodChannel.Result) {
        NpLog.d(TAG, "Flutter requested enter fullscreen")
        onFullscreenRequest?.invoke(true)
        result.success(null)
    }

    /**
     * Exits fullscreen mode
     * Dismisses the native fullscreen dialog
     */
    private fun handleExitFullScreen(result: MethodChannel.Result) {
        NpLog.d(TAG, "Flutter requested exit fullscreen")
        onFullscreenRequest?.invoke(false)
        result.success(null)
    }

    /**
     * Checks if AirPlay is available (iOS only - always false on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleIsAirPlayAvailable(result: MethodChannel.Result) {
        NpLog.d(TAG, "AirPlay availability checked - not supported on Android")
        // AirPlay is not available on Android
        result.success(false)
    }

    /**
     * Shows AirPlay picker (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleShowAirPlayPicker(result: MethodChannel.Result) {
        NpLog.d(TAG, "AirPlay picker requested but not supported on Android")
        // Simply return success - AirPlay is not available on Android
        result.success(null)
    }

    /**
     * Starts AirPlay device detection (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleStartAirPlayDetection(result: MethodChannel.Result) {
        NpLog.d(TAG, "AirPlay detection start requested but not supported on Android")
        // Simply return success - AirPlay is not available on Android
        result.success(null)
    }

    /**
     * Stops AirPlay device detection (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleStopAirPlayDetection(result: MethodChannel.Result) {
        NpLog.d(TAG, "AirPlay detection stop requested but not supported on Android")
        // Simply return success - AirPlay is not available on Android
        result.success(null)
    }

    /**
     * Disconnects from AirPlay device (iOS only - no-op on Android)
     * AirPlay is an Apple technology and not available on Android
     */
    private fun handleDisconnectAirPlay(result: MethodChannel.Result) {
        NpLog.d(TAG, "AirPlay disconnect requested but not supported on Android")
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
        NpLog.d(TAG, "📡 AirPlay availability check: false (Android)")
        eventHandler.sendEvent("airPlayAvailabilityChanged", mapOf("isAvailable" to false))
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

            // A flat index across ALL text tracks of ALL groups (same scheme as
            // handleGetAvailableAudioTracks). ExoPlayer exposes a separate text
            // track group per source (e.g. a sideloaded sidecar is its own
            // group), so a per-group index would collide between groups.
            // handleSetSubtitleTrack walks the same counter.
            var flatIndex = 0

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
                            "index" to flatIndex,
                            "language" to languageCode,
                            "displayName" to displayName,
                            "isSelected" to isSelected
                        )

                        tracks.add(trackInfo)
                        NpLog.d(TAG, "📝 Found subtitle track: $displayName ($languageCode) - Selected: $isSelected")
                        flatIndex++
                    }
                }
            }

            NpLog.d(TAG, "📝 Total subtitle tracks found: ${tracks.size}")
            result.success(tracks)
        } catch (e: Exception) {
            NpLog.e(TAG, "Error getting subtitle tracks: ${e.message}", e)
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
                NpLog.d(TAG, "📝 Disabling subtitles")

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

            // Walk the same global text-track index used by
            // handleGetAvailableSubtitleTracks to find the exact (group, track),
            // then pin it with a TrackSelectionOverride. Selecting the specific
            // track group — rather than setPreferredTextLanguage — avoids
            // selecting EVERY track that shares the language, which would render
            // two overlapping subtitles (and crash) when a sidecar and an
            // embedded track share a language.
            val currentTracks = player.currentTracks
            var trackFound = false
            var selectedLanguage = "unknown"
            var selectedDisplayName = "Unknown"
            var flatIndex = 0

            loop@ for (groupIndex in 0 until currentTracks.groups.size) {
                val group = currentTracks.groups[groupIndex]
                if (group.type != C.TRACK_TYPE_TEXT) continue

                for (trackIndex in 0 until group.length) {
                    if (flatIndex == index) {
                        val format = group.getTrackFormat(trackIndex)
                        selectedLanguage = format.language ?: "unknown"
                        selectedDisplayName = format.label?.takeIf { it.isNotEmpty() }
                            ?: selectedLanguage

                        parametersBuilder = parametersBuilder
                            .setOverrideForType(
                                TrackSelectionOverride(group.mediaTrackGroup, trackIndex)
                            )

                        trackFound = true
                        break@loop
                    }

                    flatIndex++
                }
            }

            if (!trackFound) {
                result.error("INVALID_INDEX", "Invalid subtitle track index", null)
                return
            }

            player.trackSelectionParameters = parametersBuilder.build()

            NpLog.d(TAG, "📝 Selected subtitle track: $selectedDisplayName ($selectedLanguage)")

            eventHandler.sendEvent("subtitleChange", mapOf(
                "index" to index,
                "language" to selectedLanguage,
                "displayName" to selectedDisplayName,
                "isSelected" to true
            ))

            result.success(null)
        } catch (e: Exception) {
            NpLog.e(TAG, "Error setting subtitle track: ${e.message}", e)
            result.error("ERROR", "Failed to set subtitle track: ${e.message}", null)
        }
    }
}
