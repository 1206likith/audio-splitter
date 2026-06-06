package com.audiosplitter.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.atomic.AtomicBoolean

class AudioCapturePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    companion object {
        private const val METHOD_CHANNEL = "com.audiosplitter.app/system_audio_control"
        private const val EVENT_CHANNEL = "com.audiosplitter.app/system_audio"
        private const val MEDIA_PROJECTION_REQUEST = 1001
        const val SAMPLE_RATE = 48000
        const val CHANNEL_COUNT = 2
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private val isCapturing = AtomicBoolean(false)
    private var captureThread: Thread? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startCapture" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.error("UNSUPPORTED", "AudioPlaybackCapture requires Android 10+", null)
                    return
                }
                pendingResult = result
                requestMediaProjection()
            }
            "stopCapture" -> {
                stopCapture()
                result.success(null)
            }
            "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            else -> result.notImplemented()
        }
    }

    private fun requestMediaProjection() {
        val mgr = activity?.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            ?: run { pendingResult?.error("NO_ACTIVITY", "No activity", null); return }
        activity?.startActivityForResult(mgr.createScreenCaptureIntent(), MEDIA_PROJECTION_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != MEDIA_PROJECTION_REQUEST) return false
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("PERMISSION_DENIED", "MediaProjection permission denied", null)
            pendingResult = null
            return true
        }
        val mgr = activity?.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        mediaProjection = mgr?.getMediaProjection(resultCode, data)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startCapture()
        }
        pendingResult?.success(null)
        pendingResult = null
        return true
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startCapture() {
        val projection = mediaProjection ?: return
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .build()

        val minBufSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        audioRecord = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(config)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(minBufSize * 4)
            .build()

        isCapturing.set(true)
        audioRecord?.startRecording()

        captureThread = Thread {
            val bufferSize = SAMPLE_RATE * CHANNEL_COUNT * 2 / 10 // 100ms at 48kHz stereo PCM16
            val buffer = ByteArray(bufferSize)
            while (isCapturing.get()) {
                val read = audioRecord?.read(buffer, 0, bufferSize) ?: break
                if (read > 0) {
                    val data = buffer.copyOf(read)
                    activity?.runOnUiThread {
                        eventSink?.success(data)
                    }
                }
            }
        }.also { it.start() }
    }

    private fun stopCapture() {
        isCapturing.set(false)
        captureThread?.join(500)
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        mediaProjection?.stop()
        mediaProjection = null
    }
}
