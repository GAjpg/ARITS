package com.hackathon.elevator

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.hackathon.elevator.databinding.ActivityMainBinding
import kotlin.random.Random

/**
 * 打开即自动扫描、自动识别所在楼层、自动连上目标楼层装置。
 *
 * 这里把两件事**彻底分开**：
 *   · **3D 井道里的轿厢 / 层显上那个大数字** = **轿厢现在在哪层**，来路按优先级：
 *     ① **真读数**——摄像头读电梯厅那块屏（进「摄像头读楼层」页，方案 D），
 *        或现场手动指定；② 没有真读数时用**蓝牙判层**：**手机靠近哪一层**的
 *        ESP32，轿厢就画在那一层（用户坐在轿厢里时，这就是轿厢所在层；只判得出来
 *        装了装置的 1F / 2F）；没靠近时停着不动。
 *   · **呼叫目标** = 下方楼层按钮手动选择（不点则默认跟随你靠近的楼层）；
 *     呼叫永远是手动的：点 ▲/▼，或在队友的导航 App 里按一下悬浮钮（同一个 BLE 接口）。
 *
 * 页面上有**两台电梯**（甲梯 / 乙梯 并排，层显一样大，框里只有一个大数字）：
 *   · **甲梯** = 上面说的那台，会跟着你走、也是唯一真能呼的那台；
 *   · **乙梯** = **另一台电梯的装饰**：B~3F 随机慢慢跑，纯画面，不代表任何真实读数。
 *
 * 本演示：**井道 B~3F**，但只有 **1F / 2F** 装了 ESP32 呼梯装置。
 * 所以只有 1F / 2F 能呼叫，B / 3F 的按钮是灰的。
 *
 * 你一旦手选了目标，只有**当你走到的楼层发生变化**时才会重新跟随靠近楼层。
 */
class MainActivity : AppCompatActivity(), BleManager.Listener {

    private lateinit var b: ActivityMainBinding
    private lateinit var ble: BleManager
    private var api: LocalApiServer? = null

    /** 给队友 App 用的接口地址，例如 http://192.168.1.23:8899 。 */
    private var apiUrl: String? = null

    /** 井道楼层（只用于 3D 展示）：B~3F */
    private val shaftFloors = listOf("B", "1F", "2F", "3F")

    /** 装了 ESP32 呼梯装置的楼层：**只有这些层能呼叫**（1F/2F 都有上行+下行） */
    private val deviceFloors = listOf("1F", "2F")

    /** 呼叫目标（下方楼层按钮里高亮的那层）= manualTarget ?: nearFloor。 */
    private var selectedFloor: String? = null

    /** 手机靠近的楼层（判层结果）——没有真实读数时，用它驱动 3D 轿厢。 */
    private var nearFloor: String? = null

    /** 3D 轿厢当前停在哪层（用来判断"要不要动"）。 */
    private var carShown: String? = null

    /**
     * **乙梯**（另一台电梯）的轿厢在哪层 —— **纯画面装饰**：
     * B~3F 随机慢慢跑（一次跳 1~2 层，每 3 秒多换一次）。
     * 它**永远不写进 [CarFloorSource]**，所以 /api/status 里的 car2 还是 null
     * —— 不拿编出来的数当真数据（和「队友 App 效果」页里的乙梯一模一样）。
     */
    private var carB = "3F"

    /** 乙梯自动乱跑的定时器（甲梯不在这里动：它只跟着你靠近的楼层走）。 */
    private val carBRunnable = object : Runnable {
        override fun run() {
            carB = randomNextFloor(carB)
            b.floorDisplayB.text = carB
            b.elevatorViewB.moveCarTo(shaftFloors.indexOf(carB).coerceAtLeast(0))
            b.root.postDelayed(this, 3000L + Random.nextLong(1600L))
        }
    }

    /**
     * 定时把界面刷新一遍（5 秒一次）。
     * 主要是为了**真读数超过 3 分钟后能自动退回「蓝牙判层」**（不然只有蓝牙有
     * 事件时才刷新），以及每次回到主界面时甲梯的数字是最新的。
     */
    private val ageTick = object : Runnable {
        override fun run() {
            refreshUi()
            b.root.postDelayed(this, 5000L)
        }
    }

    /** 手动选楼层按钮定的呼叫目标；**所靠近楼层一变即清空**，重新跟随。 */
    private var manualTarget: String? = null

    private var lastNodes: List<ElevatorDevice> = emptyList()

    private val floorViews = LinkedHashMap<String, TextView>()
    private var hintRunnable: Runnable? = null

