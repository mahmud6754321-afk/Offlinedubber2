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

cat << 'EOF' > app/src/main/java/com/offline/videodubber/OfflineDubberEngine.kt
package com.offline.videodubber

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

enum class SourceLanguage(val label: String, val whisperCode: String, val mlKitCode: String?) {
    AUTO("স্বয়ংক্রিয় (Auto Detect)", "", null),
    ENGLISH("ইংরেজি (English)", "en", TranslateLanguage.ENGLISH),
    HINDI("হিন্দি (Hindi)", "hi", TranslateLanguage.HINDI),
    BENGALI("বাংলা (Bengali)", "bn", TranslateLanguage.BENGALI),
    URDU("উর্দু (Urdu)", "ur", TranslateLanguage.URDU),
    ARABIC("আরবি (Arabic)", "ar", TranslateLanguage.ARABIC),
    CHINESE("চাইনিজ (Chinese)", "zh", TranslateLanguage.CHINESE),
    JAPANESE("জাপানিজ (Japanese)", "ja", TranslateLanguage.JAPANESE),
    KOREAN("কোরিয়ান (Korean)", "ko", TranslateLanguage.KOREAN),
    SPANISH("স্প্যানিশ (Spanish)", "es", TranslateLanguage.SPANISH)
}

enum class TargetLanguage(val label: String, val mlKitCode: String, val locale: Locale) {
    BENGALI("বাংলা (Bengali)", TranslateLanguage.BENGALI, Locale("bn", "BD")),
    HINDI("হিন্দি (Hindi)", TranslateLanguage.HINDI, Locale("hi", "IN")),
    ENGLISH("ইংরেজি (English)", TranslateLanguage.ENGLISH, Locale.US)
}

data class DubbingResult(
    val dubbedAudioFile: File,
    val transcriptText: String
)

class OfflineDubberEngine(private val context: Context) {

    private var recognizer: OfflineRecognizer? = null
    private var currentWhisperLang: String? = null

