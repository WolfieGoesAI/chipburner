package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.wolfiegoesai.chipburner.ChipPinout

private val PinRed = Color(0xFFFF8A80)
private val PinBlue = Color(0xFF82B1FF)
private val PinGreen = Color(0xFF9FE0AA)
private val PinPurple = Color(0xFFC3B5FF)

private fun pinColor(p: ChipPinout, index: Int): Color {
    val l = p.pins[index].uppercase()
    if (l == "VCC" || l == "VDD") return PinRed
    if (l == "GND" || l == "VSS") return PinBlue
    if (l.contains("VPP")) return C.amber
    if (l == "NC" || l == "–") return C.text3
    return when (p.roles.getOrNull(index)) {
        'o' -> PinGreen
        'c' -> C.amber
        'b' -> PinPurple
        else -> C.text
    }
}

/** Full-screen pinout drawing for a phone. */
@Composable
fun PinoutDialog(chip: String, pinout: ChipPinout?, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(color = C.ground, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Eyebrow("Pinout")
                        Text(pinout?.title ?: chip, fontFamily = Sans, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    }
                    TextButton(onClick = onDismiss) { Text("Close", color = C.amber, fontFamily = Sans) }
                }
                if (pinout == null) {
                    Text("No pinout for $chip. ChipBurner has pinouts for standard (JEDEC) EPROMs, EEPROMs, flash and SRAM in DIP and PLCC32, GALs, 8-pin serial memories, the common AVR, PIC and 8051 chips, and the logic chips in the test database. For this one, please check its data sheet.",
                        fontFamily = Sans, fontSize = 14.sp, color = C.text2)
                } else {
                    if (pinout.plcc32) PlccView(pinout) else DipView(pinout)
                    Legend(pinout)
                    for (n in pinout.notes) Text(n, fontFamily = Sans, fontSize = 13.sp, color = C.text2)
                }
            }
        }
    }
}

@Composable
private fun DipView(p: ChipPinout) {
    val n = p.pins.size
    val half = n / 2
    val rowH = if (n > 28) 22.dp else 26.dp
    val fs = if (n > 28) 11.sp else 12.sp
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.Top) {
        // left labels, pins 1…n/2 top to bottom
        Column(Modifier.weight(1f).padding(top = 14.dp)) {
            for (i in 0 until half) Box(Modifier.height(rowH).fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                Text(p.pins[i], color = pinColor(p, i), fontFamily = Mono, fontSize = fs, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.End)
            }
        }
        Column(Modifier.padding(top = 14.dp)) { for (i in 0 until half) PinStub(rowH) }
        // body
        Box(Modifier.width(76.dp).height(rowH * half + 28.dp).background(C.raised, RoundedCornerShape(6.dp)).border(1.5.dp, C.line, RoundedCornerShape(6.dp))) {
            Box(Modifier.align(Alignment.TopCenter).offset(y = (-9).dp).size(18.dp).background(C.ground, CircleShape).border(1.5.dp, C.line, CircleShape))
            Box(Modifier.align(Alignment.TopCenter).offset(y = (-9).dp).size(width = 22.dp, height = 9.dp).background(C.ground))
            Column(Modifier.padding(top = 14.dp).fillMaxWidth()) {
                for (r in 0 until half) Row(Modifier.height(rowH).fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("${r + 1}", fontFamily = Mono, fontSize = 10.sp, color = C.text3, modifier = Modifier.weight(1f))
                    Text("${n - r}", fontFamily = Mono, fontSize = 10.sp, color = C.text3, textAlign = TextAlign.End, modifier = Modifier.weight(1f))
                }
            }
        }
        Column(Modifier.padding(top = 14.dp)) { for (i in 0 until half) PinStub(rowH) }
        // right labels, pins n…n/2+1 top to bottom
        Column(Modifier.weight(1f).padding(top = 14.dp)) {
            for (r in 0 until half) {
                val i = n - 1 - r
                Box(Modifier.height(rowH).fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
                    Text(p.pins[i], color = pinColor(p, i), fontFamily = Mono, fontSize = fs, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun PinStub(h: androidx.compose.ui.unit.Dp) {
    Box(Modifier.height(h).width(12.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 12.dp, height = 8.dp).background(Color(0xFF6F6A63), RoundedCornerShape(1.dp)))
    }
}

/** PLCC32 seen from above: a sketch of the body with pin numbers, and the pin list beside it. */
@Composable
private fun PlccView(p: ChipPinout) {
    val top = listOf(4, 3, 2, 1, 32, 31, 30)
    val bottom = listOf(14, 15, 16, 17, 18, 19, 20)
    val left = (5..13).toList()
    val right = (21..29).reversed().toList()
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Row { for (k in top) PlccNum(k, highlight = k == 1) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column { for (k in left) PlccNum(k) }
            Box(Modifier.size(width = 7 * 30.dp, height = 9 * 22.dp).background(C.raised, RoundedCornerShape(4.dp)).border(1.5.dp, C.line, RoundedCornerShape(4.dp)), contentAlignment = Alignment.Center) {
                Text("PLCC32\ntop view", fontFamily = Sans, fontSize = 12.sp, color = C.text3, textAlign = TextAlign.Center)
            }
            Column { for (k in right) PlccNum(k) }
        }
        Row { for (k in bottom) PlccNum(k) }
    }
    Spacer(Modifier.height(4.dp))
    // pin list, two columns
    Row(Modifier.fillMaxWidth()) {
        for (col in 0 until 2) Column(Modifier.weight(1f)) {
            for (i in col * 16 until col * 16 + 16) Row {
                Text("%2d ".format(i + 1), fontFamily = Mono, fontSize = 12.sp, color = C.text3)
                Text(p.pins[i], fontFamily = Mono, fontSize = 12.sp, color = pinColor(p, i))
            }
        }
    }
}

@Composable
private fun PlccNum(k: Int, highlight: Boolean = false) {
    Box(Modifier.size(width = 30.dp, height = 22.dp), contentAlignment = Alignment.Center) {
        Text("$k", fontFamily = Mono, fontSize = 11.sp, color = if (highlight) C.amber else C.text2, fontWeight = if (highlight) FontWeight.SemiBold else FontWeight.Normal)
    }
}

@Composable
private fun Legend(p: ChipPinout) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
        LegendDot(PinRed, "supply")
        LegendDot(PinBlue, "ground")
        if (p.roles.isNotEmpty()) {
            LegendDot(PinGreen, "output")
            LegendDot(C.amber, "clock")
        } else {
            LegendDot(C.amber, "VPP")
        }
    }
}

@Composable
private fun LegendDot(c: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(c, CircleShape))
        Text(" $label", fontFamily = Sans, fontSize = 12.sp, color = C.text2)
    }
}
