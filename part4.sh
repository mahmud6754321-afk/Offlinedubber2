set -e
mkdir -p app/src/main/java/com/offline/videodubber

cat << 'EOF' > app/src/main/java/com/offline/videodubber/Mp4DubbedExporter.kt
package com.offline.videodubber

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

object Mp4DubbedExporter {

  fun exportDubbedMp4(context: Context, videoUri: Uri, wavFile: File, outMp4: File) {
    val wavBytes = wavFile.readBytes()
    var sampleRate = 22050; var channels = 1; var pcmData = ByteArray(0)
    var pos = 12
    while (pos + 8 <= wavBytes.size) {
      val id = String(wavBytes, pos, 4, Charsets.US_ASCII)
      val size = ByteBuffer.wrap(wavBytes, pos + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
      val dataStart = pos + 8
      if (id == "fmt " && dataStart + 16 <= wavBytes.size) {
        val fb = ByteBuffer.wrap(wavBytes, dataStart, 16).order(ByteOrder.LITTLE_ENDIAN)
        fb.short; channels = fb.short.toInt(); sampleRate = fb.int
      } else if (id == "data" && size > 0 && dataStart + size <= wavBytes.size) {
        pcmData = wavBytes.copyOfRange(dataStart, dataStart + size)
      }
      pos = dataStart + size + (size and 1)
    }
    require(pcmData.isNotEmpty()) { "অডিও ডাটা খালি।" }

    val extractor = MediaExtractor()
    extractor.setDataSource(context, videoUri, null)
    var videoTrackIdx = -1; var videoFormat: MediaFormat? = null
    for (i in 0 until extractor.trackCount) {
      val fmt = extractor.getTrackFormat(i)
      if ((fmt.getString(MediaFormat.KEY_MIME) ?: "").startsWith("video/")) { videoTrackIdx = i; videoFormat = fmt; break }
    }
    require(videoTrackIdx >= 0 && videoFormat != null) { "ভিডিও ট্র্যাক পাওয়া যায়নি।" }
    extractor.selectTrack(videoTrackIdx)

    val muxer = MediaMuxer(outMp4.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    if (videoFormat.containsKey(MediaFormat.KEY_ROTATION)) muxer.setOrientationHint(videoFormat.getInteger(MediaFormat.KEY_ROTATION))
    val muxVideoTrack = muxer.addTrack(videoFormat)

    val aacFmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
      setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
      setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
      setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
    }
    val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    encoder.configure(aacFmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    encoder.start()

    var muxAudioTrack = -1; var muxStarted = false
    val bytesPerFrame = (channels * 2).coerceAtLeast(2)

    try {
      val info = MediaCodec.BufferInfo()
      var pcmOffset = 0; var inputDone = false; var outputDone = false; var lastAudioPtsUs = -1L

      while (!outputDone) {
        if (!inputDone) {
          val inIdx = encoder.dequeueInputBuffer(10_000)
          if (inIdx >= 0) {
            val inBuf = encoder.getInputBuffer(inIdx)!!
            if (pcmOffset >= pcmData.size) {
              val endPts = (pcmOffset.toLong() / bytesPerFrame) * 1_000_000L / sampleRate
              encoder.queueInputBuffer(inIdx, 0, 0, endPts, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true
            } else {
              val toCopy = minOf(inBuf.capacity(), pcmData.size - pcmOffset)
              inBuf.clear(); inBuf.put(pcmData, pcmOffset, toCopy)
              val pts = (pcmOffset.toLong() / bytesPerFrame) * 1_000_000L / sampleRate
              encoder.queueInputBuffer(inIdx, 0, toCopy, pts, 0); pcmOffset += toCopy
            }
          }
        }
        val outIdx = encoder.dequeueOutputBuffer(info, 10_000)
        when {
          outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { muxAudioTrack = muxer.addTrack(encoder.outputFormat); muxer.start(); muxStarted = true }
          outIdx >= 0 -> {
            val outBuf = encoder.getOutputBuffer(outIdx)
            if (outBuf != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && muxStarted) {
              outBuf.position(info.offset); outBuf.limit(info.offset + info.size)
              if (info.presentationTimeUs <= lastAudioPtsUs) info.presentationTimeUs = lastAudioPtsUs + 1
              lastAudioPtsUs = info.presentationTimeUs
              muxer.writeSampleData(muxAudioTrack, outBuf, info)
            }
            encoder.releaseOutputBuffer(outIdx, false)
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true
          }
        }
      }

      if (muxStarted) {
        val maxSize = if (videoFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) videoFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE).coerceAtLeast(512 * 1024) else 1024 * 1024
        val vBuf = ByteBuffer.allocate(maxSize); val vInfo = MediaCodec.BufferInfo(); var lastVideoPts = -1L
        while (true) {
          val sz = extractor.readSampleData(vBuf, 0); if (sz < 0) break
          val pts = extractor.sampleTime; if (pts <= lastVideoPts) { extractor.advance(); continue }
          lastVideoPts = pts; vInfo.offset = 0; vInfo.size = sz; vInfo.presentationTimeUs = pts
          vInfo.flags = if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
          muxer.writeSampleData(muxVideoTrack, vBuf, vInfo); extractor.advance()
        }
      }
    } finally {
      runCatching { encoder.stop(); encoder.release() }
      runCatching { extractor.release() }
      runCatching { if (muxStarted) muxer.stop(); muxer.release() }
    }
  }
}
EOF
