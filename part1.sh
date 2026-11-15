set -e
mkdir -p app/src/main/java/com/offline/videodubber
mkdir -p app/src/main/assets/whisper

cat << 'EOF' > app/src/main/java/com/offline/videodubber/VideoAudioExtractor.kt
package com.offline.videodubber

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteOrder

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
            "ভিডিওতে কোনো অডিও পাওয়া যায়নি।"
        }

        extractor.selectTrack(audioTrackIndex)
        val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
        var sampleRate = if (inputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
            inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } else 44100
        var channelCount = if (inputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        } else 2

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
                    }
                    outIdx >= 0 -> {
                        val outBuf = codec.getOutputBuffer(outIdx)
                        if (outBuf != null && bufferInfo.size > 0) {
                            outBuf.position(bufferInfo.offset)
                            outBuf.limit(bufferInfo.offset + bufferInfo.size)
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

        return resampleTo16k(monoSamples, sampleRate)
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
import kotlin.math.sqrt

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

    private fun getRecognizer(): OfflineRecognizer {
        recognizer?.let { return it }
        val config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = "whisper/tiny-encoder.int8.onnx",
                    decoder = "whisper/tiny-decoder.int8.onnx",
                    language = "",
                    task = "transcribe"
                ),
                tokens = "whisper/tiny-tokens.txt",
                numThreads = 4,
                modelType = "whisper"
            )
        )
        return OfflineRecognizer(assetManager = context.assets, config = config).also {
            recognizer = it
        }
    }

    suspend fun processVideo(
        videoUri: Uri,
        targetLang: TargetLanguage,
        onStatus: (Float, String) -> Unit
    ): DubbingResult = withContext(Dispatchers.IO) {
        onStatus(0.10f, "ভিডিও থেকে অডিও আলাদা করা হচ্ছে...")
        val samples = VideoAudioExtractor.extract16kMonoFloatPcm(context, videoUri)
        require(samples.isNotEmpty()) { "অডিও পাওয়া যায়নি।" }

        onStatus(0.22f, "অফলাইন AI মডেল চালু হচ্ছে...")
        val asr = getRecognizer()

        val chunkSize = 16000 * 25
        val totalChunks = ((samples.size + chunkSize - 1) / chunkSize).coerceAtLeast(1)
        val rawChunks = mutableListOf<Triple<Int, Int, String>>()

        for (c in 0 until totalChunks) {
            val startIdx = c * chunkSize
            val endIdx = minOf(startIdx + chunkSize, samples.size)
            val slice = samples.copyOfRange(startIdx, endIdx)

            onStatus(
                0.25f + 0.30f * (c.toFloat() / totalChunks),
                "কথা শনাক্ত করা হচ্ছে (${c + 1}/$totalChunks)..."
            )

            if (rms(slice) < 0.002f) continue

            val stream = asr.createStream()
            stream.acceptWaveform(slice, 16000)
            asr.decode(stream)
            val text = asr.getResult(stream).text.trim()
            stream.release()

            if (text.isNotBlank()) {
                rawChunks.add(Triple(c * 25, (endIdx / 16000), text))
            }
        }

        require(rawChunks.isNotEmpty()) { "ভিডিওতে কোনো স্পষ্ট কথা পাওয়া যায়নি।" }

        onStatus(0.60f, "ভাষা শনাক্ত ও অফলাইন অনুবাদ করা হচ্ছে...")
        val combinedSampleText = rawChunks.joinToString(" ") { it.third }.take(400)
        val langIdentifier = LanguageIdentification.getClient()
        val detectedTag = langIdentifier.identifyLanguage(combinedSampleText).await()
        val sourceCode = TranslateLanguage.fromLanguageTag(detectedTag) ?: TranslateLanguage.ENGLISH

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
                translator.downloadModelIfNeeded(DownloadConditions.Builder().build()).await()
                for ((idx, chunk) in rawChunks.withIndex()) {
                    onStatus(
                        0.65f + 0.15f * (idx.toFloat() / rawChunks.size),
                        "অনুবাদ করা হচ্ছে (${idx + 1}/${rawChunks.size})..."
                    )
                    val translated = translator.translate(chunk.third).await()
                    translatedChunks.add(Triple(chunk.first, chunk.second, translated))
                }
            } finally {
                translator.close()
            }
        }

        onStatus(0.82f, "অফলাইন ভয়েস তৈরি করা হচ্ছে...")
        val partWavFiles = mutableListOf<File>()
        val transcriptBuilder = StringBuilder()
        transcriptBuilder.append("শনাক্তকৃত ভাষা কোড: $detectedTag -> ${targetLang.label}\n")
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

        val finalWav = File(context.filesDir, "dubbed_output.wav")
        mergeWavFiles(partWavFiles, finalWav)
        partWavFiles.forEach { it.delete() }

        onStatus(1.0f, "সম্পন্ন!")
        DubbingResult(finalWav, transcriptBuilder.toString())
    }

    private fun rms(data: FloatArray): Float {
        var sum = 0.0
        for (v in data) sum += v * v
        return sqrt(sum / data.size).toFloat()
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
