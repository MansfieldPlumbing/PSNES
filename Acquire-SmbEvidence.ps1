#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RomPath = (Join-Path $PSScriptRoot 'ROMS\Super Mario Bros. + Duck Hunt (USA).nes'),
    [string] $OutputDir = (Join-Path $PSScriptRoot 'evidence\smb_native_001'),
    [string] $CompiledDll = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RomPath)) {
    throw "ROM not found at '$RomPath'. Provide -RomPath to a valid Super Mario Bros. + Duck Hunt (USA) iNES image."
}

$romSha256 = (Get-FileHash -Path $RomPath -Algorithm SHA256).Hash
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if ($CompiledDll -and (Test-Path $CompiledDll)) {
    Add-Type -Path $CompiledDll
} else {
    . (Join-Path $PSScriptRoot 'PSNES.ps1')
}

function Write-PsnesObservations {
    param([string] $Path, [NesObservation[]] $Observations)
    $fs = [IO.File]::Create($Path)
    $bw = [IO.BinaryWriter]::new($fs)
    try {
        $bw.Write([byte[]]@(0x50, 0x53, 0x4E, 0x31))
        $bw.Write([int]$Observations.Length)
        foreach ($o in $Observations) {
            $bw.Write([int]$o.FrameIndex)
            $bw.Write([long]$o.TotalDots)
            $bw.Write([long]$o.TotalCycles)
            $bw.Write([int]$o.A); $bw.Write([int]$o.X); $bw.Write([int]$o.Y); $bw.Write([int]$o.SP); $bw.Write([int]$o.PC)
            $bw.Write([byte]$o.Ctrl); $bw.Write([byte]$o.Mask); $bw.Write([byte]$o.Status)
            $bw.Write([byte]$o.ScrollX); $bw.Write([byte]$o.ScrollY); $bw.Write([ushort]$o.VramAddr); $bw.Write([byte]$o.FineX)
            $bw.Write([byte]$o.Controller1); $bw.Write([byte]$o.Controller2)
            $bw.Write($o.Ram)
            $bw.Write($o.Oam)
            $bw.Write($o.Vram)
            $bw.Write($o.Palette)
            $bw.Write($o.Pixels)
            [int] $psLen = ($null -ne $o.PixelSource) ? $o.PixelSource.Length : 0
            $bw.Write($psLen)
            for ($i = 0; $i -lt $psLen; $i++) { $bw.Write($o.PixelSource[$i]) }
        }
    } finally {
        $bw.Dispose(); $fs.Dispose()
    }
}

function Read-PsnesObservations {
    param([string] $Path)
    $fs = [IO.File]::OpenRead($Path)
    $br = [IO.BinaryReader]::new($fs)
    try {
        $magic = $br.ReadBytes(4)
        if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x53 -or $magic[2] -ne 0x4E -or $magic[3] -ne 0x31) {
            throw "Invalid psnesobs magic in $Path"
        }
        [int] $count = $br.ReadInt32()
        $list = [NesObservation[]]::new($count)
        for ($idx = 0; $idx -lt $count; $idx++) {
            $o = [NesObservation]::new()
            $o.FrameIndex = $br.ReadInt32()
            $o.TotalDots = $br.ReadInt64()
            $o.TotalCycles = $br.ReadInt64()
            $o.A = $br.ReadInt32(); $o.X = $br.ReadInt32(); $o.Y = $br.ReadInt32(); $o.SP = $br.ReadInt32(); $o.PC = $br.ReadInt32()
            $o.Ctrl = $br.ReadByte(); $o.Mask = $br.ReadByte(); $o.Status = $br.ReadByte()
            $o.ScrollX = $br.ReadByte(); $o.ScrollY = $br.ReadByte(); $o.VramAddr = $br.ReadUInt16(); $o.FineX = $br.ReadByte()
            $o.Controller1 = $br.ReadByte(); $o.Controller2 = $br.ReadByte()
            $o.Ram = $br.ReadBytes(2048)
            $o.Oam = $br.ReadBytes(256)
            $o.Vram = $br.ReadBytes(4096)
            $o.Palette = $br.ReadBytes(32)
            $o.Pixels = $br.ReadBytes(61440)
            [int] $psLen = $br.ReadInt32()
            if ($psLen -gt 0) {
                $o.PixelSource = [int[]]::new($psLen)
                for ($i = 0; $i -lt $psLen; $i++) { $o.PixelSource[$i] = $br.ReadInt32() }
            }
            $list[$idx] = $o
        }
        return $list
    } finally {
        $br.Dispose(); $fs.Dispose()
    }
}

function Invoke-SmbTrajectory {
    param([string] $Path, [byte[]] $Inputs, [int] $RecordFromFrame)
    $nes = [Nes]::new()
    if (-not $nes.Rom.Load($Path)) { throw "Failed to load ROM: $Path" }
    $nes.PowerOn()
    $nes.Ppu.RecordPixelSource = $true
    $observations = [Collections.Generic.List[NesObservation]]::new()
    $snapAt200 = $null
    for ([int] $f = 0; $f -lt $Inputs.Length; $f++) {
        $nes.Memory.SetControllerState($Inputs[$f], 0)
        $nes.RunFrame()
        if ($f -ge $RecordFromFrame) {
            $observations.Add($nes.CaptureObservation($f))
        }
        if ($f -eq 200) {
            $snapAt200 = $nes.CaptureSnapshot()
        }
    }
    return [pscustomobject]@{
        Nes          = $nes
        Observations = $observations.ToArray()
        Snapshot200  = $snapAt200
    }
}

