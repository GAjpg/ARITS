package com.hackathon.elevator

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.os.SystemClock
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 立体电梯井（软件 3D，可旋转）。
 *
 * 一个极轻量的**软件 3D 渲染器**（不引入 OpenGL）：
 *   模型坐标定义几何 → yaw/pitch 旋转 → 透视投影 → 平面着色 → 画家算法按深度排序。
 *
 * 场景内容（尽量贴近真实电梯）：
 *   · 玻璃井道(4 面) + 金属框架(顶圈梁/底坑/四立柱/每层腰线)
 *   · 每层的**厅门框**（层门外框 + 中缝）与**呼梯面板**
 *   · 楼板做成“贴墙的窄环”，中间整个是井道空腔（轿厢/对重才能通过）
 *   · 轿厢：几乎塞满井道的六面体，正面 = 层门(两扇 + 中缝暖光 + 门楣/地坎)
 *   · **对重**（与轿厢反向运动）+ **曳引绳** + 顶部**曳引机/曳引轮**
 *
 * 比例：轿厢高度 ≈ 层高，井道壁距轿厢仅留一点安装间隙 —— 也就是“井道小一点、整体高一点”。
 *
 * 交互：拖动旋转 / 俯仰（默认不自动旋转）；轿厢只在“判定楼层变化”时由 moveCarTo(floor) 平滑升降。
 */
