# Draws the app's battery icon and saves it as a multi-size .ico file.
# Run once (or after changing the design): powershell -ExecutionPolicy Bypass -File make-icon.ps1
param([string]$OutFile = (Join-Path $PSScriptRoot 'battery.ico'))

Add-Type -AssemblyName System.Drawing

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconPng([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $u = $s / 16.0                                   # design grid: 16 x 16
    $stroke = [math]::Max(1.0, 1.25 * $u)
    $bodyX = 0.75 * $u; $bodyY = 3.5 * $u; $bodyW = 12.5 * $u; $bodyH = 9 * $u
    $dark = [System.Drawing.Color]::FromArgb(255, 32, 41, 52)
    $green = [System.Drawing.Color]::FromArgb(255, 12, 163, 12)

    # Outline and terminal nub
    $body = New-RoundedRect $bodyX $bodyY $bodyW $bodyH (1.6 * $u)
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), $body)
    $g.DrawPath((New-Object System.Drawing.Pen($dark, $stroke)), $body)
    $nub = New-RoundedRect (13.6 * $u) (6.25 * $u) (1.7 * $u) (3.5 * $u) (0.6 * $u)
    $g.FillPath((New-Object System.Drawing.SolidBrush($dark)), $nub)

    # Green charge level
    $pad = $stroke / 2 + 1.0 * $u
    $fill = New-RoundedRect ($bodyX + $pad) ($bodyY + $pad) (($bodyW - 2 * $pad) * 0.78) ($bodyH - 2 * $pad) (0.7 * $u)
    $g.FillPath((New-Object System.Drawing.SolidBrush($green)), $fill)

    # White tick on larger sizes
    if ($s -ge 32) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, (1.3 * $u))
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $pts = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF((3.6 * $u), (8.1 * $u))),
            (New-Object System.Drawing.PointF((5.5 * $u), (10.0 * $u))),
            (New-Object System.Drawing.PointF((9.2 * $u), (6.2 * $u))))
        $g.DrawLines($pen, $pts)
    }
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    if ($s -ge 256) {
        # Large size: PNG-compressed entry (standard for 256px icons)
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    } else {
        # Smaller sizes: classic 32-bit bitmap entry, readable by every Windows tool
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([uint32]40); $bw.Write([int32]$s); $bw.Write([int32]($s * 2))
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
        $maskStride = [int]([math]::Ceiling($s / 32.0) * 4)
        $bw.Write([uint32]($s * $s * 4 + $maskStride * $s))
        $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
        for ($y = $s - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $s; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
            }
        }
        $bw.Write((New-Object byte[] ($maskStride * $s)))   # AND mask unused with 32-bit alpha
        $bw.Flush()
    }
    $bmp.Dispose()
    return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$images = foreach ($s in $sizes) { , (New-IconPng $s) }

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $images[$i].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$len); $w.Write([uint32]$offset)
    $offset += $len
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
Write-Host "Saved $OutFile"