    private fun getRecognizer(whisperLang: String): OfflineRecognizer {
        val existing = recognizer
        if (existing != null && currentWhisperLang == whisperLang) return existing
        existing?.release()

        val config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = "whisper/base-encoder.int8.onnx",
                    decoder = "whisper/base-decoder.int8.onnx",
                    language = whisperLang,
                    task = "transcribe"
                ),
                tokens = "whisper/base-tokens.txt",
                numThreads = 4,
                modelType = "whisper"
            )
        )
        return OfflineRecognizer(assetManager = context.assets, config = config).also {
            recognizer = it
            currentWhisperLang = whisperLang
        }
    }

    private fun extractSpeechSegmentsWithVad(samples: FloatArray): List<Triple<Int, Int, FloatArray>> {
        val vadConfig = VadModelConfig(
            sileroVadModelConfig = SileroVadModelConfig(
                model = "whisper/silero_vad.onnx",
                threshold = 0.45f,
                minSilenceDuration = 0.40f,
                minSpeechDuration = 0.25f,
                windowSize = 512,
                maxSpeechDuration = 12.0f
            ),
            sampleRate = 16000,
            numThreads = 1
        )
        val vad = Vad(assetManager = context.assets, config = vadConfig)
        val list = mutableListOf<Triple<Int, Int, FloatArray>>()
        try {
            val win = 512
            var offset = 0
            while (offset + win <= samples.size) {
                vad.acceptWaveform(samples.copyOfRange(offset, offset + win))
                offset += win
            }
            vad.flush()
            while (!vad.empty()) {
                val seg = vad.front()
                val startSec = seg.start / 16000
                val endSec = (seg.start + seg.samples.size) / 16000
                if (seg.samples.size >= 4000) {
                    list.add(Triple(startSec, maxOf(endSec, startSec + 1), seg.samples))
                }
                vad.pop()
            }
        } finally {
            vad.release()
        }

        if (list.isEmpty()) {
            val chunkLen = 16000 * 10
            var pos = 0
            while (pos < samples.size) {
                val end = minOf(pos + chunkLen, samples.size)
                list.add(Triple(pos / 16000, end / 16000, samples.copyOfRange(pos, end)))
                pos = end
            }
        }
        return list
    }

    suspend fun processVideo(
        videoUri: Uri,
        sourceLang: SourceLanguage,
        targetLang: TargetLanguage,
        onStatus: (Float, String) -> Unit
    ): DubbingResult = withContext(Dispatchers.IO) {
        onStatus(0.08f, "ভিডিও থেকে অডিও আলাদা করা হচ্ছে...")
        val samples = VideoAudioExtractor.extract16kMonoFloatPcm(context, videoUri)
        require(samples.isNotEmpty()) { "অডিও পাওয়া যায়নি।" }

        onStatus(0.18f, "কথার অংশগুলো আলাদা করা হচ্ছে (VAD)...")
        val speechSegments = extractSpeechSegmentsWithVad(samples)

        onStatus(0.25f, "শক্তিশালী অফলাইন AI মডেল চালু হচ্ছে...")
        val asr = getRecognizer(sourceLang.whisperCode)

        val rawChunks = mutableListOf<Triple<Int, Int, String>>()
        val total = speechSegments.size.coerceAtLeast(1)

        for ((idx, seg) in speechSegments.withIndex()) {
            onStatus(
                0.28f + 0.35f * (idx.toFloat() / total),
                "কথা বোঝা হচ্ছে (${idx + 1}/$total)..."
            )
            val stream = asr.createStream()
            stream.acceptWaveform(seg.third, 16000)
            asr.decode(stream)
            val rawText = asr.getResult(stream).text.trim()
            stream.release()

            val cleaned = cleanWhisperRepetitions(rawText)
            if (cleaned.isNotBlank()) {
                rawChunks.add(Triple(seg.first, seg.second, cleaned))
            }
        }

        require(rawChunks.isNotEmpty()) { "ভিডিওতে কোনো স্পষ্ট কথা পাওয়া যায়নি।" }

        onStatus(0.68f, "অফলাইন অনুবাদ করা হচ্ছে...")
        val sourceCode = if (sourceLang.mlKitCode != null) {
            sourceLang.mlKitCode
        } else {
            val sampleText = rawChunks.joinToString(" ") { it.third }.take(400)
            val detected = LanguageIdentification.getClient().identifyLanguage(sampleText).await()
            TranslateLanguage.fromLanguageTag(detected) ?: TranslateLanguage.ENGLISH
        }

        val translatedChunks = mutableListOf<Triple<Int, Int, String>>()
        if (sourceCode == targetLang.mlKitCode) {
            translatedChunks.addAll(rawChunks)
        } else {
            val options = TranslatorOptions.Builder()
                .setSourceLanguage(sourceCode)
                .setTargetLanguage(targetLang.mlKitCode)
                .build()
            val translator = Translation.getClient(options)
            try {
                try {
                    translator.downloadModelIfNeeded(DownloadConditions.Builder().build()).await()
                } catch (e: Exception) {
                    throw IllegalStateException("প্রথমবার এই ভাষার অফলাইন অনুবাদ প্যাক (~৩০ MB) নামাতে একবার ইন্টারনেট চালু করুন। এরপর পুরোপুরি অফলাইন চলবে!")
                }
                for ((idx, chunk) in rawChunks.withIndex()) {
                    onStatus(
                        0.70f + 0.12f * (idx.toFloat() / rawChunks.size),
                        "অনুবাদ করা হচ্ছে (${idx + 1}/${rawChunks.size})..."
                    )
                    val translated = translator.translate(chunk.third).await()
                    translatedChunks.add(Triple(chunk.first, chunk.second, translated))
                }
            } finally {
                translator.close()
            }
        }

        onStatus(0.84f, "অফলাইন ভয়েস তৈরি করা হচ্ছে...")
        val partWavFiles = mutableListOf<File>()
        val transcriptBuilder = StringBuilder()
        transcriptBuilder.append("মূল ভাষা: $sourceCode -> অনুবাদ: ${targetLang.label}\n")
        transcriptBuilder.append("----------------------------------------\n")

        val tts = createTts(targetLang.locale)
        try {
            for ((idx, chunk) in translatedChunks.withIndex()) {
                val orig = rawChunks[idx].third
                val trans = chunk.third
                transcriptBuilder.append("[${chunk.first}s - ${chunk.second}s]\n")
                transcriptBuilder.append("মূল: $orig\nঅনুবাদ: $trans\n\n")

                val partFile = File(context.cacheDir, "tts_part_$idx.wav")
                if (partFile.exists()) partFile.delete()
                synthesizeToWav(tts, trans, partFile, "utt_$idx")
                if (partFile.exists() && partFile.length() > 44) {
                    partWavFiles.add(partFile)
                }
            }
        } finally {
            tts.stop()
            tts.shutdown()
        }

        require(partWavFiles.isNotEmpty()) {
            "ফোনে ${targetLang.label} অফলাইন ভয়েস পাওয়া যায়নি। Settings > Text-to-speech থেকে ভয়েস ডাউনলোড করুন।"
        }

        val finalWav = File(context.filesDir, "dubbed_output.wav")
        mergeWavFiles(partWavFiles, finalWav)
        partWavFiles.forEach { it.delete() }

        onStatus(1.0f, "সম্পন্ন!")
        DubbingResult(finalWav, transcriptBuilder.toString())
    }

    private fun cleanWhisperRepetitions(input: String): String {
        val words = input.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.size <= 4) return words.joinToString(" ")

        val out = mutableListOf<String>()
        var i = 0
        while (i < words.size) {
            var skipped = false
            for (n in 1..6) {
                if (i + n * 3 <= words.size) {
                    val phrase = words.subList(i, i + n)
                    var repeats = 1
                    var j = i + n
                    while (j + n <= words.size && words.subList(j, j + n) == phrase) {
                        repeats++
                        j += n
                    }
                    if (repeats >= 3) {
                        out.addAll(phrase)
                        i = j
                        skipped = true
                        break
                    }
                }
            }
            if (!skipped) {
                out.add(words[i])
                i++
            }
        }
        return out.joinToString(" ")
    }

    private suspend fun createTts(locale: Locale): TextToSpeech =
        suspendCancellableCoroutine { cont ->
            var ttsRef: TextToSpeech? = null
            ttsRef = TextToSpeech(context) { status ->
                val engine = ttsRef
                if (status == TextToSpeech.SUCCESS && engine != null) {
                    engine.language = locale
                    cont.resume(engine)
                } else {
                    cont.resumeWithException(IllegalStateException("ফোনের Text-to-Speech চালু করা যায়নি।"))
                }
            }
        }

    private suspend fun synthesizeToWav(
        tts: TextToSpeech,
        text: String,
        outFile: File,
        utteranceId: String
    ) = suspendCancellableCoroutine { cont ->
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) {
                if (id == utteranceId && cont.isActive) cont.resume(Unit)
            }
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) {
                if (id == utteranceId && cont.isActive) cont.resume(Unit)
            }
            override fun onError(id: String?, errorCode: Int) {
                if (id == utteranceId && cont.isActive) cont