    // ---------- 权限回调 ----------

    private val btPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            if (hasBluetoothPermission()) startScan() else toast("需要蓝牙权限才能连接电梯装置")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityMainBinding.inflate(layoutInflater)
        setContentView(b.root)

        // 只有 1F / 2F 装了指呼装置：这两层做全，B / 3F 只露半截（暗影）
        val focus = deviceFloors.mapNotNull { f -> shaftFloors.indexOf(f).takeIf { it >= 0 } }
        for (v in listOf(b.elevatorView, b.elevatorViewB)) {
            v.floors = shaftFloors
            v.focusIndices = focus
        }
        // 乙梯（另一台电梯）从 3F 开始，纯装饰
        b.elevatorViewB.moveCarTo(shaftFloors.indexOf(carB).coerceAtLeast(0))
        b.floorDisplayB.text = carB
        buildFloorButtons()

        ble = BleManager(this, this)

        b.btnUp.setOnClickListener { sendCommand(BleManager.CMD_UP, null) }
        b.btnDown.setOnClickListener { sendCommand(BleManager.CMD_DOWN, null) }

        // 只是给我们自己人看效果：进「队友导航 App 最终页面」模拟页
        b.btnMock.setOnClickListener {
            startActivity(Intent(this, NavMockActivity::class.java))
        }

        // 摄像头读电梯楼层（方案 D：读电梯厅那块屏上的数字）
        b.btnCamera.setOnClickListener {
            startActivity(Intent(this, CameraFloorActivity::class.java))
        }

        startApiServer()

