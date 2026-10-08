# CuraHarmony

把 [UltiMaker Cura](https://github.com/Ultimaker/Cura) 的切片能力移植到 **HarmonyOS（鸿蒙）**：
用 ArkTS/ArkUI 重建 Cura 风格界面，用 **XComponent + OpenGL ES 3.0** 做 3D 预览，把 C++ 的
**CuraEngine** 用鸿蒙 NDK 交叉编译并通过 **NAPI 进程内调用**完成真实切片，并移植 Cura 的
USB 打印行为实现串口打印。

> 目标设备：**2in1（PC）**。`entry/src/main/module.json5` 的 `deviceTypes` 只声明了 `2in1`，
> 应用启动即为沉浸式全屏。

## 当前状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 工程骨架、版本控制、源码克隆、基线构建 | ✅ |
| M1 | CuraEngine 交叉编译（arm64）+ NAPI 桥接 + 真机验证 | ✅ |
| M2 | 端到端真实切片：STL → CuraEngine → G-code | ✅ |
| M3 | XComponent + OpenGL ES 3D 预览（旋转/缩放/平台网格） | ✅ |
| M4 | Cura 风格界面（顶栏/设置侧栏/底栏），参数注入切片 | ✅ |
| M5 | USB 串口打印（端口枚举、握手、`ok` 流控、暂停/取消） | 协议层完成，**待真实打印机验证** |
| M6 | 文档与回归 | ✅ |

已验证（真机 HUAWEI MateBook Pro，HarmonyOS 7.0.0，2in1）：

- 原生桥接连通：`ping`/`getEngineInfo` 正常，`exit()` 拦截生效（引擎异常不会杀掉应用进程）。
- 真实切片：内置立方体 STL → 692 KB / 30280 行 G-code，首行 `;FLAVOR:Marlin`。
- 3D 预览：立方体 + 打印平台网格，手势可绕轨道旋转、双指缩放。
- 界面调参：侧栏 11 项设置通过 `-s key=value` 真实注入 CuraEngine。
- USB 串口 API 可调用（未接打印机时返回空端口列表）。

## 架构

```
ArkTS/ArkUI 表现层
  ├─ pages/Index.ets            顶栏 + 设置侧栏 + 3D 预览 + 状态栏
  ├─ view/PrinterPanel.ets      USB 打印面板
  ├─ view/SettingsPanel.ets     打印设置侧栏（分组）
  └─ service/                   串口客户端 + 打印机状态机
        │
        ├─ 3D 预览：XComponent(SURFACE) ──> librender.so（EGL + GLES3 + STL 解析 + 触摸手势）
        │
        └─ 切片：NAPI ──> 原生子进程（每次切片一个）──> libcuraslicer.so:SliceMain ──> CuraEngine
                                  ↑
                  resources/rawfile/profiles/default.json（Cura 定义树 + overrides）
```

**为什么每次切片起一个子进程**：CuraEngine 的 `Application::run()` 明确「一个进程只能调用一次」
（它对全局静态字段有副作用），同进程内第二次切片会 segfault（实测崩在 `OS_FFRT_*` 工作线程）。
鸿蒙的 `OH_Ability_StartNativeChildProcess` 让每次切片跑在全新进程里，静态状态天然复位——
这也正好对齐桌面版 Cura「子进程调用 CuraEngine」的模型。切片请求用行式负载经 `entryParams`
传入，子进程把结果写入 `<输出>.status`（`code=<n>` + 引擎最后一条日志），父进程轮询读取。
若设备不支持原生子进程（返回 801），会退化为进程内切片（每次启动可用一次）。

## 目录结构

```
CuraHarmony/
├── AppScope/                        应用级配置
├── entry/
│   ├── build-profile.json5          externalNativeOptions（CMake 路径 + abiFilters）
│   └── src/main/
│       ├── module.json5             仅 2in1
│       ├── ets/
│       │   ├── entryability/        UIAbility：沉浸式全屏 + 最大化
│       │   ├── pages/Index.ets      主界面
│       │   ├── model/               设置模型
│       │   ├── view/                组件（设置行/设置面板/打印机面板）
│       │   └── service/             UsbSerialClient / UsbPrinterService
│       ├── cpp/
│       │   ├── CMakeLists.txt       CuraEngine + 依赖 + NAPI + 渲染
│       │   ├── napi_init.cpp        NAPI：ping/getEngineInfo/slice(async)
│       │   ├── slicer_bridge.*      CuraEngine 进程内桥接 + exit() 拦截 + 日志镜像
│       │   └── render/              OpenGL ES 预览（XComponent）
│       └── resources/rawfile/
│           ├── profiles/default.json  生成的切片配置
│           └── models/cube.stl        内置测试模型
├── third_party/                     （已 gitignore）外部源码与交叉编译产物
│   ├── Cura/  CuraEngine/           上游源码
│   ├── deps/                        依赖源码 + 开源替代 shim
│   └── ohos-install/<abi>/          交叉编译产物
└── tools/
    ├── build_deps.ps1               交叉编译 clipper/tbb/png/z/fmt/boost_regex
    ├── gen_profiles.py              从 Cura 定义生成切片配置
    ├── gen_cube_stl.py              生成测试立方体
    ├── formulae_selftest.cpp        开源替代 shim 的自测
    └── patches/                     CuraEngine 补丁 + 依赖清单说明
```

## 构建

### 前置条件

- DevEco Studio（自带 OpenHarmony SDK / NDK / CMake / Ninja），设置好 `DEVECO_HOME`
- Python 3（生成配置与测试模型）
- 已登录的 DevEco 账号（用于 `devecocli signature generate` 签名）
- 一台开启 USB 调试的 2in1 设备

### 步骤

```powershell
# 0) 获取上游源码（third_party 未纳入版本控制，需要自行克隆）
git clone --depth 1 https://github.com/Ultimaker/Cura.git       third_party/Cura
git clone --depth 1 https://github.com/Ultimaker/CuraEngine.git third_party/CuraEngine

# 1) 克隆依赖源码（range-v3 / rapidjson / stb / spdlog / fmt / onetbb / wagyu /
#    mapbox-geometry / clipper / boost / zlib / libpng），见 tools/patches/DEPENDENCIES.md

# 2) 交叉编译依赖到 third_party/ohos-install/arm64-v8a
powershell -ExecutionPolicy Bypass -File tools/build_deps.ps1 -Abi arm64-v8a

# 3) 生成切片配置与测试模型（写入 rawfile）
python tools/gen_profiles.py
python tools/gen_cube_stl.py

# 4) 应用 CuraEngine 补丁（若 third_party/CuraEngine 是新克隆的）
git -C third_party/CuraEngine apply ../../tools/patches/curaengine-ohos.patch

# 5) 签名并运行
devecocli signature generate --product default
devecocli run --device <serial>
```

## 三个 Ultimaker 私有包的开源替代

CuraEngine 依赖 `scripta`、`cura-formulae-engine`、`zeus_expected`，它们只发布在 Ultimaker
私有 Conan 远端（`ultimaker/testing`），公开 GitHub 上不存在。`third_party/deps/` 下用等价实现补齐：

| 包 | 替代方案 |
|---|---|
| `scripta` | 仅被 `#include <scripta/logger.h>` 使用，是调试可视化钩子 → 头文件 no-op shim |
| `zeus_expected` | 只用到 `expected<T,E>` 的 `has_value/value/error` → 自写极简实现 |
| `cura-formulae-engine` | G-code 模板与设置表达式求值 → 自写迷你表达式引擎（数字/字符串/布尔/变量/算术/比较/逻辑/三元/函数/列表与下标） |

解析失败会返回错误，CuraEngine 随即回退为按原文处理，因此不支持的表达式不会破坏切片。

## 已知限制与踩坑

1. **许可：Cura 与 CuraEngine 均为 AGPL-3.0**。对外分发本应用会触发 AGPL 的开源义务
   （需公开修改与链接其代码的应用）。商用前务必确认合规。
2. **CuraEngine 一个进程只能 run 一次**：已通过「每次切片起原生子进程」解决（见架构一节）。
   若设备不支持子进程而退化为进程内切片，则同一次启动只能切一次。
3. **`exit()` 拦截是 thread-local**：CuraEngine 约 27 处 `exit()`（缺参数/缺设置）会被拦截并
   优雅失败；但若在 TBB 工作线程上触发，会走 `_Exit()` 直接结束进程。因此正解是**保证设置完整**
   而不是依赖拦截。
3. **设置文件必须完整**：`-j` 采用的是 Cura「定义树 + overrides」格式（不是扁平键值），
   且需要 `--force-read-parent`，否则像 `roofing_layer_count` 这类「既是设置又是父节点」的
   条目会被跳过，导致 `Trying to retrieve setting with no value given`。
4. **NDK libc++ 无 `<execution>`**：CuraEngine 的 `std::execution::par` 都在
   `#ifdef __cpp_lib_execution` 内，提供一个空的 `<execution>` 头即自动退化为串行。
5. **Clang 15 未实现 C++20 带括号聚合初始化（P0960）**：`emplace_back(a,b)` 对聚合体失败，
   已对 `SpeedRegion`/`OverrideArea`/`BridgeLocation` 补最小构造函数（见 patch）。
6. **沙箱路径含模块段**：真实 `filesDir` 是 `/data/storage/el2/base/haps/entry/files`，
   渲染库按已知布局探测该目录。
7. **XComponent 的 EGL 上下文跨线程**：上下文在回调（UI）线程创建、却在渲染线程使用，
   必须先 `eglMakeCurrent(NO_SURFACE,NO_SURFACE,NO_CONTEXT)` 释放；首次视口尺寸需在
   `OnSurfaceCreated` 用 `GetXComponentSize` 兜底。
8. **只保留 arm64-v8a**：若需要用 PC 模拟器（x86_64）验证，需把 `abiFilters` 加回 `x86_64`
   并为该 ABI 重新执行 `build_deps.ps1`；全量构建时间会翻倍。
9. **M5 未做硬件验证**：USB 打印协议已实现，但握手/温度/打印全流程需要用真实打印机验证。
10. **界面为 MVP 子集**：只暴露 11 项设置，未实现 Cura 的完整设置继承/依赖解析与插件系统。

## 日志与诊断

- 引擎日志镜像到沙箱 `curaengine.log`，渲染日志写入 `render.log`；失败时会读取尾部显示。
- 崩溃排查：`devecocli log --crash --bundle-name com.example.curaharmony`
- 应用内状态栏显示引擎版本，便于确认原生库是否加载成功。

## 许可与合规

本工程链接并分发 **UltiMaker Cura / CuraEngine（AGPL-3.0）**，因此整体以 **AGPL-3.0** 授权，
许可证全文见仓库根 `LICENSE`。

对外分发（包括上架应用市场）时，依据 AGPL-3.0 第 6 节须提供**对应源码（Corresponding Source）**：

- 本工程源码：本仓库全部内容；
- 上游源码与版本、本工程的补丁与交叉编译脚本：见 `THIRD_PARTY_NOTICES.md` 与
  `tools/patches/DEPENDENCIES.md`；
- 应用内「关于」页面展示了源码获取地址（`entry/src/main/ets/model/AppInfo.ets` 的 `SOURCE_URL`）。

另请留意：“Cura”为 Ultimaker 的商标，对外发布前请确认名称与商标使用是否符合要求。

