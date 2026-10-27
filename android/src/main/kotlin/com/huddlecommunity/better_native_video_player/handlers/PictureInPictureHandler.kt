package com.huddlecommunity.better_native_video_player.handlers

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import com.huddlecommunity.better_native_video_player.NpLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android picture-in-picture for the Dart fullscreen player.
 *
 * On Android the whole activity becomes the PiP window, so this works on the
 * activity rather than on a player view. The Dart controller polls
 * [isInPictureInPictureMode] while fullscreen, arms automatic PiP on leave
 * (API 31+) while fullscreen and cancels it when fullscreen ends.
 */
class PictureInPictureHandler(
    private val activityProvider: () -> Activity?
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "PictureInPictureHandler"
        const val CHANNEL_NAME = "native_video_player/pip"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityProvider()
        when (call.method) {
            "isAvailable" -> result.success(activity?.let { isAvailable(it) })
            "isInPictureInPictureMode" -> result.success(activity?.isInPictureInPictureMode == true)
            "enable" -> enable(activity, call, result)
            "cancelAutoEnter" -> {
                cancelAutoEnter(activity)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun isAvailable(activity: Activity): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun enable(activity: Activity?, call: MethodCall, result: MethodChannel.Result) {
        if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }

        val params = PictureInPictureParams.Builder()
            .setAspectRatio(
                Rational(
                    call.argument<Int>("numerator") ?: 16,
                    call.argument<Int>("denominator") ?: 9
                )
            )
        val autoEnter = call.argument<Boolean>("autoEnter") ?: false

        try {
            if (!autoEnter) {
                result.success(activity.enterPictureInPictureMode(params.build()))
                return
            }

            // Automatic entry on leave exists from Android 12; earlier versions
            // only enter on an explicit request.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                result.error(
                    "AUTO_ENTER_UNAVAILABLE",
                    "Automatic picture-in-picture needs Android 12 (API 31)",
                    "Current SDK: ${Build.VERSION.SDK_INT}"
                )
                return
            }

            activity.setPictureInPictureParams(params.setAutoEnterEnabled(true).build())
            result.success(true)
        } catch (e: IllegalStateException) {
            // Thrown when the activity does not declare supportsPictureInPicture
            // or the device has PiP turned off.
            NpLog.e(TAG, "Picture-in-picture failed: ${e.message}", e)
            result.error("PIP_FAILED", e.message, null)
        }
    }

    private fun cancelAutoEnter(activity: Activity?) {
        if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            activity.setPictureInPictureParams(
                PictureInPictureParams.Builder().setAutoEnterEnabled(false).build()
            )
        } catch (e: IllegalStateException) {
            NpLog.e(TAG, "Cancelling automatic picture-in-picture failed: ${e.message}", e)
        }
    }
}
