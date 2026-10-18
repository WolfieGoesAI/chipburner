package com.wolfiegoesai.chipburner

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import com.wolfiegoesai.chipburner.ui.ChipBurnerApp
import com.wolfiegoesai.chipburner.ui.ChipBurnerTheme

class MainActivity : ComponentActivity() {
    private val state: AppState by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            ChipBurnerTheme {
                // Keep the screen on while a job runs: a sleeping phone may cut USB power mid-write.
                LaunchedEffect(state.busy) {
                    if (state.busy) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                ChipBurnerApp(state)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        state.refreshUsb()
    }

    override fun onResume() {
        super.onResume()
        state.refreshUsb()
    }
}
