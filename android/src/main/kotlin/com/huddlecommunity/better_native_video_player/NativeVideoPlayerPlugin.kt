package com.huddlecommunity.better_native_video_player

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import androidx.media3.common.util.UnstableApi
import com.huddlecommunity.better_native_video_player.handlers.ControllerEventChannelHandler
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager
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
class NativeVideoPlayerPlugin : FlutterPlugin, ActivityAware {
    companion object {
        private const val TAG = "NativeVideoPlayerPlugin"
        private const val VIEW_TYPE = "native_video_player"

        // Store registered views
        private val registeredViews = mutableMapOf<Long, VideoPlayerView>()

        // Store current activity
        private var currentActivity: Activity? = null

        // Messenger of the most recently attached engine; needed to create
        // controller-level EventChannels before any platform view exists.
        private var messenger: BinaryMessenger? = null

        // Controller-level EventChannels keyed by controller ID. Created on
        // demand via setupControllerEventChannel (called from the Dart
        // controller constructor) and torn down on controller dispose.
        private val controllerEventChannels = mutableMapOf<Int, EventChannel>()

        fun registerView(view: VideoPlayerView, viewId: Long) {
            NpLog.d(TAG, "Registering view with id: $viewId")
            registeredViews[viewId] = view
        }

        fun unregisterView(viewId: Long) {
            NpLog.d(TAG, "Unregistering view with id: $viewId")
            registeredViews.remove(viewId)
        }

        fun getActivity(): Activity? = currentActivity

        /**
         * Get all registered video player views
         * Used by MainActivity to trigger automatic PiP on user leave hint
         */
        fun getAllViews(): Collection<VideoPlayerView> = registeredViews.values

        /**
         * Registers the StreamHandler for `native_video_player_controller_<id>`.
         *
         * Called via the shared method channel from the Dart controller
         * constructor BEFORE Dart listens, so the EventChannel `listen` call
         * always finds a native handler (avoids MissingPluginException).
         * Idempotent: an existing registration for the ID is kept (the Dart
         * side re-listening simply replaces the sink via onListen).
         */
        fun setupControllerEventChannel(controllerId: Int) {
            if (controllerEventChannels.containsKey(controllerId)) {
                NpLog.d(TAG, "Controller event channel for $controllerId already exists")
                return
            }
            val binaryMessenger = messenger
            if (binaryMessenger == null) {
                NpLog.w(TAG, "Cannot setup controller event channel - no messenger")
                return
            }
            val channel = EventChannel(
                binaryMessenger,
                "native_video_player_controller_$controllerId"
            )
            channel.setStreamHandler(ControllerEventChannelHandler(controllerId))
            controllerEventChannels[controllerId] = channel
            NpLog.d(TAG, "Set up controller event channel for controller $controllerId")
        }

        /**
         * Removes the StreamHandler registered by [setupControllerEventChannel].
         * Idempotent; also defensively drops the sink in case onCancel never ran.
         */
        fun teardownControllerEventChannel(controllerId: Int) {
            controllerEventChannels.remove(controllerId)?.setStreamHandler(null)
            SharedPlayerManager.unregisterControllerEventSink(controllerId)
            NpLog.d(TAG, "Tore down controller event channel for controller $controllerId")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Gate debug logging on the CONSUMING app's debuggable flag (the
        // library's own BuildConfig.DEBUG tracks the library build type, not
        // the app's)
        NpLog.enabled = (binding.applicationContext.applicationInfo.flags and
            ApplicationInfo.FLAG_DEBUGGABLE) != 0

        NpLog.d(TAG, "Registering NativeVideoPlayerPlugin")

        messenger = binding.binaryMessenger

        // Register platform view factory
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            VideoPlayerViewFactory(binding.binaryMessenger, binding.applicationContext)
        )

        val applicationContext = binding.applicationContext

        // Register method channel for forwarding calls to specific views
        val channel = MethodChannel(binding.binaryMessenger, VIEW_TYPE)
        channel.setMethodCallHandler { call, result ->
            NpLog.d(TAG, "Plugin received method call: ${call.method}")

            // Handle controller-level methods that don't require a viewId
            when (call.method) {
                "setupControllerEventChannel" -> {
                    val args = call.arguments as? Map<*, *>
                    val controllerId = args?.get("controllerId") as? Int
                    if (controllerId != null) {
                        setupControllerEventChannel(controllerId)
                        result.success(null)
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
                        SharedPlayerManager.removePlayer(applicationContext, controllerId)
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGUMENT", "Controller ID is required", null)
                    }
                    return@setMethodCallHandler
                }
            }

            val args = call.arguments as? Map<*, *>
            val viewId = args?.get("viewId") as? Number
            val view = viewId?.toLong()?.let { registeredViews[it] }

            if (view != null) {
                view.handleMethodCall(call, result)
            } else {
                result.error("NO_VIEW", "No view found for method call", null)
            }
        }

        // Register asset resolution channel
        val assetChannel = MethodChannel(binding.binaryMessenger, "native_video_player/assets")
        assetChannel.setMethodCallHandler { call, result ->
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

        NpLog.d(TAG, "NativeVideoPlayerPlugin registered with id: $VIEW_TYPE")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NpLog.d(TAG, "NativeVideoPlayerPlugin detached - cleaning up all players")

        // Tear down all controller-level event channels before dropping the messenger
        controllerEventChannels.values.forEach { it.setStreamHandler(null) }
        controllerEventChannels.clear()
        messenger = null

        // Clean up all shared players when the Flutter engine is detached
        // This ensures players are properly disposed when the app is closed/terminated
        SharedPlayerManager.clearAll(binding.applicationContext)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        NpLog.d(TAG, "Plugin attached to activity: ${binding.activity}")
        currentActivity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        NpLog.d(TAG, "Plugin detached from activity for config changes")
        // Don't clear activity - it will be reattached
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        NpLog.d(TAG, "Plugin reattached to activity: ${binding.activity}")
        currentActivity = binding.activity
    }

    override fun onDetachedFromActivity() {
        NpLog.d(TAG, "Plugin detached from activity")
        currentActivity = null
    }
}

/**
 * Factory for creating VideoPlayerView instances
 */
@UnstableApi
class VideoPlayerViewFactory(
    private val messenger: BinaryMessenger,
    private val context: Context
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
            binaryMessenger = messenger
        )

        NativeVideoPlayerPlugin.registerView(view, viewId.toLong())
        return view
    }
}
