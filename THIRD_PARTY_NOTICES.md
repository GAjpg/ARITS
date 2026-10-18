# Third Party Notices

## Included browser library

three.js 0.180.0 and OrbitControls, MIT license. Source: https://github.com/mrdoob/three.js/tree/r180 . The original license is retained at `Viewer/web/vendor/THREE-LICENSE.txt` and source headers remain intact.

## Campus data

`Assets/Outdoor/campus.json` is derived from OpenStreetMap and processed by the project team. Its metadata identifies `OpenStreetMap contributors (ODbL 1.0)`.

© OpenStreetMap contributors. Data license: Open Database License 1.0 (ODbL). Attribution and data license remain applicable to distribution and derivatives.

- Source and attribution: https://www.openstreetmap.org/copyright
- License: https://opendatacommons.org/licenses/odbl/1-0/

## Python dependencies

The direct dependency versions used during validation are in `requirements-snapshot.txt` and `DEPENDENCIES.json`. Package binaries are installed separately and are not bundled in this repository.

| Dependency | Purpose | Upstream and license |
| --- | --- | --- |
| Flask | Local workbench server | https://github.com/pallets/flask — BSD-3-Clause |
| NumPy | Point cloud and depth arrays | https://github.com/numpy/numpy — BSD-3-Clause and included component notices |
| Open3D | Desktop FPFH/RANSAC/ICP diagnostic tools | https://github.com/isl-org/Open3D — MIT |
| Pillow | Image processing and test fixtures | https://github.com/python-pillow/Pillow — MIT-CMU |
| SciPy | Desktop nearest-neighbor diagnostics | https://github.com/scipy/scipy — BSD-3-Clause |
| Matplotlib | Offline plots | https://matplotlib.org/stable/project/license.html — Matplotlib license and included component notices |

Original license texts from the validated direct dependency distributions are retained in `THIRD_PARTY_LICENSES/`. Transitive dependencies are installed by the package manager and keep their own notices. Open3D is used by desktop diagnostics, not the Swift phone localizer.

## Apple APIs

The App uses Apple SDK APIs including ARKit, Vision, CoreLocation, CoreMotion, CoreBluetooth, UIKit, RealityKit, SceneKit, CryptoKit and image/media support frameworks. SDK binaries are not redistributed in this source snapshot. Apple software license information: https://www.apple.com/legal/sla/ . OCR uses the system Vision API; no external trained model weights are bundled.

## Team contributions

Outdoor Android reference code, campus data processing and elevator device/protocol work were supplied by project team members. This repository contains the current iOS integration and local workbench; it does not include a historical Android APK, decompiled project, or separate device firmware. Development used Codex and Claude as programming and review aids.

No blanket open-source license has been assigned here to the team's own source. This notice does not replace or override third-party rights and licenses.
