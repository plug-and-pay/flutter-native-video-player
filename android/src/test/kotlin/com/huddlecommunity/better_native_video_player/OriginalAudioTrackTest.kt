package com.huddlecommunity.better_native_video_player

import com.huddlecommunity.better_native_video_player.handlers.OriginalAudioTrack
import com.huddlecommunity.better_native_video_player.handlers.OriginalAudioTrack.Track
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class OriginalAudioTrackTest {
    private fun track(dubbed: Boolean = false, original: Boolean = false, default: Boolean = false) =
        Track(isDubbed = dubbed, isMarkedOriginal = original, isDefault = default)

    @Test
    fun `the undubbed track of a dubbed stream is the original`() {
        assertEquals(
            0,
            OriginalAudioTrack.index(listOf(track(default = true), track(dubbed = true), track(dubbed = true)))
        )
    }

    @Test
    fun `a stream without dub markings has no original`() {
        assertNull(OriginalAudioTrack.index(listOf(track(default = true), track(), track())))
    }

    @Test
    fun `the DEFAULT one wins when several undubbed tracks qualify`() {
        assertEquals(
            2,
            OriginalAudioTrack.index(listOf(track(), track(dubbed = true), track(default = true)))
        )
    }

    @Test
    fun `a track marked original wins over the DEFAULT one`() {
        assertEquals(
            1,
            OriginalAudioTrack.index(listOf(track(default = true), track(original = true), track(dubbed = true)))
        )
    }

    @Test
    fun `without a DEFAULT the first undubbed track is the original`() {
        assertEquals(1, OriginalAudioTrack.index(listOf(track(dubbed = true), track(), track())))
    }

    @Test
    fun `a stream where every track is dubbed has no original`() {
        assertNull(OriginalAudioTrack.index(listOf(track(dubbed = true), track(dubbed = true))))
    }

    @Test
    fun `characteristics are read per audio rendition NAME`() {
        // Vimeo's master playlist (shortened).
        val tags = listOf(
            "#EXTM3U",
            """#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-high",NAME="English",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",CHANNELS="2",URI="a.m3u8"""",
            """#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-high",NAME="Nederlands (AI generated)",AUTOSELECT=YES,CHARACTERISTICS="public.translation.dubbed",LANGUAGE="nl",CHANNELS="1",URI="b.m3u8"""",
            """#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-high",NAME="Commentary",CHARACTERISTICS="public.accessibility.describes-video, public.original-content",LANGUAGE="en",URI="c.m3u8"""",
            """#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog",LANGUAGE="en",URI="s.m3u8"""",
            """#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio-high"""",
        )

        assertEquals(
            mapOf(
                "English" to emptySet(),
                "Nederlands (AI generated)" to setOf(OriginalAudioTrack.DUBBED),
                "Commentary" to setOf("public.accessibility.describes-video", OriginalAudioTrack.ORIGINAL),
            ),
            OriginalAudioTrack.audioCharacteristicsByName(tags)
        )
    }
}
