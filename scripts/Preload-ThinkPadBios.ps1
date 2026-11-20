<#
.SYNOPSIS
    Preloads official ThinkPad BIOS packages onto the USB cache for offline workshop use.
#>
[CmdletBinding()]
param(
    [string[]]$Models,
    [string]$ModelsFile,
    [switch]$IncludeAllVersions
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'

function Initialize-TlsAndEncoding {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    } catch {}
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
}

function Import-BundledLSUClient {
    param([string]$ManifestPath)

    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        Import-Module -Name $ManifestPath -Force -ErrorAction Stop
        return $true
    }

    $installed = Get-Module -ListAvailable -Name 'LSUClient' | Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) {
        Import-Module -Name $installed.Path -Force -ErrorAction Stop
        return $true
    }

    return $false
}

function Get-OsSearchOrder {
    $localOs = '10'
    try {
        if ([Environment]::OSVersion.Version.Build -ge 22000) {
            $localOs = '11'
        }
    } catch {}

    if ($localOs -eq '11') {
        return @('11', '10')
    }
    return @('10', '11')
}

function Select-BiosPackages {
    param([object[]]$Packages)

    if (-not $Packages) { return @() }

    $biosStrict = @($Packages | Where-Object {
        (
            ("$($_.Type)" -eq 'BIOS') -or
            ($_.Category -match 'BIOS') -or
            ($_.Title -match 'BIOS Update')
        ) -and
        ($_.Title -notmatch 'Dock|Monitor|Keyboard|Mouse|WWAN|NVMe|SSD|Thunderbolt')
    } | Sort-Object ReleaseDate -Descending)

    if ($biosStrict.Count -gt 0) {
        return $biosStrict
    }

    $biosFallback = @($Packages | Where-Object {
        ($_.Category -match 'BIOS|UEFI') -or
        ($_.Title -match '\bBIOS\b|\bUEFI\b')
    } | Sort-Object ReleaseDate -Descending)

    return $biosFallback
}

function Strip-Utf8Bom {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) {
        return $Text.Substring(1)
    }
    return ($Text -replace '^\xEF\xBB\xBF', '')
}

function Get-BiosLevelsFromPackageXml {
    param([xml]$PkgXml)
    $levels = @()
    try {
        if ($PkgXml -and $PkgXml.Package -and $PkgXml.Package.DetectInstall) {
            $nodes = $PkgXml.Package.DetectInstall.SelectNodes('.//_Bios/Level')
            foreach ($n in $nodes) {
                $val = "$($n.InnerText)".Trim()
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $levels += $val
                }
            }
        }
    } catch {}
    return @($levels)
}

function Get-PackageXmlMeta {
    param(
        [string]$XmlUrl = '',
        [string]$CacheFolder = ''
    )

    $levels = @()
    $rawVer = ''

    if (-not [string]::IsNullOrWhiteSpace($CacheFolder) -and (Test-Path -LiteralPath $CacheFolder -PathType Container)) {
        $xmlFiles = @(Get-ChildItem -LiteralPath $CacheFolder -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        foreach ($xf in $xmlFiles) {
            try {
                $raw = Get-Content -LiteralPath $xf.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                [xml]$doc = Strip-Utf8Bom -Text $raw
                $found = @(Get-BiosLevelsFromPackageXml -PkgXml $doc)
                if ($found.Count -gt 0) { $levels += $found }
                if ([string]::IsNullOrWhiteSpace($rawVer) -and $doc -and $doc.Package) {
                    $rawVer = "$($doc.Package.GetAttribute('version'))".Trim()
                }
            } catch {}
        }
    }

    if (($levels.Count -eq 0 -or [string]::IsNullOrWhiteSpace($rawVer)) -and -not [string]::IsNullOrWhiteSpace($XmlUrl)) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $raw = $wc.DownloadString($XmlUrl)
            $wc.Dispose()
            [xml]$doc = Strip-Utf8Bom -Text $raw
            if ($levels.Count -eq 0) {
                $levels = @(Get-BiosLevelsFromPackageXml -PkgXml $doc)
            }
            if ([string]::IsNullOrWhiteSpace($rawVer) -and $doc -and $doc.Package) {
                $rawVer = "$($doc.Package.GetAttribute('version'))".Trim()
            }
        } catch {}
    }

    return [PSCustomObject]@{
        Levels     = @($levels | Select-Object -Unique)
        RawVersion = $rawVer
    }
}

