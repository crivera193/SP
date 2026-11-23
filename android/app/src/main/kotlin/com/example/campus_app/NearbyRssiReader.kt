package com.example.campus_app

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Reads RSSI on a Nearby BLE connection accepted by Android's GATT server. */
@SuppressLint("MissingPermission")
internal class NearbyRssiReader(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val clients = mutableMapOf<String, Client>()

    fun read(peerAddress: String?, result: MethodChannel.Result) {
        val address = peerAddress?.uppercase(Locale.ROOT)
        if (address == null || !BluetoothAdapter.checkBluetoothAddress(address)) {
            result.success(null)
            return
        }
        val device = try {
            clients[address]?.device
                ?: manager?.getConnectedDevices(BluetoothProfile.GATT_SERVER)
                    ?.firstOrNull { it.address.equals(address, ignoreCase = true) }
                ?: manager?.adapter?.getRemoteDevice(address)
        } catch (_: SecurityException) {
            null
        }
        if (device == null) {
            remove(address)
            result.success(null)
            return
        }

        val client = clients.getOrPut(device.address) { Client(device) }
        client.read(result)
    }

    fun close(peerAddress: String?) {
        if (peerAddress == null) clients.keys.toList().forEach(::remove)
        else remove(peerAddress.uppercase(Locale.ROOT))
    }

    private fun remove(address: String) {
        clients.remove(address)?.close()
    }

    private inner class Client(val device: BluetoothDevice) : BluetoothGattCallback() {
        private var gatt: BluetoothGatt? = null
        private var connected = false
        private var pending: MethodChannel.Result? = null
        private val timeout = Runnable { remove(device.address) }

        fun read(result: MethodChannel.Result) {
            if (pending != null) {
                result.success(null)
                return
            }
            pending = result
            handler.postDelayed(timeout, 2_000)
            try {
                if (gatt == null) {
                    // Attach a client to the existing link. Nearby still owns its server.
                    Log.d("SPNearbyRssi", "Attaching RSSI reader to an accepted Nearby connection")
                    gatt = device.connectGatt(context, false, this, BluetoothDevice.TRANSPORT_LE)
                    if (gatt == null) remove(device.address)
                } else if (connected) {
                    requestRssi()
                }
            } catch (_: SecurityException) {
                remove(device.address)
            }
        }

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                if (gatt !== this.gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    connected = true
                    requestRssi()
                } else {
                    Log.d("SPNearbyRssi", "RSSI reader disconnected with GATT status $status")
                    remove(device.address)
                }
            }
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            handler.post {
                if (gatt !== this.gatt) return@post
                complete(if (status == BluetoothGatt.GATT_SUCCESS) rssi else null)
            }
        }

        private fun requestRssi() {
            try {
                if (pending != null && gatt?.readRemoteRssi() != true) complete(null)
            } catch (_: SecurityException) {
                remove(device.address)
            }
        }

        fun close() {
            val client = gatt
            gatt = null
            try {
                client?.close()
            } catch (_: SecurityException) {
                // The user may revoke Bluetooth access while Nearby is running.
            }
            complete(null)
        }

        private fun complete(rssi: Int?) {
            handler.removeCallbacks(timeout)
            val result = pending
            pending = null
            result?.success(rssi)
        }
    }
}
