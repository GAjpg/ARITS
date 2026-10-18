package com.hackathon.elevator

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.Camera
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.hackathon.elevator.databinding.ActivityCameraBinding
import java.util.Locale

/**
 * 摄像头读电梯厅那块屏上的数字（方案 D：**用手机自己的相机，0 元**）。
 *
 * ## 这一页其实就是"监控摄像头"
 * 现在没有装在电梯前面的固定摄像头，所以**拿一部手机当监控**：
 * 把手机对着电梯厅那块屏，打开这一页，它就一直读、一直报；
 * 别的页面（主界面 / 队友 App 效果页）显示的就是它读到的楼层。
 *
 * ## 一台摄像头能盯两台电梯
 * 并排两台电梯时，厅里那块横屏**左边一位是甲梯、右边一位是乙梯**。
 * 我们的点阵识别一次就会把**每个数字位**都读出来（按列空隙切开），
 * 所以左边那位 → 甲梯、右边那位 → 乙梯，**一台摄像头同时管两台**。
 * 只有一台电梯（或只框进来一位）也照样能用，另一位留空。
 *
 * ## 为什么是这条路
 * 另外两条"真实位置"的路子都要动硬件（听叮的麦克风、贴光敏电阻），
 * 而手机本来就有相机。屏幕上那个红点阵数字，人眼能看到，算法也能"看"到。
 *
 * ## 这条流水线（每一环都是为了解决一个真问题）
 *   1. `android.hardware.Camera` 取景 → NV21 帧（**不引新依赖**，老 API 全机型通吃）
 *   2. NV21 → **红色强度**图 [Nv21Redness]（红点阵 vs 不锈钢/蓝屏，靠"红"来分）
 *   3. **多帧取最亮** [FrameMax] —— LED 是扫描点亮的，单帧会缺笔画、把 3 读成 8 之类；
 *      连续 8 帧逐点取最大，能把"这一帧没抓到的那一段"补回来（实测中位数反而更差）
 *   4. 点阵字识别 [DotMatrixReader] → 每个数字位一个结果（从左到右）
 *   5. [DigitVoter] 多帧投票（甲、乙各一个）+ 只认井道这四层（B / 1F / 2F / 3F） —— 宁可显示"看不清"，**绝不猜**
 *
 * ## 读到了给谁用
 * 写进 [CarFloorSource]：主界面的大数字、3D 轿厢、队友 App 效果页、
 * 给队友的 `/api/status` 里的 `car` 都跟着它走（真实读数优先于"靠近哪层"的蓝牙判层）。
 *
 * ## 现场兜底
 * 万一那块屏的字形跟标准点阵差太多（读不准），下方有"现场教一下"——
 * 选甲/乙 + 点一下楼层就手动指定，摄像头读数暂停，不至于在路演时卡住。
 */
class CameraFloorActivity : AppCompatActivity(), SurfaceHolder.Callback, Camera.PreviewCallback {

    private lateinit var b: ActivityCameraBinding

    private var camera: Camera? = null
    private var worker: HandlerThread? = null
    private var workerHandler: Handler? = null
    private val main = Handler(Looper.getMainLooper())

    /** 多帧融合（抗 LED 扫描闪烁） */
    private val fuser = FrameMax(FRAMES)

    /** 多帧投票（宁可"看不清"，不猜）—— 甲梯、乙梯各一个 */
    private val voterA = DigitVoter(VOTE_K, VOTE_MIN)
    private val voterB = DigitVoter(VOTE_K, VOTE_MIN)

    private var previewW = 640
    private var previewH = 480
    private var workScale = 1
    private var redBuf = FloatArray(0)
    private var argbBuf = IntArray(0)

    private var busy = false
    private var starting = false
    private var lastPushMs = 0L
    private var lastReadMs = 0L

    /** 现场手动指定过楼层 → 暂停摄像头自动读数（不然一秒就被覆盖回去） */
    private var manualPin = false

    /** "现场教一下"正在指定哪一台：0 = 甲梯（左）、1 = 乙梯（右） */
    private var pinSlot = 0

    private val slotPills = HashMap<Int, TextView>()