function Test-BiosVersionInstalled {
    param(
        [string]$CurrentBios,
        [string[]]$DetectBiosLevels,
        [string]$PkgVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentBios) -and (@($DetectBiosLevels).Count -gt 0)) {
        foreach ($pat in $DetectBiosLevels) {
            if (-not [string]::IsNullOrWhiteSpace($pat)) {
                if ($CurrentBios -like $pat) {
                    return $true
                }
            }
        }
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentBios) -and -not [string]::IsNullOrWhiteSpace($PkgVersion)) {
        if ($CurrentBios -match '\((\d+\.\d+)\s*\)') {
            $curVerStr = $Matches[1]
            try {
                $vCur = [version]$curVerStr
                $vPkg = [version]($PkgVersion -replace '^v', '')
                if ($vCur -eq $vPkg) { return $true }
                return $false
            } catch {}
        }
    }

    return $null
}

function Get-BiosPackagesFromLenovoDirect {
    param(
        [string]$Model4,
        [string[]]$OsOrder = @('11', '10'),
        [System.Collections.Generic.List[string]]$Diagnostics = $null
    )

    $results = @()
    if ([string]::IsNullOrWhiteSpace($Model4)) { return $results }

    foreach ($osVer in $OsOrder) {
        $catalogUrl = "https://download.lenovo.com/catalog/{0}_Win{1}.xml" -f $Model4, $osVer
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $catRaw = $wc.DownloadString($catalogUrl)
            $wc.Dispose()
            if ($Diagnostics) { $Diagnostics.Add("[DIRECT] GET $catalogUrl -> OK ($($catRaw.Length) B)") }

            [xml]$catXml = Strip-Utf8Bom -Text $catRaw
            $pkgNodes = @($catXml.packages.package)
            if ($Diagnostics) { $Diagnostics.Add("[DIRECT] Win$osVer catalog total packages: $($pkgNodes.Count)") }

            $biosNodes = @($pkgNodes | Where-Object {
                ($_.category -match 'BIOS|UEFI') -or
                ($_.location -match '(uj\d+w|bios).*\.xml')
            })
            if ($Diagnostics) { $Diagnostics.Add("[DIRECT] Win$osVer catalog BIOS candidates: $($biosNodes.Count)") }

            if ($biosNodes.Count -eq 0) {
                continue
            }

            foreach ($bn in $biosNodes) {
                $pkgXmlUrl = "$($bn.location)".Trim()
                if ([string]::IsNullOrWhiteSpace($pkgXmlUrl)) { continue }
                try {
                    $wc2 = New-Object System.Net.WebClient
                    $wc2.Encoding = [System.Text.Encoding]::UTF8
                    $pkgRaw = $wc2.DownloadString($pkgXmlUrl)
                    $wc2.Dispose()

                    [xml]$pkgXml = Strip-Utf8Bom -Text $pkgRaw
                    $pkgNode = $pkgXml.Package
                    if (-not $pkgNode) { continue }

                    $pkgId    = "$($pkgNode.GetAttribute('id'))".Trim()
                    $pkgVer   = ("$($pkgNode.GetAttribute('version'))".Trim()) -replace '^v', ''

                    $relNode  = $pkgNode.SelectSingleNode('ReleaseDate')
                    $pkgDate  = if ($relNode) { "$($relNode.InnerText)".Trim() } else { '' }

                    $descNode = $pkgNode.SelectSingleNode('Title/Desc')
                    $pkgTitle = if ($descNode) { "$($descNode.InnerText)".Trim() } else { '' }
                    if ([string]::IsNullOrWhiteSpace($pkgTitle)) { $pkgTitle = "$($pkgNode.GetAttribute('name'))".Trim() }

                    $extNode  = $pkgNode.SelectSingleNode('ExtractCommand')
                    $extCmd   = if ($extNode) { "$($extNode.InnerText)".Trim() } else { '' }

                    $cmdNode  = $pkgNode.SelectSingleNode('Install/Cmdline')
                    $instCmd  = if ($cmdNode) { "$($cmdNode.InnerText)".Trim() } else { '' }

                    if ($pkgTitle -match 'Dock|Monitor|Keyboard|Mouse|WWAN|NVMe|SSD|Thunderbolt') {
                        continue
                    }

                    $instFileNode = $pkgNode.SelectSingleNode('Files/Installer/File')
                    if (-not $instFileNode) {
                        $instFileNode = $pkgNode.SelectSingleNode('Files//File')
                    }
                    $nameNode   = if ($instFileNode) { $instFileNode.SelectSingleNode('Name') } else { $null }
                    $crcNode    = if ($instFileNode) { $instFileNode.SelectSingleNode('CRC') } else { $null }
                    $instName   = if ($nameNode) { "$($nameNode.InnerText)".Trim() } else { '' }
                    $instSha256 = if ($crcNode) { "$($crcNode.InnerText)".Trim().ToUpper() } else { '' }
                    $baseUrl    = $pkgXmlUrl -replace '[^/]+$', ''
                    $dlUrl      = if (-not [string]::IsNullOrWhiteSpace($instName)) { $baseUrl + $instName } else { '' }
                    $xmlName    = ($pkgXmlUrl -split '/')[-1]
                    $levels     = @(Get-BiosLevelsFromPackageXml -PkgXml $pkgXml)

                    $results += [PSCustomObject]@{
                        Source           = 'ONLINE_DIRECT'
                        CatalogOs        = "Win$osVer"
                        ID               = $pkgId
                        Version          = $pkgVer
                        ReleaseDate      = $pkgDate
                        Title            = $pkgTitle
                        ExtractCommand   = $extCmd
                        InstallCommand   = $instCmd
                        XmlUrl           = $pkgXmlUrl
                        XmlName          = $xmlName
                        DownloadUrl      = $dlUrl
                        InstallerName    = $instName
                        InstallerSha256  = $instSha256
                        DetectBiosLevels = $levels
                    }
                } catch {
                    if ($Diagnostics) { $Diagnostics.Add("[DIRECT] Failed to parse $pkgXmlUrl : $($_.Exception.Message)") }
                }
            }

            if ($results.Count -gt 0) {
                return @($results | Sort-Object ReleaseDate -Descending)
            }
        } catch {
            if ($Diagnostics) { $Diagnostics.Add("[DIRECT] Request failed for $catalogUrl : $($_.Exception.Message)") }
        }
    }

    return @($results)
}

