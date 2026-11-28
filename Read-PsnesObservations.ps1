#requires -Version 7.0
param(
    [string] $CompiledDll = ''
)

if ($CompiledDll -and (Test-Path $CompiledDll)) {
    Add-Type -Path $CompiledDll
} elseif (-not ('NesObservation' -as [type])) {
    . (Join-Path $PSScriptRoot 'PSNES.ps1')
}

function Read-PsnesObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
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
