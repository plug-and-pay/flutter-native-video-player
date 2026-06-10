package com.huddlecommunity.better_native_video_player.handlers

import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager
import io.flutter.plugin.common.EventChannel

/**
 * Handler for controller-level event channels (`native_video_player_controller_<id>`).
 *
 * Unlike per-view event channels, this channel persists independently of platform
 * views: it stays registered while all views are disposed (releaseResources) so
 * controller-scoped events (PiP, AirPlay parity with iOS) can still reach Dart.
 * It is only torn down when the Dart controller is disposed.
 */
class ControllerEventChannelHandler(
    private val controllerId: Int
) : EventChannel.StreamHandler {

    /** Registers the event sink with [SharedPlayerManager] for persistent delivery. */
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events != null) {
            SharedPlayerManager.registerControllerEventSink(controllerId, events)
        }
    }

    /** Unregisters the event sink from [SharedPlayerManager]. */
    override fun onCancel(arguments: Any?) {
        SharedPlayerManager.unregisterControllerEventSink(controllerId)
    }
}
