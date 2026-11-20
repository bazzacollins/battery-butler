#requires -Version 5.1
<#
.SYNOPSIS
    Battery Butler - runs the Windows battery report and explains it in plain English.

.DESCRIPTION
    Runs "powercfg /batteryreport", reads the results and creates an easy-to-read web page
    that explains how healthy the battery is, how it has been used, how long it lasts and
    how to look after it. The page opens in your web browser when it is ready.

.PARAMETER XmlPath
    Optional. Explain an existing XML battery report (made with "powercfg /batteryreport /xml")
    instead of creating a new one - for example a report copied from another laptop.

.PARAMETER OutputFolder
    Where to save the summary. Default: Documents\Battery Butler Reports

.PARAMETER NoOpen
    Do not open the summary in the browser when finished.
#>
[CmdletBinding()]
param(
    [string]$XmlPath,
    [string]$OutputFolder,
    [switch]$NoOpen,
    [switch]$Interactive   # used by the Start menu shortcut: keeps the window open long enough to read
)

$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

# =====================================================================================
#  Small helpers
# =====================================================================================

function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }
function N([double]$v) { $v.ToString('0.##', $Inv) }   # numbers inside SVG must use "." decimals

function Get-Child($node, [string]$name) {
    if ($null -eq $node) { return $null }
    foreach ($c in $node.ChildNodes) {
        if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $name) { return $c }
    }
    return $null
}

function Get-Children($node, [string]$name) {
    $list = New-Object System.Collections.ArrayList
    if ($null -ne $node) {
        foreach ($c in $node.ChildNodes) {
            if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $name) { [void]$list.Add($c) }
        }
    }
    return , $list
}

function Get-Text($node, [string]$name) {
    $c = Get-Child $node $name
    if ($null -ne $c) { return $c.InnerText.Trim() }
    return ''
}

function Attr($el, [string]$name) {
    if ($null -eq $el) { return '' }
    return $el.GetAttribute($name)
}

function To-Num([string]$s) {
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
    return 0.0
}

