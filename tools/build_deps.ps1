# Builds the compiled third-party dependencies of CuraEngine for a HarmonyOS ABI.
# Header-only dependencies (range-v3, rapidjson, stb, spdlog, boost headers, wagyu, shims)
# do not need a build step and are consumed straight from their source trees.
#
# Usage: powershell -ExecutionPolicy Bypass -File tools/build_deps.ps1 -Abi arm64-v8a

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('arm64-v8a', 'x86_64')]
    [string]$Abi
)

$ErrorActionPreference = 'Stop'

$sdk = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native'
$cmake = Join-Path $sdk 'build-tools\cmake\bin\cmake.exe'
$ninja = Join-Path $sdk 'build-tools\cmake\bin\ninja.exe'
$cxx = Join-Path $sdk 'llvm\bin\clang++.exe'
$ar = Join-Path $sdk 'llvm\bin\llvm-ar.exe'
$toolchain = Join-Path $sdk 'build\cmake\ohos.toolchain.cmake'
$sysroot = Join-Path $sdk 'sysroot'

$root = Split-Path $PSScriptRoot -Parent
$deps = Join-Path $root 'third_party\deps'
$install = Join-Path $root "third_party\ohos-install\$Abi"
$builds = Join-Path $root "third_party\ohos-build\$Abi"

$triple = if ($Abi -eq 'arm64-v8a') { 'aarch64-linux-ohos' } else { 'x86_64-linux-ohos' }

New-Item -ItemType Directory -Force -Path $install, $builds | Out-Null

function Invoke-CMakeBuild {
    param([string]$Name, [string]$Source, [hashtable]$Options)
    $buildDir = Join-Path $builds $Name
    Write-Host "== configuring $Name ($Abi) =="
    $args = @('-G', 'Ninja', '-S', $Source, '-B', $buildDir,
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
        "-DOHOS_ARCH=$Abi",
        '-DOHOS_STL=c++_shared',
        '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_INSTALL_PREFIX=$install",
        "-DCMAKE_MAKE_PROGRAM=$ninja",
        "-DCMAKE_PREFIX_PATH=$install")
    foreach ($key in $Options.Keys) {
        $args += "-D$key=$($Options[$key])"
    }
    & $cmake @args
    if ($LASTEXITCODE -ne 0) { throw "configure failed for $Name" }
    Write-Host "== building $Name ($Abi) =="
    & $cmake --build $buildDir --target install
    if ($LASTEXITCODE -ne 0) { throw "build failed for $Name" }
}

function Invoke-ClipperBuild {
    $out = Join-Path $install 'lib\libclipper.a'
    if (Test-Path $out) { Write-Host '== clipper already built =='; return }
    Write-Host "== building clipper ($Abi) =="
    $objDir = Join-Path $builds 'clipper'
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    $obj = Join-Path $objDir 'clipper.o'
    & $cxx "--target=$triple" "--sysroot=$sysroot" "-isystem" (Join-Path $sysroot "usr\include\$triple") '-std=c++20' '-O2' '-fPIC' '-DNDEBUG' `
        "-I$(Join-Path $deps 'clipper\include\polyclipping')" '-c' (Join-Path $deps 'clipper\src\clipper.cpp') '-o' $obj
    if ($LASTEXITCODE -ne 0) { throw 'clipper compile failed' }
    New-Item -ItemType Directory -Force -Path (Join-Path $install 'lib'), (Join-Path $install 'include\polyclipping') | Out-Null
    & $ar 'rcs' $out $obj
    if ($LASTEXITCODE -ne 0) { throw 'clipper archive failed' }
    Copy-Item (Join-Path $deps 'clipper\include\polyclipping\clipper.hpp') (Join-Path $install 'include\polyclipping\clipper.hpp') -Force
}

function Invoke-BoostRegexBuild {
    $out = Join-Path $install 'lib\libboost_regex.a'
    if (Test-Path $out) { Write-Host '== boost_regex already built =='; return }
    Write-Host "== building boost_regex ($Abi) =="
    $objDir = Join-Path $builds 'boost_regex'
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    $sources = Get-ChildItem (Join-Path $deps 'boost\libs\regex\src') -Filter '*.cpp'
    $objects = @()
    foreach ($source in $sources) {
        $obj = Join-Path $objDir ($source.BaseName + '.o')
        & $cxx "--target=$triple" "--sysroot=$sysroot" "-isystem" (Join-Path $sysroot "usr\include\$triple") '-std=c++20' '-O2' '-fPIC' '-DNDEBUG' `
            "-I$(Join-Path $deps 'boost')" '-c' $source.FullName '-o' $obj
        if ($LASTEXITCODE -ne 0) { throw "boost_regex compile failed: $($source.Name)" }
        $objects += $obj
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $install 'lib') | Out-Null
    & $ar 'rcs' $out @objects
    if ($LASTEXITCODE -ne 0) { throw 'boost_regex archive failed' }
}

Invoke-ClipperBuild
Invoke-CMakeBuild -Name 'zlib' -Source (Join-Path $deps 'zlib') -Options @{ 'ZLIB_BUILD_EXAMPLES' = 'OFF' }
Invoke-CMakeBuild -Name 'libpng' -Source (Join-Path $deps 'libpng') -Options @{ 'PNG_SHARED' = 'OFF'; 'PNG_TESTS' = 'OFF'; 'PNG_EXECUTABLES' = 'OFF'; 'ZLIB_ROOT' = $install }
Invoke-CMakeBuild -Name 'onetbb' -Source (Join-Path $deps 'onetbb') -Options @{ 'TBB_TEST' = 'OFF'; 'BUILD_SHARED_LIBS' = 'OFF'; 'TBB_STRICT' = 'OFF'; 'TBB_EXAMPLES' = 'OFF' }
Invoke-BoostRegexBuild

Write-Host ''
Write-Host "== installed into $install =="
Get-ChildItem (Join-Path $install 'lib') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
