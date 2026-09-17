package com.sebb7.farrelay.settings

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Immutable snapshot handed to the IO layer so it never reads UI state off-thread. */
data class BridgeConfig(
    val sshHost: String,
    val sshPort: Int,
    val sshUser: String,
    val authMode: SSHAuthMode,
    val password: String,
    val privateKeyPem: String,
    val privateKeyPassphrase: String,
    val remoteCommand: String,
)

/**
 * All persisted configuration, mirroring the iOS/macOS `AppSettings`. Backed by
 * [android.content.SharedPreferences] with the same `farrelay.*` key names as the
 * Swift `UserDefaults` store, so the model lines up one-to-one across ports.
 *
 * Fields are Compose state, so the settings UI observes them directly.
 */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("farrelay", Context.MODE_PRIVATE)

    // SSH bridge
    var sshHost by mutableStateOf(prefs.getString(K.SSH_HOST, "") ?: "")
    var sshPort by mutableStateOf(prefs.getInt(K.SSH_PORT, 22))
    var sshUser by mutableStateOf(prefs.getString(K.SSH_USER, "") ?: "")
    var sshAuthMode by mutableStateOf(SSHAuthMode.from(prefs.getString(K.SSH_AUTH_MODE, null)))
    var sshPassword by mutableStateOf(prefs.getString(K.SSH_PASSWORD, "") ?: "")
    var sshPrivateKeyPem by mutableStateOf(prefs.getString(K.SSH_KEY_PEM, "") ?: "")
    var sshPrivateKeyPassphrase by mutableStateOf(prefs.getString(K.SSH_KEY_PASS, "") ?: "")
    var remoteFarRelayCommand by mutableStateOf(prefs.getString(K.REMOTE_CMD, "farrelay") ?: "farrelay")

    // NVDA Remote relay (forwarded as `farrelay --ipc` args on the bridge)
    var relayHost by mutableStateOf(prefs.getString(K.RELAY_HOST, "nvdaremote.com") ?: "nvdaremote.com")
    var relayPort by mutableStateOf(prefs.getInt(K.RELAY_PORT, 6837))
    var channel by mutableStateOf(prefs.getString(K.CHANNEL, "") ?: "")
    var fingerprint by mutableStateOf(prefs.getString(K.FINGERPRINT, "") ?: "")
    var insecure by mutableStateOf(prefs.getBoolean(K.INSECURE, false))

    // Local input
    var nvdaModifier by mutableStateOf(NvdaModifier.from(prefs.getString(K.NVDA_MOD, null)))
    var leftAltMapping by mutableStateOf(ModifierMapping.from(prefs.getString(K.LEFT_ALT, null), ModifierMapping.Alt))
    var rightAltMapping by mutableStateOf(ModifierMapping.from(prefs.getString(K.RIGHT_ALT, null), ModifierMapping.Alt))
    var metaMapping by mutableStateOf(ModifierMapping.from(prefs.getString(K.META, null), ModifierMapping.Win))

    // Speech (Android TextToSpeech rate is a multiplier; 1.0 == normal)
    var speechRate by mutableStateOf(prefs.getFloat(K.SPEECH_RATE, 1.0f))
    var voiceId by mutableStateOf(prefs.getString(K.VOICE_ID, null))

    fun save() {
        prefs.edit().apply {
            putString(K.SSH_HOST, sshHost)
            putInt(K.SSH_PORT, sshPort)
            putString(K.SSH_USER, sshUser)
            putString(K.SSH_AUTH_MODE, sshAuthMode.wire)
            putString(K.SSH_PASSWORD, sshPassword)
            putString(K.SSH_KEY_PEM, sshPrivateKeyPem)
            putString(K.SSH_KEY_PASS, sshPrivateKeyPassphrase)
            putString(K.REMOTE_CMD, remoteFarRelayCommand)
            putString(K.RELAY_HOST, relayHost)
            putInt(K.RELAY_PORT, relayPort)
            putString(K.CHANNEL, channel)
            putString(K.FINGERPRINT, fingerprint)
            putBoolean(K.INSECURE, insecure)
            putString(K.NVDA_MOD, nvdaModifier.wire)
            putString(K.LEFT_ALT, leftAltMapping.wire)
            putString(K.RIGHT_ALT, rightAltMapping.wire)
            putString(K.META, metaMapping.wire)
            putFloat(K.SPEECH_RATE, speechRate)
            if (voiceId != null) putString(K.VOICE_ID, voiceId) else remove(K.VOICE_ID)
        }.apply()
    }

    fun snapshot(): BridgeConfig = BridgeConfig(
        sshHost = sshHost.trim(),
        sshPort = sshPort,
        sshUser = sshUser.trim(),
        authMode = sshAuthMode,
        password = sshPassword,
        privateKeyPem = sshPrivateKeyPem,
        privateKeyPassphrase = sshPrivateKeyPassphrase,
        remoteCommand = remoteCommand(),
    )

    /**
     * Build the remote `farrelay --ipc` invocation for the SSH exec channel.
     * Whitespace / shell-meta in arguments is shell-quoted so they can't break
     * out of the remote command. Mirrors the Swift `remoteCommand()`.
     */
    fun remoteCommand(): String {
        val argv = mutableListOf<String>()
        val cmd = remoteFarRelayCommand.trim()
        argv += cmd.ifEmpty { "farrelay" }
        argv += "--ipc"
        argv += "--host"; argv += relayHost
        argv += "--port"; argv += relayPort.toString()
        argv += "--channel"; argv += channel
        if (fingerprint.isNotEmpty()) {
            argv += "--fingerprint"; argv += fingerprint
        }
        if (insecure) argv += "--insecure"
        return argv.joinToString(" ") { shellQuote(it) }
    }

    private object K {
        const val SSH_HOST = "farrelay.sshHost"
        const val SSH_PORT = "farrelay.sshPort"
        const val SSH_USER = "farrelay.sshUser"
        const val SSH_AUTH_MODE = "farrelay.sshAuthMode"
        const val SSH_PASSWORD = "farrelay.sshPassword"
        const val SSH_KEY_PEM = "farrelay.sshPrivateKeyPEM"
        const val SSH_KEY_PASS = "farrelay.sshPrivateKeyPassphrase"
        const val REMOTE_CMD = "farrelay.remoteFarRelayCommand"
        const val RELAY_HOST = "farrelay.relayHost"
        const val RELAY_PORT = "farrelay.relayPort"
        const val CHANNEL = "farrelay.channel"
        const val FINGERPRINT = "farrelay.fingerprint"
        const val INSECURE = "farrelay.insecure"
        const val NVDA_MOD = "farrelay.nvdaModifier"
        const val LEFT_ALT = "farrelay.leftAltMapping"
        const val RIGHT_ALT = "farrelay.rightAltMapping"
        const val META = "farrelay.metaMapping"
        const val SPEECH_RATE = "farrelay.speechRate"
        const val VOICE_ID = "farrelay.voiceIdentifier"
    }
}

/** POSIX single-quote shell quoting. Equivalent to Python's `shlex.quote`. */
private fun shellQuote(s: String): String {
    if (s.isEmpty()) return "''"
    val safe = s.all { ch -> ch.isLetterOrDigit() || ch in "@%+=:,./-_" }
    if (safe) return s
    return "'" + s.replace("'", "'\\''") + "'"
}
