package com.wolfiegoesai.chipburner.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.wolfiegoesai.chipburner.R

object C {
    val ground = Color(0xFF15171A)
    val card = Color(0xFF1E2125)
    val raised = Color(0xFF2A2E33)
    val field = Color(0xFF22262A)
    val bar = Color(0xFF1B1E21)
    val line = Color(0xFF3A3F45)
    val text = Color(0xFFECE8E1)
    val text2 = Color(0xFFA39E95)
    val text3 = Color(0xFF8E8981)
    val amber = Color(0xFFF2A33A)
    val amberLight = Color(0xFFFFC170)
    val amberDim = Color(0xFF3A2E1A)
    val onAmber = Color(0xFF1B1408)
    val green = Color(0xFF9FD8A8)
    val greenBg = Color(0xFF1F2A22)
    val greenDot = Color(0xFF6CCB7B)
    val red = Color(0xFFFF9A8B)
    val redBg = Color(0xFF3A1F1C)
    val uv = Color(0xFF8F86F0)
}

val Sans = FontFamily(
    Font(R.font.plex_sans_regular, FontWeight.Normal),
    Font(R.font.plex_sans_medium, FontWeight.Medium),
    Font(R.font.plex_sans_semibold, FontWeight.SemiBold),
)
val Mono = FontFamily(
    Font(R.font.plex_mono_regular, FontWeight.Normal),
    Font(R.font.plex_mono_semibold, FontWeight.SemiBold),
)

private val base = TextStyle(fontFamily = Sans, color = C.text)

val AppTypography = Typography(
    headlineSmall = base.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
    titleLarge = base.copy(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = base.copy(fontSize = 16.sp, fontWeight = FontWeight.Medium),
    bodyLarge = base.copy(fontSize = 16.sp),
    bodyMedium = base.copy(fontSize = 14.sp),
    bodySmall = base.copy(fontSize = 12.sp, color = C.text2),
    labelLarge = base.copy(fontSize = 15.sp, fontWeight = FontWeight.Medium),
    labelMedium = base.copy(fontSize = 12.sp, fontWeight = FontWeight.Medium),
    labelSmall = base.copy(fontSize = 11.sp),
)

@Composable
fun ChipBurnerTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = C.amber, onPrimary = C.onAmber, primaryContainer = C.amberDim, onPrimaryContainer = C.amberLight,
            secondary = C.uv, background = C.ground, onBackground = C.text, surface = C.card, onSurface = C.text,
            surfaceVariant = C.raised, onSurfaceVariant = C.text2, outline = C.line,
            surfaceContainer = C.bar, surfaceContainerHigh = C.card, surfaceContainerLow = C.ground,
            secondaryContainer = C.amberDim, onSecondaryContainer = C.amberLight,
            error = C.red, errorContainer = C.redBg,
        ),
        typography = AppTypography,
        content = content,
    )
}
