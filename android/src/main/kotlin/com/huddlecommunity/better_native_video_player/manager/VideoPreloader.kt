package com.huddlecommunity.better_native_video_player.manager

import android.content.Context
import com.huddlecommunity.better_native_video_player.NpLog

/**
 * Backs NativeVideoPlayerPreloader on Android: keeps the first segments of
 * the videos around the current reel in the disk cache, which a later load()
 * of the same URL reads. Holds no players and no memory beyond the URL set;
 * the cache's own LRU bounds the bytes.
 *
 * Main thread only (called from the plugin's method channel).
 */
object VideoPreloader {
    private const val TAG = "VideoPreloader"

    // The URLs the current window wants. Read from the precache thread.
    @Volatile
    private var wanted: Set<String> = emptySet()

    // URLs already warmed or being warmed, so moving the window doesn't
    // queue them again.
    private val started = mutableSetOf<String>()

    fun setWindow(
        context: Context,
        items: List<Pair<String, Map<String, String>?>>,
        precacheBytes: Long,
        cacheMaxBytes: Long
    ) {
        wanted = items.map { it.first }.toSet()
        // Forget what left the window: if it comes back, it is warmed again
        // (a no-op network-wise while the bytes are still cached).
        started.retainAll(wanted)
        for ((url, headers) in items) {
            if (!started.add(url)) continue
            VideoCacheManager.precache(
                context,
                url,
                headers,
                precacheBytes,
                cacheMaxBytes,
                shouldRun = { url in wanted }
            ) { ok, message ->
                if (!ok) {
                    started.remove(url)
                    if (message != "skipped") NpLog.w(TAG, "Preload failed for $url: $message")
                }
            }
        }
        NpLog.d(TAG, "Preload window: ${items.size} item(s)")
    }

    fun clear() {
        wanted = emptySet()
        started.clear()
    }
}
