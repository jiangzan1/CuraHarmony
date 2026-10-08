# 第三方组件与许可 / Third-Party Notices

CuraHarmony 基于以下开源项目构建。完整对应源码的获取方式见文末「对应源码（Corresponding Source）」。

## 主要组件

| 组件 | 版本 | 许可证 |
|---|---|---|
| Cura | upstream | **AGPL-3.0** |
| CuraEngine | 5.14.0-alpha.0 | **AGPL-3.0** |
| fmt | 12.1.0 | MIT（含例外条款） |
| oneTBB | 2022.3.0 | Apache-2.0 |
| clipper（源码取自 pyclipper） | 6.4.2 | Boost Software License 1.0 |
| Boost（含 Boost.Regex） | 1.88.0 | Boost Software License 1.0 |
| zlib | 1.3.1 | zlib License |
| libpng | 1.6.48 | libpng License（zlib 系） |
| range-v3 | 0.12.0 | Boost Software License 1.0 |
| rapidjson | master | MIT |
| stb | master | Public Domain / MIT 双许可 |
| spdlog | 1.17.0 | MIT |
| mapbox wagyu | 0.5.0 | ISC |
| mapbox geometry.hpp | 2.0.3 | ISC |

> 以各上游仓库中的 LICENSE 原文为准。

## 本工程自写的替代实现

Ultimaker 的 `scripta`、`zeus_expected`、`cura-formulae-engine` 仅存在于其私有 Conan 远端，
本工程以等价实现补齐，见 `tools/patches/DEPENDENCIES.md`：

- `third_party/deps/scripta`（no-op 头）
- `third_party/deps/zeus_expected`
- `third_party/deps/cura-formulae-engine`
- `third_party/deps/compat/include/execution`（空头，禁用 PSTL 分支）

这些文件由本工程编写，随本工程按 AGPL-3.0 授权。

## 对应源码（Corresponding Source）

`third_party/` 未纳入版本控制。要重建出与本应用一致的产物，需按 `tools/patches/DEPENDENCIES.md`
获取下列上游源码，并应用本工程的补丁与构建脚本：

### 上游源码
```bash
git clone --depth 1 https://github.com/Ultimaker/Cura.git       third_party/Cura
git clone --depth 1 https://github.com/Ultimaker/CuraEngine.git third_party/CuraEngine
# 依赖（fmt / oneTBB / clipper / boost / zlib / libpng / range-v3 / rapidjson / stb /
#      spdlog / wagyu / geometry.hpp）见 tools/patches/DEPENDENCIES.md
```

### 本工程对上游的修改
- `tools/patches/curaengine-ohos.patch` —— 针对 HarmonyOS NDK 的 CuraEngine 补丁
- `tools/build_deps.ps1` —— 依赖交叉编译脚本（OHOS arm64-v8a）
- `entry/src/main/cpp/` —— NAPI 桥接、原生子进程切片、EGL/OpenGL ES 预览

### 构建
见仓库根 `README.md` 的「构建」章节。

## 商标

“Cura”是 Ultimaker 的商标。本工程与 Ultimaker 无从属关系，亦未获得其背书。
