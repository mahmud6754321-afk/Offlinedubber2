set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > app/src/main/java/com/offline/videodubber/MainActivity.kt
package com.offline.videodubber

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.Toast
import android.widget.VideoView
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

class MainActivity : ComponentActivity() {
  private lateinit var engine: OfflineDubberEngine
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    engine = OfflineDubberEngine(applicationContext)
    setContent { VtProTheme { Surface(modifier = Modifier.fillMaxSize(), color = VtBg) { DubberScreen(engine) } } }
  }
  override fun onDestroy() { super.onDestroy(); engine.release() }
}

fun formatTimeMs(ms: Int): String {
  val secTotal = (ms / 1000).coerceAtLeast(0)
  return String.format(Locale.US, "%02d:%02d", secTotal / 60, secTotal % 60)
}

@Composable
fun DubberScreen(engine: OfflineDubberEngine) {
  val context = LocalContext.current
  val activity = context as? Activity
  val clipboard = LocalClipboardManager.current
  val scope = rememberCoroutineScope()

  var showSplash by remember { mutableStateOf(true) }
  LaunchedEffect(Unit) { delay(1100); showSplash = false }

  var selectedVideoUri by remember { mutableStateOf<Uri?>(null) }
  var sourceLang by remember { mutableStateOf(SourceLanguage.AUTO) }
  var showSourceMenu by remember { mutableStateOf(false) }
  var selectedLang by remember { mutableStateOf(TargetLanguage.BENGALI) }
  var isProcessing by remember { mutableStateOf(false) }
  var progress by remember { mutableFloatStateOf(0f) }
  var statusText by remember { mutableStateOf("শুরু করতে একটি ভিডিও নির্বাচন করুন") }
  var result by remember { mutableStateOf<DubbingResult?>(null) }

  var showProSettings by remember { mutableStateOf(false) }
  var speechRate by remember { mutableFloatStateOf(1.0f) }
  var pitch by remember { mutableFloatStateOf(1.0f) }
  var bgVolume by remember { mutableFloatStateOf(0.0f) }
  var showSubtitles by remember { mutableStateOf(true) }

  var showHistoryDialog by remember { mutableStateOf(false) }
  var historyList by remember { mutableStateOf(HistoryStore.load(context)) }
  var showEditDialog by remember { mutableStateOf(false) }

  var isFullScreen by remember { mutableStateOf(false) }
  var isPlaying by remember { mutableStateOf(false) }
  var durationMs by remember { mutableIntStateOf(0) }
  var currentPosMs by remember { mutableIntStateOf(0) }
  var isSeeking by remember { mutableStateOf(false) }
  var sliderPosMs by remember { mutableFloatStateOf(0f) }
  var pendingSeekMs by remember { mutableIntStateOf(0) }
  var pendingAutoPlay by remember { mutableStateOf(false) }

  var videoViewRef by remember { mutableStateOf<VideoView?>(null) }
  var videoMpRef by remember { mutableStateOf<MediaPlayer?>(null) }
  var mediaPlayerRef by remember { mutableStateOf<MediaPlayer?>(null) }

  val projectionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
    val data = res.data
    if (res.resultCode == Activity.RESULT_OK && data != null) {
      ContextCompat.startForegroundService(context, FloatingLiveService.createStartIntent(context, res.resultCode, data, sourceLang, selectedLang))
      Toast.makeText(context, "ফ্লোটিং লাইভ চালু হয়েছে!", Toast.LENGTH_LONG).show()
    }
  }

  fun launchProjection() {
    val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    Toast.makeText(context, "'Entire screen' সিলেক্ট করে অনুমোদন দিন", Toast.LENGTH_SHORT).show()
    projectionLauncher.launch(mgr.createScreenCaptureIntent())
  }

  val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { g ->
    if (g[Manifest.permission.RECORD_AUDIO] == true) launchProjection()
    else Toast.makeText(context, "Microphone পারমিশন প্রয়োজন।", Toast.LENGTH_SHORT).show()
  }

  fun startFloatingLiveFlow() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    if (!Settings.canDrawOverlays(context)) {
      Toast.makeText(context, "'Display over other apps' চালু করুন", Toast.LENGTH_LONG).show()
      context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")))
      return
    }
    val need = mutableListOf<String>()
    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.RECORD_AUDIO)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.POST_NOTIFICATIONS)
    if (need.isNotEmpty()) permLauncher.launch(need.toTypedArray()) else launchProjection()
  }

  val pickVideoLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
    if (uri != null) {
      runCatching { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
      selectedVideoUri = uri; result = null; isFullScreen = false; statusText = "ভিডিও নির্বাচিত হয়েছে। এবার রূপান্তর শুরু করুন।"
    }
  }

  val saveAudioLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("audio/wav")) { saveUri ->
    val src = result?.dubbedAudioFile
    if (saveUri != null && src != null && src.exists()) {
      context.contentResolver.openOutputStream(saveUri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
      Toast.makeText(context, "অডিও সেভ হয়েছে!", Toast.LENGTH_SHORT).show()
    }
  }

  val saveSrtLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { saveUri ->
    val r = result ?: return@rememberLauncherForActivityResult
    if (saveUri != null) {
      context.contentResolver.openOutputStream(saveUri)?.use { it.write(buildSrtContent(r.cues).toByteArray()) }
      Toast.makeText(context, "সাবটাইটেল (.srt) সেভ হয়েছে!", Toast.LENGTH_SHORT).show()
    }
  }

  val saveMp4Launcher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("video/mp4")) { saveUri ->
    val vUri = selectedVideoUri; val r = result
    if (saveUri != null && vUri != null && r != null && r.dubbedAudioFile.exists()) {
      isProcessing = true; statusText = "বাংলা ভয়েসসহ .mp4 ভিডিও তৈরি হচ্ছে..."
      scope.launch {
        try {
          val tmpMp4 = File(context.cacheDir, "export_dubbed.mp4")
          withContext(Dispatchers.IO) {
            Mp4DubbedExporter.exportDubbedMp4(context, vUri, r.dubbedAudioFile, tmpMp4)
            context.contentResolver.openOutputStream(saveUri)?.use { out -> tmpMp4.inputStream().use { it.copyTo(out) } }
            tmpMp4.delete()
          }
          statusText = "সম্পূর্ণ .mp4 ভিডিও সেভ সম্পন্ন!"
          Toast.makeText(context, "ভিডিও সেভ হয়েছে!", Toast.LENGTH_LONG).show()
        } catch (e: Exception) { statusText = "ত্রুটি: ${e.localizedMessage}" } finally { isProcessing = false }
      }
    }
  }

  fun stopPlayback() {
    isPlaying = false
    runCatching { videoViewRef?.pause(); mediaPlayerRef?.stop(); mediaPlayerRef?.release(); mediaPlayerRef = null }
  }

  fun seekBoth(targetMs: Int) {
    val safeMs = targetMs.coerceIn(0, durationMs.coerceAtLeast(0))
    currentPosMs = safeMs; runCatching { videoViewRef?.seekTo(safeMs) }
    runCatching {
      mediaPlayerRef?.let { mp ->
        if (safeMs < mp.duration) { mp.seekTo(safeMs); if (isPlaying && !mp.isPlaying) mp.start() } else if (mp.isPlaying) mp.pause()
      }
    }
  }

  fun togglePlayPause() {
    val vv = videoViewRef ?: return
    if (isPlaying) {
      runCatching { vv.pause() }; runCatching { if (mediaPlayerRef?.isPlaying == true) mediaPlayerRef?.pause() }; isPlaying = false
    } else {
      var cur = runCatching { vv.currentPosition }.getOrDefault(currentPosMs)
      if (durationMs > 500 && cur >= durationMs - 300) { cur = 0; seekBoth(0) }
      runCatching { vv.start() }
      runCatching { mediaPlayerRef?.let { mp -> if (cur < mp.duration) { mp.seekTo(cur); mp.start() } } }
      isPlaying = true
    }
  }

  fun attachVideo(vv: VideoView, videoUri: Uri, audioFile: File) {
    videoViewRef = vv; vv.setVideoURI(videoUri)
    vv.setOnPreparedListener { mp ->
      videoMpRef = mp; mp.setVolume(bgVolume, bgVolume); durationMs = mp.duration.coerceAtLeast(1)
      val seekTarget = pendingSeekMs; val autoPlay = pendingAutoPlay; pendingSeekMs = 0; pendingAutoPlay = false
      val player = MediaPlayer().apply { setDataSource(audioFile.absolutePath); prepare() }
      mediaPlayerRef = player
      if (autoPlay) {
        if (seekTarget > 0) vv.seekTo(seekTarget)
        if (seekTarget < player.duration) { player.seekTo(seekTarget); player.start() }
        vv.start(); isPlaying = true
      } else { vv.seekTo(if (seekTarget > 0) seekTarget else 100); currentPosMs = seekTarget; isPlaying = false }
    }
    vv.setOnCompletionListener { isPlaying = false; currentPosMs = durationMs; runCatching { if (mediaPlayerRef?.isPlaying == true) mediaPlayerRef?.pause() } }
  }

  fun playFromStart(videoUri: Uri, audioFile: File) { stopPlayback(); pendingSeekMs = 0; pendingAutoPlay = true; videoViewRef?.let { attachVideo(it, videoUri, audioFile) } }
  fun setFullScreenMode(enable: Boolean) {
    val curPos = runCatching { videoViewRef?.currentPosition ?: currentPosMs }.getOrDefault(currentPosMs)
    val wasPlaying = isPlaying; stopPlayback(); pendingSeekMs = curPos; pendingAutoPlay = wasPlaying; isFullScreen = enable
  }

  LaunchedEffect(bgVolume) { runCatching { videoMpRef?.setVolume(bgVolume, bgVolume) } }
  LaunchedEffect(isPlaying, isSeeking) {
    while (isPlaying) { if (!isSeeking) currentPosMs = runCatching { videoViewRef?.currentPosition ?: currentPosMs }.getOrDefault(currentPosMs); delay(250) }
  }

  if (showSplash) {
    Box(modifier = Modifier.fillMaxSize().background(VtBg), contentAlignment = Alignment.Center) {
      Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Image(painter = painterResource(id = R.drawable.app_logo), contentDescription = "VT", contentScale = ContentScale.Crop,
          modifier = Modifier.size(120.dp).clip(RoundedCornerShape(26.dp)).border(2.dp, VtGold, RoundedCornerShape(26.dp)))
        Text("VT ভিডিও ট্রান্সলেটর PRO", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = VtGold)
        Text("১০০% অফলাইন AI ডাবিং ও লাইভ স্টুডিও", style = MaterialTheme.typography.bodySmall, color = VtSubText)
      }
    }
    return
  }

  val currentResult = result; val currentVideo = selectedVideoUri
  if (isFullScreen && currentResult != null && currentVideo != null) {
    FullScreenVideoPlayer(
      activity, currentVideo, currentResult.dubbedAudioFile, currentResult.cues, showSubtitles, isPlaying, currentPosMs, durationMs,
      { showSubtitles = !showSubtitles }, { vv, u, f -> attachVideo(vv, u, f) },
      { if (mediaPlayerRef == null) playFromStart(currentVideo, currentResult.dubbedAudioFile) else togglePlayPause() },
      { seekBoth(it) }, { setFullScreenMode(false) }
    )
    return
  }

  Column(modifier = Modifier.fillMaxSize().background(VtBg).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    VtProHeader(
      onOpenHistory = { historyList = HistoryStore.load(context); showHistoryDialog = true },
      onToggleSettings = { showProSettings = !showProSettings }
    )

    if (showProSettings) {
      ProSettingsCard(speechRate, { speechRate = it }, pitch, { pitch = it }, bgVolume, { bgVolume = it }, showSubtitles, { showSubtitles = it }) {
        runCatching { context.startActivity(Intent("com.android.settings.TTS_SETTINGS")) }
      }
    }

    Card(colors = CardDefaults.cardColors(containerColor = VtCard), border = BorderStroke(1.dp, Color(0xFF2E2E42))) {
      Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
          Icon(Icons.Rounded.Translate, null, tint = VtGold, modifier = Modifier.size(18.dp))
          Text("১. ভিডিওর মূল ভাষা", color = VtGold, style = MaterialTheme.typography.labelLarge)
        }
        Box(modifier = Modifier.fillMaxWidth()) {
          OutlinedButton(onClick = { if (!isProcessing) showSourceMenu = true }, modifier = Modifier.fillMaxWidth()) { Text(sourceLang.label, color = VtText) }
          DropdownMenu(expanded = showSourceMenu, onDismissRequest = { showSourceMenu = false }) {
            SourceLanguage.entries.forEach { src -> DropdownMenuItem(text = { Text(src.label) }, onClick = { sourceLang = src; showSourceMenu = false }) }
          }
        }
        Text("২. কোন ভাষায় দেখতে/শুনতে চান?", color = VtGold, style = MaterialTheme.typography.labelLarge)
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
          TargetLanguage.entries.forEach { lang ->
            FilterChip(selected = (selectedLang == lang), onClick = { if (!isProcessing) selectedLang = lang }, label = { Text(lang.label.substringBefore(" ")) })
          }
        }
      }
    }

    Card(colors = CardDefaults.cardColors(containerColor = VtCardAlt), border = BorderStroke(1.dp, VtRed)) {
      Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
          Icon(Icons.Rounded.LiveTv, null, tint = VtRed, modifier = Modifier.size(20.dp))
          Text("ফ্লোটিং লাইভ স্টুডিও (YouTube / Chrome)", color = VtGold, style = MaterialTheme.typography.titleSmall)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          Button(onClick = { startFloatingLiveFlow() }, enabled = !isProcessing, colors = ButtonDefaults.buttonColors(containerColor = VtRed, contentColor = Color.White), modifier = Modifier.weight(1.3f)) {
            Icon(Icons.Rounded.PlayArrow, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text("লাইভ চালু")
          }
          OutlinedButton(onClick = { context.stopService(Intent(context, FloatingLiveService::class.java)) }, modifier = Modifier.weight(1f)) {
            Icon(Icons.Rounded.Stop, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text("বন্ধ")
          }
        }
      }
    }

    Button(onClick = { pickVideoLauncher.launch(arrayOf("video/*")) }, enabled = !isProcessing, modifier = Modifier.fillMaxWidth()) {
      Icon(Icons.Rounded.VideoLibrary, null, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp))
      Text(if (selectedVideoUri == null) "৩. গ্যালারি থেকে ভিডিও সিলেক্ট করুন" else "অন্য ভিডিও সিলেক্ট করুন")
    }

    Button(
      onClick = {
        val uri = selectedVideoUri ?: return@Button
        stopPlayback(); isProcessing = true; progress = 0f
        scope.launch {
          try {
            val res = engine.processVideo(uri, sourceLang, selectedLang, speechRate, pitch) { p, msg -> progress = p; statusText = msg }
            result = res
            HistoryStore.saveNew(context, HistoryEntry(System.currentTimeMillis(), uri.lastPathSegment ?: "ভিডিও", uri.toString(), res.dubbedAudioFile.absolutePath, selectedLang.label, res.headerInfo, res.cues))
          } catch (e: Exception) { statusText = "ত্রুটি: ${e.localizedMessage}" } finally { isProcessing = false }
        }
      },
      enabled = selectedVideoUri != null && !isProcessing, modifier = Modifier.fillMaxWidth()
    ) {
      Icon(Icons.Rounded.AutoAwesome, null, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp))
      Text(if (isProcessing) "প্রসেস চলছে..." else "৪. অফলাইন প্রো ডাবিং শুরু করুন")
    }

    if (isProcessing) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
    Text(statusText, color = VtSubText, style = MaterialTheme.typography.bodySmall)

    if (currentResult != null && currentVideo != null) {
      val activeCue = currentResult.cues.firstOrNull { currentPosMs in it.startMs..it.endMs }
      key(currentVideo, currentResult.dubbedAudioFile) {
        Box(modifier = Modifier.fillMaxWidth().height(340.dp).clip(RoundedCornerShape(14.dp)).border(1.5.dp, VtGold, RoundedCornerShape(14.dp))) {
          AndroidView(
            factory = { ctx ->
              FrameLayout(ctx).apply {
                setBackgroundColor(android.graphics.Color.BLACK)
                val vv = VideoView(ctx).apply { layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER) }
                addView(vv); attachVideo(vv, currentVideo, currentResult.dubbedAudioFile)
              }
            },
            modifier = Modifier.fillMaxSize()
          )
          if (showSubtitles && activeCue != null) {
            Box(modifier = Modifier.align(Alignment.BottomCenter).padding(10.dp).background(Color.Black.copy(alpha = 0.78f), RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 6.dp)) {
              Text(activeCue.trans, color = VtGold, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
            }
          }
        }
      }

      Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(formatTimeMs(if (isSeeking) sliderPosMs.toInt() else currentPosMs), color = VtText, style = MaterialTheme.typography.bodySmall)
        Slider(value = if (isSeeking) sliderPosMs else currentPosMs.toFloat(), onValueChange = { isSeeking = true; sliderPosMs = it },
          onValueChangeFinished = { seekBoth(sliderPosMs.toInt()); isSeeking = false }, valueRange = 0f..durationMs.coerceAtLeast(1000).toFloat(), modifier = Modifier.weight(1f).padding(horizontal = 8.dp))
        Text(formatTimeMs(durationMs), color = VtText, style = MaterialTheme.typography.bodySmall)
      }

      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { if (mediaPlayerRef == null) playFromStart(currentVideo, currentResult.dubbedAudioFile) else togglePlayPause() }, modifier = Modifier.weight(1f)) {
          Icon(if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, null, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(4.dp))
          Text(if (isPlaying) "বিরতি" else "শুনুন ও দেখুন")
        }
        OutlinedButton(onClick = { stopPlayback(); seekBoth(0) }, modifier = Modifier.weight(0.75f)) {
          Icon(Icons.Rounded.Stop, null, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(4.dp)); Text("থামান")
        }
      }

      Button(onClick = { setFullScreenMode(true) }, modifier = Modifier.fillMaxWidth()) {
        Icon(Icons.Rounded.Fullscreen, null, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(6.dp)); Text("ফুল স্ক্রিন (সাবটাইটেল, ব্রাইটনেস, ঘোরানো)")
      }
      Button(onClick = { saveMp4Launcher.launch("VT_Dubbed_${System.currentTimeMillis()}.mp4") }, enabled = !isProcessing,
        colors = ButtonDefaults.buttonColors(containerColor = VtRed, contentColor = Color.White), modifier = Modifier.fillMaxWidth()) {
        Icon(Icons.Rounded.Movie, null, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text("সম্পূর্ণ ডাবিং ভিডিও সেভ করুন (.mp4)")
      }

      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { saveAudioLauncher.launch("VT_Audio_${selectedLang.mlKitCode}.wav") }, modifier = Modifier.weight(1f)) {
          Icon(Icons.Rounded.AudioFile, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text(".wav অডিও")
        }
        OutlinedButton(onClick = { saveSrtLauncher.launch("VT_Sub_${selectedLang.mlKitCode}.srt") }, modifier = Modifier.weight(1f)) {
          Icon(Icons.Rounded.Subtitles, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text(".srt ফাইল")
        }
      }

      Card(colors = CardDefaults.cardColors(containerColor = VtCard), border = BorderStroke(1.dp, Color(0xFF2E2E42)), modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
          Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { clipboard.setText(AnnotatedString(currentResult.transcriptText)); Toast.makeText(context, "কপি হয়েছে!", Toast.LENGTH_SHORT).show() }, modifier = Modifier.weight(1f)) {
              Icon(Icons.Rounded.ContentCopy, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text("কপি")
            }
            OutlinedButton(onClick = { showEditDialog = true }, modifier = Modifier.weight(1f)) {
              Icon(Icons.Rounded.Edit, null, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text("এডিট ভয়েস")
            }
          }
          Text(currentResult.transcriptText, color = VtSubText, style = MaterialTheme.typography.bodySmall)
        }
      }
    }
  }

  if (showEditDialog && currentResult != null) {
    EditTranscriptDialog(currentResult.cues.joinToString("\n") { it.trans }, { showEditDialog = false }) { edited ->
      val lines = edited.lines().filter { it.isNotBlank() }
      val updatedCues = currentResult.cues.mapIndexed { i, c -> c.copy(trans = lines.getOrElse(i) { c.trans }) }
      showEditDialog = false; stopPlayback(); isProcessing = true; statusText = "এডিট করা লেখা থেকে নতুন ভয়েস তৈরি হচ্ছে..."
      scope.launch {
        try { result = engine.reSynthesizeFromCues(updatedCues, currentResult.headerInfo, selectedLang, speechRate, pitch); statusText = "নতুন ভয়েস তৈরি সম্পন্ন!" }
        catch (e: Exception) { statusText = "ত্রুটি: ${e.localizedMessage}" } finally { isProcessing = false }
      }
    }
  }

  if (showHistoryDialog) {
    HistoryDialog(historyList, { item ->
      val audioF = File(item.audioPath)
      if (audioF.exists()) {
        stopPlayback(); selectedVideoUri = Uri.parse(item.videoUri); result = DubbingResult(audioF, item.cues, item.headerInfo)
        statusText = "হিস্ট্রি থেকে লোড হয়েছে: ${item.title}"; showHistoryDialog = false
      } else Toast.makeText(context, "অডিও ফাইলটি পাওয়া যায়নি।", Toast.LENGTH_SHORT).show()
    }, { showHistoryDialog = false })
  }
}
EOF
