package com.wolfiegoesai.chipburner

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import com.wolfiegoesai.chipburner.ui.ChipBurnerApp
import com.wolfiegoesai.chipburner.ui.ChipBurnerTheme

class MainActivity : ComponentActivity() {
    private val state: AppState by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The screen stays on while ChipBurner is open: a sleeping phone may cut USB power to the programmer.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContent {
            ChipBurnerTheme {
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
