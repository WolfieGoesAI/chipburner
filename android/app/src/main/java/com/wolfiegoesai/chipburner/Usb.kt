package com.wolfiegoesai.chipburner

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import androidx.core.content.ContextCompat

/** Finds the programmer on the USB-OTG port, asks for permission and keeps the connection open. */
class UsbProgrammer(private val context: Context, private val onChange: () -> Unit) {
    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val action = context.packageName + ".USB_PERMISSION"

    var device: UsbDevice? = null
        private set
    private var connection: UsbDeviceConnection? = null

    /** The open connection's file descriptor, or null when no programmer is usable. */
    val fd: Int? get() = connection?.fileDescriptor?.takeIf { it >= 0 }

    val status: Status
        get() = when {
            device == null -> Status.NONE
            connection == null && !manager.hasPermission(device) -> Status.NO_PERMISSION
            connection == null -> Status.NOT_OPEN
            else -> Status.READY
        }

    enum class Status { NONE, NO_PERMISSION, NOT_OPEN, READY }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.action) {
                action, UsbManager.ACTION_USB_DEVICE_ATTACHED -> refresh()
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    close(); device = null; refresh()
                }
            }
        }
    }

    fun start() {
        val filter = IntentFilter().apply {
            addAction(action)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        refresh()
    }

    fun stop() {
        runCatching { context.unregisterReceiver(receiver) }
        close()
    }

    /** Looks for a programmer, and opens it when permission is already granted. */
    fun refresh() {
        val found = manager.deviceList.values.firstOrNull { isProgrammer(it) }
        if (found?.deviceName != device?.deviceName) close()
        device = found
        if (found != null && connection == null && manager.hasPermission(found)) {
            connection = manager.openDevice(found)
        }
        onChange()
    }

    fun requestPermission() {
        val d = device ?: return
        val intent = Intent(action).setPackage(context.packageName)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        manager.requestPermission(d, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    fun close() {
        runCatching { connection?.close() }
        connection = null
    }

    companion object {
        val ids = setOf(0x04D8 to 0xE11C, 0xA466 to 0x0A53)
        fun isProgrammer(d: UsbDevice) = (d.vendorId to d.productId) in ids
    }
}
