package com.huddlecommunity.better_native_video_player.handlers

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Handles sending events from native Android to Flutter via EventChannel
 * Equivalent to iOS VideoPlayerEventHandler
 */
class VideoPlayerEventHandler(private val isSharedPlayer: Boolean = false) : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private var initialStateCallback: (() -> Unit)? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Only send isInitialized event for new players, not for shared players
        // Shared players will send their current playback state instead
        if (!isSharedPlayer) {
            sendEvent("isInitialized")
        } else {
            // For shared players, send the current state once the listener is attached
            initialStateCallback?.invoke()
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
     */
    fun sendEvent(name: String, data: Map<String, Any>? = null) {
        val event = mutableMapOf<String, Any>("event" to name)
        data?.let { event.putAll(it) }
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(event)
        }
    }
}
