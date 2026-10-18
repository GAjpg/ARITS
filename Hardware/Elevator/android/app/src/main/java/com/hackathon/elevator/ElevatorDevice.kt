package com.hackathon.elevator

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic

/** 一台 ESP32 节点的连接状态机。 */
enum class NodeState { SCANNED, CONNECTING, DISCOVERING, READY, FAILED }

/**
 * 一台电梯节点（一块 ESP32）在 App 侧的全部状态。
 *
 * RSSI 处理照抄 dsh 的思路：先取中位数去毛刺，再做指数平滑。
 * 原始 RSSI 抖动极大（同一点位能差 15dBm），直接用会在两层之间乱跳。
 */
class ElevatorDevice(val address: String) {

    var name: String? = null
    /** 解析出来的楼层名，例如 "1F"。null 表示还没解析到。 */
    var floor: String? = null

    // ---------------- 信号强度 ----------------
    var rawRssi: Int = -127
        private set
    var filteredRssi: Double = -127.0
        private set
    var lastSeenMs: Long = 0L
        private set
    var seenCount: Int = 0
        private set

    private val rssiWindow = ArrayDeque<Int>()

    // ---------------- GATT ----------------
    var gatt: BluetoothGatt? = null
    var chrCmd: BluetoothGattCharacteristic? = null
    var chrStatus: BluetoothGattCharacteristic? = null
    var state: NodeState = NodeState.SCANNED

    /** 每台节点一条串行写队列（GATT 同一时刻只允许一个未完成操作）。 */
    val writeQueue = ArrayDeque<ByteArray>()
    var writeInFlight = false
    var writeDeadlineMs = 0L

    var reconnectAttempts: Int = 0
    var nextRetryMs: Long = 0L

    // ---------------- 从 STATUS 解析 ----------------
    var busyUp: Boolean = false
    var busyDown: Boolean = false
    var lastResult: String? = null
    var lastError: String? = null

    val isReady: Boolean get() = state == NodeState.READY

    val displayName: String
        get() = name ?: floor?.let { "ELEV-$it" } ?: address

    fun pushRssi(value: Int, now: Long) {
        rawRssi = value
        lastSeenMs = now
        seenCount++
        rssiWindow.addLast(value)
        while (rssiWindow.size > RSSI_WINDOW) rssiWindow.removeFirst()
        val median = medianOf()
        filteredRssi = if (filteredRssi < -126.0) median.toDouble()
        else filteredRssi + EMA_ALPHA * (median - filteredRssi)
    }

    /** 太长时间没被扫到（掉电/走远）→ 认为不在附近，退出判层。 */
    fun markLost() {
        rawRssi = -127
        filteredRssi = -127.0
        busyUp = false
        busyDown = false
    }

    private fun medianOf(): Int {
        if (rssiWindow.isEmpty()) return -127
        val s = rssiWindow.sorted()
        val m = s.size / 2
        return if (s.size % 2 == 1) s[m] else (s[m - 1] + s[m]) / 2
    }

    companion object {
        /** 中位数窗口长度：太大迟滞，太小压不住毛刺。窗口 3 ≈ 0.15~0.25s 就填满。 */
        const val RSSI_WINDOW = 3

        /** 指数平滑系数：越大越跟手，越小越平滑。0.62 ≈ 1~2 个采样就跟上。 */
        const val EMA_ALPHA = 0.62
    }
}
