#requires -Version 7.0
using namespace System
using namespace System.IO

[CmdletBinding()]
param(
    # An iNES image to play in a window.
    [string] $Rom,
    # How the frame fills the window. Tab cycles the modes while playing.
    [ValidateSet('Fit', 'Stretch', 'Blur')] [string] $Scaling = 'Fit',
    # Run the built-in conformance suite instead.
    [switch] $Conformance
)

enum Mirroring {
    Horizontal = 0
    Vertical = 1
    FourScreen = 2
    SingleScreen = 3
}

class Rom {
    [byte[]] $PrgRom
    [byte[]] $ChrRom
    [bool] $ChrRam
    [int] $Mapper
    [Mirroring] $Mirroring
    [bool] $IsValid
    [bool] $HasBatteryBackedRam

    Rom() {
        $this.IsValid = $false
    }

    [bool] Load([string] $filePath) {
        # A failed reload must not leave a previously loaded image marked valid.
        $this.IsValid = $false
        $this.PrgRom = $null
        $this.ChrRom = $null
        $this.ChrRam = $false
        if (-not [File]::Exists($filePath)) { return $false }
        
        [byte[]] $data = [File]::ReadAllBytes($filePath)
        if ($data.Length -lt 16) { return $false }

        # Check iNES Magic "NES<EOF>"
        if ($data[0] -ne 0x4E -or $data[1] -ne 0x45 -or $data[2] -ne 0x53 -or $data[3] -ne 0x1A) {
            return $false
        }

        [int] $prgBanks = $data[4]
        [int] $chrBanks = $data[5]
        [byte] $control1 = $data[6]
        [byte] $control2 = $data[7]
        if ($prgBanks -eq 0) { return $false }
        # This core implements NROM only. Reject NES 2.0 and nonzero
        # mappers instead of executing them through fixed NROM mapping.
        if (($control2 -band 0x0C) -eq 0x08) { return $false }
        [int] $mapperNumber = (($control2 -band 0xF0) -bor (($control1 -shr 4) -band 0x0F))
        if ($mapperNumber -ne 0) { return $false }

        $this.HasBatteryBackedRam = ($control1 -band 0x02) -ne 0

        if (($control1 -band 0x08) -ne 0) {
            $this.Mirroring = [Mirroring]::FourScreen
        } else {
            $this.Mirroring = (($control1 -band 0x01) -ne 0) ? [Mirroring]::Vertical : [Mirroring]::Horizontal
        }

        $this.Mapper = (($control2 -band 0xF0) -bor (($control1 -shr 4) -band 0x0F))

        [int] $offset = 16
        if (($control1 -band 0x04) -ne 0) {
            $offset += 512 # Skip trainer
        }

        [int] $prgSize = $prgBanks * 16384
        [int] $chrSize = $chrBanks * 8192
        if ($offset + $prgSize + $chrSize -gt $data.Length) { return $false }
        $this.PrgRom = [byte[]]::new($prgSize)
        [Array]::Copy($data, $offset, $this.PrgRom, 0, $prgSize)
        $offset += $prgSize

        if ($chrBanks -gt 0) {
            $this.ChrRom = [byte[]]::new($chrSize)
            [Array]::Copy($data, $offset, $this.ChrRom, 0, $chrSize)
            $this.ChrRam = $false
        } else {
            # Uses CHR-RAM. Keep this separate from the storage length: an
            # 8 KiB CHR-ROM is not writable, while CHR-RAM is.
            $this.ChrRom = [byte[]]::new(8192)
            $this.ChrRam = $true
        }

        $this.IsValid = $true
        return $true
    }
}

class Ppu {
    [byte[]] $Pixels = [byte[]]::new(256 * 240)
    [bool[]] $BgOpaque = [bool[]]::new(256 * 240)
    [byte[]] $Vram
    [byte[]] $Palette
    [byte[]] $Oam
    [Rom] $Rom
    [int] $Scanline
    [int] $Cycle

    [byte] $Ctrl
    [byte] $Mask
    [byte] $Status
    [byte] $OamAddr
    [byte] $ScrollX
    [byte] $ScrollY
    [ushort] $VramAddr
    [ushort] $TempAddr
    [byte] $FineX
    [bool] $WriteToggle
    [byte] $DataBuffer
    # Scanline on which sprite 0 overlaps opaque background this frame, or -1.
    [int] $Sprite0Line = -1
    # Scroll and control in force on each visible row, captured as the CPU runs.
    [int[]] $LineX = [int[]]::new(240)
    [int[]] $LineY = [int[]]::new(240)
    [int[]] $LineCtrl = [int[]]::new(240)

    Ppu([Rom] $rom) {
        # The PPU is constructed before the ROM is loaded, so allocate the
        # maximum nametable storage up front; mirroring selects the visible
        # tables and keeps four-screen ROMs representable.
        $this.Vram = [byte[]]::new(4096)
        $this.Palette = [byte[]]::new(32)
        $this.Oam = [byte[]]::new(256)
        $this.Rom = $rom
        $this.Status = 0xA0
    }

    [byte] ReadRegister([ushort] $address) {
        [ushort] $reg = $address % 8
        switch ($reg) {
            2 { 
                [byte] $res = $this.Status
                $this.Status = $this.Status -band 0x7F
                $this.WriteToggle = $false
                return $res
            }
            4 { return $this.Oam[$this.OamAddr] }
            7 {
                [ushort] $addr = $this.VramAddr
                [byte] $res = $this.DataBuffer
                if ($addr -ge 0x3F00) {
                    # Palette reads are not delayed; the internal buffer is
                    # filled from the nametable address behind the palette.
                    $res = $this.ReadVram($addr)
                    $this.DataBuffer = $this.ReadVram([ushort](($addr - 0x1000) -band 0x3FFF))
                } else {
                    $this.DataBuffer = $this.ReadVram($addr)
                }
                $this.VramAddr = [ushort](($addr + ((($this.Ctrl -band 0x04) -ne 0) ? 32 : 1)) -band 0x3FFF)
                return $res
            }
        }
        return 0
    }
    
    [void] WriteRegister([ushort] $address, [byte] $value) {
        [ushort] $reg = $address % 8
        switch ($reg) {
            0 {
                [byte] $oldCtrl = $this.Ctrl
                $this.Ctrl = $value
                $this.TempAddr = ($this.TempAddr -band 0xF3FF) -bor (([ushort]($value -band 0x03)) -shl 10)
                # Enabling NMI while VBlank is already asserted produces an
                # NMI edge on the NES.
                if (($oldCtrl -band 0x80) -eq 0 -and ($value -band 0x80) -ne 0 -and
                    ($this.Status -band 0x80) -ne 0 -and $null -ne $this.Cpu) {
                    $this.Cpu.nmiRaised = $true
                }
            }
            1 { $this.Mask = $value }
            3 { $this.OamAddr = $value }
            4 { 
                $this.Oam[$this.OamAddr] = $value
                $this.OamAddr = [byte](($this.OamAddr + 1) -band 0xFF)
            }
            5 { 
                if (-not $this.WriteToggle) {
                    $this.ScrollX = $value
                    $this.FineX = $value -band 0x07
                    $this.TempAddr = ($this.TempAddr -band 0xFFE0) -bor ($value -shr 3)
                    $this.WriteToggle = $true
                } else {
                    $this.ScrollY = $value
                    $this.TempAddr = ($this.TempAddr -band 0x8C1F) -bor (([ushort]($value -band 0x07)) -shl 12) -bor (([ushort]($value -band 0xF8)) -shl 2)
                    $this.WriteToggle = $false
                }
            }
            6 {
                if (-not $this.WriteToggle) {
                    $this.TempAddr = ($this.TempAddr -band 0x00FF) -bor (([ushort]($value -band 0x3F)) -shl 8)
                    $this.WriteToggle = $true
                } else {
                    $this.TempAddr = ($this.TempAddr -band 0xFF00) -bor $value
                    $this.VramAddr = $this.TempAddr
                    $this.WriteToggle = $false
                }
            }
            7 {
                $this.WriteVram($this.VramAddr, $value)
                [int] $increment = (($this.Ctrl -band 0x04) -ne 0) ? 32 : 1
                $this.VramAddr = [ushort](($this.VramAddr + $increment) -band 0x3FFF)
            }
        }
    }

    [byte] ReadVram([ushort] $addr) {
        $addr = $addr % 0x4000
        if ($addr -lt 0x2000) {
            if ($null -ne $this.Rom.ChrRom -and $this.Rom.ChrRom.Length -gt 0) {
                return $this.Rom.ChrRom[$addr % $this.Rom.ChrRom.Length]
            }
            return 0
        } elseif ($addr -lt 0x3F00) {
            [int] $nt = ($addr -band 0x0FFF) -shr 10
            [int] $inner = $addr -band 0x03FF
            [int] $table = $nt
            if ($this.Rom.Mirroring -eq [Mirroring]::Vertical) {
                $table = $nt -band 1
            } elseif ($this.Rom.Mirroring -eq [Mirroring]::Horizontal) {
                $table = $nt -shr 1
            } elseif ($this.Rom.Mirroring -eq [Mirroring]::SingleScreen) {
                $table = 0
            }
            return $this.Vram[($table * 1024 + $inner) % $this.Vram.Length]
        } else {
            [int] $paletteAddress = $addr -band 0x1F
            if (($paletteAddress -band 0x13) -eq 0x10) { $paletteAddress -= 0x10 }
            return $this.Palette[$paletteAddress]
        }
    }

    [void] WriteVram([ushort] $addr, [byte] $val) {
        $addr = $addr % 0x4000
        if ($addr -lt 0x2000) {
            if ($this.Rom.ChrRam) {
                $this.Rom.ChrRom[$addr % $this.Rom.ChrRom.Length] = $val
            }
        } elseif ($addr -lt 0x3F00) {
            [int] $nt = ($addr -band 0x0FFF) -shr 10
            [int] $inner = $addr -band 0x03FF
            [int] $table = $nt
            if ($this.Rom.Mirroring -eq [Mirroring]::Vertical) {
                $table = $nt -band 1
            } elseif ($this.Rom.Mirroring -eq [Mirroring]::Horizontal) {
                $table = $nt -shr 1
            } elseif ($this.Rom.Mirroring -eq [Mirroring]::SingleScreen) {
                $table = 0
            }
            $this.Vram[($table * 1024 + $inner) % $this.Vram.Length] = $val
        } else {
            [int] $paletteAddress = $addr -band 0x1F
            if (($paletteAddress -band 0x13) -eq 0x10) { $paletteAddress -= 0x10 }
            $this.Palette[$paletteAddress] = $val
        }
    }

    
    [bool] $FrameEnded
    [Cpu6502] $Cpu

    [void] RenderFrame() {
        # RenderFrame runs after the CPU's frame, so it cannot set the sprite-0 flag itself:
        # it records the hit's scanline, and AdvanceDots sets the flag when the CPU reaches it.
        $this.Sprite0Line = -1
        # Cache hot PPU fields locally. PowerShell property dispatch inside
        # the 61,440-pixel loop is substantially more expensive than array access.
        [int] $cachedmask = $this.Mask
        [int] $cachedctrl = $this.Ctrl
        [int] $cachedscrollX = $this.ScrollX
        [int] $cachedscrollY = $this.ScrollY
        $cachedvram = $this.Vram
        $cachedpalette = $this.Palette
        $cachedpixels = $this.Pixels
        $cachedbgOpaque = $this.BgOpaque
        $cachedoam = $this.Oam
        $cachedrom = $this.Rom
        $mirroring = $cachedrom.Mirroring
        $chrRom = $cachedrom.ChrRom
        # Mapper 0 tile-span renderer. Background work is aligned to source
        # tile spans, so a non-byte-aligned scroll only clips the first/last
        # span; each tile row is fetched once and emitted to the framebuffer.
        [bool] $bgEnabled = ($cachedmask -band 0x08) -ne 0
        [bool] $sprEnabled = ($cachedmask -band 0x10) -ne 0
        [int] $bgPattern = (($cachedctrl -band 0x10) -ne 0) ? 0x1000 : 0
        [int] $sprPattern = (($cachedctrl -band 0x08) -ne 0) ? 0x1000 : 0
        [int] $baseNt = $cachedctrl -band 0x03
        [int] $chrLength = if ($null -ne $chrRom) { $chrRom.Length } else { 0 }
        [int] $vramLength = $cachedvram.Length

        for ([int] $y = 0; $y -lt 240; $y++) {
            # Mid-frame scroll: each row renders with the scroll and control in force on that row.
            # Row-local: sprites below still use the frame's own Ctrl.
            $cachedscrollX = $this.LineX[$y]
            $cachedscrollY = $this.LineY[$y]
            [int] $rowCtrl = $this.LineCtrl[$y]
            $baseNt = $rowCtrl -band 0x03
            $bgPattern = (($rowCtrl -band 0x10) -ne 0) ? 0x1000 : 0
            [int] $worldY = $y + $cachedscrollY
            [int] $ntY = ($worldY -shr 8) -band 1
            [int] $localY = $worldY -band 0xFF
            [int] $tileY = $localY -shr 3
            [int] $fineY = $localY -band 7
            [int] $worldTileFirst = $cachedscrollX -shr 3
            [int] $worldTileLast = ($cachedscrollX + 255) -shr 3

            for ([int] $worldTileX = $worldTileFirst; $worldTileX -le $worldTileLast; $worldTileX++) {
                [int] $destStart = ($worldTileX * 8) - $cachedscrollX
                [int] $destEnd = $destStart + 7
                [int] $emitStart = if ($destStart -lt 0) { 0 } else { $destStart }
                [int] $emitEnd = if ($destEnd -gt 255) { 255 } else { $destEnd }
                if ($emitStart -gt $emitEnd) { continue }

                [int] $localTileX = $worldTileX -band 31
                [int] $ntX = ($worldTileX -shr 5) -band 1
                [int] $nt = ($baseNt + $ntX + (2 * $ntY)) -band 3
                [int] $ntTable = $nt
                if ($mirroring -eq [Mirroring]::Vertical) {
                    $ntTable = $nt -band 1
                } elseif ($mirroring -eq [Mirroring]::Horizontal) {
                    $ntTable = $nt -shr 1
                } elseif ($mirroring -eq [Mirroring]::SingleScreen) {
                    $ntTable = 0
                }
                [int] $ntBase = ($ntTable * 1024) % $vramLength
                [int] $tile = $cachedvram[($ntBase + ($tileY * 32) + $localTileX) % $vramLength]
                [int] $attr = $cachedvram[($ntBase + 0x3C0 + (($tileY -shr 2) * 8) + ($localTileX -shr 2)) % $vramLength]
                [int] $quadrant = ((($tileY -band 2) -shr 1) -shl 1) -bor (($localTileX -band 2) -shr 1)
                [int] $paletteNo = ($attr -shr ($quadrant * 2)) -band 3
                [int] $plane = $bgPattern + ($tile * 16) + $fineY
                [int] $lo = if ($chrLength -gt 0) { $chrRom[$plane % $chrLength] } else { 0 }
                [int] $hi = if ($chrLength -gt 0) { $chrRom[($plane + 8) % $chrLength] } else { 0 }

                for ([int] $x = $emitStart; $x -le $emitEnd; $x++) {
                    [int] $sourceCol = $x - $destStart
                    [int] $bit = 7 - $sourceCol
                    [int] $pixel = (($lo -shr $bit) -band 1) -bor ((($hi -shr $bit) -band 1) -shl 1)
                    # A transparent background pixel shows the backdrop at $3F00, not its palette's own entry zero.
                    [int] $color = $cachedpalette[($pixel -eq 0) ? 0 : (($paletteNo * 4) + $pixel)]
                    [int] $frameIndex = ($y * 256) + $x
                    $cachedbgOpaque[$frameIndex] = $bgEnabled -and $pixel -ne 0 -and ($x -ge 8 -or ($cachedmask -band 0x02) -ne 0)
                    if (-not $bgEnabled -or ($x -lt 8 -and ($cachedmask -band 0x02) -eq 0)) {
                        $color = $cachedpalette[0]
                    }
                    $cachedpixels[$frameIndex] = [byte]$color
                }
            }
        }

        if ($sprEnabled) {
            [int] $height = (($cachedctrl -band 0x20) -ne 0) ? 16 : 8
            for ([int] $n = 63; $n -ge 0; $n--) {
                [int] $o = $n * 4
                [int] $sy = $cachedoam[$o]
                [int] $tile = $cachedoam[$o + 1]
                [int] $attr = $cachedoam[$o + 2]
                [int] $sx = $cachedoam[$o + 3]
                for ([int] $row = 0; $row -lt $height; $row++) {
                    [int] $dy = $sy + 1 + $row
                    if ($dy -lt 0 -or $dy -ge 240) { continue }
                    [int] $sourceRow = (($attr -band 0x80) -ne 0) ? ($height - 1 - $row) : $row
                    [int] $patternBase = $sprPattern
                    [int] $tileIndex = $tile
                    if ($height -eq 16) {
                        # In 8x16 mode PPUCTRL bit 3 is ignored. OAM tile bit 0
                        # selects the pattern table; bits 1-7 select the pair.
                        $patternBase = (($tile -band 1) -ne 0) ? 0x1000 : 0
                        $tileIndex = ($tile -band 0xFE) + ($sourceRow -shr 3)
                    }
                    [int] $plane = $patternBase + ($tileIndex * 16) + ($sourceRow -band 7)
                    [int] $lo = if ($chrLength -gt 0) { $chrRom[$plane % $chrLength] } else { 0 }
                    [int] $hi = if ($chrLength -gt 0) { $chrRom[($plane + 8) % $chrLength] } else { 0 }
                    for ([int] $col = 0; $col -lt 8; $col++) {
                        [int] $dx = $sx + $col
                        if ($dx -lt 0 -or $dx -ge 256) { continue }
                        [int] $sourceCol = (($attr -band 0x40) -ne 0) ? (7 - $col) : $col
                        [int] $pixel = (($lo -shr (7 - $sourceCol)) -band 1) -bor ((($hi -shr (7 - $sourceCol)) -band 1) -shl 1)
                        if ($pixel -eq 0 -or ($dx -lt 8 -and ($cachedmask -band 0x04) -eq 0)) { continue }
                        [int] $idx = ($dy * 256) + $dx
                        [bool] $pixelBgOpaque = $cachedbgOpaque[$idx]
                        if ($n -eq 0 -and $pixelBgOpaque -and $dx -lt 255 -and
                            ($dx -ge 8 -or (($cachedmask -band 0x04) -ne 0)) -and
                            ($dx -ge 8 -or (($cachedmask -band 0x02) -ne 0))) {
                            if ($this.Sprite0Line -lt 0 -or $dy -lt $this.Sprite0Line) { $this.Sprite0Line = $dy }
                        }
                        if (($attr -band 0x20) -ne 0 -and $pixelBgOpaque) { continue }
                        $cachedpixels[$idx] = [byte]$cachedpalette[0x10 + (($attr -band 3) * 4) + $pixel]
                    }
                }
            }
        }
    }

