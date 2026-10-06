# CuraEngine 依赖清单（HarmonyOS 交叉编译）

CuraEngine 5.14.0-alpha.0 的依赖原本由 Conan 管理，但本机没有 Conan，且 Conan Center 的
配方不支持 `os=OHOS`，因此这些依赖全部从上游源码手工 vendor（见 `tools/build_deps.ps1`）。

## 需要编译的依赖

| 依赖 | 版本 / 标签 | 获取方式 | 产物 |
|---|---|---|---|
| fmt | `12.1.0` | `git clone --branch 12.1.0 https://github.com/fmtlib/fmt` | `libfmt.a` |
| oneTBB | `v2022.3.0` | `git clone --branch v2022.3.0 https://github.com/uxlfoundation/oneTBB` | `libtbb.a` |
| clipper | `6.4.2` | 上游为 SourceForge zip（已失效）；改用内置 6.4.2 源码的 `pyclipper`：`src/clipper.{hpp,cpp}` 放到 `include/polyclipping/` + `src/` | `libclipper.a` |
| Boost.Regex | `1.88.0` | `https://archives.boost.io/release/1.88.0/source/boost_1_88_0.zip`，只解压 `boost/` 与 `libs/regex/` | `libboost_regex.a` |
| zlib | `v1.3.1` | `git clone --branch v1.3.1 https://github.com/madler/zlib` | `libz.a` |
| libpng | `v1.6.48` | `git clone --branch v1.6.48 https://github.com/pnggroup/libpng` | `libpng.a` |

## 头文件库（无需编译，直接引用源码目录）

| 依赖 | 版本 / 标签 | 仓库 |
|---|---|---|
| range-v3 | `0.12.0` | `https://github.com/ericniebler/range-v3` |
| rapidjson | master | `https://github.com/Tencent/rapidjson` |
| stb | master | `https://github.com/nothings/stb` |
| spdlog | `v1.17.0` | `https://github.com/gabime/spdlog`（header-only 模式） |
| Boost（头文件） | `1.88.0` | 同上 Boost 归档的 `boost/` |
| mapbox wagyu | `0.5.0` | `https://github.com/mapbox/wagyu`（header-only） |
| mapbox geometry | `v2.0.3` | `https://codeload.github.com/mapbox/geometry.hpp/tar.gz/refs/tags/v2.0.3`（wagyu 的必需依赖） |

## 开源替代（补齐 Ultimaker 私有包）

这三个包只存在于 Ultimaker 私有 Conan 远端（`ultimaker/testing`），公开不可得：

| 包 | 替代实现位置 |
|---|---|
| `scripta` | `third_party/deps/scripta/include/scripta/logger.h`（no-op） |
| `zeus_expected` | `third_party/deps/zeus_expected/include/zeus/expected.hpp` |
| `cura-formulae-engine` | `third_party/deps/cura-formulae-engine/include/cura-formulae-engine/` |
| `<execution>`（libc++ 缺失） | `third_party/deps/compat/include/execution`（空头，禁用 PSTL 分支） |

## 目录约定

```
third_party/deps/<name>/            依赖源码（git clone 或解压）
third_party/ohos-install/<abi>/     交叉编译产物（include/ 与 lib/）
third_party/ohos-build/<abi>/       各依赖的 CMake 构建树
```

## 备注

- 磁盘占用较大（Boost 归档 241 MB；仅解压所需子集）。
- 交叉编译统一使用 NDK 自带工具链：`<sdk>/native/build/cmake/ohos.toolchain.cmake`，
  `OHOS_ARCH=arm64-v8a`、`OHOS_STL=c++_shared`。
- 若网络不稳定，`git clone` 可能失败（HTTP 可达但 git 协议被阻断时，改用 codeload tarball）。
