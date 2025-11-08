package com.huddlecommunity.better_native_video_player

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
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

        fun registerView(view: VideoPlayerView, viewId: Long) {
            Log.d(TAG, "Registering view with id: $viewId")
            registeredViews[viewId] = view
        }

        fun unregisterView(viewId: Long) {
            Log.d(TAG, "Unregistering view with id: $viewId")
            registeredViews.remove(viewId)
        }

        fun getActivity(): Activity? = currentActivity

        /**
         * Get all registered video player views
         * Used by MainActivity to trigger automatic PiP on user leave hint
         */
        fun getAllViews(): Collection<VideoPlayerView> = registeredViews.values
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "Registering NativeVideoPlayerPlugin")

        // Register platform view factory
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            VideoPlayerViewFactory(binding.binaryMessenger, binding.applicationContext)
        )

        // Register method channel for forwarding calls to specific views
        val channel = MethodChannel(binding.binaryMessenger, VIEW_TYPE)
        channel.setMethodCallHandler { call, result ->
            Log.d(TAG, "Plugin received method call: ${call.method}")

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
                                Log.d(TAG, "Extracting asset '$assetPath' to '${outputFile.absolutePath}'")
                                binding.applicationContext.assets.open(assetPath).use { inputStream ->
                                    outputFile.outputStream().use { outputStream ->
                                        inputStream.copyTo(outputStream)
                                    }
                                }
                            } else {
                                Log.d(TAG, "Asset already extracted at '${outputFile.absolutePath}'")
                            }

                            Log.d(TAG, "Resolved asset '$assetKey' to '${outputFile.absolutePath}'")
                            result.success(outputFile.absolutePath)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to resolve asset: ${e.message}", e)
                            result.error("ASSET_ERROR", "Failed to resolve asset: ${e.message}", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Asset key is required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        Log.d(TAG, "NativeVideoPlayerPlugin registered with id: $VIEW_TYPE")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "NativeVideoPlayerPlugin detached")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        Log.d(TAG, "Plugin attached to activity: ${binding.activity}")
        currentActivity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        Log.d(TAG, "Plugin detached from activity for config changes")
        // Don't clear activity - it will be reattached
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        Log.d(TAG, "Plugin reattached to activity: ${binding.activity}")
        currentActivity = binding.activity
    }

    override fun onDetachedFromActivity() {
        Log.d(TAG, "Plugin detached from activity")
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
        Log.d(TAG, "Creating VideoPlayerView with id: $viewId")

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