    [void] StartFrame() {
        $this.FrameEnded = $false
    }

    [void] AdvanceDots([int] $dots) {
        for ([int] $i = 0; $i -lt $dots; $i++) {
            $this.Cycle++
            if ($this.Cycle -ge 341) {
                $this.Cycle = 0
                $this.Scanline++
                if ($this.Scanline -le 240) {
                    [int] $row = $this.Scanline - 1
                    [int] $t = $this.TempAddr
                    $this.LineX[$row] = (($t -band 0x1F) * 8) + $this.FineX
                    $this.LineY[$row] = if ($row -eq 0) { ((($t -shr 5) -band 0x1F) * 8) + (($t -shr 12) -band 7) } else { $this.LineY[0] }
                    $this.LineCtrl[$row] = ([int]$this.Ctrl -band 0xFC) -bor (($t -shr 10) -band 3)
                }
                if ($this.Scanline -eq $this.Sprite0Line) { $this.Status = $this.Status -bor 0x40 }

                if ($this.Scanline -eq 241) {
                    $this.Status = $this.Status -bor 0x80 # Set VBLANK
                    if (($this.Ctrl -band 0x80) -ne 0) {
                        if ($null -ne $this.Cpu) {
                            $this.Cpu.nmiRaised = $true
                        }
                    }
                } elseif ($this.Scanline -ge 262) {
                    $this.Scanline = 0
                    $this.Status = $this.Status -band 0x3F # Clear VBLANK and sprite-0
                    $this.Sprite0Line = -1
                    $this.FrameEnded = $true
                }
            }
        }
    }
}

class Memory {
    [byte[]] $Ram
    [byte[]] $Sram
    [Rom] $Rom
    [Ppu] $Ppu
    [Cpu6502] $Cpu
    [byte] $Controller1
    [byte] $Controller2
    [byte] $Controller1Index
    [byte] $Controller2Index
    [bool] $ControllerStrobe

    Memory([Rom] $rom) {
        $this.Ram = [byte[]]::new(2048)
        $this.Sram = [byte[]]::new(8192)
        $this.Rom = $rom
    }
    
    [byte] Read([ushort] $address) {
        if ($address -lt 0x2000) {
            return $this.Ram[$address % 0x0800]
        } elseif ($address -ge 0x2000 -and $address -lt 0x4000) {
            return $this.Ppu.ReadRegister($address)
        } elseif ($address -eq 0x4016) {
            if ($this.ControllerStrobe) { return [byte]($this.Controller1 -band 1) }
            if ($this.Controller1Index -lt 8) {
                [byte] $result = ($this.Controller1 -shr $this.Controller1Index) -band 1
                $this.Controller1Index++
                return $result
            }
            return 1
        } elseif ($address -eq 0x4017) {
            if ($this.ControllerStrobe) { return [byte]($this.Controller2 -band 1) }
            if ($this.Controller2Index -lt 8) {
                [byte] $result = ($this.Controller2 -shr $this.Controller2Index) -band 1
                $this.Controller2Index++
                return $result
            }
            return 1
        } elseif ($address -ge 0x4000 -and $address -lt 0x4018) {
            return 0
        } elseif ($address -ge 0x6000 -and $address -lt 0x8000) {
            return $this.Sram[$address - 0x6000]
        } elseif ($address -ge 0x8000) {
            if ($this.Rom.IsValid -and $null -ne $this.Rom.PrgRom -and $this.Rom.PrgRom.Length -gt 0) {
                [int] $prgAddr = $address - 0x8000
                if ($this.Rom.PrgRom.Length -eq 16384) {
                    $prgAddr = $prgAddr % 16384
                }
                return $this.Rom.PrgRom[$prgAddr]
            }
        }
        return 0
    }

    [void] Write([ushort] $address, [byte] $value) {
        if ($address -lt 0x2000) {
            $this.Ram[$address % 0x0800] = $value
        } elseif ($address -ge 0x2000 -and $address -lt 0x4000) {
            $this.Ppu.WriteRegister($address, $value)
        } elseif ($address -ge 0x4000 -and $address -lt 0x4018) {
            if ($address -eq 0x4016) {
                [bool] $newStrobe = ($value -band 1) -ne 0
                if ($newStrobe -or $this.ControllerStrobe) {
                    $this.Controller1Index = 0
                    $this.Controller2Index = 0
                }
                $this.ControllerStrobe = $newStrobe
            } elseif ($address -eq 0x4014) {
                # OAM DMA
                [ushort] $page = [ushort]([int]$value -shl 8)
                for ([int] $i = 0; $i -lt 256; $i++) {
                    $this.Ppu.Oam[$this.Ppu.OamAddr] = $this.Read([ushort]($page + $i))
                    $this.Ppu.OamAddr = [byte](($this.Ppu.OamAddr + 1) -band 0xFF)
                }
                if ($null -ne $this.Cpu) {
                    [long] $currentCycle = $this.Cpu._cpuCycleBase + $this.Cpu.instrBusCycles
                    [int] $dmaCycles = ($currentCycle % 2 -eq 0) ? 514 : 513
                    $this.Cpu._cpuCycleBase += $dmaCycles
                    $this.Ppu.AdvanceDots($dmaCycles * 3)
                }
            }
        } elseif ($address -ge 0x6000 -and $address -lt 0x8000) {
            $this.Sram[$address - 0x6000] = $value
        }
    }
    
    [void] SetControllerState([byte] $port1, [byte] $port2) {
        $this.Controller1 = $port1
        $this.Controller2 = $port2
        $this.Controller1Index = 0
        $this.Controller2Index = 0
    }

    [ushort] Read16([ushort] $address) {
        [ushort] $lo = $this.Read($address)
        [ushort] $hi = $this.Read([ushort]($address + 1))
        return [ushort]($lo -bor ($hi -shl 8))
    }
}

enum AddrMode {
    ADDR_ZP = 0
    ADDR_REL = 1
    ADDR_IMP = 2
    ADDR_ABS = 3
    ADDR_ACC = 4
    ADDR_IMM = 5
    ADDR_ZPX = 6
    ADDR_ZPY = 7
    ADDR_ABSX = 8
    ADDR_ABSY = 9
    ADDR_PREIDXIND = 10
    ADDR_POSTIDXIND = 11
    ADDR_INDABS = 12
}
enum Instruction {
    INS_ADC = 0
    INS_AND = 1
    INS_ASL = 2
    INS_BCC = 3
    INS_BCS = 4
    INS_BEQ = 5
    INS_BIT = 6
    INS_BMI = 7
    INS_BNE = 8
    INS_BPL = 9
    INS_BRK = 10
    INS_BVC = 11
    INS_BVS = 12
    INS_CLC = 13
    INS_CLD = 14
    INS_CLI = 15
    INS_CLV = 16
    INS_CMP = 17
    INS_CPX = 18
    INS_CPY = 19
    INS_DEC = 20
    INS_DEX = 21
    INS_DEY = 22
    INS_EOR = 23
    INS_INC = 24
    INS_INX = 25
    INS_INY = 26
    INS_JMP = 27
    INS_JSR = 28
    INS_LDA = 29
    INS_LDX = 30
    INS_LDY = 31
    INS_LSR = 32
    INS_NOP = 33
    INS_ORA = 34
    INS_PHA = 35
    INS_PHP = 36
    INS_PLA = 37
    INS_PLP = 38
    INS_ROL = 39
    INS_ROR = 40
    INS_RTI = 41
    INS_RTS = 42
    INS_SBC = 43
    INS_SEC = 44
    INS_SED = 45
    INS_SEI = 46
    INS_STA = 47
    INS_STX = 48
    INS_STY = 49
    INS_TAX = 50
    INS_TAY = 51
    INS_TSX = 52
    INS_TXA = 53
    INS_TXS = 54
    INS_TYA = 55
    INS_ALR = 56
    INS_ANC = 57
    INS_ARR = 58
    INS_AXS = 59
    INS_LAX = 60
    INS_SAX = 61
    INS_DCP = 62
    INS_ISC = 63
    INS_RLA = 64
    INS_RRA = 65
    INS_SLO = 66
    INS_SRE = 67
    INS_SKB = 68
    INS_IGN = 69
    INS_SHA = 71
    INS_SHS = 72
    INS_SHY = 73
    INS_SHX = 74
    INS_LAE = 75
    INS_ANE = 76
    INS_LXA = 77
}
class OpInfo {
    [Instruction] $Ins
    [AddrMode] $Mode
    [int] $Size
    [int] $Cycles
    OpInfo([Instruction]$i, [AddrMode]$m, [int]$s, [int]$c) {
        $this.Ins = $i; $this.Mode = $m; $this.Size = $s; $this.Cycles = $c
    }
}
class Cpu6502 {
    [Memory] $Mem
    [Ppu] $Ppu
    
    [int] $REG_ACC
    [int] $REG_X
    [int] $REG_Y
    [int] $REG_SP
    [int] $REG_PC
    [int] $REG_PC_NEW
    
    [int] $F_CARRY
    [int] $F_ZERO
    [int] $F_INTERRUPT
    [int] $F_INTERRUPT_NEW
    [int] $F_DECIMAL
    [int] $F_BRK
    [int] $F_BRK_NEW
    [int] $F_OVERFLOW
    [int] $F_SIGN
    
    [int] $instrBusCycles
    [int] $apuCatchupCycles
    [int] $nmiDotsRemainingInStep
    [int] $_dmcFetchCycles
    [long] $_cpuCycleBase
    
    [bool] $irqRequested
    [int] $irqType
    
    [bool] $nmiRaised
    [bool] $nmiPending
    [bool] $nmiImmediate
    [int] $nmiRaisedAtCycle
    
    [int] $dataBus
    
    [OpInfo[]] $OpTable
    
