set -e
mkdir -p app/src/main/java/com/offline/videodubber
mkdir -p app/src/main/assets/whisper

cat << 'EOF' > app/src/main/java/com/offline/videodubber/VideoAudioExtractor.kt
package com.offline.videodubber

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteOrder
import kotlin.math.abs

object VideoAudioExtractor {

  fun extract16kMonoFloatPcm(context: Context, videoUri: Uri): FloatArray {
    val extractor = MediaExtractor()
    extractor.setDataSource(context, videoUri, null)

    var audioTrackIndex = -1
    var inputFormat: MediaFormat? = null
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
      if (mime.startsWith("audio/")) {
        audioTrackIndex = i
        inputFormat = format
        break
      }
    }

    require(audioTrackIndex >= 0 && inputFormat != null) { "ভিডিওতে কোনো অডিও ট্র্যাক পাওয়া যায়নি।" }

    extractor.selectTrack(audioTrackIndex)
    val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
    var sampleRate = if (inputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
    var channelCount = if (inputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2
    var pcmEncoding = if (inputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) inputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT

    val codec = MediaCodec.createDecoderByType(mime)
    codec.configure(inputFormat, null, null, 0)
    codec.start()

    val monoSamples = ArrayList<Float>(16000 * 60)
    val bufferInfo = MediaCodec.BufferInfo()
    var inputDone = false
    var outputDone = false

    try {
      while (!outputDone) {
        if (!inputDone) {
          val inIdx = codec.dequeueInputBuffer(10_000)
          if (inIdx >= 0) {
            val inBuf = codec.getInputBuffer(inIdx)!!
            val sampleSize = extractor.readSampleData(inBuf, 0)
            if (sampleSize < 0) {
              codec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              codec.queueInputBuffer(inIdx, 0, sampleSize, extractor.sampleTime, 0)
              extractor.advance()
            }
          }
        }

        val outIdx = codec.dequeueOutputBuffer(bufferInfo, 10_000)
        when {
          outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            val outFmt = codec.outputFormat
            if (outFmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) sampleRate = outFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            if (outFmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) channelCount = outFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            if (outFmt.containsKey(MediaFormat.KEY_PCM_ENCODING)) pcmEncoding = outFmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
          }
          outIdx >= 0 -> {
            val outBuf = codec.getOutputBuffer(outIdx)
            if (outBuf != null && bufferInfo.size > 0) {
              outBuf.position(bufferInfo.offset)
              outBuf.limit(bufferInfo.offset + bufferInfo.size)
              if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                val floatBuf = outBuf.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                val floats = FloatArray(floatBuf.remaining())
                floatBuf.get(floats)
                var i = 0
                while (i + channelCount <= floats.size) {
                  var sum = 0f
                  for (c in 0 until channelCount) sum += floats[i + c]
                  monoSamples.add((sum / channelCount).coerceIn(-1f, 1f))
                  i += channelCount
                }
              } else {
                val shortBuf = outBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                val shorts = ShortArray(shortBuf.remaining())
                shortBuf.get(shorts)
                var i = 0
                while (i + channelCount <= shorts.size) {
                  var sum = 0f
                  for (c in 0 until channelCount) sum += shorts[i + c] / 32768.0f
                  monoSamples.add(sum / channelCount)
                  i += channelCount
                }
              }
            }
            codec.releaseOutputBuffer(outIdx, false)
            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true
          }
        }
      }
    } finally {
      codec.stop(); codec.release(); extractor.release()
    }

    val resampled = resampleTo16k(monoSamples, sampleRate)
    normalizeIfQuiet(resampled)
    return resampled
  }

  private fun normalizeIfQuiet(samples: FloatArray) {
    var peak = 0f
    for (v in samples) { val a = abs(v); if (a > peak) peak = a }
    if (peak in 0.005f..0.45f) {
      val gain = (0.75f / peak).coerceAtMost(6.0f)
      for (i in samples.indices) samples[i] = (samples[i] * gain).coerceIn(-1f, 1f)
    }
  }

  private fun resampleTo16k(input: List<Float>, srcRate: Int): FloatArray {
    if (input.isEmpty()) return FloatArray(0)
    if (srcRate == 16000) return input.toFloatArray()
    val ratio = srcRate.toDouble() / 16000.0
    val outLen = (input.size / ratio).toInt().coerceAtLeast(1)
    val out = FloatArray(outLen)
    for (i in 0 until outLen) {
      val pos = i * ratio
      val idx = pos.toInt().coerceIn(0, input.size - 1)
      val nextIdx = (idx + 1).coerceAtMost(input.size - 1)
      val frac = (pos - idx).toFloat()
      out[i] = input[idx] * (1f - frac) + input[nextIdx] * frac
    }
    return out
  }
}
EOF

