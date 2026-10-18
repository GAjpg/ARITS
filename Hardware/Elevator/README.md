# 最终代码 · 固件 + App（给代码库）

> **版本**：App = **v12**（`电梯呼叫_v12.apk`）· 固件 = **v8**
> **部署**：井道 **B / 1F / 2F / 3F**；呼梯装置装在 **1F、2F**；两块板的广播名 = **`ELEV-1F` / `ELEV-2F`**。

---

## 1. 目录

```
android/            安卓 App 源码工程（Android Studio / gradle 直接打开）
firmware/           ESP32 固件源码
  elevator_1F/elevator_1F.ino    1F 板
  elevator_2F/elevator_2F.ino    2F 板
  chime_node/chime_node.ino      可选的"到站叮声"节点（不装也能完整演示）
```

两块板**只有 `FLOOR_NAME` 一行不同**；舵机引脚 **D13 = 上行、D12 = 下行**。

---

## 2. App 关键文件（`android/app/src/main/java/com/hackathon/elevator/`）

| 文件 | 作用 |
|---|---|
| `MainActivity.kt` | 主界面、扫描/连接、悬浮呼梯按钮 |
| `BleManager.kt` | BLE 扫描与 GATT 连接（广播名前缀 `ELEV-`） |
| `FloorJudge.kt` | RSSI 判层（中位数 + EMA + 滞回 + 连胜防抖） |
| `ElevatorView.kt` | 真 3D 井道（甲/乙两台轿厢） |
| `CarFloorSource.kt` | "轿厢在哪层"的来源（画面/摄像头/手动，可切换） |
| `LocalApiServer.kt` | 对外最小 HTTP 接口（给队友的 App 调） |
| `CameraFloorActivity.kt` | 摄像头读楼层显示（原型/备用） |
| `NavMockActivity.kt` | 导航 App 效果模拟页 |

## 3. 固件关键点

- 广播名：`ELEV-` + `FLOOR_NAME` → `ELEV-1F` / `ELEV-2F`
- 舵机：松开 70° → 按下 130°（约 60° 行程）；行程 350 ms + 保持 600 ms + 收回 350 ms
- 服务/特征：`FFE0` / `FFE1`（命令）/ `FFE2`（状态 notify）
- 命令：写 `UP` / `DOWN`；回执形如 `1F|OK:UP`
- **只有人主动点按才会呼梯**，没有任何定时器自动呼梯

## 4. 编译

```bash
# App
cd android
gradle assembleDebug        # 产物 app/build/outputs/apk/debug/app-debug.apk

# 固件：Arduino IDE 打开对应 .ino
#   开发板 ESP32 Dev Module，分区 Huge APP
```

## 5. 说明

- 本包**只含源码**。已编译的 **APK** 在 `安卓App_v12.zip`，固件预编译 **bin** 在 `烧录程序_v8.zip`。
- 已排除构建产物（`build/`、`.gradle/`）与本机路径文件（`local.properties`）。
- 技术文档见仓库根目录：`BLE_PROTOCOL.md` / `NAV_APP_UI_SPEC.md` / `SHAFT_MODEL.md` / `API.md` / `HANDOVER.md` / `REPORT.md`。