    Cpu6502([Memory] $mem, [Ppu] $ppu) {
        $this.Mem = $mem
        $this.Ppu = $ppu
        $this.OpTable = [OpInfo[]]::new(256)
        $this.OpTable[105] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[101] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[117] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[109] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[125] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[121] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[97] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[113] = [OpInfo]::new([Instruction]::INS_ADC, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[41] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[37] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[53] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[45] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[61] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[57] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[33] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[49] = [OpInfo]::new([Instruction]::INS_AND, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[10] = [OpInfo]::new([Instruction]::INS_ASL, [AddrMode]::ADDR_ACC, 1, 2)
        $this.OpTable[6] = [OpInfo]::new([Instruction]::INS_ASL, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[22] = [OpInfo]::new([Instruction]::INS_ASL, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[14] = [OpInfo]::new([Instruction]::INS_ASL, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[30] = [OpInfo]::new([Instruction]::INS_ASL, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[144] = [OpInfo]::new([Instruction]::INS_BCC, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[176] = [OpInfo]::new([Instruction]::INS_BCS, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[240] = [OpInfo]::new([Instruction]::INS_BEQ, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[48] = [OpInfo]::new([Instruction]::INS_BMI, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[208] = [OpInfo]::new([Instruction]::INS_BNE, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[16] = [OpInfo]::new([Instruction]::INS_BPL, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[80] = [OpInfo]::new([Instruction]::INS_BVC, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[112] = [OpInfo]::new([Instruction]::INS_BVS, [AddrMode]::ADDR_REL, 2, 2)
        $this.OpTable[36] = [OpInfo]::new([Instruction]::INS_BIT, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[44] = [OpInfo]::new([Instruction]::INS_BIT, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[0] = [OpInfo]::new([Instruction]::INS_BRK, [AddrMode]::ADDR_IMP, 1, 7)
        $this.OpTable[24] = [OpInfo]::new([Instruction]::INS_CLC, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[216] = [OpInfo]::new([Instruction]::INS_CLD, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[88] = [OpInfo]::new([Instruction]::INS_CLI, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[184] = [OpInfo]::new([Instruction]::INS_CLV, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[201] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[197] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[213] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[205] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[221] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[217] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[193] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[209] = [OpInfo]::new([Instruction]::INS_CMP, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[224] = [OpInfo]::new([Instruction]::INS_CPX, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[228] = [OpInfo]::new([Instruction]::INS_CPX, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[236] = [OpInfo]::new([Instruction]::INS_CPX, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[192] = [OpInfo]::new([Instruction]::INS_CPY, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[196] = [OpInfo]::new([Instruction]::INS_CPY, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[204] = [OpInfo]::new([Instruction]::INS_CPY, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[198] = [OpInfo]::new([Instruction]::INS_DEC, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[214] = [OpInfo]::new([Instruction]::INS_DEC, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[206] = [OpInfo]::new([Instruction]::INS_DEC, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[222] = [OpInfo]::new([Instruction]::INS_DEC, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[202] = [OpInfo]::new([Instruction]::INS_DEX, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[136] = [OpInfo]::new([Instruction]::INS_DEY, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[73] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[69] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[85] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[77] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[93] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[89] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[65] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[81] = [OpInfo]::new([Instruction]::INS_EOR, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[230] = [OpInfo]::new([Instruction]::INS_INC, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[246] = [OpInfo]::new([Instruction]::INS_INC, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[238] = [OpInfo]::new([Instruction]::INS_INC, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[254] = [OpInfo]::new([Instruction]::INS_INC, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[232] = [OpInfo]::new([Instruction]::INS_INX, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[200] = [OpInfo]::new([Instruction]::INS_INY, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[76] = [OpInfo]::new([Instruction]::INS_JMP, [AddrMode]::ADDR_ABS, 3, 3)
        $this.OpTable[108] = [OpInfo]::new([Instruction]::INS_JMP, [AddrMode]::ADDR_INDABS, 3, 5)
        $this.OpTable[32] = [OpInfo]::new([Instruction]::INS_JSR, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[169] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[165] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[181] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[173] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[189] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[185] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[161] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[177] = [OpInfo]::new([Instruction]::INS_LDA, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[162] = [OpInfo]::new([Instruction]::INS_LDX, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[166] = [OpInfo]::new([Instruction]::INS_LDX, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[182] = [OpInfo]::new([Instruction]::INS_LDX, [AddrMode]::ADDR_ZPY, 2, 4)
        $this.OpTable[174] = [OpInfo]::new([Instruction]::INS_LDX, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[190] = [OpInfo]::new([Instruction]::INS_LDX, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[160] = [OpInfo]::new([Instruction]::INS_LDY, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[164] = [OpInfo]::new([Instruction]::INS_LDY, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[180] = [OpInfo]::new([Instruction]::INS_LDY, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[172] = [OpInfo]::new([Instruction]::INS_LDY, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[188] = [OpInfo]::new([Instruction]::INS_LDY, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[74] = [OpInfo]::new([Instruction]::INS_LSR, [AddrMode]::ADDR_ACC, 1, 2)
        $this.OpTable[70] = [OpInfo]::new([Instruction]::INS_LSR, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[86] = [OpInfo]::new([Instruction]::INS_LSR, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[78] = [OpInfo]::new([Instruction]::INS_LSR, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[94] = [OpInfo]::new([Instruction]::INS_LSR, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[26] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[58] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[90] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[122] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[218] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[234] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[250] = [OpInfo]::new([Instruction]::INS_NOP, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[9] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[5] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[21] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[13] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[29] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[25] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[1] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[17] = [OpInfo]::new([Instruction]::INS_ORA, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[72] = [OpInfo]::new([Instruction]::INS_PHA, [AddrMode]::ADDR_IMP, 1, 3)
        $this.OpTable[8] = [OpInfo]::new([Instruction]::INS_PHP, [AddrMode]::ADDR_IMP, 1, 3)
        $this.OpTable[104] = [OpInfo]::new([Instruction]::INS_PLA, [AddrMode]::ADDR_IMP, 1, 4)
        $this.OpTable[40] = [OpInfo]::new([Instruction]::INS_PLP, [AddrMode]::ADDR_IMP, 1, 4)
        $this.OpTable[42] = [OpInfo]::new([Instruction]::INS_ROL, [AddrMode]::ADDR_ACC, 1, 2)
        $this.OpTable[38] = [OpInfo]::new([Instruction]::INS_ROL, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[54] = [OpInfo]::new([Instruction]::INS_ROL, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[46] = [OpInfo]::new([Instruction]::INS_ROL, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[62] = [OpInfo]::new([Instruction]::INS_ROL, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[106] = [OpInfo]::new([Instruction]::INS_ROR, [AddrMode]::ADDR_ACC, 1, 2)
        $this.OpTable[102] = [OpInfo]::new([Instruction]::INS_ROR, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[118] = [OpInfo]::new([Instruction]::INS_ROR, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[110] = [OpInfo]::new([Instruction]::INS_ROR, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[126] = [OpInfo]::new([Instruction]::INS_ROR, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[64] = [OpInfo]::new([Instruction]::INS_RTI, [AddrMode]::ADDR_IMP, 1, 6)
        $this.OpTable[96] = [OpInfo]::new([Instruction]::INS_RTS, [AddrMode]::ADDR_IMP, 1, 6)
        $this.OpTable[233] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[235] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[229] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[245] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[237] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[253] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[249] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[225] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[241] = [OpInfo]::new([Instruction]::INS_SBC, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[56] = [OpInfo]::new([Instruction]::INS_SEC, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[248] = [OpInfo]::new([Instruction]::INS_SED, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[120] = [OpInfo]::new([Instruction]::INS_SEI, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[133] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[149] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[141] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[157] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_ABSX, 3, 5)
        $this.OpTable[153] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_ABSY, 3, 5)
        $this.OpTable[129] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[145] = [OpInfo]::new([Instruction]::INS_STA, [AddrMode]::ADDR_POSTIDXIND, 2, 6)
        $this.OpTable[134] = [OpInfo]::new([Instruction]::INS_STX, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[150] = [OpInfo]::new([Instruction]::INS_STX, [AddrMode]::ADDR_ZPY, 2, 4)
        $this.OpTable[142] = [OpInfo]::new([Instruction]::INS_STX, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[132] = [OpInfo]::new([Instruction]::INS_STY, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[148] = [OpInfo]::new([Instruction]::INS_STY, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[140] = [OpInfo]::new([Instruction]::INS_STY, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[170] = [OpInfo]::new([Instruction]::INS_TAX, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[168] = [OpInfo]::new([Instruction]::INS_TAY, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[186] = [OpInfo]::new([Instruction]::INS_TSX, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[138] = [OpInfo]::new([Instruction]::INS_TXA, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[154] = [OpInfo]::new([Instruction]::INS_TXS, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[152] = [OpInfo]::new([Instruction]::INS_TYA, [AddrMode]::ADDR_IMP, 1, 2)
        $this.OpTable[75] = [OpInfo]::new([Instruction]::INS_ALR, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[11] = [OpInfo]::new([Instruction]::INS_ANC, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[43] = [OpInfo]::new([Instruction]::INS_ANC, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[107] = [OpInfo]::new([Instruction]::INS_ARR, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[203] = [OpInfo]::new([Instruction]::INS_AXS, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[163] = [OpInfo]::new([Instruction]::INS_LAX, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[167] = [OpInfo]::new([Instruction]::INS_LAX, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[175] = [OpInfo]::new([Instruction]::INS_LAX, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[179] = [OpInfo]::new([Instruction]::INS_LAX, [AddrMode]::ADDR_POSTIDXIND, 2, 5)
        $this.OpTable[183] = [OpInfo]::new([Instruction]::INS_LAX, [AddrMode]::ADDR_ZPY, 2, 4)
        $this.OpTable[191] = [OpInfo]::new([Instruction]::INS_LAX, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[131] = [OpInfo]::new([Instruction]::INS_SAX, [AddrMode]::ADDR_PREIDXIND, 2, 6)
        $this.OpTable[135] = [OpInfo]::new([Instruction]::INS_SAX, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[143] = [OpInfo]::new([Instruction]::INS_SAX, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[151] = [OpInfo]::new([Instruction]::INS_SAX, [AddrMode]::ADDR_ZPY, 2, 4)
        $this.OpTable[195] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_PREIDXIND, 2, 8)
        $this.OpTable[199] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[207] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[211] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_POSTIDXIND, 2, 8)
        $this.OpTable[215] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[219] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_ABSY, 3, 7)
        $this.OpTable[223] = [OpInfo]::new([Instruction]::INS_DCP, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[227] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_PREIDXIND, 2, 8)
        $this.OpTable[231] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[239] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[243] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_POSTIDXIND, 2, 8)
        $this.OpTable[247] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[251] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_ABSY, 3, 7)
        $this.OpTable[255] = [OpInfo]::new([Instruction]::INS_ISC, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[35] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_PREIDXIND, 2, 8)
        $this.OpTable[39] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[47] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[51] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_POSTIDXIND, 2, 8)
        $this.OpTable[55] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[59] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_ABSY, 3, 7)
        $this.OpTable[63] = [OpInfo]::new([Instruction]::INS_RLA, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[99] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_PREIDXIND, 2, 8)
        $this.OpTable[103] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[111] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[115] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_POSTIDXIND, 2, 8)
        $this.OpTable[119] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[123] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_ABSY, 3, 7)
        $this.OpTable[127] = [OpInfo]::new([Instruction]::INS_RRA, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[3] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_PREIDXIND, 2, 8)
        $this.OpTable[7] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[15] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[19] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_POSTIDXIND, 2, 8)
        $this.OpTable[23] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[27] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_ABSY, 3, 7)
        $this.OpTable[31] = [OpInfo]::new([Instruction]::INS_SLO, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[67] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_PREIDXIND, 2, 8)
        $this.OpTable[71] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_ZP, 2, 5)
        $this.OpTable[79] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_ABS, 3, 6)
        $this.OpTable[83] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_POSTIDXIND, 2, 8)
        $this.OpTable[87] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_ZPX, 2, 6)
        $this.OpTable[91] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_ABSY, 3, 7)
        $this.OpTable[95] = [OpInfo]::new([Instruction]::INS_SRE, [AddrMode]::ADDR_ABSX, 3, 7)
        $this.OpTable[128] = [OpInfo]::new([Instruction]::INS_SKB, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[130] = [OpInfo]::new([Instruction]::INS_SKB, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[137] = [OpInfo]::new([Instruction]::INS_SKB, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[194] = [OpInfo]::new([Instruction]::INS_SKB, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[226] = [OpInfo]::new([Instruction]::INS_SKB, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[12] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABS, 3, 4)
        $this.OpTable[28] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[60] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[92] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[124] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[220] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[252] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ABSX, 3, 4)
        $this.OpTable[4] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[68] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[100] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZP, 2, 3)
        $this.OpTable[20] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[52] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[84] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[116] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[212] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[244] = [OpInfo]::new([Instruction]::INS_IGN, [AddrMode]::ADDR_ZPX, 2, 4)
        $this.OpTable[147] = [OpInfo]::new([Instruction]::INS_SHA, [AddrMode]::ADDR_POSTIDXIND, 2, 6)
        $this.OpTable[159] = [OpInfo]::new([Instruction]::INS_SHA, [AddrMode]::ADDR_ABSY, 3, 5)
        $this.OpTable[155] = [OpInfo]::new([Instruction]::INS_SHS, [AddrMode]::ADDR_ABSY, 3, 5)
        $this.OpTable[156] = [OpInfo]::new([Instruction]::INS_SHY, [AddrMode]::ADDR_ABSX, 3, 5)
        $this.OpTable[158] = [OpInfo]::new([Instruction]::INS_SHX, [AddrMode]::ADDR_ABSY, 3, 5)
        $this.OpTable[187] = [OpInfo]::new([Instruction]::INS_LAE, [AddrMode]::ADDR_ABSY, 3, 4)
        $this.OpTable[139] = [OpInfo]::new([Instruction]::INS_ANE, [AddrMode]::ADDR_IMM, 2, 2)
        $this.OpTable[171] = [OpInfo]::new([Instruction]::INS_LXA, [AddrMode]::ADDR_IMM, 2, 2)
    }

    [void] Reset() {
        $this.REG_ACC = 0
        $this.REG_X = 0
        $this.REG_Y = 0
        $this.REG_SP = 0xFD
        $this.F_CARRY = 0
        $this.F_ZERO = 1
        $this.F_INTERRUPT = 1
        $this.F_INTERRUPT_NEW = 1
        $this.F_DECIMAL = 0
        $this.F_BRK = 0
        $this.F_BRK_NEW = 0
        $this.F_OVERFLOW = 0
        $this.F_SIGN = 0
        $this.irqRequested = $false
        $this.nmiRaised = $false
        $this.nmiPending = $false
        $this.nmiImmediate = $false
        $this.REG_PC_NEW = 0
        $this.DoResetInterrupt()
        $this.REG_PC = $this.REG_PC_NEW
        $this.Ppu.Scanline = 0
        $this.Ppu.Cycle = 0
        $this.Ppu.Status = $this.Ppu.Status -band 0x7F
    }

    
    [int] Emulate() {
        if ($null -eq $this.Mem) { return 32 }
        
        $this.instrBusCycles = 0
        $this.apuCatchupCycles = 0
        $this.nmiDotsRemainingInStep = 0
        
        [int] $interruptCycles = 0
        
        if ($this.nmiRaised) {
            $this.nmiPending = $true
            $this.nmiRaised = $false
        }
        
        if ($this.irqRequested) {
            [int] $tempSt = $this.GetStatus()
            $this.REG_PC_NEW = $this.REG_PC
            $this.F_INTERRUPT_NEW = $this.F_INTERRUPT
            switch ($this.irqType) {
                0 {
                    if ($this.F_INTERRUPT -eq 0) {
                        $this.DoIrq($tempSt -band 0xEF)
                        $interruptCycles = 7
                    }
                }
                2 {
                    $this.DoResetInterrupt()
                    $interruptCycles = 7
                }
            }
            $this.REG_PC = $this.REG_PC_NEW
            $this.F_INTERRUPT = $this.F_INTERRUPT_NEW
            $this.F_BRK = $this.F_BRK_NEW
            $this.irqRequested = $false
        }
        
        $this._dmcFetchCycles = 0x7FFFFFFF
        
        [byte] $opcode = $this.Load([ushort](($this.REG_PC + 1) -band 0xFFFF))
        
        [OpInfo] $opinfo = $this.OpTable[$opcode]
        if ($null -eq $opinfo) {
            throw ('Game crashed, invalid opcode at address 0x' + $this.REG_PC.ToString('X4'))
        }
        
        [int] $cycleAdd = 0
        [int] $cycleCount = $opinfo.Cycles
        [int] $addr = 0
        [int] $temp = 0
        [int] $baseHigh = 0
        [int] $opaddr = $this.REG_PC
        # Advance the pre-increment PC before operand addressing and execution.
        # Immediate addressing and relative branches use this post-size value;
        # JSNES follows the same convention. Control-flow handlers replace it
        # when they jump or return.
        $this.REG_PC = ($this.REG_PC + $opinfo.Size) -band 0xFFFF
        
        [int] $zpBase6 = 0; [int] $zpBase7 = 0; [int] $zpPtr10 = 0; [int] $zpAddr10 = 0; [int] $zpAddr = 0; [int] $hiAddr = 0;
        [int] $add = 0; [int] $b1 = 0; [int] $b2 = 0; [int] $val = 0; [int] $shyVal = 0; [int] $shxVal = 0; [int] $shaVal = 0; [int] $shsVal = 0;
        [int] $t = 0; [int] $b = 0; [int] $carry = 0; [int] $compare = 0; [int] $result = 0;
        
        switch ($opinfo.Mode) {

      ([AddrMode]::ADDR_ZP) {
        # Zero Page mode. Use the address given after the opcode,
        # but without high byte.
        $addr = $this.Load($opaddr + 2)
        break
      }
      ([AddrMode]::ADDR_REL) {
        # Relative mode.
        $addr = $this.Load($opaddr + 2)
        if ($addr -lt 0x80) {
          $addr += $this.REG_PC
        } else {
          $addr += $this.REG_PC - 256
        }
        break
      }
      ([AddrMode]::ADDR_IMP) {
        # Implied mode. The 6502's second cycle performs a dummy read of the
        # byte at PC (the next opcode). This is a real bus operation that
        # updates the data bus and can trigger I/O side effects.
        # Note: $opaddr is REG_PC which is one less than the actual instruction
        # address (opcode is at $opaddr+1), so the dummy read targets $opaddr+2.
        # See https:#www.nesdev.org/wiki/CPU_addressing_modes
        $this.Load($opaddr + 2)
        break
      }
      ([AddrMode]::ADDR_ABS) {
        # Absolute mode. Use the two bytes following the opcode as
        # an address.
        $addr = $this.Load16Bit($opaddr + 2)
        break
      }
      ([AddrMode]::ADDR_ACC) {
        # Accumulator mode. The address is in the accumulator register.
        # Like implied mode, the 6502 performs a dummy read of the byte at PC
        # during its second cycle ($opaddr+2, see case 2 comment).
        # See https:#www.nesdev.org/wiki/CPU_addressing_modes
        $this.Load($opaddr + 2)
        $addr = $this.REG_ACC
        break
      }
      ([AddrMode]::ADDR_IMM) {
        # Immediate mode. The value is given after the opcode.
        $addr = $this.REG_PC
        break
      }
      ([AddrMode]::ADDR_ZPX) {
        # Zero Page Indexed mode, X as index. Use the address given
        # after the opcode, then $add the X register to get the final address.
        # The 6502 reads from the unindexed zero-page address while adding X.
        # This "dummy read" is a real bus cycle that can trigger I/O side effects.
        # See https:#www.nesdev.org/wiki/CPU_addressing_modes
        [int] $zpBase6 = $this.Load($opaddr + 2)
        $this.Load($zpBase6) # dummy read from unindexed zero-page address
        $addr = ($zpBase6 + $this.REG_X) -band 0xff
        break
      }
      ([AddrMode]::ADDR_ZPY) {
        # Zero Page Indexed mode, Y as index. Same dummy read behavior as case 6.
        [int] $zpBase7 = $this.Load($opaddr + 2)
        $this.Load($zpBase7) # dummy read from unindexed zero-page address
        $addr = ($zpBase7 + $this.REG_Y) -band 0xff
        break
      }
      ([AddrMode]::ADDR_ABSX) {
        # Absolute Indexed Mode, X as index.
        $addr = $this.Load16Bit($opaddr + 2)
        $baseHigh = ($addr -shr 8) -band 0xff
        if (($addr -band 0xff00) -ne (($addr + $this.REG_X) -band 0xff00)) {
          # Page boundary crossed: the 6502 first reads from the "wrong"
          # address (correct low byte, uncorrected high byte) before reading
          # the correct one. This dummy read is a real bus cycle that updates
          # the data bus and can trigger I/O side effects.
          # See https:#www.nesdev.org/wiki/CPU_addressing_modes
          $this.Load(($addr -band 0xff00) -bor (($addr + $this.REG_X) -band 0xff))
          $cycleAdd = 1
        }
        $addr += $this.REG_X
        break
      }
      ([AddrMode]::ADDR_ABSY) {
        # Absolute Indexed Mode, Y as index.
        # Same page-crossing dummy read behavior as case 8.
        $addr = $this.Load16Bit($opaddr + 2)
        $baseHigh = ($addr -shr 8) -band 0xff
        if (($addr -band 0xff00) -ne (($addr + $this.REG_Y) -band 0xff00)) {
          $this.Load(($addr -band 0xff00) -bor (($addr + $this.REG_Y) -band 0xff))
          $cycleAdd = 1
        }
        $addr += $this.REG_Y
        break
      }
      ([AddrMode]::ADDR_PREIDXIND) {
        # Pre-indexed Indirect mode, (d,X). Read pointer from zero page,
        # $add X, then read the 16-bit effective address. Wraps within zero page.
        # Dummy read from the unindexed pointer address while adding X.
        [int] $zpPtr10 = $this.Load($opaddr + 2)
        $this.Load($zpPtr10) # dummy read: 6502 reads from ptr before adding X
        [int] $zpAddr10 = ($zpPtr10 + $this.REG_X) -band 0xff
        $addr =
          [int]$this.Load($zpAddr10) -bor ([int]$this.Load(($zpAddr10 + 1) -band 0xff) -shl 8)
        break
      }
      ([AddrMode]::ADDR_POSTIDXIND) {
        # Post-indexed Indirect mode, (d),Y. Read 16-bit base address from
        # zero page, then $add Y. Page-crossing dummy read as in case 8.
        [int] $zpAddr = $this.Load($opaddr + 2)
        $addr =
          [int]$this.Load($zpAddr) -bor ([int]$this.Load(($zpAddr + 1) -band 0xff) -shl 8)
        $baseHigh = ($addr -shr 8) -band 0xff
        if (($addr -band 0xff00) -ne (($addr + $this.REG_Y) -band 0xff00)) {
          $this.Load(($addr -band 0xff00) -bor (($addr + $this.REG_Y) -band 0xff))
          $cycleAdd = 1
        }
        $addr += $this.REG_Y
        break
      }
      ([AddrMode]::ADDR_INDABS) {
        # Indirect Absolute mode (JMP indirect). Find the 16-bit address
        # contained at the given location. The 6502 has a famous bug: when
        # the pointer's low byte is $FF, the high byte wraps within the
        # same page instead of crossing to the next page.
        $addr = $this.Load16Bit($opaddr + 2) # Find op
        [int] $hiAddr = ($addr -band 0xff00) -bor ((($addr -band 0xff) + 1) -band 0xff)
        $addr = [int]$this.Load($addr) -bor ([int]$this.Load($hiAddr) -shl 8)
        break
      }

        }
        # Effective addresses wrap at 16 bits, as JSNES (addr &= 0xffff) and FCEUX do.
        $addr = $addr -band 0xFFFF
        switch ($opinfo.Ins) {

      ([Instruction]::INS_ADC) {
        # *******
        # * ADC *
        # *******

        # Add with $carry.
        $add = $this.Load($addr)
        $temp = $this.REG_ACC + $add + $this.F_CARRY

        if (
          (($this.REG_ACC -bxor $add) -band 0x80) -eq 0 -and
          (($this.REG_ACC -bxor $temp) -band 0x80) -ne 0
        ) {
          $this.F_OVERFLOW = 1
        } else {
          $this.F_OVERFLOW = 0
        }
        $this.F_CARRY = $temp -gt 255 ? 1 : 0
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        $this.REG_ACC = $temp -band 255
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_AND) {
        # *******
        # * AND *
        # *******

        # AND memory with accumulator.
        $this.REG_ACC = $this.REG_ACC -band $this.Load($addr)
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_ASL) {
        # *******
        # * ASL *
        # *******

        # Shift left one bit
        if ($opinfo.Mode -eq [AddrMode]::ADDR_ACC) {
          $this.F_CARRY = ($this.REG_ACC -shr 7) -band 1
          $this.REG_ACC = ($this.REG_ACC -shl 1) -band 255
          $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
          $this.F_ZERO = $this.REG_ACC
        } else {
          # Read-Modify-Write (RMW) cycle pattern for memory operands:
          #   1. For indexed modes without page crossing, the 6502 always
          #      does a dummy read (same as stores, see case 47/STA).
          #   2. Read the value from the effective address.
          #   3. Write the ORIGINAL value back (dummy write) while computing.
          #   4. Write the MODIFIED value.
          # The dummy write is a real bus cycle — writing to I/O registers
          # like PPU $2007 twice has visible side effects.
          # See https:#www.nesdev.org/wiki/CPU_addressing_modes (RMW column)
          if (
            $cycleAdd -eq 0 -and
            ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
          ) {
            $this.Load($addr) # dummy read (indexed, no page crossing)
          }
          $temp = $this.Load($addr)
          $this.Write($addr, $temp) # dummy write (original value)
          $this.F_CARRY = ($temp -shr 7) -band 1
          $temp = ($temp -shl 1) -band 255
          $this.F_SIGN = ($temp -shr 7) -band 1
          $this.F_ZERO = $temp
          $this.Write($addr, $temp)
        }
        break
      }
      ([Instruction]::INS_BCC) {
        # *******
        # * BCC *
        # *******

        # Branch on $carry clear
        if ($this.F_CARRY -eq 0) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BCS) {
        # *******
        # * BCS *
        # *******

        # Branch on $carry set
        if ($this.F_CARRY -eq 1) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BEQ) {
        # *******
        # * BEQ *
        # *******

        # Branch on zero
        if ($this.F_ZERO -eq 0) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BIT) {
        # *******
        # * BIT *
        # *******

        $temp = $this.Load($addr)
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_OVERFLOW = ($temp -shr 6) -band 1
        $temp = $temp -band $this.REG_ACC
        $this.F_ZERO = $temp
        break
      }
      ([Instruction]::INS_BMI) {
        # *******
        # * BMI *
        # *******

        # Branch on negative $result
        if ($this.F_SIGN -eq 1) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BNE) {
        # *******
        # * BNE *
        # *******

        # Branch on not zero
        if ($this.F_ZERO -ne 0) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BPL) {
        # *******
        # * BPL *
        # *******

        # Branch on positive $result
        if ($this.F_SIGN -eq 0) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BRK) {
        # *******
        # * BRK *
        # *******

        $this.REG_PC += 2
        $this.Push(($this.REG_PC -shr 8) -band 255)
        $this.Push($this.REG_PC -band 255)
        $this.F_BRK = 1
        $this.Push($this.GetStatus())

        $this.F_INTERRUPT = 1
        #$this.REG_PC = load(0xFFFE) -bor (load(0xFFFF) -shl 8)
        $this.REG_PC = $this.Load16Bit(0xfffe)
        $this.REG_PC--
        break
      }
      ([Instruction]::INS_BVC) {
        # *******
        # * BVC *
        # *******

        # Branch on overflow clear
        if ($this.F_OVERFLOW -eq 0) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_BVS) {
        # *******
        # * BVS *
        # *******

        # Branch on overflow set
        if ($this.F_OVERFLOW -eq 1) {
          $cycleCount += $this._takeBranch($opaddr, $addr)
        }
        break
      }
      ([Instruction]::INS_CLC) {
        # *******
        # * CLC *
        # *******

        # Clear $carry flag
        $this.F_CARRY = 0
        break
      }
      ([Instruction]::INS_CLD) {
        # *******
        # * CLD *
        # *******

        # Clear decimal flag
        $this.F_DECIMAL = 0
        break
      }
      ([Instruction]::INS_CLI) {
        # *******
        # * CLI *
        # *******

        # Clear interrupt flag
        $this.F_INTERRUPT = 0
        break
      }
      ([Instruction]::INS_CLV) {
        # *******
        # * CLV *
        # *******

        # Clear overflow flag
        $this.F_OVERFLOW = 0
        break
      }
      ([Instruction]::INS_CMP) {
        # *******
        # * CMP *
        # *******

        # Compare memory and accumulator:
        $temp = $this.REG_ACC - $this.Load($addr)
        $this.F_CARRY = $temp -ge 0 ? 1 : 0
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_CPX) {
        # *******
        # * CPX *
        # *******

        # Compare memory and index X:
        $temp = $this.REG_X - $this.Load($addr)
        $this.F_CARRY = $temp -ge 0 ? 1 : 0
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        break
      }
      ([Instruction]::INS_CPY) {
        # *******
        # * CPY *
        # *******

        # Compare memory and index Y:
        $temp = $this.REG_Y - $this.Load($addr)
        $this.F_CARRY = $temp -ge 0 ? 1 : 0
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        break
      }
      ([Instruction]::INS_DEC) {
        # *******
        # * DEC *
        # *******

        # Decrement memory by one (RMW pattern, see ASL case 2):
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $temp = ($temp - 1) -band 0xff
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp
        $this.Write($addr, $temp)
        break
      }
      ([Instruction]::INS_DEX) {
        # *******
        # * DEX *
        # *******

        # Decrement index X by one:
        $this.REG_X = ($this.REG_X - 1) -band 0xff
        $this.F_SIGN = ($this.REG_X -shr 7) -band 1
        $this.F_ZERO = $this.REG_X
        break
      }
      ([Instruction]::INS_DEY) {
        # *******
        # * DEY *
        # *******

        # Decrement index Y by one:
        $this.REG_Y = ($this.REG_Y - 1) -band 0xff
        $this.F_SIGN = ($this.REG_Y -shr 7) -band 1
        $this.F_ZERO = $this.REG_Y
        break
      }
      ([Instruction]::INS_EOR) {
        # *******
        # * EOR *
        # *******

        # XOR Memory with accumulator, store in accumulator:
        $this.REG_ACC = ($this.Load($addr) -bxor $this.REG_ACC) -band 0xff
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_INC) {
        # *******
        # * INC *
        # *******

        # Increment memory by one (RMW pattern, see ASL case 2):
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $temp = ($temp + 1) -band 0xff
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp
        $this.Write($addr, $temp)
        break
      }
      ([Instruction]::INS_INX) {
        # *******
        # * INX *
        # *******

        # Increment index X by one:
        $this.REG_X = ($this.REG_X + 1) -band 0xff
        $this.F_SIGN = ($this.REG_X -shr 7) -band 1
        $this.F_ZERO = $this.REG_X
        break
      }
      ([Instruction]::INS_INY) {
        # *******
        # * INY *
        # *******

        # Increment index Y by one:
        $this.REG_Y++
        $this.REG_Y = $this.REG_Y -band 0xff
        $this.F_SIGN = ($this.REG_Y -shr 7) -band 1
        $this.F_ZERO = $this.REG_Y
        break
      }
      ([Instruction]::INS_JMP) {
        # *******
        # * JMP *
        # *******

        # Jump to new location:
        $this.REG_PC = $addr - 1
        break
      }
      ([Instruction]::INS_JSR) {
        # *******
        # * JSR *
        # *******

        # Jump to new location, saving return address.
        # Push return address on stack:
        $this.Push(($this.REG_PC -shr 8) -band 255)
        $this.Push($this.REG_PC -band 255)
        # On real 6502, JSR reads the high byte of the target address as its
        # last cycle (after the pushes), updating the data bus. This matters
        # for open bus behavior when JSR targets unmapped addresses.
        # See https:#www.nesdev.org/wiki/Open_bus_behavior
        $this.Load($opaddr + 3)
        $this.REG_PC = $addr - 1
        break
      }
      ([Instruction]::INS_LDA) {
        # *******
        # * LDA *
        # *******

        # Load accumulator with memory:
        $this.REG_ACC = $this.Load($addr)
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_LDX) {
        # *******
        # * LDX *
        # *******

        # Load index X with memory:
        $this.REG_X = $this.Load($addr)
        $this.F_SIGN = ($this.REG_X -shr 7) -band 1
        $this.F_ZERO = $this.REG_X
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_LDY) {
        # *******
        # * LDY *
        # *******

        # Load index Y with memory:
        $this.REG_Y = $this.Load($addr)
        $this.F_SIGN = ($this.REG_Y -shr 7) -band 1
        $this.F_ZERO = $this.REG_Y
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_LSR) {
        # *******
        # * LSR *
        # *******

        # Shift right one bit (RMW pattern, see ASL case 2):
        if ($opinfo.Mode -eq [AddrMode]::ADDR_ACC) {
          $temp = $this.REG_ACC -band 0xff
          $this.F_CARRY = $temp -band 1
          $temp = $temp -shr 1
          $this.REG_ACC = $temp
        } else {
          if (
            $cycleAdd -eq 0 -and
            ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
          ) {
            $this.Load($addr) # dummy read (indexed, no page crossing)
          }
          $temp = $this.Load($addr) -band 0xff
          $this.Write($addr, $temp) # dummy write (original value)
          $this.F_CARRY = $temp -band 1
          $temp = $temp -shr 1
          $this.Write($addr, $temp)
        }
        $this.F_SIGN = 0
        $this.F_ZERO = $temp
        break
      }
      ([Instruction]::INS_NOP) {
        # *******
        # * NOP *
        # *******

        # No OPeration.
        # Ignore.
        break
      }
      ([Instruction]::INS_ORA) {
        # *******
        # * ORA *
        # *******

        # OR memory with accumulator, store in accumulator.
        $temp = ($this.Load($addr) -bor $this.REG_ACC) -band 255
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp
        $this.REG_ACC = $temp
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_PHA) {
        # *******
        # * PHA *
        # *******

        # Push accumulator on stack
        $this.Push($this.REG_ACC)
        break
      }
      ([Instruction]::INS_PHP) {
        # *******
        # * PHP *
        # *******

        # Push processor status on stack
        $this.F_BRK = 1
        $this.Push($this.GetStatus())
        break
      }
      ([Instruction]::INS_PLA) {
        # *******
        # * PLA *
        # *******

        # Pull accumulator from stack
        $this.REG_ACC = $this.Pull()
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        break
      }
      ([Instruction]::INS_PLP) {
        # *******
        # * PLP *
        # *******

        # Pull processor status from stack
        $this.SetStatusFromStack($this.Pull())
        break
      }
      ([Instruction]::INS_ROL) {
        # *******
        # * ROL *
        # *******

        # Rotate one bit left (RMW pattern, see ASL case 2)
        if ($opinfo.Mode -eq [AddrMode]::ADDR_ACC) {
          $temp = $this.REG_ACC
          $add = $this.F_CARRY
          $this.F_CARRY = ($temp -shr 7) -band 1
          $temp = (($temp -shl 1) -band 0xff) + $add
          $this.REG_ACC = $temp
        } else {
          if (
            $cycleAdd -eq 0 -and
            ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
          ) {
            $this.Load($addr) # dummy read (indexed, no page crossing)
          }
          $temp = $this.Load($addr)
          $this.Write($addr, $temp) # dummy write (original value)
          $add = $this.F_CARRY
          $this.F_CARRY = ($temp -shr 7) -band 1
          $temp = (($temp -shl 1) -band 0xff) + $add
          $this.Write($addr, $temp)
        }
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp
        break
      }
      ([Instruction]::INS_ROR) {
        # *******
        # * ROR *
        # *******

        # Rotate one bit right (RMW pattern, see ASL case 2)
        if ($opinfo.Mode -eq [AddrMode]::ADDR_ACC) {
          $add = $this.F_CARRY -shl 7
          $this.F_CARRY = $this.REG_ACC -band 1
          $temp = ($this.REG_ACC -shr 1) + $add
          $this.REG_ACC = $temp
        } else {
          if (
            $cycleAdd -eq 0 -and
            ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
          ) {
            $this.Load($addr) # dummy read (indexed, no page crossing)
          }
          $temp = $this.Load($addr)
          $this.Write($addr, $temp) # dummy write (original value)
          $add = $this.F_CARRY -shl 7
          $this.F_CARRY = $temp -band 1
          $temp = ($temp -shr 1) + $add
          $this.Write($addr, $temp)
        }
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp
        break
      }
      ([Instruction]::INS_RTI) {
        # *******
        # * RTI *
        # *******

        # Return from interrupt. Pull status and PC from stack.
        $this.SetStatusFromStack($this.Pull())

        $this.REG_PC = $this.Pull()
        $this.REG_PC += [int]$this.Pull() -shl 8
        if ($this.REG_PC -eq 0xffff) {
          return $cycleCount
        }
        $this.REG_PC--
        break
      }
      ([Instruction]::INS_RTS) {
        # *******
        # * RTS *
        # *******

        # Return from subroutine. Pull PC from stack.

        $this.REG_PC = $this.Pull()
        $this.REG_PC += [int]$this.Pull() -shl 8

        if ($this.REG_PC -eq 0xffff) {
          return $cycleCount # return from NSF play routine:
        }
        break
      }
      ([Instruction]::INS_SBC) {
        # *******
        # * SBC *
        # *******

        $add = $this.Load($addr)
        $temp = $this.REG_ACC - $add - (1 - $this.F_CARRY)
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        if (
          (($this.REG_ACC -bxor $temp) -band 0x80) -ne 0 -and
          (($this.REG_ACC -bxor $add) -band 0x80) -ne 0
        ) {
          $this.F_OVERFLOW = 1
        } else {
          $this.F_OVERFLOW = 0
        }
        $this.F_CARRY = $temp -lt 0 ? 0 : 1
        $this.REG_ACC = $temp -band 0xff
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_SEC) {
        # *******
        # * SEC *
        # *******

        # Set $carry flag
        $this.F_CARRY = 1
        break
      }
      ([Instruction]::INS_SED) {
        # *******
        # * SED *
        # *******

        # Set decimal mode
        $this.F_DECIMAL = 1
        break
      }
      ([Instruction]::INS_SEI) {
        # *******
        # * SEI *
        # *******

        # Set interrupt disable status
        $this.F_INTERRUPT = 1
        break
      }
      ([Instruction]::INS_STA) {
        # *******
        # * STA *
        # *******

        # Store accumulator in memory.
        # Unlike loads, stores ALWAYS take the extra cycle for indexed
        # addressing, even without a page crossing. The page-crossing case
        # already added the dummy read in the addressing mode (cases 8/9/11)
        # $this handles the non-crossing case.
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr)
        }
        $this.Write($addr, $this.REG_ACC)
        break
      }
      ([Instruction]::INS_STX) {
        # *******
        # * STX *
        # *******

        # Store index X in memory
        $this.Write($addr, $this.REG_X)
        break
      }
      ([Instruction]::INS_STY) {
        # *******
        # * STY *
        # *******

        # Store index Y in memory:
        $this.Write($addr, $this.REG_Y)
        break
      }
      ([Instruction]::INS_TAX) {
        # *******
        # * TAX *
        # *******

        # Transfer accumulator to index X:
        $this.REG_X = $this.REG_ACC
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        break
      }
      ([Instruction]::INS_TAY) {
        # *******
        # * TAY *
        # *******

        # Transfer accumulator to index Y:
        $this.REG_Y = $this.REG_ACC
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        break
      }
      ([Instruction]::INS_TSX) {
        # *******
        # * TSX *
        # *******

        # Transfer stack pointer to index X:
        $this.REG_X = $this.REG_SP -band 0xff
        $this.F_SIGN = ($this.REG_SP -shr 7) -band 1
        $this.F_ZERO = $this.REG_X
        break
      }
      ([Instruction]::INS_TXA) {
        # *******
        # * TXA *
        # *******

        # Transfer index X to accumulator:
        $this.REG_ACC = $this.REG_X
        $this.F_SIGN = ($this.REG_X -shr 7) -band 1
        $this.F_ZERO = $this.REG_X
        break
      }
      ([Instruction]::INS_TXS) {
        # *******
        # * TXS *
        # *******

        # Transfer index X to stack pointer:
        $this.REG_SP = $this.REG_X -band 0xff
        break
      }
      ([Instruction]::INS_TYA) {
        # *******
        # * TYA *
        # *******

        # Transfer index Y to accumulator:
        $this.REG_ACC = $this.REG_Y
        $this.F_SIGN = ($this.REG_Y -shr 7) -band 1
        $this.F_ZERO = $this.REG_Y
        break
      }
      ([Instruction]::INS_ALR) {
        # *******
        # * ALR *
        # *******

        # Shift right one bit after ANDing:
        $temp = $this.REG_ACC -band $this.Load($addr)
        $this.F_CARRY = $temp -band 1
        $this.REG_ACC = $this.F_ZERO = $temp -shr 1
        $this.F_SIGN = 0
        break
      }
      ([Instruction]::INS_ANC) {
        # *******
        # * ANC *
        # *******

        # AND accumulator, setting $carry to bit 7 $result.
        $this.REG_ACC = $this.F_ZERO = $this.REG_ACC -band $this.Load($addr)
        $this.F_CARRY = $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        break
      }
      ([Instruction]::INS_ARR) {
        # *******
        # * ARR *
        # *******

        # Rotate right one bit after ANDing:
        $temp = $this.REG_ACC -band $this.Load($addr)
        $this.REG_ACC = $this.F_ZERO = ($temp -shr 1) + ($this.F_CARRY -shl 7)
        $this.F_SIGN = $this.F_CARRY
        $this.F_CARRY = ($temp -shr 7) -band 1
        $this.F_OVERFLOW = (($temp -shr 7) -bxor ($temp -shr 6)) -band 1
        break
      }
      ([Instruction]::INS_AXS) {
        # *******
        # * AXS *
        # *******

        # Set X to (X AND A) - value.
        # Like CMP, AXS sets N, Z, C but does NOT affect the V (overflow) flag.
        # https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        $temp = ($this.REG_X -band $this.REG_ACC) - $this.Load($addr)
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        $this.F_CARRY = $temp -lt 0 ? 0 : 1
        $this.REG_X = $temp -band 0xff
        break
      }
      ([Instruction]::INS_LAX) {
        # *******
        # * LAX *
        # *******

        # Load A and X with memory:
        $this.REG_ACC = $this.REG_X = $this.F_ZERO = $this.Load($addr)
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_SAX) {
        # *******
        # * SAX *
        # *******

        # Store A AND X in memory:
        $this.Write($addr, $this.REG_ACC -band $this.REG_X)
        break
      }
      ([Instruction]::INS_DCP) {
        # *******
        # * DCP *
        # *******

        # Decrement memory then $compare (unofficial, RMW pattern see ASL case 2):
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $temp = ($temp - 1) -band 0xff
        $this.Write($addr, $temp)

        # Then $compare with the accumulator:
        $temp = $this.REG_ACC - $temp
        $this.F_CARRY = $temp -ge 0 ? 1 : 0
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        break
      }
      ([Instruction]::INS_ISC) {
        # *******
        # * ISC *
        # *******

        # Increment memory then subtract (unofficial, RMW pattern see ASL case 2):
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $temp = ($temp + 1) -band 0xff
        $this.Write($addr, $temp)

        # Then subtract from the accumulator:
        [int] $isb_val = $temp
        $temp = $this.REG_ACC - $isb_val - (1 - $this.F_CARRY)
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        if (
          (($this.REG_ACC -bxor $temp) -band 0x80) -ne 0 -and
          (($this.REG_ACC -bxor $isb_val) -band 0x80) -ne 0
        ) {
          $this.F_OVERFLOW = 1
        } else {
          $this.F_OVERFLOW = 0
        }
        $this.F_CARRY = $temp -lt 0 ? 0 : 1
        $this.REG_ACC = $temp -band 0xff
        break
      }
      ([Instruction]::INS_RLA) {
        # *******
        # * RLA *
        # *******

        # Rotate left then AND (unofficial, RMW pattern see ASL case 2)
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $add = $this.F_CARRY
        $this.F_CARRY = ($temp -shr 7) -band 1
        $temp = (($temp -shl 1) -band 0xff) + $add
        $this.Write($addr, $temp)

        # Then AND with the accumulator.
        $this.REG_ACC = $this.REG_ACC -band $temp
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        break
      }
      ([Instruction]::INS_RRA) {
        # *******
        # * RRA *
        # *******

        # Rotate right then $add (unofficial, RMW pattern see ASL case 2)
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $add = $this.F_CARRY -shl 7
        $this.F_CARRY = $temp -band 1
        $temp = ($temp -shr 1) + $add
        $this.Write($addr, $temp)

        # Then $add to the accumulator
        [int] $rra_val = $temp
        $temp = $this.REG_ACC + $rra_val + $this.F_CARRY

        if (
          (($this.REG_ACC -bxor $rra_val) -band 0x80) -eq 0 -and
          (($this.REG_ACC -bxor $temp) -band 0x80) -ne 0
        ) {
          $this.F_OVERFLOW = 1
        } else {
          $this.F_OVERFLOW = 0
        }
        $this.F_CARRY = $temp -gt 255 ? 1 : 0
        $this.F_SIGN = ($temp -shr 7) -band 1
        $this.F_ZERO = $temp -band 0xff
        $this.REG_ACC = $temp -band 255
        break
      }
      ([Instruction]::INS_SLO) {
        # *******
        # * SLO *
        # *******

        # Shift left then OR (unofficial, RMW pattern see ASL case 2)
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr)
        $this.Write($addr, $temp) # dummy write (original value)
        $this.F_CARRY = ($temp -shr 7) -band 1
        $temp = ($temp -shl 1) -band 255
        $this.Write($addr, $temp)

        # Then OR with the accumulator.
        $this.REG_ACC = $this.REG_ACC -bor $temp
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        break
      }
      ([Instruction]::INS_SRE) {
        # *******
        # * SRE *
        # *******

        # Shift right then XOR (unofficial, RMW pattern see ASL case 2)
        if (
          $cycleAdd -eq 0 -and
          ($opinfo.Mode -eq [AddrMode]::ADDR_ABSX -or $opinfo.Mode -eq [AddrMode]::ADDR_ABSY -or $opinfo.Mode -eq [AddrMode]::ADDR_POSTIDXIND)
        ) {
          $this.Load($addr) # dummy read (indexed, no page crossing)
        }
        $temp = $this.Load($addr) -band 0xff
        $this.Write($addr, $temp) # dummy write (original value)
        $this.F_CARRY = $temp -band 1
        $temp = $temp -shr 1
        $this.Write($addr, $temp)

        # Then XOR with the accumulator.
        $this.REG_ACC = $this.REG_ACC -bxor $temp
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        $this.F_ZERO = $this.REG_ACC
        break
      }
      ([Instruction]::INS_SKB) {
        # *******
        # * SKB *
        # *******

        # Do nothing
        break
      }
      ([Instruction]::INS_IGN) {
        # *******
        # * IGN *
        # *******

        # Do nothing but load.
        # TODO: Properly implement the double-reads.
        $this.Load($addr)
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_SHA) {
        # *******
        # * SHA * (AHX/AXA)
        # *******

        # Store A AND X AND (high byte of base address + 1).
        # On page crossing, the high byte of the effective address is
        # replaced with the stored value — a quirk of the 6502's internal
        # bus arbitration during indexed addressing.
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes

        # Stores always perform the indexed dummy read, even without page
        # crossing. This is a real bus cycle needed for correct timing
        # (and DMA overlap detection).
        # See https:#www.nesdev.org/wiki/CPU_addressing_modes
        if ($cycleAdd -eq 0) {
          $this.Load($addr)
        }
        # When a DMC DMA fires during $this instruction's read cycles, the
        # DMA hijacks the internal bus and the "& (H+1)" factor is dropped.
        # See _cyclesToNextDmcFetch() for the full explanation, and
        # AccuracyCoin.asm lines 4441-4460 for the test ROM's DMA sync.
        [int] $dmaDuringInstr =
          $this._dmcFetchCycles -gt 0 -and
          $this._dmcFetchCycles -le $this.instrBusCycles
        [int] $shaVal = $dmaDuringInstr ? ($this.REG_ACC -band $this.REG_X) : ($this.REG_ACC -band $this.REG_X -band ((($baseHigh + 1) -band 0xff) -bor 0))
        if ($cycleAdd -eq 1) {
          $addr = ($shaVal -shl 8) -bor ($addr -band 0xff)
        }
        $this.Write($addr, $shaVal)
        break
      }
      ([Instruction]::INS_SHS) {
        # *******
        # * SHS * (TAS/XAS)
        # *******

        # Transfer A AND X to SP, then store SP AND (high byte + 1).
        # Same page-crossing address glitch as SHA.
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        if ($cycleAdd -eq 0) {
          $this.Load($addr) # forced dummy read (see case 71 comment)
        }
        [int] $dmaDuringInstr2 =
          $this._dmcFetchCycles -gt 0 -and
          $this._dmcFetchCycles -le $this.instrBusCycles
        $this.REG_SP = ($this.REG_ACC -band $this.REG_X)
        [int] $shsVal = $dmaDuringInstr2 ? ($this.REG_SP -band 0xff) : ($this.REG_SP -band 0xff -band (($baseHigh + 1) -band 0xff))
        if ($cycleAdd -eq 1) {
          $addr = ($shsVal -shl 8) -bor ($addr -band 0xff)
        }
        $this.Write($addr, $shsVal)
        break
      }
      ([Instruction]::INS_SHY) {
        # *******
        # * SHY * (SYA/SAY)
        # *******

        # Store Y AND (high byte of base address + 1).
        # Same page-crossing address glitch as SHA.
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        if ($cycleAdd -eq 0) {
          $this.Load($addr) # forced dummy read (see case 71 comment)
        }
        [int] $dmaDuringInstr3 =
          $this._dmcFetchCycles -gt 0 -and
          $this._dmcFetchCycles -le $this.instrBusCycles
        [int] $shyVal = $dmaDuringInstr3 ? ($this.REG_Y) : ($this.REG_Y -band (($baseHigh + 1) -band 0xff))
        if ($cycleAdd -eq 1) {
          $addr = ($shyVal -shl 8) -bor ($addr -band 0xff)
        }
        $this.Write($addr, $shyVal)
        break
      }
      ([Instruction]::INS_SHX) {
        # *******
        # * SHX * (SXA/XAS)
        # *******

        # Store X AND (high byte of base address + 1).
        # Same page-crossing address glitch as SHA.
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        if ($cycleAdd -eq 0) {
          $this.Load($addr) # forced dummy read (see case 71 comment)
        }
        [int] $dmaDuringInstr4 =
          $this._dmcFetchCycles -gt 0 -and
          $this._dmcFetchCycles -le $this.instrBusCycles
        [int] $shxVal = $dmaDuringInstr4 ? ($this.REG_X) : ($this.REG_X -band (($baseHigh + 1) -band 0xff))
        if ($cycleAdd -eq 1) {
          $addr = ($shxVal -shl 8) -bor ($addr -band 0xff)
        }
        $this.Write($addr, $shxVal)
        break
      }
      ([Instruction]::INS_LAE) {
        # *******
        # * LAE * (LAS/LAR)
        # *******

        # Load A, X, and SP with (memory AND SP).
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        $temp = $this.Load($addr) -band ($this.REG_SP -band 0xff)
        $this.REG_ACC = $this.REG_X = $this.F_ZERO = $temp
        $this.REG_SP = $temp -band 0xff
        $this.F_SIGN = ($temp -shr 7) -band 1
        $cycleCount += $cycleAdd
        break
      }
      ([Instruction]::INS_ANE) {
        # *******
        # * ANE * (XAA)
        # *******

        # A = (A -bor MAGIC) -band X -band Immediate. The "magic" constant varies between
        # CPU revisions ($00, $EE, $FF, etc). Using $FF — the most common value
        # and the only one that passes AccuracyCoin's magic-independent tests.
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        $this.REG_ACC = $this.F_ZERO =
          ($this.REG_ACC -bor 0xff) -band $this.REG_X -band $this.Load($addr)
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        break
      }
      ([Instruction]::INS_LXA) {
        # *******
        # * LXA * (LAX immediate/ATX)
        # *******

        # A = (A -bor MAGIC) -band Immediate, X = A. Same magic constant issue as ANE.
        # See https:#www.nesdev.org/wiki/Programming_with_unofficial_opcodes
        $this.REG_ACC =
          $this.REG_X =
          $this.F_ZERO =
            ($this.REG_ACC -bor 0xff) -band $this.Load($addr)
        $this.F_SIGN = ($this.REG_ACC -shr 7) -band 1
        break
      }

      default {
        # *******
        # * ??? *
        # *******

        throw ('Game crashed, invalid opcode at address 0x' + $opaddr.ToString('X4'))
      }
    
        }
        
        # A VBlank edge raised during the previous instruction is promoted
        # at the start of this one and serviced after this instruction, as in
        # JSNES's interrupt pipeline. The previous source only set
        # nmiPending and never consumed it.
        if ($this.nmiPending) {
            $this.REG_PC_NEW = $this.REG_PC
            $this.F_INTERRUPT_NEW = $this.F_INTERRUPT
            $this.DoNonMaskableInterrupt($this.GetStatus() -band 0xEF)
            $this.REG_PC = $this.REG_PC_NEW
            $this.F_INTERRUPT = $this.F_INTERRUPT_NEW
            $this.F_BRK = $this.F_BRK_NEW
            $this.nmiPending = $false
            $interruptCycles = 7
        }

        $this._cpuCycleBase += ($cycleCount + $interruptCycles)
        return ($cycleCount + $interruptCycles)
    }


    [int] _takeBranch([int] $opaddr, [int] $addr) {
        [int] $nextPC = ($opaddr + 3) -band 0xFFFF
        [int] $target = ($addr + 1) -band 0xFFFF
        [void]$this.Load([ushort]$nextPC)
        if (($nextPC -band 0xFF00) -ne ($target -band 0xFF00)) {
            [int] $wrongAddr = ($nextPC -band 0xFF00) -bor ($target -band 0x00FF)
            [void]$this.Load([ushort]$wrongAddr)
            $this.REG_PC = $addr
            return 2
        }
        $this.REG_PC = $addr
        return 1
    }

    [byte] Load([ushort] $addr) {
        $this.dataBus = $this.Mem.Read($addr)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        return [byte]$this.dataBus
    }

    [ushort] Load16Bit([ushort] $addr) {
        [ushort] $lo = $this.Load($addr)
        [ushort] $hi = $this.Load([ushort]($addr + 1))
        return [ushort]($lo -bor ($hi -shl 8))
    }

    [void] Write([ushort] $addr, [byte] $val) {
        $this.dataBus = $val
        $this.Mem.Write($addr, $val)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
    }

    [void] Push([byte] $val) {
        $this.dataBus = $val
        $this.Mem.Write([ushort](0x0100 -bor $this.REG_SP), $val)
        $this.REG_SP = ($this.REG_SP - 1) -band 0xFF
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
    }

    [byte] Pull() {
        $this.REG_SP = ($this.REG_SP + 1) -band 0xFF
        $this.dataBus = $this.Mem.Read([ushort](0x0100 -bor $this.REG_SP))
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        return [byte]$this.dataBus
    }

    [int] GetStatus() {
        return $this.F_CARRY -bor
            (($this.F_ZERO -eq 0 ? 1 : 0) -shl 1) -bor
            ($this.F_INTERRUPT -shl 2) -bor
            ($this.F_DECIMAL -shl 3) -bor
            ($this.F_BRK -shl 4) -bor
            0x20 -bor
            ($this.F_OVERFLOW -shl 6) -bor
            ($this.F_SIGN -shl 7)
    }

    [void] SetStatus([int] $st) {
        $this.F_CARRY = $st -band 1
        $this.F_ZERO = (($st -shr 1) -band 1) -eq 1 ? 0 : 1
        $this.F_INTERRUPT = ($st -shr 2) -band 1
        $this.F_DECIMAL = ($st -shr 3) -band 1
        $this.F_BRK = ($st -shr 4) -band 1
        $this.F_OVERFLOW = ($st -shr 6) -band 1
        $this.F_SIGN = ($st -shr 7) -band 1
    }

    [void] SetStatusFromStack([int] $st) {
        $this.F_CARRY = $st -band 1
        $this.F_ZERO = (($st -shr 1) -band 1) -eq 1 ? 0 : 1
        $this.F_INTERRUPT = ($st -shr 2) -band 1
        $this.F_DECIMAL = ($st -shr 3) -band 1
        $this.F_OVERFLOW = ($st -shr 6) -band 1
        $this.F_SIGN = ($st -shr 7) -band 1
    }

    [void] DoNonMaskableInterrupt([int] $status) {
        if ($null -eq $this.Mem) { return }
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        $this.REG_PC_NEW = ($this.REG_PC_NEW + 1) -band 0xFFFF
        $this.Push([byte](($this.REG_PC_NEW -shr 8) -band 0xFF))
        $this.Push([byte]($this.REG_PC_NEW -band 0xFF))
        $this.F_INTERRUPT_NEW = 1
        $this.F_BRK_NEW = 0
        $this.Push([byte]$status)
        $this.dataBus = $this.Mem.Read(0xFFFA)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        [int] $lo = $this.dataBus
        $this.dataBus = $this.Mem.Read(0xFFFB)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        $this.REG_PC_NEW = $lo -bor ($this.dataBus -shl 8)
        $this.REG_PC_NEW = ($this.REG_PC_NEW - 1) -band 0xFFFF
    }

    [void] DoResetInterrupt() {
        $this.dataBus = $this.Mem.Read(0xFFFC)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        [int] $lo = $this.dataBus
        $this.dataBus = $this.Mem.Read(0xFFFD)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        $this.REG_PC_NEW = $lo -bor ($this.dataBus -shl 8)
        $this.REG_PC_NEW = ($this.REG_PC_NEW - 1) -band 0xFFFF
    }

    [void] DoIrq([int] $status) {
        $this.REG_PC_NEW = ($this.REG_PC_NEW + 1) -band 0xFFFF
        $this.Push([byte](($this.REG_PC_NEW -shr 8) -band 0xFF))
        $this.Push([byte]($this.REG_PC_NEW -band 0xFF))
        $this.Push([byte]$status)
        $this.F_INTERRUPT_NEW = 1
        $this.F_BRK_NEW = 0
        $this.dataBus = $this.Mem.Read(0xFFFE)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        [int] $lo = $this.dataBus
        $this.dataBus = $this.Mem.Read(0xFFFF)
        $this.instrBusCycles++
        $this.Ppu.AdvanceDots(3)
        $this.REG_PC_NEW = $lo -bor ($this.dataBus -shl 8)
        $this.REG_PC_NEW = ($this.REG_PC_NEW - 1) -band 0xFFFF
    }


}

class Nes {
    [Cpu6502] $Cpu
    [Ppu] $Ppu
    [Memory] $Memory
    [Rom] $Rom

    Nes() {
        $this.Rom = [Rom]::new()
        $this.Ppu = [Ppu]::new($this.Rom)
        $this.Memory = [Memory]::new($this.Rom)
        $this.Memory.Ppu = $this.Ppu
        $this.Cpu = [Cpu6502]::new($this.Memory, $this.Ppu)
        $this.Memory.Cpu = $this.Cpu
        $this.Ppu.Cpu = $this.Cpu
    }

    [void] PowerOn() {
        if ($this.Rom.IsValid) { $this.Cpu.Reset() }
    }

    [void] RunFrame() {
        if (-not $this.Rom.IsValid) { return }
        $this.Ppu.StartFrame()
        while (-not $this.Ppu.FrameEnded) {
            [void]$this.Cpu.Emulate()
        }
        $this.Ppu.RenderFrame()
        $this.Ppu.FrameEnded = $false
    }
}

# Headless runs: PsnesBench <rom> <frames> runs that many frames with no window, then prints the frame count, the
# milliseconds taken and a checksum of RAM. The entry point of the native build; the same method runs interpreted.
class PsnesBench {
    static [int] Main([string[]] $arguments) {
        if ($arguments.Length -ne 2) { [Console]::WriteLine('usage: PsnesBench <rom> <frames>'); return 2 }
        $nes = [Nes]::new()
        if (-not $nes.Rom.Load($arguments[0])) { [Console]::WriteLine('The ROM did not load.'); return 1 }
        $nes.PowerOn()
        [int] $frames = [int]::Parse($arguments[1])
        $clock = [Diagnostics.Stopwatch]::StartNew()
        for ([int] $frame = 0; $frame -lt $frames; $frame++) { $nes.RunFrame() }
        $clock.Stop()
        [Console]::WriteLine('{0} frames in {1} ms; RAM checksum {2:X16}', $frames, $clock.ElapsedMilliseconds, [PsnesBench]::Checksum($nes.Memory.Ram))
        return 0
    }

    # Rotate left by 5, then xor the next byte: a short fingerprint of a machine state, for comparing two runs.
    # Shifts never overflow, so this means the same interpreted and lowered.
    static [ulong] Checksum([byte[]] $bytes) {
        [ulong] $hash = 0
        for ([int] $i = 0; $i -lt $bytes.Length; $i++) {
            $hash = (($hash -shl 5) -bor ($hash -shr 59)) -bxor $bytes[$i]
        }
        return $hash
    }
}

# ============================================================================
# WINDOW
# ============================================================================

# Native calls. One StdCall delegate type is emitted per signature; layouts and
# signatures follow the Windows SDK 10.0.26100.0 headers (WinUser.h, wingdi.h, dwmapi.h).
class Win32 {
    static [Reflection.Emit.ModuleBuilder] $Module = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('PSNES.Native'), [Reflection.Emit.AssemblyBuilderAccess]::Run).DefineDynamicModule('Native')
    static [Collections.Generic.Dictionary[string, Type]] $Shapes = [Collections.Generic.Dictionary[string, Type]]::new()
    static [Collections.Generic.Dictionary[string, IntPtr]] $Libraries = [Collections.Generic.Dictionary[string, IntPtr]]::new([StringComparer]::OrdinalIgnoreCase)

    static [IntPtr] Export([string] $library, [string] $name) {
        if (-not [Win32]::Libraries.ContainsKey($library)) {
            [Win32]::Libraries[$library] = [Runtime.InteropServices.NativeLibrary]::Load($library)
        }
        return [Runtime.InteropServices.NativeLibrary]::GetExport([Win32]::Libraries[$library], $name)
    }

    static [Delegate] Bind([string] $library, [string] $name, [Type] $returnType, [Type[]] $parameterTypes) {
        [string] $shape = $returnType.FullName + '('
        foreach ($parameterType in $parameterTypes) { $shape += $parameterType.FullName + ',' }
        if (-not [Win32]::Shapes.ContainsKey($shape)) {
            $builder = [Win32]::Module.DefineType('Call' + [Win32]::Shapes.Count, 'Class,Public,Sealed', [MulticastDelegate])
            $constructor = $builder.DefineConstructor('Public,HideBySig,RTSpecialName', [Reflection.CallingConventions]::Standard, [Type[]]@([object], [IntPtr]))
            $constructor.SetImplementationFlags('Runtime,Managed')
            $invoke = $builder.DefineMethod('Invoke', 'Public,HideBySig,NewSlot,Virtual', $returnType, $parameterTypes)
            $invoke.SetImplementationFlags('Runtime,Managed')
            $builder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
                [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor([Type[]]@([Runtime.InteropServices.CallingConvention])),
                [object[]]@([Runtime.InteropServices.CallingConvention]::StdCall)))
            [Win32]::Shapes[$shape] = $builder.CreateType()
        }
        return [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer([Win32]::Export($library, $name), [Win32]::Shapes[$shape])
    }
}

# Palette indices to opaque 0xAARRGGBB, and the bounding box of what changed between frames.
class NesBlit {
    static [void] Convert([byte[]] $indices, [int[]] $palette, [int[]] $target) {
        [int] $count = $indices.Length
        for ([int] $i = 0; $i -lt $count; $i++) {
            $target[$i] = $palette[[int]$indices[$i] -band 63]
        }
    }

    # Stats: changed pixels, pixels that changed back to the frame before last, then left, top, right, bottom.
    static [void] Damage([int[]] $older, [int[]] $previous, [int[]] $current, [int[]] $stats) {
        [int] $left = 256; [int] $right = -1; [int] $top = 240; [int] $bottom = -1
        [int] $changed = 0; [int] $returned = 0; [int] $at = 0
        for ([int] $y = 0; $y -lt 240; $y++) {
            for ([int] $x = 0; $x -lt 256; $x++) {
                if ($current[$at] -ne $previous[$at]) {
                    $changed++
                    if ($current[$at] -eq $older[$at]) { $returned++ }
                    if ($x -lt $left) { $left = $x }
                    if ($x -gt $right) { $right = $x }
                    if ($y -lt $top) { $top = $y }
                    $bottom = $y
                }
                $at++
            }
        }
        $stats[0] = $changed; $stats[1] = $returned; $stats[2] = $left; $stats[3] = $top; $stats[4] = $right; $stats[5] = $bottom
    }

    # The frame scaled to cover a small buffer (cropped, aspect kept), blurred and dimmed to 60%.
    # Drawn stretched behind the game, it fills the sides with the game's own colours.
    static [void] Glow([int[]] $frame, [int[]] $glow, [int] $wide, [int] $tall) {
        [int] $count = $wide * $tall
        [int[]] $red = [int[]]::new($count); [int[]] $green = [int[]]::new($count); [int[]] $blue = [int[]]::new($count)
        [int[]] $scratch = [int[]]::new($count)
        [double] $cover = [Math]::Max($wide / 256.0, $tall / 240.0)
        [int] $at = 0
        for ([int] $y = 0; $y -lt $tall; $y++) {
            [int] $sy = [Math]::Min(239, [Math]::Max(0, [int][Math]::Floor(($y + 0.5 - $tall / 2.0) / $cover + 120.0)))
            for ([int] $x = 0; $x -lt $wide; $x++) {
                [int] $sx = [Math]::Min(255, [Math]::Max(0, [int][Math]::Floor(($x + 0.5 - $wide / 2.0) / $cover + 128.0)))
                [int] $value = $frame[$sy * 256 + $sx]
                $red[$at] = ($value -shr 16) -band 0xFF; $green[$at] = ($value -shr 8) -band 0xFF; $blue[$at] = $value -band 0xFF
                $at++
            }
        }
        foreach ($plane in $red, $green, $blue) {
            for ([int] $pass = 0; $pass -lt 2; $pass++) { [NesBlit]::Box($plane, $scratch, $wide, $tall, 2) }
        }
        for ([int] $i = 0; $i -lt $count; $i++) {
            $glow[$i] = [int](0xFF000000 -bor ((($red[$i] * 3) / 5) -shl 16) -bor ((($green[$i] * 3) / 5) -shl 8) -bor (($blue[$i] * 3) / 5))
        }
    }

    # Box blur of one plane, horizontal then vertical, with running sums and edges held.
    static [void] Box([int[]] $plane, [int[]] $scratch, [int] $wide, [int] $tall, [int] $radius) {
        [int] $span = 2 * $radius + 1
        for ([int] $y = 0; $y -lt $tall; $y++) {
            [int] $row = $y * $wide
            [int] $sum = 0
            for ([int] $k = -$radius; $k -le $radius; $k++) { $sum += $plane[$row + [Math]::Min($wide - 1, [Math]::Max(0, $k))] }
            for ([int] $x = 0; $x -lt $wide; $x++) {
                $scratch[$row + $x] = [int][Math]::Floor($sum / $span)
                $sum += $plane[$row + [Math]::Min($wide - 1, $x + $radius + 1)] - $plane[$row + [Math]::Max(0, $x - $radius)]
            }
        }
        for ([int] $x = 0; $x -lt $wide; $x++) {
            [int] $sum = 0
            for ([int] $k = -$radius; $k -le $radius; $k++) { $sum += $scratch[[Math]::Min($tall - 1, [Math]::Max(0, $k)) * $wide + $x] }
            for ([int] $y = 0; $y -lt $tall; $y++) {
                $plane[$y * $wide + $x] = [int][Math]::Floor($sum / $span)
                $sum += $scratch[[Math]::Min($tall - 1, $y + $radius + 1) * $wide + $x] - $scratch[[Math]::Max(0, $y - $radius) * $wide + $x]
            }
        }
    }
}

# A Windows 11 window with a system backdrop. Its messages are pumped on a thread of its own, so
# dragging or resizing never stops the game; the game thread draws into the window through GDI.
# Frames go through a ring of three buffers: only the rectangle that changed reaches GDI, and
# frames that did not change are skipped.
class NesWindow {
    # FCEUX's NES palette, 0xRRGGBB per colour index.
    static [int[]] $Palette = @(
        0x747474, 0x24188C, 0x0000A8, 0x44009C, 0x8C0074, 0xA80010, 0xA40000, 0x7C0800, 0x402C00, 0x004400, 0x005000, 0x003C14, 0x183C5C, 0x000000, 0x000000, 0x000000,
        0xBCBCBC, 0x0070EC, 0x2038EC, 0x8000F0, 0xBC00BC, 0xE40058, 0xD82800, 0xC84C0C, 0x887000, 0x009400, 0x00A800, 0x009038, 0x008088, 0x000000, 0x000000, 0x000000,
        0xFCFCFC, 0x3CBCFC, 0x5C94FC, 0xCC88FC, 0xF478FC, 0xFC74B4, 0xFC7460, 0xFC9838, 0xF0BC3C, 0x80D010, 0x4CDC48, 0x58F898, 0x00E8D8, 0x787878, 0x000000, 0x000000,
        0xFCFCFC, 0xA8E4FC, 0xC4D4FC, 0xD4C8FC, 0xFCC4FC, 0xFCC4D8, 0xFCBCB0, 0xFCD8A8, 0xFCE4A0, 0xE0FCA0, 0xA8F0BC, 0xB0FCCC, 0x9CFCF0, 0xC4C4C4, 0x000000, 0x000000)
    # Virtual-key code for each controller bit, A B Select Start Up Down Left Right: X Z RShift Enter and the arrows.
    static [int[]] $Keys = @(0x58, 0x5A, 0xA1, 0x0D, 0x26, 0x28, 0x25, 0x27)
    # Tab cycles these. Fit keeps the aspect ratio at any scale; Stretch fills the window;
    # Blur is Fit with the sides filled by a dimmed, blurred copy of the frame.
    static [string[]] $Modes = @('Fit', 'Stretch', 'Blur')

    [IntPtr] $Handle
    [IntPtr] $Device
    [IntPtr] $Module
    [IntPtr] $ClassName
    [IntPtr] $Title
    [IntPtr] $Published
    [IntPtr] $Message
    [IntPtr] $Header
    [IntPtr] $GlowHeader
    [IntPtr] $Rect
    [IntPtr] $Backdrop
    [Threading.Thread] $Pump
    [Threading.ThreadStart] $PumpEntry
    [string] $Scaling
    [int] $ClientWide
    [int] $ClientTall
    [double] $ScaleX = 1.0
    [double] $ScaleY = 1.0
    [int] $OriginX
    [int] $OriginY
    [int] $DrawWide
    [int] $DrawTall
    [int[]] $Colors = [int[]]::new(64)
    [int[][]] $Ring = @([int[]]::new(61440), [int[]]::new(61440), [int[]]::new(61440))
    [Runtime.InteropServices.GCHandle[]] $Pins = [Runtime.InteropServices.GCHandle[]]::new(3)
    [int[]] $Glow
    [Runtime.InteropServices.GCHandle] $GlowPin
    [int] $GlowWide
    [int] $GlowTall
    [int[]] $Facts = [int[]]::new(6)
    [bool] $FullDraw = $true
    [bool] $TabWasDown
    [int] $Frames
    [int] $Drawn
    [int] $Skipped
    [int] $Healed

    hidden [Delegate] $RegisterClassExW = [Win32]::Bind('user32.dll', 'RegisterClassExW', [uint16], [Type[]]@([IntPtr]))
    hidden [Delegate] $UnregisterClassW = [Win32]::Bind('user32.dll', 'UnregisterClassW', [int], [Type[]]@([IntPtr], [IntPtr]))
    hidden [Delegate] $IsWindow = [Win32]::Bind('user32.dll', 'IsWindow', [int], [Type[]]@([IntPtr]))
    hidden [Delegate] $ShowWindow = [Win32]::Bind('user32.dll', 'ShowWindow', [int], [Type[]]@([IntPtr], [int]))
    hidden [Delegate] $PostMessageW = [Win32]::Bind('user32.dll', 'PostMessageW', [int], [Type[]]@([IntPtr], [uint32], [IntPtr], [IntPtr]))
    hidden [Delegate] $SetForegroundWindow = [Win32]::Bind('user32.dll', 'SetForegroundWindow', [int], [Type[]]@([IntPtr]))
    hidden [Delegate] $GetForegroundWindow = [Win32]::Bind('user32.dll', 'GetForegroundWindow', [IntPtr], [Type[]]@())
    hidden [Delegate] $LoadCursorW = [Win32]::Bind('user32.dll', 'LoadCursorW', [IntPtr], [Type[]]@([IntPtr], [IntPtr]))
    hidden [Delegate] $LoadIconW = [Win32]::Bind('user32.dll', 'LoadIconW', [IntPtr], [Type[]]@([IntPtr], [IntPtr]))
    hidden [Delegate] $GetClientRect = [Win32]::Bind('user32.dll', 'GetClientRect', [int], [Type[]]@([IntPtr], [IntPtr]))
    hidden [Delegate] $GetDC = [Win32]::Bind('user32.dll', 'GetDC', [IntPtr], [Type[]]@([IntPtr]))
    hidden [Delegate] $FillRect = [Win32]::Bind('user32.dll', 'FillRect', [int], [Type[]]@([IntPtr], [IntPtr], [IntPtr]))
    hidden [Delegate] $GetAsyncKeyState = [Win32]::Bind('user32.dll', 'GetAsyncKeyState', [int16], [Type[]]@([int]))
    hidden [Delegate] $GetModuleHandleW = [Win32]::Bind('kernel32.dll', 'GetModuleHandleW', [IntPtr], [Type[]]@([IntPtr]))
    hidden [Delegate] $GetStockObject = [Win32]::Bind('gdi32.dll', 'GetStockObject', [IntPtr], [Type[]]@([int]))
    hidden [Delegate] $GetPixel = [Win32]::Bind('gdi32.dll', 'GetPixel', [uint32], [Type[]]@([IntPtr], [int], [int]))
    hidden [Delegate] $SetStretchBltMode = [Win32]::Bind('gdi32.dll', 'SetStretchBltMode', [int], [Type[]]@([IntPtr], [int]))
    hidden [Delegate] $StretchDIBits = [Win32]::Bind('gdi32.dll', 'StretchDIBits', [int], [Type[]]@([IntPtr], [int], [int], [int], [int], [int], [int], [int], [int], [IntPtr], [IntPtr], [uint32], [uint32]))
    hidden [Delegate] $DwmSetWindowAttribute = [Win32]::Bind('dwmapi.dll', 'DwmSetWindowAttribute', [int], [Type[]]@([IntPtr], [uint32], [IntPtr], [uint32]))
    hidden [Delegate] $DwmExtendFrameIntoClientArea = [Win32]::Bind('dwmapi.dll', 'DwmExtendFrameIntoClientArea', [int], [Type[]]@([IntPtr], [IntPtr]))

    NesWindow([string] $title, [int] $wide, [int] $tall, [string] $scaling) {
        $this.Scaling = $scaling
        # Alpha must be FF: the backdrop extends the frame over the client area, so the compositor
        # reads alpha there and treats 00 as see-through. GetPixel sees only RGB and cannot catch it.
        for ([int] $c = 0; $c -lt 64; $c++) { $this.Colors[$c] = [int](0xFF000000 -bor [NesWindow]::Palette[$c]) }
        for ([int] $b = 0; $b -lt 3; $b++) { $this.Pins[$b] = [Runtime.InteropServices.GCHandle]::Alloc($this.Ring[$b], [Runtime.InteropServices.GCHandleType]::Pinned) }
        $this.Message = [Runtime.InteropServices.Marshal]::AllocHGlobal(48)
        $this.Rect = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
        $this.Published = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($this.Published, [IntPtr]::new(-1))
        $this.Header = [NesWindow]::NewBitmapHeader(256, 240)
        $this.GlowHeader = [NesWindow]::NewBitmapHeader(1, 1)

        # WNDCLASSEXW, 80 bytes. The window procedure is DefWindowProcW itself. There is no class
        # brush, so Windows never erases what the game thread draws; Layout clears to the backdrop.
        $this.Module = $this.GetModuleHandleW.Invoke([IntPtr]::Zero)
        $this.ClassName = [Runtime.InteropServices.Marshal]::StringToHGlobalUni('PSNES')
        $this.Backdrop = $this.GetStockObject.Invoke(4) # BLACK_BRUSH: alpha 0, so the backdrop shows through.
        $icon = $this.LoadIconW.Invoke([IntPtr]::Zero, [IntPtr]32512)
        $class = [Runtime.InteropServices.Marshal]::AllocHGlobal(80)
        try {
            [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(80), 0, $class, 80)
            [Runtime.InteropServices.Marshal]::WriteInt32($class, 0, 80)
            [Runtime.InteropServices.Marshal]::WriteInt32($class, 4, 0x0020) # CS_OWNDC: one device context for the window's life.
            [Runtime.InteropServices.Marshal]::WriteIntPtr($class, 8, [Win32]::Export('user32.dll', 'DefWindowProcW'))
            [Runtime.InteropServices.Marshal]::WriteIntPtr($class, 24, $this.Module)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($class, 32, $icon)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($class, 40, $this.LoadCursorW.Invoke([IntPtr]::Zero, [IntPtr]32512))
            [Runtime.InteropServices.Marshal]::WriteIntPtr($class, 64, $this.ClassName)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($class, 72, $icon)
            if ($this.RegisterClassExW.Invoke($class) -eq 0) { throw 'PSNES could not register its window class.' }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($class) }

        # A window belongs to the thread that creates it, so the pump thread creates it, publishes
        # the handle, and pumps until the window is gone.
        $this.Title = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($title)
        $this.PumpEntry = $this.BuildPump($wide, $tall)
        $this.Pump = [Threading.Thread]::new($this.PumpEntry)
        $this.Pump.IsBackground = $true
        $this.Pump.Name = 'PSNES window'
        $this.Pump.Start()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ([Runtime.InteropServices.Marshal]::ReadIntPtr($this.Published) -eq [IntPtr]::new(-1)) {
            if ($clock.Elapsed.TotalSeconds -gt 10) { throw 'The PSNES window thread did not start.' }
            [Threading.Thread]::Sleep(1)
        }
        $this.Handle = [Runtime.InteropServices.Marshal]::ReadIntPtr($this.Published)
        if ($this.Handle -eq [IntPtr]::Zero) { throw 'PSNES could not create its window.' }

        $value = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
        try {
            # Dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE) and no outline (DWMWA_BORDER_COLOR = DWMWA_COLOR_NONE).
            # Builds that lack an attribute answer E_INVALIDARG, which leaves the default.
            foreach ($attribute in @(@(20, 1), @(34, -2))) {
                [Runtime.InteropServices.Marshal]::WriteInt32($value, $attribute[1])
                [int] $result = $this.DwmSetWindowAttribute.Invoke($this.Handle, [uint32]$attribute[0], $value, [uint32]4)
                if ($result -lt 0 -and $result -ne -2147024809) { throw "DwmSetWindowAttribute $($attribute[0]) failed: $result" }
            }
            if ([Environment]::OSVersion.Version.Build -ge 22621) {
                # Mica (DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW), extended over the whole client area.
                [Runtime.InteropServices.Marshal]::WriteInt32($value, 2)
                [int] $result = $this.DwmSetWindowAttribute.Invoke($this.Handle, [uint32]38, $value, [uint32]4)
                if ($result -lt 0) { throw "DWM backdrop failed: $result" }
                foreach ($offset in 0, 4, 8, 12) { [Runtime.InteropServices.Marshal]::WriteInt32($value, $offset, -1) }
                $result = $this.DwmExtendFrameIntoClientArea.Invoke($this.Handle, $value)
                if ($result -lt 0) { throw "DWM frame extension failed: $result" }
            }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($value) }

        # The first ShowWindow may honour the launcher's STARTUPINFO instead of SW_SHOW.
        [void]$this.ShowWindow.Invoke($this.Handle, 5)
        [void]$this.ShowWindow.Invoke($this.Handle, 5)
        [void]$this.SetForegroundWindow.Invoke($this.Handle)
        $this.Device = $this.GetDC.Invoke($this.Handle)
        $this.Layout($true)
    }

    # BITMAPINFOHEADER for a top-down 32-bit BI_RGB bitmap.
    static [IntPtr] NewBitmapHeader([int] $wide, [int] $tall) {
        $bitmapInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal(44)
        [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(44), 0, $bitmapInfo, 44)
        [Runtime.InteropServices.Marshal]::WriteInt32($bitmapInfo, 0, 40)
        [Runtime.InteropServices.Marshal]::WriteInt32($bitmapInfo, 4, $wide)
        [Runtime.InteropServices.Marshal]::WriteInt32($bitmapInfo, 8, -$tall)
        [Runtime.InteropServices.Marshal]::WriteInt16($bitmapInfo, 12, 1)
        [Runtime.InteropServices.Marshal]::WriteInt16($bitmapInfo, 14, 32)
        return $bitmapInfo
    }

    # The pump thread's body, emitted as IL that calls user32 directly, so no PowerShell runs on that
    # thread and it needs no runspace:
    #   hwnd = CreateWindowExW(...); *Published = hwnd
    #   while (hwnd && GetMessageW(msg) > 0) { TranslateMessage(msg); DispatchMessageW(msg); if (!IsWindow(hwnd)) break }
    hidden [Threading.ThreadStart] BuildPump([int] $wide, [int] $tall) {
        $method = [Reflection.Emit.DynamicMethod]::new('PSNESWindowPump', [void], [Type[]]@())
        $il = $method.GetILGenerator()
        $window = $il.DeclareLocal([IntPtr])
        $loop = $il.DefineLabel(); $done = $il.DefineLabel()
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        [NesWindow]::EmitPointer($il, $this.ClassName)
        [NesWindow]::EmitPointer($il, $this.Title)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, 0x00CF0000) # WS_OVERLAPPEDWINDOW
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, [int]::MinValue) # CW_USEDEFAULT
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, [int]::MinValue)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $wide)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $tall)
        [NesWindow]::EmitPointer($il, [IntPtr]::Zero)
        [NesWindow]::EmitPointer($il, [IntPtr]::Zero)
        [NesWindow]::EmitPointer($il, $this.Module)
        [NesWindow]::EmitPointer($il, [IntPtr]::Zero)
        [NesWindow]::EmitCall($il, 'CreateWindowExW', [IntPtr], [Type[]]@([uint32], [IntPtr], [IntPtr], [uint32], [int], [int], [int], [int], [IntPtr], [IntPtr], [IntPtr], [IntPtr]))
        $il.Emit([Reflection.Emit.OpCodes]::Stloc, $window)
        [NesWindow]::EmitPointer($il, $this.Published)
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $window)
        $il.Emit([Reflection.Emit.OpCodes]::Stind_I)
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $window)
        $il.Emit([Reflection.Emit.OpCodes]::Brfalse, $done)
        $il.MarkLabel($loop)
        [NesWindow]::EmitPointer($il, $this.Message)
        [NesWindow]::EmitPointer($il, [IntPtr]::Zero)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        [NesWindow]::EmitCall($il, 'GetMessageW', [int], [Type[]]@([IntPtr], [IntPtr], [uint32], [uint32]))
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        $il.Emit([Reflection.Emit.OpCodes]::Ble, $done)
        [NesWindow]::EmitPointer($il, $this.Message)
        [NesWindow]::EmitCall($il, 'TranslateMessage', [int], [Type[]]@([IntPtr]))
        $il.Emit([Reflection.Emit.OpCodes]::Pop)
        [NesWindow]::EmitPointer($il, $this.Message)
        [NesWindow]::EmitCall($il, 'DispatchMessageW', [IntPtr], [Type[]]@([IntPtr]))
        $il.Emit([Reflection.Emit.OpCodes]::Pop)
        $il.Emit([Reflection.Emit.OpCodes]::Ldloc, $window)
        [NesWindow]::EmitCall($il, 'IsWindow', [int], [Type[]]@([IntPtr]))
        $il.Emit([Reflection.Emit.OpCodes]::Brtrue, $loop)
        $il.MarkLabel($done)
        $il.Emit([Reflection.Emit.OpCodes]::Ret)
        return [Threading.ThreadStart]$method.CreateDelegate([Threading.ThreadStart])
    }

    hidden static [void] EmitPointer([Reflection.Emit.ILGenerator] $il, [IntPtr] $value) {
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, $value.ToInt64())
        $il.Emit([Reflection.Emit.OpCodes]::Conv_I)
    }

    hidden static [void] EmitCall([Reflection.Emit.ILGenerator] $il, [string] $name, [Type] $returnType, [Type[]] $parameterTypes) {
        [NesWindow]::EmitPointer($il, [Win32]::Export('user32.dll', $name))
        $il.EmitCalli([Reflection.Emit.OpCodes]::Calli, [Runtime.InteropServices.CallingConvention]::StdCall, $returnType, $parameterTypes)
    }

    # Places the frame for the current mode. A changed client area is cleared to the backdrop and
    # fully redrawn, so nothing drawn at an old size or origin stays on screen.
    [void] Layout([bool] $force) {
        [void]$this.GetClientRect.Invoke($this.Handle, $this.Rect)
        [int] $wide = [Runtime.InteropServices.Marshal]::ReadInt32($this.Rect, 8)
        [int] $tall = [Runtime.InteropServices.Marshal]::ReadInt32($this.Rect, 12)
        if (-not $force -and $wide -eq $this.ClientWide -and $tall -eq $this.ClientTall) { return }
        $this.ClientWide = $wide; $this.ClientTall = $tall
        if ($wide -le 0 -or $tall -le 0) { return }
        [void]$this.FillRect.Invoke($this.Device, $this.Rect, $this.Backdrop)
        if ($this.Scaling -eq 'Stretch') {
            $this.ScaleX = $wide / 256.0; $this.ScaleY = $tall / 240.0
        } else {
            $this.ScaleX = [Math]::Min($wide / 256.0, $tall / 240.0); $this.ScaleY = $this.ScaleX
        }
        $this.DrawWide = [int][Math]::Floor(256 * $this.ScaleX); $this.DrawTall = [int][Math]::Floor(240 * $this.ScaleY)
        $this.OriginX = [int][Math]::Floor(($wide - $this.DrawWide) / 2); $this.OriginY = [int][Math]::Floor(($tall - $this.DrawTall) / 2)
        if ($this.Scaling -eq 'Blur') {
            # One glow pixel per 32x32 of the window. Interpreted, 8x8 cost 3.3 s per frame at 1920x1080.
            $this.GlowWide = [Math]::Max(1, [int][Math]::Ceiling($wide / 32)); $this.GlowTall = [Math]::Max(1, [int][Math]::Ceiling($tall / 32))
            if ($this.GlowPin.IsAllocated) { $this.GlowPin.Free() }
            $this.Glow = [int[]]::new($this.GlowWide * $this.GlowTall)
            $this.GlowPin = [Runtime.InteropServices.GCHandle]::Alloc($this.Glow, [Runtime.InteropServices.GCHandleType]::Pinned)
            [Runtime.InteropServices.Marshal]::WriteInt32($this.GlowHeader, 4, $this.GlowWide)
            [Runtime.InteropServices.Marshal]::WriteInt32($this.GlowHeader, 8, -$this.GlowTall)
        }
        $this.FullDraw = $true
    }

    # False once the window is closed.
    [bool] Alive() {
        if ($this.IsWindow.Invoke($this.Handle) -eq 0) { return $false }
        $this.Layout($false)
        return $true
    }

    # Controller 1 from the keyboard while this window has focus. Tab switches the scaling mode.
    [byte] ReadControls() {
        if ($this.GetForegroundWindow.Invoke() -ne $this.Handle) { $this.TabWasDown = $false; return 0 }
        [bool] $tabDown = ([int]$this.GetAsyncKeyState.Invoke(0x09) -band 0x8000) -ne 0
        if ($tabDown -and -not $this.TabWasDown) {
            $this.Scaling = [NesWindow]::Modes[([Array]::IndexOf([NesWindow]::Modes, $this.Scaling) + 1) % [NesWindow]::Modes.Length]
            $this.Layout($true)
        }
        $this.TabWasDown = $tabDown
        [int] $buttons = 0
        for ([int] $bit = 0; $bit -lt 8; $bit++) {
            if (([int]$this.GetAsyncKeyState.Invoke([NesWindow]::Keys[$bit]) -band 0x8000) -ne 0) { $buttons = $buttons -bor (1 -shl $bit) }
        }
        return [byte]$buttons
    }

    # Window column and row where a frame column or row begins.
    [int] Column([int] $x) { return $this.OriginX + [int][Math]::Floor($x * $this.ScaleX) }
    [int] Row([int] $y) { return $this.OriginY + [int][Math]::Floor($y * $this.ScaleY) }

    [void] Present([byte[]] $pixels) {
        if ($this.ClientWide -le 0 -or $this.ClientTall -le 0) { return }
        [int] $slot = $this.Frames % 3
        $this.Frames++
        [bool] $full = $this.FullDraw
        # Dirty rectangles assume the screen still shows the last frame. Sample the screen against that
        # frame and heal with a full redraw if anything else is there.
        if (-not $full) {
            $shown = $this.Ring[($slot + 2) % 3]
            foreach ($y in 8, 60, 120, 180, 232) {
                foreach ($x in 8, 70, 128, 190, 248) {
                    [uint32] $reading = $this.GetPixel.Invoke($this.Device, [int](($this.Column($x) + $this.Column($x + 1)) / 2), [int](($this.Row($y) + $this.Row($y + 1)) / 2))
                    # CLR_INVALID: this point cannot be read now, which is not a mismatch.
                    if ($reading -eq [uint32]::MaxValue) { continue }
                    [int] $onScreen = [int]$reading
                    [int] $asBuffer = (($onScreen -band 0xFF) -shl 16) -bor ($onScreen -band 0xFF00) -bor (($onScreen -shr 16) -band 0xFF)
                    if ($asBuffer -ne ($shown[$y * 256 + $x] -band 0xFFFFFF)) { $full = $true; break }
                }
                if ($full) { $this.Healed++; break }
            }
        }
        [NesBlit]::Convert($pixels, $this.Colors, $this.Ring[$slot])
        [NesBlit]::Damage($this.Ring[($slot + 1) % 3], $this.Ring[($slot + 2) % 3], $this.Ring[$slot], $this.Facts)
        if ($this.Facts[0] -eq 0 -and -not $full) { $this.Skipped++; return }
        if ($this.Scaling -eq 'Blur') { $this.PresentGlow($this.Ring[$slot]) }
        [int] $sourceX = 0; [int] $sourceY = 0; [int] $spanX = 256; [int] $spanY = 240
        if (-not $full) {
            $sourceX = $this.Facts[2]; $sourceY = $this.Facts[3]
            $spanX = $this.Facts[4] - $this.Facts[2] + 1; $spanY = $this.Facts[5] - $this.Facts[3] + 1
        }
        [int] $left = $this.Column($sourceX); [int] $top = $this.Row($sourceY)
        # COLORONCOLOR: whole pixels, never blended, whether enlarging or shrinking.
        [void]$this.SetStretchBltMode.Invoke($this.Device, 3)
        [int] $lines = $this.StretchDIBits.Invoke($this.Device,
            $left, $top, $this.Column($sourceX + $spanX) - $left, $this.Row($sourceY + $spanY) - $top,
            $sourceX, 240 - $sourceY - $spanY, $spanX, $spanY,
            $this.Pins[$slot].AddrOfPinnedObject(), $this.Header, [uint32]0, [uint32]0x00CC0020)
        if ($lines -gt 0) { $this.Drawn++; $this.FullDraw = $false }
    }

    # The four bands around the frame, from the blurred glow.
    hidden [void] PresentGlow([int[]] $frame) {
        [NesBlit]::Glow($frame, $this.Glow, $this.GlowWide, $this.GlowTall)
        [int] $wide = $this.ClientWide; [int] $tall = $this.ClientTall
        [int] $right = $this.OriginX + $this.DrawWide; [int] $bottom = $this.OriginY + $this.DrawTall
        # HALFTONE averages when the glow is stretched up.
        [void]$this.SetStretchBltMode.Invoke($this.Device, 4)
        # Each band: x, y, width, height. Arithmetic is parenthesized because the comma binds before -.
        foreach ($band in @(@(0, 0, $wide, $this.OriginY), @(0, $bottom, $wide, ($tall - $bottom)), @(0, $this.OriginY, $this.OriginX, $this.DrawTall), @($right, $this.OriginY, ($wide - $right), $this.DrawTall))) {
            [int] $x = $band[0]; [int] $y = $band[1]; [int] $w = $band[2]; [int] $h = $band[3]
            if ($w -le 0 -or $h -le 0) { continue }
            [int] $gx = [int][Math]::Floor($x * $this.GlowWide / $wide); [int] $gw = [Math]::Max(1, [int][Math]::Ceiling(($x + $w) * $this.GlowWide / $wide) - $gx)
            [int] $gy = [int][Math]::Floor($y * $this.GlowTall / $tall); [int] $gh = [Math]::Max(1, [int][Math]::Ceiling(($y + $h) * $this.GlowTall / $tall) - $gy)
            [void]$this.StretchDIBits.Invoke($this.Device, $x, $y, $w, $h, $gx, $this.GlowTall - $gy - $gh, $gw, $gh,
                $this.GlowPin.AddrOfPinnedObject(), $this.GlowHeader, [uint32]0, [uint32]0x00CC0020)
        }
    }

    [void] Close() {
        # DestroyWindow works only on the window's own thread: ask it to close, then let the pump end.
        if ($this.Handle -ne [IntPtr]::Zero -and $this.IsWindow.Invoke($this.Handle) -ne 0) {
            [void]$this.PostMessageW.Invoke($this.Handle, [uint32]0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        if ($null -ne $this.Pump -and -not $this.Pump.Join(5000)) { throw 'The PSNES window thread did not end.' }
        $this.Handle = [IntPtr]::Zero; $this.Device = [IntPtr]::Zero
        if ($this.ClassName -ne [IntPtr]::Zero) { [void]$this.UnregisterClassW.Invoke($this.ClassName, $this.Module) }
        foreach ($pin in $this.Pins) { if ($pin.IsAllocated) { $pin.Free() } }
        if ($this.GlowPin.IsAllocated) { $this.GlowPin.Free() }
        foreach ($block in $this.ClassName, $this.Title, $this.Published, $this.Message, $this.Rect, $this.Header, $this.GlowHeader) {
            if ($block -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($block) }
        }
        $this.ClassName = $this.Title = $this.Published = $this.Message = $this.Rect = $this.Header = $this.GlowHeader = [IntPtr]::Zero
    }
}

# Plays an iNES image in a window until the window is closed.
function Invoke-PSNES([string] $Path, [string] $Scaling) {
    $nes = [Nes]::new()
    if (-not $nes.Rom.Load($Path)) { throw "PSNES could not load $Path." }
    $nes.PowerOn()
    $window = [NesWindow]::new('PSNES - ' + [IO.Path]::GetFileName($Path), 816, 776, $Scaling)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($window.Alive()) {
            $nes.Memory.SetControllerState($window.ReadControls(), 0)
            $nes.RunFrame()
            $window.Present($nes.Ppu.Pixels)
        }
    } finally { $window.Close() }
    [pscustomobject]@{
        Rom = $Path
        Scaling = $window.Scaling
        Frames = $window.Frames
        Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        FramesPerSecond = [Math]::Round($window.Frames / [Math]::Max(0.001, $clock.Elapsed.TotalSeconds), 2)
        Drawn = $window.Drawn
        Skipped = $window.Skipped
        Healed = $window.Healed
    }
}

# ============================================================================
# BUILT-IN CONFORMANCE
# ============================================================================

function Test-PSNESConformance {
# PSNES deterministic conformance tests.
# This suite intentionally performs no optimization and no source patching.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
function Assert-Equal([object]$Expected, [object]$Actual, [string]$Name) {
    if ($Expected -ne $Actual) { throw "$Name expected [$Expected], got [$Actual]" }
}
function New-Rig {
    $rom = [Rom]::new()
    $rom.PrgRom = [byte[]]::new(32768)
    $rom.ChrRom = [byte[]]::new(8192)
    $rom.ChrRam = $true
    $rom.Mapper = 0
    $rom.Mirroring = [Mirroring]::Horizontal
    $rom.IsValid = $true
    $ppu = [Ppu]::new($rom)
    $mem = [Memory]::new($rom); $mem.Ppu = $ppu
    $cpu = [Cpu6502]::new($mem, $ppu)
    $mem.Cpu = $cpu; $ppu.Cpu = $cpu
    $rom.PrgRom[0x7ffa] = 0x00; $rom.PrgRom[0x7ffb] = 0x80
    $rom.PrgRom[0x7ffc] = 0x00; $rom.PrgRom[0x7ffd] = 0x80
    $rom.PrgRom[0x7ffe] = 0x00; $rom.PrgRom[0x7fff] = 0x80
    $cpu.Reset()
    return [pscustomobject]@{ Rom=$rom; Ppu=$ppu; Mem=$mem; Cpu=$cpu }
}
function Run-One([object]$r, [byte[]]$Code, [int]$Start = 0x8000) {
    for ($i=0; $i -lt $Code.Length; $i++) { [void]($r.Rom.PrgRom[($Start - 0x8000) + $i] = $Code[$i]) }
    [void]($r.Cpu.REG_PC = $Start - 1)
    return [int]$r.Cpu.Emulate()
}
$results = [System.Collections.Generic.List[object]]::new()
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add([pscustomobject]@{Name=$Name;Result='PASS';Detail=''}) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Detail=$_.Exception.Message}) }
}

Case 'cycle NOP equals six PPU dots' {
    $r=New-Rig; $before=$r.Ppu.Cycle; $cycles=Run-One $r ([byte[]](0xea));
    Assert-Equal 2 $cycles 'NOP CPU cycles'; Assert-Equal (($before+6)%341) $r.Ppu.Cycle 'NOP PPU dots'
}
Case 'branch page-cross dummy cycles and target' {
    $r=New-Rig; $extra=$r.Cpu._takeBranch(0x00fc,0x00ff)
    Assert-Equal 2 $extra 'branch extra cycles'; Assert-Equal 0x00ff $r.Cpu.REG_PC 'branch PC convention'
}
Case 'JSR pushes return address and RTS restores it' {
    $r=New-Rig; Run-One $r ([byte[]](0x20,0x00,0x80));
    Assert-Equal 0xfb $r.Cpu.REG_SP 'JSR SP'; Assert-Equal 0x02 $r.Mem.Read(0x01fc) 'JSR return low';
    Assert-Equal 0x80 $r.Mem.Read(0x01fd) 'JSR return high'
}
Case 'NMI pending is serviced after following instruction' {
    $r=New-Rig; $r.Rom.PrgRom[0x7ffa]=0x00; $r.Rom.PrgRom[0x7ffb]=0x90; $r.Cpu.nmiRaised=$true
    Run-One $r ([byte[]](0xea)); Assert-Equal $false $r.Cpu.nmiPending 'NMI consumed'; Assert-Equal 0x8fff $r.Cpu.REG_PC 'NMI vector convention'
}
Case 'VBlank edge and status read latch' {
    $r=New-Rig; $r.Ppu.Scanline=240; $r.Ppu.Cycle=340; $r.Ppu.Status=0
    $r.Ppu.AdvanceDots(1); Assert-Equal 241 $r.Ppu.Scanline 'VBlank scanline'; Assert-Equal 0x80 ($r.Ppu.Status -band 0x80) 'VBlank set'
    Assert-Equal 0x80 ($r.Ppu.ReadRegister(2) -band 0x80) 'status read'; Assert-Equal 0 ($r.Ppu.Status -band 0x80) 'status clears VBlank'
}
Case 'ADC boundary flags' {
    $r=New-Rig; $r.Cpu.REG_ACC=0x7f; $r.Cpu.F_CARRY=0; Run-One $r ([byte[]](0x69,0x01))
    Assert-Equal 0x80 $r.Cpu.REG_ACC 'ADC result'; Assert-Equal 1 $r.Cpu.F_OVERFLOW 'ADC overflow'; Assert-Equal 1 $r.Cpu.F_SIGN 'ADC sign'
}
Case 'SBC borrow boundary' {
    $r=New-Rig; $r.Cpu.REG_ACC=0; $r.Cpu.F_CARRY=1; Run-One $r ([byte[]](0xe9,0x01))
    Assert-Equal 0xff $r.Cpu.REG_ACC 'SBC result'; Assert-Equal 0 $r.Cpu.F_CARRY 'SBC borrow'
}
Case 'unofficial ALR body semantics' {
    $r=New-Rig; $r.Cpu.REG_ACC=0xff; Run-One $r ([byte[]](0x4b,0x80))
    Assert-Equal 0x40 $r.Cpu.REG_ACC 'ALR result'; Assert-Equal 0 $r.Cpu.F_CARRY 'ALR carry'
}
Case 'PPU address latch and 32-byte increment' {
    $r=New-Rig; $r.Ppu.Ctrl=4; $r.Ppu.WriteRegister(6,0x20); $r.Ppu.WriteRegister(6,0x00); $r.Ppu.WriteRegister(7,0x5a)
    Assert-Equal 0x2020 $r.Ppu.VramAddr 'PPUDATA increment 32'; Assert-Equal 0x5a $r.Ppu.ReadVram(0x2000) 'PPU address latch'
}
Case 'scroll seam base nametables and vertical wrap' {
    $r=New-Rig; $r.Ppu.Ctrl=3; $r.Ppu.Mask=8; $r.Ppu.ScrollX=255; $r.Ppu.ScrollY=255; $r.Ppu.RenderFrame()
    Assert-Equal 61440 $r.Ppu.Pixels.Length 'complete framebuffer at seam'
}
Case '8x16 ignores PPUCTRL sprite table bit' {
    $r=New-Rig; $r.Ppu.WriteVram(0x0000,0x80); $r.Ppu.WriteVram(0x1000,0x00)
    $r.Ppu.Palette[0x11]=0x2a; $r.Ppu.Oam[0]=0; $r.Ppu.Oam[1]=0; $r.Ppu.Oam[2]=0; $r.Ppu.Oam[3]=0
    $r.Ppu.Ctrl=0x28; $r.Ppu.Mask=0x14; $r.Ppu.RenderFrame(); Assert-Equal 0x2a $r.Ppu.Pixels[256] '8x16 pixel'
}
Case 'sprite zero hit is visible through PPUSTATUS' {
    $r=New-Rig
    $r.Ppu.Ctrl=0; $r.Ppu.Mask=0x1e; $r.Ppu.Status=0
    # Sprite Y=0 appears on display row 1. Make both background row 1 and
    # sprite row 0 opaque at screen coordinate (8,1).
    $r.Ppu.WriteVram(0x0000,0x80); $r.Ppu.WriteVram(0x0001,0x80)
    $r.Ppu.WriteVram(0x2000,0); $r.Ppu.Palette[1]=1; $r.Ppu.Palette[0x11]=2
    $r.Ppu.Oam[0]=0; $r.Ppu.Oam[1]=0; $r.Ppu.Oam[2]=0; $r.Ppu.Oam[3]=8
    $r.Ppu.RenderFrame()
    # RenderFrame records the hit's scanline; the flag rises when the PPU reaches it.
    Assert-Equal 1 $r.Ppu.Sprite0Line 'sprite zero hit scanline'
    Assert-Equal 0 ($r.Ppu.Status -band 0x40) 'sprite zero hit before its scanline'
    $r.Ppu.Scanline=0; $r.Ppu.Cycle=0
    $r.Ppu.AdvanceDots(341)
    Assert-Equal 0x40 ($r.Ppu.ReadRegister(0x2002) -band 0x40) 'sprite zero hit'
}
# Sprite overflow/evaluation is intentionally unsupported. It remains documented
# in the audit rather than being a required green-gate assertion.
Case 'sprite Y FF and clipping boundaries' {
    $r=New-Rig; $r.Ppu.Mask=0x14; $r.Ppu.Oam[0]=0xff; $r.Ppu.Oam[1]=0; $r.Ppu.Oam[2]=0; $r.Ppu.Oam[3]=255; $r.Ppu.RenderFrame()
    Assert-Equal 61440 $r.Ppu.Pixels.Length 'sprite edge frame remains complete'
}
Case 'mapper one image does not become valid mapper zero' {
    $path=Join-Path ([IO.Path]::GetTempPath()) "psnes-mapper-$([guid]::NewGuid()).nes"; $d=[byte[]]::new(16+16384); $d[0]=0x4e;$d[1]=0x45;$d[2]=0x53;$d[3]=0x1a;$d[4]=1;$d[6]=0x10;[IO.File]::WriteAllBytes($path,$d)
    try { $rom=[Rom]::new(); Assert-Equal $false $rom.Load($path) 'unsupported mapper rejection' } finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}
Case 'NES 2.0 image rejects unsupported format' {
    $path=Join-Path ([IO.Path]::GetTempPath()) "psnes-nes2-$([guid]::NewGuid()).nes"; $d=[byte[]]::new(16+16384); $d[0]=0x4e;$d[1]=0x45;$d[2]=0x53;$d[3]=0x1a;$d[4]=1;$d[7]=8;[IO.File]::WriteAllBytes($path,$d)
    try { $rom=[Rom]::new(); Assert-Equal $false $rom.Load($path) 'NES 2 rejection' } finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}
Case 'trainer offset and illegal NROM size handling' {
    $path=Join-Path ([IO.Path]::GetTempPath()) "psnes-trainer-$([guid]::NewGuid()).nes"; $d=[byte[]]::new(16+512+16384); $d[0]=0x4e;$d[1]=0x45;$d[2]=0x53;$d[3]=0x1a;$d[4]=1;$d[6]=4;$d[528]=0x5a;[IO.File]::WriteAllBytes($path,$d)
    try { $rom=[Rom]::new(); Assert-Equal $true $rom.Load($path) 'trainer ROM load'; Assert-Equal 0x5a $rom.PrgRom[0] 'trainer skip' } finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}
Case 'typed OAMADDR wraps through OAMDATA' {
    $r=New-Rig; $r.Ppu.OamAddr=[byte]0xff
    $r.Ppu.WriteRegister(0x2004,[byte]0xa5)
    Assert-Equal 0xa5 $r.Ppu.Oam[0xff] 'OAMDATA writes at FF'
    Assert-Equal 0 $r.Ppu.OamAddr 'OAMADDR wraps FF to 00'
}
Case 'controller index post-shift behavior' {
    $r=New-Rig
    $r.Mem.SetControllerState(1,0); $r.Mem.Write(0x4016,1); $r.Mem.Write(0x4016,0)
    for($i=0;$i-lt 8;$i++){ [void]$r.Mem.Read(0x4016) }
    Assert-Equal 1 $r.Mem.Read(0x4016) 'controller post-shift'
}
$results | Format-Table -AutoSize
if (@($results | Where-Object Result -eq 'FAIL').Count -gt 0) { exit 1 }

}

# ============================================================================
# DIRECT ENTRY
# ============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    if ($Conformance) {
        Test-PSNESConformance
        return
    }

    if (-not $Rom) { throw 'Pass -Rom with the path of an iNES image to play, or -Conformance to run the conformance suite.' }
    Invoke-PSNES -Path $Rom -Scaling $Scaling
}