cat << 'EOF' > app/src/main/java/com/offline/videodubber/ProExtras.kt
package com.offline.videodubber

import android.content.Context
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

val VtBg = Color(0xFF0B0B10)
val VtCard = Color(0xFF161622)
val VtCardAlt = Color(0xFF1E1E2E)
val VtGold = Color(0xFFFFC107)
val VtRed = Color(0xFFE53935)
val VtText = Color(0xFFF5F5F7)
val VtSubText = Color(0xFFB0B3C5)

@Composable
fun VtProTheme(content: @Composable () -> Unit) {
  MaterialTheme(
    colorScheme = darkColorScheme(
      primary = VtGold, onPrimary = Color.Black,
      secondary = VtRed, onSecondary = Color.White,
      background = VtBg, surface = VtCard, surfaceVariant = VtCardAlt,
      onBackground = VtText, onSurface = VtText, outline = Color(0xFF3A3A52)
    ),
    content = content
  )
}

data class SubtitleCue(val startMs: Int, val endMs: Int, val orig: String, val trans: String)

data class HistoryEntry(
  val id: Long, val title: String, val videoUri: String, val audioPath: String,
  val targetLangName: String, val headerInfo: String, val cues: List<SubtitleCue>
)

fun buildSrtContent(cues: List<SubtitleCue>): String {
  fun srtTime(ms: Int): String {
    val s = ms.coerceAtLeast(0)
    return String.format(Locale.US, "%02d:%02d:%02d,%03d", s / 3600000, (s % 3600000) / 60000, (s % 60000) / 1000, s % 1000)
  }
  return buildString {
    cues.forEachIndexed { i, c -> append("${i + 1}\n${srtTime(c.startMs)} --> ${srtTime(c.endMs)}\n${c.trans}\n\n") }
  }
}

object HistoryStore {
  private const val FILE_NAME = "vt_history.json"

  fun load(ctx: Context): List<HistoryEntry> {
    val file = File(ctx.filesDir, FILE_NAME)
    if (!file.exists()) return emptyList()
    return runCatching {
      val arr = JSONArray(file.readText())
      (0 until arr.length()).map { i ->
        val obj = arr.getJSONObject(i)
        val cArr = obj.getJSONArray("cues")
        val cues = (0 until cArr.length()).map { j ->
          val c = cArr.getJSONObject(j)
          SubtitleCue(c.getInt("s"), c.getInt("e"), c.getString("o"), c.getString("t"))
        }
        HistoryEntry(obj.getLong("id"), obj.getString("title"), obj.getString("videoUri"), obj.getString("audioPath"), obj.getString("targetLangName"), obj.getString("headerInfo"), cues)
      }
    }.getOrDefault(emptyList())
  }

  fun saveNew(ctx: Context, entry: HistoryEntry) {
    val existing = load(ctx).filterNot { it.videoUri == entry.videoUri && it.targetLangName == entry.targetLangName }
    val updated = (listOf(entry) + existing).take(12)
    val arr = JSONArray()
    updated.forEach { item ->
      val obj = JSONObject().apply {
        put("id", item.id); put("title", item.title); put("videoUri", item.videoUri)
        put("audioPath", item.audioPath); put("targetLangName", item.targetLangName); put("headerInfo", item.headerInfo)
        val cArr = JSONArray()
        item.cues.forEach { c -> cArr.put(JSONObject().apply { put("s", c.startMs); put("e", c.endMs); put("o", c.orig); put("t", c.trans) }) }
        put("cues", cArr)
      }
      arr.put(obj)
    }
    runCatching { File(ctx.filesDir, FILE_NAME).writeText(arr.toString()) }
  }
}
EOF
