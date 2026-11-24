package com.huddlecommunity.better_native_video_player.handlers

import java.util.Locale

/**
 * Names audio and subtitle tracks the way iOS does
 * (`AVMediaSelectionOption.displayName`): by their language, in the device
 * language ("Duits" on a Dutch phone), not by the HLS `NAME` attribute, which
 * packagers fill with ids like `stream_5` or with their own wording.
 *
 * The `NAME` only comes in when two tracks of the same kind share a language,
 * so they stay distinguishable: "English (stream_5)" next to
 * "English (stream_6)", or just "English AD" when the name already says which
 * language it is. A sidecar subtitle keeps the label the app passed.
 */
object TrackDisplayNames {
    /** The id prefix sidecar subtitle configurations carry (see parseSidecarSubtitleConfigs). */
    const val SIDECAR_ID_PREFIX = "nvp-sidecar-"

    data class Track(val language: String?, val label: String?, val isSidecar: Boolean = false)

    /** One display name per track, in the same order. */
    fun displayNames(tracks: List<Track>, displayLocale: Locale = Locale.getDefault()): List<String> {
        val languageNames = tracks.map { languageName(it.language, displayLocale) }
        val sharedLanguages = tracks.indices
            .filter { !tracks[it].isSidecar && languageNames[it] != null }
            .groupBy { languageNames[it] }
            .filterValues { it.size > 1 }
            .keys

        return tracks.mapIndexed { index, track ->
            val label = track.label?.trim()?.takeIf { it.isNotEmpty() }
            val languageName = languageNames[index]
            when {
                track.isSidecar -> label ?: languageName ?: track.language ?: "Unknown"
                languageName == null -> label ?: track.language ?: "Unknown"
                languageName !in sharedLanguages || label == null -> languageName
                label.contains(languageName, ignoreCase = true) -> label
                else -> "$languageName ($label)"
            }
        }
    }

    /**
     * The language of a BCP 47 tag in [displayLocale], with its region or
     * script when the tag has one ("Portuguese (Brazil)"), capitalised. Null
     * for a missing or undetermined language.
     */
    fun languageName(language: String?, displayLocale: Locale = Locale.getDefault()): String? {
        if (language.isNullOrBlank()) return null
        val locale = Locale.forLanguageTag(language.trim())
        if (locale.language.isEmpty() || locale.language == "und") return null

        val name = locale.getDisplayName(displayLocale)
        if (name.isEmpty() || name.equals(locale.language, ignoreCase = true)) return null

        return name.replaceFirstChar { if (it.isLowerCase()) it.titlecase(displayLocale) else it.toString() }
    }
}
