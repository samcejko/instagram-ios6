# Names the Objective-C method that the frames of a crash report fall in, for the armv7 build (a thin 32-bit Mach-O)
# when there is neither a symbol table nor a link map: the binary's own ObjC metadata (class, metaclass and category
# method lists) gives every method's address. A C function or a block is reported as the method before it, which is
# usually the method it belongs to; ".cxx_destruct" frames are the release of a class's instance variables.
#
#   .\tools\symbolicate-objc.ps1 -Binary <Shutter binary of that build> -Offsets 542708,519734
#
# The offsets are the "+ N" of the report's Shutter frames (from the image base). The binary: Payload/Shutter.app/Shutter
# from the IPA of the same CI run (packages\run-<id>\*.ipa). iOS 6 crash reports land only in the syslog once
# /var/mobile/Library/Logs/CrashReporter is full ("Not saving crash log because we have reached the limit"):
# grep 'ReportCrash\[<pid>\]' /var/log/syslog.
param([Parameter(Mandatory = $true)][string]$Binary, [Parameter(Mandatory = $true)][long[]]$Offsets)

$b = [IO.File]::ReadAllBytes((Resolve-Path $Binary).Path)
function U32([long]$o) { return [long][BitConverter]::ToUInt32($b, [int]$o) }
function CStr([long]$o) {
    $end = $o
    while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
    return [Text.Encoding]::ASCII.GetString($b, [int]$o, [int]($end - $o))
}

# (a hex literal like 0xFEEDFACE is a negative Int32 in Windows PowerShell)
if ((U32 0) -ne [Convert]::ToInt64('FEEDFACE', 16)) { throw "not a thin 32-bit Mach-O (magic $('{0:X8}' -f (U32 0)))" }
$ncmds = U32 16
$segments = @()
$sections = @{}
$off = 28
for ($i = 0; $i -lt $ncmds; $i++) {
    $cmd = U32 $off; $size = U32 ($off + 4)
    if ($cmd -eq 1) {   # LC_SEGMENT
        $seg = [pscustomobject]@{ name = (CStr ($off + 8)); vmaddr = (U32 ($off + 24)); vmsize = (U32 ($off + 28)); fileoff = (U32 ($off + 32)) }
        $segments += $seg
        $nsects = U32 ($off + 48)
        $s = $off + 56
        for ($k = 0; $k -lt $nsects; $k++) {
            $sect = (CStr $s); if ($sect.Length -gt 16) { $sect = $sect.Substring(0, 16) }
            $sseg = (CStr ($s + 16)); if ($sseg.Length -gt 16) { $sseg = $sseg.Substring(0, 16) }
            $sections["$sseg,$sect"] = [pscustomobject]@{ addr = (U32 ($s + 32)); size = (U32 ($s + 36)); offset = (U32 ($s + 40)) }
            $s += 68
        }
    }
    $off += $size
}
function VmToOff([long]$vm) {
    foreach ($sg in $segments) {
        if ($vm -ge $sg.vmaddr -and $vm -lt ($sg.vmaddr + $sg.vmsize)) { return $sg.fileoff + ($vm - $sg.vmaddr) }
    }
    return -1
}
$text = $segments | Where-Object { $_.name -eq '__TEXT' } | Select-Object -First 1
"__TEXT vmaddr = 0x{0:X}" -f $text.vmaddr

$methods = New-Object System.Collections.ArrayList
function AddList([long]$listVm, [string]$owner, [string]$kind) {
    if ($listVm -eq 0) { return }
    $o = VmToOff $listVm
    if ($o -lt 0) { return }
    $entsize = (U32 $o) -band 0xFFFC
    $count = U32 ($o + 4)
    for ($j = 0; $j -lt $count; $j++) {
        $e = $o + 8 + $j * $entsize
        $selOff = VmToOff (U32 $e)
        $sel = if ($selOff -ge 0) { CStr $selOff } else { '?' }
        $imp = (U32 ($e + 8)) -band 0xFFFFFFFE   # (the Thumb bit off)
        [void]$methods.Add([pscustomobject]@{ imp = $imp; name = "$kind[$owner $sel]" })
    }
}
function ClassRo([long]$classVm) {
    $o = VmToOff $classVm
    if ($o -lt 0) { return $null }
    return [pscustomobject]@{ isa = (U32 $o); ro = ((U32 ($o + 16)) -band 0xFFFFFFFC) }
}

$cl = $sections['__DATA,__objc_classlist']
if ($cl) {
    for ($p = 0; $p -lt $cl.size; $p += 4) {
        $c = ClassRo (U32 ($cl.offset + $p))
        if (-not $c) { continue }
        $roOff = VmToOff $c.ro
        $name = CStr (VmToOff (U32 ($roOff + 16)))
        AddList (U32 ($roOff + 20)) $name '-'
        $meta = ClassRo $c.isa
        if ($meta) { $mro = VmToOff $meta.ro; if ($mro -ge 0) { AddList (U32 ($mro + 20)) $name '+' } }
    }
}
$cat = $sections['__DATA,__objc_catlist']
if ($cat) {
    for ($p = 0; $p -lt $cat.size; $p += 4) {
        $o = VmToOff (U32 ($cat.offset + $p))
        $cname = CStr (VmToOff (U32 $o))
        AddList (U32 ($o + 8)) "($cname)" '-'
        AddList (U32 ($o + 12)) "($cname)" '+'
    }
}
$sorted = $methods | Sort-Object imp
"methods: $($sorted.Count)"
foreach ($ofs in $Offsets) {
    $addr = $text.vmaddr + $ofs
    $best = $null; $next = $null
    foreach ($m in $sorted) { if ($m.imp -le $addr) { $best = $m } elseif (-not $next) { $next = $m } }
    if ($best) { "offset {0} = 0x{1:X}: {2} +0x{3:X} (next method at +0x{4:X})" -f $ofs, $addr, $best.name, ($addr - $best.imp), $(if ($next) { $next.imp - $best.imp } else { 0 }) }
    else { "offset {0} = 0x{1:X}: before every method" -f $ofs, $addr }
}
