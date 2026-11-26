package dev.tunes404.tunes404

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs yt-dlp inside the app (youtubedl-android bundles Python and yt-dlp).
 *
 * Channel "dev.tunes404/ytdlp":
 *   init                                  -> null   (extracts Python + yt-dlp on first run, then updates yt-dlp daily in the background)
 *   run {args, timeoutMs, js}             -> stdout (js: use the bundled quickjs runtime; false: run without one)
 *   update                                -> status string
 *   version                               -> yt-dlp version
 *
 * The JavaScript runtime is quickjs-ng, shipped as libqjs.so so it lands in the app's native-library folder
 * (the only place Android lets an app execute files from).
 */
class YtDlpPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val pool = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val initialised = AtomicBoolean(false)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.tunes404/ytdlp")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    private fun qjsPath(): String = File(context.applicationInfo.nativeLibraryDir, "libqjs.so").absolutePath

    @Synchronized
    private fun ensureInit() {
        if (initialised.get()) return
        YoutubeDL.getInstance().init(context)
        FFmpeg.getInstance().init(context)
        initialised.set(true)
        backgroundUpdate()
    }

    /** YouTube changes often: once a day, in the background, pull the newest yt-dlp. */
    private fun backgroundUpdate() {
        val prefs = context.getSharedPreferences("ytdlp", Context.MODE_PRIVATE)
        val last = prefs.getLong("lastUpdate", 0L)
        if (System.currentTimeMillis() - last < 24L * 3600 * 1000) return
        pool.execute {
            try {
                YoutubeDL.getInstance().updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
                prefs.edit().putLong("lastUpdate", System.currentTimeMillis()).apply()
            } catch (_: Throwable) {
                // offline or rate limited: keep the version we have
            }
        }
    }

    private fun execute(args: List<String>, js: Boolean, timeoutMs: Long): String {
        ensureInit()
        val jsArgs = if (js) listOf("--no-js-runtimes", "--js-runtimes", "quickjs:${qjsPath()}") else listOf("--no-js-runtimes")
        return try {
            runOnce(jsArgs + args, timeoutMs)
        } catch (e: Exception) {
            // An older yt-dlp that doesn't know the JS options yet: run without them.
            if ((e.message ?: "").contains("no such option", ignoreCase = true)) runOnce(args, timeoutMs) else throw e
        }
    }

    private fun runOnce(args: List<String>, timeoutMs: Long): String {
        val request = YoutubeDLRequest(emptyList<String>())
        request.addCommands(args)
        val processId = UUID.randomUUID().toString()
        val timedOut = AtomicBoolean(false)
        val killer = Runnable {
            timedOut.set(true)
            YoutubeDL.getInstance().destroyProcessById(processId)
        }
        main.postDelayed(killer, timeoutMs)
        try {
            val response = YoutubeDL.getInstance().execute(request, processId, null)
            return response.out
        } catch (e: Exception) {
            if (timedOut.get()) throw RuntimeException("yt-dlp timed out")
            throw RuntimeException(summarise(e.message))
        } finally {
            main.removeCallbacks(killer)
        }
    }

    /** yt-dlp prints a lot; the error line is what the user needs. */
    private fun summarise(raw: String?): String {
        val lines = (raw ?: "yt-dlp failed").trim().lines()
        return lines.lastOrNull { it.contains("ERROR") } ?: lines.lastOrNull() ?: "yt-dlp failed"
    }

    /** Errors like ExceptionInInitializerError carry no message: walk to the root cause so the UI shows something useful. */
    private fun describe(e: Throwable): String {
        var root: Throwable = e
        while (root.cause != null && root.cause !== root) root = root.cause!!
        val msg = e.message ?: root.message
        return if (msg != null) msg else "${e.javaClass.simpleName}: ${root.javaClass.name}"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        pool.execute {
            try {
                val value: Any? = when (call.method) {
                    "init" -> { ensureInit(); null }
                    "run" -> {
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        val timeout = (call.argument<Number>("timeoutMs") ?: 120000).toLong()
                        val js = call.argument<Boolean>("js") ?: true
                        execute(args, js, timeout)
                    }
                    "update" -> {
                        ensureInit()
                        val status = YoutubeDL.getInstance().updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
                        context.getSharedPreferences("ytdlp", Context.MODE_PRIVATE)
                            .edit().putLong("lastUpdate", System.currentTimeMillis()).apply()
                        status?.toString() ?: ""
                    }
                    "version" -> {
                        ensureInit()
                        YoutubeDL.getInstance().versionName(context) ?: YoutubeDL.getInstance().version(context) ?: ""
                    }
                    else -> { main.post { result.notImplemented() }; return@execute }
                }
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("ytdlp", describe(e), null) }
            }
        }
    }
}