class ElevatorView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    var floors: List<String> = listOf("B", "1F", "2F", "3F")
        set(value) {
            field = if (value.isEmpty()) listOf("1F") else value
            carIndex = carIndex.coerceIn(0, field.size - 1)
            geometryDirty = true
            dirty = true
            invalidate()
        }

    /** 是否自动缓慢旋转。默认关闭：井道保持不动，只允许手指拖动旋转。 */
    var autoRotate = false

    /**
     * 必须**完整**显示的楼层下标（其余楼层只露半截，并画成暗影）。
     * 本项目里只有 1F / 2F 装了呼梯装置，于是把这两层做全、B / 3F 做半截虚影，
     * 井道因此能放大将近一倍。留空 = 回到“整座井道铺满”的老样子。
     */
    var focusIndices: List<Int> = emptyList()
        set(value) {
            field = value
            geometryDirty = true
            dirty = true
            invalidate()
        }

    /** 把轿厢平滑移动到指定楼层（0 = 最底层）。 */
    fun moveCarTo(floorIndex: Int) {
        val i = floorIndex.coerceIn(0, (floors.size - 1).coerceAtLeast(0))
        if (i == carIndex && carInited) return
        carIndex = i
        carTargetY = carCenterY(i)
        dirty = true
    }

    /**
     * 开门：门开 → 停 [holdMs] 毫秒 → 自己关上。
     * 轿厢**到站**时会自动调它（见 [autoDoorOnArrive]），也可以手动调（例如"按了呼梯"）。
     */
    fun openDoors(holdMs: Long = 1800L) {
        doorTarget = 1f
        dirty = true
        removeCallbacks(closeDoors)
        postDelayed(closeDoors, holdMs.coerceIn(300L, 10_000L))
    }

    // ==================================================================
    // 几何常量（模型单位）
    // ==================================================================

    private val shaftHalf = 0.80f     // 井道内壁半宽/半深
    private val carHalf = 0.66f       // 轿厢半宽/半深（只留 0.14 安装间隙 → 塞满）
    private val carHalfH = 1.05f      // 轿厢半高（总高 2.1，接近层高）
    private val floorGap = 2.60f      // 层高
    private val carClear = 0.06f      // 轿厢底距楼板
    private val pitDepth = 0.45f      // 底坑
    private val headroom = 1.00f      // 顶层上方净空（放曳引机）
    private val slabBorder = 0.11f    // 楼板贴墙窄环宽度

    private var shaftBottom = 0f
    private var shaftTop = 0f

    // 视野窗口：把 focusIndices 的两层（含上下各露一小截）框进一屏
    private var viewCenterY = 0f
    private var viewHeight = 1f
    private var bandBottom = Float.NEGATIVE_INFINITY
    private var bandTop = Float.POSITIVE_INFINITY

    private fun slabY(i: Int) = i * floorGap
    private fun carCenterY(i: Int) = slabY(i) + carHalfH + carClear
    private fun doorH() = carHalfH * 2f - 0.18f

    // ==================================================================
    // 状态
    // ==================================================================

    private var geometryDirty = true

    /** 需要重绘一次（尺寸变化/换向/初始化时置位）。 */
    private var dirty = true
    private var carIndex = 0
    private var carY = 0f
    private var carTargetY = 0f
    private var carInited = false
    private var cwY = 0f

    /**
     * **开门效果**：`doorOpen` = 门开合程度（0 = 全关，1 = 全开）。
     * 轿厢**到站**时自动开一会儿再关上（见 [autoDoorOnArrive]），门一开两扇门就往两边缩，
     * 中间露出轿内暖光 —— 看起来就是"电梯到了、门开了"。
     */
    private var doorOpen = 0f
    private var doorTarget = 0f

    /** 到站是否自动开门（默认开）。关掉它就只剩升降动画。 */
    var autoDoorOnArrive = true

    private val closeDoors = Runnable {
        doorTarget = 0f
        dirty = true
    }

    // 初始朝向：略微侧转，能同时看到正面轿门与井道纵深
    private var yaw = 0.42f
    private var pitch = -0.13f
    private var dragging = false
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var lastFrameMs = 0L

    private var focal = 1f
    private var cx = 0f
    private var cyc = 0f

    // ==================================================================
    // 画笔 / 缓冲（全部复用）
    // ==================================================================

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = resources.displayMetrics.density * 1.1f
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#C6DCF0")
        textSize = resources.displayMetrics.density * 14f
        isFakeBoldText = true
    }
    private val path = Path()

    /** 上下渐隐（让半截楼层融进黑暗里） */
    private val fadePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var fadeTop: Shader? = null
    private var fadeBottom: Shader? = null
    private var fadeH = -1f

    private val MAXF = 240
    private val fPts = FloatArray(MAXF * 8)
    private val fDepth = FloatArray(MAXF)
    private val fColor = IntArray(MAXF)
    private val fLine = BooleanArray(MAXF)
    private val fText = arrayOfNulls<String>(MAXF)
    private val order = IntArray(MAXF)
    private var fCount = 0
    private val verts = FloatArray(12)

    private val lx = 0.40f
    private val ly = 0.80f
    private val lz = 0.45f

    private companion object {
        const val DIST = 9.0f
        const val AUTO_SPIN = 0.30f
        const val NEAR = 0.15f

        /** 无关楼层（B / 3F）的透明度系数——越小明虚影越淡。 */
        const val GHOST = 0.26f
    }

    init { isClickable = true }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        geometryDirty = true
        dirty = true
    }

    // ==================================================================
    // 动画循环
    // ==================================================================

    private val frameLoop = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            val dt = if (lastFrameMs == 0L) 0.016f
            else ((now - lastFrameMs).coerceIn(0L, 50L)) / 1000f
            lastFrameMs = now

            if (autoRotate && !dragging) yaw += dt * AUTO_SPIN

            if (!carInited) {
                carY = carTargetY
                cwY = cwYFor(carY)
                carInited = true
            }
            val moving = abs(carTargetY - carY) > 0.0005f
            carY += (carTargetY - carY) * (dt * 5f).coerceIn(0f, 1f)
            cwY = cwYFor(carY)
            val stillMoving = abs(carTargetY - carY) > 0.0005f

            // 门：一走就关；刚好停下（到站）就自动开一会儿再关
            if (stillMoving) {
                if (doorTarget != 0f) {
                    doorTarget = 0f
                    removeCallbacks(closeDoors)
                }
            } else if (moving && autoDoorOnArrive) {
                openDoors()
            }
            val doorAnimating = abs(doorTarget - doorOpen) > 0.002f
            if (doorAnimating) {
                doorOpen += (doorTarget - doorOpen) * (dt * 7f).coerceIn(0f, 1f)
                if (abs(doorTarget - doorOpen) <= 0.002f) doorOpen = doorTarget
                dirty = true
            }

            // 不旋转、不升降、门也不动时就不重绘（静止省电）
            if (dirty || moving || doorAnimating || (autoRotate && !dragging)) {
                dirty = false
                invalidate()
            }
            postOnAnimation(this)
        }
    }

    /** 对重与轿厢反向运动。 */
    private fun cwYFor(cy: Float): Float {
        val n = (floors.size - 1).coerceAtLeast(1)
        val t = ((cy - carCenterY(0)) / (carCenterY(n) - carCenterY(0))).coerceIn(0f, 1f)
        val cwTop = shaftTop - 0.75f
        val cwBot = shaftBottom + 0.85f
        return cwTop + t * (cwBot - cwTop)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        lastFrameMs = 0L
        dirty = true
        postOnAnimation(frameLoop)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        removeCallbacks(frameLoop)
    }

    // ==================================================================
    // 触摸
    // ==================================================================

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                dragging = true
                lastTouchX = event.x
                lastTouchY = event.y
                parent?.requestDisallowInterceptTouchEvent(true)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                yaw += (event.x - lastTouchX) * 0.012f
                pitch = (pitch + (event.y - lastTouchY) * 0.005f).coerceIn(-0.80f, 0.12f)
                lastTouchX = event.x
                lastTouchY = event.y
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                dragging = false
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    // ==================================================================
    // 几何 / 投影
    // ==================================================================

    private fun ensureGeometry() {
        val w = width.toFloat()
        val h = height.toFloat()
        cx = w / 2f
        cyc = h / 2f

        if (geometryDirty) {
            val n = floors.size
            shaftBottom = slabY(0) - pitDepth
            shaftTop = carCenterY(n - 1) + carHalfH + headroom

            val focus = focusIndices.filter { it in 0 until n }
            if (focus.isEmpty()) {
                // 老样子：整座井道铺满
                viewCenterY = (shaftBottom + shaftTop) / 2f
                viewHeight = shaftTop - shaftBottom
                bandBottom = Float.NEGATIVE_INFINITY
                bandTop = Float.POSITIVE_INFINITY
            } else {
                // 只要 focus 里的楼层“做全”，上下各多露一点给相邻楼层（做暗影）
                val i0 = focus.minOrNull() ?: 0
                val i1 = focus.maxOrNull() ?: 0
                val vb = slabY(i0) - 1.00f        // 下沿：看到下一层的上半截
                val vt = slabY(i1 + 1) + 0.80f    // 上沿：看到上一层的下半截
                viewCenterY = (vb + vt) / 2f
                viewHeight = vt - vb
                bandBottom = slabY(i0)
                bandTop = slabY(i1 + 1)
            }
            carTargetY = carCenterY(carIndex)
            geometryDirty = false
        }
        // 竖向：把“视野窗口”撑满 ~96% 高度（窗口越窄，井道看着越大）
        focal = (h * 0.96f) * DIST / viewHeight

        if (fadeH != h) {
            fadeH = h
            val edge = Color.argb(210, 3, 7, 12)
            val clear = Color.argb(0, 3, 7, 12)
            val fh = h * 0.22f
            fadeTop = LinearGradient(0f, 0f, 0f, fh, edge, clear, Shader.TileMode.CLAMP)
            fadeBottom = LinearGradient(0f, h, 0f, h - fh, edge, clear, Shader.TileMode.CLAMP)
        }
    }

    private fun project(x: Float, y: Float, z: Float, out: FloatArray, oi: Int) {
        val cy = cos(yaw); val sy = sin(yaw)
        val cp = cos(pitch); val sp = sin(pitch)
        val yy = y - viewCenterY
        val rx = x * cy + z * sy
        val rz0 = -x * sy + z * cy
        val ry = yy * cp - rz0 * sp
        val rz = yy * sp + rz0 * cp + DIST
        val zz = if (rz < NEAR) NEAR else rz
        val s = focal / zz
        out[oi] = cx + rx * s
        out[oi + 1] = cyc - ry * s
    }

    private fun camDepth(x: Float, y: Float, z: Float): Float {
        val cy = cos(yaw); val sy = sin(yaw)
        val cp = cos(pitch); val sp = sin(pitch)
        val yy = y - viewCenterY
        val rz0 = -x * sy + z * cy
        return yy * sp + rz0 * cp + DIST
    }

    /** 落在 1F~2F 带之外的几何，统一画成“暗影”。 */
    private fun ghostAt(y: Float) = y < bandBottom || y > bandTop

    private fun ghosted(color: Int): Int {
        val a = (((color ushr 24) and 0xFF) * GHOST).toInt().coerceIn(0, 255)
        return (a shl 24) or (color and 0x00FFFFFF)
    }

    private fun shade(base: Int, bright: Float, alpha: Int): Int {
        val b = bright.coerceIn(0.18f, 1.35f)
        val r = (((base shr 16) and 0xFF) * b).toInt().coerceIn(0, 255)
        val g = (((base shr 8) and 0xFF) * b).toInt().coerceIn(0, 255)
        val bl = ((base and 0xFF) * b).toInt().coerceIn(0, 255)
        return (alpha shl 24) or (r shl 16) or (g shl 8) or bl
    }

    /** 两个颜色按 t(0..1) 混合 —— 用来做“开门 → 轿内亮起来”的渐变。 */
    private fun lerpColor(c0: Int, c1: Int, t: Float): Int {
        val a = t.coerceIn(0f, 1f)
        val r = (((c0 shr 16) and 0xFF) + ((((c1 shr 16) and 0xFF) - ((c0 shr 16) and 0xFF)) * a)).toInt().coerceIn(0, 255)
        val g = (((c0 shr 8) and 0xFF) + ((((c1 shr 8) and 0xFF) - ((c0 shr 8) and 0xFF)) * a)).toInt().coerceIn(0, 255)
        val b = ((c0 and 0xFF) + (((c1 and 0xFF) - (c0 and 0xFF)) * a)).toInt().coerceIn(0, 255)
        return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    private fun faceBrightness(): Float {
        val cy = cos(yaw); val sy = sin(yaw)
        val cp = cos(pitch); val sp = sin(pitch)
        val ax = verts[3] - verts[0]; val ay = verts[4] - verts[1]; val az = verts[5] - verts[2]
        val bx = verts[6] - verts[0]; val by = verts[7] - verts[1]; val bz = verts[8] - verts[2]
        var nx = ay * bz - az * by
        var ny = az * bx - ax * bz
        var nz = ax * by - ay * bx
        val nl = sqrt(nx * nx + ny * ny + nz * nz)
        if (nl > 1e-6f) { nx /= nl; ny /= nl; nz /= nl }
        val rnx = nx * cy + nz * sy
        val rnz0 = -nx * sy + nz * cy
        val rny = ny * cp - rnz0 * sp
        val rnz = ny * sp + rnz0 * cp
        return 0.34f + 0.66f * abs(rnx * lx + rny * ly + rnz * lz)
    }

    private fun setQuad(
        x0: Float, y0: Float, z0: Float,
        x1: Float, y1: Float, z1: Float,
        x2: Float, y2: Float, z2: Float,
        x3: Float, y3: Float, z3: Float
    ) {
        verts[0] = x0; verts[1] = y0; verts[2] = z0
        verts[3] = x1; verts[4] = y1; verts[5] = z1
        verts[6] = x2; verts[7] = y2; verts[8] = z2
        verts[9] = x3; verts[10] = y3; verts[11] = z3
    }

    private fun emitQuad(base: Int, alpha: Int, brightOverride: Float = -1f) {
        if (fCount >= MAXF) return
        var bright = if (brightOverride > 0f) brightOverride else faceBrightness()
        var a = alpha
        val f = fCount++
        val b = f * 8
        var depth = 0f
        var ys = 0f
        for (k in 0 until 4) {
            val x = verts[k * 3]; val y = verts[k * 3 + 1]; val z = verts[k * 3 + 2]
            project(x, y, z, fPts, b + k * 2)
            depth += camDepth(x, y, z)
            ys += y
        }
        if (ghostAt(ys * 0.25f)) {
            a = (alpha * GHOST).toInt().coerceIn(0, 255)
            bright *= 0.62f
        }
        fDepth[f] = depth * 0.25f
        fColor[f] = shade(base, bright, a)
        fLine[f] = false
        fText[f] = null
    }

    private fun emitLine(
        x0: Float, y0: Float, z0: Float,
        x1: Float, y1: Float, z1: Float,
        color: Int
    ) {
        if (fCount >= MAXF) return
        val f = fCount++
        val b = f * 8
        project(x0, y0, z0, fPts, b)
        project(x1, y1, z1, fPts, b + 2)
        fDepth[f] = (camDepth(x0, y0, z0) + camDepth(x1, y1, z1)) * 0.5f
        fColor[f] = if (ghostAt((y0 + y1) * 0.5f)) ghosted(color) else color
        fLine[f] = true
        fText[f] = null
    }

    private fun emitText(text: String, x: Float, y: Float, z: Float) {
        if (fCount >= MAXF) return
        val f = fCount++
        project(x, y, z, fPts, f * 8)
        fDepth[f] = camDepth(x, y, z)
        fColor[f] = if (ghostAt(y)) ghosted(Color.parseColor("#C6DCF0")) else Color.parseColor("#C6DCF0")
        fLine[f] = false
        fText[f] = text
    }

    /** 一个长方体（6 面）。 */
    private fun box(ox: Float, oy: Float, oz: Float, hx: Float, hy: Float, hz: Float, base: Int, alpha: Int) {
        setQuad(ox - hx, oy - hy, oz - hz, ox + hx, oy - hy, oz - hz, ox + hx, oy + hy, oz - hz, ox - hx, oy + hy, oz - hz); emitQuad(base, alpha)
        setQuad(ox - hx, oy - hy, oz + hz, ox + hx, oy - hy, oz + hz, ox + hx, oy + hy, oz + hz, ox - hx, oy + hy, oz + hz); emitQuad(base, alpha)
        setQuad(ox - hx, oy - hy, oz - hz, ox - hx, oy - hy, oz + hz, ox - hx, oy + hy, oz + hz, ox - hx, oy + hy, oz - hz); emitQuad(base, alpha)
        setQuad(ox + hx, oy - hy, oz - hz, ox + hx, oy - hy, oz + hz, ox + hx, oy + hy, oz + hz, ox + hx, oy + hy, oz - hz); emitQuad(base, alpha)
        setQuad(ox - hx, oy + hy, oz - hz, ox + hx, oy + hy, oz - hz, ox + hx, oy + hy, oz + hz, ox - hx, oy + hy, oz + hz); emitQuad(base, alpha)
        setQuad(ox - hx, oy - hy, oz - hz, ox + hx, oy - hy, oz - hz, ox + hx, oy - hy, oz + hz, ox - hx, oy - hy, oz + hz); emitQuad(base, alpha)
    }

    private fun rectLines(h: Float, y: Float, color: Int) {
        emitLine(-h, y, -h, h, y, -h, color)
        emitLine(h, y, -h, h, y, h, color)
        emitLine(h, y, h, -h, y, h, color)
        emitLine(-h, y, h, -h, y, -h, color)
    }

    // ==================================================================
    // 场景
    // ==================================================================

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        ensureGeometry()
        fCount = 0

        val frame = Color.parseColor("#9FC0DE")
        val frameSoft = Color.argb(200, 159, 192, 222)

        buildShaft(frame, frameSoft)
        buildLandings(frameSoft)
        buildFloors()
        buildMechanism()
        buildCar()

        for (i in floors.indices) {
            emitText(floors[i], -0.30f, slabY(i) + 0.34f, -shaftHalf + 0.04f)
        }

        drawFaces(canvas)

        // 上下渐隐：让 B / 3F 的半截楼层融进黑暗里，像虚影
        val vw = width.toFloat()
        val vh = height.toFloat()
        val fh = vh * 0.22f
        fadePaint.shader = fadeTop
        canvas.drawRect(0f, 0f, vw, fh, fadePaint)
        fadePaint.shader = fadeBottom
        canvas.drawRect(0f, vh - fh, vw, vh, fadePaint)
    }

    private fun buildShaft(frame: Int, frameSoft: Int) {
        val h = shaftHalf
        val b = shaftBottom
        val t = shaftTop
        val glass = Color.parseColor("#3E6FA8")

        // 4 面玻璃井壁
        setQuad(-h, b, -h, h, b, -h, h, t, -h, -h, t, -h); emitQuad(glass, 34)
        setQuad(-h, b, h, h, b, h, h, t, h, -h, t, h); emitQuad(glass, 34)
        setQuad(-h, b, -h, -h, b, h, -h, t, h, -h, t, -h); emitQuad(glass, 34)
        setQuad(h, b, -h, h, b, h, h, t, h, h, t, -h); emitQuad(glass, 34)

        // 底坑地面（实心）
        setQuad(-h, b, -h, h, b, -h, h, b, h, -h, b, h); emitQuad(Color.parseColor("#16304A"), 255)

        // 顶圈梁（开放，让人能看进去）
        rectLines(h, t, frame)

        // 4 根立柱
        emitLine(-h, b, -h, -h, t, -h, frame)
        emitLine(h, b, -h, h, t, -h, frame)
        emitLine(-h, b, h, -h, t, h, frame)
        emitLine(h, b, h, h, t, h, frame)

        // 每层腰线
        for (i in floors.indices) rectLines(h, slabY(i) + 0.02f, frameSoft)

        // 导轨（轿厢两侧，贯通全高）—— 真实电梯的 T 型导轨
        val railX = carHalf + 0.02f
        val railColor = Color.parseColor("#B9D2E8")
        for (rx in floatArrayOf(-railX, railX)) {
            emitLine(rx, b, -0.05f, rx, t, -0.05f, railColor)
            emitLine(rx, b, 0.05f, rx, t, 0.05f, railColor)
        }
    }

    /** 每层厅门框 + 呼梯面板。 */
    private fun buildLandings(frameSoft: Int) {
        val zf = -shaftHalf + 0.02f
        val halfDoor = carHalf * 0.86f
        val dh = doorH()
        val steel = Color.parseColor("#8FA9C2")
        for (i in floors.indices) {
            val y0 = slabY(i) + 0.06f
            val y1 = y0 + dh
            // 厅门门板（半透明钢，位于门框之后，避免与框线抢排序）
            setQuad(-halfDoor, y0, zf + 0.01f, halfDoor, y0, zf + 0.01f, halfDoor, y1, zf + 0.01f, -halfDoor, y1, zf + 0.01f)
            emitQuad(steel, 58)
            // 门框
            emitLine(-halfDoor, y0, zf, halfDoor, y0, zf, frameSoft)
            emitLine(-halfDoor, y1, zf, halfDoor, y1, zf, frameSoft)
            emitLine(-halfDoor, y0, zf, -halfDoor, y1, zf, frameSoft)
            emitLine(halfDoor, y0, zf, halfDoor, y1, zf, frameSoft)
            // 中缝
            emitLine(0f, y0, zf, 0f, y1, zf, frameSoft)
            // 蹲底坎
            emitLine(-halfDoor, y0, zf, halfDoor, y0, zf, Color.parseColor("#0E2438"))

            // 呼梯面板（层门右侧）
            val px = halfDoor + 0.09f
            box(px, y0 + dh * 0.62f, zf + 0.01f, 0.035f, 0.11f, 0.015f, Color.parseColor("#2A3E52"), 255)
            // 上行按钮（亮）
            box(px, y0 + dh * 0.62f + 0.05f, zf - 0.005f, 0.012f, 0.012f, 0.006f, Color.parseColor("#7CE0A0"), 255)
        }
    }

    /** 楼板做成贴墙的窄环，中间整块是井道空腔。 */
    private fun buildFloors() {
        val h = shaftHalf
        val b = slabBorder
        val top = Color.parseColor("#24405C")
        for (i in floors.indices) {
            val y = slabY(i)
            // 前 / 后 两条
            setQuad(-h, y, h - b, h, y, h - b, h, y, h, -h, y, h); emitQuad(top, 255)
            setQuad(-h, y, -h, h, y, -h, h, y, -h + b, -h, y, -h + b); emitQuad(top, 255)
            // 左 / 右 两条
            setQuad(-h, y, -h + b, -h + b, y, -h + b, -h + b, y, h - b, -h, y, h - b); emitQuad(top, 255)
            setQuad(h - b, y, -h + b, h, y, -h + b, h, y, h - b, h - b, y, h - b); emitQuad(top, 255)
        }
    }

    /** 顶部曳引机 + 曳引轮 + 曳引绳 + 对重。 */
    private fun buildMechanism() {
        val t = shaftTop
        // 机座横梁
        box(0f, t - 0.22f, 0f, 0.55f, 0.09f, 0.34f, Color.parseColor("#7C93A6"), 255)
        // 曳引轮
        box(0f, t - 0.40f, 0f, 0.16f, 0.13f, 0.13f, Color.parseColor("#5E7080"), 255)

        // 对重（在轿厢后方，反向运动）
        val cwX = 0.40f
        val cwZ = shaftHalf - 0.22f
        box(cwX, cwY, cwZ, 0.16f, 0.58f, 0.10f, Color.parseColor("#4A5A66"), 255)
        // 对重块的叠片分缝
        val cwPlate = Color.parseColor("#38454E")
        for (k in 1..3) {
            val py = cwY - 0.58f + k * 0.29f
            emitLine(cwX - 0.16f, py, cwZ - 0.101f, cwX + 0.16f, py, cwZ - 0.101f, cwPlate)
        }

        // 曳引绳：轿厢顶 -> 轮；对重顶 -> 轮
        val rope = Color.argb(190, 175, 196, 214)
        val carTop = carY + carHalfH
        val cwTop = cwY + 0.58f
        val sheaveY = t - 0.46f
        for (dx in floatArrayOf(-0.10f, 0f, 0.10f)) {
            emitLine(dx, carTop, 0f, dx, sheaveY, 0f, rope)
        }
        for (dx in floatArrayOf(-0.05f, 0.05f)) {
            emitLine(cwX + dx, cwTop, cwZ, cwX + dx, sheaveY, cwZ, rope)
        }
    }

    private fun buildCar() {
        val s = carHalf
        val hh = carHalfH
        val cy = carY
        val y0 = cy - hh
        val y1 = cy + hh

        val body = Color.parseColor("#33536F")
        val top = Color.parseColor("#456A8E")
        val bot = Color.parseColor("#1B2E40")
        val dark = Color.parseColor("#22384E")

        // 门一开，**轿内自己会亮起来**：地板/四壁从暗色渐变到亮钢色。
        // （门后看到的是真正的轿厢内部 + 纵深，而不是贴在门口的一块黄板）
        val lit = doorOpen.coerceIn(0f, 1f)
        val botIn = lerpColor(bot, Color.parseColor("#8E93A0"), lit)     // 轿内地板
        val sideIn = lerpColor(body, Color.parseColor("#9FB4C6"), lit)   // 轿内两侧壁
        val backIn = lerpColor(dark, Color.parseColor("#D9D5C8"), lit)   // 轿内后壁（最亮）

        // 顶 / 底 / 左右 / 后
        setQuad(-s, y1, -s, s, y1, -s, s, y1, s, -s, y1, s); emitQuad(top, 255)
        setQuad(-s, y0, -s, s, y0, -s, s, y0, s, -s, y0, s); emitQuad(botIn, 255)
        setQuad(-s, y0, -s, -s, y0, s, -s, y1, s, -s, y1, -s); emitQuad(sideIn, 255)
        setQuad(s, y0, -s, s, y0, s, s, y1, s, s, y1, -s); emitQuad(sideIn, 255)
        setQuad(-s, y0, s, s, y0, s, s, y1, s, -s, y1, s); emitQuad(backIn, 255, 1.10f)

        // 正面（-z）：由互不重叠的水平/垂直分块拼成 → 不需要排序竞争
        val zF = -s
        val doorL = carHalf * 0.92f
        val headerY = y0 + doorH() + 0.12f
        fun front(x0: Float, x1: Float, ya: Float, yb: Float, color: Int) {
            setQuad(x0, ya, zF, x1, ya, zF, x1, yb, zF, x0, yb, zF)
            emitQuad(color, 255)
        }
        val header = Color.parseColor("#24435E")
        val door = Color.parseColor("#86AECF")
        val seam = Color.parseColor("#F0C070")
        // 门开合：两扇门往两边缩，中间那道缝越开越宽 —— 缝里**不糊任何挡板**，
        // 直接透视到轿厢内部（后壁 + 地板 + 扶手），所以“里面那层黄板”没有了。
        val gapHalf = 0.03f + doorOpen * (s * 0.92f - 0.03f)
        front(-s, s, headerY, y1, header)          // 门楣
        front(-s, s, y0, y0 + 0.06f, header)       // 地坎
        front(-s, -gapHalf, y0 + 0.06f, headerY, door)   // 左门
        front(gapHalf, s, y0 + 0.06f, headerY, door)     // 右门
        // 门关着时，中缝里只是一线暖光（开门后这层就消失，露出轿内）
        if (doorOpen < 0.02f) front(-gapHalf, gapHalf, y0 + 0.06f, headerY, seam)
        // 门口内侧两侧的立柱（让门有厚度感）
        emitLine(-doorL, y0 + 0.06f, zF, -doorL, headerY, zF, header)
        emitLine(doorL, y0 + 0.06f, zF, doorL, headerY, zF, header)
        // 门开着时，把两扇门的前沿也描出来 —— 看着才像真的滑开了
        if (doorOpen > 0.02f) {
            emitLine(-gapHalf, y0 + 0.06f, zF, -gapHalf, headerY, zF, header)
            emitLine(gapHalf, y0 + 0.06f, zF, gapHalf, headerY, zF, header)
            // 轿内后壁上的扶手（贴着后壁，只在门开时透过门口露出来）
            val backRailY = y0 + hh * 0.62f
            val backRailZ = s - 0.004f
            emitLine(-s * 0.86f, backRailY, backRailZ, s * 0.86f, backRailY, backRailZ, Color.parseColor("#8A6B33"))
            emitLine(-s * 0.86f, backRailY - 0.05f, backRailZ, s * 0.86f, backRailY - 0.05f, backRailZ, Color.parseColor("#6E5426"))
            // 轿内顶灯的暖光（洒在后壁上方）—— 黄光只有这么一条，不是一整块板
            val lampY = headerY - 0.34f
            val lx0 = -s * 0.58f
            val lx1 = s * 0.58f
            setQuad(lx0 - 0.05f, lampY - 0.20f, s - 0.008f, lx1 + 0.05f, lampY - 0.20f, s - 0.008f, lx1 + 0.05f, lampY + 0.20f, s - 0.008f, lx0 - 0.05f, lampY + 0.20f, s - 0.008f)
            emitQuad(Color.parseColor("#FFDF9A"), 78, 1.20f)
            setQuad(lx0, lampY - 0.055f, s - 0.013f, lx1, lampY - 0.055f, s - 0.013f, lx1, lampY + 0.055f, s - 0.013f, lx0, lampY + 0.055f, s - 0.013f)
            emitQuad(Color.parseColor("#FFF4D2"), 255, 1.30f)
        }

        // 轿壁细节：扶手线 + 踢脚线（略微浮出表面，避免与面共面）
        val trim = Color.parseColor("#28405A")
        val railY = y0 + hh * 1.05f
        val skirtY = y0 + 0.10f
        for (sx in floatArrayOf(-s, s)) {
            val ox = if (sx < 0f) -0.006f else 0.006f
            emitLine(sx + ox, railY, -s, sx + ox, railY, s, trim)
            emitLine(sx + ox, skirtY, -s, sx + ox, skirtY, s, trim)
        }
    }

    // ==================================================================
    // 绘制
    // ==================================================================

    private fun drawFaces(canvas: Canvas) {
        for (i in 0 until fCount) order[i] = i
        for (i in 1 until fCount) {
            val key = order[i]
            val kd = fDepth[key]
            var j = i - 1
            while (j >= 0 && fDepth[order[j]] < kd) {
                order[j + 1] = order[j]; j--
            }
            order[j + 1] = key
        }

        for (i in 0 until fCount) {
            val f = order[i]
            val b = f * 8
            val text = fText[f]
            when {
                text != null -> {
                    labelPaint.color = fColor[f]
                    canvas.drawText(text, fPts[b], fPts[b + 1], labelPaint)
                }
                fLine[f] -> {
                    linePaint.color = fColor[f]
                    canvas.drawLine(fPts[b], fPts[b + 1], fPts[b + 2], fPts[b + 3], linePaint)
                }
                else -> {
                    path.reset()
                    path.moveTo(fPts[b], fPts[b + 1])
                    path.lineTo(fPts[b + 2], fPts[b + 3])
                    path.lineTo(fPts[b + 4], fPts[b + 5])
                    path.lineTo(fPts[b + 6], fPts[b + 7])
                    path.close()
                    fillPaint.color = fColor[f]
                    canvas.drawPath(path, fillPaint)
                }
            }
        }
    }
}
