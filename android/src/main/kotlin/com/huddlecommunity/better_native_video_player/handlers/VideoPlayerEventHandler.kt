package com.huddlecommunity.better_native_video_player.handlers

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel

/**
 * Handles sending events from native Android to Flutter via EventChannel
 * Equivalent to iOS VideoPlayerEventHandler
 */
class VideoPlayerEventHandler(private val isSharedPlayer: Boolean = false) : EventChannel.StreamHandler {
    companion object {
        private const val TAG = "VideoPlayerEventHandler"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var initialStateCallback: (() -> Unit)? = null
    private var hasSentInitialState: Boolean = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Log.d(TAG, "onListen called - isSharedPlayer: $isSharedPlayer, hasCallback: ${initialStateCallback != null}")
        eventSink = events
        // Only send isInitialized event for new players, not for shared players
        // Shared players will send their current playback state instead
        if (!isSharedPlayer) {
            Log.d(TAG, "Sending isInitialized event for new player")
            sendEvent("isInitialized")
            hasSentInitialState = true
        } else {
            // For shared players, send the current state once the listener is attached
            // Send synchronously to ensure it's the first event received
            Log.d(TAG, "Invoking initial state callback for shared player")
            initialStateCallback?.invoke()
            hasSentInitialState = true
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    /**
     * Sets a callback to send the initial state for shared players
     * This callback is invoked when onListen is called
     */
    fun setInitialStateCallback(callback: () -> Unit) {
        initialStateCallback = callback
    }

    /**
     * Sends an event to Flutter
     * @param name Event name (e.g., "play", "pause", "loading")
     * @param data Optional additional data to send with the event
     * @param synchronous If true, send immediately without posting to handler (use for initial state)
     */
    fun sendEvent(name: String, data: Map<String, Any>? = null, synchronous: Boolean = false) {
        val event = mutableMapOf<String, Any>("event" to name)
        data?.let { event.putAll(it) }
        if (synchronous && eventSink != null) {
            // Send immediately for initial state to ensure it's received first
            Log.d(TAG, "Sending event synchronously: $name (eventSink is not null)")
            eventSink?.success(event)
        } else if (eventSink != null) {
            Log.d(TAG, "Sending event asynchronously: $name (eventSink is not null)")
            Handler(Looper.getMainLooper()).post {
                eventSink?.success(event)
            }
        } else {
            Log.w(TAG, "Cannot send event: $name - eventSink is null (EventChannel not ready yet)")
        }
    }
}
