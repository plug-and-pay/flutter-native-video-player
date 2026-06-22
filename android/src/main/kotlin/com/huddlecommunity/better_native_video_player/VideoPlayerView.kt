package com.huddlecommunity.better_native_video_player

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.pm.ActivityInfo
import android.os.Build
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.annotation.RequiresApi
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

/**
 * Main platform view for the native video player
 * Handles fullscreen natively without creating multiple platform views
 */
@UnstableApi
class VideoPlayerView(
    private val context: Context,
    private val viewId: Long,
    private val args: Map<String, Any>?,
    binaryMessenger: io.flutter.plugin.common.BinaryMessenger
) : PlatformView, VideoPlayerBackend {

    companion object {
        private const val TAG = "VideoPlayerView"
    }

    override val backendViewId: Long get() = viewId

    // The display-independent half (player, handlers, channels, viewport
    // capping, common dispose) lives in the session; this class keeps the
    // Android View display path and native fullscreen.
    private val session: PlayerBackendSession

    // Heavy display path: full Media3 PlayerView (inflates the complete
    // controller UI even with useController = false). Null when the
    // lightweight path is active.
    private val playerView: PlayerView?

    // Lightweight display path (lightweightInlineViews config + hidden
    // controls): bare SurfaceView in an AspectRatioFrameLayout, plus a
    // SubtitleView wired to the player's cues so captions (including the
    // native sidecar track used during PiP/fullscreen) keep rendering.
    private val lightSurfaceView: SurfaceView?
    private val lightListener: Player.Listener?

    // Reports the video's display size to Dart in both display paths so the
    // Flutter sidecar-subtitle overlay can anchor captions to the video's
    // content rect (e.g. portrait fullscreen with a 16:9 video).
    private val videoSizeListener: Player.Listener

    // The view that displays video, whichever path is active; moved between
    // the inline container and the fullscreen dialog.
    private val videoContentView: View

    private val player: ExoPlayer get() = session.player
    private val controllerId: Int? get() = session.controllerId

    // Container that holds the player view
    // This is what Flutter sees - the player view can be moved in/out of it
    private val containerView: FrameLayout

    // Track fullscreen state
    private var isFullScreen: Boolean = false

    // Track disposal state to prevent events after disposal
    private var isDisposed: Boolean = false

    // Fullscreen dialog
    private var fullscreenDialog: Dialog? = null

    // Store original system UI flags and orientation
    private var originalSystemUiVisibility: Int = 0
    private var originalOrientation: Int = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED

    init {
        NpLog.d(TAG, "Creating VideoPlayerView with id: $viewId")

        // Extract initial fullscreen state from args
        isFullScreen = args?.get("isFullScreen") as? Boolean ?: false
        NpLog.d(TAG, "Initial fullscreen state: $isFullScreen")

        session = PlayerBackendSession(
            context = context,
            viewId = viewId,
            args = args,
            binaryMessenger = binaryMessenger,
            onSiblingDisposed = {
                reconnectSurface()
                // Emit current state after reconnecting to ensure UI stays in sync
                session.emitCurrentState()
            }
        )

        // Set fullscreen callback for method handler
        session.methodHandler.onFullscreenRequest = { enterFullscreen ->
            handleFullscreenToggleNative(enterFullscreen)
        }

        // Create the display view: a full PlayerView, or — when the app
        // opted into lightweightInlineViews and this view hides native
        // controls — a bare SurfaceView + SubtitleView in an
        // AspectRatioFrameLayout (PlayerView inflates its complete controller
        // UI even when useController is false).
        val showNativeControls = session.showNativeControls
        val useLightView =
            (args?.get("lightweightInlineViews") as? Boolean ?: false) && !showNativeControls
        if (useLightView) {
            playerView = null
            val contentFrame = AspectRatioFrameLayout(context).apply {
                setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT)
            }
            val surfaceView = SurfaceView(context)
            contentFrame.addView(
                surfaceView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
            val subtitleView = SubtitleView(context).apply {
                setUserDefaultStyle()
                setUserDefaultTextSize()
            }
            contentFrame.addView(
                subtitleView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
            player.setVideoSurfaceView(surfaceView)

            // Seed state for shared players already mid-playback, then track it
            applyLightAspectRatio(contentFrame, player.videoSize)
            subtitleView.setCues(player.currentCues.cues)
            val listener = object : Player.Listener {
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    applyLightAspectRatio(contentFrame, videoSize)
                }

                override fun onCues(cueGroup: CueGroup) {
                    subtitleView.setCues(cueGroup.cues)
                }
            }
            player.addListener(listener)
            lightSurfaceView = surfaceView
            lightListener = listener
            videoContentView = contentFrame
            NpLog.d(TAG, "Lightweight SurfaceView configured (controls hidden)")
        } else {
            lightSurfaceView = null
            lightListener = null
            playerView = PlayerView(context).apply {
                this.player = this@VideoPlayerView.player
                useController = showNativeControls
                controllerShowTimeoutMs = 5000
                controllerHideOnTouch = true

                // Hide unnecessary buttons: settings, next, previous
                setShowNextButton(false)
                setShowPreviousButton(false)
                // Note: There's no direct method to hide settings button, but we can hide it via layout

                // Configure HDR rendering
                if (!session.enableHDR) {
                    NpLog.d(TAG, "🎨 HDR disabled for PlayerView - ExoPlayer will tone-map to SDR")
                    // ExoPlayer handles tone-mapping automatically, but we can hint at the surface level
                    // Note: More explicit control would require custom RenderersFactory
                } else {
                    NpLog.d(TAG, "🎨 HDR enabled for PlayerView")
                }

                NpLog.d(TAG, "PlayerView configured")
            }
            videoContentView = playerView
        }

        // Report the video's display size to Dart so the sidecar subtitle
        // overlay can pin captions to the video's content rect. Covers both
        // display paths; platform views handle crop/rotation natively, so no
        // Dart-side rotation correction is needed.
        videoSizeListener = object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                sendVideoSize(videoSize)
            }
        }
        player.addListener(videoSizeListener)
        sendVideoSize(player.videoSize)

        // For shared players that already existed, ensure surface is properly connected
        // This is crucial when returning to a video after calling releaseResources()
        if (session.isSharedPlayer) {
            NpLog.d(TAG, "Ensuring surface connection for existing shared player")
            videoContentView.post { rebindVideoOutput() }
        }

        // Create container view that holds the player view
        // This allows us to move the player view in/out for fullscreen
        containerView = FrameLayout(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            addView(videoContentView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
        }

        // For shared players, also reconnect when this view is attached to a window.
        // Surface may not be ready in init; attaching ensures we rebind once the view is in the hierarchy.
        if (session.isSharedPlayer) {
            containerView.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(v: View) {
                    containerView.removeOnAttachStateChangeListener(this)
                    reconnectSurface()
                }
                override fun onViewDetachedFromWindow(v: View) {}
            })
        }

        // Set up fullscreen button listener after PlayerView is configured
        // (the lightweight path has no controller, hence no fullscreen button)
        playerView?.let { pv -> pv.post {
            pv.setFullscreenButtonClickListener { enteringFullScreen ->
                NpLog.d(TAG, "Fullscreen button clicked, wants to enter: $enteringFullScreen, current state: $isFullScreen")
                
                // The button sends us the state it wants to ENTER
                // If we're already in that state, the button is out of sync (e.g., when Flutter triggered fullscreen)
                // In that case, we should do the opposite action
                val shouldEnter = if (isFullScreen && enteringFullScreen) {
                    // Button wants to enter fullscreen, but we're already in fullscreen
                    // This means the button icon is out of sync - we should exit instead
                    NpLog.d(TAG, "Button out of sync: wants to enter but already in fullscreen, exiting instead")
                    false
                } else if (!isFullScreen && !enteringFullScreen) {
                    // Button wants to exit fullscreen, but we're not in fullscreen
                    // This means the button icon is out of sync - we should enter instead
                    NpLog.d(TAG, "Button out of sync: wants to exit but not in fullscreen, entering instead")
                    true
                } else {
                    // Button is in sync with our state
                    enteringFullScreen
                }
                
                handleFullscreenToggleNative(shouldEnter)
            }
        } }

        // Handlers, observer, event channel and SharedPlayerManager
        // registration all live in the session (created above).

        NpLog.d(TAG, "VideoPlayerView initialized")
    }

    override fun getView(): View {
        // Return the container view, not the player view directly
        // This allows us to move the player view in/out for fullscreen
        return containerView
    }

    /**
     * Handles method calls from Flutter
     */
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setShowNativeControls" -> {
                val show = call.argument<Boolean>("show") ?: true
                if (playerView != null) {
                    playerView.useController = show
                } else if (show) {
                    // Documented lightweightInlineViews limitation: a bare
                    // SurfaceView cannot render controls; recreate the view
                    // with showNativeControls instead.
                    NpLog.w(TAG, "setShowNativeControls(true) ignored - view $viewId is a lightweight SurfaceView")
                }
                result.success(null)
            }
            "ensureSurfaceConnected" -> {
                // Called when reconnecting after all platform views were disposed (list→detail→back).
                reconnectSurface()
                result.success(null)
            }
            "setViewportSize" -> {
                val width = (call.argument<Number>("width"))?.toInt() ?: 0
                val height = (call.argument<Number>("height"))?.toInt() ?: 0
                session.setViewportSize(width, height, isFullScreen)
                result.success(null)
            }
            else -> {
                session.methodHandler.handleMethodCall(call, result)
            }
        }
    }

    /**
     * Handles fullscreen toggle natively by moving the player view between container and fullscreen dialog
     * This uses ONE PlayerView instead of creating multiple platform views
     */
    private fun handleFullscreenToggleNative(enteringFullScreen: Boolean) {
        // Don't handle fullscreen if already disposed
        if (isDisposed) {
            NpLog.d(TAG, "Ignoring fullscreen toggle - view is disposed")
            return
        }

        // Get activity from plugin (most reliable) or context
        val activity = NativeVideoPlayerPlugin.getActivity() ?: getActivity(context)
        if (activity == null) {
            NpLog.e(TAG, "Cannot get Activity, cannot handle fullscreen")
            return
        }

        NpLog.d(TAG, "Got activity: ${activity.javaClass.simpleName}")

        if (enteringFullScreen) {
            // Fullscreen shows the full display: lift the viewport quality cap
            session.clearViewportConstraints()
            enterFullscreenNative(activity)

            // Notify Flutter that fullscreen was entered
            session.eventHandler.sendEvent("fullscreenChange", mapOf("isFullscreen" to true))
        } else {
            exitFullscreenNative(activity)
            session.restoreViewportConstraints()

            // Notify Flutter that fullscreen was exited
            session.eventHandler.sendEvent("fullscreenChange", mapOf("isFullscreen" to false))
        }

        // Update internal state
        isFullScreen = enteringFullScreen

        // Update the fullscreen button icon to reflect the new state
        // Use a delay to ensure the view transition has completed
        playerView?.postDelayed({
            updateFullscreenButtonState(enteringFullScreen)
        }, 100)
    }

    /**
     * Gets the Activity from a Context, handling ContextWrapper cases
     */
    private fun getActivity(context: Context?): Activity? {
        if (context == null) {
            NpLog.e(TAG, "Context is null")
            return null
        }

        NpLog.d(TAG, "Context type: ${context.javaClass.name}")

        if (context is Activity) {
            NpLog.d(TAG, "Context is Activity")
            return context
        }

        if (context is android.content.ContextWrapper) {
            NpLog.d(TAG, "Context is ContextWrapper, unwrapping...")
            return getActivity(context.baseContext)
        }

        NpLog.e(TAG, "Context is neither Activity nor ContextWrapper")
        return null
    }

    /**
     * Enters fullscreen by removing the player view from the container and adding it to a fullscreen dialog
     */
    private fun enterFullscreenNative(activity: Activity) {
        NpLog.d(TAG, "Entering fullscreen natively")

        // Store original orientation
        originalOrientation = activity.requestedOrientation

        // Hide system UI on the activity window
        activity.window?.let { activityWindow ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val controller = WindowCompat.getInsetsController(activityWindow, activityWindow.decorView)
                controller.hide(WindowInsetsCompat.Type.systemBars())
                controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            } else {
                @Suppress("DEPRECATION")
                activityWindow.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    )
            }
        }

        // Remove player view from container (important: remove from parent first!)
        (videoContentView.parent as? ViewGroup)?.removeView(videoContentView)

        // Create fullscreen dialog with black background and no title bar
        fullscreenDialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen).apply {
            setContentView(videoContentView)

            // Handle back button to exit fullscreen
            setOnKeyListener { _, keyCode, event ->
                if (keyCode == android.view.KeyEvent.KEYCODE_BACK && event.action == android.view.KeyEvent.ACTION_UP) {
                    // Trigger the fullscreen toggle to exit (it will handle state and events)
                    videoContentView.post {
                        handleFullscreenToggleNative(false)
                    }
                    true
                } else {
                    false
                }
            }

            // Handle dialog dismissal
            setOnDismissListener {
                // Ensure we exit fullscreen if dialog is dismissed
                if (isFullScreen) {
                    exitFullscreenNative(activity)
                    isFullScreen = false
                }
            }

            show()
        }

        // Set fullscreen mode on dialog window
        fullscreenDialog?.window?.let { window ->
            // Make dialog cover the entire screen including status bar and navigation bar
            window.setLayout(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT
            )

            // Draw over the status bar and navigation bar areas
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                window.attributes.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }

            // Set window flags to cover everything
            window.setFlags(
                WindowManager.LayoutParams.FLAG_FULLSCREEN
                    or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                    or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN
                    or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                    or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Android 11+ API
                window.setDecorFitsSystemWindows(false)
                val controller = WindowCompat.getInsetsController(window, window.decorView)
                controller.hide(WindowInsetsCompat.Type.systemBars())
                controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    )
            }

            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        // Allow all orientations in fullscreen
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR

        NpLog.d(TAG, "Entered fullscreen natively")
    }

    /**
     * Exits fullscreen by removing the player view from the dialog and adding it back to the container
     */
    private fun exitFullscreenNative(activity: Activity) {
        NpLog.d(TAG, "Exiting fullscreen natively")

        fullscreenDialog?.let { dialog ->
            // Remove player view from dialog
            (videoContentView.parent as? ViewGroup)?.removeView(videoContentView)

            // Dismiss dialog
            dialog.dismiss()
            fullscreenDialog = null
        }

        // Add player view back to container
        if (videoContentView.parent == null) {
            containerView.addView(videoContentView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
        }

        // Force the display view to reattach its surface to the player
        // This is necessary because moving the view between parents can disconnect the surface
        videoContentView.post { rebindVideoOutput() }

        // Restore system UI on the activity window
        activity.window?.let { activityWindow ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val controller = WindowCompat.getInsetsController(activityWindow, activityWindow.decorView)
                controller.show(WindowInsetsCompat.Type.systemBars())
            } else {
                @Suppress("DEPRECATION")
                activityWindow.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
            }
        }

        // Restore original orientation
        activity.requestedOrientation = originalOrientation

        NpLog.d(TAG, "Exited fullscreen natively")
    }

    /**
     * Updates the fullscreen button icon to match the current fullscreen state
     * This is needed when fullscreen is toggled from Flutter rather than from the button itself
     */
    private fun updateFullscreenButtonState(isFullscreen: Boolean) {
        val playerView = playerView ?: return
        try {
            // Access the fullscreen button using reflection
            // The button is part of the PlayerView's controller
            val fullscreenButton = playerView.findViewById<android.widget.ImageButton>(
                androidx.media3.ui.R.id.exo_fullscreen
            )
            
            if (fullscreenButton != null) {
                NpLog.d(TAG, "Fullscreen button found, current selected state: ${fullscreenButton.isSelected}, setting to: $isFullscreen")
                
                // Try multiple approaches to update the button icon
                
                // Approach 1: Update selected state
                fullscreenButton.isSelected = isFullscreen
                fullscreenButton.refreshDrawableState()
                
                // Approach 2: Update content description (helps with accessibility)
                fullscreenButton.contentDescription = if (isFullscreen) "Exit fullscreen" else "Enter fullscreen"
                
                // Approach 3: Directly set the image resource based on fullscreen state
                // ExoPlayer uses exo_icon_fullscreen_enter and exo_icon_fullscreen_exit
                try {
                    val iconResourceId = if (isFullscreen) {
                        androidx.media3.ui.R.drawable.exo_icon_fullscreen_exit
                    } else {
                        androidx.media3.ui.R.drawable.exo_icon_fullscreen_enter
                    }
                    fullscreenButton.setImageResource(iconResourceId)
                    NpLog.d(TAG, "Set fullscreen button icon directly to: ${if (isFullscreen) "exit" else "enter"}")
                } catch (e: Exception) {
                    NpLog.w(TAG, "Could not set fullscreen button icon directly: ${e.message}")
                }
                
                // Force redraw
                fullscreenButton.invalidate()
                
                NpLog.d(TAG, "Fullscreen button state updated successfully (new selected=${fullscreenButton.isSelected})")
            } else {
                NpLog.w(TAG, "Fullscreen button not found in PlayerView")
            }
        } catch (e: Exception) {
            NpLog.e(TAG, "Error updating fullscreen button state: ${e.message}", e)
        }
    }

    // PiP is now handled by the floating package on the Dart side
    // All PiP-related methods have been removed

    /**
     * Reconnects the player's surface to this view's display surface
     * This is called when another platform view using the same shared player is disposed
     */
    private fun reconnectSurface() {
        if (isDisposed) {
            NpLog.d(TAG, "Ignoring surface reconnect - view is disposed")
            return
        }

        NpLog.d(TAG, "Reconnecting surface for view $viewId (notified by another view disposal)")
        videoContentView.post { rebindVideoOutput() }
    }

    /**
     * Detaches and reattaches the player's video output so the surface
     * reconnects, whichever display path is active.
     */
    private fun rebindVideoOutput() {
        val playerView = playerView
        if (playerView != null) {
            val currentPlayer = playerView.player
            if (currentPlayer != null) {
                playerView.player = null
                playerView.player = currentPlayer
                NpLog.d(TAG, "Surface reconnected (PlayerView) for view $viewId")
            } else {
                NpLog.w(TAG, "Cannot reconnect surface - player is null")
            }
        } else {
            val surfaceView = lightSurfaceView ?: return
            player.clearVideoSurfaceView(surfaceView)
            player.setVideoSurfaceView(surfaceView)
            NpLog.d(TAG, "Surface reconnected (SurfaceView) for view $viewId")
        }
    }

    /**
     * Sizes the lightweight content frame to the video's aspect ratio (what
     * PlayerView's internal AspectRatioFrameLayout does in the heavy path).
     */
    private fun applyLightAspectRatio(frame: AspectRatioFrameLayout, videoSize: VideoSize) {
        if (videoSize.width == 0 || videoSize.height == 0) return
        frame.setAspectRatio(videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height)
    }

    /**
     * Reports the video's display size to Dart (same payload the texture path
     * emits), so the Flutter sidecar-subtitle overlay can letterbox-match its
     * captions to the video. Platform views handle crop/rotation natively, so
     * [rotationCorrection] is always 0.
     */
    private fun sendVideoSize(videoSize: VideoSize) {
        if (videoSize.width == 0 || videoSize.height == 0) return
        session.eventHandler.sendEvent(
            "videoSize",
            mapOf(
                "width" to (videoSize.width * videoSize.pixelWidthHeightRatio).toInt(),
                "height" to videoSize.height,
                "rotationCorrection" to 0
            )
        )
    }

    override fun dispose() {
        NpLog.d(TAG, "VideoPlayerView dispose for id: $viewId")

        // Mark as disposed to prevent any further events
        isDisposed = true

        // Remove this view from the plugin's static registry (otherwise the
        // map keeps a strong reference to every view ever created)
        NativeVideoPlayerPlugin.unregisterView(viewId)

        // Exit fullscreen if active
        if (isFullScreen) {
            val activity = getActivity(context)
            if (activity != null) {
                exitFullscreenNative(activity)
            }
        }

        // Dismiss fullscreen dialog if it exists
        fullscreenDialog?.dismiss()
        fullscreenDialog = null

        // Remove fullscreen button listener to prevent clicks during disposal
        playerView?.setFullscreenButtonClickListener(null)

        NpLog.d(TAG, "dispose() - controllerId: $controllerId")

        // Remove the light display path's own listener before the common dispose
        lightListener?.let { player.removeListener(it) }
        player.removeListener(videoSizeListener)

        session.disposeCommon(detachOutput = {
            // IMPORTANT: For shared players, detach the player from this view's display
            // surface to prevent disconnecting it. Another platform view may still be
            // using the player. If we don't detach here, disposing this view will
            // disconnect the player's surface, leaving other views without video frames.
            playerView?.player = null
            lightSurfaceView?.let { player.clearVideoSurfaceView(it) }
            NpLog.d(TAG, "Detached player from display surface to preserve it for other views")
        })
    }
}

