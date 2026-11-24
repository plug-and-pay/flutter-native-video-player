package com.huddlecommunity.better_native_video_player

import com.huddlecommunity.better_native_video_player.handlers.TrackDisplayNames
import com.huddlecommunity.better_native_video_player.handlers.TrackDisplayNames.Track
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TrackDisplayNamesTest {
    private val english = Locale.ENGLISH
    private val dutch = Locale.forLanguageTag("nl")

    @Test
    fun `tracks are named by language, not by the HLS NAME`() {
        // The audio of Shaka's angel-one stream.
        val names = TrackDisplayNames.displayNames(
            listOf(
                Track("de", "stream_4"),
                Track("it", "stream_8"),
                Track("fr", "stream_7"),
            ),
            english,
        )

        assertEquals(listOf("German", "Italian", "French"), names)
    }

    @Test
    fun `names are in the device language, capitalised`() {
        val names = TrackDisplayNames.displayNames(
            listOf(Track("de", "stream_4"), Track("en", "Nederlands (AI generated)")),
            dutch,
        )

        assertEquals(listOf("Duits", "Engels"), names)
    }

    @Test
    fun `two tracks sharing a language add their NAME`() {
        val names = TrackDisplayNames.displayNames(
            listOf(
                Track("en", "stream_5"),
                Track("de", "stream_4"),
                Track("en", "stream_6"),
            ),
            english,
        )

        assertEquals(listOf("English (stream_5)", "German", "English (stream_6)"), names)
    }

    @Test
    fun `a NAME that already names the language is used as is`() {
        val names = TrackDisplayNames.displayNames(
            listOf(Track("en", "English"), Track("en", "English (Audio Description)")),
            english,
        )

        assertEquals(listOf("English", "English (Audio Description)"), names)
    }

    @Test
    fun `a region or script is part of the name`() {
        val names = TrackDisplayNames.displayNames(
            listOf(Track("pt-BR", "stream_3"), Track("el", "stream_1")),
            english,
        )

        assertEquals(listOf("Portuguese (Brazil)", "Greek"), names)
    }

    @Test
    fun `a sidecar track keeps the label the app passed`() {
        val names = TrackDisplayNames.displayNames(
            listOf(
                Track("en", "stream_0"),
                Track("en", "English (club translation)", isSidecar = true),
            ),
            english,
        )

        // The sidecar doesn't make the embedded track ambiguous either.
        assertEquals(listOf("English", "English (club translation)"), names)
    }

    @Test
    fun `a track without a usable language falls back to its NAME`() {
        val names = TrackDisplayNames.displayNames(
            listOf(Track(null, "Commentary"), Track("und", "Director"), Track(null, null)),
            english,
        )

        assertEquals(listOf("Commentary", "Director", "Unknown"), names)
    }

    @Test
    fun `undetermined and unknown codes have no language name`() {
        assertNull(TrackDisplayNames.languageName("und", english))
        assertNull(TrackDisplayNames.languageName("", english))
        assertNull(TrackDisplayNames.languageName("xx", english))
    }
}