# Primary PSNES-native trajectory: Start at 40-41, Right (0x80) from 150..299, Jump (0x81) at 210..224
[byte[]] $primaryInputs = [byte[]]::new(300)
$primaryInputs[40] = 0x08; $primaryInputs[41] = 0x08
for ($f = 150; $f -lt 300; $f++) {
    $primaryInputs[$f] = ($f -ge 210 -and $f -le 224) ? [byte]0x81 : [byte]0x80
}

$primary = Invoke-SmbTrajectory -Path $RomPath -Inputs $primaryInputs -RecordFromFrame 150

# Branch A (identical continuation from frame 200 for 40 frames)
$branchA = $primary.Nes.Branch($primary.Snapshot200)
$branchA.Ppu.RecordPixelSource = $true
$branchAObs = [Collections.Generic.List[NesObservation]]::new()
for ($f = 201; $f -le 240; $f++) {
    $branchA.Memory.SetControllerState($primaryInputs[$f], 0)
    $branchA.RunFrame()
    $branchAObs.Add($branchA.CaptureObservation($f))
}

# Branch B (divergent Left=0x40 continuation from frame 200 for 40 frames)
$branchB = $primary.Nes.Branch($primary.Snapshot200)
$branchB.Ppu.RecordPixelSource = $true
$branchBObs = [Collections.Generic.List[NesObservation]]::new()
for ($f = 201; $f -le 240; $f++) {
    $branchB.Memory.SetControllerState(0x40, 0)
    $branchB.RunFrame()
    $branchBObs.Add($branchB.CaptureObservation($f))
}

# Withheld trajectory: Right+B dash (0x82) from frame 150..239
[byte[]] $withheldInputs = [byte[]]::new(240)
$withheldInputs[40] = 0x08; $withheldInputs[41] = 0x08
for ($f = 150; $f -lt 240; $f++) { $withheldInputs[$f] = 0x82 }
$withheld = Invoke-SmbTrajectory -Path $RomPath -Inputs $withheldInputs -RecordFromFrame 150

# Byte-exact equality check across all 40 corresponding frames (201..240) of Primary vs Branch A
[bool] $byteExact = $true
for ($i = 0; $i -lt 40; $i++) {
    $o1 = $primary.Observations[(201 - 150) + $i]
    $o2 = $branchAObs[$i]
    if ($o1.TotalDots -ne $o2.TotalDots -or $o1.TotalCycles -ne $o2.TotalCycles) { $byteExact = $false; break }
    if ([Linq.Enumerable]::SequenceEqual($o1.Ram, $o2.Ram) -eq $false -or
        [Linq.Enumerable]::SequenceEqual($o1.Oam, $o2.Oam) -eq $false -or
        [Linq.Enumerable]::SequenceEqual($o1.Pixels, $o2.Pixels) -eq $false -or
        [Linq.Enumerable]::SequenceEqual($o1.PixelSource, $o2.PixelSource) -eq $false) {
        $byteExact = $false; break
    }
}
if (-not $byteExact) { throw 'Branch A failed byte-exact continuation equality!' }

# Persist all 320 observations in compact typed binary format
$pPath = Join-Path $OutputDir 'primary.psnesobs'
$wPath = Join-Path $OutputDir 'withheld.psnesobs'
$aPath = Join-Path $OutputDir 'branch_a.psnesobs'
$bPath = Join-Path $OutputDir 'branch_b.psnesobs'
Write-PsnesObservations -Path $pPath -Observations $primary.Observations
Write-PsnesObservations -Path $wPath -Observations $withheld.Observations
Write-PsnesObservations -Path $aPath -Observations $branchAObs.ToArray()
Write-PsnesObservations -Path $bPath -Observations $branchBObs.ToArray()

# Verify round-trip read
$rt = Read-PsnesObservations -Path $pPath
if ($rt.Length -ne 150 -or -not [Linq.Enumerable]::SequenceEqual($rt[90].Pixels, $primary.Observations[90].Pixels)) {
    throw 'Round-trip Read-PsnesObservations verification failed!'
}

# Visual variation stats on frame 240
$orig240 = $primary.Observations[240 - 150]
$bB240   = $branchBObs[39]
$distinctColors = @($orig240.Pixels | Select-Object -Unique).Count
[int] $bgCount = 0; [int] $sprCount = 0; [int] $univCount = 0
foreach ($ps in $orig240.PixelSource) {
    $kind = $ps -band 0x30000000
    if ($kind -eq 0x10000000) { $bgCount++ }
    elseif ($kind -eq 0x20000000) { $sprCount++ }
    else { $univCount++ }
}
[int] $diffPixels = 0
for ($i = 0; $i -lt 61440; $i++) { if ($orig240.Pixels[$i] -ne $bB240.Pixels[$i]) { $diffPixels++ } }

$manifest = [pscustomobject]@{
    TrajectoryType     = 'PSNES-native controller trajectory (not a synchronized FM2/BK2 replay)'
    PsnesCommit        = (git -C $PSScriptRoot rev-parse --short HEAD)
    RomSha256          = $romSha256
    ByteExactBranchA   = $byteExact
    Frame240DistinctColors = $distinctColors
    Frame240PixelSource    = "univ=$univCount, bg=$bgCount, spr=$sprCount"
    OrigVsBranchBDiffPx    = $diffPixels
    PrimarySha256      = (Get-FileHash $pPath -Algorithm SHA256).Hash
    WithheldSha256     = (Get-FileHash $wPath -Algorithm SHA256).Hash
    BranchASha256      = (Get-FileHash $aPath -Algorithm SHA256).Hash
    BranchBSha256      = (Get-FileHash $bPath -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDir 'manifest.json') -Encoding UTF8
$manifest | Format-List
