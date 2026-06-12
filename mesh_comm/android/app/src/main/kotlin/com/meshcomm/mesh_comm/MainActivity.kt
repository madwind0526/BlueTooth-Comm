package com.meshcomm.mesh_comm

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val alertChannelName = "mesh_comm/alerts"
    private val fileChannelName  = "com.meshcomm/file_selector"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var filePickerResult: MethodChannel.Result? = null

    companion object {
        private const val REQ_OPEN_FILE = 2001
        private const val REQ_SAVE_FILE = 2002

        /** /storage/emulated/0/... 경로 → ExternalStorage content:// URI */
        private fun pathToContentUri(path: String): Uri? {
            val base = "/storage/emulated/0/"
            if (!path.startsWith(base)) return null
            val relative = path.removePrefix(base).replace("/", "%2F")
            return Uri.parse(
                "content://com.android.externalstorage.documents/document/primary:$relative"
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        acquireMulticastLock()

        val requiredPermissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                // Some Samsung devices suppress peer scan results unless
                // location permission and the system location service are on.
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }

        val missingPermissions = requiredPermissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isNotEmpty()) {
            requestPermissions(missingPermissions.toTypedArray(), 1001)
        }
    }

    override fun onResume() {
        super.onResume()
        if (multicastLock?.isHeld == false) acquireMulticastLock()
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseMulticastLock()
    }

    private fun acquireMulticastLock() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("MeshCommMulticast")
        multicastLock!!.setReferenceCounted(false)
        multicastLock!!.acquire()
    }

    private fun releaseMulticastLock() {
        if (multicastLock?.isHeld == true) multicastLock!!.release()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── 알림/진동 채널 ─────────────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            alertChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playAlert" -> { playAlert(); result.success(null) }
                "vibrate"   -> { vibrate();   result.success(null) }
                else        -> result.notImplemented()
            }
        }

        // ── 파일 선택/저장 채널 ────────────────────────────────────────────────
        // openFilePicker  : ACTION_GET_CONTENT  → Samsung My Files (폴더 트리)
        // saveFilePicker  : ACTION_CREATE_DOCUMENT → DocumentsUI 저장
        // readFileFromUri : content URI → ByteArray
        // writeFileToUri  : ByteArray → content URI
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            fileChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openFilePicker" -> {
                    val dir  = call.argument<String>("initialDirectory")
                    val mime = call.argument<String>("mimeType") ?: "*/*"
                    filePickerResult = result
                    val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                        type = mime
                        addCategory(Intent.CATEGORY_OPENABLE)
                        if (dir != null) {
                            pathToContentUri(dir)?.let {
                                putExtra(DocumentsContract.EXTRA_INITIAL_URI, it)
                            }
                        }
                    }
                    startActivityForResult(intent, REQ_OPEN_FILE)
                }
                "saveFilePicker" -> {
                    val dir  = call.argument<String>("initialDirectory")
                    val name = call.argument<String>("suggestedName") ?: "file"
                    filePickerResult = result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        type = "*/*"
                        addCategory(Intent.CATEGORY_OPENABLE)
                        putExtra(Intent.EXTRA_TITLE, name)
                        if (dir != null) {
                            pathToContentUri(dir)?.let {
                                putExtra(DocumentsContract.EXTRA_INITIAL_URI, it)
                            }
                        }
                    }
                    startActivityForResult(intent, REQ_SAVE_FILE)
                }
                "readFileFromUri" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("INVALID", "uri required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val bytes = contentResolver
                            .openInputStream(Uri.parse(uriStr))
                            ?.use { it.readBytes() }
                        result.success(bytes)
                    } catch (e: Exception) {
                        result.error("READ_ERROR", e.message, null)
                    }
                }
                "writeFileToUri" -> {
                    val uriStr = call.argument<String>("uri")
                    val bytes  = call.argument<ByteArray>("bytes")
                    if (uriStr == null || bytes == null) {
                        result.error("INVALID", "uri and bytes required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        contentResolver
                            .openOutputStream(Uri.parse(uriStr))
                            ?.use { it.write(bytes) }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("WRITE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_OPEN_FILE || requestCode == REQ_SAVE_FILE) {
            if (resultCode == Activity.RESULT_OK) {
                filePickerResult?.success(data?.data?.toString())
            } else {
                filePickerResult?.success(null)
            }
            filePickerResult = null
        }
    }

    private fun playAlert() {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        val ringtone = RingtoneManager.getRingtone(applicationContext, uri) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            ringtone.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        }
        ringtone.play()
    }

    private fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(
                VibrationEffect.createOneShot(450, VibrationEffect.DEFAULT_AMPLITUDE),
            )
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(450)
        }
    }
}