function Save-DirectBiosPackage {
    param(
        [PSCustomObject]$PackageInfo,
        [string]$CacheRoot
    )

    $pkgDir = Join-Path $CacheRoot $PackageInfo.ID
    if (-not (Test-Path -LiteralPath $pkgDir -PathType Container)) {
        $null = New-Item -Path $pkgDir -ItemType Directory -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($PackageInfo.XmlUrl) -and -not [string]::IsNullOrWhiteSpace($PackageInfo.XmlName)) {
        $xmlDest = Join-Path $pkgDir $PackageInfo.XmlName
        if (-not (Test-Path -LiteralPath $xmlDest -PathType Leaf)) {
            $wcXml = New-Object System.Net.WebClient
            $wcXml.DownloadFile($PackageInfo.XmlUrl, $xmlDest)
            $wcXml.Dispose()
        }
    }

    if ([string]::IsNullOrWhiteSpace($PackageInfo.DownloadUrl) -or [string]::IsNullOrWhiteSpace($PackageInfo.InstallerName)) {
        throw "Package $($PackageInfo.ID) has no installer download URL."
    }

    $exeDest = Join-Path $pkgDir $PackageInfo.InstallerName
    $needDownload = $true
    if (Test-Path -LiteralPath $exeDest -PathType Leaf) {
        if (-not [string]::IsNullOrWhiteSpace($PackageInfo.InstallerSha256)) {
            $existingHash = (Get-FileHash -LiteralPath $exeDest -Algorithm SHA256).Hash.ToUpper()
            if ($existingHash -eq $PackageInfo.InstallerSha256.ToUpper()) {
                $needDownload = $false
            }
        } else {
            $needDownload = $false
        }
    }

    if ($needDownload) {
        Write-Host ("[*] Downloading {0} -> {1}" -f $PackageInfo.DownloadUrl, $exeDest) -ForegroundColor Cyan
        $wcExe = New-Object System.Net.WebClient
        $wcExe.DownloadFile($PackageInfo.DownloadUrl, $exeDest)
        $wcExe.Dispose()

        if (-not [string]::IsNullOrWhiteSpace($PackageInfo.InstallerSha256)) {
            $actualHash = (Get-FileHash -LiteralPath $exeDest -Algorithm SHA256).Hash.ToUpper()
            if ($actualHash -ne $PackageInfo.InstallerSha256.ToUpper()) {
                Remove-Item -LiteralPath $exeDest -Force -ErrorAction SilentlyContinue
                throw "SHA256 verification failed for $($PackageInfo.InstallerName) (expected: $($PackageInfo.InstallerSha256), got: $actualHash)"
            }
            Write-Host "[OK] File SHA256 checksum verified." -ForegroundColor Green
        }
    } else {
        Write-Host "[OK] Installer $($PackageInfo.InstallerName) already exists in cache with valid SHA256." -ForegroundColor Green
    }

    return $pkgDir
}

