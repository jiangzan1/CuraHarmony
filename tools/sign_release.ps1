# 生成 AGC 发布包（release-signed App Pack，.app）。
#
# 背景：hvigor 的 build-profile.json5 里 storePassword/keyPassword 需要 DevEco 加密后的十六进制
# （校验：长度 >= 32 且为偶数），命令行无法直接使用明文密码。因此流程改为：
#   1) hvigor 执行 assembleApp，产出“未签名”的 .app；
#   2) 用官方 hap-sign-tool 以发布证书 + 明文密码对该未签名包重新签名。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools/sign_release.ps1
#   powershell -ExecutionPolicy Bypass -File tools/sign_release.ps1 -KeystorePwd <你的密码>

param(
    [string]$KeystorePwd = "12345678i",
    [string]$KeyAlias = "curaharmony",
    [string]$Version = "1.0.0",
    [string]$OutDir = "E:\Users\jiangzan\cura\证书",
    # 正式版 DevEco 安装目录。默认锁定 C:\DevEco Studio（release SDK）；
    # 不要沿用环境变量 DEVECO_HOME，它可能被安装器指向 beta 版。
    [string]$DevEcoHome = "C:\DevEco Studio"
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
# hvigor locates the SDK through DEVECO_SDK_HOME, not DEVECO_HOME, so both must point at the release
# install or the package carries beta APIs and the store rejects it ("应用使用了HarmonyOS beta版本的API").
$devecoHome = $DevEcoHome
$devecoSdk = Join-Path $devecoHome "sdk"
$env:DEVECO_HOME = $devecoHome
$env:DEVECO_SDK_HOME = $devecoSdk

$node = Join-Path $devecoHome "tools\node\node.exe"
$hvigor = Join-Path $devecoHome "tools\hvigor\bin\hvigorw.js"
$java = Join-Path $devecoHome "jbr\bin\java.exe"
$signTool = Join-Path $devecoSdk "default\openharmony\toolchains\lib\hap-sign-tool.jar"

$certFile = Join-Path $OutDir "cura harmony.cer"
$profileFile = Join-Path $OutDir "cura harmonyRelease.p7b"
$keystoreFile = Join-Path $OutDir "curaharmony.p12"

$unsignedApp = Join-Path $projectRoot "build\outputs\default\CuraHarmony-default-unsigned.app"
$outApp = Join-Path $OutDir "CuraHarmony-$Version-release.app"

foreach ($p in @($node, $hvigor, $java, $signTool, $certFile, $profileFile, $keystoreFile)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少文件: $p" }
}

$sdkPkg = Join-Path $devecoSdk "default\sdk-pkg.json"
if (Test-Path -LiteralPath $sdkPkg) {
    $sdkMeta = Get-Content -Raw -LiteralPath $sdkPkg | ConvertFrom-Json
    Write-Host ("DevEco: {0}" -f $devecoHome)
    Write-Host ("SDK:    {0} {1} ({2})" -f $sdkMeta.data.displayName, $sdkMeta.data.version, $sdkMeta.data.releaseType)
    if ($sdkMeta.data.releaseType -ne "Release") {
        throw "当前 SDK 不是 Release 版（$($sdkMeta.data.releaseType)），打出的包会被应用市场拒收。请改用正式版 DevEco Studio。"
    }
}

Write-Host "1/2 执行 assembleApp（产出未签名 .app）..."
Push-Location $projectRoot
try {
    & $node $hvigor assembleApp --mode project -p product=default -p buildMode=release --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "assembleApp 失败" }
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $unsignedApp)) { throw "未找到未签名包: $unsignedApp" }

Write-Host "2/2 使用发布证书签名..."
& $java -jar $signTool sign-app `
    -mode localSign `
    -keyAlias $KeyAlias `
    -keyPwd $KeystorePwd `
    -appCertFile $certFile `
    -profileFile $profileFile `
    -inFile $unsignedApp `
    -signAlg SHA256withECDSA `
    -keystoreFile $keystoreFile `
    -keystorePwd $KeystorePwd `
    -outFile $outApp
if ($LASTEXITCODE -ne 0) { throw "签名失败" }

Write-Host "发布包已生成: $outApp"
