package com.hackathon.elevator

import android.annotation.SuppressLint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.hackathon.elevator.databinding.ActivityNavMockBinding
import kotlin.random.Random

/**
 * 「队友导航 App · 最终页面效果」模拟页。
 *
 * 这一页是给**我们自己人看的**：把队友那个 iOS 导航 App 最后的样子，
 * 用安卓先摆出来，好在没硬件、没联调的时候就能看到效果。
 *
 * ## 页面结构
 *   1. 假地图 / AR 背景（[NavMapView]，纯装饰）+ 顶部悬浮卡：**电梯现在在几层**；
 *   2. 右侧绿色圆钮，**两个作用**：
 *        · **直接点** = 呼梯（按"你要去哪层"算出该按上行还是下行）；
 *        · **按住向左拖** = 进**全屏大屏**（电梯呼叫页，照主界面做的）：
 *          两台井道并排 + 大层显 + 楼层键 + ▲▼ + 底部状态；
 *   3. 大屏里可以**看到两台电梯各自的轿厢位置**（甲梯 / 乙梯）；
 *   4. 底部一排"模拟开关"：手动摆出"你在哪层 / 去哪层 / 甲梯在哪层 / 乙梯在哪层"。
 *
 * ## 两台电梯怎么来的
 * 一栋楼并排两台电梯是常态，电梯厅那块横屏**左边一位 = 甲梯、右边一位 = 乙梯**。
 * 摄像头那一页（[CameraFloorActivity]）一次就能把两位都读出来，写进 [CarFloorSource]，
 * 所以**一台摄像头就能同时显示两台电梯的实际位置**。
 *
 * 演示时我们**只模拟一台电梯（甲梯）**：
 *   · **甲梯 = 你在哪层它就画在哪层**（真机上就是"蓝牙判层"：手机靠近哪层的装置，轿厢就在哪层），
 *     点了悬浮钮呼梯，它还会**一层一层开过来**，到了自动开门；
 *   · **乙梯只是"另一台电梯"的装饰**：B~3F 随机慢慢跑，纯模拟，不代表任何真实读数。
 *
 * ⚠️ 这一页**没有真的蓝牙、没有真的摄像头**去连装置：呼梯是假的（只走一遍界面流程），
 *    楼层数字**优先用 [CarFloorSource] 里的真实读数**（摄像头读到了就显示真值），
 *    没有真实读数就用这里的模拟值（会自己跑，也能手点）。
 *    凡是模拟出来的都标了"模拟"。
 */
class NavMockActivity : AppCompatActivity() {

    private lateinit var b: ActivityNavMockBinding

    private val floors = listOf("B", "1F", "2F", "3F")

    /** 装了呼梯装置的楼层（和主 App 一致：只有 1F / 2F） */
    private val deviceFloors = listOf("1F", "2F")

    private var youFloor = "1F"      // 你在哪层（模拟：来自蓝牙 RSSI）
    private var destFloor = "3F"     // 要去哪层（模拟：来自导航路线）
    private var carA = "1F"          // 甲梯轿厢在哪层（**跟着 youFloor 走**；真机上这个数来自蓝牙判层）
    private var carB = "3F"          // 乙梯轿厢在哪层（纯装饰：随机慢慢跑）
    private var autoRun = true       // 乙梯自动乱跑（方便看效果）
    private var calling = false      // 正在呼叫（防止连点）
    private var traveling = false    // 甲梯轿厢正在赶过来

    /** 大屏里选的"要按哪一层的装置"（默认 = 你所在层） */
    private var callFloor = "1F"

    private var bigOpen = false

    /** 临时状态文字（呼叫中/回执）；为 null 时显示"靠近 xx · 在线 2/2" */
    private var transient: String? = null

    private val ui = Handler(Looper.getMainLooper())

    private val youPills = LinkedHashMap<String, TextView>()
    private val destPills = LinkedHashMap<String, TextView>()
    private val carPills = LinkedHashMap<String, TextView>()
    private val carBPills = LinkedHashMap<String, TextView>()
    private val bigFloorPills = LinkedHashMap<String, TextView>()