function Read-ModelIndex {
    param([string]$IndexPath)

    $map = @{}
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
        return $map
    }

    try {
        $raw = Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8 -ErrorAction Stop
        $raw = Strip-Utf8Bom -Text $raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $map }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $obj) { return $map }
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = @($prop.Value)
        }
    } catch {
        Write-Warning "Unable to read cache index ($IndexPath): $($_.Exception.Message)"
        return $null
    }
    return $map
}

function Save-ModelIndexEntry {
    param(
        [string]$IndexPath,
        [string]$Model4,
        [hashtable]$Entry
    )

    if ([string]::IsNullOrWhiteSpace($Model4) -or [string]::IsNullOrWhiteSpace($Entry.ID)) {
        return
    }

    $map = Read-ModelIndex -IndexPath $IndexPath
    if ($null -eq $map) {
        Write-Warning "Skipping cache index write to avoid overwriting existing $IndexPath."
        return
    }

    $existing = @()
    if ($map.ContainsKey($Model4)) {
        $existing = @($map[$Model4] | Where-Object { $_.ID -ne $Entry.ID })
    }

    $newObj = [PSCustomObject]$Entry
    $combined = @($newObj) + @($existing)
    $map[$Model4] = @($combined | Sort-Object ReleaseDate -Descending)

    $outObj = New-Object PSObject
    foreach ($k in ($map.Keys | Sort-Object)) {
        $arr = @($map[$k])
        Add-Member -InputObject $outObj -MemberType NoteProperty -Name $k -Value $arr
    }

    $json = $outObj | ConvertTo-Json -Depth 6
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($IndexPath, $json, $utf8Bom)
}

Initialize-TlsAndEncoding

Write-Host ""
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host "   THINKPAD BIOS PRELOAD - Offline USB Cache Builder" -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan

$ToolRoot       = Split-Path -Parent $PSScriptRoot
$ModuleManifest = Join-Path $ToolRoot 'modules\LSUClient\LSUClient.psd1'
$UsbCacheDir    = Join-Path $ToolRoot 'cache'
$IndexPath      = Join-Path $UsbCacheDir 'model-index.json'

