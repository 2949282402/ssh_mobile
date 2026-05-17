package com.example.ssh_mobile

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.AlarmClock
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ssh_mobile/power"
    private val systemChannelName = "ssh_mobile/client_system"

    companion object {
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireLocks" -> {
                    acquireLocks()
                    result.success(true)
                }
                "releaseLocks" -> {
                    releaseLocks()
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestBatteryOptimizationExemption" -> {
                    requestBatteryOptimizationExemption()
                    result.success(true)
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSystemAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    val hour = (args?.get("hour") as? Number)?.toInt()
                    val minute = (args?.get("minute") as? Number)?.toInt()
                    val message = args?.get("message") as? String
                    val skipUi = args?.get("skipUi") as? Boolean ?: false
                    if (hour == null || minute == null || hour !in 0..23 || minute !in 0..59) {
                        result.error("INVALID_ALARM_TIME", "Alarm hour/minute is invalid", null)
                        return@setMethodCallHandler
                    }
                    result.success(setSystemAlarm(hour, minute, message, skipUi))
                }
                "getNetworkInfo" -> {
                    result.success(getNetworkInfo())
                }
                "getBatteryStatus" -> {
                    result.success(getBatteryStatus())
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun acquireLocks() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wakeLock?.isHeld != true) {
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "ssh_mobile:SshKeepAliveWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }

        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (wifiLock?.isHeld != true) {
            wifiLock = wifiManager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "ssh_mobile:SshKeepAliveWifiLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        wifiLock = null

        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBatteryOptimizations()) {
            return
        }

        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }

        try {
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        startActivity(intent)
    }

    private fun setSystemAlarm(hour: Int, minute: Int, message: String?, skipUi: Boolean): Boolean {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_MESSAGE, message ?: "SSH Mobile")
            putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
        }
        val handler = intent.resolveActivity(packageManager) ?: return false
        return try {
            intent.component = handler
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun getNetworkInfo(): Map<String, Any?> {
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val activeNetwork = connectivityManager.activeNetwork
        val capabilities = activeNetwork?.let { connectivityManager.getNetworkCapabilities(it) }
        val transports = mutableListOf<String>()
        if (capabilities != null) {
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) transports.add("wifi")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) transports.add("cellular")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) transports.add("ethernet")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) transports.add("vpn")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) transports.add("bluetooth")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            ) {
                transports.add("wifiAware")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 &&
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_LOWPAN)
            ) {
                transports.add("lowpan")
            }
        }
        val linkProperties = activeNetwork?.let { connectivityManager.getLinkProperties(it) }
        val dnsServers = linkProperties?.dnsServers?.map { it.hostAddress } ?: emptyList()
        val interfaceName = linkProperties?.interfaceName
        val proxy = linkProperties?.httpProxy
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val wifiInfo = try {
            @Suppress("DEPRECATION")
            wifiManager.connectionInfo
        } catch (_: Exception) {
            null
        }
        return mapOf(
            "connected" to (activeNetwork != null && capabilities != null),
            "validated" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ?: false),
            "metered" to connectivityManager.isActiveNetworkMetered,
            "transports" to transports,
            "vpnActive" to transports.contains("vpn"),
            "interfaceName" to interfaceName,
            "dnsServers" to dnsServers,
            "httpProxyHost" to proxy?.host,
            "httpProxyPort" to proxy?.port,
            "wifiEnabled" to wifiManager.isWifiEnabled,
            "wifiSsid" to sanitizeSsid(wifiInfo?.ssid),
            "wifiBssidAvailable" to (!wifiInfo?.bssid.isNullOrBlank() && wifiInfo?.bssid != "02:00:00:00:00:00"),
            "wifiRssi" to wifiInfo?.rssi,
            "wifiLinkSpeedMbps" to wifiInfo?.linkSpeed,
            "note" to "Some Wi-Fi identifiers may be hidden by Android privacy rules unless location permissions are granted."
        )
    }

    private fun getBatteryStatus(): Map<String, Any?> {
        val batteryIntent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) level * 100.0 / scale else null
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val plugged = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "batteryPercent" to percent,
            "status" to when (status) {
                BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
                BatteryManager.BATTERY_STATUS_FULL -> "full"
                BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "notCharging"
                else -> "unknown"
            },
            "plugged" to mapOf(
                "ac" to ((plugged and BatteryManager.BATTERY_PLUGGED_AC) != 0),
                "usb" to ((plugged and BatteryManager.BATTERY_PLUGGED_USB) != 0),
                "wireless" to ((plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS) != 0)
            ),
            "powerSaveMode" to powerManager.isPowerSaveMode,
            "ignoringBatteryOptimizations" to isIgnoringBatteryOptimizations(),
            "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) thermalStatusName(powerManager.currentThermalStatus) else "unavailable",
            "note" to "Battery and optimization status describe the client device, useful for SSH keep-alive and monitor background sampling diagnostics."
        )
    }

    private fun sanitizeSsid(ssid: String?): String? {
        if (ssid.isNullOrBlank() || ssid == "<unknown ssid>") return null
        return ssid.trim('"')
    }

    private fun thermalStatusName(status: Int): String {
        return when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown"
        }
    }
}
