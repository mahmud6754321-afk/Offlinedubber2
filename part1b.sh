set -e
mkdir -p app/src/main/java/com/offline/videodubber

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
                if (id == utteranceId && cont.isActive) cont.resume(Unit)
            }
        })
        val res = tts.synthesizeToFile(text, Bundle(), outFile, utteranceId)
        if (res != TextToSpeech.SUCCESS && cont.isActive) {
            cont.resume(Unit)
        }
    }

    private fun mergeWavFiles(inputs: List<File>, output: File) {
        if (inputs.isEmpty()) {
            output.writeBytes(ByteArray(0))
            return
        }
        var sampleRate = 22050
        var channels = 1
        var bitsPerSample = 16
        val pcmStream = ByteArrayOutputStream()

        inputs.forEachIndexed { index, file ->
            val bytes = file.readBytes()
            var pos = 12
            while (pos + 8 <= bytes.size) {
                val id = String(bytes, pos, 4, Charsets.US_ASCII)
                val size = ByteBuffer.wrap(bytes, pos + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
                val dataStart = pos + 8
                if (id == "fmt " && dataStart + 16 <= bytes.size && index == 0) {
                    val fmtBuf = ByteBuffer.wrap(bytes, dataStart, 16).order(ByteOrder.LITTLE_ENDIAN)
                    fmtBuf.short
                    channels = fmtBuf.short.toInt()
                    sampleRate = fmtBuf.int
                    fmtBuf.int
                    fmtBuf.short
                    bitsPerSample = fmtBuf.short.toInt()
                } else if (id == "data" && size > 0 && dataStart + size <= bytes.size) {
                    pcmStream.write(bytes, dataStart, size)
                }
                pos = dataStart + size + (size and 1)
            }
        }

        val pcmData = pcmStream.toByteArray()
        val byteRate = sampleRate * channels * (bitsPerSample / 8)
        val blockAlign = (channels * (bitsPerSample / 8)).toShort()

        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt(36 + pcmData.size)
            put("WAVE".toByteArray(Charsets.US_ASCII))
            put("fmt ".toByteArray(Charsets.US_ASCII))
            putInt(16)
            putShort(1)
            putShort(channels.toShort())
            putInt(sampleRate)
            putInt(byteRate)
            putShort(blockAlign)
            putShort(bitsPerSample.toShort())
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(pcmData.size)
        }.array()

        FileOutputStream(output).use { fos ->
            fos.write(header)
            fos.write(pcmData)
        }
    }

    fun release() {
        recognizer?.release()
        recognizer = null
    }
}
EOF
