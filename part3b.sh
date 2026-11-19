set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > app/src/main/java/com/offline/videodubber/WavTtsHelper.kt
package com.offline.videodubber

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

object WavTtsHelper {

  fun cleanWhisperRepetitions(input: String): String {
    val words = input.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    if (words.size <= 4) return words.joinToString(" ")
    val out = mutableListOf<String>()
    var i = 0
    while (i < words.size) {
      var skipped = false
      for (n in 1..6) {
        if (i + n * 3 <= words.size) {
          val phrase = words.subList(i, i + n)
          var repeats = 1; var j = i + n
          while (j + n <= words.size && words.subList(j, j + n) == phrase) { repeats++; j += n }
          if (repeats >= 3) { out.addAll(phrase); i = j; skipped = true; break }
        }
      }
      if (!skipped) { out.add(words[i]); i++ }
    }
    return out.joinToString(" ")
  }

  suspend fun createTts(
    context: Context, locale: Locale, forLiveAssistant: Boolean, speechRate: Float = 1.0f, pitch: Float = 1.0f
  ): Pair<TextToSpeech, Boolean> = suspendCancellableCoroutine { cont ->
    var ttsRef: TextToSpeech? = null
    ttsRef = TextToSpeech(context) { status ->
      val engine = ttsRef
      if (status == TextToSpeech.SUCCESS && engine != null) {
        if (forLiveAssistant) {
          engine.setAudioAttributes(
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
          )
        }
        engine.setSpeechRate(speechRate.coerceIn(0.6f, 1.6f))
        engine.setPitch(pitch.coerceIn(0.6f, 1.5f))
        val voices = runCatching { engine.voices }.getOrNull().orEmpty()
        val offlineExact = voices.firstOrNull { !it.isNetworkConnectionRequired && it.locale.language == locale.language && it.locale.country == locale.country }
        val offlineLang = voices.firstOrNull { !it.isNetworkConnectionRequired && it.locale.language == locale.language }
        val useOffline = (offlineExact != null || offlineLang != null)
        if (offlineExact != null) engine.voice = offlineExact
        else if (offlineLang != null) engine.voice = offlineLang
        else engine.language = locale
        cont.resume(Pair(engine, useOffline))
      } else cont.resumeWithException(IllegalStateException("Text-to-Speech চালু করা যায়নি।"))
    }
  }

  suspend fun synthesizeToWav(tts: TextToSpeech, text: String, outFile: File, utteranceId: String, useEmbeddedOnly: Boolean) =
    suspendCancellableCoroutine { cont ->
      tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
        override fun onStart(id: String?) {}
        override fun onDone(id: String?) { if (id == utteranceId && cont.isActive) cont.resume(Unit) }
        @Deprecated("Deprecated in Java") override fun onError(id: String?) { if (id == utteranceId && cont.isActive) cont.resume(Unit) }
        override fun onError(id: String?, errorCode: Int) { if (id == utteranceId && cont.isActive) cont.resume(Unit) }
      })
      val params = Bundle().apply {
        if (useEmbeddedOnly) {
          putString(TextToSpeech.Engine.KEY_FEATURE_EMBEDDED_SYNTHESIS, "true")
          putString(TextToSpeech.Engine.KEY_FEATURE_NETWORK_SYNTHESIS, "false")
        }
      }
      val res = tts.synthesizeToFile(text, params, outFile, utteranceId)
      if (res != TextToSpeech.SUCCESS && cont.isActive) cont.resume(Unit)
    }

  fun mergeWavFiles(inputs: List<File>, output: File) {
    if (inputs.isEmpty()) { output.writeBytes(ByteArray(0)); return }
    var sampleRate = 22050; var channels = 1; var bitsPerSample = 16
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
          fmtBuf.short; channels = fmtBuf.short.toInt(); sampleRate = fmtBuf.int
          fmtBuf.int; fmtBuf.short; bitsPerSample = fmtBuf.short.toInt()
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
      put("RIFF".toByteArray(Charsets.US_ASCII)); putInt(36 + pcmData.size)
      put("WAVE".toByteArray(Charsets.US_ASCII)); put("fmt ".toByteArray(Charsets.US_ASCII))
      putInt(16); putShort(1); putShort(channels.toShort()); putInt(sampleRate)
      putInt(byteRate); putShort(blockAlign); putShort(bitsPerSample.toShort())
      put("data".toByteArray(Charsets.US_ASCII)); putInt(pcmData.size)
    }.array()
    FileOutputStream(output).use { it.write(header); it.write(pcmData) }
  }
}
EOF

cat << 'EOF' > app/src/main/java/com/offline/videodubber/ProDialogs.kt
package com.offline.videodubber

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.util.Locale

