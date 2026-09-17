package com.sebb7.farrelay

import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.sebb7.farrelay.input.KeyForwarder
import com.sebb7.farrelay.ipc.IpcCommand
import com.sebb7.farrelay.ui.RootScreen
import com.sebb7.farrelay.ui.theme.FarRelayTheme

/**
 * Hosts the Compose UI and captures the hardware keyboard while the app is
 * focused (the iOS-style focused-only model). If the optional
 * [com.sebb7.farrelay.input.FarRelayAccessibilityService] is enabled it captures
 * system-wide instead — including combos Android intercepts before a focused
 * app (Alt+Tab, Meta) — so we defer to it here to avoid double-handling.
 */
class MainActivity : ComponentActivity() {
    private val container by lazy { (application as FarRelayApp).container }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            FarRelayTheme {
                RootScreen(container)
            }
        }
    }

    override fun onPause() {
        super.onPause()
        // We stop receiving key-ups once unfocused; release anything held on the
        // slave so a backgrounded app can't leave a modifier latched. (When the
        // accessibility service is driving, it keeps receiving events, so leave it.)
        if (!container.accessibilityRunning.value) {
            KeyForwarder.reset()
            if (container.bridge.forwarding.value) {
                container.bridge.send(IpcCommand.ReleaseAll)
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // When the accessibility service is active it captures system-wide; don't
        // double-handle here (consumed events never reach us anyway).
        if (!container.accessibilityRunning.value && KeyForwarder.handle(container, event)) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
