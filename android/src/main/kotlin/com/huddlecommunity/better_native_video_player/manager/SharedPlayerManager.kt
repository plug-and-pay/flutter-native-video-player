package com.huddlecommunity.better_native_video_player.manager

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.media3.exoplayer.ExoPlayer
import com.huddlecommunity.better_native_video_player.VideoPlayerMediaSessionService
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerEventHandler

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

    // Store PiP settings for each controller
    // This ensures PiP settings persist across all views using the same controller
    private val pipSettings = mutableMapOf<Int, PipSettings>()

    // Store available qualities for each controller
    // This ensures qualities persist across view recreations
    private val qualitiesCache = mutableMapOf<Int, List<Map<String, Any>>>()

    // Store fullscreen state before PiP for each controller
    // This ensures we can restore the correct fullscreen state after PiP, even if the view is recreated
    private val fullscreenBeforePip = mutableMapOf<Int, Boolean>()

    data class PipSettings(
        val allowsPictureInPicture: Boolean,
        val canStartPictureInPictureAutomatically: Boolean,
        val showNativeControls: Boolean
    )

    /**
     * Gets or creates a player for the given controller ID
     * Returns a Pair<ExoPlayer, Boolean> where the Boolean indicates if the player already existed (true) or was newly created (false)
     */
    fun getOrCreatePlayer(context: Context, controllerId: Int): Pair<ExoPlayer, Boolean> {
        val alreadyExisted = players.containsKey(controllerId)
        val player = players.getOrPut(controllerId) {
            ExoPlayer.Builder(context).build()
        }
        return Pair(player, alreadyExisted)
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
        Log.d(TAG, "Registered view $viewId for controller $controllerId (total views: ${views.size})")
    }

    /**
     * Unregisters a platform view and notifies other views to reconnect
     */
    fun unregisterView(controllerId: Int, viewId: Long) {
        val views = activeViews[controllerId]
        if (views != null) {
            views.remove(viewId)
            Log.d(TAG, "Unregistered view $viewId for controller $controllerId (remaining views: ${views.size})")

            // Notify all remaining views to reconnect their surfaces
            views.values.forEach { callback ->
                try {
                    callback()
                } catch (e: Exception) {
                    Log.e(TAG, "Error calling reconnect callback: ${e.message}", e)
                }
            }

            // Clean up empty maps
            if (views.isEmpty()) {
                activeViews.remove(controllerId)
            }
        }
    }

    /**
     * Sets PiP settings for a controller
     * This ensures the settings persist across all views using the same controller
     */
    fun setPipSettings(
        controllerId: Int,
        allowsPictureInPicture: Boolean,
        canStartPictureInPictureAutomatically: Boolean,
        showNativeControls: Boolean
    ) {
        pipSettings[controllerId] = PipSettings(
            allowsPictureInPicture = allowsPictureInPicture,
            canStartPictureInPictureAutomatically = canStartPictureInPictureAutomatically,
            showNativeControls = showNativeControls
        )
        Log.d(TAG, "Set PiP settings for controller $controllerId - allows: $allowsPictureInPicture, autoStart: $canStartPictureInPictureAutomatically")
    }

    /**
     * Gets PiP settings for a controller
     * Returns null if no settings have been stored for this controller
     */
    fun getPipSettings(controllerId: Int): PipSettings? {
        return pipSettings[controllerId]
    }

    /**
     * Sets available qualities for a controller
     * This ensures qualities persist across view recreations
     */
    fun setQualities(controllerId: Int, qualities: List<Map<String, Any>>) {
        qualitiesCache[controllerId] = qualities
        Log.d(TAG, "Stored ${qualities.size} qualities for controller $controllerId")
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

        Log.d(TAG, "Stopped all views for controller $controllerId")
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

        // Remove PiP settings
        pipSettings.remove(controllerId)

        // Remove qualities cache
        qualitiesCache.remove(controllerId)

        // Remove fullscreen state
        fullscreenBeforePip.remove(controllerId)

        // Clear active views for this controller
        activeViews.remove(controllerId)

        Log.d(TAG, "Removed player for controller $controllerId")

        // If no more players, stop the service
        if (players.isEmpty()) {
            stopMediaSessionService(context)
        }
    }

    /**
     * Sets the fullscreen state before entering PiP for a controller
     * This ensures the correct fullscreen state can be restored after PiP, even if view is recreated
     */
    fun setFullscreenBeforePip(controllerId: Int, wasFullscreen: Boolean) {
        fullscreenBeforePip[controllerId] = wasFullscreen
        Log.d(TAG, "Stored fullscreen state before PiP for controller $controllerId: $wasFullscreen")
    }

    /**
     * Gets the fullscreen state before entering PiP for a controller
     * Returns null if no state has been stored for this controller
     */
    fun getFullscreenBeforePip(controllerId: Int): Boolean? {
        return fullscreenBeforePip[controllerId]
    }

    /**
     * Clears the fullscreen state after PiP is complete
     */
    fun clearFullscreenBeforePip(controllerId: Int) {
        fullscreenBeforePip.remove(controllerId)
        Log.d(TAG, "Cleared fullscreen state for controller $controllerId")
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

        // Clear PiP settings
        pipSettings.clear()

        // Clear qualities cache
        qualitiesCache.clear()

        // Clear fullscreen state
        fullscreenBeforePip.clear()

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