    private val cameraPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                tryOpenIfReady()
            } else {
                b.camStatus.text = getString(R.string.cam_need_permission)
                toast(getString(R.string.cam_need_permission))
            }
        }

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityCameraBinding.inflate(layoutInflater)
        setContentView(b.root)

        // 这一页就是"监控摄像头"：屏幕自己黑掉 = 读数就停了（onPause 会把相机放掉）。
        // 所以在这一页里强制常亮 —— 用户不用去系统设置里改"自动锁屏"。
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        b.surface.holder.addCallback(this)
        b.btnBack.setOnClickListener { finish() }
        b.camAuto.setOnClickListener {
            manualPin = false
            b.camAuto.visibility = View.GONE
            b.camStatus.text = getString(R.string.cam_auto_restored)
        }
        buildLearnButtons()

        worker = HandlerThread("cam-floor").also { it.start() }
        workerHandler = Handler(worker!!.looper)

        if (hasCameraPermission()) {
            b.camStatus.text = getString(R.string.cam_opening)
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onResume() {
        super.onResume()
        if (hasCameraPermission()) tryOpenIfReady()
    }

    override fun onPause() {
        super.onPause()
        releaseCamera()
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseCamera()
        worker?.quitSafely()
        worker = null
        workerHandler = null
        main.removeCallbacksAndMessages(null)
    }

    // ------------------------------------------------------------------
    // 开摄像头
    // ------------------------------------------------------------------

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun holderReady(): Boolean = b.surface.holder.surface?.isValid == true

    private fun tryOpenIfReady() {
        if (isFinishing || camera != null || starting) return
        if (!hasCameraPermission() || !holderReady()) return
        starting = true
        try {
            openCamera()
        } catch (t: Throwable) {
            Log.w(TAG, "摄像头打不开", t)
            b.camStatus.text = getString(R.string.cam_open_failed)
            toast(getString(R.string.cam_open_failed))
        } finally {
            starting = false
        }
    }

    private fun openCamera() {
        val cam = Camera.open(CAMERA_ID)
        val p = cam.parameters
        val size = choosePreviewSize(p)
        previewW = size.width
        previewH = size.height
        p.setPreviewSize(size.width, size.height)
        p.previewFormat = ImageFormat.NV21
        cam.parameters = p
        cam.setDisplayOrientation(displayOrientation())
        cam.setPreviewDisplay(b.surface.holder)

        // 工作分辨率：一条 640×480 的帧在手机上一次要算 30 万个点，
        // 太大就降一半（数字在屏幕上本来就占得很大，降一半完全够认）
        workScale = if (previewW * previewH > 640 * 480) 2 else 1

        val bufSize = previewW * previewH * 3 / 2
        cam.setPreviewCallbackWithBuffer(this)
        repeat(3) { cam.addCallbackBuffer(ByteArray(bufSize)) }
        cam.startPreview()

        camera = cam
        b.camStatus.text = getString(R.string.cam_warming_up)
        Log.d(TAG, "摄像头就绪 ${previewW}x$previewH scale=$workScale")
    }

    private fun releaseCamera() {
        val cam = camera ?: return
        camera = null
        try {
            cam.setPreviewCallbackWithBuffer(null)
            cam.stopPreview()
        } catch (t: Throwable) {
            Log.w(TAG, "停预览失败", t)
        }
        try {
            cam.release()
        } catch (t: Throwable) {
            Log.w(TAG, "释放摄像头失败", t)
        }
        busy = false
        fuser.reset()
        voterA.reset()
        voterB.reset()
        b.mask.invalidate()
    }

    /** 挑一个"够用又不太大"的预览尺寸（优先 640×480）。 */
    private fun choosePreviewSize(p: Camera.Parameters): Camera.Size {
        val all = p.supportedPreviewSizes
        if (all.isNullOrEmpty()) return p.previewSize ?: error("相机没给预览尺寸")
        val target = 640 * 480
        return all.filter { it.width * it.height >= target }
            .minByOrNull { it.width * it.height }
            ?: all.maxByOrNull { it.width * it.height }!!
    }

    /** 让预览画面"正"过来。 */
    @Suppress("DEPRECATION")
    private fun displayOrientation(): Int {
        val info = Camera.CameraInfo()
        Camera.getCameraInfo(CAMERA_ID, info)
        val rotation = when (windowManager.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        return if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
            (360 - (info.orientation + rotation) % 360) % 360
        } else {
            (info.orientation - rotation + 360) % 360
        }
    }

    // ------------------------------------------------------------------
    // Surface 回调
    // ------------------------------------------------------------------

    override fun surfaceCreated(holder: SurfaceHolder) {
        tryOpenIfReady()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        tryOpenIfReady()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        releaseCamera()
    }

    // ------------------------------------------------------------------
    // 每帧
    // ------------------------------------------------------------------

    override fun onPreviewFrame(data: ByteArray?, cam: Camera?) {
        val d = data ?: return
        val h = workerHandler
        if (busy || h == null) {
            // 上一帧还没算完：这一帧直接还给相机（宁可掉帧也不排队）
            camera?.addCallbackBuffer(d)
            return
        }
        busy = true
        h.post {
            try {
                process(d)
            } catch (t: Throwable) {
                Log.w(TAG, "帧处理失败", t)
            }
            busy = false
            main.post { camera?.addCallbackBuffer(d) }
        }
    }

    private fun process(data: ByteArray) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastPushMs < MIN_FRAME_MS) return       // 限速：~7 帧/秒，别把 CPU 烧了
        lastPushMs = now

        val ow = (previewW + workScale - 1) / workScale
        val oh = (previewH + workScale - 1) / workScale
        if (redBuf.size != ow * oh) redBuf = FloatArray(ow * oh)
        Nv21Redness.fill(data, previewW, previewH, workScale, redBuf)

        val fused = fuser.push(redBuf, ow, oh)            // 最近 FRAMES 帧逐点取最亮

        if (now - lastReadMs < READ_MS) return            // 完整识别没必要每帧都跑
        lastReadMs = now

        // 红色强度 → 只留 R 通道的图，交给点阵识别（阈值/量纲与离线验证时完全一致）
        val n = ow * oh
        if (argbBuf.size != n) argbBuf = IntArray(n)
        var peak = 0f
        for (i in 0 until n) {
            val v = fused[i]
            if (v > peak) peak = v
            val iv = when {
                v > 255f -> 255
                v < 0f -> 0
                else -> v.toInt()
            }
            argbBuf[i] = 0xFF000000.toInt() or (iv shl 16)
        }

        val res = DotMatrixReader.read(argbBuf, ow, oh, DotMatrixReader.Box(0, 0, ow - 1, oh - 1))

        // 「一块横窗里两个数字位」：**从左到右**每一位就是一台电梯（左=甲、右=乙）。
        // 只读到一位也正常（这栋楼只有一台梯，或者另一台离得远没框进来）。
        val seen = ArrayList<String?>(CarFloorSource.CARS)
        for (i in 0 until CarFloorSource.CARS) {
            val r = res.getOrNull(i)
            seen.add(if (r != null && r.confident) floorOf(r.ch) else null)
        }
        val votedA = voterA.push(seen[0]?.let { FLOORS.indexOf(it) })?.let { FLOORS[it] }
        val votedB = voterB.push(seen[1]?.let { FLOORS.indexOf(it) })?.let { FLOORS[it] }

        main.post {
            b.mask.setFrame(fused, ow, oh, peak, res.map { it.box }, votedA ?: "")
            showRead(votedA, votedB, seen, res, peak)
        }
        if (!manualPin) {
            if (votedA != null) CarFloorSource.set(0, votedA, CarFloorSource.SRC_CAMERA)
            if (votedB != null) CarFloorSource.set(1, votedB, CarFloorSource.SRC_CAMERA)
        }
    }

    /** 只有井道这四层才算数（B / 1F / 2F / 3F，认成别的必然是误读）。 */
    private fun floorOf(ch: Char?): String? {
        if (ch == null) return null
        val f = "${ch}F"
        return if (FLOORS.contains(f)) f else null
    }

    // ------------------------------------------------------------------
    // 界面
    // ------------------------------------------------------------------

    private fun showRead(
        votedA: String?,
        votedB: String?,
        seen: List<String?>,
        res: List<DotMatrixReader.Result>,
        peak: Float
    ) {
        b.camRead.text = votedA ?: getString(R.string.floor_none)
        b.camRead.setTextColor(
            ContextCompat.getColor(
                this,
                if (votedA != null) R.color.display_digit else R.color.display_dim
            )
        )
        b.camReadB.text = if (votedB != null) "乙 $votedB" else ""
        b.camReadB.visibility = if (votedB != null) View.VISIBLE else View.GONE

        // 状态那行也跟颜色变：读到了 = 亮绿（站远一点都能一眼看出"读到了"），没读到 = 灰
        b.camStatus.setTextColor(
            ContextCompat.getColor(
                this,
                if (votedA != null || votedB != null) R.color.display_digit
                else R.color.text_secondary
            )
        )

        val frames = "（${fuser.frames}/$FRAMES 帧）"
        b.camStatus.text = when {
            manualPin -> getString(R.string.cam_pinned, pinName())

            peak < DotMatrixReader.MIN_RED_PEAK ->
                getString(R.string.cam_no_red) + frames

            seen.all { it == null } ->
                getString(R.string.cam_no_digit) + frames

            votedA == null && votedB == null -> {
                val r = res.firstOrNull()
                getString(
                    R.string.cam_unsure,
                    (r?.ch ?: '?').toString(),
                    fmt(r?.score),
                    fmt(r?.runnerUp)
                ) + frames
            }

            else -> {
                val got = ArrayList<String>(2)
                if (votedA != null) got.add("甲 $votedA")
                if (votedB != null) got.add("乙 $votedB")
                getString(R.string.cam_ok, got.joinToString(" · ")) + frames
            }
        }
    }

    private fun pinName(): String = "${if (pinSlot == 0) "甲" else "乙"} ${CarFloorSource.current(pinSlot) ?: ""}"

    private fun buildLearnButtons() {
        // 先选"教哪一台"，再点楼层
        for (slot in 0 until CarFloorSource.CARS) {
            val tv = TextView(this).apply {
                text = if (slot == 0) "甲" else "乙"
                gravity = Gravity.CENTER
                textSize = 14f
                setPadding(dp(11), dp(9), dp(11), dp(9))
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    pinSlot = slot
                    updatePinPills()
                }
            }
            addPill(b.learnSlots, tv, endDp = if (slot == 0) 4 else 14)
            slotPills[slot] = tv
        }
        for (f in FLOORS) {
            val tv = TextView(this).apply {
                text = f
                gravity = Gravity.CENTER
                textSize = 14f
                setPadding(dp(15), dp(9), dp(15), dp(9))
                isClickable = true
                isFocusable = true
                setOnClickListener { pinFloor(f) }
            }
            addPill(b.learnRow, tv, endDp = 8)
        }
        updatePinPills()
    }

    private fun addPill(row: LinearLayout, tv: TextView, endDp: Int) {
        tv.setBackgroundResource(R.drawable.bg_floor_normal)
        tv.setTextColor(ContextCompat.getColor(this, R.color.text_primary))
        val lp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        )
        lp.marginEnd = dp(endDp)
        tv.layoutParams = lp
        row.addView(tv)
    }

    private fun updatePinPills() {
        for ((slot, v) in slotPills) {
            val on = slot == pinSlot
            v.setBackgroundResource(
                if (on) R.drawable.bg_floor_selected else R.drawable.bg_floor_normal
            )
            v.setTextColor(
                ContextCompat.getColor(this, if (on) R.color.accent else R.color.text_secondary)
            )
        }
    }

    /** 现场教一下：手动指定"这一台电梯在哪层"，摄像头自动读数暂停。 */
    private fun pinFloor(f: String) {
        manualPin = true
        CarFloorSource.set(pinSlot, f, CarFloorSource.SRC_MANUAL)
        if (pinSlot == 0) {
            b.camRead.text = f
            b.camRead.setTextColor(ContextCompat.getColor(this, R.color.display_digit))
        } else {
            b.camReadB.text = "乙 $f"
            b.camReadB.visibility = View.VISIBLE
        }
        b.camAuto.visibility = View.VISIBLE
        b.camStatus.text = getString(R.string.cam_pinned, pinName())
        toast(getString(R.string.cam_pinned_toast, pinName()))
    }

    private fun fmt(v: Double?): String =
        if (v == null) "-" else String.format(Locale.US, "%.2f", v)

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private companion object {
        const val TAG = "ElevatorApp"

        /** 后置摄像头 */
        const val CAMERA_ID = 0

        /** 融合几帧（8 帧 ≈ 1 秒出头，够补回扫描丢的笔画，又不至于把换层瞬间混在一起） */
        const val FRAMES = 8

        /** 帧间隔下限（毫秒）→ 约 7 帧/秒 */
        const val MIN_FRAME_MS = 140L

        /** 完整识别的间隔（毫秒） */
        const val READ_MS = 400L

        /** 投票窗口 / 至少几票 */
        const val VOTE_K = 3
        const val VOTE_MIN = 2

        val FLOORS = listOf("B", "1F", "2F", "3F")
    }
}