    /**
     * 乙梯自动乱跑：每 3 秒左右（再随机加一点）换一层，**跳 1~2 层**。
     * 甲梯**不在这里动** —— 它只跟着"你在哪层"走（见 [refreshAll]）。
     */
    private val autoTick = object : Runnable {
        override fun run() {
            // 有真实读数时别让模拟值在底下乱跑（不然真实读数一过期就"跳"）
            val hasReal = CarFloorSource.current(0) != null || CarFloorSource.current(1) != null
            if (autoRun && !traveling && !calling && !hasReal) {
                stepCarB()
                refreshAll()
            }
            ui.postDelayed(this, 3000L + Random.nextLong(1600L))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityNavMockBinding.inflate(layoutInflater)
        setContentView(b.root)

        // ---- 两台井道（照主界面：B~3F，把 1F/2F 做全） ----
        val focus = deviceFloors.mapNotNull { f -> floors.indexOf(f).takeIf { it >= 0 } }
        for (v in listOf(b.shaftA, b.shaftB)) {
            v.floors = floors
            v.focusIndices = focus
        }

        // ---- 底部模拟开关 ----
        youPills["1F"] = b.pillYou1
        youPills["2F"] = b.pillYou2
        val destViews = listOf(b.pillDest1, b.pillDest2, b.pillDest3, b.pillDest4)
        val carViews = listOf(b.pillCar1, b.pillCar2, b.pillCar3, b.pillCar4)
        val carBViews = listOf(b.pillCarB1, b.pillCarB2, b.pillCarB3, b.pillCarB4)
        floors.forEachIndexed { i, f ->
            destPills[f] = destViews[i]
            carPills[f] = carViews[i]
            carBPills[f] = carBViews[i]
        }
        for ((f, v) in youPills) v.setOnClickListener {
            youFloor = f
            callFloor = f
            carA = f            // 甲梯 = 你在哪层，它就画在哪层
            refreshAll()
        }
        for ((f, v) in destPills) v.setOnClickListener { destFloor = f; refreshAll() }
        // 手点轿厢 = "我就想让它显示这一层" -> 顺带把这个槽的真实读数清掉，免得真实值把它盖回去
        for ((f, v) in carPills) v.setOnClickListener {
            carA = f
            CarFloorSource.clear(0)
            refreshAll()
        }
        for ((f, v) in carBPills) v.setOnClickListener {
            autoRun = false      // 手点了就停下来，不然马上被"乱跑"顶掉
            carB = f
            CarFloorSource.clear(1)
            refreshAll()
        }
        b.pillAuto.setOnClickListener {
            autoRun = !autoRun
            if (autoRun) CarFloorSource.clear()   // 回到"全自动模拟"
            refreshAll()
        }

        // ---- 大屏里的楼层按钮（选"按哪一层的装置"） ----
        buildBigFloorButtons()

        // ---- 悬浮钮：点 = 呼梯，向左拖 = 进大屏 ----
        b.fab.setOnClickListener { call(plannedDir()) }
        setupFabDrag()

        // ---- 大屏里的按钮 ----
        b.bigBack.setOnClickListener { closeBig() }
        b.bigUp.setOnClickListener { call(BleManager.CMD_UP) }
        b.bigDown.setOnClickListener { call(BleManager.CMD_DOWN) }

        // 返回键：大屏开着就先回地图，不直接退出
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (bigOpen) closeBig() else finish()
            }
        })

        refreshAll()
        // 自动运行的定时器在 onResume 里挂（onCreate 后必然会走 onResume，避免挂两份）
    }

    /** 大屏里的楼层胶囊：B~3F，只有 1F/2F 装了装置（灰掉的是没装置的）。 */
    private fun buildBigFloorButtons() {
        for (f in floors) {
            val hasDevice = deviceFloors.contains(f)
            val tv = TextView(this).apply {
                text = f
                gravity = android.view.Gravity.CENTER
                textSize = 16f
                setPadding(dp(17), dp(11), dp(17), dp(11))
                isClickable = true
                isFocusable = true
                alpha = if (hasDevice) 1f else 0.35f
                setOnClickListener {
                    if (!hasDevice) toast("$f 没有呼梯装置（本演示只有 1F / 2F）")
                    else {
                        callFloor = f
                        refreshAll()
                    }
                }
            }
            val lp = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
            )
            lp.marginEnd = dp(9)
            tv.layoutParams = lp
            b.bigFloorRow.addView(tv)
            bigFloorPills[f] = tv
        }
    }

    // ------------------------------------------------------------------
    // 界面刷新
    // ------------------------------------------------------------------

    private fun refreshAll() {
        // 模拟开关的高亮
        for ((f, v) in youPills) setPill(v, f == youFloor)
        for ((f, v) in destPills) setPill(v, f == destFloor)
        for ((f, v) in carPills) setPill(v, f == carA)
        for ((f, v) in carBPills) setPill(v, f == carB)
        for ((f, v) in bigFloorPills) setPill(v, f == callFloor)
        setPill(b.pillAuto, autoRun)

        // 真实读数优先（摄像头读到了就用真值，没读到才用模拟值）
        val realA = CarFloorSource.current(0)
        val realB = CarFloorSource.current(1)
        val showA = realA ?: carA
        val showB = realB ?: carB

        // 顶部悬浮卡：电梯现在在几层（主看甲梯 = 我们装了装置的那台）
        b.carFloor.text = showA
        b.carNote.text = when {
            realA != null -> "甲梯 · " + realLine(0)
            realB != null -> "甲梯 · 跟着你 ｜ 乙梯 · " + realLine(1)
            traveling -> "甲梯正在赶往 $showA…（跟着你）"
            else -> "甲梯跟着你（$youFloor）· 乙梯自动跑"
        }

        // 大屏：两台层显 + 两台井道里的轿厢（层显框里只放数字，底下不写小字）
        b.bigFloorA.text = showA
        b.bigFloorB.text = showB
        b.shaftA.moveCarTo(floorIndex(showA))
        b.shaftB.moveCarTo(floorIndex(showB))

        // 悬浮钮：呼叫的楼层 = 你所在楼层；箭头 = 往目的地是上还是下
        val dir = plannedDir()
        b.fabArrow.text = when (dir) {
            BleManager.CMD_UP -> getString(R.string.arrow_up)
            BleManager.CMD_DOWN -> getString(R.string.arrow_down)
            else -> "•"
        }
        b.fabFloor.text = youFloor

        // 大屏底部：这一趟怎么走
        b.bigBottom.text = transient ?: run {
            val d = plannedDir()
            when {
                destFloor == youFloor -> "你已经在 $youFloor，这趟不用坐电梯"
                d == null -> "● 靠近 $youFloor · 在线 2/2 · 就绪（模拟）"
                else -> "● 靠近 $youFloor · 去 $destFloor → 按 $callFloor 的${dirLabel(d)} · 在线 2/2（模拟）"
            }
        }
    }

    /**
     * 这一台的数字是**真读数**时怎么念：`真 · 摄像头 · 刚刚`。
     *
     * 没有真读数的情况不在这儿 —— 甲梯是"跟着你"、乙梯是"另一台电梯在跑"，
     * 由 [refreshAll] 里那几句人话直接说；**两台层显下面不再写"模拟 · …"那行小字**（v9）。
     */
    private fun realLine(slot: Int): String =
        "真 · ${CarFloorSource.sourceLabel(slot)} · ${CarFloorSource.ageText(slot)}"

    private fun floorIndex(f: String): Int = floors.indexOf(f).coerceAtLeast(0)

    private fun setPill(v: TextView, on: Boolean) {
        v.setBackgroundResource(
            if (on) R.drawable.bg_floor_selected else R.drawable.bg_floor_normal
        )
        v.setTextColor(
            ContextCompat.getColor(this, if (on) R.color.accent else R.color.text_secondary)
        )
    }

    // ------------------------------------------------------------------
    // 悬浮钮：点 = 呼梯，向左拖 = 进全屏大屏
    // ------------------------------------------------------------------

    @SuppressLint("ClickableViewAccessibility")
    private fun setupFabDrag() {
        var startX = 0f
        var dragged = false
        b.fab.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = e.rawX
                    dragged = false
                    v.animate().cancel()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - startX
                    if (dx < -dp(10)) dragged = true
                    v.translationX = if (dx < 0f) dx else 0f
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (v.translationX <= -dp(56)) {
                        v.translationX = 0f
                        openBig()
                    } else {
                        v.animate().translationX(0f).setDuration(140).start()
                    }
                    if (!dragged) v.performClick()
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.animate().translationX(0f).setDuration(140).start()
                    true
                }
                else -> false
            }
        }
    }

    /** 向左拖出来 = 全屏大屏（电梯呼叫页）。 */
    private fun openBig() {
        bigOpen = true
        b.expandHint.visibility = View.GONE
        b.fab.visibility = View.GONE
        b.topCard.visibility = View.GONE
        b.simBar.visibility = View.GONE
        b.bigPage.alpha = 0f
        b.bigPage.visibility = View.VISIBLE
        b.bigPage.animate().alpha(1f).setDuration(180).start()
        refreshAll()
    }

    private fun closeBig() {
        bigOpen = false
        b.bigPage.animate().alpha(0f).setDuration(150).withEndAction {
            b.bigPage.visibility = View.GONE
            b.fab.visibility = View.VISIBLE
            b.fab.alpha = 0f
            b.fab.animate().alpha(1f).setDuration(140).start()
            b.topCard.visibility = View.VISIBLE
            b.simBar.visibility = View.VISIBLE
            b.expandHint.visibility = View.VISIBLE
        }.start()
    }

    // ------------------------------------------------------------------
    // 呼叫（模拟）
    // ------------------------------------------------------------------

    /**
     * 走一遍真实的呼叫流程：下发 -> 约 1.3 秒后收到回执 -> 轿厢赶过来。
     * @param dir `CMD_UP` / `CMD_DOWN`；null 表示"你已经在目的地楼层"
     */
    private fun call(dir: String?) {
        if (calling) {
            toast("正在呼叫中，请稍候…")
            return
        }
        if (dir == null) {
            toast("你已经在 $youFloor 了，这趟不用坐电梯")
            return
        }
        if (!deviceFloors.contains(callFloor)) {
            toast("$callFloor 没装呼梯装置（本演示只有 1F / 2F）")
            return
        }

        calling = true
        transient = "正在呼叫… 已下发 ${dirLabel(dir)} → ELEV-$callFloor（模拟）"
        refreshAll()

        ui.postDelayed({
            calling = false
            val ack = if (dir == BleManager.CMD_UP) "UP" else "DOWN"
            transient = "✓ 收到 $callFloor|OK:$ack —— 装置已按下（模拟）"
            refreshAll()
            moveCarTo(callFloor)
            ui.postDelayed({
                transient = null
                refreshAll()
            }, 2800L)
        }, 1300L)
    }

    /** 模拟甲梯轿厢一层一层开过来 */
    private fun moveCarTo(target: String) {
        val ti = floors.indexOf(target)
        if (ti < 0) return
        traveling = true
        refreshAll()

        fun step() {
            val ci = floors.indexOf(carA)
            if (ci < 0 || ci == ti) {
                traveling = false
                refreshAll()
                return
            }
            carA = floors[if (ti > ci) ci + 1 else ci - 1]
            refreshAll()
            ui.postDelayed({ step() }, 650L)
        }
        ui.postDelayed({ step() }, 400L)
    }

    /**
     * 乙梯自动运行：**随机**换一层（距离 1~2 层），间隔由 [autoTick] 控制（3 秒起）。
     * 甲梯不参与：它跟着"你在哪层"，只有呼梯时才一层一层开过来。
     */
    private fun stepCarB() {
        val j = floors.indexOf(carB).coerceAtLeast(0)
        val cand = listOf(j - 2, j - 1, j + 1, j + 2).filter { it in floors.indices }
        carB = floors[cand.random()]
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    /** 按"你在哪层 + 要去哪层"算出该按上行还是下行；null = 不用坐电梯 */
    private fun plannedDir(): String? {
        val y = floors.indexOf(youFloor)
        val d = floors.indexOf(destFloor)
        if (y < 0 || d < 0) return null
        return when {
            d > y -> BleManager.CMD_UP
            d < y -> BleManager.CMD_DOWN
            else -> null
        }
    }

    private fun dirLabel(dir: String?): String =
        if (dir == BleManager.CMD_DOWN) "下行" else "上行"

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(autoTick)
    }

    override fun onResume() {
        super.onResume()
        ui.postDelayed(autoTick, 1600L)
        refreshAll()
    }

    override fun onDestroy() {
        super.onDestroy()
        ui.removeCallbacksAndMessages(null)
    }
}
