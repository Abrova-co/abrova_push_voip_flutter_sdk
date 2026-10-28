/**
 * AbrovaPush VoIP Flutter Plugin
 * Thin wrapper around the native AbrovaPush VoIP SDK
 */
package ir.abrova.push.voip.flutter

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.NewIntentListener
import ir.abrova.push.voip.CallData
import ir.abrova.push.voip.AbrovaPushVoip
import ir.abrova.push.voip.VoipCallback
import ir.abrova.push.voip.VoipConfig

class AbrovaPushVoipPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, NewIntentListener {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "AbrovaPushVoipPlugin"
        private const val CHANNEL_NAME = "ir.abrova.push/voip"

        var instance: AbrovaPushVoipPlugin? = null
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "Plugin attached to engine")
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        instance = this

        // Initialize native SDK
        AbrovaPushVoip.initialize(binding.applicationContext)

        // Set up callback to forward events to Flutter
        AbrovaPushVoip.setCallback(object : VoipCallback {
            override fun onCallAccepted(callData: CallData) {
                invokeFlutterMethod("onCallAccepted", callData.toMap())
            }

            override fun onCallDeclined(callData: CallData) {
                invokeFlutterMethod("onCallDeclined", callData.toMap())
            }

            override fun onCallTimeout(callData: CallData) {
                invokeFlutterMethod("onCallTimeout", callData.toMap())
            }

            override fun onError(error: String) {
                invokeFlutterMethod("onError", error)
            }
        })
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "Plugin detached from engine")
        channel.setMethodCallHandler(null)
        instance = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        Log.d(TAG, "Attached to activity: ${activity?.javaClass?.simpleName}")

        binding.addOnNewIntentListener(this)
        checkActivityIntent(binding.activity.intent)
    }

    override fun onNewIntent(intent: Intent): Boolean {
        Log.d(TAG, "onNewIntent received")
        checkActivityIntent(intent)

        // If we have an initial call, invoke immediately
        AbrovaPushVoip.getInitialCall()?.let { call ->
            Log.d(TAG, "Invoking onCallAccepted from onNewIntent")
            invokeFlutterMethod("onCallAccepted", call.toMap())
        }

        return true
    }

    private fun checkActivityIntent(intent: Intent?) {
        intent?.let {
            if (it.getBooleanExtra("abrova_push_voip_call_accepted", false)) {
                val callDataJson = it.getStringExtra("abrova_push_voip_call_data")
                Log.d(TAG, "Activity launched with VoIP call data: $callDataJson")
                callDataJson?.let { json ->
                    CallData.fromJson(json)?.let { data ->
                        Log.d(TAG, "Setting initial call from activity intent: ${data.callId}")
                        AbrovaPushVoip.setInitialCall(data)
                    }
                }
                it.removeExtra("abrova_push_voip_call_accepted")
                it.removeExtra("abrova_push_voip_call_data")
            }
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "init" -> {
                val configMap = call.arguments as? Map<*, *>
                if (configMap != null) {
                    val config = VoipConfig.fromMap(configMap)
                    AbrovaPushVoip.updateConfig(config)
                    Log.d(TAG, "VoIP initialized with config: $config")

                    // Deliver pending initial call after a short delay
                    mainHandler.postDelayed({
                        AbrovaPushVoip.getInitialCall()?.let { pendingCall ->
                            Log.d(TAG, "Invoking onCallAccepted for pending call: ${pendingCall.callId}")
                            invokeFlutterMethod("onCallAccepted", pendingCall.toMap())
                        }
                    }, 500)
                }
                result.success(null)
            }

            "getInitialCall" -> {
                val initialCall = AbrovaPushVoip.getInitialCall()
                if (initialCall != null) {
                    result.success(initialCall.toMap())
                } else {
                    result.success(null)
                }
            }

            "endCall" -> {
                val callId = call.argument<String>("callId")
                if (callId != null) {
                    AbrovaPushVoip.endCall(callId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "callId is required", null)
                }
            }

            "reportCallConnected" -> {
                val callId = call.argument<String>("callId")
                if (callId != null) {
                    AbrovaPushVoip.reportCallConnected(callId)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "callId is required", null)
                }
            }

            "showIncomingCall" -> {
                val callDataMap = call.arguments as? Map<*, *>
                if (callDataMap != null) {
                    val callData = CallData.fromMap(callDataMap)
                    AbrovaPushVoip.showIncomingCall(callData)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "callData is required", null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun invokeFlutterMethod(method: String, arguments: Any?) {
        mainHandler.post {
            try {
                Log.d(TAG, "Invoking Flutter method: $method")
                if (::channel.isInitialized) {
                    channel.invokeMethod(method, arguments)
                } else {
                    Log.e(TAG, "Channel not initialized")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to invoke Flutter method: ${e.message}")
            }
        }
    }
}
