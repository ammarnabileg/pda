package com.tamween.tamween_pda

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var tone: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tamween/beep").setMethodCallHandler { call, result ->
            try {
                val t = tone ?: ToneGenerator(AudioManager.STREAM_MUSIC, 100).also { tone = it }
                when (call.method) {
                    "ok" -> t.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
                    "error" -> t.startTone(ToneGenerator.TONE_SUP_ERROR, 600)
                }
            } catch (e: RuntimeException) {
                // Some devices refuse a ToneGenerator; vibration still gives feedback.
            }
            result.success(null)
        }
    }

    override fun onDestroy() {
        tone?.release()
        tone = null
        super.onDestroy()
    }
}
