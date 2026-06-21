package com.callbundle.callbundle_android

import android.content.Context

/**
 * User-customizable, localizable text labels for the call UI.
 *
 * These come from [AndroidCallConfig] on the Dart side and are persisted to
 * [android.content.SharedPreferences] during `configure()`. Persistence is
 * required so that killed-state incoming calls — where a background FCM engine
 * shows the notification without ever calling `configure()` — still render the
 * app's custom/translated labels rather than the English defaults.
 */
data class CallLabels(
    val answer: String = DEFAULT_ANSWER,
    val decline: String = DEFAULT_DECLINE,
    val hangUp: String = DEFAULT_HANG_UP,
    val voiceCall: String = DEFAULT_VOICE_CALL,
    val videoCall: String = DEFAULT_VIDEO_CALL
) {
    /** Returns the subtitle text for the given call type (1 = video). */
    fun callTypeText(callType: Int): String =
        if (callType == 1) videoCall else voiceCall

    companion object {
        private const val PREFS = "callbundle_labels"
        private const val KEY_ANSWER = "answerButtonText"
        private const val KEY_DECLINE = "declineButtonText"
        private const val KEY_HANG_UP = "hangUpButtonText"
        private const val KEY_VOICE = "voiceCallText"
        private const val KEY_VIDEO = "videoCallText"

        private const val DEFAULT_ANSWER = "Accept"
        private const val DEFAULT_DECLINE = "Decline"
        private const val DEFAULT_HANG_UP = "End Call"
        private const val DEFAULT_VOICE_CALL = "Voice Call"
        private const val DEFAULT_VIDEO_CALL = "Video Call"

        /**
         * Persists the label overrides found in the `android` config map.
         * Only keys present in [androidConfig] are written; missing keys keep
         * their previously stored value (or fall back to defaults on load).
         */
        fun save(context: Context, androidConfig: Map<*, *>?) {
            if (androidConfig == null) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putOptionalString(KEY_ANSWER, androidConfig[KEY_ANSWER])
                putOptionalString(KEY_DECLINE, androidConfig[KEY_DECLINE])
                putOptionalString(KEY_HANG_UP, androidConfig[KEY_HANG_UP])
                putOptionalString(KEY_VOICE, androidConfig[KEY_VOICE])
                putOptionalString(KEY_VIDEO, androidConfig[KEY_VIDEO])
                apply()
            }
        }

        /** Loads the persisted labels, falling back to English defaults. */
        fun load(context: Context): CallLabels {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return CallLabels(
                answer = prefs.getString(KEY_ANSWER, null) ?: DEFAULT_ANSWER,
                decline = prefs.getString(KEY_DECLINE, null) ?: DEFAULT_DECLINE,
                hangUp = prefs.getString(KEY_HANG_UP, null) ?: DEFAULT_HANG_UP,
                voiceCall = prefs.getString(KEY_VOICE, null) ?: DEFAULT_VOICE_CALL,
                videoCall = prefs.getString(KEY_VIDEO, null) ?: DEFAULT_VIDEO_CALL
            )
        }

        private fun android.content.SharedPreferences.Editor.putOptionalString(
            key: String,
            value: Any?
        ) {
            val text = value as? String
            if (text != null) putString(key, text)
        }
    }
}
