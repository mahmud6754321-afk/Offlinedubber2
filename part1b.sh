set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > app/src/main/java/com/offline/videodubber/OfflineDubberEngine.kt
package com.offline.videodubber

import android.content.Context
import android.net.Uri
import android.speech.tts.TextToSpeech
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
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
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.Locale

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

data class DubbingResult(val dubbedAudioFile: File, val cues: List<SubtitleCue>, val headerInfo: String) {
  val transcriptText: String
    get() = buildString {
      append(headerInfo).append("\n----------------------------------------\n")
      cues.forEach { c -> append("[${c.startMs / 1000}s - ${c.endMs / 1000}s]\nমূল: ${c.orig}\nঅনুবাদ: ${c.trans}\n\n") }
    }
}

class OfflineDubberEngine(private val context: Context) {

  private var recognizer: OfflineRecognizer? = null
  private var currentWhisperLang: String? = null
  private var liveTranslator: Translator? = null
  private var liveSrcCode: String? = null
  private var liveTgtCode: String? = null

  private fun getRecognizer(whisperLang: String): OfflineRecognizer {
    val existing = recognizer
    if (existing != null && currentWhisperLang == whisperLang) return existing
    existing?.release()
    val config = OfflineRecognizerConfig(
      featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
      modelConfig = OfflineModelConfig(
        whisper = OfflineWhisperModelConfig(
          encoder = "whisper/base-encoder.int8.onnx", decoder = "whisper/base-decoder.int8.onnx",
          language = whisperLang, task = "transcribe"
        ),
        tokens = "whisper/base-tokens.txt", numThreads = 4, modelType = "whisper"
      )
    )
    return OfflineRecognizer(assetManager = context.assets, config = config).also {
      recognizer = it; currentWhisperLang = whisperLang
    }
  }

  fun createLiveVad(): Vad {
    val vadConfig = VadModelConfig(
      sileroVadModelConfig = SileroVadModelConfig(
        model = "whisper/silero_vad.onnx", threshold = 0.45f,
        minSilenceDuration = 0.35f, minSpeechDuration = 0.25f, windowSize = 512, maxSpeechDuration = 6.0f
      ),
      sampleRate = 16000, numThreads = 1
    )
    return Vad(assetManager = context.assets, config = vadConfig)
  }

  suspend fun createTts(locale: Locale, forLiveAssistant: Boolean): Pair<TextToSpeech, Boolean> =
    WavTtsHelper.createTts(context, locale, forLiveAssistant)

