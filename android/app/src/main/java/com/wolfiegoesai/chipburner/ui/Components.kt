package com.wolfiegoesai.chipburner.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun Card(modifier: Modifier = Modifier, padding: PaddingValues = PaddingValues(18.dp), content: @Composable ColumnScope.() -> Unit) {
    Surface(color = C.card, shape = RoundedCornerShape(20.dp), modifier = modifier.fillMaxWidth()) {
        Column(Modifier.padding(padding), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
    }
}

@Composable
fun Eyebrow(text: String) {
    Text(text.uppercase(), fontSize = 12.sp, color = C.text2, letterSpacing = 0.8.sp, fontFamily = Sans)
}

@Composable
fun PrimaryButton(text: String, icon: Int? = null, enabled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(
        onClick = onClick, enabled = enabled, shape = RoundedCornerShape(18.dp),
        colors = ButtonDefaults.buttonColors(containerColor = C.amber, contentColor = C.onAmber, disabledContainerColor = C.amberDim, disabledContentColor = Color(0xFFA38A63)),
        modifier = modifier.fillMaxWidth().height(64.dp),
    ) {
        if (icon != null) {
            Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(10.dp))
        }
        Text(text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, fontFamily = Sans)
    }
}

@Composable
fun TileButton(text: String, enabled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(
        onClick = onClick, enabled = enabled, shape = RoundedCornerShape(16.dp),
        colors = ButtonDefaults.buttonColors(containerColor = C.raised, contentColor = C.text, disabledContainerColor = C.card, disabledContentColor = C.text3),
        modifier = modifier.height(56.dp),
    ) { Text(text, fontSize = 15.sp, fontWeight = FontWeight.Medium, fontFamily = Sans) }
}

@Composable
fun OutlineButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick, enabled = enabled, shape = RoundedCornerShape(12.dp), border = BorderStroke(1.dp, C.line),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = C.text),
        modifier = modifier.heightIn(min = 44.dp),
        contentPadding = PaddingValues(horizontal = 14.dp),
    ) { Text(text, fontSize = 14.sp, fontFamily = Sans) }
}

@Composable
fun FilterChipButton(text: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(10.dp),
        color = if (selected) C.amberDim else Color.Transparent,
        border = if (selected) null else BorderStroke(1.dp, C.line),
        modifier = Modifier.heightIn(min = 36.dp),
    ) {
        Box(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
            Text(text, fontSize = 14.sp, color = if (selected) C.amberLight else Color(0xFFCFCAC2), fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal, fontFamily = Sans)
        }
    }
}

@Composable
fun StatusPill(text: String, good: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(16.dp), color = if (good) C.greenBg else C.raised) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(8.dp).background(if (good) C.greenDot else C.text3, CircleShape))
            Text(text, fontSize = 13.sp, color = if (good) C.green else Color(0xFFCFCAC2), fontWeight = FontWeight.Medium, fontFamily = Sans)
        }
    }
}

@Composable
fun Tag(text: String, onClick: (() -> Unit)? = null) {
    val shape = RoundedCornerShape(10.dp)
    if (onClick != null) {
        Surface(onClick = onClick, shape = shape, color = C.card) {
            Text(text, Modifier.padding(horizontal = 12.dp, vertical = 10.dp), fontSize = 13.sp, color = Color(0xFFCFCAC2), fontFamily = Sans)
        }
    } else {
        Surface(shape = shape, color = C.card) {
            Text(text, Modifier.padding(horizontal = 12.dp, vertical = 10.dp), fontSize = 13.sp, color = Color(0xFFCFCAC2), fontFamily = Sans)
        }
    }
}
