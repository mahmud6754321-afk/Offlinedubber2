set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > app/src/main/java/com/offline/videodubber/FloatingLiveService.kt
package com.offline.videodubber

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlin.coroutines.resume
import kotlin.math.abs

class FloatingLiveService : Service() {

  companion object {
    private const val CHANNEL_ID = "vt_floating_live"
    private const val NOTIF_ID = 4041
    private const val EXTRA_CODE = "result_code"
    private const val EXTRA_DATA = "result_data"
    private const val EXTRA_SRC = "src_lang"
    private const val EXTRA_TGT = "tgt_lang"

    fun createStartIntent(ctx: Context, resultCode: Int, data: Intent, src: SourceLanguage, tgt: TargetLanguage): Intent =
      Intent(ctx, FloatingLiveService::class.java).apply {
        putExtra(EXTRA_CODE, resultCode); putExtra(EXTRA_DATA, data)
        putExtra(EXTRA_SRC, src.name); putExtra(EXTRA_TGT, tgt.name)
      }
  }

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var windowManager: WindowManager? = null
  private var expandedView: LinearLayout? = null
  private var miniBubble: ImageView? = null
  private var subtitleTv: TextView? = null
  private var origTv: TextView? = null

  private var mediaProjection: MediaProjection? = null
  private var audioRecord: AudioRecord? = null
  private var engine: OfflineDubberEngine? = null
  private var tts: TextToSpeech? = null
  private var ttsOfflineReady = false

