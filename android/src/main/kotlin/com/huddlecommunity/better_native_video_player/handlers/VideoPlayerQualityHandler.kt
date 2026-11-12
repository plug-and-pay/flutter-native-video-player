package com.huddlecommunity.better_native_video_player.handlers

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.hls.HlsManifest
import com.huddlecommunity.better_native_video_player.NpLog

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URL
import kotlin.math.roundToInt

/**
 * Handles HLS quality parsing and management
 */
object VideoPlayerQualityHandler {
    private const val TAG = "VideoPlayerQuality"

    data class QualityLevel(
        val url: String,
        val label: String,
        val bitrate: Int,
        val width: Int,
        val height: Int
    )

    /**
     * Fetches and parses HLS qualities from an M3U8 playlist URL
     * @param url The M3U8 playlist URL
     * @return List of quality maps with metadata
     */
    /**
     * The quality list from the HLS manifest the player already downloaded:
     * no extra request, and it works for streams that need headers. Same shape
     * as [fetchHLSQualities] ("Auto" first, then variants by height). Returns
     * null when [manifest] is not an HLS manifest yet.
     */
    @OptIn(UnstableApi::class)
    fun qualitiesFromManifest(manifest: Any?): List<Map<String, Any>>? {
        val hls = manifest as? HlsManifest ?: return null
        val qualities = hls.multivariantPlaylist.variants.mapNotNull { variant ->
            val format = variant.format
            if (format.width <= 0 || format.height <= 0) return@mapNotNull null
            val bitrate = if (format.bitrate > 0) format.bitrate else format.peakBitrate
            QualityLevel(
                url = variant.url.toString(),
                label = "${format.width}x${format.height}",
                bitrate = if (bitrate > 0) bitrate else 0,
                width = format.width,
                height = format.height
            )
        }.sortedBy { it.height }
        val result = mutableListOf<Map<String, Any>>()
        result.add(mapOf("label" to "Auto", "url" to (qualities.firstOrNull()?.url ?: ""), "isAuto" to true))
        result.addAll(qualities.map { quality ->
            mapOf(
                "label" to quality.label,
                "url" to quality.url,
                "bitrate" to quality.bitrate,
                "width" to quality.width,
                "height" to quality.height,
                "isAuto" to false
            )
        })
        NpLog.d(TAG, "Read ${qualities.size} quality variants from the player's HLS manifest")
        return result
    }

    suspend fun fetchHLSQualities(url: String, headers: Map<String, String>? = null): List<Map<String, Any>> = withContext(Dispatchers.IO) {
        try {
            val connection = URL(url).openConnection()
            headers?.forEach { (key, value) -> connection.setRequestProperty(key, value) }
            val playlist = connection.getInputStream().bufferedReader().use { it.readText() }

            val qualities = mutableListOf<QualityLevel>()
            val lines = playlist.lines()
            var lastBitrate: Int? = null
            var lastResolution: Pair<Int, Int>? = null

            for (line in lines) {
                when {
                    line.contains("#EXT-X-STREAM-INF") -> {
                        // Extract resolution
                        val resolutionMatch = Regex("RESOLUTION=(\\d+)x(\\d+)").find(line)
                        if (resolutionMatch != null) {
                            val width = resolutionMatch.groupValues[1].toInt()
                            val height = resolutionMatch.groupValues[2].toInt()
                            lastResolution = width to height
                        }

                        // Extract bitrate
                        val bitrateMatch = Regex("BANDWIDTH=(\\d+)").find(line)
                        lastBitrate = bitrateMatch?.groupValues?.get(1)?.toInt()
                    }
                    line.endsWith(".m3u8") && lastResolution != null -> {
                        // Resolve relative URLs against the base URL
                        val qualityUrl = when {
                            line.startsWith("http://") || line.startsWith("https://") -> line
                            line.startsWith("/") -> {
                                // Absolute path - use the host from the base URL
                                val baseUri = URL(url)
                                "${baseUri.protocol}://${baseUri.host}$line"
                            }
                            else -> {
                                // Relative path - resolve against the base URL directory
                                val baseUrl = URL(url)
                                val basePath = baseUrl.path.substringBeforeLast("/")
                                "${baseUrl.protocol}://${baseUrl.host}$basePath/$line"
                            }
                        }

                        qualities.add(
                            QualityLevel(
                                url = qualityUrl,
                                label = "${lastResolution.first}x${lastResolution.second}",
                                bitrate = lastBitrate ?: 0,
                                width = lastResolution.first,
                                height = lastResolution.second
                            )
                        )

                        lastResolution = null
                        lastBitrate = null
                    }
                }
            }

            // Sort qualities by resolution height (ascending)
            val sortedQualities = qualities.sortedBy { it.height }

            // Convert to map format for Flutter
            val result = mutableListOf<Map<String, Any>>()

            // Add auto quality option
            result.add(mapOf(
                "label" to "Auto",
                "url" to (sortedQualities.firstOrNull()?.url ?: ""),
                "isAuto" to true
            ))

            // Add all available qualities
            result.addAll(sortedQualities.map { quality ->
                mapOf(
                    "label" to quality.label,
                    "url" to quality.url,
                    "bitrate" to quality.bitrate,
                    "width" to quality.width,
                    "height" to quality.height,
                    "isAuto" to false
                )
            })

            NpLog.d(TAG, "Parsed ${qualities.size} quality variants from HLS playlist")
            result
        } catch (e: Exception) {
            NpLog.e(TAG, "Error fetching HLS qualities: ${e.message}", e)
            emptyList()
        }
    }
}