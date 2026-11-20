package com.cloudwebrtc.webrtc.audio;

import android.content.Context;
import android.media.AudioManager;
import android.media.MediaRecorder;
import android.os.Build;
import android.util.Log;

import androidx.annotation.Nullable;

import org.webrtc.audio.JavaAudioDeviceModule;

/**
 * Chooses the microphone audio source for the JavaAudioDeviceModule, set with the
 * {@code androidAudioSource} initialize option.
 * <p>
 * Capturing from {@link MediaRecorder.AudioSource#VOICE_COMMUNICATION} opens the platform's VoIP
 * input path, where the device applies its own speech processing (echo cancellation, noise
 * suppression and, on many phones, OEM voice isolation). That processing treats music as noise.
 * Every other value captures from a non-VoIP source with the platform AcousticEchoCanceler and
 * NoiseSuppressor effects off, leaving echo and noise to WebRTC's software audio processing,
 * driven by the getUserMedia constraints. MIC and CAMCORDER may still carry OEM processing.
 * <p>
 * VOICE_RECOGNITION, UNPROCESSED and MIC aren't privacy-sensitive, and WebRtcAudioRecord offers
 * no way to call AudioRecord.Builder#setPrivacySensitive, so on Android 10 and 11 another app
 * capturing audio in the foreground can silence this capture.
 */
public final class CaptureAudioSource {

    private static final String TAG = "CaptureAudioSource";

    public static final String OPTION_KEY = "androidAudioSource";

    /** VOICE_RECOGNITION. The default. */
    public static final String MUSIC = "music";

    private CaptureAudioSource() {}

    /**
     * Configures the builder for the requested source. Leaves it untouched for
     * {@code voiceCommunication}, which keeps the upstream behaviour.
     */
    public static void apply(Context context, JavaAudioDeviceModule.Builder builder,
                             @Nullable String option) {
        int source = resolve(context, option);
        Log.i(TAG, "androidAudioSource " + (option == null ? MUSIC + " (default)" : option)
                + " -> " + name(source));
        if (source == MediaRecorder.AudioSource.VOICE_COMMUNICATION) {
            return;
        }
        builder.setAudioSource(source)
                .setUseHardwareAcousticEchoCanceler(false)
                .setUseHardwareNoiseSuppressor(false);
    }

    static int resolve(Context context, @Nullable String option) {
        if (option == null) {
            return MediaRecorder.AudioSource.VOICE_RECOGNITION;
        }
        switch (option) {
            case MUSIC:
            case "voiceRecognition":
                return MediaRecorder.AudioSource.VOICE_RECOGNITION;
            case "voiceCommunication":
                return MediaRecorder.AudioSource.VOICE_COMMUNICATION;
            case "unprocessed":
                return unprocessedSupported(context)
                        ? MediaRecorder.AudioSource.UNPROCESSED
                        : MediaRecorder.AudioSource.VOICE_RECOGNITION;
            case "mic":
                return MediaRecorder.AudioSource.MIC;
            case "camcorder":
                return MediaRecorder.AudioSource.CAMCORDER;
            default:
                Log.w(TAG, "Unknown androidAudioSource '" + option + "', using " + MUSIC);
                return MediaRecorder.AudioSource.VOICE_RECOGNITION;
        }
    }

    // UNPROCESSED behaves like DEFAULT (MIC) where the device doesn't report support for it, so fall
    // back to VOICE_RECOGNITION, the one source the CDD requires to have noise reduction and AGC
    // off by default. It is also the default: the CDD calibrates UNPROCESSED about 18 dB quieter,
    // more than WebRTC's fixed-digital AGC on Android can make up.
    private static boolean unprocessedSupported(Context context) {
        AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
                && audioManager != null
                && "true".equals(audioManager.getProperty(
                        AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED));
    }

    private static String name(int source) {
        switch (source) {
            case MediaRecorder.AudioSource.VOICE_COMMUNICATION:
                return "VOICE_COMMUNICATION";
            case MediaRecorder.AudioSource.UNPROCESSED:
                return "UNPROCESSED";
            case MediaRecorder.AudioSource.VOICE_RECOGNITION:
                return "VOICE_RECOGNITION";
            case MediaRecorder.AudioSource.MIC:
                return "MIC";
            case MediaRecorder.AudioSource.CAMCORDER:
                return "CAMCORDER";
            default:
                return String.valueOf(source);
        }
    }
}