function To-Date([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($s, $Inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    return $null
}

function To-Hours([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0.0 }
    try { return ([System.Xml.XmlConvert]::ToTimeSpan($s)).TotalHours } catch { return 0.0 }
}

function Plural([int]$n, [string]$word) { if ($n -eq 1) { "1 $word" } else { "$n ${word}s" } }

# "6 hours 15 minutes" style
function Fmt-Dur([double]$hours) {
    if ($hours -lt (1 / 60)) { return 'less than a minute' }
    $t = [TimeSpan]::FromHours($hours)
    $d = [int][math]::Floor($t.TotalDays)
    if ($d -ge 1) {
        $s = Plural $d 'day'
        if ($t.Hours -gt 0) { $s += ' ' + (Plural $t.Hours 'hour') }
        return $s
    }
    if ($t.Hours -ge 1) {
        $s = Plural $t.Hours 'hour'
        if ($t.Minutes -gt 0) { $s += ' ' + (Plural $t.Minutes 'minute') }
        return $s
    }
    return Plural ([math]::Max(1, $t.Minutes)) 'minute'
}

# "6h 15m" style
function Fmt-Short([double]$hours) {
    if ($hours -le 0) { return '0m' }
    $t = [TimeSpan]::FromHours($hours)
    $d = [int][math]::Floor($t.TotalDays)
    if ($d -ge 1) { return ('{0}d {1}h' -f $d, $t.Hours) }
    if ($t.Hours -ge 1) { return ('{0}h {1}m' -f $t.Hours, $t.Minutes) }
    return ('{0}m' -f [math]::Max(1, $t.Minutes))
}

function Fmt-Wh([double]$mWh) { '{0:N1} Wh' -f ($mWh / 1000) }
function Fmt-Pct([double]$p) { '{0:N0}%' -f $p }
function Fmt-When([datetime]$d) { $d.ToString('ddd d MMM, HH:mm') }
function Fmt-Day([datetime]$d) { $d.ToString('d MMM yyyy') }

function Get-NiceMax([double]$v) {
    if ($v -le 0) { return 1 }
    $exp = [math]::Pow(10, [math]::Floor([math]::Log10($v)))
    foreach ($m in 1, 2, 2.5, 5, 10) { if ($m * $exp -ge $v) { return $m * $exp } }
    return 10 * $exp
}

function Get-Kind([string]$type) {
    switch -regex ($type) {
        '^Active'                         { return 'use' }
        'Standby|Suspend|Sleep|Hibernat'  { return 'sleep' }
        default                           { return 'other' }
    }
}

function Get-StateName([string]$type) {
    switch -regex ($type) {
        '^Active'          { return 'In use' }
        'ConnectedStandby' { return 'Asleep (modern standby)' }
        'Suspend|Sleep'    { return 'Asleep' }
        'Hibernat'         { return 'Hibernating' }
        'ReportGenerated'  { return 'This report was run' }
        'BatteryChanged'   { return 'Battery was changed' }
        default            { if ($type) { return $type } else { return 'Unknown' } }
    }
}

# Status "pill": icon + label, never colour alone
function Pill([string]$tone, [string]$label) {
    $icon = switch ($tone) { 'good' { '&#10003;' } 'info' { 'i' } 'warn' { '!' } 'alert' { '!!' } default { 'i' } }
    "<span class='pill pill-$tone'><span class='pill-ico' aria-hidden='true'>$icon</span>$(Enc $label)</span>"
}

# =====================================================================================
#  Charts (inline SVG, hover tooltips handled by the script at the bottom of the page)
# =====================================================================================

function Get-TopRoundedPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $r = [math]::Min($r, [math]::Min($w / 2, $h))
    "M$(N $x),$(N ($y + $h)) L$(N $x),$(N ($y + $r)) Q$(N $x),$(N $y) $(N ($x + $r)),$(N $y) " +
    "L$(N ($x + $w - $r)),$(N $y) Q$(N ($x + $w)),$(N $y) $(N ($x + $w)),$(N ($y + $r)) L$(N ($x + $w)),$(N ($y + $h)) Z"
}

function New-LineChart {
    param(
        [object[]]$Points,            # objects with Date, Value, Tip
        [double]$YLo, [double]$YHi, [double]$YStep,
        [string]$YSuffix = '%',
        [object[]]$RefLines = @(),    # objects with Value, Label
        [object[]]$Bands = @(),       # objects with Start, End (shaded periods)
        [string]$DateFormat = 'MMM yyyy',
        [string]$LastLabel = '',
        [string]$Aria = 'Chart',
        [switch]$DayTicks             # label each midnight instead of 5 evenly spaced ticks
    )
    $W = 680; $H = 260; $L = 46; $R = 18; $T = 18; $B = 34
    $pw = $W - $L - $R; $ph = $H - $T - $B
    $x0 = $Points[0].Date; $x1 = $Points[$Points.Count - 1].Date
    $span = ($x1 - $x0).TotalSeconds; if ($span -le 0) { $span = 1 }
    $fx = { param($d) $L + (($d - $x0).TotalSeconds / $span) * $pw }
    $fy = { param($v) $vv = [math]::Max($YLo, [math]::Min($YHi, $v)); $T + (1 - (($vv - $YLo) / ($YHi - $YLo))) * $ph }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg class='chart' viewBox='0 0 $W $H' role='img' aria-label='$(Enc $Aria)'>")

    foreach ($band in $Bands) {
        $bx0 = & $fx $band.Start; $bx1 = & $fx $band.End
        if ($bx1 - $bx0 -gt 0.5) {
            [void]$sb.Append("<rect class='band' x='$(N $bx0)' y='$T' width='$(N ($bx1 - $bx0))' height='$ph'/>")
        }
    }
    for ($v = $YLo; $v -le $YHi + 0.001; $v += $YStep) {
        $y = & $fy $v
        $cls = if ($v -eq $YLo) { 'base' } else { 'grid' }
        [void]$sb.Append("<line class='$cls' x1='$L' x2='$($W - $R)' y1='$(N $y)' y2='$(N $y)'/>")
        [void]$sb.Append("<text class='ax' x='$($L - 8)' y='$(N ($y + 4))' text-anchor='end'>$(N $v)$YSuffix</text>")
    }
    foreach ($ref in $RefLines) {
        $y = & $fy $ref.Value
        [void]$sb.Append("<line class='ref' x1='$L' x2='$($W - $R)' y1='$(N $y)' y2='$(N $y)'/>")
        [void]$sb.Append("<text class='ref-l' x='$($L + 6)' y='$(N ($y - 6))' text-anchor='start'>$(Enc $ref.Label)</text>")
    }
    $tickDays = @()
    if ($DayTicks) {
        $d = $x0.Date.AddDays(1)
        while ($d -lt $x1) { $tickDays += $d; $d = $d.AddDays(1) }
    }
    if ($tickDays.Count -ge 1 -and $tickDays.Count -le 8) {
        foreach ($d in $tickDays) {
            $x = & $fx $d
            [void]$sb.Append("<line class='grid' x1='$(N $x)' x2='$(N $x)' y1='$T' y2='$($T + $ph)'/>")
            [void]$sb.Append("<text class='ax' x='$(N ($x + 4))' y='$($H - 10)' text-anchor='start'>$(Enc $d.ToString($DateFormat))</text>")
        }
    } else {
        for ($k = 0; $k -le 4; $k++) {
            $d = $x0.AddSeconds($span * $k / 4)
            $x = & $fx $d
            $anchor = if ($k -eq 0) { 'start' } elseif ($k -eq 4) { 'end' } else { 'middle' }
            [void]$sb.Append("<text class='ax' x='$(N $x)' y='$($H - 10)' text-anchor='$anchor'>$(Enc $d.ToString($DateFormat))</text>")
        }
    }

    $xs = New-Object System.Collections.ArrayList; $ys = New-Object System.Collections.ArrayList
    foreach ($p in $Points) { [void]$xs.Add((& $fx $p.Date)); [void]$ys.Add((& $fy $p.Value)) }
    $segs = for ($i = 0; $i -lt $xs.Count; $i++) { "$(N $xs[$i]),$(N $ys[$i])" }
    [void]$sb.Append("<path class='ln' d='M$($segs -join ' L')'/>")

    $lx = $xs[$xs.Count - 1]; $ly = $ys[$ys.Count - 1]
    [void]$sb.Append("<circle class='last' cx='$(N $lx)' cy='$(N $ly)' r='4.5'/>")
    if ($LastLabel) {
        # Put the label on the side of the point away from where the line arrives from
        $back = [math]::Max(0, $ys.Count - 6); $sumY = 0.0; $cnt = 0
        for ($i = $back; $i -lt $ys.Count - 1; $i++) { $sumY += $ys[$i]; $cnt++ }
        $prevY = if ($cnt -gt 0) { $sumY / $cnt } else { $ly }
        $below = ($prevY -lt $ly - 1) -or ($ly -lt $T + 24)
        if ($ly -gt $T + $ph - 24) { $below = $false }
        $labelY = if ($below) { $ly + 22 } else { $ly - 12 }
        [void]$sb.Append("<text class='lbl' x='$(N ($lx - 6))' y='$(N $labelY)' text-anchor='end'>$(Enc $LastLabel)</text>")
    }

    [void]$sb.Append("<line class='hv-line' x1='0' x2='0' y1='$T' y2='$($T + $ph)'/><circle class='hv-dot' cx='0' cy='0' r='4.5'/>")
    for ($i = 0; $i -lt $xs.Count; $i++) {
        $left = if ($i -eq 0) { $L } else { ($xs[$i - 1] + $xs[$i]) / 2 }
        $right = if ($i -eq $xs.Count - 1) { $W - $R } else { ($xs[$i] + $xs[$i + 1]) / 2 }
        $wid = [math]::Max(1, $right - $left)
        [void]$sb.Append("<rect class='hit' x='$(N $left)' y='$T' width='$(N $wid)' height='$ph' data-cx='$(N $xs[$i])' data-cy='$(N $ys[$i])' data-tip='$(Enc $Points[$i].Tip)'/>")
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-StackedBarChart {
    param(
        [object[]]$Items,    # objects with Label, A (bottom: on battery), B (top: plugged in), Tip
        [string]$Aria = 'Chart'
    )
    $W = 680; $H = 240; $L = 46; $R = 12; $T = 14; $B = 34
    $pw = $W - $L - $R; $ph = $H - $T - $B
    $max = 0.0
    foreach ($it in $Items) { $s = $it.A + $it.B; if ($s -gt $max) { $max = $s } }
    $top = Get-NiceMax $max
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg class='chart' viewBox='0 0 $W $H' role='img' aria-label='$(Enc $Aria)'>")
    for ($k = 0; $k -le 4; $k++) {
        $v = $top * $k / 4
        $y = $T + $ph - ($v / $top) * $ph
        $cls = if ($k -eq 0) { 'base' } else { 'grid' }
        [void]$sb.Append("<line class='$cls' x1='$L' x2='$($W - $R)' y1='$(N $y)' y2='$(N $y)'/>")
        [void]$sb.Append("<text class='ax' x='$($L - 8)' y='$(N ($y + 4))' text-anchor='end'>$(N ([math]::Round($v, 1)))h</text>")
    }
    $n = $Items.Count
    $slot = $pw / $n
    $bw = [math]::Min(34, $slot * 0.62)
    $every = [math]::Max(1, [math]::Ceiling($n / 7))
    $yBase = $T + $ph
    for ($i = 0; $i -lt $n; $i++) {
        $it = $Items[$i]
        $cx = $L + $slot * ($i + 0.5); $x = $cx - $bw / 2
        $hA = if ($it.A -gt 0) { [math]::Max(1.5, $it.A / $top * $ph) } else { 0 }
        $hB = if ($it.B -gt 0) { [math]::Max(1.5, $it.B / $top * $ph) } else { 0 }
        if ($hA -gt 0) {
            if ($hB -gt 0) {
                [void]$sb.Append("<rect class='s1' x='$(N $x)' y='$(N ($yBase - $hA))' width='$(N $bw)' height='$(N $hA)'/>")
            } else {
                [void]$sb.Append("<path class='s1' d='$(Get-TopRoundedPath $x ($yBase - $hA) $bw $hA 4)'/>")
            }
        }
        if ($hB -gt 0) {
            $gap = if ($hA -gt 0) { 2 } else { 0 }
            $yB = $yBase - $hA - $gap - $hB
            [void]$sb.Append("<path class='s2' d='$(Get-TopRoundedPath $x $yB $bw $hB 4)'/>")
        }
        if (($n - 1 - $i) % $every -eq 0) {
            [void]$sb.Append("<text class='ax' x='$(N $cx)' y='$($H - 12)' text-anchor='middle'>$(Enc $it.Label)</text>")
        }
        [void]$sb.Append("<rect class='hit bar-hit' x='$(N ($L + $slot * $i))' y='$T' width='$(N $slot)' height='$ph' data-tip='$(Enc $it.Tip)'/>")
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function Legend([string[]]$entries) {
    # entries: "class|label"
    $parts = foreach ($e in $entries) {
        $bits = $e.Split('|')
        "<span class='lg'><span class='lg-key $($bits[0])'></span>$(Enc $bits[1])</span>"
    }
    "<div class='legend'>$($parts -join '')</div>"
}

function Table([string[]]$headers, [object[]]$rows, [string]$summary = 'Show the numbers as a table') {
    $h = ($headers | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
    $b = foreach ($r in $rows) { '<tr>' + (($r | ForEach-Object { "<td>$(Enc ([string]$_))</td>" }) -join '') + '</tr>' }
    "<details class='tbl'><summary>$(Enc $summary)</summary><div class='tbl-wrap'><table><thead><tr>$h</tr></thead><tbody>$($b -join '')</tbody></table></div></details>"
}

function Section([string]$id, [string]$num, [string]$title, [string]$reportName, [string]$body) {
    $aka = if ($reportName) { "<p class='aka'>In the Windows report this is called <b>$(Enc $reportName)</b></p>" } else { '' }
    "<section class='card' id='$id'><div class='sec-head'><span class='sec-num'>$num</span><div><h2>$(Enc $title)</h2>$aka</div></div>$body</section>"
}

function Get-ChargeLimitHelp([string]$maker) {
    $m = $maker.ToLower()
    if ($m -match 'lenovo')          { return 'Open <b>Lenovo Vantage</b>, go to <b>Device &gt; Power</b> and turn on <b>Conservation Mode</b> (or set a <b>Battery Charge Threshold</b> of around 80%).' }
    if ($m -match 'dell|alienware')  { return 'Open <b>Dell Optimizer</b> or <b>Dell Power Manager</b>, go to <b>Battery Settings</b> and choose <b>Primarily AC Use</b> (or a <b>Custom</b> limit such as 80%).' }
    if ($m -match 'hp|hewlett')      { return 'Open the <b>myHP</b> app (or <b>HP Power Manager</b>) and look for <b>Battery Health Manager</b> or <b>Adaptive Battery Optimizer</b>. On some HP models this setting is in the BIOS.' }
    if ($m -match 'asus')            { return 'Open <b>MyASUS</b>, go to <b>Customization &gt; Power &amp; Performance</b> and set <b>Battery Health Charging</b> to <b>Balanced mode</b> (80%).' }
    if ($m -match 'acer')            { return 'Open <b>Acer Care Center</b> or <b>AcerSense</b> and turn on <b>Battery charge limit</b> (stops at 80%).' }
    if ($m -match 'microsoft')       { return 'On a Surface, open the <b>Surface app</b>, choose <b>Battery</b> and turn on <b>Smart Charging</b>.' }
    if ($m -match 'huawei|honor')    { return 'Open <b>PC Manager</b>, go to <b>Settings</b> and turn on <b>Smart charge</b>. This keeps the battery below 100% when you are mostly plugged in.' }
    if ($m -match 'samsung')         { return 'Open <b>Samsung Settings</b> and turn on <b>Battery Life Extender</b> (stops charging at 85%).' }
    if ($m -match 'msi|micro-star')  { return 'Open <b>MSI Center</b> and set <b>Battery Master</b> to <b>Balanced</b> or <b>Best for Battery</b>.' }
    if ($m -match 'razer')           { return 'Open <b>Razer Synapse</b> and turn on <b>Battery Health Optimizer</b>.' }
    if ($m -match 'framework')       { return 'Restart into the BIOS (press F2 at start-up) and set the <b>battery charge limit</b> to around 80%.' }
    return 'Look in your laptop maker''s support app, or in the BIOS/UEFI settings, for an option called something like <b>battery charge limit</b>, <b>battery care</b> or <b>conservation mode</b>.'
}

# =====================================================================================
#  Main
# =====================================================================================

try {
    Write-Host ''
    Write-Host '  Battery Butler, at your service' -ForegroundColor Cyan
    Write-Host '  -------------------------------' -ForegroundColor Cyan

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Battery Butler Reports'
    }
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $techReport = $null
    $isLive = $false
    $tempXml = $null

    if (-not $XmlPath) {
        $isLive = $true
        Write-Host '  Asking Windows for its battery report...'
        $tempXml = Join-Path $env:TEMP "battery-report-$stamp.xml"
        & powercfg.exe /batteryreport /xml /output "$tempXml" | Out-Null
        if (-not (Test-Path -LiteralPath $tempXml)) { throw 'Windows did not create a battery report (powercfg /batteryreport failed).' }
        $XmlPath = $tempXml
        # Also keep Windows' own (technical) report so it can be opened from the summary
        $techReport = Join-Path $OutputFolder "Technical battery report $stamp.html"
        & powercfg.exe /batteryreport /output "$techReport" | Out-Null
        if (-not (Test-Path -LiteralPath $techReport)) { $techReport = $null }
    } elseif (-not (Test-Path -LiteralPath $XmlPath)) {
        throw "Can't find the file: $XmlPath"
    }

    Write-Host '  Reading the results...'
    [xml]$doc = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $XmlPath).Path)
    $root = $doc.DocumentElement
    $sysEl = Get-Child $root 'SystemInformation'
    $repEl = Get-Child $root 'ReportInformation'

    $maker    = Get-Text $sysEl 'SystemManufacturer'
    $model    = Get-Text $sysEl 'SystemProductName'
    $computer = Get-Text $sysEl 'ComputerName'
    $biosDate = To-Date (Get-Text $sysEl 'BIOSDate')
    $scanTime = To-Date (Get-Text $repEl 'LocalScanTime')
    if (-not $scanTime) { $scanTime = Get-Date }

    # ---------------- Batteries ----------------
    $bats = @(foreach ($b in (Get-Children (Get-Child $root 'Batteries') 'Battery')) {
        [pscustomobject]@{
            Id     = Get-Text $b 'Id'
            Maker  = Get-Text $b 'Manufacturer'
            Chem   = Get-Text $b 'Chemistry'
            Design = To-Num (Get-Text $b 'DesignCapacity')
            Full   = To-Num (Get-Text $b 'FullChargeCapacity')
            Cycles = To-Num (Get-Text $b 'CycleCount')
        }
    })
    $designCap = 0.0; $fullCap = 0.0; $cycles = 0.0
    foreach ($b in $bats) { $designCap += $b.Design; $fullCap += $b.Full; $cycles += $b.Cycles }
    $hasBattery = ($bats.Count -gt 0 -and $designCap -gt 0)
    $health = if ($hasBattery) { $fullCap / $designCap * 100 } else { 0 }

    # ---------------- Life estimates (since Windows was installed) ----------------
    $rtEl = Get-Child $root 'RuntimeEstimates'
    $rtFull = Get-Child $rtEl 'FullChargeCapacity'
    $rtDesign = Get-Child $rtEl 'DesignCapacity'
    $estUseNow   = To-Hours (Get-Text $rtFull 'ActiveRuntime')
    $estUseNew   = To-Hours (Get-Text $rtDesign 'ActiveRuntime')
    $estSleepNow = To-Hours (Get-Text $rtFull 'ConnectedStandbyRuntime')
    $estSleepNew = To-Hours (Get-Text $rtDesign 'ConnectedStandbyRuntime')

    # ---------------- History (Usage history / capacity history / estimates) ----------------
    $hist = @(@(foreach ($e in (Get-Children (Get-Child $root 'History') 'HistoryEntry')) {
        $s = To-Date (Attr $e 'LocalStartDate'); if (-not $s) { $s = To-Date (Attr $e 'StartDate') }
        $en = To-Date (Attr $e 'LocalEndDate');  if (-not $en) { $en = To-Date (Attr $e 'EndDate') }
        if (-not $en) { $en = $s }
        [pscustomobject]@{
            Start     = $s
            End       = $en
            Design    = To-Num (Attr $e 'DesignCapacity')
            Full      = To-Num (Attr $e 'FullChargeCapacity')
            Cycles    = To-Num (Attr $e 'CycleCount')
            UseBat    = To-Hours (Attr $e 'ActiveDcTime')
            UsePlug   = To-Hours (Attr $e 'ActiveAcTime')
            SleepBat  = To-Hours (Attr $e 'CsDcTime')
            SleepPlug = To-Hours (Attr $e 'CsAcTime')
            EstNow    = To-Hours (Attr $e 'EstimatedFullChargeActiveTime')
            EstNew    = To-Hours (Attr $e 'EstimatedDesignActiveTime')
            Changed   = ((Attr $e 'BatteryChanged') -eq '1')
        }
    }) | Where-Object { $null -ne $_.Start } | Sort-Object Start)

    # ---------------- Recent usage (last few days) ----------------
    $usage = @(@(foreach ($e in (Get-Children (Get-Child $root 'RecentUsage') 'UsageEntry')) {
        $t = To-Date (Attr $e 'LocalTimestamp'); if (-not $t) { $t = To-Date (Attr $e 'Timestamp') }
        $ac = (Attr $e 'Ac').ToLower()
        $charge = To-Num (Attr $e 'ChargeCapacity')
        $full = To-Num (Attr $e 'FullChargeCapacity')
        $pct = if ($full -gt 0) { [math]::Min(100, $charge / $full * 100) } else { $null }
        [pscustomobject]@{
            Time   = $t
            Ac     = ($ac -eq '1' -or $ac -eq 'true')
            Type   = Attr $e 'EntryType'
            Charge = $charge
            Full   = $full
            Pct    = $pct
        }
    }) | Where-Object { $null -ne $_.Time } | Sort-Object Time)

    # Turn the list of "something changed at this time" entries into periods
    $segs = @(for ($i = 0; $i -lt $usage.Count - 1; $i++) {
        $a = $usage[$i]; $z = $usage[$i + 1]
        $drainPct = if ($null -ne $a.Pct -and $null -ne $z.Pct) { $a.Pct - $z.Pct } else { 0 }
        [pscustomobject]@{
            Start    = $a.Time
            End      = $z.Time
            Hours    = ($z.Time - $a.Time).TotalHours
            Kind     = Get-Kind $a.Type
            State    = Get-StateName $a.Type
            Ac       = $a.Ac
            StartPct = $a.Pct
            EndPct   = $z.Pct
            DrainPct = $drainPct
            DrainWh  = ($a.Charge - $z.Charge) / 1000
        }
    })

    # Live status from Windows right now (only meaningful for this laptop)
    $liveCharge = $null; $livePlugged = $null
    if ($isLive) {
        try {
            $wb = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
            if ($wb.Count -gt 0) {
                $liveCharge = [double]$wb[0].EstimatedChargeRemaining
                $livePlugged = ($wb[0].BatteryStatus -ne 1 -and $wb[0].BatteryStatus -ne 4 -and $wb[0].BatteryStatus -ne 5)
            }
        } catch { }
    }

    Write-Host '  Working out what it all means...'

    $titleDevice = (@($maker, $model) | Where-Object { $_ }) -join ' '
    if (-not $titleDevice) { $titleDevice = $computer }

    # =================================================================================
    #  Calculations used by several sections and by the advice
    # =================================================================================

    # Recent usage stats
    $rUseBat = 0.0; $rUsePlug = 0.0; $rSleepBat = 0.0; $rSleepPlug = 0.0; $rFullPlugged = 0.0
    $unplugs = 0; $lowDips = 0
    foreach ($s in $segs) {
        if ($s.Kind -eq 'use')   { if ($s.Ac) { $rUsePlug += $s.Hours } else { $rUseBat += $s.Hours } }
        if ($s.Kind -eq 'sleep') { if ($s.Ac) { $rSleepPlug += $s.Hours } else { $rSleepBat += $s.Hours } }
        if ($s.Ac -and $null -ne $s.StartPct -and $s.StartPct -ge 95 -and $null -ne $s.EndPct -and $s.EndPct -ge 95) { $rFullPlugged += $s.Hours }
    }
    $minEntry = $null; $maxEntry = $null; $wasLow = $false
    for ($i = 0; $i -lt $usage.Count; $i++) {
        $u = $usage[$i]
        if ($i -gt 0 -and $usage[$i - 1].Ac -and -not $u.Ac) { $unplugs++ }
        if ($null -ne $u.Pct) {
            if ($null -eq $minEntry -or $u.Pct -lt $minEntry.Pct) { $minEntry = $u }
            if ($null -eq $maxEntry -or $u.Pct -gt $maxEntry.Pct) { $maxEntry = $u }
            if ($u.Pct -lt 20 -and -not $wasLow) { $lowDips++; $wasLow = $true }
            if ($u.Pct -ge 30) { $wasLow = $false }
        }
    }

    # Battery usage (drain) stats - only periods on battery
    $batSegs = @($segs | Where-Object { -not $_.Ac -and $_.Kind -ne 'other' -and $_.Hours -gt 0 })
    $useDrain = 0.0; $useHours = 0.0; $sleepDrain = 0.0; $sleepHours = 0.0
    foreach ($s in $batSegs) {
        if ($s.DrainPct -lt 0) { continue }
        if ($s.Kind -eq 'use')   { $useDrain += $s.DrainPct; $useHours += $s.Hours }
        if ($s.Kind -eq 'sleep') { $sleepDrain += $s.DrainPct; $sleepHours += $s.Hours }
    }
    $rateUse = if ($useHours -ge 0.25 -and $useDrain -gt 0) { $useDrain / $useHours } else { $null }
    $rateSleep = if ($sleepHours -ge 1) { $sleepDrain / $sleepHours } else { $null }

    # Usage history totals
    $hUseBat = 0.0; $hUsePlug = 0.0; $hSleepBat = 0.0; $hSleepPlug = 0.0
    foreach ($h in $hist) { $hUseBat += $h.UseBat; $hUsePlug += $h.UsePlug; $hSleepBat += $h.SleepBat; $hSleepPlug += $h.SleepPlug }
    $hUseTotal = $hUseBat + $hUsePlug
    $plugShare = if ($hUseTotal -ge 1) { $hUsePlug / $hUseTotal * 100 } else { $null }
    $recentPeriods = @($hist | Select-Object -Last 8)
    $idlePeriods = @($recentPeriods | Where-Object { ($_.UseBat + $_.UsePlug) -lt 0.1 }).Count
    $batteryChanged = @($hist | Where-Object { $_.Changed }).Count -gt 0

    # Capacity history
    $capPts = New-Object System.Collections.ArrayList
    foreach ($h in $hist) {
        if ($h.Design -gt 0 -and $h.Full -gt 0) {
            $p = $h.Full / $h.Design * 100
            [void]$capPts.Add([pscustomobject]@{ Date = $h.End; Value = $p; Full = $h.Full; Tip = "$(Fmt-Day $h.End)|Health: $(Fmt-Pct $p)|Holds $(Fmt-Wh $h.Full) when full" })
        }
    }
    if ($hasBattery) {
        [void]$capPts.Add([pscustomobject]@{ Date = $scanTime; Value = $health; Full = $fullCap; Tip = "Today|Health: $(Fmt-Pct $health)|Holds $(Fmt-Wh $fullCap) when full" })
    }
    # Rate of change from when records began to today, in percentage points per year
    # (kept deliberately simple so it matches the "then vs now" figures shown to the user)
    $slope = $null; $spanYears = 0.0
    if ($capPts.Count -ge 2) {
        $spanYears = ($capPts[$capPts.Count - 1].Date - $capPts[0].Date).TotalDays / 365.25
        if ($spanYears -ge 0.25) { $slope = ($capPts[$capPts.Count - 1].Value - $capPts[0].Value) / $spanYears }
    }

    # Estimates history - only periods with enough battery use to mean anything
    $estRows = @($hist | Where-Object { $_.UseBat -ge 0.5 -and $_.EstNow -ge (10 / 60) })
    # Best single "how long does a full charge last" figure
    $lifeNow = if ($estUseNow -gt (10 / 60)) { $estUseNow } elseif ($rateUse) { 100 / $rateUse } elseif ($estRows.Count -gt 0) { $estRows[$estRows.Count - 1].EstNow } else { $null }

    # Health grade
    $grade = if (-not $hasBattery) { $null }
        elseif ($health -ge 90) { @{ Tone = 'good';  Label = 'Excellent';  Text = 'Your battery is in great shape. It holds almost as much charge as it did when it was new.' } }
        elseif ($health -ge 80) { @{ Tone = 'good';  Label = 'Good';       Text = 'Your battery is healthy. It has lost a little capacity, which is completely normal as batteries age.' } }
        elseif ($health -ge 70) { @{ Tone = 'warn';  Label = 'Fair';       Text = 'Your battery is showing its age. You will notice it runs out sooner than it used to, but it still has plenty of life left.' } }
        elseif ($health -ge 60) { @{ Tone = 'warn';  Label = 'Worn';       Text = 'Your battery has worn noticeably. It is still usable, but it is worth starting to plan for a replacement.' } }
        else                    { @{ Tone = 'alert'; Label = 'Needs replacing soon'; Text = 'Your battery has lost a lot of its capacity. A replacement would make a big difference to how long your laptop lasts unplugged.' } }

    # =================================================================================
    #  1. Battery health
    # =================================================================================
    if ($hasBattery) {
        $minsPerHour = [math]::Min(60, [math]::Round($health * 0.6))
        $gaugeW = [math]::Min(100, [math]::Max(0, $health))
        $over = if ($health -gt 100) { "<p>Your battery currently reports slightly <b>more</b> than its official capacity. That's common with newer batteries - manufacturers build in a little headroom - and it's a good sign.</p>" } else { '' }
        $cycleHtml = if ($cycles -gt 0) {
            $cyc = [int]$cycles
            $cycNote = if ($cyc -lt 100) { 'That is very low - most laptop batteries are designed to handle somewhere between 300 and 1,000 cycles before they drop to about 80% health.' }
                       elseif ($cyc -lt 300) { 'That is a low-to-moderate number. Most laptop batteries are designed to handle somewhere between 300 and 1,000 cycles before they drop to about 80% health.' }
                       elseif ($cyc -lt 700) { 'That is a moderate amount of use. Most laptop batteries are designed to handle somewhere between 300 and 1,000 cycles before they drop to about 80% health.' }
                       else { 'That is a lot of use. Most laptop batteries are designed to handle somewhere between 300 and 1,000 cycles, so wear is expected by now.' }
            "<p><b>Charge cycles: $cyc.</b> One cycle means using a full battery's worth of charge in total - for example, using 50% one day and 50% the next counts as one cycle. $cycNote</p>"
        } else { "<p><b>Charge cycles:</b> your laptop doesn't report how many times the battery has been charged, so this can't be shown.</p>" }
        $multi = if ($bats.Count -gt 1) { "<p>Your laptop has <b>$($bats.Count) batteries</b>. The figures above combine them.</p>" } else { '' }
        $chem = switch -regex ($bats[0].Chem) { 'LION|Li-?ion' { 'lithium-ion' } 'LiP|Poly' { 'lithium-polymer' } default { '' } }
        $chemHtml = if ($chem) { " It's a $chem battery, the standard type used in modern laptops." } else { '' }

        $healthBody = @"
<div class='gauge-row'>
  <div class='hero'><span class='hero-n'>$(Fmt-Pct $health)</span><span class='hero-l'>battery health</span>$(Pill $grade.Tone $grade.Label)</div>
  <div class='gauge-wrap'>
    <div class='gauge' role='img' aria-label='Battery health $(Fmt-Pct $health) of original capacity'>
      <div class='gauge-fill tone-$($grade.Tone)' style='width:$(N $gaugeW)%'></div>
      <span class='gauge-mark' style='left:80%'></span><span class='gauge-mark' style='left:60%'></span>
    </div>
    <div class='gauge-scale'><span style='left:0%'>0%</span><span style='left:60%'>60%</span><span style='left:80%'>80%</span><span style='left:100%'>100%</span></div>
    <p class='gauge-note'>Above 80% is healthy. Below 60% a replacement is usually worthwhile.</p>
  </div>
</div>
<p class='lead'>$(Enc $grade.Text)</p>
<div class='compare'>
  <div><span class='cmp-v'>$(Fmt-Wh $designCap)</span><span class='cmp-l'>What it held when new<br><small>(design capacity)</small></span></div>
  <div class='cmp-arrow' aria-hidden='true'>&#8594;</div>
  <div><span class='cmp-v'>$(Fmt-Wh $fullCap)</span><span class='cmp-l'>What it holds now when full<br><small>(full charge capacity)</small></span></div>
</div>
<p>Think of the battery as a fuel tank. When new, the tank held <b>$(Fmt-Wh $designCap)</b> of energy. Today, when charged to 100%, it holds <b>$(Fmt-Wh $fullCap)</b> - that's <b>$(Fmt-Pct $health)</b> of the original size. In everyday terms: <b>for every hour of use you got when the battery was new, you'll now get about $minsPerHour minutes.</b>$chemHtml</p>
$over
$cycleHtml
$multi
"@
    }

    # =================================================================================
    #  2. Recent usage
    # =================================================================================
    if ($usage.Count -ge 2) {
        $rFirst = $usage[0].Time; $rLast = $usage[$usage.Count - 1].Time
        $rSpan = ($rLast - $rFirst).TotalDays
        $spanText = if ($rSpan -ge 1.5) { "the last $([math]::Round($rSpan)) days" } else { 'the last day or so' }
        $facts = @"
<ul class='facts'>
  <li><span class='fact-v'>$(Fmt-Short $rUseBat)</span><span class='fact-l'>in use on battery</span></li>
  <li><span class='fact-v'>$(Fmt-Short $rUsePlug)</span><span class='fact-l'>in use while plugged in</span></li>
  <li><span class='fact-v'>$(Fmt-Short ($rSleepBat + $rSleepPlug))</span><span class='fact-l'>asleep</span></li>
  <li><span class='fact-v'>$unplugs</span><span class='fact-l'>times unplugged</span></li>
</ul>
"@
        $obs = New-Object System.Collections.ArrayList
        if ($minEntry) { [void]$obs.Add("The lowest the battery got was <b>$(Fmt-Pct $minEntry.Pct)</b> ($(Enc (Fmt-When $minEntry.Time))).") }
        if ($maxEntry) { [void]$obs.Add("The highest it got was <b>$(Fmt-Pct $maxEntry.Pct)</b>.") }
        if ($lowDips -gt 0) { [void]$obs.Add("It dropped below 20% <b>$(Plural $lowDips 'time')</b>. Running very low regularly adds extra wear.") }
        if ($rFullPlugged -ge 1) { [void]$obs.Add("It sat plugged in at (or close to) 100% for about <b>$(Fmt-Dur $rFullPlugged)</b>. Being held at full charge for long periods slowly wears a battery.") }
        if ($rSleepBat -ge 1) { [void]$obs.Add("It spent about <b>$(Fmt-Dur $rSleepBat)</b> asleep while unplugged - see the next section for how much battery that used.") }
        $obsHtml = if ($obs.Count) { '<ul class="obs">' + (($obs | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>' } else { '' }

        $chartPts = @($usage | Where-Object { $null -ne $_.Pct } | ForEach-Object {
            $src = if ($_.Ac) { 'Plugged in' } else { 'On battery' }
            [pscustomobject]@{ Date = $_.Time; Value = $_.Pct; Tip = "$(Fmt-When $_.Time)|Charge: $(Fmt-Pct $_.Pct)|$(Get-StateName $_.Type), $($src.ToLower())" }
        })
        $bands = @($segs | Where-Object { $_.Ac } | ForEach-Object { [pscustomobject]@{ Start = $_.Start; End = $_.End } })
        $chartHtml = ''
        if ($chartPts.Count -ge 2) {
            $lastP = $chartPts[$chartPts.Count - 1]
            $chartHtml = "<h3>Charge level over $spanText</h3>" +
                (Legend @('k-line|Charge level', 'k-band|Plugged in (shaded)')) +
                (New-LineChart -Points $chartPts -YLo 0 -YHi 100 -YStep 25 -Bands $bands -DateFormat 'ddd d MMM' -DayTicks -LastLabel "Now $(Fmt-Pct $lastP.Value)" -Aria 'Battery charge level over the last few days')
        }
        $rows = @(foreach ($u in $usage) {
            $src = if ($u.Ac) { 'Plugged in' } else { 'Battery' }
            $pc = if ($null -ne $u.Pct) { Fmt-Pct $u.Pct } else { '-' }
            , @((Fmt-When $u.Time), (Get-StateName $u.Type), $src, $pc)
        })
        $recentBody = "<p class='lead'>Here's what your laptop has been doing over $spanText (from $(Enc (Fmt-When $rFirst)) to $(Enc (Fmt-When $rLast))).</p>" +
            $facts + $obsHtml + $chartHtml +
            (Table @('When', 'What was happening', 'Power', 'Charge level') $rows 'Show every change Windows recorded')
    } else {
        $recentBody = "<p class='lead'>Windows hasn't recorded any activity on this battery in the last few days.</p><p>This normally means the laptop was switched off, or was left plugged in and asleep the whole time. Run this check again after you've used the laptop for a day or two to see this section filled in.</p>"
    }
    if ($null -ne $liveCharge) {
        $plugText = if ($livePlugged) { 'plugged in' } else { 'running on battery' }
        $recentBody = "<p class='now'><b>Right now:</b> the battery is at <b>$(Fmt-Pct $liveCharge)</b> and the laptop is $plugText.</p>" + $recentBody
    }

    # =================================================================================
    #  3. Battery usage (drain while unplugged)
    # =================================================================================
    if ($batSegs.Count -gt 0) {
        $p = New-Object System.Collections.ArrayList
        if ($null -ne $rateUse) {
            $useVerdict = if ($rateUse -lt 10) { Pill 'good' 'Light use' } elseif ($rateUse -le 20) { Pill 'info' 'Typical' } else { Pill 'warn' 'Heavy use' }
            [void]$p.Add("<p class='lead'>While you were using it unplugged, your laptop used about <b>$('{0:N0}' -f $rateUse)% of the battery per hour</b>. At that rate, a full charge would last roughly <b>$(Fmt-Dur (100 / $rateUse))</b>. $useVerdict</p>")
            [void]$p.Add("<p>Between 10% and 20% an hour is typical for everyday tasks like browsing and documents. Video calls, games, streaming or a bright screen push it higher.</p>")
        } else {
            [void]$p.Add("<p class='lead'>Your laptop was only used on battery very briefly in the last few days, so there isn't enough information to work out how quickly it drains while in use.</p>")
        }
        if ($null -ne $rateSleep) {
            $night = $rateSleep * 8
            $sleepVerdict = if ($rateSleep -le 1) { Pill 'good' 'Normal' } elseif ($rateSleep -le 3) { Pill 'warn' 'A little high' } else { Pill 'alert' 'High' }
            [void]$p.Add("<p>While <b>asleep</b> on battery, it used about <b>$('{0:N1}' -f $rateSleep)% per hour</b> - roughly <b>$(Fmt-Pct ([math]::Min(100, $night)))</b> over an 8-hour night. $sleepVerdict</p>")
            [void]$p.Add("<p class='muted'>Many modern laptops stay lightly awake while sleeping (&quot;modern standby&quot;) so they can fetch email and updates. Losing up to about 1% an hour is normal; much more than that suggests something is keeping it busy.</p>")
        }
        $big = @($batSegs | Where-Object { $_.DrainPct -gt 0.5 } | Sort-Object DrainPct -Descending | Select-Object -First 3)
        if ($big.Count -gt 0) {
            $items = foreach ($s in $big) {
                $what = if ($s.Kind -eq 'use') { 'in use' } else { 'asleep' }
                "<li><b>$(Enc (Fmt-When $s.Start))</b> - $what for $(Fmt-Dur $s.Hours), used <b>$(Fmt-Pct $s.DrainPct)</b> of the battery ($(Fmt-Pct $s.StartPct) &#8594; $(Fmt-Pct $s.EndPct))</li>"
            }
            [void]$p.Add("<h3>Biggest battery users</h3><ul class='obs'>$($items -join '')</ul>")
        }
        $rows = @(foreach ($s in $batSegs) {
            $dp = if ($s.DrainPct -gt 0) { Fmt-Pct $s.DrainPct } else { '-' }
            $dw = if ($s.DrainWh -gt 0) { '{0:N1} Wh' -f $s.DrainWh } else { '-' }
            , @((Fmt-When $s.Start), $s.State, (Fmt-Short $s.Hours), $dp, $dw)
        })
        [void]$p.Add((Table @('Started', 'What was happening', 'How long', 'Battery used', 'Energy used') $rows 'Show every time it ran on battery'))
        $drainBody = $p -join ''
    } else {
        $drainBody = "<p class='lead'>Your laptop wasn't used on battery power in the last few days, so there's nothing to show here.</p><p>This section fills in once the laptop has been used unplugged - it shows how quickly the battery goes down while you're using it and while it's asleep.</p>"
    }

    # =================================================================================
    #  4. Usage history
    # =================================================================================
    if ($hist.Count -gt 0) {
        $since = $hist[0].Start
        $yrs = ($scanTime - $since).TotalDays / 365.25
        $ageText = if ($yrs -ge 1) { "about $('{0:N1}' -f $yrs) years" } else { "about $([math]::Max(1, [math]::Round($yrs * 12))) months" }
        $p = New-Object System.Collections.ArrayList
        [void]$p.Add("<p class='lead'>Windows has been keeping records since <b>$(Fmt-Day $since)</b> ($ageText). Over that time your laptop has been <b>in use for $(Fmt-Dur $hUseTotal)</b> in total.</p>")
        [void]$p.Add(@"
<ul class='facts'>
  <li><span class='fact-v'>$(Fmt-Short $hUseBat)</span><span class='fact-l'>in use on battery</span></li>
  <li><span class='fact-v'>$(Fmt-Short $hUsePlug)</span><span class='fact-l'>in use while plugged in</span></li>
  <li><span class='fact-v'>$(Fmt-Short $hSleepBat)</span><span class='fact-l'>asleep on battery</span></li>
  <li><span class='fact-v'>$(Fmt-Short $hSleepPlug)</span><span class='fact-l'>asleep while plugged in</span></li>
</ul>
"@)
        if ($null -ne $plugShare) {
            $style = if ($plugShare -ge 75) { "That means you mostly use your laptop <b>like a desktop computer</b>, plugged in at a desk. Batteries used this way tend to sit at 100% for long periods, which wears them faster - see the advice below for an easy fix." }
                     elseif ($plugShare -le 25) { "That means you mostly use your laptop <b>on the go</b>, running on battery. The battery gets plenty of work, so good charging habits really pay off." }
                     else { "That's a <b>healthy mix</b> of battery and mains use." }
            $shareText = if ($plugShare -ge 99.5) { 'Almost all' } elseif ($plugShare -le 0.5) { 'Almost none' } else { "About <b>$(Fmt-Pct $plugShare)</b>" }
            $shareText = if ($shareText -like 'About*') { $shareText } else { "<b>$shareText</b>" }
            [void]$p.Add("<p>$shareText of the time you've spent using your laptop, it was plugged in. $style</p>")
        }
        if ($idlePeriods -ge 3) { [void]$p.Add("<p>In <b>$idlePeriods of the last $($recentPeriods.Count)</b> periods Windows recorded, the laptop wasn't used at all.</p>") }
        if ($batteryChanged) { [void]$p.Add("<p>Windows noticed that the <b>battery was replaced</b> at some point during this history.</p>") }

        $chartRows = @($hist | Select-Object -Last 12)
        $items = @(foreach ($h in $chartRows) {
            $days = ($h.End - $h.Start).TotalDays
            $label = $h.Start.ToString('d MMM')
            $rangeText = if ($days -le 1.1) { $h.Start.ToString('ddd d MMM yyyy') } else { "$($h.Start.ToString('d MMM')) - $($h.End.ToString('d MMM yyyy'))" }
            [pscustomobject]@{
                Label = $label; A = $h.UseBat; B = $h.UsePlug
                Tip = "$rangeText|In use on battery: $(Fmt-Short $h.UseBat)|In use plugged in: $(Fmt-Short $h.UsePlug)|Asleep: $(Fmt-Short ($h.SleepBat + $h.SleepPlug))"
            }
        })
        [void]$p.Add("<h3>Time in use, most recent periods</h3>")
        [void]$p.Add((Legend @('k-s1|On battery', 'k-s2|Plugged in')))
        [void]$p.Add((New-StackedBarChart -Items $items -Aria 'Hours of use per period, on battery and plugged in'))
        [void]$p.Add("<p class='muted'>Each bar is one period from the Windows report (older history is grouped into weeks). Hover over a bar for details.</p>")
        $rows = @(foreach ($h in ($hist | Sort-Object Start -Descending)) {
            , @((Fmt-Day $h.Start), (Fmt-Day $h.End), (Fmt-Short $h.UseBat), (Fmt-Short $h.UsePlug), (Fmt-Short $h.SleepBat), (Fmt-Short $h.SleepPlug))
        })
        [void]$p.Add((Table @('From', 'To', 'In use (battery)', 'In use (plugged in)', 'Asleep (battery)', 'Asleep (plugged in)') $rows 'Show the full history'))
        $historyBody = $p -join ''
    } else {
        $historyBody = "<p class='lead'>Windows hasn't built up a usage history for this battery yet. Check back after a week or two of use.</p>"
    }

    # =================================================================================
    #  5. Battery capacity history
    # =================================================================================
    if ($capPts.Count -ge 2) {
        $first = $capPts[0]; $last = $capPts[$capPts.Count - 1]
        $p = New-Object System.Collections.ArrayList
        [void]$p.Add("<p class='lead'>When records began on <b>$(Fmt-Day $first.Date)</b>, a full charge held <b>$(Fmt-Wh $first.Full)</b> ($(Fmt-Pct $first.Value) of the original design). Today it holds <b>$(Fmt-Wh $last.Full)</b> ($(Fmt-Pct $last.Value)).</p>")
        if ($null -ne $slope -and $spanYears -ge 0.25) {
            $perYear = -$slope
            if ($perYear -le 0.5) {
                [void]$p.Add("<p>Over $(if ($spanYears -ge 1) { "$('{0:N1}' -f $spanYears) years" } else { "$([math]::Round($spanYears * 12)) months" }), the capacity has stayed <b>steady</b>. $(Pill 'good' 'Stable')</p>")
            } else {
                $verdict = if ($perYear -le 5) { (Pill 'good' 'Normal rate of wear') + ' Most laptop batteries lose roughly 2-5% a year with normal use.' }
                           elseif ($perYear -le 10) { (Pill 'warn' 'Faster than typical') + ' Most laptop batteries lose roughly 2-5% a year. Heat and being kept at 100% are the usual causes of faster wear.' }
                           else { (Pill 'alert' 'Wearing quickly') + ' Most laptop batteries lose roughly 2-5% a year, so this is fast. Heat, being kept at 100% and heavy use are the usual causes.' }
                [void]$p.Add("<p>On average it's been losing about <b>$('{0:N1}' -f $perYear)% of its original capacity per year</b>. $verdict</p>")
                if ($health -gt 80 -and $perYear -gt 0.5) {
                    $toEighty = ($health - 80) / $perYear
                    $when = if ($toEighty -ge 1) { "about $([math]::Round($toEighty)) $(if ([math]::Round($toEighty) -eq 1) { 'year' } else { 'years' })" } else { "about $([math]::Max(1, [math]::Round($toEighty * 12))) months" }
                    [void]$p.Add("<p>If it carries on at this rate, it would reach 80% health (the point where most people start to notice) in <b>$when</b>. This is only a rough guide - looking after the battery can slow it down.</p>")
                }
            }
        }
        [void]$p.Add("<p class='muted'>Small ups and downs on the chart are normal: Windows re-measures the battery from time to time and the reading can wobble a little.</p>")
        $lo = [math]::Min(60, [math]::Floor((($capPts | Measure-Object Value -Minimum).Minimum - 5) / 10) * 10)
        $hi = [math]::Max(100, [math]::Ceiling((($capPts | Measure-Object Value -Maximum).Maximum) / 10) * 10)
        [void]$p.Add("<h3>Battery health over time</h3>")
        [void]$p.Add((New-LineChart -Points $capPts.ToArray() -YLo $lo -YHi $hi -YStep 10 -RefLines @([pscustomobject]@{ Value = 80; Label = '80% - wear becomes noticeable' }) -DateFormat 'MMM yyyy' -LastLabel "Today $(Fmt-Pct $health)" -Aria 'Battery health as a percentage of original capacity over time'))
        $rows = @(foreach ($c in ($capPts | Sort-Object Date -Descending)) { , @((Fmt-Day $c.Date), (Fmt-Wh $c.Full), (Fmt-Pct $c.Value)) })
        [void]$p.Add((Table @('Date', 'Holds when full', 'Health') $rows 'Show the numbers as a table'))
        $capBody = $p -join ''
    } else {
        $capBody = "<p class='lead'>There isn't enough history yet to show how the battery's capacity has changed over time.</p>"
    }

    # =================================================================================
    #  6. Battery life estimates
    # =================================================================================
    $p = New-Object System.Collections.ArrayList
    if ($estUseNow -gt (10 / 60)) {
        $lost = $estUseNew - $estUseNow
        $lostText = if ($lost -gt (2 / 60)) { " When the battery was new, the same use would have given you about <b>$(Fmt-Dur $estUseNew)</b> - so wear has cost you around <b>$(Fmt-Dur $lost)</b> per charge." } else { " That's about the same as when the battery was new." }
        [void]$p.Add("<p class='lead'>Based on how you've used your laptop, Windows estimates a full charge gives you about <b>$(Fmt-Dur $estUseNow)</b> of use.$lostText</p>")
        if ($estSleepNow -gt 1) {
            [void]$p.Add("<p>If you leave it <b>asleep</b> with the lid closed, a full charge would last about <b>$(Fmt-Dur $estSleepNow)</b>$(if ($estSleepNew -gt $estSleepNow + 1) { " (about $(Fmt-Dur $estSleepNew) when new)" }).</p>")
        }
    } elseif ($null -ne $lifeNow) {
        [void]$p.Add("<p class='lead'>Based on recent use, a full charge lasts roughly <b>$(Fmt-Dur $lifeNow)</b>.</p>")
    } else {
        [void]$p.Add("<p class='lead'>Windows hasn't seen enough battery use yet to estimate how long a full charge lasts.</p>")
    }
    if ($estRows.Count -gt 0) {
        [void]$p.Add("<p>These estimates change depending on what you were doing. Browsing and writing documents use far less power than video calls, games, streaming or editing photos and video, so a week of heavy use will show a shorter estimate than a week of light use.</p>")
        $showRows = @($estRows | Select-Object -Last 8)
        $hiEst = ($showRows | Measure-Object EstNow -Maximum).Maximum
        $loEst = ($showRows | Measure-Object EstNow -Minimum).Minimum
        if ($showRows.Count -ge 3) {
            [void]$p.Add("<p>In recent periods where the laptop was used on battery, the estimate ranged from <b>$(Fmt-Dur $loEst)</b> to <b>$(Fmt-Dur $hiEst)</b>.</p>")
        }
        $rows = @(foreach ($h in ($showRows | Sort-Object Start -Descending)) {
            , @("$(Fmt-Day $h.Start) - $(Fmt-Day $h.End)", (Fmt-Short $h.UseBat), (Fmt-Short $h.EstNow), (Fmt-Short $h.EstNew))
        })
        [void]$p.Add((Table @('Period', 'Used on battery', 'A full charge would last (now)', 'When the battery was new') $rows 'Show recent estimates'))
    }
    $estBody = $p -join ''

    # =================================================================================
    #  7. Advice
    # =================================================================================
    $tips = New-Object System.Collections.ArrayList
    function Add-Tip([string]$tone, [string]$title, [string]$body) { [void]$tips.Add([pscustomobject]@{ Tone = $tone; Title = $title; Body = $body }) }

    if ($null -ne $liveCharge -and $livePlugged -and $liveCharge -le 2) {
        Add-Tip 'alert' 'Check that the battery is charging' "Windows says the laptop is plugged in, but the battery is at <b>$(Fmt-Pct $liveCharge)</b>. If it's still at 0% after an hour or so on the charger, try a different socket, check the charger cable and restart the laptop. If it still won't charge, the battery or charger may be faulty - contact the manufacturer or a repair shop."
    }

    if ($hasBattery) {
        if ($health -ge 90) {
            Add-Tip 'good' 'Your battery is in great shape' "At $(Fmt-Pct $health) health there's nothing you need to fix. The habits below will help keep it that way for longer."
        } elseif ($health -ge 80) {
            Add-Tip 'good' 'Normal wear for its age' "At $(Fmt-Pct $health) health your battery has worn a little, which is completely normal. The tips below will help slow down further wear."
        } elseif ($health -ge 60) {
            Add-Tip 'warn' 'Expect shorter battery life' "At $(Fmt-Pct $health) health you'll get noticeably less time unplugged than when the laptop was new. Keep your charger handy for long days, and consider a replacement battery if it's becoming a nuisance. If your laptop is still under warranty (usually 1-2 years) contact the manufacturer - some cover batteries that wear this quickly."
        } else {
            Add-Tip 'alert' 'Think about replacing the battery' "At $(Fmt-Pct $health) health the battery has lost a large part of its capacity. A replacement from the manufacturer or a reputable repair shop will give you back most of your unplugged time, and is usually far cheaper than a new laptop. Use a genuine or good-quality replacement, not the cheapest one you can find."
        }

        if ($cycles -gt 0 -and $cycles -lt 150 -and $health -lt 90 -and $hist.Count -gt 0) {
            Add-Tip 'info' 'Your battery has aged more than it has been used' "It has only done $([int]$cycles) charge cycles, yet it has lost $(Fmt-Pct (100 - [math]::Min(100, $health))) of its capacity. That kind of wear comes mainly from <b>time, heat and being kept at 100%</b> rather than from use. Keeping the laptop cool and using a charge limit (below) are the most effective things you can do."
        }
        if ($cycles -ge 500) {
            Add-Tip 'info' 'Lots of charge cycles' "Your battery has done $([int]$cycles) charge cycles. Most laptop batteries are designed for 300-1,000, so some wear is expected. Avoiding very low and very high charge levels will help it last."
        }
    }

    $limitReasons = New-Object System.Collections.ArrayList
    if ($null -ne $plugShare -and $plugShare -ge 75) {
        $useText = if ($plugShare -ge 99.5) { 'almost all of your use is while plugged in' } else { "about $(Fmt-Pct $plugShare) of your use is while plugged in" }
        [void]$limitReasons.Add($useText)
    }
    if ($rFullPlugged -ge 12) { [void]$limitReasons.Add("in the last few days it sat at full charge for about $(Fmt-Dur $rFullPlugged)") }
    if ($limitReasons.Count -gt 0) {
        Add-Tip 'warn' 'Set a charge limit of about 80%' "Your report shows that $($limitReasons -join ', and '). Lithium-ion batteries wear fastest when they're kept full, so if your laptop spends most of its time on the charger, stopping charging at around 80% can noticeably extend the battery's life. You can turn it off any time you need a full charge for a trip.<br><br><b>How to do it on your $(Enc $maker) laptop:</b> $(Get-ChargeLimitHelp $maker) Some newer laptops also offer <b>Smart charging</b> in Windows under <b>Settings &gt; System &gt; Power &amp; battery</b>."
    }

    if (($minEntry -and $minEntry.Pct -lt 10) -or $lowDips -ge 2) {
        $lowTxt = if ($minEntry) { " (it got as low as $(Fmt-Pct $minEntry.Pct) recently)" } else { '' }
        Add-Tip 'warn' 'Try not to let it run right down' "Your battery has been running very low$lowTxt. Regularly draining a lithium-ion battery close to empty wears it faster. Aim to plug in at around 20%. Turning on <b>Energy saver</b> (in <b>Settings &gt; System &gt; Power &amp; battery</b>) to switch on automatically at 20% will help you remember."
    }

    if ($null -ne $rateUse -and $rateUse -gt 20) {
        Add-Tip 'warn' 'Your battery drains quickly when in use' "You're using about $('{0:N0}' -f $rateUse)% per hour on battery. To make a charge last longer: lower the screen brightness (the screen is usually the biggest power user), close apps you aren't using, turn on <b>Energy saver</b>, and choose the <b>Best power efficiency</b> power mode in <b>Settings &gt; System &gt; Power &amp; battery</b>. That page also has a <b>Battery usage</b> list showing which apps are using the most power."
    }

    if ($null -ne $rateSleep -and $rateSleep -gt 1.5) {
        Add-Tip 'warn' 'It loses a lot of charge while asleep' "Your laptop lost about $('{0:N1}' -f $rateSleep)% per hour while asleep. If you won't be using it for more than a few hours, <b>shut it down</b> (or use <b>Hibernate</b>) instead of just closing the lid. Unplugging USB devices before sleep, and keeping Windows and your laptop maker's drivers up to date, can also help."
    }

    if ($null -ne $slope -and $spanYears -ge 0.5 -and -$slope -gt 6) {
        Add-Tip 'warn' 'Capacity is dropping faster than usual' "Your battery is losing about $('{0:N1}' -f (-$slope))% of its capacity a year - faster than the typical 2-5%. The most common causes are <b>heat</b> (blocked vents, using it on a bed or sofa, gaming or heavy work for long periods) and <b>sitting at 100%</b> on the charger. Tackling those two will make the biggest difference."
    }

    if ($idlePeriods -ge 3) {
        Add-Tip 'info' 'Storing the laptop between uses' "Your laptop often goes unused for a week or more. If you're putting it away for a while, leave the battery at around <b>50%</b>, shut it down fully (not sleep) and keep it somewhere cool. Batteries stored completely full or completely empty wear faster, and one left empty for months can stop working altogether."
    }

    if ($biosDate -and ($scanTime - $biosDate).TotalDays -gt 730) {
        Add-Tip 'info' 'Check for firmware updates' "Your laptop's BIOS (its built-in firmware) is dated $(Fmt-Day $biosDate). Manufacturers often include battery-charging and power improvements in these updates. Use your laptop maker's support app or website to check whether a newer version is available."
    }

    $general = @(
        @('Keep it cool', 'Heat is the biggest enemy of laptop batteries. Use your laptop on a hard, flat surface - not a bed, sofa or cushion - so the air vents can breathe. Don''t leave it in a hot car or in direct sun, and avoid charging it inside a bag or tight sleeve.'),
        @('Little and often is best', 'Lithium-ion batteries are happiest between about 20% and 80%. You don''t need to run the battery flat before charging - that''s an old myth from older battery types. Topping up whenever it''s convenient is fine.'),
        @('Let Windows save power for you', 'Turn on <b>Energy saver</b> in <b>Settings &gt; System &gt; Power &amp; battery</b> and set it to start automatically at 20%. Turning down screen brightness is the single quickest way to make a charge last longer.'),
        @('Use a good charger', 'Use the charger that came with your laptop, or a good-quality replacement with the same power rating. Cheap, poorly made chargers can run hot and charge badly.'),
        @('Storing it away', 'If you won''t use the laptop for a few weeks, leave the battery at about 50%, shut it down fully and store it somewhere cool and dry. Check and top it up every couple of months.'),
        @('Keep it up to date', 'Install Windows Updates and your laptop maker''s updates (drivers and BIOS). These often contain fixes and improvements for charging and power use.'),
        @('Keep the percentage accurate', 'Every couple of months, let the battery run down to about 10% and then charge it to 100% in one go. This doesn''t change its health, but helps Windows show an accurate percentage and accurate reports like this one.'),
        @('Watch out for swelling', 'If the laptop case starts to bulge, the trackpad lifts or the keyboard pushes up, the battery may be swelling. Stop using the laptop, unplug it and contact the manufacturer or a repair shop. Never try to press or puncture a swollen battery.')
    )

    $tipHtml = ($tips | ForEach-Object {
        "<div class='tip tip-$($_.Tone)'><div class='tip-head'>$(Pill $_.Tone $(switch ($_.Tone) { 'good' { 'Good news' } 'info' { 'Worth knowing' } 'warn' { 'Recommended' } 'alert' { 'Important' } }))<h3>$(Enc $_.Title)</h3></div><p>$($_.Body)</p></div>"
    }) -join ''
    $genHtml = ($general | ForEach-Object { "<li><b>$(Enc $_[0])</b><span>$($_[1])</span></li>" }) -join ''
    $adviceBody = "<p class='lead'>Based on what's in your report, here's what we'd suggest.</p>" +
        "<div class='tips'>$tipHtml</div>" +
        "<h3 class='gen-h'>Good habits for every laptop battery</h3><ul class='gen'>$genHtml</ul>"

    # =================================================================================
    #  At a glance + glossary + page assembly
    # =================================================================================
    $glance = ''
    if ($hasBattery) {
        $lifeTile = if ($null -ne $lifeNow) { Fmt-Short $lifeNow } else { 'Not known yet' }
        $cycTile = if ($cycles -gt 0) { [string][int]$cycles } else { 'Not reported' }
        $topTip = @($tips | Where-Object { $_.Tone -eq 'alert' -or $_.Tone -eq 'warn' } | Select-Object -First 1)
        $topLine = if ($topTip.Count) { "<p class='verdict-tip'><b>Top tip:</b> $(Enc $topTip[0].Title). <a href='#advice'>See advice</a></p>" } else { '' }
        # Nearly-empty battery: the capacity figure may be re-measured after the next full charge
        $lowNote = ''
        if ($null -ne $liveCharge -and $liveCharge -lt 10) {
            $plugAdvice = if ($livePlugged) { "If it charges all the way to 100% from here" } else { "Plug it in soon. If you then charge it all the way to 100%" }
            $lowNote = "<p class='low-note'><b>Your battery is nearly empty ($(Fmt-Pct $liveCharge)).</b> $plugAdvice, the battery may re-measure how much it can hold, and the health figure below could change. For the most reliable reading, run this check again after a full charge.</p>"
        }
        $glance = @"
<section class='card glance'>
  <p class='verdict'>$(Pill $grade.Tone $grade.Label) <span>$(Enc $grade.Text)</span></p>
  $topLine
  $lowNote
  <ul class='tiles'>
    <li><span class='tile-l'>Battery health</span><span class='tile-v'>$(Fmt-Pct $health)</span><span class='tile-s'>of its original capacity</span></li>
    <li><span class='tile-l'>Holds when full</span><span class='tile-v'>$(Fmt-Wh $fullCap)</span><span class='tile-s'>was $(Fmt-Wh $designCap) when new</span></li>
    <li><span class='tile-l'>Charge cycles</span><span class='tile-v'>$cycTile</span><span class='tile-s'>full charges used so far</span></li>
    <li><span class='tile-l'>A full charge lasts about</span><span class='tile-v'>$lifeTile</span><span class='tile-s'>with your typical use</span></li>
  </ul>
</section>
"@
    }

    $glossary = @'
<section class='card' id='glossary'>
  <div class='sec-head'><span class='sec-num'>?</span><div><h2>What the words mean</h2></div></div>
  <dl class='gloss'>
    <dt>Design capacity</dt><dd>How much energy the battery could hold when it was brand new, as set by the manufacturer.</dd>
    <dt>Full charge capacity</dt><dd>How much energy the battery can hold today when it's charged to 100%. This slowly shrinks as the battery ages.</dd>
    <dt>Battery health</dt><dd>Full charge capacity divided by design capacity. 100% means as good as new.</dd>
    <dt>Wh and mWh</dt><dd>Watt-hours: a measure of energy, like litres for a fuel tank. The Windows report uses milliwatt-hours (mWh); 1,000 mWh = 1 Wh.</dd>
    <dt>Charge cycle</dt><dd>Using a full battery's worth of charge in total. Using 50% today and 50% tomorrow adds up to one cycle.</dd>
    <dt>AC / Battery</dt><dd>"AC" in the Windows report means plugged into the mains. "Battery" (or DC) means running unplugged.</dd>
    <dt>Asleep / Connected standby</dt><dd>The low-power state when you close the lid. "Connected" or "modern" standby means the laptop stays lightly awake to fetch email and updates, which uses a little battery.</dd>
  </dl>
</section>
'@

    if ($hasBattery) {
        $sections = @(
            $glance,
            (Section 'health' '1' 'Battery health: how much charge it can still hold' 'Installed batteries' $healthBody),
            (Section 'recent' '2' 'What your laptop has been doing lately' 'Recent usage' $recentBody),
            (Section 'drain' '3' 'How fast the battery goes down when unplugged' 'Battery usage' $drainBody),
            (Section 'history' '4' 'How you use your laptop over time' 'Usage history' $historyBody),
            (Section 'capacity' '5' 'How the battery has worn over time' 'Battery capacity history' $capBody),
            (Section 'life' '6' 'How long a full charge lasts' 'Battery life estimates' $estBody),
            (Section 'advice' '7' 'Looking after your battery' '' $adviceBody),
            $glossary
        ) -join "`n"
    } else {
        $sections = Section 'none' '!' 'No battery found' '' "<p class='lead'>Windows didn't find a laptop battery on this computer, so there's nothing to report. If this is a desktop PC, that's expected. If it is a laptop, the battery may be disconnected or faulty - contact the manufacturer or a repair shop.</p>"
    }

    $techLink = if ($techReport) { "<a href='$(Enc ([Uri]$techReport).AbsoluteUri)'>Open the full technical report from Windows</a>" } else { '' }
    $subtitle = "$(Enc $titleDevice)$(if ($computer -and $computer -ne $titleDevice) { " &middot; $(Enc $computer)" }) &middot; checked $(Enc $scanTime.ToString('dddd d MMMM yyyy, HH:mm'))"

    $css = @'
:root{
  color-scheme: light;
  --page:#f9f9f7; --card:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,0.10); --wash:rgba(11,11,11,0.05);
  --s1:#2a78d6; --s2:#eb6834; --band:rgba(235,104,52,0.12);
  --good:#0ca30c; --good-ink:#006300; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b;
  --good-bg:rgba(12,163,12,0.10); --warn-bg:rgba(250,178,25,0.16); --alert-bg:rgba(208,59,59,0.10); --info-bg:rgba(42,120,214,0.10);
  --accent:#2a78d6;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    color-scheme: dark;
    --page:#0d0d0d; --card:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10); --wash:rgba(255,255,255,0.06);
    --s1:#3987e5; --s2:#d95926; --band:rgba(217,89,38,0.16);
    --good-ink:#0ca30c; --good-bg:rgba(12,163,12,0.16); --warn-bg:rgba(250,178,25,0.14); --alert-bg:rgba(208,59,59,0.18); --info-bg:rgba(57,135,229,0.16);
    --accent:#6da7ec;
  }
}
:root[data-theme="dark"]{
  color-scheme: dark;
  --page:#0d0d0d; --card:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10); --wash:rgba(255,255,255,0.06);
  --s1:#3987e5; --s2:#d95926; --band:rgba(217,89,38,0.16);
  --good-ink:#0ca30c; --good-bg:rgba(12,163,12,0.16); --warn-bg:rgba(250,178,25,0.14); --alert-bg:rgba(208,59,59,0.18); --info-bg:rgba(57,135,229,0.16);
  --accent:#6da7ec;
}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:var(--accent)}
.wrap{max-width:860px;margin:0 auto;padding:32px 16px 64px}
header h1{font-size:32px;line-height:1.2;margin:0 0 4px;letter-spacing:-0.01em}
header .tagline{font-size:18px;margin:0 0 6px}
header .sub{color:var(--ink2);margin:0 0 6px}
header nav{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:14px;margin-top:14px}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:24px;margin:18px 0}
.sec-head{display:flex;gap:14px;align-items:flex-start;margin-bottom:12px}
.sec-num{flex:none;width:32px;height:32px;border-radius:50%;background:var(--info-bg);color:var(--accent);display:flex;align-items:center;justify-content:center;font-weight:700}
h2{font-size:22px;line-height:1.3;margin:2px 0 0}
h3{font-size:17px;margin:22px 0 8px}
.aka{margin:2px 0 0;color:var(--muted);font-size:13px}
.lead{font-size:17px}
.muted{color:var(--ink2);font-size:14px}
.now{background:var(--info-bg);border-radius:10px;padding:10px 14px}
.pill{display:inline-flex;align-items:center;gap:6px;font-size:13px;font-weight:600;padding:2px 10px 2px 4px;border-radius:999px;vertical-align:middle;white-space:nowrap}
.pill-ico{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;padding:0 4px;border-radius:999px;font-size:11px;font-weight:800;color:#fff}
.pill-good{background:var(--good-bg);color:var(--good-ink)} .pill-good .pill-ico{background:var(--good)}
.pill-info{background:var(--info-bg);color:var(--ink)} .pill-info .pill-ico{background:var(--s1)}
.pill-warn{background:var(--warn-bg);color:var(--ink)} .pill-warn .pill-ico{background:var(--warning);color:#0b0b0b}
.pill-alert{background:var(--alert-bg);color:var(--ink)} .pill-alert .pill-ico{background:var(--critical)}
.glance .verdict{font-size:17px;margin:0 0 8px;display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}
.verdict-tip{margin:0 0 14px;color:var(--ink2)}
.low-note{margin:0 0 14px;padding:10px 14px;border-radius:10px;background:var(--warn-bg);border-left:4px solid var(--warning)}
.tiles{list-style:none;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.tiles li{border:1px solid var(--border);border-radius:12px;padding:14px;display:flex;flex-direction:column}
.tile-l{font-size:13px;color:var(--ink2)} .tile-v{font-size:28px;font-weight:700;line-height:1.25;margin:4px 0} .tile-s{font-size:13px;color:var(--muted)}
.gauge-row{display:flex;gap:28px;align-items:center;flex-wrap:wrap;margin:6px 0 10px}
.hero{display:flex;flex-direction:column;align-items:flex-start;gap:4px}
.hero-n{font-size:56px;font-weight:700;line-height:1}
.hero-l{color:var(--ink2);font-size:14px}
.gauge-wrap{flex:1;min-width:240px}
.gauge{position:relative;height:18px;border-radius:9px;background:var(--wash);overflow:hidden}
.gauge-fill{height:100%;border-radius:9px}
.tone-good{background:var(--good)} .tone-warn{background:var(--warning)} .tone-alert{background:var(--critical)} .tone-info{background:var(--s1)}
.gauge-mark{position:absolute;top:0;bottom:0;width:2px;background:var(--card)}
.gauge-scale{position:relative;height:20px;font-size:12px;color:var(--muted);margin-top:4px}
.gauge-scale span{position:absolute;transform:translateX(-50%)}
.gauge-scale span:first-child{transform:none} .gauge-scale span:last-child{transform:translateX(-100%)}
.gauge-note{font-size:13px;color:var(--ink2);margin:6px 0 0}
.compare{display:flex;align-items:center;gap:16px;flex-wrap:wrap;margin:16px 0;padding:14px 16px;border:1px solid var(--border);border-radius:12px}
.compare>div:not(.cmp-arrow){display:flex;flex-direction:column}
.cmp-v{font-size:24px;font-weight:700} .cmp-l{font-size:13px;color:var(--ink2);line-height:1.35} .cmp-arrow{font-size:24px;color:var(--muted)}
.facts{list-style:none;padding:0;margin:14px 0;display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.facts li{background:var(--wash);border-radius:10px;padding:10px 12px;display:flex;flex-direction:column}
.fact-v{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums} .fact-l{font-size:13px;color:var(--ink2)}
.obs{padding-left:20px} .obs li{margin:4px 0}
.legend{display:flex;gap:16px;flex-wrap:wrap;font-size:13px;color:var(--ink2);margin:4px 0 6px}
.lg{display:inline-flex;align-items:center;gap:6px}
.lg-key{display:inline-block;width:12px;height:12px;border-radius:3px}
.k-s1{background:var(--s1)} .k-s2{background:var(--s2)} .k-band{background:var(--band);border:1px solid var(--s2)}
.k-line{height:2px;width:16px;border-radius:1px;background:var(--s1)}
svg.chart{width:100%;height:auto;display:block;overflow:visible}
svg .grid{stroke:var(--grid);stroke-width:1}
svg .base{stroke:var(--axis);stroke-width:1}
svg .ax{fill:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
svg .ref{stroke:var(--ink2);stroke-width:1;stroke-dasharray:4 4}
svg .ref-l{fill:var(--ink2);font-size:12px}
svg .band{fill:var(--band)}
svg .ln{fill:none;stroke:var(--s1);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
svg .last{fill:var(--s1);stroke:var(--card);stroke-width:2}
svg .lbl{fill:var(--ink);font-size:13px;font-weight:600}
svg .s1{fill:var(--s1)} svg .s2{fill:var(--s2)}
svg .hit{fill:transparent;cursor:default}
svg .bar-hit:hover{fill:var(--wash)}
svg .hv-line{stroke:var(--axis);stroke-width:1;display:none;pointer-events:none}
svg .hv-dot{fill:var(--s1);stroke:var(--card);stroke-width:2;display:none;pointer-events:none}
#tip{position:fixed;z-index:10;display:none;pointer-events:none;background:var(--card);color:var(--ink);border:1px solid var(--border);box-shadow:0 4px 16px rgba(0,0,0,0.12);border-radius:8px;padding:8px 10px;font-size:13px;line-height:1.45;max-width:260px}
#tip .tip-title{font-weight:700;margin-bottom:2px}
details.tbl{margin-top:14px}
details.tbl summary{cursor:pointer;color:var(--accent);font-size:14px}
.tbl-wrap{overflow-x:auto;margin-top:8px}
table{border-collapse:collapse;width:100%;font-size:14px;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--grid);white-space:nowrap}
th{color:var(--ink2);font-weight:600}
.tips{display:grid;gap:12px;margin:14px 0}
.tip{border-radius:12px;padding:14px 16px;border:1px solid var(--border)}
.tip-good{background:var(--good-bg)} .tip-info{background:var(--info-bg)} .tip-warn{background:var(--warn-bg)} .tip-alert{background:var(--alert-bg)}
.tip-head{display:flex;flex-direction:column;gap:4px;align-items:flex-start}
.tip h3{margin:2px 0 0}
.tip p{margin:6px 0 0}
.gen-h{margin-top:26px}
.gen{list-style:none;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.gen li{border:1px solid var(--border);border-radius:12px;padding:12px 14px;display:flex;flex-direction:column;gap:4px;font-size:15px}
.gen li span{color:var(--ink2)}
.gloss dt{font-weight:700;margin-top:10px} .gloss dd{margin:2px 0 0;color:var(--ink2)}
footer{color:var(--muted);font-size:13px;text-align:center;margin-top:24px}
@media (max-width:560px){ .card{padding:18px} header h1{font-size:26px} .hero-n{font-size:46px} .tile-v{font-size:24px} }
@media print{ body{background:#fff} .card{break-inside:avoid} details.tbl{display:none} }
'@

    $js = @'
(function(){
  var tip=document.getElementById('tip');
  function hideHover(svg){ if(!svg) return; var l=svg.querySelector('.hv-line'), d=svg.querySelector('.hv-dot'); if(l) l.style.display='none'; if(d) d.style.display='none'; }
  function move(e){
    var x=e.clientX+14, y=e.clientY+14, r=tip.getBoundingClientRect();
    if(x+r.width>window.innerWidth-8) x=e.clientX-r.width-14;
    if(y+r.height>window.innerHeight-8) y=e.clientY-r.height-14;
    tip.style.left=Math.max(4,x)+'px'; tip.style.top=Math.max(4,y)+'px';
  }
  function show(e){
    var t=e.currentTarget, lines=(t.getAttribute('data-tip')||'').split('|');
    tip.innerHTML='';
    lines.forEach(function(l,i){ var d=document.createElement('div'); d.textContent=l; if(i===0) d.className='tip-title'; tip.appendChild(d); });
    tip.style.display='block'; move(e);
    var svg=t.ownerSVGElement;
    if(svg && t.hasAttribute('data-cx')){
      var cx=t.getAttribute('data-cx'), cy=t.getAttribute('data-cy');
      var l=svg.querySelector('.hv-line'), d=svg.querySelector('.hv-dot');
      if(l){ l.setAttribute('x1',cx); l.setAttribute('x2',cx); l.style.display='block'; }
      if(d){ d.setAttribute('cx',cx); d.setAttribute('cy',cy); d.style.display='block'; }
    }
  }
  function hide(e){ tip.style.display='none'; hideHover(e.currentTarget.ownerSVGElement); }
  Array.prototype.forEach.call(document.querySelectorAll('[data-tip]'), function(el){
    el.addEventListener('mouseenter',show); el.addEventListener('mousemove',move); el.addEventListener('mouseleave',hide);
  });
})();
'@

    $html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<title>Battery Butler</title>
<style>
$css
</style>
</head>
<body>
<div class='wrap'>
<header>
  <h1>Battery Butler</h1>
  <p class='tagline'>Your laptop battery, explained in plain English.</p>
  <p class='sub'>$subtitle</p>
  <nav><a href='#health'>Health</a><a href='#recent'>Recent use</a><a href='#drain'>Battery drain</a><a href='#history'>Usage history</a><a href='#capacity'>Wear over time</a><a href='#life'>Battery life</a><a href='#advice'>Advice</a><a href='#glossary'>Jargon buster</a></nav>
</header>
$sections
<footer>
  <p>Made from the Windows battery report (powercfg /batteryreport). Figures are Windows' own measurements and estimates, so treat them as a good guide rather than exact.</p>
  <p>$techLink</p>
</footer>
</div>
<div id='tip' role='tooltip'></div>
<script>
$js
</script>
</body>
</html>
"@

    $outFile = Join-Path $OutputFolder "Battery Butler $stamp.html"
    [IO.File]::WriteAllText($outFile, $html, (New-Object System.Text.UTF8Encoding($true)))
    if ($tempXml -and (Test-Path -LiteralPath $tempXml)) { Remove-Item -LiteralPath $tempXml -Force }

    Write-Host ''
    Write-Host '  Done! Your battery summary has been saved to:' -ForegroundColor Green
    Write-Host "  $outFile"
    Write-Host ''
    if (-not $NoOpen) { Start-Process -FilePath $outFile }
    if ($Interactive) { Start-Sleep -Seconds 3 }
    exit 0
}
catch {
    Write-Host ''
    Write-Host '  Sorry - something went wrong while checking the battery.' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (line $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor DarkGray
    Write-Host ''
    if ($Interactive) { Read-Host '  Press Enter to close' | Out-Null }
    exit 1
}
