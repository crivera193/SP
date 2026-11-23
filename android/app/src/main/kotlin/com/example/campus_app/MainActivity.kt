package com.example.campus_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nearbyRssi: NearbyRssiReader? = null
    private var nearbyChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val reader = NearbyRssiReader(applicationContext)
        nearbyRssi = reader
        nearbyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.campus_app/nearby_rssi",
        ).apply {
            setMethodCallHandler { call, result ->
                val address = call.arguments as? String
                when (call.method) {
                    "read" -> reader.read(address, result)
                    "close" -> {
                        reader.close(address)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nearbyChannel?.setMethodCallHandler(null)
        nearbyRssi?.close(null)
        nearbyChannel = null
        nearbyRssi = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
