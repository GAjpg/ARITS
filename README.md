# LiDARProbe

校园室内外导航 iOS App 与 Mac 本地地图工作台的当前源码快照。

## 目录

- `App/`：iOS App、室内外导航、建图与补采、门牌和 BLE 呼梯适配。
- `Sources/ProbeCore/`：共享定位、空间路线、文件与校园绑定模型。
- `Tests/`：Swift 核心测试。
- `Assets/Outdoor/campus.json`：OpenStreetMap 校园底图。
- `Viewer/`：本地点云查看、通行空间校准和校园地图编辑。
- `Tools/`：构建、回放、验证及共享 Swift 空间路线工具。

## iOS

使用完整 Xcode 打开 `LiDARProbe.xcodeproj`，选择 `LiDARProbe` scheme。最低 iOS 17，室内深度功能需要支持 sceneDepth 的 LiDAR 设备；真机运行请配置自己的签名团队。源码副本已清空原开发团队设置。

```bash
swift test -c release
bash Tools/build_unsigned.sh
bash Tools/build_space_route.sh
```

## Mac 本地工作台

建议 Python 3.12。首次安装依赖需要联网。

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-snapshot.txt
.venv/bin/python Viewer/server.py --no-browser
```

按终端显示地址访问 `/`（点云）、`/space`（通行空间）、`/outdoor`（校园地图）。空间预览使用共享 Swift CLI，需要 Xcode 命令行工具。

```bash
.venv/bin/python -m unittest discover -s Tools -p 'test_*.py'
.venv/bin/python -m unittest discover -s Viewer -p 'test_*.py'
```

## 版本范围

本仓库只有 2026-10-18 导出的当前工作版本，不包含开发仓库的提交历史、分支和标签。保留了当前 App 构建需要的工作区源码。已从这份源码副本验证：Swift 299 项、Python 工具 31 项、Viewer 35 项通过，iOS 未签名构建通过；这些检查不是现场定位准确率证明。

不包含参赛说明文档审核稿、旧 APK、反编译文件、现场扫描与照片日志、构建缓存、虚拟环境及签名材料。室内地图和电梯装置需另行采集或配置。此快照不包含独立安卓工程或 ESP32 固件。

第三方来源与许可见 `THIRD_PARTY_NOTICES.md`。本队自研代码的对外发布许可尚未指定，第三方许可不受影响。
