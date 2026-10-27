package com.huddlecommunity.better_native_video_player

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import androidx.media3.common.util.UnstableApi
import com.huddlecommunity.better_native_video_player.handlers.ControllerEventChannelHandler
import com.huddlecommunity.better_native_video_player.handlers.PictureInPictureHandler
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager
import com.huddlecommunity.better_native_video_player.manager.VideoCacheManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Native Video Player Plugin for Android
 * Implements ActivityAware to get access to the Activity for fullscreen dialogs
 */
@UnstableApi
class NativeVideoPlayerPlugin(
    private val sharedPlayerManager: SharedPlayerManager = SharedPlayerManager()
) : FlutterPlugin, ActivityAware {
    companion object {
        private const val TAG = "NativeVideoPlayerPlugin"
        private const val VIEW_TYPE = "native_video_player"

        // Store registered views
        private val registeredViews = mutableMapOf<BinaryMessenger, MutableMap<Long, VideoPlayerBackend>>()

        // Store current activity
        private var currentActivity: Activity? = null

        private val attachedPlugins = mutableSetOf<NativeVideoPlayerPlugin>()

        fun registerView(messenger: BinaryMessenger, view: VideoPlayerBackend, viewId: Long) {
            NpLog.d(TAG, "Registering view with id: $viewId")
            registeredViews.getOrPut(messenger) { mutableMapOf() }[viewId] = view
        }

        fun unregisterView(messenger: BinaryMessenger, viewId: Long) {
            NpLog.d(TAG, "Unregistering view with id: $viewId")
            registeredViews[messenger]?.remove(viewId)
        }

        fun getActivity(): Activity? = currentActivity

        /**
         * Get all registered video player views
         * Used by MainActivity to trigger automatic PiP on user leave hint
         */
        fun getAllViews(): Collection<VideoPlayerView> =
            registeredViews.values.flatMap { it.values }.filterIsInstance<VideoPlayerView>()
    }

    private var methodChannel: MethodChannel? = null
    private var assetChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var messenger: BinaryMessenger? = null
    private var textureRegistry: io.flutter.view.TextureRegistry? = null
    private val textureBackends = mutableMapOf<Long, TextureVideoPlayer>()
    private val controllerEventChannels = mutableMapOf<Int, EventChannel>()
    private val controllerEventHandlers = mutableMapOf<Int, ControllerEventChannelHandler>()
    private var activity: Activity? = null

    private fun disposeAllTextureBackends() {
        textureBackends.values.toList().forEach { it.dispose() }
        textureBackends.clear()
    }

    private fun setupControllerEventChannel(controllerId: Int): Boolean {
        val binaryMessenger = messenger ?: return false
        if (controllerEventChannels.containsKey(controllerId)) return true
        val handler = ControllerEventChannelHandler(controllerId, sharedPlayerManager)
        val channel = EventChannel(binaryMessenger, "native_video_player_controller_$controllerId")
        channel.setStreamHandler(handler)
        controllerEventChannels[controllerId] = channel
        controllerEventHandlers[controllerId] = handler
        return true
    }

    private fun teardownControllerEventChannel(controllerId: Int) {
        controllerEventChannels.remove(controllerId)?.setStreamHandler(null)
        controllerEventHandlers.remove(controllerId)?.onCancel(null)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Gate debug logging on the CONSUMING app's debuggable flag (the
        // library's own BuildConfig.DEBUG tracks the library build type, not
        // the app's)
        NpLog.enabled = (binding.applicationContext.applicationInfo.flags and
            ApplicationInfo.FLAG_DEBUGGABLE) != 0

        NpLog.d(TAG, "Registering NativeVideoPlayerPlugin")

        attachedPlugins.add(this)
        messenger = binding.binaryMessenger
        textureRegistry = binding.textureRegistry

        // Register platform view factory
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            VideoPlayerViewFactory(binding.binaryMessenger, binding.applicationContext, sharedPlayerManager)
        )

        val applicationContext = binding.applicationContext

        // Register method channel for forwarding calls to specific views
        val channel = MethodChannel(binding.binaryMessenger, VIEW_TYPE)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            NpLog.d(TAG, "Plugin received method call: ${call.method}")

            // Handle controller-level methods that don't require a viewId
            when (call.method) {
                "setupControllerEventChannel" -> {
                    val args = call.arguments as? Map<*, *>
                    val controllerId = args?.get("controllerId") as? Int
                    if (controllerId != null) {
                        if (setupControllerEventChannel(controllerId)) {
                            result.success(null)
                        } else {
                            result.error("NO_ENGINE", "Engine messenger unavailable", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Controller ID is required", null)
                    }
                    return@setMethodCallHandler
                }
                "teardownControllerEventChannel" -> {
                    val args = call.arguments as? Map<*, *>
                    val controllerId = args?.get("controllerId") as? Int
                    if (controllerId != null) {
                        teardownControllerEventChannel(controllerId)
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGUMENT", "Controller ID is required", null)
                    }
                    return@setMethodCallHandler
                }
                "disposeController" -> {
                    // Releases the shared native player by controller ID. Used by
                    // Dart dispose() when no platform view is alive (after
                    // releaseResources()) so the native player cannot leak.
                    val args = call.arguments as? Map<*, *>
                    val controllerId = args?.get("controllerId") as? Int
                    if (controllerId != null) {
                        sharedPlayerManager.removePlayer(applicationContext, controllerId)
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGUMENT", "Controller ID is required", null)
                    }
                    return@setMethodCallHandler
                }
                "viewDisposed" -> {
                    // Texture backends have no PlatformView.dispose — this
                    // Dart hook is their disposal trigger. For platform views
                    // it's a no-op (the engine calls dispose itself); iOS
                    // uses it to deregister its per-view EventChannel handler.
                    val viewId = ((call.arguments as? Map<*, *>)?.get("viewId") as? Number)?.toLong()
                    if (viewId != null) {
                        textureBackends.remove(viewId)?.dispose()
                    }
                    result.success(null)
                    return@setMethodCallHandler
                }
                "createTextureView" -> {
                    // Texture rendering mode: the Dart widget allocated the
                    // viewId from platformViewsRegistry (collision-free with
                    // real platform views) and sends the same creationParams
                    // a platform view would get.
                    @Suppress("UNCHECKED_CAST")
                    val params = call.arguments as? Map<String, Any>
                    val viewId = (params?.get("viewId") as? Number)?.toLong()
                    val registry = textureRegistry
                    if (viewId == null || registry == null) {
                        result.error(
                            "NO_ENGINE",
                            "viewId missing or texture registry unavailable",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    val producer = registry.createSurfaceProducer()
                    val backend = TextureVideoPlayer(
                        applicationContext,
                        viewId,
                        params,
                        sharedPlayerManager,
                        binding.binaryMessenger,
                        producer
                    )
                    textureBackends[viewId] = backend
                    registerView(binding.binaryMessenger, backend, viewId)
                    result.success(mapOf("textureId" to producer.id()))
                    return@setMethodCallHandler
                }
                "disposeAllTextureViews" -> {
                    // Hot-restart hygiene: the Dart isolate forgot its texture
                    // backends but they survive natively — called once per
                    // isolate before the first createTextureView.
                    disposeAllTextureBackends()
                    result.success(null)
                    return@setMethodCallHandler
                }
                "precacheVideo" -> {
                    // Global (no viewId): warms the opt-in disk cache so a
                    // later load starts without network round-trips. Works
                    // before any player exists.
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url == null) {
                        result.error("INVALID_ARGUMENT", "url is required", null)
                        return@setMethodCallHandler
                    }
                    @Suppress("UNCHECKED_CAST")
                    val headers = args["headers"] as? Map<String, String>
                    val precacheBytes = (args["precacheBytes"] as? Number)?.toLong()
                        ?: VideoCacheManager.DEFAULT_PRECACHE_BYTES
                    val cacheMaxBytes = (args["cacheMaxBytes"] as? Number)?.toLong()
                        ?: VideoCacheManager.DEFAULT_MAX_BYTES
                    VideoCacheManager.precache(
                        applicationContext,
                        url,
                        headers,
                        precacheBytes,
                        cacheMaxBytes
                    ) { ok, _ -> result.success(ok) }
                    return@setMethodCallHandler
                }
            }

            val args = call.arguments as? Map<*, *>
            val viewId = args?.get("viewId") as? Number
            val view = viewId?.toLong()?.let { registeredViews[binding.binaryMessenger]?.get(it) }

            if (view != null) {
                view.handleMethodCall(call, result)
            } else if (call.method == "pause" && pauseWithoutView(args)) {
                result.success(true)
            } else {
                result.error("NO_VIEW", "No view found for method call", null)
            }
        }

        // Register asset resolution channel
        val assets = MethodChannel(binding.binaryMessenger, "native_video_player/assets")
        assetChannel = assets
        assets.setMethodCallHandler { call, result ->
            when (call.method) {
                "resolveAssetPath" -> {
                    val assetKey = (call.arguments as? Map<*, *>)?.get("assetKey") as? String
                    if (assetKey != null) {
                        try {
                            // Flutter assets are bundled in the APK and need to be extracted to a file
                            // Get the asset file path using Flutter's asset lookup
                            val assetPath = binding.flutterAssets.getAssetFilePathByName(assetKey)

                            // Extract the asset to cache directory so ExoPlayer can read it as a file
                            val cacheDir = binding.applicationContext.cacheDir
                            val fileName = assetKey.substringAfterLast('/')
                            val outputFile = java.io.File(cacheDir, fileName)

                            // Only extract if the file doesn't already exist or is outdated
                            if (!outputFile.exists()) {
                                NpLog.d(TAG, "Extracting asset '$assetPath' to '${outputFile.absolutePath}'")
                                binding.applicationContext.assets.open(assetPath).use { inputStream ->
                                    outputFile.outputStream().use { outputStream ->
                                        inputStream.copyTo(outputStream)
                                    }
                                }
                            } else {
                                NpLog.d(TAG, "Asset already extracted at '${outputFile.absolutePath}'")
                            }

                            NpLog.d(TAG, "Resolved asset '$assetKey' to '${outputFile.absolutePath}'")
                            result.success(outputFile.absolutePath)
                        } catch (e: Exception) {
                            NpLog.e(TAG, "Failed to resolve asset: ${e.message}", e)
                            result.error("ASSET_ERROR", "Failed to resolve asset: ${e.message}", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Asset key is required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Picture-in-picture works on this engine's activity (null for an
        // engine without one, which then reports PiP as unavailable).
        val pip = MethodChannel(binding.binaryMessenger, PictureInPictureHandler.CHANNEL_NAME)
        pipChannel = pip
        pip.setMethodCallHandler(PictureInPictureHandler { activity })

        NpLog.d(TAG, "NativeVideoPlayerPlugin registered with id: $VIEW_TYPE")
    }

    /**
     * Pauses a controller's player when the view a pause was routed to is
     * gone. The engine disposes a platform view before the widget's dispose
     * runs, and an app may keep a controller without any view; the shared
     * player keeps playing in both cases, so the pause must still reach it.
     */
    private fun pauseWithoutView(args: Map<*, *>?): Boolean {
        val controllerId = (args?.get("controllerId") as? Number)?.toInt() ?: return false
        val player = sharedPlayerManager.getExistingPlayer(controllerId) ?: return false
        player.pause()
        NpLog.d(TAG, "Paused controller $controllerId without a view")
        return true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NpLog.d(TAG, "NativeVideoPlayerPlugin detached")

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        assetChannel?.setMethodCallHandler(null)
        assetChannel = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        registeredViews.remove(binding.binaryMessenger)?.values?.toList()?.forEach { backend ->
            backend.dispose()
        }
        disposeAllTextureBackends()
        sharedPlayerManager.clearAll(binding.applicationContext)
        textureRegistry = null
        controllerEventChannels.keys.toList().forEach { teardownControllerEventChannel(it) }
        messenger = null
        attachedPlugins.remove(this)

        if (attachedPlugins.isEmpty()) {
            VideoCacheManager.cancelAllPrecache()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NpLog.d(TAG, "Plugin attached to activity: ${binding.activity}")
        activity = binding.activity
        currentActivity = activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        NpLog.d(TAG, "Plugin detached from activity for config changes")
        // Don't clear activity - it will be reattached
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        NpLog.d(TAG, "Plugin reattached to activity: ${binding.activity}")
        activity = binding.activity
        currentActivity = activity
    }

    override fun onDetachedFromActivity() {
        NpLog.d(TAG, "Plugin detached from activity")
        if (currentActivity === activity) currentActivity = null
        activity = null
    }
}

/**
 * Factory for creating VideoPlayerView instances
 */
@UnstableApi
class VideoPlayerViewFactory(
    private val messenger: BinaryMessenger,
    private val context: Context,
    private val sharedPlayerManager: SharedPlayerManager
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    companion object {
        private const val TAG = "VideoPlayerViewFactory"
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        NpLog.d(TAG, "Creating VideoPlayerView with id: $viewId")

        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any>

        val view = VideoPlayerView(
            context = this.context,
            viewId = viewId.toLong(),
            args = creationParams,
            sharedPlayerManager = sharedPlayerManager,
            binaryMessenger = messenger
        )

        NativeVideoPlayerPlugin.registerView(messenger, view, viewId.toLong())
        return view
    }
}