  private suspend fun ensureModelsAndTranslate(text: String, srcCode: String, tgtCode: String): String {
    if (srcCode == tgtCode) return text
    if (liveTranslator == null || liveSrcCode != srcCode || liveTgtCode != tgtCode) {
      liveTranslator?.close()
      val tr = Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(srcCode).setTargetLanguage(tgtCode).build())
      val mgr = RemoteModelManager.getInstance()
      val sReady = runCatching { mgr.isModelDownloaded(TranslateRemoteModel.Builder(srcCode).build()).await() }.getOrDefault(false)
      val tReady = runCatching { mgr.isModelDownloaded(TranslateRemoteModel.Builder(tgtCode).build()).await() }.getOrDefault(false)
      if (!sReady || !tReady) {
        val ok = withTimeoutOrNull(90_000L) {
          runCatching { tr.downloadModelIfNeeded(DownloadConditions.Builder().build()).await() }.isSuccess
        } ?: false
        if (!ok) { tr.close(); throw IllegalStateException("প্রথমবার এই ভাষার অনুবাদ প্যাক (~৩০ MB) নামাতে ইন্টারনেট চালু করুন।") }
      }
      liveTranslator = tr; liveSrcCode = srcCode; liveTgtCode = tgtCode
    }
    return liveTranslator!!.translate(text).await()
  }

  suspend fun transcribeAndTranslateLive(samples: FloatArray, sourceLang: SourceLanguage, targetLang: TargetLanguage): Pair<String, String>? =
    withContext(Dispatchers.IO) {
      val asr = getRecognizer(sourceLang.whisperCode)
      val stream = asr.createStream()
      stream.acceptWaveform(samples, 16000)
      asr.decode(stream)
      val raw = asr.getResult(stream).text.trim()
      stream.release()
      val cleaned = WavTtsHelper.cleanWhisperRepetitions(raw)
      if (cleaned.isBlank() || cleaned.length < 2) return@withContext null
      val srcCode = if (sourceLang.mlKitCode != null) sourceLang.mlKitCode else {
        val det = runCatching { LanguageIdentification.getClient().identifyLanguage(cleaned).await() }.getOrDefault("en")
        TranslateLanguage.fromLanguageTag(det) ?: TranslateLanguage.ENGLISH
      }
      Pair(cleaned, ensureModelsAndTranslate(cleaned, srcCode, targetLang.mlKitCode))
    }

  private fun extractSpeechSegmentsWithVad(samples: FloatArray): List<Triple<Int, Int, FloatArray>> {
    val vad = createLiveVad()
    val list = mutableListOf<Triple<Int, Int, FloatArray>>()
    try {
      var offset = 0
      while (offset + 512 <= samples.size) { vad.acceptWaveform(samples.copyOfRange(offset, offset + 512)); offset += 512 }
      vad.flush()
      while (!vad.empty()) {
        val seg = vad.front()
        val s = seg.start / 16000; val e = (seg.start + seg.samples.size) / 16000
        if (seg.samples.size >= 4000) list.add(Triple(s, maxOf(e, s + 1), seg.samples))
        vad.pop()
      }
    } finally { vad.release() }
    if (list.isEmpty()) {
      var pos = 0
      while (pos < samples.size) {
        val end = minOf(pos + 160000, samples.size)
        list.add(Triple(pos / 16000, end / 16000, samples.copyOfRange(pos, end))); pos = end
      }
    }
    return list
  }

  suspend fun processVideo(
    videoUri: Uri, sourceLang: SourceLanguage, targetLang: TargetLanguage,
    speechRate: Float = 1.0f, pitch: Float = 1.0f, onStatus: (Float, String) -> Unit
  ): DubbingResult = withContext(Dispatchers.IO) {
    onStatus(0.08f, "ভিডিও থেকে অডিও আলাদা করা হচ্ছে...")
    val samples = VideoAudioExtractor.extract16kMonoFloatPcm(context, videoUri)
    require(samples.isNotEmpty()) { "অডিও পাওয়া যায়নি।" }

    onStatus(0.18f, "কথার অংশগুলো আলাদা করা হচ্ছে (VAD)...")
    val speechSegments = extractSpeechSegmentsWithVad(samples)

    onStatus(0.25f, "অফলাইন AI মডেল চালু হচ্ছে...")
    val asr = getRecognizer(sourceLang.whisperCode)
    val rawChunks = mutableListOf<Triple<Int, Int, String>>()
    val total = speechSegments.size.coerceAtLeast(1)

    for ((idx, seg) in speechSegments.withIndex()) {
      onStatus(0.28f + 0.35f * (idx.toFloat() / total), "কথা বোঝা হচ্ছে (${idx + 1}/$total)...")
      val stream = asr.createStream()
      stream.acceptWaveform(seg.third, 16000)
      asr.decode(stream)
      val rawText = asr.getResult(stream).text.trim()
      stream.release()
      val cleaned = WavTtsHelper.cleanWhisperRepetitions(rawText)
      if (cleaned.isNotBlank()) rawChunks.add(Triple(seg.first, seg.second, cleaned))
    }
    require(rawChunks.isNotEmpty()) { "ভিডিওতে কোনো স্পষ্ট কথা পাওয়া যায়নি।" }

    onStatus(0.65f, "অফলাইন অনুবাদ করা হচ্ছে...")
    val sourceCode = if (sourceLang.mlKitCode != null) sourceLang.mlKitCode else {
      val det = LanguageIdentification.getClient().identifyLanguage(rawChunks.joinToString(" ") { it.third }.take(400)).await()
      TranslateLanguage.fromLanguageTag(det) ?: TranslateLanguage.ENGLISH
    }

    val cues = mutableListOf<SubtitleCue>()
    for ((idx, chunk) in rawChunks.withIndex()) {
      onStatus(0.68f + 0.14f * (idx.toFloat() / rawChunks.size), "অফলাইনে অনুবাদ হচ্ছে (${idx + 1}/${rawChunks.size})...")
      val translated = ensureModelsAndTranslate(chunk.third, sourceCode, targetLang.mlKitCode)
      cues.add(SubtitleCue(chunk.first * 1000, maxOf(chunk.second * 1000, chunk.first * 1000 + 1200), chunk.third, translated))
    }

    onStatus(0.85f, "প্রো অফলাইন ভয়েস তৈরি হচ্ছে...")
    val outFile = File(context.filesDir, "dubbed_${System.currentTimeMillis()}.wav")
    val header = synthesizeCues(cues, "মূল ভাষা: $sourceCode -> অনুবাদ: ${targetLang.label}", targetLang, speechRate, pitch, outFile)
    onStatus(1.0f, "সম্পন্ন!")
    DubbingResult(outFile, cues, header)
  }

  suspend fun reSynthesizeFromCues(
    cues: List<SubtitleCue>, headerInfo: String, targetLang: TargetLanguage, speechRate: Float, pitch: Float
  ): DubbingResult = withContext(Dispatchers.IO) {
    val outFile = File(context.filesDir, "dubbed_${System.currentTimeMillis()}.wav")
    val header = synthesizeCues(cues, headerInfo, targetLang, speechRate, pitch, outFile)
    DubbingResult(outFile, cues, header)
  }

  private suspend fun synthesizeCues(
    cues: List<SubtitleCue>, baseHeader: String, targetLang: TargetLanguage, speechRate: Float, pitch: Float, outFile: File
  ): String {
    val partFiles = mutableListOf<File>()
    val (tts, hasOffline) = WavTtsHelper.createTts(context, targetLang.locale, false, speechRate, pitch)
    try {
      for ((idx, cue) in cues.withIndex()) {
        val partFile = File(context.cacheDir, "tts_part_$idx.wav")
        if (partFile.exists()) partFile.delete()
        withTimeoutOrNull(20_000L) { WavTtsHelper.synthesizeToWav(tts, cue.trans, partFile, "utt_$idx", hasOffline) }
        if (partFile.exists() && partFile.length() > 44) partFiles.add(partFile)
      }
    } finally { tts.stop(); tts.shutdown() }
    require(partFiles.isNotEmpty()) { "ফোনে ${targetLang.label} অফলাইন ভয়েস ডাউনলোড করা নেই। প্রো সেটিংস থেকে ভয়েস নামিয়ে নিন।" }
    WavTtsHelper.mergeWavFiles(partFiles, outFile)
    partFiles.forEach { it.delete() }
    return if (hasOffline) baseHeader else "$baseHeader\n(নোট: Settings > Text-to-speech থেকে অফলাইন ভয়েস নামিয়ে নিন)"
  }

  fun release() { liveTranslator?.close(); liveTranslator = null; recognizer?.release(); recognizer = null }
}
EOF
