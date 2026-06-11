package com.huddlecommunity.better_native_video_player.manager

import com.huddlecommunity.better_native_video_player.NpLog

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.PriorityTaskManager
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import com.huddlecommunity.better_native_video_player.VideoPlayerMediaSessionService
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerEventHandler
import io.flutter.plugin.common.EventChannel

/**
 * Manages shared ExoPlayer instances and NotificationHandlers across multiple platform views
 * Keeps players and notification handlers alive even when platform views are disposed
 * Note: Each platform view gets its own PlayerView, but they share the same ExoPlayer and NotificationHandler
 */
object SharedPlayerManager {
    private const val TAG = "SharedPlayerManager"

    private val players = mutableMapOf<Int, ExoPlayer>()
    private val notificationHandlers = mutableMapOf<Int, VideoPlayerNotificationHandler>()

    // Track active platform views for each controller
    // Map<ControllerId, Map<ViewId, SurfaceReconnectCallback>>
    private val activeViews = mutableMapOf<Int, MutableMap<Long, () -> Unit>>()

    // Store available qualities for each controller
    // This ensures qualities persist across view recreations
    private val qualitiesCache = mutableMapOf<Int, List<Map<String, Any>>>()

    // Controller-level event sinks (native_video_player_controller_<id>).
    // These persist while all platform views are disposed so controller-scoped
    // events keep flowing after releaseResources(); mirrors the iOS
    // SharedPlayerManager.controllerEventSinks design.
    private val controllerEventSinks = mutableMapOf<Int, EventChannel.EventSink>()

    private val mainHandler = Handler(Looper.getMainLooper())

    // One PriorityTaskManager shared by every player created with
    // prioritizeActivePlayback: playing players load at C.PRIORITY_PLAYBACK
    // while paused ones are demoted, so a feed's background players stop
    // competing for bandwidth/IO with the videos actually being watched.
    // Priorities only coordinate between players sharing this instance.
    private val sharedPriorityTaskManager = PriorityTaskManager()

    /**
     * Gets or creates a player for the given controller ID
     * Returns a Pair<ExoPlayer, Boolean> where the Boolean indicates if the player already existed (true) or was newly created (false)
     *
     * [bufferConfig] (optional, from the Dart NativeVideoPlayerConfig) tunes
     * DefaultLoadControl and only applies when the player is first created
     * for this controller ID; null keeps ExoPlayer's defaults.
     * [prioritizeActivePlayback] attaches the shared PriorityTaskManager.
     */
    fun getOrCreatePlayer(
        context: Context,
        controllerId: Int,
        bufferConfig: Map<*, *>? = null,
        prioritizeActivePlayback: Boolean = false
    ): Pair<ExoPlayer, Boolean> {
        val alreadyExisted = players.containsKey(controllerId)
        val player = players.getOrPut(controllerId) {
            buildPlayer(context, bufferConfig, prioritizeActivePlayback)
        }
        return Pair(player, alreadyExisted)
    }

