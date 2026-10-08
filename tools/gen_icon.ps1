# Generates the CuraHarmony layered app icon (background + foreground) and the launch icon.
# ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$appMedia = Join-Path $root "AppScope\resources\base\media"
$entryMedia = Join-Path $root "entry\src\main\resources\base\media"
$publish = Join-Path (Split-Path -Parent $root) "publish"

$S = 1024

function New-Canvas([System.Drawing.Color]$c1, [System.Drawing.Color]$c2) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $rect = New-Object System.Drawing.Rectangle(0, 0, $S, $S)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 90.0)
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
    return @($bmp, $g)
}

function New-PolygonPoints($coords) {
    $pts = New-Object System.Drawing.PointF[] ($coords.Count / 2)
    for ($i = 0; $i -lt $coords.Count / 2; $i++) {
        $pts[$i] = New-Object System.Drawing.PointF($coords[$i * 2], $coords[$i * 2 + 1])
    }
    return $pts
}

function Draw-Mark($g) {
    # Build plate shadow under the cube.
    $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 0, 0, 0))
    $g.FillEllipse($shadow, 300, 690, 424, 130)
    $shadow.Dispose()

    # Isometric cube: 3D-printed block with visible layer lines.
    $topFace = New-PolygonPoints @(512, 375, 702, 470, 512, 565, 322, 470)
    $leftFace = New-PolygonPoints @(322, 470, 512, 565, 512, 775, 322, 680)
    $rightFace = New-PolygonPoints @(512, 565, 702, 470, 702, 680, 512, 775)

    $bTop = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $bLeft = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 191, 212, 245))
    $bRight = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 143, 176, 232))
    $g.FillPolygon($bLeft, $leftFace)
    $g.FillPolygon($bRight, $rightFace)
    $g.FillPolygon($bTop, $topFace)
    $bTop.Dispose(); $bLeft.Dispose(); $bRight.Dispose()

    # Print layers on both side faces.
    $layerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 16, 48, 107), 6.0)
    foreach ($t in 0.2, 0.4, 0.6, 0.8) {
        $y = 210 * $t
        $g.DrawLine($layerPen, 322, 470 + $y, 512, 565 + $y)
        $g.DrawLine($layerPen, 512, 565 + $y, 702, 470 + $y)
    }
    $layerPen.Dispose()

    # Nozzle above the block, printing the next layer.
    $bNozzle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 235, 243, 255))
    $g.FillRectangle($bNozzle, 470, 250, 84, 44)
    $tip = New-PolygonPoints @(474, 294, 550, 294, 512, 345)
    $g.FillPolygon($bNozzle, $tip)
    $bNozzle.Dispose()
}

# --- background (opaque) -------------------------------------------------
$bg = New-Canvas ([System.Drawing.Color]::FromArgb(255, 10, 21, 38)) ([System.Drawing.Color]::FromArgb(255, 47, 111, 208))
$bgBmp = $bg[0]; $bgG = $bg[1]
$glow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(26, 255, 255, 255))
$bgG.FillEllipse($glow, 150, 120, 724, 724)
$glow.Dispose()
$bgG.Dispose()
$bgBmp.Save((Join-Path $appMedia "background.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bgBmp.Save((Join-Path $entryMedia "background.png"), [System.Drawing.Imaging.ImageFormat]::Png)

# --- foreground (transparent) -------------------------------------------
$fgBmp = New-Object System.Drawing.Bitmap($S, $S)
$fgG = [System.Drawing.Graphics]::FromImage($fgBmp)
$fgG.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$fgG.Clear([System.Drawing.Color]::Transparent)
Draw-Mark $fgG
$fgG.Dispose()
$fgBmp.Save((Join-Path $appMedia "foreground.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$fgBmp.Save((Join-Path $entryMedia "foreground.png"), [System.Drawing.Imaging.ImageFormat]::Png)

# --- composite (store master 1024 + launch icon 144) --------------------
$comp = New-Object System.Drawing.Bitmap($S, $S)
$cg = [System.Drawing.Graphics]::FromImage($comp)
$cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$cg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$cg.DrawImage($bgBmp, 0, 0, $S, $S)
$cg.DrawImage($fgBmp, 0, 0, $S, $S)
$cg.Dispose()

if (-not (Test-Path -LiteralPath $publish)) { New-Item -ItemType Directory -Path $publish -Force | Out-Null }
$comp.Save((Join-Path $publish "app-icon-1024.png"), [System.Drawing.Imaging.ImageFormat]::Png)

$small = New-Object System.Drawing.Bitmap(144, 144)
$sg = [System.Drawing.Graphics]::FromImage($small)
$sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$sg.DrawImage($comp, 0, 0, 144, 144)
$sg.Dispose()
$small.Save((Join-Path $entryMedia "startIcon.png"), [System.Drawing.Imaging.ImageFormat]::Png)

$comp.Dispose(); $small.Dispose(); $bgBmp.Dispose(); $fgBmp.Dispose()
Write-Host "Icon written: background/foreground (AppScope + entry), startIcon, publish/app-icon-1024.png"
