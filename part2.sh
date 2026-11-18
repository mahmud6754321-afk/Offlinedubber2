set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > gradle.properties
org.gradle.jvmargs=-Xmx4096m -Dfile.encoding=UTF-8
android.useAndroidX=true
android.nonTransitiveRClass=true
EOF

cat << 'EOF' > settings.gradle.kts
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
rootProject.name = "OfflineVideoDubber"
include(":app")
EOF

cat << 'EOF' > build.gradle.kts
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}
EOF

cat << 'EOF' > app/build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.offline.videodubber"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.offline.videodubber"
        minSdk = 24
        targetSdk = 35
        versionCode = 4
        versionName = "4.0"

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    androidResources {
        noCompress += listOf("onnx", "txt")
    }
}

dependencies {
    implementation("com.github.k2-fsa:sherpa-onnx:v1.13.1")
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:language-id:17.0.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.8.1")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
}
EOF

cat << 'EOF' > app/src/main/AndroidManifest.xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />

    <queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
    </queries>

    <application
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:label="VT ভিডিও ট্রান্সলেটর"
        android:supportsRtl="true"
        android:theme="@android:style/Theme.Material.Light.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

cat << 'EOF' > app/src/main/java/com/offline/videodubber/MainActivity.kt
package com.offline.videodubber

import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.Toast
import android.widget.VideoView
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var engine: OfflineDubberEngine

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        engine = OfflineDubberEngine(applicationContext)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    DubberScreen(engine)
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        engine.release()
    }
}

@Composable
fun DubberScreen(engine: OfflineDubberEngine) {
    val context = LocalContext.current
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
        runCatching {
            videoViewRef?.pause()
            mediaPlayerRef?.stop()
            mediaPlayerRef?.release()
            mediaPlayerRef = null
        }
    }

    fun attachVideo(vv: VideoView, videoUri: Uri, audioFile: File) {
        vv.setVideoURI(videoUri)
        vv.setOnPreparedListener { mp ->
            mp.setVolume(0f, 0f)
            val seekTarget = pendingSeekMs
            val autoPlay = pendingAutoPlay
            pendingSeekMs = 0
            pendingAutoPlay = false
            if (autoPlay) {
                val player = MediaPlayer().apply {
                    setDataSource(audioFile.absolutePath)
                    prepare()
                    if (seekTarget > 0 && seekTarget < duration) seekTo(seekTarget)
                    start()
                }
                mediaPlayerRef = player
                if (seekTarget > 0) vv.seekTo(seekTarget)
                vv.start()
            } else {
                vv.seekTo(if (seekTarget > 0) seekTarget else 100)
            }
        }
    }

    fun playSynced(videoUri: Uri, audioFile: File) {
        stopPlayback()
        pendingSeekMs = 0
        pendingAutoPlay = true
        videoViewRef?.let { attachVideo(it, videoUri, audioFile) }
    }

    fun toggleFullScreen(enable: Boolean) {
        val curPos = runCatching { videoViewRef?.currentPosition ?: 0 }.getOrDefault(0)
        val wasPlaying = runCatching { mediaPlayerRef?.isPlaying == true }.getOrDefault(false)
        stopPlayback()
        pendingSeekMs = curPos
        pendingAutoPlay = wasPlaying
        isFullScreen = enable
    }

    BackHandler(enabled = isFullScreen) {
        toggleFullScreen(false)
    }

    val currentResult = result
    val currentVideo = selectedVideoUri

    if (isFullScreen && currentResult != null && currentVideo != null) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
        ) {
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
                        videoViewRef = vv
                        attachVideo(vv, currentVideo, currentResult.dubbedAudioFile)
                    }
                },
                modifier = Modifier.fillMaxSize()
            )

            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.65f))
                    .padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = { playSynced(currentVideo, currentResult.dubbedAudioFile) },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("▶ শুনুন")
                }
                OutlinedButton(
                    onClick = { stopPlayback() },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White),
                    modifier = Modifier.weight(1f)
                ) {
                    Text("⏹ থামান")
                }
                Button(
                    onClick = { toggleFullScreen(false) },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("✕ ছোট করুন")
                }
            }
        }
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
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(14.dp))
            )
            Column {
                Text(
                    text = "VT অফলাইন AI ডাবিং",
                    style = MaterialTheme.typography.headlineSmall
                )
                Text(
                    text = "১০০% ফ্রি ও অফলাইন (Whisper Base + VAD)",
                    style = MaterialTheme.typography.bodySmall
                )
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
            ) {
                Text("ভিডিওর ভাষা: ${sourceLang.label}")
            }
            DropdownMenu(
                expanded = showSourceMenu,
                onDismissRequest = { showSourceMenu = false }
            ) {
                SourceLanguage.entries.forEach { src ->
                    DropdownMenuItem(
                        text = { Text(src.label) },
                        onClick = {
                            sourceLang = src
                            showSourceMenu = false
                        }
                    )
                }
            }
        }

        Text("৩. কোন ভাষায় শুনতে চান?", style = MaterialTheme.typography.titleMedium)
        Column {
            TargetLanguage.entries.forEach { lang ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Start
                ) {
                    RadioButton(
                        selected = (selectedLang == lang),
                        onClick = { if (!isProcessing) selectedLang = lang }
                    )
                    Text(
                        text = lang.label,
                        modifier = Modifier.padding(top = 12.dp)
                    )
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
        ) {
            Text(if (isProcessing) "কাজ চলছে..." else "৪. অফলাইন রূপান্তর শুরু করুন")
        }

        if (isProcessing) {
            LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
        }
        Text(text = statusText, style = MaterialTheme.typography.bodyMedium)

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
                        videoViewRef = vv
                        attachVideo(vv, currentVideo, currentResult.dubbedAudioFile)
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(380.dp)
                    .clip(RoundedCornerShape(12.dp))
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { playSynced(currentVideo, currentResult.dubbedAudioFile) },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("▶ শুনুন ও দেখুন")
                }
                OutlinedButton(
                    onClick = { stopPlayback() },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("⏹ থামান")
                }
            }

            Button(
                onClick = { toggleFullScreen(true) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("⛶ ফুল স্ক্রিন (বড় পর্দায় দেখুন)")
            }

            OutlinedButton(
                onClick = { saveAudioLauncher.launch("dubbed_${selectedLang.mlKitCode}.wav") },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("💾 অনুবাদ করা অডিও সেভ করুন (.wav)")
            }

            Card(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = currentResult.transcriptText,
                    modifier = Modifier.padding(12.dp),
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}
EOF
