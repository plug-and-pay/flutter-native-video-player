package com.huddlecommunity.better_native_video_player

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A player backend reachable through the shared 'native_video_player'
 * MethodChannel routing (NativeVideoPlayerPlugin.registeredViews).
 *
 * Implemented by [VideoPlayerView] (platform views: PlayerView or the
 * lightweight SurfaceView) and by the texture backend, which has no Android
 * View at all.
 */
interface VideoPlayerBackend {
    val backendViewId: Long
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result)
    fun dispose()
}