  @Volatile private var voiceEnabled = false
  @Volatile private var paused = false
  @Volatile private var isSpeakingTts = false
  @Volatile private var running = false

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent == null) { stopSelf(); return START_NOT_STICKY }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val ch = NotificationChannel(CHANNEL_ID, "VT লাইভ অনুবাদ", NotificationManager.IMPORTANCE_LOW)
      getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
    }
    val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle("VT প্রো লাইভ চালু আছে")
      .setContentText("অন্য অ্যাপে ভিডিও চালালে অনুবাদ দেখাবে")
      .setSmallIcon(R.drawable.app_logo)
      .setOngoing(true)
      .build()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
    } else startForeground(NOTIF_ID, notif)

    val resultCode = intent.getIntExtra(EXTRA_CODE, 0)
    @Suppress("DEPRECATION") val data: Intent? = intent.getParcelableExtra(EXTRA_DATA)
    val srcLang = runCatching { SourceLanguage.valueOf(intent.getStringExtra(EXTRA_SRC) ?: "AUTO") }.getOrDefault(SourceLanguage.AUTO)
    val tgtLang = runCatching { TargetLanguage.valueOf(intent.getStringExtra(EXTRA_TGT) ?: "BENGALI") }.getOrDefault(TargetLanguage.BENGALI)

    if (data == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) { stopSelf(); return START_NOT_STICKY }
    showProOverlay(srcLang, tgtLang)
    startLiveCapture(resultCode, data, srcLang, tgtLang)
    return START_NOT_STICKY
  }

  private fun pillBtn(label: String, bgHex: String, txtColor: Int, d: Float, onClick: (TextView) -> Unit): TextView {
    return TextView(this).apply {
      text = label; textSize = 12f; setTextColor(txtColor); typeface = Typeface.DEFAULT_BOLD
      gravity = Gravity.CENTER
      setPadding((9 * d).toInt(), (5 * d).toInt(), (9 * d).toInt(), (5 * d).toInt())
      background = GradientDrawable().apply {
        setColor(Color.parseColor(bgHex)); cornerRadius = 18 * d
        setStroke((1 * d).toInt(), Color.parseColor("#44FFC107"))
      }
      val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
      lp.marginStart = (5 * d).toInt(); layoutParams = lp
      setOnClickListener { onClick(this) }
    }
  }

  @SuppressLint("ClickableViewAccessibility")
  private fun showProOverlay(srcLang: SourceLanguage, tgtLang: TargetLanguage) {
    if (expandedView != null) return
    val wm = getSystemService(WINDOW_SERVICE) as WindowManager
    windowManager = wm
    val d = resources.displayMetrics.density

    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding((12 * d).toInt(), (10 * d).toInt(), (12 * d).toInt(), (12 * d).toInt())
      background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(Color.parseColor("#F212121C"), Color.parseColor("#F20A0A10"))).apply {
        cornerRadius = 18 * d; setStroke((1.5f * d).toInt(), Color.parseColor("#FFC107"))
      }
    }

    val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    val logoIv = ImageView(this).apply {
      setImageResource(R.drawable.app_logo); scaleType = ImageView.ScaleType.CENTER_CROP; clipToOutline = true
      outlineProvider = object : ViewOutlineProvider() { override fun getOutline(v: View, o: Outline) { o.setOval(0, 0, v.width, v.height) } }
      layoutParams = LinearLayout.LayoutParams((28 * d).toInt(), (28 * d).toInt())
    }

    val titleTv = TextView(this).apply {
      text = " ● LIVE  ${srcLang.label.substringBefore(" ")} → ${tgtLang.label.substringBefore(" ")}"
      setTextColor(Color.parseColor("#FFC107")); textSize = 12f; typeface = Typeface.DEFAULT_BOLD
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }

    val pauseBtn = pillBtn("⏸", "#222233", Color.WHITE, d) { tv -> paused = !paused; tv.text = if (paused) "▶" else "⏸" }
    val voiceBtn = pillBtn("🔇", "#222233", Color.WHITE, d) { tv -> voiceEnabled = !voiceEnabled; tv.text = if (voiceEnabled) "🔊" else "🔇" }
    val minBtn = pillBtn("—", "#222233", Color.parseColor("#FFC107"), d) { expandedView?.visibility = View.GONE; miniBubble?.visibility = View.VISIBLE }
    val closeBtn = pillBtn("✕", "#B71C1C", Color.WHITE, d) { stopSelf() }

    header.addView(logoIv); header.addView(titleTv); header.addView(pauseBtn); header.addView(voiceBtn); header.addView(minBtn); header.addView(closeBtn)

    val divider = View(this).apply {
      setBackgroundColor(Color.parseColor("#33FFC107"))
      val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (1 * d).toInt())
      lp.topMargin = (7 * d).toInt(); lp.bottomMargin = (7 * d).toInt(); layoutParams = lp
    }

    val subTv = TextView(this).apply { text = "অপেক্ষা করছি... অন্য অ্যাপে ভিডিও চালান"; setTextColor(Color.WHITE); textSize = 15.5f; typeface = Typeface.DEFAULT_BOLD }
    val oTv = TextView(this).apply { text = "VT স্টুডিও প্রো (অফলাইন)"; setTextColor(Color.parseColor("#A5A8BC")); textSize = 11.5f; setPadding(0, (3 * d).toInt(), 0, 0) }
    subtitleTv = subTv; origTv = oTv
    root.addView(header); root.addView(divider); root.addView(subTv); root.addView(oTv)

    val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else {
      @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
    }
    val params = WindowManager.LayoutParams((324 * d).toInt(), WindowManager.LayoutParams.WRAP_CONTENT, layoutType,
      WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.START; x = (18 * d).toInt(); y = (120 * d).toInt() }

    var ix = 0; var iy = 0; var tx = 0f; var ty = 0f
    header.setOnTouchListener { _, ev ->
      when (ev.action) {
        MotionEvent.ACTION_DOWN -> { ix = params.x; iy = params.y; tx = ev.rawX; ty = ev.rawY; true }
        MotionEvent.ACTION_MOVE -> { params.x = ix + (ev.rawX - tx).toInt(); params.y = iy + (ev.rawY - ty).toInt(); runCatching { wm.updateViewLayout(root, params) }; true }
        else -> false
      }
    }

    val bubble = ImageView(this).apply {
      setImageResource(R.drawable.app_logo); scaleType = ImageView.ScaleType.CENTER_CROP; clipToOutline = true
      outlineProvider = object : ViewOutlineProvider() { override fun getOutline(v: View, o: Outline) { o.setOval(0, 0, v.width, v.height) } }
      background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setStroke((2 * d).toInt(), Color.parseColor("#FFC107")) }
      visibility = View.GONE
    }
    val bParams = WindowManager.LayoutParams((54 * d).toInt(), (54 * d).toInt(), layoutType,
      WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.START; x = (20 * d).toInt(); y = (220 * d).toInt() }

    var bix = 0; var biy = 0; var btx = 0f; var bty = 0f
    bubble.setOnTouchListener { _, ev ->
      when (ev.action) {
        MotionEvent.ACTION_DOWN -> { bix = bParams.x; biy = bParams.y; btx = ev.rawX; bty = ev.rawY; true }
        MotionEvent.ACTION_MOVE -> { bParams.x = bix + (ev.rawX - btx).toInt(); bParams.y = biy + (ev.rawY - bty).toInt(); runCatching { wm.updateViewLayout(bubble, bParams) }; true }
        MotionEvent.ACTION_UP -> { if (abs(ev.rawX - btx) < 12 && abs(ev.rawY - bty) < 12) { bubble.visibility = View.GONE; root.visibility = View.VISIBLE }; true }
        else -> false
      }
    }
    wm.addView(root, params); wm.addView(bubble, bParams)
    expandedView = root; miniBubble = bubble
  }

  @SuppressLint("MissingPermission")
  private fun startLiveCapture(resultCode: Int, data: Intent, srcLang: SourceLanguage, tgtLang: TargetLanguage) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return
    val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    val proj = mgr.getMediaProjection(resultCode, data) ?: return
    mediaProjection = proj
    proj.registerCallback(object : MediaProjection.Callback() { override fun onStop() { scope.launch { stopSelf() } } }, Handler(Looper.getMainLooper()))

    val captureConfig = AudioPlaybackCaptureConfiguration.Builder(proj)
      .addMatchingUsage(AudioAttributes.USAGE_MEDIA).addMatchingUsage(AudioAttributes.USAGE_GAME).addMatchingUsage(AudioAttributes.USAGE_UNKNOWN).build()
    val format = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
    val minBuf = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT).coerceAtLeast(4096)
    val recorder = AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(minBuf * 8).setAudioPlaybackCaptureConfig(captureConfig).build()
    if (recorder.state != AudioRecord.STATE_INITIALIZED) { subtitleTv?.text = "DRM লক করা অ্যাপের অডিও ধরা যাবে না"; return }

    audioRecord = recorder; val eng = OfflineDubberEngine(applicationContext); engine = eng; running = true; recorder.startRecording()
    val channel = Channel<FloatArray>(capacity = 250)

    scope.launch(Dispatchers.IO) {
      val buf = ShortArray(512)
      while (running) {
        val read = recorder.read(buf, 0, buf.size)
        if (read == 512 && !isSpeakingTts && !paused) channel.trySend(FloatArray(512) { i -> buf[i] / 32768.0f })
      }
      channel.close()
    }

    scope.launch(Dispatchers.IO) {
      runCatching { val (t, off) = eng.createTts(tgtLang.locale, true); tts = t; ttsOfflineReady = off }
      val vad = eng.createLiveVad()
      try {
        for (chunk in channel) {
          if (!running) break
          vad.acceptWaveform(chunk)
          while (!vad.empty() && running) {
            val seg = vad.front()
            if (seg.samples.size >= 4800 && !paused) {
              try {
                val res = eng.transcribeAndTranslateLive(seg.samples, srcLang, tgtLang)
                if (res != null) {
                  withContext(Dispatchers.Main) { subtitleTv?.text = res.second; origTv?.text = res.first }
                  if (voiceEnabled && tts != null) speakLive(res.second)
                }
              } catch (e: Exception) { withContext(Dispatchers.Main) { subtitleTv?.text = e.localizedMessage ?: "অনুবাদ ত্রুটি" } }
            }
            vad.pop()
          }
        }
      } finally { vad.release() }
    }
  }

  private suspend fun speakLive(text: String) {
    val engineTts = tts ?: return; isSpeakingTts = true
    try {
      withTimeoutOrNull(7_000L) {
        suspendCancellableCoroutine<Unit> { cont ->
          val id = "live_${System.currentTimeMillis()}"
          engineTts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(u: String?) {}
            override fun onDone(u: String?) { if (u == id && cont.isActive) cont.resume(Unit) }
            @Deprecated("Deprecated in Java") override fun onError(u: String?) { if (u == id && cont.isActive) cont.resume(Unit) }
            override fun onError(u: String?, err: Int) { if (u == id && cont.isActive) cont.resume(Unit) }
          })
          val params = Bundle().apply {
            if (ttsOfflineReady) {
              putString(TextToSpeech.Engine.KEY_FEATURE_EMBEDDED_SYNTHESIS, "true")
              putString(TextToSpeech.Engine.KEY_FEATURE_NETWORK_SYNTHESIS, "false")
            }
          }
          engineTts.speak(text, TextToSpeech.QUEUE_FLUSH, params, id)
        }
      }
      delay(300)
    } finally { isSpeakingTts = false }
  }

  override fun onDestroy() {
    running = false; scope.cancel()
    runCatching { audioRecord?.stop(); audioRecord?.release() }
    runCatching { mediaProjection?.stop() }
    runCatching { tts?.stop(); tts?.shutdown() }
    runCatching { engine?.release() }
    runCatching { expandedView?.let { windowManager?.removeView(it) } }
    runCatching { miniBubble?.let { windowManager?.removeView(it) } }
    expandedView = null; miniBubble = null; super.onDestroy()
  }
}
EOF