    /**
     * Builds an ExoPlayer, optionally with a tuned DefaultLoadControl and the
     * shared PriorityTaskManager.
     */
    fun buildPlayer(
        context: Context,
        bufferConfig: Map<*, *>? = null,
        prioritizeActivePlayback: Boolean = false
    ): ExoPlayer {
        val builder = ExoPlayer.Builder(context)
            .setAudioAttributes(AudioAttributes.DEFAULT, false)
        if (prioritizeActivePlayback) {
            builder.setPriorityTaskManager(sharedPriorityTaskManager)
            // Start demoted: loading-while-paused yields to playing players.
            // PriorityTaskManager only blocks when a HIGHER-priority task is
            // active, so a lone player is never slowed down. The observer
            // promotes/demotes on play/pause transitions.
            builder.setPriority(C.PRIORITY_PLAYBACK_PRELOAD)
        }
        if (bufferConfig != null) {
            val minBufferMs = (bufferConfig["minBufferMs"] as? Number)?.toInt() ?: 50000
            val maxBufferMs = (bufferConfig["maxBufferMs"] as? Number)?.toInt() ?: 50000
            val bufferForPlaybackMs =
                (bufferConfig["bufferForPlaybackMs"] as? Number)?.toInt() ?: 2500
            val bufferForPlaybackAfterRebufferMs =
                (bufferConfig["bufferForPlaybackAfterRebufferMs"] as? Number)?.toInt() ?: 5000
            builder.setLoadControl(
                DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        minBufferMs,
                        maxBufferMs,
                        bufferForPlaybackMs,
                        bufferForPlaybackAfterRebufferMs
                    )
                    .build()
            )
            NpLog.d(
                TAG,
                "Built player with buffer config: min=$minBufferMs max=$maxBufferMs " +
                    "forPlayback=$bufferForPlaybackMs afterRebuffer=$bufferForPlaybackAfterRebufferMs"
            )
        }
        return builder.build()
    }

    /**
     * Gets or creates a notification handler for the given controller ID
     */
    fun getOrCreateNotificationHandler(
        context: Context,
        controllerId: Int,
        player: ExoPlayer,
        eventHandler: VideoPlayerEventHandler
    ): VideoPlayerNotificationHandler {
        return notificationHandlers.getOrPut(controllerId) {
            VideoPlayerNotificationHandler(context, player, eventHandler)
        }
    }

    /**
     * Registers a platform view for a controller
     * The callback will be called when another view using the same controller is disposed
     */
    fun registerView(controllerId: Int, viewId: Long, reconnectCallback: () -> Unit) {
        val views = activeViews.getOrPut(controllerId) { mutableMapOf() }
        views[viewId] = reconnectCallback
        NpLog.d(TAG, "Registered view $viewId for controller $controllerId (total views: ${views.size})")
    }

    /**
     * Unregisters a platform view and notifies other views to reconnect
     */
    fun unregisterView(controllerId: Int, viewId: Long) {
        val views = activeViews[controllerId]
        if (views != null) {
            views.remove(viewId)
            NpLog.d(TAG, "Unregistered view $viewId for controller $controllerId (remaining views: ${views.size})")

            // Notify all remaining views to reconnect their surfaces
            views.values.forEach { callback ->
                try {
                    callback()
                } catch (e: Exception) {
                    NpLog.e(TAG, "Error calling reconnect callback: ${e.message}", e)
                }
            }

            // Clean up empty maps
            if (views.isEmpty()) {
                activeViews.remove(controllerId)
            }
        }
    }

    /**
     * Registers a controller-level event sink for persistent events.
     * Replaces any previous sink for the same controller (e.g. after a hot
     * restart, where the new Dart isolate re-listens on the same channel).
     */
    fun registerControllerEventSink(controllerId: Int, sink: EventChannel.EventSink) {
        controllerEventSinks[controllerId] = sink
        NpLog.d(TAG, "Registered controller event sink for controller $controllerId")
    }

    /**
     * Unregisters a controller-level event sink
     */
    fun unregisterControllerEventSink(controllerId: Int) {
        controllerEventSinks.remove(controllerId)
        NpLog.d(TAG, "Unregistered controller event sink for controller $controllerId")
    }

    /**
     * Sends an event through the controller-level event channel.
     * Safe to call without a registered sink (normal during initialization or
     * after disposal); delivery happens on the main looper.
     */
    fun sendControllerEvent(controllerId: Int, eventName: String, data: Map<String, Any?> = emptyMap()) {
        val sink = controllerEventSinks[controllerId] ?: return
        val event = HashMap<String, Any?>(data)
        event["event"] = eventName
        mainHandler.post { sink.success(event) }
    }

    /**
     * Sets available qualities for a controller
     * This ensures qualities persist across view recreations
     */
    fun setQualities(controllerId: Int, qualities: List<Map<String, Any>>) {
        qualitiesCache[controllerId] = qualities
        NpLog.d(TAG, "Stored ${qualities.size} qualities for controller $controllerId")
    }

    /**
     * Gets available qualities for a controller
     * Returns null if no qualities have been stored for this controller
     */
    fun getQualities(controllerId: Int): List<Map<String, Any>>? {
        return qualitiesCache[controllerId]
    }

    /**
     * Stops all views for a given controller
     */
    fun stopAllViewsForController(controllerId: Int) {
        val player = players[controllerId] ?: return

        // Stop playback
        player.stop()

        NpLog.d(TAG, "Stopped all views for controller $controllerId")
    }

    /**
     * Removes a player (called when explicitly disposed)
     */
    fun removePlayer(context: Context, controllerId: Int) {
        // First stop all views using this player
        stopAllViewsForController(controllerId)

        // Release notification handler
        notificationHandlers[controllerId]?.release()
        notificationHandlers.remove(controllerId)

        // Release player
        players[controllerId]?.release()
        players.remove(controllerId)

        // Remove qualities cache
        qualitiesCache.remove(controllerId)

        // Clear active views for this controller
        activeViews.remove(controllerId)

        NpLog.d(TAG, "Removed player for controller $controllerId")

        // If no more players, stop the service
        if (players.isEmpty()) {
            stopMediaSessionService(context)
        }
    }

    /**
     * Clears all players (e.g., on logout)
     */
    fun clearAll(context: Context) {
        // Release all notification handlers
        notificationHandlers.values.forEach { it.release() }
        notificationHandlers.clear()

        // Release all players
        players.values.forEach { it.release() }
        players.clear()

        // Clear qualities cache
        qualitiesCache.clear()

        // Drop controller-level event sinks (their channels are torn down by
        // the plugin on engine detach)
        controllerEventSinks.clear()

        // Stop the service when clearing all players
        stopMediaSessionService(context)
    }

    /**
     * Stops the MediaSessionService
     */
    private fun stopMediaSessionService(context: Context) {
        VideoPlayerMediaSessionService.setMediaSession(null)
        val serviceIntent = Intent(context, VideoPlayerMediaSessionService::class.java)
        context.stopService(serviceIntent)
    }
}