@Composable
fun VtProHeader(onOpenHistory: () -> Unit, onToggleSettings: () -> Unit) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
    Image(
      painter = painterResource(id = R.drawable.app_logo), contentDescription = "VT", contentScale = ContentScale.Crop,
      modifier = Modifier.size(56.dp).clip(RoundedCornerShape(14.dp)).border(1.5.dp, VtGold, RoundedCornerShape(14.dp))
    )
    Column(modifier = Modifier.weight(1f)) {
      Text("VT ভিডিও ট্রান্সলেটর", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = VtGold)
      Text("অফলাইন AI স্টুডিও PRO", style = MaterialTheme.typography.bodySmall, color = VtSubText)
    }
    OutlinedIconButton(onClick = onOpenHistory, border = BorderStroke(1.dp, VtGold)) { Icon(Icons.Rounded.History, "History", tint = VtGold) }
    OutlinedIconButton(onClick = onToggleSettings, border = BorderStroke(1.dp, VtGold)) { Icon(Icons.Rounded.Tune, "Settings", tint = VtGold) }
  }
}

@Composable
fun ProSettingsCard(
  speechRate: Float, onRateChange: (Float) -> Unit,
  pitch: Float, onPitchChange: (Float) -> Unit,
  bgVolume: Float, onBgChange: (Float) -> Unit,
  showSubtitles: Boolean, onSubChange: (Boolean) -> Unit,
  onOpenTtsSettings: () -> Unit
) {
  Card(colors = CardDefaults.cardColors(containerColor = VtCard), border = BorderStroke(1.dp, VtGold)) {
    Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
      Text("প্রো ভয়েস ও প্লেয়ার সেটিংস", color = VtGold, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
      Text("ভয়েস স্পিড: ${String.format(Locale.US, "%.2fx", speechRate)}", color = VtText, style = MaterialTheme.typography.bodySmall)
      Slider(value = speechRate, onValueChange = onRateChange, valueRange = 0.75f..1.45f)
      Text("ভয়েস টোন (পিচ): ${String.format(Locale.US, "%.2f", pitch)}", color = VtText, style = MaterialTheme.typography.bodySmall)
      Slider(value = pitch, onValueChange = onPitchChange, valueRange = 0.75f..1.35f)
      Text("মূল ভিডিওর ব্যাকগ্রাউন্ড সাউন্ড: ${(bgVolume * 100).toInt()}%", color = VtText, style = MaterialTheme.typography.bodySmall)
      Slider(value = bgVolume, onValueChange = onBgChange, valueRange = 0f..0.40f)
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
        Text("ভিডিওতে বাংলা সাবটাইটেল (CC)", color = VtText)
        Switch(checked = showSubtitles, onCheckedChange = onSubChange)
      }
      OutlinedButton(onClick = onOpenTtsSettings, modifier = Modifier.fillMaxWidth()) {
        Icon(Icons.Rounded.RecordVoiceOver, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
        Text("ফোনের অফলাইন ভয়েস প্যাক ডাউনলোড করুন")
      }
    }
  }
}

@Composable
fun EditTranscriptDialog(initialText: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
  var buf by remember { mutableStateOf(initialText) }
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("অনুবাদ এডিট করুন (প্রতি লাইনে ১টি বাক্য)", color = VtGold) },
    text = { OutlinedTextField(value = buf, onValueChange = { buf = it }, modifier = Modifier.fillMaxWidth().height(220.dp)) },
    confirmButton = { Button(onClick = { onConfirm(buf) }) { Text("ভয়েস আপডেট করুন") } },
    dismissButton = { TextButton(onClick = onDismiss) { Text("বাতিল") } }
  )
}

@Composable
fun HistoryDialog(historyList: List<HistoryEntry>, onSelect: (HistoryEntry) -> Unit, onDismiss: () -> Unit) {
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("পূর্বের অনুবাদসমূহ", color = VtGold) },
    text = {
      Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (historyList.isEmpty()) Text("এখনো কোনো হিস্ট্রি নেই।", color = VtSubText)
        historyList.forEach { item ->
          Card(colors = CardDefaults.cardColors(containerColor = VtCardAlt), modifier = Modifier.fillMaxWidth().clickable { onSelect(item) }) {
            Column(modifier = Modifier.padding(10.dp)) {
              Text(item.title, color = VtGold, style = MaterialTheme.typography.labelLarge)
              Text(item.targetLangName, color = VtSubText, style = MaterialTheme.typography.bodySmall)
            }
          }
        }
      }
    },
    confirmButton = { TextButton(onClick = onDismiss) { Text("বন্ধ করুন") } }
  )
}
EOF
