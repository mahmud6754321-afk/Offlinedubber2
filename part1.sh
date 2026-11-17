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

        require(audioTrackIndex >= 0 && inputFormat != null) {
            "ভিডিওতে কোনো অডিও ট্র্যাক পাওয়া যায়নি।"
        }

        extractor.selectTrack(audioTrackIndex)
        val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
        var sampleRate = if (inputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
            inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } else 44100
        var channelCount = if (inputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        } else 2
        var pcmEncoding = if (inputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            inputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } else AudioFormat.ENCODING_PCM_16BIT

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
                        if (outFmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                            sampleRate = outFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        }
                        if (outFmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            channelCount = outFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }
                        if (outFmt.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            pcmEncoding = outFmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        }
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
                                    for (c in 0 until channelCount) {
                                        sum += floats[i + c]
                                    }
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
                                    for (c in 0 until channelCount) {
                                        sum += shorts[i + c] / 32768.0f
                                    }
                                    monoSamples.add(sum / channelCount)
                                    i += channelCount
                                }
                            }
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            outputDone = true
                        }
                    }
                }
            }
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }

        val resampled = resampleTo16k(monoSamples, sampleRate)
        normalizeIfQuiet(resampled)
        return resampled
    }

    private fun normalizeIfQuiet(samples: FloatArray) {
        var peak = 0f
        for (v in samples) {
            val a = abs(v)
            if (a > peak) peak = a
        }
        if (peak in 0.005f..0.45f) {
            val gain = (0.75f / peak).coerceAtMost(6.0f)
            for (i in samples.indices) {
                samples[i] = (samples[i] * gain).coerceIn(-1f, 1f)
            }
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
