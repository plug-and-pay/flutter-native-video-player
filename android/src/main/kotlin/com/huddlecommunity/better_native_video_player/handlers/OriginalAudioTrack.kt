package com.huddlecommunity.better_native_video_player.handlers

/**
 * Finds the original-language audio track of a stream that also has dubbed
 * ones (Vimeo's AI dubs mark each dub `CHARACTERISTICS="public.translation.dubbed"`).
 * The same rule runs on iOS (OriginalAudioTrack.swift).
 *
 * Media3's HLS parser keeps only four CHARACTERISTICS values as role flags, and
 * the dub marking isn't one of them, so the characteristics are read from the
 * master playlist's `#EXT-X-MEDIA` tags, which Media3 keeps in
 * `HlsMultivariantPlaylist.tags`.
 */
object OriginalAudioTrack {
    const val DUBBED = "public.translation.dubbed"
    const val ORIGINAL = "public.original-content"

    data class Track(val isDubbed: Boolean, val isMarkedOriginal: Boolean, val isDefault: Boolean)

    /**
     * Only a stream that marks at least one track dubbed has an original: a
     * track that isn't dubbed, preferring one marked original, then the
     * DEFAULT one, then the first. Without dub markings there is none, so a
     * plain multi-language stream gets no "original" label.
     */
    fun index(tracks: List<Track>): Int? {
        if (tracks.none { it.isDubbed }) return null

        val candidates = tracks.indices.filter { !tracks[it].isDubbed }
        return candidates.firstOrNull { tracks[it].isMarkedOriginal }
            ?: candidates.firstOrNull { tracks[it].isDefault }
            ?: candidates.firstOrNull()
    }

    private val nameAttribute = Regex("""NAME="([^"]*)"""")
    private val characteristicsAttribute = Regex("""CHARACTERISTICS="([^"]*)"""")

    /**
     * The CHARACTERISTICS of each audio rendition in a master playlist's tags,
     * by rendition NAME (which Media3 uses as the track's label; HLS requires
     * it to be unique within its group).
     */
    fun audioCharacteristicsByName(tags: List<String>): Map<String, Set<String>> =
        tags.asSequence()
            .filter { it.startsWith("#EXT-X-MEDIA:") && it.contains("TYPE=AUDIO") }
            .mapNotNull { tag ->
                val name = nameAttribute.find(tag)?.groupValues?.get(1) ?: return@mapNotNull null
                val characteristics = characteristicsAttribute.find(tag)?.groupValues?.get(1)
                    ?.split(',')
                    ?.map { it.trim() }
                    ?.filter { it.isNotEmpty() }
                    ?.toSet()
                    ?: emptySet()
                name to characteristics
            }
            .toMap()
}
