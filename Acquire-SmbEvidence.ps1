#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RomPath = (Join-Path $PSScriptRoot 'ROMS\Super Mario Bros. + Duck Hunt (USA).nes'),
    [string] $OutputDir = (Join-Path $PSScriptRoot 'evidence\smb_native_001')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RomPath)) {
    throw "ROM not found at '$RomPath'. Provide -RomPath to a valid Super Mario Bros. + Duck Hunt (USA) iNES image."
}

$romSha256 = (Get-FileHash -Path $RomPath -Algorithm SHA256).Hash
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

. (Join-Path $PSScriptRoot 'PSNES.ps1')

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

$orig240 = $primary.Observations[240 - 150]
$bA240   = $branchAObs[39]
$bB240   = $branchBObs[39]

$summary = [pscustomobject]@{
    TrajectoryType       = 'PSNES-native controller trajectory (not a synchronized FM2/BK2 replay)'
    RomSha256            = $romSha256
    PrimaryFrameCount    = $primary.Observations.Length
    WithheldFrameCount   = $withheld.Observations.Length
    BranchPointFrame     = 200
    Orig240RamChecksum   = [PsnesBench]::Checksum($orig240.Ram).ToString('X16')
    BranchA240RamChecksum = [PsnesBench]::Checksum($bA240.Ram).ToString('X16')
    Orig240FbChecksum    = [PsnesBench]::Checksum($orig240.Pixels).ToString('X16')
    BranchA240FbChecksum = [PsnesBench]::Checksum($bA240.Pixels).ToString('X16')
    BranchB240RamChecksum = [PsnesBench]::Checksum($bB240.Ram).ToString('X16')
    BranchB240FbChecksum = [PsnesBench]::Checksum($bB240.Pixels).ToString('X16')
    Orig240ScrollX       = $orig240.ScrollX
    BranchA240ScrollX    = $bA240.ScrollX
    BranchB240ScrollX    = $bB240.ScrollX
}

$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDir 'summary.json') -Encoding UTF8
[IO.File]::WriteAllBytes((Join-Path $OutputDir 'primary_inputs.bin'), $primaryInputs)
[IO.File]::WriteAllBytes((Join-Path $OutputDir 'withheld_inputs.bin'), $withheldInputs)
[IO.File]::WriteAllBytes((Join-Path $OutputDir 'orig_240_pixels.bin'), $orig240.Pixels)
[IO.File]::WriteAllBytes((Join-Path $OutputDir 'branch_b_240_pixels.bin'), $bB240.Pixels)
[IO.File]::WriteAllBytes((Join-Path $OutputDir 'orig_240_oam.bin'), $orig240.Oam)
[IO.File]::WriteAllBytes((Join-Path $OutputDir 'branch_b_240_oam.bin'), $bB240.Oam)

$summary | Format-List
