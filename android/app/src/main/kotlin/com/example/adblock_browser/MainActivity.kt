package com.example.adblock_browser

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android drops inbound multicast (mDNS/SSDP) unless a MulticastLock is held.
        // Cast discovery acquires this while the cast screen is open.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "multicast_lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        if (lock == null) {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            lock = wifi.createMulticastLock("cast").apply { setReferenceCounted(false) }
                        }
                        if (lock?.isHeld != true) lock?.acquire()
                        result.success(null)
                    }
                    "release" -> {
                        if (lock?.isHeld == true) lock?.release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
