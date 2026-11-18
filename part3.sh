set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > app/src/main/java/com/offline/videodubber/MainActivity.kt
package com.offline.videodubber

import android.app.Activity
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.Toast
import android.widget.VideoView
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

class MainActivity : ComponentActivity() {
  private lateinit var engine: OfflineDubberEngine
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    engine = OfflineDubberEngine(applicationContext)
    setContent {
      MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) { DubberScreen(engine) }
      }
    }
  }
  override fun onDestroy() {
    super.onDestroy()
    engine.release()
  }
}

fun formatTimeMs(ms: Int): String {
  val secTotal = (ms / 1000).coerceAtLeast(0)
  return String.format(Locale.US, "%02d:%02d", secTotal / 60, secTotal % 60)
}

@Composable
fun DubberScreen(engine: OfflineDubberEngine) {
  val context = LocalContext.current
  val activity = context as? Activity
  val scope = rememberCoroutineScope()

  var selectedVideoUri by remember { mutableStateOf<Uri?>(null) }
  var sourceLang by remember { mutableStateOf(SourceLanguage.AUTO) }
  var showSourceMenu by remember { mutableStateOf(false) }
  var selectedLang by remember { mutableStateOf(TargetLanguage.BENGALI) }
  var isProcessing by remember { mutableStateOf(false) }
  var progress by remember { mutableFloatStateOf(0f) }
  var statusText by remember { mutableStateOf("শুরু করতে একটি ভিডিও নির্বাচন করুন") }
  var result by remember { mutableStateOf<DubbingResult?>(null) }

  var isFullScreen by remember { mutableStateOf(false) }
  var isPlaying by remember { mutableStateOf(false) }
  var durationMs by remember { mutableIntStateOf(0) }
  var currentPosMs by remember { mutableIntStateOf(0) }
  var isSeeking by remember { mutableStateOf(false) }
  var sliderPosMs by remember { mutableFloatStateOf(0f) }

  var pendingSeekMs by remember { mutableIntStateOf(0) }
  var pendingAutoPlay by remember { mutableStateOf(false) }

  var videoViewRef by remember { mutableStateOf<VideoView?>(null) }
  var mediaPlayerRef by remember { mutableStateOf<MediaPlayer?>(null) }

  val pickVideoLauncher = rememberLauncherForActivityResult(
    contract = ActivityResultContracts.OpenDocument()
  ) { uri ->
    if (uri != null) {
      selectedVideoUri = uri
      result = null
      isFullScreen = false
      statusText = "ভিডিও নির্বাচিত হয়েছে। এবার ভাষা বেছে নিয়ে রূপান্তর শুরু করুন।"
    }
  }

  val saveAudioLauncher = rememberLauncherForActivityResult(
    contract = ActivityResultContracts.CreateDocument("audio/wav")
  ) { saveUri ->
    val src = result?.dubbedAudioFile
    if (saveUri != null && src != null && src.exists()) {
      context.contentResolver.openOutputStream(saveUri)?.use { out ->
        src.inputStream().use { input -> input.copyTo(out) }
      }
      Toast.makeText(context, "অডিও সেভ হয়েছে!", Toast.LENGTH_SHORT).show()
    }
  }

  fun stopPlayback() {
    isPlaying = false
    runCatching {
      videoViewRef?.pause()
      mediaPlayerRef?.stop()
      mediaPlayerRef?.release()
      mediaPlayerRef = null
    }
  }

  fun seekBoth(targetMs: Int) {
    val safeMs = targetMs.coerceIn(0, durationMs.coerceAtLeast(0))
    currentPosMs = safeMs
    runCatching { videoViewRef?.seekTo(safeMs) }
    runCatching {
      mediaPlayerRef?.let { mp ->
        if (safeMs < mp.duration) {
          mp.seekTo(safeMs)
          if (isPlaying && !mp.isPlaying) mp.start()
        } else if (mp.isPlaying) {
          mp.pause()
        }
      }
    }
  }

  fun togglePlayPause() {
    val vv = videoViewRef ?: return
    if (isPlaying) {
      runCatching { vv.pause() }
      runCatching { if (mediaPlayerRef?.isPlaying == true) mediaPlayerRef?.pause() }
      isPlaying = false
    } else {
      var cur = runCatching { vv.currentPosition }.getOrDefault(currentPosMs)
      if (durationMs > 500 && cur >= durationMs - 300) {
        cur = 0
        seekBoth(0)
      }
      runCatching { vv.start() }
      runCatching {
        mediaPlayerRef?.let { mp ->
          if (cur < mp.duration) {
            mp.seekTo(cur)
            mp.start()
          }
        }
      }
      isPlaying = true
    }
  }

  fun attachVideo(vv: VideoView, videoUri: Uri, audioFile: File) {
    videoViewRef = vv
    vv.setVideoURI(videoUri)
    vv.setOnPreparedListener { mp ->
      mp.setVolume(0f, 0f)
      durationMs = mp.duration.coerceAtLeast(1)
      val seekTarget = pendingSeekMs
      val autoPlay = pendingAutoPlay
      pendingSeekMs = 0
      pendingAutoPlay = false

      val player = MediaPlayer().apply {
        setDataSource(audioFile.absolutePath)
        prepare()
      }
      mediaPlayerRef = player

      if (autoPlay) {
        if (seekTarget > 0) vv.seekTo(seekTarget)
        if (seekTarget < player.duration) {
          player.seekTo(seekTarget)
          player.start()
        }
        vv.start()
        isPlaying = true
      } else {
        val pos = if (seekTarget > 0) seekTarget else 100
        vv.seekTo(pos)
        currentPosMs = seekTarget
        isPlaying = false
      }
    }
    vv.setOnCompletionListener {
      isPlaying = false
      currentPosMs = durationMs
      runCatching { if (mediaPlayerRef?.isPlaying == true) mediaPlayerRef?.pause() }
    }
  }

  fun playFromStart(videoUri: Uri, audioFile: File) {
    stopPlayback()
    pendingSeekMs = 0
    pendingAutoPlay = true
    videoViewRef?.let { attachVideo(it, videoUri, audioFile) }
  }

  fun setFullScreenMode(enable: Boolean) {
    val curPos = runCatching { videoViewRef?.currentPosition ?: currentPosMs }.getOrDefault(currentPosMs)
    val wasPlaying = isPlaying
    stopPlayback()
    pendingSeekMs = curPos
    pendingAutoPlay = wasPlaying
    isFullScreen = enable
  }

  LaunchedEffect(isPlaying, isSeeking) {
    while (isPlaying) {
      if (!isSeeking) {
        val pos = runCatching { videoViewRef?.currentPosition ?: currentPosMs }.getOrDefault(currentPosMs)
        currentPosMs = pos
      }
      delay(250)
    }
  }

  val currentResult = result
  val currentVideo = selectedVideoUri

  if (isFullScreen && currentResult != null && currentVideo != null) {
    FullScreenVideoPlayer(
      activity = activity,
      videoUri = currentVideo,
      audioFile = currentResult.dubbedAudioFile,
      isPlaying = isPlaying,
      currentPosMs = currentPosMs,
      durationMs = durationMs,
      onAttachVideo = { vv, uri, file -> attachVideo(vv, uri, file) },
      onTogglePlayPause = {
        if (mediaPlayerRef == null) playFromStart(currentVideo, currentResult.dubbedAudioFile)
        else togglePlayPause()
      },
      onSeekTo = { seekBoth(it) },
      onExit = { setFullScreenMode(false) }
    )
    return
  }

  Column(
    modifier = Modifier
      .fillMaxSize()
      .verticalScroll(rememberScrollState())
      .padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp)
  ) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(12.dp),
      modifier = Modifier.fillMaxWidth()
    ) {
      Image(
        painter = painterResource(id = R.drawable.app_logo),
        contentDescription = "VT Logo",
        contentScale = ContentScale.Crop,
        modifier = Modifier.size(64.dp).clip(RoundedCornerShape(14.dp))
      )
      Column {
        Text("VT অফলাইন AI ডাবিং", style = MaterialTheme.typography.headlineSmall)
        Text("১০০% ফ্রি ও অফলাইন (Whisper Base + VAD)", style = MaterialTheme.typography.bodySmall)
      }
    }

    Button(
      onClick = { pickVideoLauncher.launch(arrayOf("video/*")) },
      enabled = !isProcessing,
      modifier = Modifier.fillMaxWidth()
    ) {
      Text(if (selectedVideoUri == null) "১. ভিডিও সিলেক্ট করুন" else "অন্য ভিডিও সিলেক্ট করুন")
    }

    Text("২. ভিডিওতে কোন ভাষায় কথা বলা হচ্ছে?", style = MaterialTheme.typography.titleMedium)
    Box(modifier = Modifier.fillMaxWidth()) {
      OutlinedButton(
        onClick = { if (!isProcessing) showSourceMenu = true },
        modifier = Modifier.fillMaxWidth()
      ) { Text("ভিডিওর ভাষা: ${sourceLang.label}") }
      DropdownMenu(expanded = showSourceMenu, onDismissRequest = { showSourceMenu = false }) {
        SourceLanguage.entries.forEach { src ->
          DropdownMenuItem(
            text = { Text(src.label) },
            onClick = { sourceLang = src; showSourceMenu = false }
          )
        }
      }
    }

    Text("৩. কোন ভাষায় শুনতে চান?", style = MaterialTheme.typography.titleMedium)
    Column {
      TargetLanguage.entries.forEach { lang ->
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
          RadioButton(selected = (selectedLang == lang), onClick = { if (!isProcessing) selectedLang = lang })
          Text(lang.label, modifier = Modifier.padding(top = 12.dp))
        }
      }
    }

    Button(
      onClick = {
        val uri = selectedVideoUri ?: return@Button
        stopPlayback()
        isProcessing = true
        progress = 0f
        scope.launch {
          try {
            val res = engine.processVideo(uri, sourceLang, selectedLang) { p, msg ->
              progress = p
              statusText = msg
            }
            result = res
          } catch (e: Exception) {
            statusText = "ত্রুটি: ${e.localizedMessage ?: "প্রসেস করা যায়নি"}"
          } finally {
            isProcessing = false
          }
        }
      },
      enabled = selectedVideoUri != null && !isProcessing,
      modifier = Modifier.fillMaxWidth()
    ) { Text(if (isProcessing) "কাজ চলছে..." else "৪. অফলাইন রূপান্তর শুরু করুন") }

    if (isProcessing) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
    Text(statusText, style = MaterialTheme.typography.bodyMedium)

    if (currentResult != null && currentVideo != null) {
      HorizontalDivider()
      Text("ডাবিং সম্পন্ন!", style = MaterialTheme.typography.titleMedium)

      AndroidView(
        factory = { ctx ->
          FrameLayout(ctx).apply {
            setBackgroundColor(android.graphics.Color.BLACK)
            val vv = VideoView(ctx).apply {
              layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER
              )
            }
            addView(vv)
            attachVideo(vv, currentVideo, currentResult.dubbedAudioFile)
          }
        },
        modifier = Modifier.fillMaxWidth().height(360.dp).clip(RoundedCornerShape(12.dp))
      )

      Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(formatTimeMs(if (isSeeking) sliderPosMs.toInt() else currentPosMs), style = MaterialTheme.typography.bodySmall)
        Slider(
          value = if (isSeeking) sliderPosMs else currentPosMs.toFloat(),
          onValueChange = { isSeeking = true; sliderPosMs = it },
          onValueChangeFinished = { seekBoth(sliderPosMs.toInt()); isSeeking = false },
          valueRange = 0f..durationMs.coerceAtLeast(1000).toFloat(),
          modifier = Modifier.weight(1f).padding(horizontal = 8.dp)
        )
        Text(formatTimeMs(durationMs), style = MaterialTheme.typography.bodySmall)
      }

      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
          onClick = { if (mediaPlayerRef == null) playFromStart(currentVideo, currentResult.dubbedAudioFile) else togglePlayPause() },
          modifier = Modifier.weight(1f)
        ) { Text(if (isPlaying) "⏸ বিরতি" else "▶ শুনুন ও দেখুন") }
        OutlinedButton(
          onClick = { stopPlayback(); seekBoth(0) },
          modifier = Modifier.weight(1f)
        ) { Text("⏹ থামান") }
      }

      Button(
        onClick = { setFullScreenMode(true) },
        modifier = Modifier.fillMaxWidth()
      ) { Text("⛶ ফুল স্ক্রিন (ঘোরানো ও ব্রাইটনেস সহ)") }

      OutlinedButton(
        onClick = { saveAudioLauncher.launch("dubbed_${selectedLang.mlKitCode}.wav") },
        modifier = Modifier.fillMaxWidth()
      ) { Text("💾 অনুবাদ করা অডিও সেভ করুন (.wav)") }

      Card(modifier = Modifier.fillMaxWidth()) {
        Text(currentResult.transcriptText, modifier = Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall)
      }
    }
  }
}
EOF
