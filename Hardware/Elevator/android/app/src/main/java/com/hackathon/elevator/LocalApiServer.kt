package com.hackathon.elevator

import android.os.Handler
import android.os.Looper
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.Collections

/**
 * 给“别的 App”用的最小本地 HTTP 接口（跨平台：iOS / Android / 网页都能调）。
 *
 * 用途：队友的室内导航 App 可以用它来让本 App 去做事，例如
 *   GET /api/status                 → 看当前靠近楼层 / 目标楼层 / 各节点信号
 *   GET /api/call?floor=1F&dir=UP   → 让 1F 装置的舵机按下“上行”按钮
 *
 * 设计取舍：
 *   · 零第三方依赖，只用 ServerSocket + 手写极简 HTTP/1.1，几十 KB 也不占。
 *   · 只监听局域网；所有会碰到 BLE/UI 的动作都 **post 回主线程** 再执行。
 *   · 每个请求单独处理，连接用完即关（Connection: close），适合低频控制。
 *   · 带 `Access-Control-Allow-Origin: *`，所以网页里 fetch() 也能直接调。
 *
 * 端口默认 8899；地址形如 http://<手机局域网IP>:8899 。
 */
class LocalApiServer(
    private val port: Int,
    /** 返回 /api/status 的 JSON 文本（由 MainActivity 组装）。 */
    private val statusJson: () -> String,
    /** 支持的楼层列表。 */
    private val floors: () -> List<String>,
    /** 执行一次呼叫；返回 (是否已下发, 说明文字)。 */
    private val call: (floor: String?, dir: String) -> Pair<Boolean, String>,
    /** 设置呼叫目标楼层；返回是否成功。 */
    private val setTarget: (String) -> Boolean,
    private val log: (String) -> Unit
) {

    @Volatile
    private var running = false
    private var serverSocket: ServerSocket? = null
    private var thread: Thread? = null

    private val main = Handler(Looper.getMainLooper())

    val isRunning: Boolean get() = running

    fun start() {
        if (running) return
        running = true
        thread = Thread({ serveLoop() }, "elevator-api").apply {
            isDaemon = true
            start()
        }
        log("HTTP 接口已开启：http://${localIpAddress()}:$port")
    }

    fun stop() {
        running = false
        runCatching { serverSocket?.close() }
        serverSocket = null
        thread = null
    }

    // ------------------------------------------------------------------
    // 接受连接
    // ------------------------------------------------------------------

    private fun serveLoop() {
        val ss = try {
            ServerSocket(port)
        } catch (t: Throwable) {
            log("HTTP 接口启动失败（端口 $port 被占？）：${t.message}")
            running = false
            return
        }
        serverSocket = ss
        while (running) {
            val socket = try {
                ss.accept()
            } catch (t: Throwable) {
                if (running) log("accept 出错：${t.message}")
                break
            }
            try {
                handle(socket)
            } catch (t: Throwable) {
                log("请求处理出错：${t.message}")
            } finally {
                runCatching { socket.close() }
            }
        }
    }

    private fun handle(socket: Socket) {
        socket.soTimeout = 4000
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
        val writer = PrintWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))

        val requestLine = reader.readLine() ?: return
        val parts = requestLine.split(" ")
        if (parts.size < 2) { respond(writer, 400, errorJson("malformed request")); return }
        val method = parts[0].uppercase()
        val target = parts[1]

        // 读掉请求头
        var contentLength = 0
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
            if (line.startsWith("Content-Length:", ignoreCase = true)) {
                contentLength = line.substringAfter(':').trim().toIntOrNull() ?: 0
            }
        }
        var body = ""
        if (contentLength > 0) {
            val buf = CharArray(contentLength)
            var read = 0
            while (read < contentLength) {
                val n = reader.read(buf, read, contentLength - read)
                if (n <= 0) break
                read += n
            }
            body = String(buf, 0, read)
        }

        val q = target.indexOf('?')
        val path = (if (q >= 0) target.substring(0, q) else target).trimEnd('/')
        val params = HashMap<String, String>()
        if (q >= 0) params.putAll(parseQuery(target.substring(q + 1)))
        if (method == "POST" && body.isNotEmpty()) params.putAll(parseQuery(body))

        route(writer, method, path.ifEmpty { "/" }, params)
    }

    private fun route(writer: PrintWriter, method: String, path: String, p: Map<String, String>) {
        when (path) {
            "/", "/api", "/api/ping" ->
                respond(writer, 200, """{"ok":true,"app":"elevator-call","api":1,"port":$port}""")

            "/api/floors" ->
                respond(writer, 200, """{"ok":true,"floors":${jsonArray(floors())}}""")

            "/api/status" ->
                respond(writer, 200, onMain { statusJson() } ?: errorJson("busy"))

            "/api/call" -> {
                val rawDir = p["dir"] ?: p["direction"]
                val dir = normalizeDir(rawDir)
                if (dir == null) {
                    respond(writer, 400, errorJson("dir 必须是 UP 或 DOWN"))
                    return
                }
                val floor = p["floor"]?.takeIf { it.isNotBlank() }
                val res = onMain { call(floor, dir) }
                if (res == null) { respond(writer, 500, errorJson("超时")); return }
                val (ok, msg) = res
                respond(
                    writer, if (ok) 200 else 409,
                    """{"ok":$ok,"floor":${jsonStr(floor ?: "auto")},"dir":${jsonStr(dir)},"message":${jsonStr(msg)}}"""
                )
            }

            "/api/target" -> {
                val floor = p["floor"]
                if (floor.isNullOrBlank()) { respond(writer, 400, errorJson("缺少 floor")); return }
                val ok = onMain { setTarget(floor) } ?: false
                respond(
                    writer, if (ok) 200 else 400,
                    """{"ok":$ok,"target":${jsonStr(floor)}}"""
                )
            }

            else -> respond(writer, 404, errorJson("未知路径 $path"))
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /** 把回调放到主线程执行（会碰 BLE / UI），最多等 4 秒。 */
    private fun <T> onMain(block: () -> T): T? {
        if (Looper.myLooper() == Looper.getMainLooper()) return runCatching { block() }.getOrNull()
        val lock = Object()
        var result: T? = null
        var done = false
        main.post {
            val r = runCatching { block() }.getOrNull()
            synchronized(lock) { result = r; done = true; lock.notifyAll() }
        }
        synchronized(lock) {
            val deadline = System.currentTimeMillis() + 4000
            while (!done && System.currentTimeMillis() < deadline) lock.wait(200)
        }
        return if (done) result else null
    }

    private fun normalizeDir(raw: String?): String? = when (raw?.trim()?.uppercase()) {
        "UP", "上", "上行" -> BleManager.CMD_UP
        "DOWN", "下", "下行" -> BleManager.CMD_DOWN
        else -> null
    }

    private fun parseQuery(query: String): Map<String, String> {
        if (query.isEmpty()) return emptyMap()
        val out = HashMap<String, String>()
        for (kv in query.split('&')) {
            if (kv.isEmpty()) continue
            val i = kv.indexOf('=')
            val k = if (i >= 0) kv.substring(0, i) else kv
            val v = if (i >= 0) kv.substring(i + 1) else ""
            out[URLDecoder.decode(k, "UTF-8")] = URLDecoder.decode(v, "UTF-8")
        }
        return out
    }

    private fun respond(writer: PrintWriter, code: Int, json: String) {
        val bytes = json.toByteArray(Charsets.UTF_8)
        writer.print("HTTP/1.1 $code ${if (code == 200) "OK" else "Error"}\r\n")
        writer.print("Content-Type: application/json; charset=utf-8\r\n")
        writer.print("Access-Control-Allow-Origin: *\r\n")
        writer.print("Access-Control-Allow-Headers: *\r\n")
        writer.print("Cache-Control: no-store\r\n")
        writer.print("Connection: close\r\n")
        writer.print("Content-Length: ${bytes.size}\r\n")
        writer.print("\r\n")
        writer.print(json)
        writer.flush()
    }

    private fun errorJson(msg: String) = """{"ok":false,"error":${jsonStr(msg)}}"""

    companion object {
        /** 默认端口。 */
        const val DEFAULT_PORT = 8899

        fun jsonStr(s: String?): String {
            if (s == null) return "null"
            val sb = StringBuilder("\"")
            for (c in s) {
                when (c) {
                    '\\' -> sb.append("\\\\")
                    '"' -> sb.append("\\\"")
                    '\n' -> sb.append("\\n")
                    '\r' -> sb.append("\\r")
                    '\t' -> sb.append("\\t")
                    else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
                }
            }
            return sb.append('"').toString()
        }

        fun jsonArray(items: List<String>) = items.joinToString(",", "[", "]") { jsonStr(it) }

        /** 手机的局域网 IPv4（用于拼给用户/队友的地址）。 */
        fun localIpAddress(): String {
            return runCatching {
                for (nif in Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!nif.isUp || nif.isLoopback) continue
                    for (addr in Collections.list(nif.inetAddresses)) {
                        if (addr is Inet4Address && !addr.isLoopbackAddress) {
                            val ip = addr.hostAddress ?: continue
                            if (ip.startsWith("169.254.")) continue
                            return@runCatching ip
                        }
                    }
                }
                "127.0.0.1"
            }.getOrDefault("127.0.0.1")
        }
    }
}
