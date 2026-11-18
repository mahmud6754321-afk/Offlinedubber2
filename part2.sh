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
    versionCode = 5
    versionName = "5.0"

    ndk {
      abiFilters += listOf("arm64-v8a", "armeabi-v7a")
    }
  }

  buildTypes {
    release { isMinifyEnabled = false }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }

  kotlinOptions { jvmTarget = "17" }
  buildFeatures { compose = true }
  androidResources { noCompress += listOf("onnx", "txt") }
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
      android:configChanges="orientation|screenSize|screenLayout|keyboardHidden"
      android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF

cat << 'EOF' > app/src/main/java/com/offline/videodubber/FullScreenVideoPlayer.kt
package com.offline.videodubber

import android.app.Activity
import android.content.pm.ActivityInfo
import android.net.Uri
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.VideoView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import java.io.File

@Composable
fun FullScreenVideoPlayer(
  activity: Activity?,
  videoUri: Uri,
  audioFile: File,
  isPlaying: Boolean,
  currentPosMs: Int,
  durationMs: Int,
  onAttachVideo: (VideoView, Uri, File) -> Unit,
  onTogglePlayPause: () -> Unit,
  onSeekTo: (Int) -> Unit,
  onExit: () -> Unit
) {
  var showControls by remember { mutableStateOf(true) }
  var showBrightnessBar by remember { mutableStateOf(false) }
  var isLandscape by remember { mutableStateOf(false) }
  var brightness by remember { mutableFloatStateOf(0.6f) }
  var isSeeking by remember { mutableStateOf(false) }
  var sliderPosMs by remember { mutableFloatStateOf(0f) }

  fun exitCleanly() {
    isLandscape = false
    activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    activity?.window?.attributes = activity?.window?.attributes?.apply {
      screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
    }
    onExit()
  }

  BackHandler { exitCleanly() }

  Box(
    modifier = Modifier
      .fillMaxSize()
      .background(Color.Black)
      .clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null
      ) { showControls = !showControls }
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
          onAttachVideo(vv, videoUri, audioFile)
        }
      },
      modifier = Modifier.fillMaxSize()
    )

    if (showControls) {
      Column(
        modifier = Modifier
          .align(Alignment.TopCenter)
          .fillMaxWidth()
          .background(Color.Black.copy(alpha = 0.65f))
          .padding(horizontal = 12.dp, vertical = 10.dp)
      ) {
        Row(
          modifier = Modifier.fillMaxWidth(),
          verticalAlignment = Alignment.CenterVertically,
          horizontalArrangement = Arrangement.SpaceBetween
        ) {
          TextButton(onClick = { exitCleanly() }) {
            Text("← বের হন", color = Color.White)
          }
          Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OutlinedButton(
              onClick = { showBrightnessBar = !showBrightnessBar },
              colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White)
            ) { Text("☀ ব্রাইটনেস") }
            OutlinedButton(
              onClick = {
                isLandscape = !isLandscape
                activity?.requestedOrientation = if (isLandscape) {
                  ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                } else {
                  ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
              },
              colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White)
            ) { Text("🔄 ঘোরান") }
          }
        }

        if (showBrightnessBar) {
          Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)
          ) {
            Text("☀", color = Color.White)
            Slider(
              value = brightness,
              onValueChange = { v ->
                brightness = v
                activity?.window?.attributes = activity?.window?.attributes?.apply {
                  screenBrightness = v.coerceIn(0.05f, 1.0f)
                }
              },
              valueRange = 0.05f..1.0f,
              modifier = Modifier.weight(1f).padding(horizontal = 8.dp)
            )
            Text("${(brightness * 100).toInt()}%", color = Color.White)
          }
        }
      }

      Column(
        modifier = Modifier
          .align(Alignment.BottomCenter)
          .fillMaxWidth()
          .background(Color.Black.copy(alpha = 0.72f))
          .padding(12.dp)
      ) {
        Row(
          verticalAlignment = Alignment.CenterVertically,
          modifier = Modifier.fillMaxWidth()
        ) {
          Text(formatTimeMs(if (isSeeking) sliderPosMs.toInt() else currentPosMs), color = Color.White)
          Slider(
            value = if (isSeeking) sliderPosMs else currentPosMs.toFloat(),
            onValueChange = { isSeeking = true; sliderPosMs = it },
            onValueChangeFinished = { onSeekTo(sliderPosMs.toInt()); isSeeking = false },
            valueRange = 0f..durationMs.coerceAtLeast(1000).toFloat(),
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp)
          )
          Text(formatTimeMs(durationMs), color = Color.White)
        }

        Row(
          modifier = Modifier.fillMaxWidth(),
          horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
          OutlinedButton(
            onClick = { onSeekTo(currentPosMs - 10_000) },
            colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White),
            modifier = Modifier.weight(1f)
          ) { Text("⏪ 10s") }
          Button(
            onClick = { onTogglePlayPause() },
            modifier = Modifier.weight(1.2f)
          ) { Text(if (isPlaying) "⏸ বিরতি" else "▶ চালু") }
          OutlinedButton(
            onClick = { onSeekTo(currentPosMs + 10_000) },
            colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White),
            modifier = Modifier.weight(1f)
          ) { Text("10s ⏩") }
        }
      }
    }
  }
}
EOF