        // 打开即开始，无需点任何按钮
        if (hasBluetoothPermission()) {
            startScan()
        } else {
            btPermissionLauncher.launch(requiredBluetoothPermissions())
        }
    }

    // ---------- 给别的 App 用的 HTTP 接口 ----------

    private fun startApiServer() {
        if (api != null) return
        api = LocalApiServer(
            port = API_PORT,
            statusJson = ::apiStatusJson,
            floors = { deviceFloors },
            call = { floor, dir -> tryCall(dir, floor) },
            setTarget = { f -> pickTarget(f) },
            log = { Log.d(TAG, it) }
        ).also {
            it.start()
            apiUrl = "http://${LocalApiServer.localIpAddress()}:$API_PORT"
        }
    }

    // ---------- 权限 ----------

    private fun requiredBluetoothPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasBluetoothPermission(): Boolean =
        requiredBluetoothPermissions().all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }

    // ---------- 楼层按钮 ----------

    private fun buildFloorButtons() {
        b.floorRow.removeAllViews()
        floorViews.clear()
        for (f in shaftFloors) {
            val hasDevice = deviceFloors.contains(f)
            val tv = TextView(this).apply {
                text = f
                gravity = Gravity.CENTER
                textSize = 16f
                setPadding(dp(18), dp(13), dp(18), dp(13))
                setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_primary))
                alpha = if (hasDevice) 1f else 0.35f
            }
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            lp.marginEnd = dp(10)
            tv.layoutParams = lp
            // 可点：手动选择“呼叫目标楼层”（只影响 ▲/▼ 发去哪层，不影响轿厢）
            tv.setOnClickListener { pickTarget(f) }
            b.floorRow.addView(tv)
            floorViews[f] = tv
        }
        updateFloorButtons()
    }

    private fun updateFloorButtons() {
        for (f in shaftFloors) {
            val tv = floorViews[f] ?: continue
            if (!deviceFloors.contains(f)) {          // B / 3F：没有装置，置灰
                tv.setBackgroundResource(R.drawable.bg_floor_normal)
                tv.setTextColor(ContextCompat.getColor(this, R.color.text_secondary))
                tv.alpha = 0.35f
                continue
            }
            tv.alpha = 1f
            val selected = f == selectedFloor
            tv.setBackgroundResource(
                if (selected) R.drawable.bg_floor_selected else R.drawable.bg_floor_normal
            )
            tv.setTextColor(
                ContextCompat.getColor(this, if (selected) R.color.accent else R.color.text_primary)
            )
        }
    }

    /**
     * 手动选“呼叫目标楼层”（不动 3D 轿厢）。
     * 返回是否选成功——只有装了装置的楼层（1F/2F）可选。
     */
    private fun pickTarget(floor: String): Boolean {
        if (!deviceFloors.contains(floor)) {
            showHint("$floor 没有呼梯装置（本演示只有 1F / 2F）")
            return false
        }
        manualTarget = floor
        applyTarget()
        return true
    }

    /** 把目标楼层同步到界面（高亮 + 底部状态条）。目标 = 手动选择 ?: 靠近楼层。 */
    private fun applyTarget() {
        val t = (manualTarget ?: nearFloor)?.takeIf { deviceFloors.contains(it) }
        selectedFloor = t
        updateFloorButtons()
        updateBottomBar()
    }

    // ---------- 发送命令 ----------

    private fun sendCommand(dir: String, floor: String?) {
        val (ok, msg) = tryCall(dir, floor)
        showHint(if (ok) "$msg，等待装置回执…" else msg)
    }

    /**
     * 真正下发一次呼叫；返回 (是否已下发, 说明)。
     * ▲/▼、HTTP 接口(队友 App) 都走这里，行为完全一致。
     */
    private fun tryCall(dir: String, floor: String?): Pair<Boolean, String> {
        val f = floor ?: selectedFloor ?: ble.floorJudge.currentFloor
            ?: return false to "正在检测楼层"
        if (!deviceFloors.contains(f)) return false to "$f 没有呼梯装置"
        val dev = lastNodes.firstOrNull { it.floor == f }
            ?: return false to "未发现 $f 装置，请靠近"
        if (!dev.isReady) return false to "$f 装置连接中，请稍候"
        ble.sendCommand(dev.address, dir)
        return true to "已下发 ${dirText(dir)} → $f"
    }

    /** 组装 /api/status 的 JSON。 */
    private fun apiStatusJson(): String {
        val nodesJson = lastNodes.joinToString(",") { n ->
            """{"floor":${LocalApiServer.jsonStr(n.floor)},""" +
                """"address":${LocalApiServer.jsonStr(n.address)},""" +
                """"name":${LocalApiServer.jsonStr(n.name)},""" +
                """"rssi":${n.rawRssi},"ready":${n.isReady}}"""
        }
        // car = 轿厢在哪层：优先"真实读数"（摄像头/手动指定），没有就用"靠近哪层"判出来的（蓝牙判层）。
        // carSource 说明这个数是怎么来的：camera / manual / near（near = 蓝牙判层，见 NAV_APP_UI_SPEC.md §10）。
        val carReal = CarFloorSource.current(0)
        val car = carReal ?: nearFloor
        val carSrc = if (carReal != null) CarFloorSource.sourceCode(0)
        else if (car != null) "near" else null
        val carB = CarFloorSource.current(1)
        return """{"ok":true,"api":1,"near":${LocalApiServer.jsonStr(nearFloor)},""" +
            """"target":${LocalApiServer.jsonStr(selectedFloor)},""" +
            """"car":${LocalApiServer.jsonStr(car)},""" +
            """"carSource":${LocalApiServer.jsonStr(carSrc)},""" +
            """"car2":${LocalApiServer.jsonStr(carB)},""" +
            """"floors":${LocalApiServer.jsonArray(deviceFloors)},""" +
            """"shaftFloors":${LocalApiServer.jsonArray(shaftFloors)},"nodes":[$nodesJson]}"""
    }

    private fun dirText(dir: String) = if (dir == BleManager.CMD_UP) "上行" else "下行"

    // ---------- 扫描与刷新 ----------

    private fun startScan() {
        ble.startScan()
    }

    /**
     * 刷新界面。
     *
     * **甲梯层显上那个大数字 = 轿厢现在在哪层**，它的来路按优先级取：
     *   ① **真实读数**（摄像头读到电梯屏 / 现场手动指定）—— 硬件上看不到轿厢，这是"真"的来源；
     *   ② 没有真读数时，用**蓝牙判层**："手机靠近哪层，轿厢就画在哪层"
     *      （用户坐在轿厢里时，这就是轿厢所在层；只判得出来装了装置的 1F/2F）。
     * 层显框里**只放那个大数字**（不写小字）；装置连没连上、找到了几台，看页面最下面那条。
     * 乙梯（另一台电梯）不在这里动，它由 [carBRunnable] 自己随机跑。
     */
    private fun refreshUi() {
        val judgeFloor = ble.floorJudge.currentFloor
        val near = judgeFloor != null && deviceFloors.contains(judgeFloor)

        // 靠近的楼层发生变化 → ① 手动选的目标作废、重新跟随 ②（没有真读数时）轿厢跟着挪
        if (near && judgeFloor != nearFloor) {
            nearFloor = judgeFloor
            manualTarget = null
            applyTarget()
        }

        val realCar = CarFloorSource.current()
        val car = realCar ?: nearFloor
        if (car != carShown) {
            carShown = car
            val i = car?.let { shaftFloors.indexOf(it) } ?: -1
            if (i >= 0) b.elevatorView.moveCarTo(i)
        }

        // 甲梯层显：大大的楼层数字（就是轿厢所在的楼层）；都没有就显示 --
        b.floorDisplay.text = car ?: getString(R.string.floor_none)
        b.floorDisplay.setTextColor(
            ContextCompat.getColor(this, if (car != null) R.color.display_digit else R.color.display_dim)
        )
        updateBottomBar()
    }

    /**
     * 底部那条状态：呼叫目标 + 装置连没连上。
     * 层显框里现在**不写小字**了，所以"找没找到装置"也在这儿说。
     */
    private fun updateBottomBar() {
        val f = selectedFloor
        if (f == null) {
            val api = apiUrl?.let { "外部接口 $it" }
            val state = if (lastNodes.isEmpty()) getString(R.string.detecting)
            else "找到 ${lastNodes.size} 台装置 · 等靠近 1F / 2F"
            b.bottomBar.text = listOfNotNull(api, state).joinToString(" · ")
            return
        }
        val dev = lastNodes.firstOrNull { it.floor == f }
        val nearTip = if (nearFloor != null && nearFloor != f) "（靠近 $nearFloor）" else ""
        b.bottomBar.text = when {
            dev == null -> "未发现 $f 装置 · 请靠近"
            dev.isReady -> "已就绪 · 呼叫目标 $f$nearTip"
            else -> "$f 装置连接中…"
        }
    }

    // ---------- BleManager.Listener ----------

    override fun onNodesChanged(nodes: List<ElevatorDevice>) {
        lastNodes = nodes
        refreshUi()
    }

    override fun onAck(floor: String, result: String) {
        val f = floor.ifBlank { selectedFloor ?: "?" }
        when {
            result.startsWith("OK") -> showHint("✓ $f 已按下（$result）")
            result.startsWith("ERR") -> showHint("⚠ $f 装置返回：$result")
            else -> showHint("$f 装置返回：$result")
        }
    }

    override fun onLog(msg: String) {
        // 诊断信息进 Logcat；只把“需要用户处理”的关键信息浮到界面，避免刷屏
        Log.d(TAG, msg)
        val important = listOf("请", "失败", "异常", "没有", "无法", "缺少", "被拒", "超时", "拿不到")
        if (important.any { msg.contains(it) }) showHint(msg)
    }

    // ---------- 工具 ----------

    private fun showHint(text: String) {
        hintRunnable?.let { b.root.removeCallbacks(it) }
        b.hintBar.text = text
        b.hintBar.visibility = View.VISIBLE
        b.hintBar.alpha = 0f
        b.hintBar.animate().alpha(1f).setDuration(150).start()

        val r = Runnable {
            b.hintBar.animate().alpha(0f).setDuration(300)
                .withEndAction { b.hintBar.visibility = View.INVISIBLE }
                .start()
        }
        hintRunnable = r
        b.root.postDelayed(r, 2800)
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    /** 随机换一层给自己看：一次跳 1~2 层（乙梯专用，纯装饰）。 */
    private fun randomNextFloor(cur: String): String {
        val i = shaftFloors.indexOf(cur).coerceAtLeast(0)
        val cand = listOf(i - 2, i - 1, i + 1, i + 2).filter { it in shaftFloors.indices }
        return shaftFloors[cand.random()]
    }

    override fun onResume() {
        super.onResume()
        // 从「摄像头读楼层」页回来时，把新读到的轿厢楼层立刻反映到主界面
        refreshUi()
        b.root.removeCallbacks(ageTick)
        b.root.postDelayed(ageTick, 5000L)
        // 乙梯（另一台电梯）：回到前台就开始跑
        b.root.removeCallbacks(carBRunnable)
        b.root.postDelayed(carBRunnable, 1600L)
        if (hasBluetoothPermission() && !ble.isScanning()) ble.startScan()
    }

    override fun onPause() {
        super.onPause()
        b.root.removeCallbacks(ageTick)
        b.root.removeCallbacks(carBRunnable)
    }

    override fun onDestroy() {
        super.onDestroy()
        api?.stop()
        ble.close()
    }

    companion object {
        private const val TAG = "ElevatorApp"

        /** 给别的 App(队友导航 App) 调用的本地 HTTP 端口。 */
        private const val API_PORT = LocalApiServer.DEFAULT_PORT
    }
}
