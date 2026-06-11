package com.huddlecommunity.better_native_video_player.manager

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.hls.offline.HlsDownloader
import androidx.media3.exoplayer.offline.Downloader
import com.huddlecommunity.better_native_video_player.NpLog
import com.huddlecommunity.better_native_video_player.handlers.VideoPlayerMethodHandler
import java.io.File
import java.util.concurrent.Executors

/**
 * Opt-in disk cache for remote media (NativeVideoPlayerConfig.androidEnableDiskCache).
 *
 * One process-lifetime [SimpleCache]: SimpleCache throws if two instances
 * open the same directory, and the Android process (with this object) outlives
 * Flutter hot restarts, so the instance is created once and never released.
 * All failures degrade to the uncached upstream factory — caching must never
 * break playback.
 */
@UnstableApi
object VideoCacheManager {
    private const val TAG = "VideoCacheManager"

    /** Subdirectory of the app cache dir (asset extraction uses the root). */
    private const val CACHE_DIR_NAME = "bnvp_media_cache"

    const val DEFAULT_MAX_BYTES = 100L * 1024 * 1024
    const val DEFAULT_PRECACHE_BYTES = 2L * 1024 * 1024

    @Volatile
    private var cache: SimpleCache? = null
    private var creationFailed = false

    // Serializes precache work; HlsDownloader requires an Executor anyway.
    private val precacheExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "bnvp-precache")
    }
    private val activeDownloads = mutableSetOf<Any>() // Downloader or CacheWriter
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Returns the shared cache, creating it on first use. The first caller's
     * [maxBytes] wins (same applies-at-first-creation semantics as
     * androidBufferConfig); later different values are ignored.
     */
    @Synchronized
    fun getOrCreate(context: Context, maxBytes: Long): SimpleCache? {
        cache?.let { return it }
        if (creationFailed) return null
        return try {
            val created = SimpleCache(
                File(context.applicationContext.cacheDir, CACHE_DIR_NAME),
                LeastRecentlyUsedCacheEvictor(maxBytes),
                StandaloneDatabaseProvider(context.applicationContext)
            )
            cache = created
            NpLog.d(TAG, "Disk cache created (max ${maxBytes / (1024 * 1024)}MB)")
            created
        } catch (e: Exception) {
            NpLog.e(TAG, "Disk cache creation failed - playing uncached: ${e.message}", e)
            creationFailed = true
            null
        }
    }

    /**
     * Wraps [upstream] with the shared cache, or returns it unchanged when
     * the cache is unavailable. The per-load upstream keeps its headers, so
     * cache misses fetch exactly what an uncached load would.
     */
    fun buildCacheFactory(
        context: Context,
        upstream: DataSource.Factory,
        maxBytes: Long
    ): DataSource.Factory {
        val cache = getOrCreate(context, maxBytes) ?: return upstream
        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstream)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    /**
     * Warms the cache for [url] so a later load starts without network
     * round-trips: progressive sources cache the first [precacheBytes];
     * HLS caches the multivariant + media playlists and leading segments
     * until the byte budget is reached (VOD-oriented — a live playlist is
     * simply bounded by the budget).
     *
     * Runs on a single background thread; [callback] is posted to the main
     * looper with success/failure. Cancellation at the byte cap is reported
     * as success.
     */
    fun precache(
        context: Context,
        url: String,
        headers: Map<String, String>?,
        precacheBytes: Long,
        cacheMaxBytes: Long,
        callback: (Boolean, String?) -> Unit
    ) {
        val appContext = context.applicationContext
        precacheExecutor.execute {
            val result = runCatching { doPrecache(appContext, url, headers, precacheBytes, cacheMaxBytes) }
            Thread.interrupted() // clear a cancel's interrupt flag; the thread is reused
            val ok = result.isSuccess || isBudgetCancellation(result.exceptionOrNull())
            val message = if (ok) null else result.exceptionOrNull().toString()
            if (!ok) {
                NpLog.w(TAG, "Precache failed for $url: $message")
            } else {
                NpLog.d(TAG, "Precached $url (budget ${precacheBytes / 1024}KB)")
            }
            mainHandler.post { callback(ok, message) }
        }
    }

    /**
     * Cancelling a download at the byte budget surfaces differently per
     * path (CacheWriter: InterruptedException/InterruptedIOException;
     * SegmentDownloader: CancellationException) — all of them mean "the
     * warm-start data is in the cache", i.e. success.
     */
    private fun isBudgetCancellation(error: Throwable?): Boolean {
        var cause = error
        while (cause != null) {
            if (cause is InterruptedException ||
                cause is java.io.InterruptedIOException ||
                cause is java.util.concurrent.CancellationException
            ) {
                return true
            }
            cause = cause.cause
        }
        return false
    }

    private fun doPrecache(
        context: Context,
        url: String,
        headers: Map<String, String>?,
        precacheBytes: Long,
        cacheMaxBytes: Long
    ) {
        if (getOrCreate(context, cacheMaxBytes) == null) {
            throw IllegalStateException("disk cache unavailable")
        }

        val upstream = DefaultHttpDataSource.Factory().apply {
            headers?.let { setDefaultRequestProperties(it) }
        }
        // No PriorityTaskManager here: proceedOrThrow aborts (rather than
        // waits) for non-highest priorities, and a manual CacheWriter has no
        // retry loop around it — the byte budget keeps contention with
        // active playback negligible anyway.
        val factory = CacheDataSource.Factory()
            .setCache(cache!!)
            .setUpstreamDataSourceFactory(upstream)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

        if (VideoPlayerMethodHandler.isHlsUrl(url)) {
            // Runnable::run executes segment fetches inline on this precache
            // thread (sequential); handing it precacheExecutor would deadlock
            // its single thread, which download() below is already occupying.
            val downloader = HlsDownloader(MediaItem.fromUri(url), factory, Runnable::run)
            synchronized(activeDownloads) { activeDownloads.add(downloader) }
            try {
                // Cancelling at the budget surfaces as a cancellation
                // exception, classified as success by the caller.
                downloader.download { _, bytesDownloaded, _ ->
                    if (bytesDownloaded >= precacheBytes) {
                        downloader.cancel()
                    }
                }
            } finally {
                synchronized(activeDownloads) { activeDownloads.remove(downloader) }
            }
        } else {
            val dataSpec = DataSpec.Builder()
                .setUri(Uri.parse(url))
                .setPosition(0)
                .setLength(precacheBytes)
                .build()
            val writer = CacheWriter(factory.createDataSourceForDownloading(), dataSpec, null, null)
            synchronized(activeDownloads) { activeDownloads.add(writer) }
            try {
                writer.cache()
            } finally {
                synchronized(activeDownloads) { activeDownloads.remove(writer) }
            }
        }
    }

    /** Cancels in-flight precaches (engine detach). The cache stays open. */
    fun cancelAllPrecache() {
        synchronized(activeDownloads) {
            for (download in activeDownloads) {
                when (download) {
                    is Downloader -> download.cancel()
                    is CacheWriter -> download.cancel()
                }
            }
            activeDownloads.clear()
        }
    }
}
