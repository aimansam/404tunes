package dev.tunes404.tunes404

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// AudioServiceActivity lets the media notification and lock-screen controls reach the Flutter engine.
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+: the playback notification (and its lock-screen controls) only shows once this is granted.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(YtDlpPlugin())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.tunes404/update")
            .setMethodCallHandler(::onUpdateCall)
    }

    // In-app updates (lib/update/installer_android.dart).
    private fun onUpdateCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "install" -> result.success(installApk(File(call.argument<String>("path")!!)))
                "open" -> {
                    val url = Uri.parse(call.argument<String>("url")!!)
                    require(url.scheme == "https" && url.host == "github.com") { "unexpected address" }
                    startActivity(Intent(Intent.ACTION_VIEW, url))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("update", e.message, null)
        }
    }

    /** Opens the system installer for a downloaded update. The user confirms there. */
    private fun installApk(apk: File): String {
        // Only files the updater itself downloaded.
        require(apk.isFile && apk.canonicalFile.parentFile == File(cacheDir, "updates").canonicalFile) {
            "not a downloaded update"
        }
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return "needs_permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "started"
    }
}

/** Our own class, so this provider cannot clash with a FileProvider declared by a plugin. */
class UpdateFileProvider : FileProvider()