if ($UsbCacheDir.Contains(' ')) {
    Write-Host "[ERROR] USB folder path contains a space: $UsbCacheDir" -ForegroundColor Red
    Write-Host "Rename the folder on your USB drive so it contains no spaces (e.g. ThinkPad-Logo-Remover)." -ForegroundColor Yellow
    [void](Read-Host "Press ENTER to exit")
    exit 1
}

if (-not (Test-Path -LiteralPath $UsbCacheDir -PathType Container)) {
    $null = New-Item -Path $UsbCacheDir -ItemType Directory -Force
}

if (-not (Import-BundledLSUClient -ManifestPath $ModuleManifest)) {
    Write-Host "[ERROR] LSUClient module not found at $ModuleManifest" -ForegroundColor Red
    [void](Read-Host "Press ENTER to exit")
    exit 1
}

$modelList = New-Object System.Collections.Generic.List[string]

if ($Models -and $Models.Count -gt 0) {
    foreach ($item in $Models) {
        foreach ($tok in ($item -split '[,\s;]+')) {
            $t = $tok.Trim().ToUpper()
            if ($t.Length -gt 4) { $t = $t.Substring(0, 4) }
            if ($t -match '^[A-Z0-9]{4}$' -and (-not $modelList.Contains($t))) { $modelList.Add($t) }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($ModelsFile) -and (Test-Path -LiteralPath $ModelsFile -PathType Leaf)) {
    foreach ($line in (Get-Content -LiteralPath $ModelsFile -Encoding UTF8)) {
        $clean = ($line -replace '#.*$', '').Trim().ToUpper()
        if ($clean.Length -gt 4) { $clean = $clean.Substring(0, 4) }
        if ($clean -match '^[A-Z0-9]{4}$' -and (-not $modelList.Contains($clean))) { $modelList.Add($clean) }
    }
}

if ($modelList.Count -eq 0) {
    Write-Host ""
    Write-Host "Enter 4-character ThinkPad model codes (MTM prefix, e.g. 20S0, 20W0, 20XW, 20L5)" -ForegroundColor Yellow
    Write-Host "or enter the path to a .txt file with one model code per line:" -ForegroundColor Yellow
    $rawInput = Read-Host "Models or file path"

    $trimmed = $rawInput.Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($trimmed) -and (Test-Path -LiteralPath $trimmed -PathType Leaf)) {
        foreach ($line in (Get-Content -LiteralPath $trimmed -Encoding UTF8)) {
            $clean = ($line -replace '#.*$', '').Trim().ToUpper()
            if ($clean.Length -gt 4) { $clean = $clean.Substring(0, 4) }
            if ($clean -match '^[A-Z0-9]{4}$' -and (-not $modelList.Contains($clean))) { $modelList.Add($clean) }
        }
    } else {
        foreach ($tok in ($rawInput -split '[,\s;]+')) {
            $t = $tok.Trim().ToUpper()
            if ($t.Length -gt 4) { $t = $t.Substring(0, 4) }
            if ($t -match '^[A-Z0-9]{4}$' -and (-not $modelList.Contains($t))) { $modelList.Add($t) }
        }
    }
}

if ($modelList.Count -eq 0) {
    Write-Host "[ERROR] No valid 4-character model codes provided (e.g. 20S0)." -ForegroundColor Red
    [void](Read-Host "Press ENTER to exit")
    exit 1
}

$osOrder = Get-OsSearchOrder
$summary = @()

foreach ($m in $modelList) {
    Write-Host ""
    Write-Host ">>> Processing model: $m" -ForegroundColor Cyan
    try {
        $biosPkgs = @()
        $usedDirect = $false

        foreach ($osTry in $osOrder) {
            try {
                $lsuErr = @()
                $allPkgs = @(Get-LSUpdate -Model $m -All -NoTestApplicable -NoTestInstalled -NoTestSeverityOverride `
                    -MachineCharacteristicsOverride @{ '_OS' = $osTry } `
                    -ErrorAction SilentlyContinue -ErrorVariable lsuErr)
                $found = @(Select-BiosPackages -Packages $allPkgs)
                if ($found.Count -gt 0) {
                    $biosPkgs = $found
                    break
                }
            } catch {}
        }

        if ($biosPkgs.Count -eq 0) {
            Write-Host "  [*] Trying direct Lenovo XML catalog..." -ForegroundColor Yellow
            $directFound = @(Get-BiosPackagesFromLenovoDirect -Model4 $m -OsOrder $osOrder)
            if ($directFound.Count -gt 0) {
                $biosPkgs = $directFound
                $usedDirect = $true
            }
        }

        if ($biosPkgs.Count -eq 0) {
            Write-Warning "No BIOS package found for model $m."
            $summary += [PSCustomObject]@{ Model = $m; Status = 'SKIPPED'; Info = 'No BIOS package in catalog' }
            continue
        }

        $toDownload = if ($IncludeAllVersions) { $biosPkgs } else { @($biosPkgs[0]) }
        foreach ($pkg in $toDownload) {
            if ($usedDirect) {
                Write-Host ("  Downloading (Direct): {0} | Ver {1} | {2}" -f $pkg.ID, $pkg.Version, $pkg.Title) -ForegroundColor Gray
                $null = Save-DirectBiosPackage -PackageInfo $pkg -CacheRoot $UsbCacheDir
                Save-ModelIndexEntry -IndexPath $IndexPath -Model4 $m -Entry @{
                    ID               = $pkg.ID
                    Title            = $pkg.Title
                    Version          = $pkg.Version
                    ReleaseDate      = $pkg.ReleaseDate
                    ExtractCommand   = $pkg.ExtractCommand
                    InstallCommand   = $pkg.InstallCommand
                    DetectBiosLevels = @($pkg.DetectBiosLevels)
                    CachedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
            } else {
                Write-Host ("  Downloading (LSU): {0} | Ver {1} | {2}" -f $pkg.ID, $pkg.Version, $pkg.Title) -ForegroundColor Gray
                Save-LSUpdate -Package $pkg -Path $UsbCacheDir -ShowProgress -ErrorAction Continue
                $meta = Get-PackageXmlMeta -XmlUrl $pkg.URL -CacheFolder (Join-Path $UsbCacheDir $pkg.ID)
                $levels = @($meta.Levels)
                $verStr = "$($pkg.Version)"
                if (($verStr -eq '0.0.0.0') -and -not [string]::IsNullOrWhiteSpace($meta.RawVersion)) {
                    $verStr = $meta.RawVersion -replace '^v', ''
                }
                Save-ModelIndexEntry -IndexPath $IndexPath -Model4 $m -Entry @{
                    ID               = $pkg.ID
                    Title            = $pkg.Title
                    Version          = $verStr
                    ReleaseDate      = $pkg.ReleaseDate.ToString('yyyy-MM-dd')
                    ExtractCommand   = $pkg.Installer.ExtractCommand
                    InstallCommand   = $pkg.Installer.Command
                    DetectBiosLevels = @($levels)
                    CachedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
            }
        }
        $summary += [PSCustomObject]@{ Model = $m; Status = 'OK'; Info = "$($toDownload[0].ID) (v$($toDownload[0].Version))" }
    } catch {
        Write-Warning "Error for model $m : $($_.Exception.Message)"
        $summary += [PSCustomObject]@{ Model = $m; Status = 'ERROR'; Info = $_.Exception.Message }
    }
}

Write-Host ""
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " PRELOAD SUMMARY" -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan
$summary | Format-Table -AutoSize
Write-Host ("Cache index: {0}" -f $IndexPath) -ForegroundColor Green

try { [void](Read-Host "Press ENTER to exit") } catch {}
