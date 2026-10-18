package com.hackathon.elevator

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.UUID

/**
 * BLE 总控：扫描所有节点 + 维持长连接 + 订阅状态回执 + 判定楼层。
 *
 * 相比上一版的关键改动（都是同行评审点出来的真问题）：
 *  1. **保持连接**，不再“连上→写一条→断开”。写队列 + 订阅 STATUS 才能拿到真回执。
 *  2. **写队列**：GATT 同一时刻只允许一个未完成操作；`writeCharacteristic` 返回 false
 *     必须退回队列重试，否则命令会静默消失、连接也会泄漏。
 *  3. **检查 status**：连接/服务发现失败（如 133）有明确日志与退避重连，不再闷头失败。
 *  4. **扫描回调不做 name 假设**：读 `scanRecord.deviceName`，并用 `device.name` 兜底。
 *  5. 所有状态变更统一 post 回主线程，避免 binder 线程与主线程的数据竞争。
 */
class BleManager(
    private val context: Context,
    private val listener: Listener
) {

    interface Listener {
        /** 节点列表或它们的信号/状态有变化。 */
        fun onNodesChanged(nodes: List<ElevatorDevice>)

        /** 节点回执：floor 例如 "1F"，result 例如 "OK:UP"。 */
        fun onAck(floor: String, result: String)

        /** 日志（连接失败、扫描失败等）。 */
        fun onLog(msg: String)
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("0000ffe0-0000-1000-8000-00805f9b34fb")
        val CMD_CHAR_UUID: UUID = UUID.fromString("0000ffe1-0000-1000-8000-00805f9b34fb")
        val STATUS_CHAR_UUID: UUID = UUID.fromString("0000ffe2-0000-1000-8000-00805f9b34fb")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** 设备名前缀（固件广播名 ELEV-1F / ELEV-2F）。 */
        const val NAME_PREFIX = "ELEV-"

        const val CMD_UP = "UP"
        const val CMD_DOWN = "DOWN"

        private const val TICK_MS = 200L
        private const val WRITE_TIMEOUT_MS = 3000L
        private const val RSSI_POLL_MS = 1000L

        /** 扫到新 RSSI 后最多这么频繁地重判一次（40ms < 人眼“瞬时”阈值）。 */
        private const val EVAL_THROTTLE_MS = 40L

        /** 超过这么久没被扫到 / 没刷新到 RSSI，就认为不在附近。 */
        const val STALE_MS = 2500L
    }

    private val handler = Handler(Looper.getMainLooper())
    private val nodes = LinkedHashMap<String, ElevatorDevice>()

    val floorJudge = FloorJudge()

    @Volatile
    private var scanning = false

    private var lastRssiPollMs = 0L
    private var lastEvalMs = 0L

    private val adapter: BluetoothAdapter?
        get() = runCatching {
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        }.getOrNull()

    fun isScanning(): Boolean = scanning

    /** 给界面用的节点快照（按楼层、再按信号强弱排序）。 */
    fun nodesSnapshot(): List<ElevatorDevice> =
        nodes.values.sortedWith(
            compareBy({ it.floor ?: "zz" }, { -it.filteredRssi })
        )

    // ------------------------------------------------------------------
    // 扫描
    // ------------------------------------------------------------------

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = handleScan(result)
        override fun onBatchScanResults(results: MutableList<ScanResult>) =
            results.forEach { handleScan(it) }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            listener.onLog("扫描启动失败，错误码 $errorCode")
        }
    }

    private fun handleScan(result: ScanResult) {
        val rec = result.scanRecord
        val name = rec?.deviceName ?: runCatching { result.device.name }.getOrNull() ?: return
        if (!name.startsWith(NAME_PREFIX)) return

        val now = System.currentTimeMillis()
        val isNew = !nodes.containsKey(result.device.address)
        val dev = nodes.getOrPut(result.device.address) { ElevatorDevice(result.device.address) }

        dev.name = name
        val fl = name.removePrefix(NAME_PREFIX).trim()
        if (fl.isNotEmpty()) dev.floor = fl
        dev.pushRssi(result.rssi, now)

        if (isNew) {
            listener.onLog("发现节点 $name (${result.device.address})")
            connect(dev)
        }

        // 每扫到一次就尽快重判一次（节流），不必等 250ms tick
        requestEval(now)
    }

    /** 节流地把“重判楼层 + 通知 UI”排到主线程。 */
    private fun requestEval(now: Long) {
        if (now - lastEvalMs < EVAL_THROTTLE_MS) return
        lastEvalMs = now
        handler.post {
            floorJudge.update(nodesSnapshot())
            listener.onNodesChanged(nodesSnapshot())
        }
    }

    @SuppressLint("MissingPermission")
    fun startScan() {
        if (scanning) return
        val a = adapter ?: run { listener.onLog("此设备没有蓝牙"); return }
        val enabled = runCatching { a.isEnabled }.getOrDefault(false)
        if (!enabled) { listener.onLog("请先打开手机蓝牙"); return }
        val scanner = runCatching { a.bluetoothLeScanner }.getOrNull()
        if (scanner == null) { listener.onLog("拿不到 BLE 扫描器（权限没给？）"); return }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            // 不设过滤器：不同 ROM 对 ServiceUUID 过滤实现差异较大，容易漏报。设备就几台，自己过滤最稳。
            scanner.startScan(null, settings, scanCallback)
            scanning = true                       // 只有真正启动了才置位（修上一版“置位后提前 return”的死锁）
            startTick()
            listener.onLog("开始扫描电梯节点…")
        } catch (t: Throwable) {
            scanning = false
            listener.onLog("无法开始扫描：${t.message}")
        }
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        scanning = false
        handler.removeCallbacks(tick)
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
    }

    // ------------------------------------------------------------------
    // 连接
    // ------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun connect(dev: ElevatorDevice) {
        val a = adapter ?: return
        if (dev.state == NodeState.CONNECTING || dev.state == NodeState.DISCOVERING ||
            dev.state == NodeState.READY
        ) return

        val device = runCatching { a.getRemoteDevice(dev.address) }.getOrNull()
        if (device == null) { listener.onLog("设备地址无效"); return }

        closeGatt(dev)
        dev.state = NodeState.CONNECTING
        try {
            dev.gatt = device.connectGatt(
                context, false, NodeGattCallback(dev.address), BluetoothDevice.TRANSPORT_LE
            )
        } catch (t: Throwable) {
            dev.state = NodeState.FAILED
            listener.onLog("connectGatt 异常：${t.message}")
            scheduleRetry(dev)
        }
    }

    private fun closeGatt(dev: ElevatorDevice) {
        val g = dev.gatt ?: return
        dev.gatt = null
        runCatching { g.disconnect() }
        runCatching { g.close() }
        dev.chrCmd = null
        dev.chrStatus = null
        dev.writeQueue.clear()
        dev.writeInFlight = false
    }

    private fun scheduleRetry(dev: ElevatorDevice) {
        dev.reconnectAttempts++
        val backoff = (2000L shl (dev.reconnectAttempts - 1).coerceIn(0, 4)).coerceAtMost(30_000L)
        dev.nextRetryMs = System.currentTimeMillis() + backoff
    }

    private inner class NodeGattCallback(private val address: String) : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                val dev = nodes[address] ?: return@post
                when {
                    newState == BluetoothProfile.STATE_CONNECTED &&
                        status == BluetoothGatt.GATT_SUCCESS -> {
                        dev.reconnectAttempts = 0
                        dev.state = NodeState.DISCOVERING
                        listener.onLog("${dev.displayName} 已连接，发现服务…")
                        runCatching { gatt.discoverServices() }
                            .onFailure { listener.onLog("discoverServices 失败：${it.message}") }
                    }

                    newState == BluetoothProfile.STATE_DISCONNECTED -> {
                        dev.state = NodeState.FAILED
                        dev.busyUp = false
                        dev.busyDown = false
                        dev.writeInFlight = false
                        dev.writeQueue.clear()
                        if (status != BluetoothGatt.GATT_SUCCESS)
                            listener.onLog("${dev.displayName} 连接失败 status=$status")
                        else
                            listener.onLog("${dev.displayName} 断开")
                        runCatching { gatt.close() }
                        if (dev.gatt === gatt) dev.gatt = null
                        scheduleRetry(dev)
                    }
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            handler.post {
                val dev = nodes[address] ?: return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    dev.state = NodeState.FAILED
                    listener.onLog("${dev.displayName} 服务发现失败 status=$status")
                    return@post
                }
                val svc = gatt.getService(SERVICE_UUID)
                val cmd = svc?.getCharacteristic(CMD_CHAR_UUID)
                if (cmd == null) {
                    dev.state = NodeState.FAILED
                    listener.onLog("${dev.displayName} 缺少控制通道（固件对不上？）")
                    return@post
                }
                dev.chrCmd = cmd
                val st = svc.getCharacteristic(STATUS_CHAR_UUID)
                dev.chrStatus = st

                // 订阅状态通知 → 真正能收到“舵机按完了”的回执
                if (st != null) {
                    runCatching {
                        gatt.setCharacteristicNotification(st, true)
                        st.getDescriptor(CCCD)?.let { cccd ->
                            @Suppress("DEPRECATION")
                            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                            @Suppress("DEPRECATION")
                            gatt.writeDescriptor(cccd)
                        }
                    }.onFailure { listener.onLog("订阅通知失败：${it.message}") }
                }

                dev.state = NodeState.READY
                dev.lastError = null
                listener.onLog("${dev.displayName} 就绪")
                pumpQueue(dev)
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            handler.post { nodes[address]?.let { pumpQueue(it) } }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            handler.post {
                val dev = nodes[address] ?: return@post
                dev.writeInFlight = false
                if (status != BluetoothGatt.GATT_SUCCESS) listener.onLog("${dev.displayName} 写入失败 status=$status")
                pumpQueue(dev)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid == STATUS_CHAR_UUID) handleStatus(address, value)
        }

        @Deprecated("兼容 API 33 以下的 2 参数版本")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            @Suppress("DEPRECATION")
            val value = characteristic.value
            if (characteristic.uuid == STATUS_CHAR_UUID) handleStatus(address, value)
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val now = System.currentTimeMillis()
                handler.post { nodes[address]?.pushRssi(rssi, now) }
            }
        }
    }

    private fun handleStatus(address: String, value: ByteArray?) {
        if (value == null) return
        val text = String(value, Charsets.UTF_8).trim()
        if (text.isEmpty()) return
        handler.post {
            val dev = nodes[address] ?: return@post
            val parts = text.split("|", limit = 2)
            val result = parts.getOrNull(1) ?: text
            dev.lastResult = result
            dev.busyUp = false
            dev.busyDown = false
            listener.onAck(dev.floor ?: parts.getOrNull(0) ?: "", result)
        }
    }

    // ------------------------------------------------------------------
    // 下发命令（串行队列）
    // ------------------------------------------------------------------

    fun sendCommand(address: String, cmd: String) {
        val dev = nodes[address] ?: run { listener.onLog("设备不存在"); return }
        if (dev.writeQueue.size > 24) { listener.onLog("${dev.displayName} 队列积压，丢弃一笔"); return }
        dev.writeQueue.addLast(cmd.toByteArray(Charsets.UTF_8))
        pumpQueue(dev)
    }

    private fun pumpQueue(dev: ElevatorDevice) {
        if (dev.writeInFlight) return
        val gatt = dev.gatt ?: return
        if (dev.state != NodeState.READY) return

        val item = dev.writeQueue.removeFirstOrNull() ?: return
        val chr = dev.chrCmd
        if (chr == null) { listener.onLog("${dev.displayName} 控制通道缺失"); pumpQueue(dev); return }

        dev.writeInFlight = true
        dev.writeDeadlineMs = System.currentTimeMillis() + WRITE_TIMEOUT_MS
        try {
            @Suppress("DEPRECATION")
            chr.value = item
            @Suppress("DEPRECATION")
            val ok = gatt.writeCharacteristic(chr)
            if (!ok) {
                // 请求没被接受 → 回调不会来。必须退回队首，否则命令消失 + 连接泄漏。
                dev.writeInFlight = false
                dev.writeQueue.addFirst(item)
                listener.onLog("${dev.displayName} 写入被拒（GATT 忙），稍后重试")
            } else {
                listener.onLog("→ ${dev.displayName}  ${String(item)}")
            }
        } catch (t: Throwable) {
            dev.writeInFlight = false
            dev.writeQueue.addFirst(item)
            listener.onLog("${dev.displayName} 写入异常：${t.message}")
        }
    }

    // ------------------------------------------------------------------
    // 周期任务
    // ------------------------------------------------------------------

    private val tick = object : Runnable {
        @SuppressLint("MissingPermission")
        override fun run() {
            val now = System.currentTimeMillis()

            for (dev in nodes.values) {
                // 1) 写看门狗：有的 ROM 会吞掉 onCharacteristicWrite 回调
                if (dev.writeInFlight && now > dev.writeDeadlineMs) {
                    dev.writeInFlight = false
                    listener.onLog("${dev.displayName} 写入超时，继续下一笔")
                    pumpQueue(dev)
                }
                // 2) 失败自动重连（退避）
                if (dev.state == NodeState.FAILED && now >= dev.nextRetryMs &&
                    now - dev.lastSeenMs < STALE_MS * 3
                ) {
                    connect(dev)
                }
            }

            // 3) 已连接节点定期读一次 RSSI（扫描之外再补一路）
            if (now - lastRssiPollMs > RSSI_POLL_MS) {
                lastRssiPollMs = now
                for (dev in nodes.values) {
                    if (dev.state == NodeState.READY) runCatching { dev.gatt?.readRemoteRssi() }
                }
            }

            // 4) 过期设备：掉电/走远的不再参与判层
            for (dev in nodes.values) {
                if (now - dev.lastSeenMs > STALE_MS) dev.markLost()
            }

            // 5) 判层
            floorJudge.update(nodesSnapshot())
            listener.onNodesChanged(nodesSnapshot())

            handler.postDelayed(this, TICK_MS)
        }
    }

    private fun startTick() {
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    // ------------------------------------------------------------------

    fun close() {
        stopScan()
        for (dev in nodes.values) closeGatt(dev)
        nodes.clear()
        floorJudge.reset()
    }
}
