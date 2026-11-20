<#
.SYNOPSIS
    ThinkPad Custom Logo Remover - Automates removing custom corporate BIOS boot logos using LSUClient and official Lenovo BIOS flash tools.
.DESCRIPTION
    Detects the ThinkPad MTM model and current BIOS version, checks AC power, battery (>= 30%), BitLocker,
    and Lenovo WMI BIOS security settings, downloads (or uses offline USB cache) the official Lenovo BIOS package
    (supporting Win11/Win10 catalog fallback and direct Lenovo XML discovery) with SHA256 verification, extracts
    it to a fast local working folder, strips loose LOGO.* files, and launches WINUPTP with live monitoring and logging.
    When the latest BIOS is already installed, supports both Fast Same-Version (-s -bcp) mode and an automated
    multi-reboot Full Cycle (-Resume) that saves the latest BIOS, downgrades to a safe previous release, restores
    the latest BIOS, and automatically re-enables SecureRollBackPrevention via Lenovo WMI.
#>
[CmdletBinding()]
param(
    [switch]$OfflineOnly,
    [string]$ModelOverride,
    [switch]$SkipPowerCheck,
    [switch]$Resume
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

function Get-BiosLevelsFromCacheFolder {
    param([string]$Folder)
    $meta = Get-PackageXmlMeta -CacheFolder $Folder
    return @($meta.Levels)
}

function Get-BiosVersionRelation {
    param(
        [string]$CurrentBios,
        [string[]]$DetectBiosLevels,
        [string]$PkgVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentBios) -and (@($DetectBiosLevels).Count -gt 0)) {
        foreach ($pat in $DetectBiosLevels) {
            if (-not [string]::IsNullOrWhiteSpace($pat)) {
                if ($CurrentBios -like $pat) {
                    return 'SAME'
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentBios) -and -not [string]::IsNullOrWhiteSpace($PkgVersion) -and ($PkgVersion -ne '0.0.0.0')) {
        if ($CurrentBios -match '\((\d+\.\d+)\s*\)') {
            $curVerStr = $Matches[1]
            $pkgClean = ($PkgVersion -replace '^v', '').Trim()
            if ($pkgClean -match '^(\d+\.\d+)') {
                $pkgVerStr = $Matches[1]
                try {
                    $vCur = [version]$curVerStr
                    $vPkg = [version]$pkgVerStr
                    if ($vCur -eq $vPkg) { return 'SAME' }
                    if ($vCur -gt $vPkg) { return 'NEWER_ON_LAPTOP' }
                    return 'OLDER_ON_LAPTOP'
                } catch {}
            }
        }
    }

    if (@($DetectBiosLevels).Count -gt 0) {
        return 'OLDER_ON_LAPTOP'
    }

    return 'UNKNOWN'
}

function ConvertFrom-LenovoPackageXml {
    param(
        [xml]$PkgXml,
        [string]$PkgXmlUrl,
        [string]$CatalogOs = ''
    )

    if (-not $PkgXml -or -not $PkgXml.Package) { return $null }
    $pkgNode = $PkgXml.Package

    $pkgId    = "$($pkgNode.GetAttribute('id'))".Trim()
    $pkgVer   = ("$($pkgNode.GetAttribute('version'))".Trim()) -replace '^v', ''

    $relNode  = $pkgNode.SelectSingleNode('ReleaseDate')
    $pkgDate  = if ($relNode) { "$($relNode.InnerText)".Trim() } else { '' }

    $descNode = $pkgNode.SelectSingleNode('Title/Desc')
    $pkgTitle = if ($descNode) { "$($descNode.InnerText)".Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($pkgTitle)) { $pkgTitle = "$($pkgNode.GetAttribute('name'))".Trim() }

    if ($pkgTitle -match 'Dock|Monitor|Keyboard|Mouse|WWAN|NVMe|SSD|Thunderbolt') {
        return $null
    }

    $extNode  = $pkgNode.SelectSingleNode('ExtractCommand')
    $extCmd   = if ($extNode) { "$($extNode.InnerText)".Trim() } else { '' }

    $cmdNode  = $pkgNode.SelectSingleNode('Install/Cmdline')
    $instCmd  = if ($cmdNode) { "$($cmdNode.InnerText)".Trim() } else { '' }

    $instFileNode = $pkgNode.SelectSingleNode('Files/Installer/File')
    if (-not $instFileNode) {
        $instFileNode = $pkgNode.SelectSingleNode('Files//File')
    }
    $nameNode   = if ($instFileNode) { $instFileNode.SelectSingleNode('Name') } else { $null }
    $crcNode    = if ($instFileNode) { $instFileNode.SelectSingleNode('CRC') } else { $null }
    $instName   = if ($nameNode) { "$($nameNode.InnerText)".Trim() } else { '' }
    $instSha256 = if ($crcNode) { "$($crcNode.InnerText)".Trim().ToUpper() } else { '' }

    $readmeNode = $pkgNode.SelectSingleNode('Files/Readme/File/Name')
    $readmeName = if ($readmeNode) { "$($readmeNode.InnerText)".Trim() } else { '' }

    $baseUrl    = $PkgXmlUrl -replace '[^/]+$', ''
    $dlUrl      = if (-not [string]::IsNullOrWhiteSpace($instName)) { $baseUrl + $instName } else { '' }
    $readmeUrl  = if (-not [string]::IsNullOrWhiteSpace($readmeName)) { $baseUrl + $readmeName } else { '' }
    $xmlName    = ($PkgXmlUrl -split '/')[-1]
    $levels     = @(Get-BiosLevelsFromPackageXml -PkgXml $PkgXml)

    return [PSCustomObject]@{
        Source           = 'ONLINE_DIRECT'
        CatalogOs        = $CatalogOs
        ID               = $pkgId
        Version          = $pkgVer
        ReleaseDate      = $pkgDate
        Title            = $pkgTitle
        ExtractCommand   = $extCmd
        InstallCommand   = $instCmd
        XmlUrl           = $PkgXmlUrl
        XmlName          = $xmlName
        ReadmeUrl        = $readmeUrl
        DownloadUrl      = $dlUrl
        InstallerName    = $instName
        InstallerSha256  = $instSha256
        DetectBiosLevels = $levels
    }
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
                    $parsed = ConvertFrom-LenovoPackageXml -PkgXml $pkgXml -PkgXmlUrl $pkgXmlUrl -CatalogOs "Win$osVer"
                    if ($parsed) {
                        $results += $parsed
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

function Get-PreviousBiosPackageFromReadme {
    param(
        [string]$LatestPkgId,
        [string]$LatestXmlUrl,
        [string]$CurrentBios,
        [string]$CacheFolder = ''
    )

    if ([string]::IsNullOrWhiteSpace($LatestPkgId)) { return $null }

    try {
        $baseUrl = 'https://download.lenovo.com/pccbbs/mobiles/'
        if (-not [string]::IsNullOrWhiteSpace($LatestXmlUrl)) {
            $baseUrl = $LatestXmlUrl -replace '[^/]+$', ''
        }

        $cleanLatestId = ($LatestPkgId.Trim() -replace '_v\d+$', '').ToLower()
        if ($cleanLatestId -notmatch '^([A-Za-z0-9]*?[A-Za-z])(\d{2,3})([A-Za-z])$') {
            return $null
        }
        $prefix    = $Matches[1]
        $latestNum = [int]$Matches[2]
        $suffix    = $Matches[3]

        $localReadmeName = ''
        $readmeUrl = ''
        if (-not [string]::IsNullOrWhiteSpace($CacheFolder) -and (Test-Path -LiteralPath $CacheFolder -PathType Container)) {
            $xmlFiles = @(Get-ChildItem -LiteralPath $CacheFolder -Filter '*.xml' -File -ErrorAction SilentlyContinue)
            foreach ($xf in $xmlFiles) {
                try {
                    $rawLocal = Get-Content -LiteralPath $xf.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    [xml]$docLocal = Strip-Utf8Bom -Text $rawLocal
                    $rNode = $docLocal.Package.SelectSingleNode('Files/Readme/File/Name')
                    if ($rNode -and -not [string]::IsNullOrWhiteSpace($rNode.InnerText)) {
                        $localReadmeName = $rNode.InnerText.Trim()
                        $readmeUrl = $baseUrl + $localReadmeName
                        break
                    }
                } catch {}
            }
        }

        if ([string]::IsNullOrWhiteSpace($readmeUrl) -and -not [string]::IsNullOrWhiteSpace($LatestXmlUrl)) {
            try {
                $wcXml = New-Object System.Net.WebClient
                $wcXml.Encoding = [System.Text.Encoding]::UTF8
                $rawXml = $wcXml.DownloadString($LatestXmlUrl)
                $wcXml.Dispose()
                [xml]$docNet = Strip-Utf8Bom -Text $rawXml
                $rNode = $docNet.Package.SelectSingleNode('Files/Readme/File/Name')
                if ($rNode -and -not [string]::IsNullOrWhiteSpace($rNode.InnerText)) {
                    $localReadmeName = $rNode.InnerText.Trim()
                    $readmeUrl = $baseUrl + $localReadmeName
                }
            } catch {}
        }

        if ([string]::IsNullOrWhiteSpace($readmeUrl)) {
            $readmeUrl = "{0}{1}.html" -f $baseUrl, $cleanLatestId
        }

        $htmlRaw = ''
        if (-not [string]::IsNullOrWhiteSpace($CacheFolder) -and (Test-Path -LiteralPath $CacheFolder -PathType Container)) {
            $localNames = @()
            if (-not [string]::IsNullOrWhiteSpace($localReadmeName)) { $localNames += $localReadmeName }
            $localNames += @("$cleanLatestId.html", "$($LatestPkgId.ToLower()).html", "$cleanLatestId.txt", "$($LatestPkgId.ToLower()).txt")
            foreach ($ln in @($localNames | Select-Object -Unique)) {
                $lp = Join-Path $CacheFolder $ln
                if (Test-Path -LiteralPath $lp -PathType Leaf) {
                    try {
                        $htmlRaw = Get-Content -LiteralPath $lp -Raw -Encoding UTF8 -ErrorAction Stop
                        if (-not [string]::IsNullOrWhiteSpace($htmlRaw)) { break }
                    } catch {}
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($htmlRaw)) {
            $wcHtml = New-Object System.Net.WebClient
            $wcHtml.Encoding = [System.Text.Encoding]::UTF8
            $htmlRaw = $wcHtml.DownloadString($readmeUrl)
            $wcHtml.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace($htmlRaw)) { return $null }

        # Restrict ID search to Version Information / changelog section (skip top advisory notes)
        $cutIdx = $htmlRaw.IndexOf('Version Information', [System.StringComparison]::OrdinalIgnoreCase)
        if ($cutIdx -lt 0) {
            $cutIdx = $htmlRaw.IndexOf('Summary of Changes', [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($cutIdx -lt 0) {
            $cutIdx = $htmlRaw.IndexOf($cleanLatestId, [System.StringComparison]::OrdinalIgnoreCase)
        }
        $searchRegion = if ($cutIdx -ge 0) { $htmlRaw.Substring($cutIdx) } else { $htmlRaw }

        $idPattern = "\b({0})(\d{{2,3}})({1})\b" -f [regex]::Escape($prefix), [regex]::Escape($suffix)
        $candMap = @{}
        foreach ($m in [regex]::Matches($searchRegion, $idPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $cand = $m.Value.ToLower()
            $candNum = [int]$m.Groups[2].Value
            if ($cand -eq $cleanLatestId -or $candNum -ge $latestNum) { continue }
            if (-not $candMap.ContainsKey($cand)) {
                $candMap[$cand] = $candNum
            }
        }

        if ($candMap.Count -eq 0) { return $null }

        $candObjs = @()
        foreach ($k in $candMap.Keys) {
            $candObjs += [PSCustomObject]@{ Id = $k; Num = [int]$candMap[$k] }
        }
        $topCands = @($candObjs | Sort-Object Num -Descending | Select-Object -First 6)

        # Detect hard anti-rollback barriers in README notices (enforced even with SecureRollBackPrevention disabled)
        $curVerObj = $null
        if ($CurrentBios -match '\((\d+\.\d+)\s*\)') {
            try { $curVerObj = [version]$Matches[1] } catch {}
        }

        $maxBarrierVer = $null
        $blockSplit = $htmlRaw -replace '(?i)</?(?:p|div|li|tr|h[1-6]|br)[^>]*>', "`n"
        $tagStripped = $blockSplit -replace '<[^>]+>', ' '
        $decodedText = $tagStripped
        try {
            $decodedText = [System.Net.WebUtility]::HtmlDecode($tagStripped)
        } catch {
            $decodedText = $tagStripped -replace '&nbsp;', ' '
        }
        $decodedText = $decodedText -replace [char]0x00A0, ' '

        $barrierFloors = @()
        foreach ($rawLine in ($decodedText -split "`r?`n")) {
            $line = ($rawLine -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match 'Secure\s*RollBack') { continue }

            if ($line -match '(?:version|v)\s*(\d+\.\d+)\s+or\s+higher.{0,160}?(?:no longer able to roll\s*back|cannot roll\s*back|can''t roll\s*back|cannot be downgraded|can''t be downgraded).{0,100}?(?:before|prior to|older than)\s*(?:version\s*|v)?(\d+\.\d+)') {
                try { $barrierFloors += [version]$Matches[2] } catch {}
            }
            if ($line -match '(?:can''t|cannot)\s+be\s+downgraded\s+to\s+older\s+BIOS\s+version\s+after\s+upgrade\s+to\s+[A-Za-z0-9_]+\s*\((\d+\.\d+)\)') {
                try { $barrierFloors += [version]$Matches[1] } catch {}
            }
        }

        if ($null -ne $curVerObj -and @($barrierFloors).Count -gt 0) {
            foreach ($bf in $barrierFloors) {
                if ($bf -le $curVerObj) {
                    if ($null -eq $maxBarrierVer -or $bf -gt $maxBarrierVer) {
                        $maxBarrierVer = $bf
                    }
                }
            }
        }

        foreach ($candItem in $topCands) {
            $candId = $candItem.Id
            foreach ($xmlSuffix in @('_2_.xml', '.xml')) {
                $candXmlUrl = "{0}{1}{2}" -f $baseUrl, $candId, $xmlSuffix
                try {
                    $wcCand = New-Object System.Net.WebClient
                    $wcCand.Encoding = [System.Text.Encoding]::UTF8
                    $candRaw = $wcCand.DownloadString($candXmlUrl)
                    $wcCand.Dispose()

                    [xml]$candDoc = Strip-Utf8Bom -Text $candRaw
                    $pkgObj = ConvertFrom-LenovoPackageXml -PkgXml $candDoc -PkgXmlUrl $candXmlUrl -CatalogOs 'README_PREV'
                    if (-not $pkgObj -or [string]::IsNullOrWhiteSpace($pkgObj.DownloadUrl) -or [string]::IsNullOrWhiteSpace($pkgObj.InstallerName)) {
                        continue
                    }

                    if ($null -ne $maxBarrierVer -and -not [string]::IsNullOrWhiteSpace($pkgObj.Version)) {
                        $candClean = ($pkgObj.Version -replace '^v', '').Trim()
                        if ($candClean -match '^(\d+\.\d+)') {
                            try {
                                $candVerObj = [version]$Matches[1]
                                if ($candVerObj -lt $maxBarrierVer) {
                                    Write-Host ("[INFO] Skipping {0} (v{1}) - below Lenovo hard anti-rollback barrier v{2}." -f $pkgObj.ID, $pkgObj.Version, $maxBarrierVer) -ForegroundColor Yellow
                                    break
                                }
                            } catch {}
                        }
                    }

                    $rel = Get-BiosVersionRelation -CurrentBios $CurrentBios -DetectBiosLevels $pkgObj.DetectBiosLevels -PkgVersion $pkgObj.Version
                    if ($rel -eq 'SAME') {
                        continue
                    }
                    if (($CurrentBios -match '\((\d+\.\d+)\s*\)') -and ($rel -eq 'OLDER_ON_LAPTOP')) {
                        continue
                    }
                    return $pkgObj
                } catch {}
            }
        }
    } catch {}

    return $null
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

function Write-Banner {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "   THINKPAD CUSTOM LOGO REMOVER  (LSUClient + BIOS Flash Helper)" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "------------------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor White
    Write-Host "------------------------------------------------------------------------" -ForegroundColor DarkCyan
}

function Pause-Exit {
    param([int]$Code = 0)
    Write-Host ""
    try {
        [void](Read-Host "Press ENTER to exit")
    } catch {}
    exit $Code
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LiveSystemInfo {
    $cs   = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction SilentlyContinue
    $csp  = Get-CimInstance -ClassName 'Win32_ComputerSystemProduct' -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName 'Win32_BIOS' -ErrorAction SilentlyContinue

    $mfg     = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer.Trim() } else { '' }
    $full    = if ($cs -and $cs.Model) { $cs.Model.Trim() } else { '' }
    $prod    = if ($csp -and $csp.Version) { $csp.Version.Trim() } else { '' }
    $ser     = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber.Trim() } else { '' }
    $biosVer = if ($bios -and $bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion.Trim() } else { '' }
    $biosDt  = if ($bios -and $bios.ReleaseDate) { try { ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } catch { "$($bios.ReleaseDate)" } } else { '' }

    return [PSCustomObject]@{
        Manufacturer = $mfg
        FullModel    = $full
        ProductName  = $prod
        Serial       = $ser
        CurrentBios  = $biosVer
        BiosDate     = $biosDt
    }
}

function Get-PowerState {
    $acOnline = $null
    $chargePct = $null
    $hasBattery = $false

    try {
        $bs = Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryStatus' -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $bs) {
            $acOnline = [bool]$bs.PowerOnline
        }
    } catch {}

    try {
        $bats = @(Get-CimInstance -ClassName 'Win32_Battery' -ErrorAction Stop)
        if ($bats.Count -gt 0) {
            $hasBattery = $true
            $pcts = @($bats | ForEach-Object { [int]$_.EstimatedChargeRemaining })
            if ($pcts.Count -gt 0) {
                $chargePct = ($pcts | Measure-Object -Minimum).Minimum
            }
            if ($null -eq $acOnline) {
                $acStatuses = @(2, 6, 7, 8, 9)
                $acOnline = [bool]($bats | Where-Object { $_.BatteryStatus -in $acStatuses } | Select-Object -First 1)
            }
        }
    } catch {}

    return [PSCustomObject]@{
        HasBattery = $hasBattery
        AcOnline   = $acOnline
        ChargePct  = $chargePct
    }
}

function Test-PowerBeforeFlash {
    param([switch]$SkipCheck)

    if ($SkipCheck) { return }

    while ($true) {
        $pwr = Get-PowerState
        $acText = if ($null -eq $pwr.AcOnline) { 'Unknown' } elseif ($pwr.AcOnline) { 'Connected' } else { 'NOT CONNECTED' }
        $batText = if (-not $pwr.HasBattery) { 'No battery detected' } elseif ($null -ne $pwr.ChargePct) { "$($pwr.ChargePct)%" } else { 'Unknown' }

        $acColor = if ($pwr.AcOnline -eq $true) { 'Green' } else { 'Red' }
        Write-Host ("  AC Charger    : {0}   |   Battery: {1}" -f $acText, $batText) -ForegroundColor $acColor

        $lowBattery = ($pwr.HasBattery -and ($null -ne $pwr.ChargePct) -and ($pwr.ChargePct -lt 30))
        $noAc = ($pwr.AcOnline -eq $false)

        if (-not $noAc -and -not $lowBattery) {
            break
        }

        Write-Host "[WARNING] For safe BIOS flashing, AC power MUST be connected and battery >= 30%!" -ForegroundColor Red
        $pChoice = Read-Host "Connect AC charger then press [R] to retry, [C] to continue at your own risk, or [Q] to quit"
        if ($pChoice -match '^(Q|q)$') { Pause-Exit 0 }
        if ($pChoice -match '^(C|c)$') { break }
    }
}

function Get-BitLockerState {
    param([string]$MountPoint = $env:SystemDrive)

    $active = $false
    $detail = "Not active"

    if (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue) {
        try {
            $vol = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
            if ($vol -and ($vol.ProtectionStatus -eq 'On' -or "$($vol.ProtectionStatus)" -eq '1')) {
                $active = $true
                $detail = "ACTIVE ($($vol.VolumeStatus))"
            } elseif ($vol) {
                $detail = "Off / Suspended ($($vol.ProtectionStatus))"
            }
            return [PSCustomObject]@{ Active = $active; Detail = $detail }
        } catch {}
    }

    try {
        $out = & manage-bde.exe -status $MountPoint 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $protLine = ($out | Select-String -Pattern 'Protection Status' | Select-Object -First 1).Line
            if ($protLine -match 'Protection On') {
                $active = $true
                $detail = "ACTIVE (manage-bde)"
            } elseif ($protLine) {
                $detail = $protLine.Trim()
            }
        }
    } catch {}

    return [PSCustomObject]@{ Active = $active; Detail = $detail }
}

function Suspend-BitLockerSafe {
    param([string]$MountPoint = $env:SystemDrive)

    Write-Host "[*] Suspending BitLocker for 1 reboot..." -ForegroundColor Yellow
    if (Get-Command -Name 'Suspend-BitLocker' -ErrorAction SilentlyContinue) {
        try {
            $null = Suspend-BitLocker -MountPoint $MountPoint -RebootCount 1 -ErrorAction Stop
            Write-Host "[OK] BitLocker suspended successfully (1 reboot)." -ForegroundColor Green
            return $true
        } catch {
            Write-Warning "Suspend-BitLocker failed: $($_.Exception.Message)"
        }
    }

    try {
        $null = & manage-bde.exe -protectors -disable $MountPoint -rc 1 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] BitLocker suspended via manage-bde (1 reboot)." -ForegroundColor Green
            return $true
        }
    } catch {}

    return $false
}

function Get-LenovoBiosSecurityInfo {
    $result = [PSCustomObject]@{
        Available             = $false
        SecureRollback        = $null
        SecureRollbackKeyName = 'SecureRollBackPrevention'
        FlashByEndUsers       = $null
        WindowsUefiUpdate     = $null
        LockBiosSetting       = $null
        SupervisorPasswordSet = $null
    }

    try {
        $settings = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_BiosSetting' -ErrorAction Stop)
        if ($settings.Count -gt 0) {
            $result.Available = $true
            $map = @{}
            foreach ($s in $settings) {
                if ($s.CurrentSetting) {
                    $parts = $s.CurrentSetting -split ',', 2
                    if ($parts.Count -eq 2) {
                        $keyName = $parts[0].Trim()
                        $val = ($parts[1] -split ';')[0].Trim()
                        $map[$keyName] = $val
                    }
                }
            }
            foreach ($k in $map.Keys) {
                if ($k -imatch '^SecureRollBackPrevention$') {
                    $result.SecureRollback = $map[$k]
                    $result.SecureRollbackKeyName = $k
                } elseif ($k -imatch '^FlashBIOSUpdatingByEndUsers$') {
                    $result.FlashByEndUsers = $map[$k]
                } elseif ($k -imatch '^WindowsUEFIFirmwareUpdate$') {
                    $result.WindowsUefiUpdate = $map[$k]
                } elseif ($k -imatch '^LockBIOSSetting$') {
                    $result.LockBiosSetting = $map[$k]
                }
            }
        }
    } catch {}

    try {
        $pw = Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_BiosPasswordSettings' -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $pw -and $null -ne $pw.PasswordState) {
            $result.SupervisorPasswordSet = (([int]$pw.PasswordState -band 1) -ne 0)
        }
    } catch {}

    return $result
}

function Set-LenovoSecureRollback {
    param(
        [string]$SettingKeyName = 'SecureRollBackPrevention',
        [ValidateSet('Enable', 'Disable')]
        [string]$Value = 'Disable',
        [string]$Password = ''
    )

    $out = [PSCustomObject]@{
        Success      = $false
        SetReturn    = ''
        SaveReturn   = ''
        ErrorMessage = ''
    }

    try {
        $setInst = Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_SetBiosSetting' -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $setInst) {
            $out.ErrorMessage = 'WMI class Lenovo_SetBiosSetting is unavailable.'
            return $out
        }

        $argStr = if ([string]::IsNullOrEmpty($Password)) {
            "{0},{1}" -f $SettingKeyName, $Value
        } else {
            "{0},{1},{2},ascii,us" -f $SettingKeyName, $Value, $Password
        }

        $setRes = Invoke-CimMethod -InputObject $setInst -MethodName 'SetBiosSetting' -Arguments @{ parameter = $argStr } -ErrorAction Stop
        $setRet = if ($setRes -and $setRes.PSObject.Properties['return']) { "$($setRes.return)" } else { "$setRes" }
        $out.SetReturn = $setRet

        if ($setRet -ine 'Success') {
            $out.ErrorMessage = "SetBiosSetting returned: $setRet"
            return $out
        }

        $saveInst = Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lenovo_SaveBiosSettings' -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $saveInst) {
            $out.ErrorMessage = 'WMI class Lenovo_SaveBiosSettings is unavailable.'
            return $out
        }

        $saveArg = if ([string]::IsNullOrEmpty($Password)) { '' } else { "{0},ascii,us" -f $Password }
        $saveRes = Invoke-CimMethod -InputObject $saveInst -MethodName 'SaveBiosSettings' -Arguments @{ parameter = $saveArg } -ErrorAction Stop
        $saveRet = if ($saveRes -and $saveRes.PSObject.Properties['return']) { "$($saveRes.return)" } else { "$saveRes" }
        $out.SaveReturn = $saveRet

        if ($saveRet -ieq 'Success') {
            $out.Success = $true
        } else {
            $out.ErrorMessage = "SaveBiosSettings returned: $saveRet"
        }
    } catch {
        $out.ErrorMessage = $_.Exception.Message
    }

    return $out
}

function Clear-ResumeRegistration {
    param(
        [string]$TaskName = 'ThinkPadLogoRemover_Resume',
        [string]$StatePath = 'C:\Temp\TPLogoRemover\resume\resume-state.json'
    )

    try {
        if (Get-Command -Name 'Unregister-ScheduledTask' -ErrorAction SilentlyContinue) {
            $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($existingTask) {
                $null = Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    try {
        $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        if (Test-Path -LiteralPath $runOncePath) {
            $prop = Get-ItemProperty -LiteralPath $runOncePath -Name $TaskName -ErrorAction SilentlyContinue
            if ($null -ne $prop) {
                Remove-ItemProperty -LiteralPath $runOncePath -Name $TaskName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    try {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Register-ResumeAfterReboot {
    param(
        [hashtable]$StateData,
        [string]$SourceScriptPath,
        [string]$ResumeRoot = 'C:\Temp\TPLogoRemover\resume',
        [string]$StatePath = 'C:\Temp\TPLogoRemover\resume\resume-state.json',
        [string]$ResumeScriptPath = 'C:\Temp\TPLogoRemover\resume\Remove-ThinkPadLogo.ps1',
        [string]$TaskName = 'ThinkPadLogoRemover_Resume'
    )

    if (-not (Test-Path -LiteralPath $ResumeRoot -PathType Container)) {
        $null = New-Item -Path $ResumeRoot -ItemType Directory -Force -ErrorAction Stop
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceScriptPath) -and (Test-Path -LiteralPath $SourceScriptPath -PathType Leaf)) {
        if ($SourceScriptPath -ine $ResumeScriptPath) {
            Copy-Item -LiteralPath $SourceScriptPath -Destination $ResumeScriptPath -Force -ErrorAction Stop
        }
    } elseif (-not (Test-Path -LiteralPath $ResumeScriptPath -PathType Leaf)) {
        throw "Unable to copy script for auto-resume ($SourceScriptPath)."
    }

    $json = ([PSCustomObject]$StateData) | ConvertTo-Json -Depth 6
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($StatePath, $json, $utf8Bom)

    try {
        if (Get-Command -Name 'Unregister-ScheduledTask' -ErrorAction SilentlyContinue) {
            $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($old) {
                $null = Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -Resume" -f $ResumeScriptPath

    try {
        if ((Get-Command -Name 'Register-ScheduledTask' -ErrorAction SilentlyContinue) -and -not [string]::IsNullOrWhiteSpace($currentUser)) {
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
            try { $trigger.Delay = 'PT5S' } catch {}
            $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
            $taskObj   = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
            $null = Register-ScheduledTask -TaskName $TaskName -InputObject $taskObj -Force -ErrorAction Stop
            Write-Host ("[OK] Scheduled auto-resume after logon (phase: {0}, Task: {1})." -f $StateData.Phase, $TaskName) -ForegroundColor Green
            return 'SCHEDULED_TASK'
        }
    } catch {
        Write-Warning "Task Scheduler registration failed ($($_.Exception.Message)). Falling back to RunOnce..."
    }

    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        $null = New-Item -Path $runOncePath -Force
    }
    $runCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File $ResumeScriptPath -Resume'`""
    Set-ItemProperty -LiteralPath $runOncePath -Name $TaskName -Value $runCmd -Force -ErrorAction Stop
    Write-Host ("[OK] Scheduled auto-resume after logon (phase: {0}, RunOnce)." -f $StateData.Phase) -ForegroundColor Green
    return 'RUNONCE'
}

function Resolve-ToolRootFromSystem {
    param([string]$PreferredRoot)

    if (-not [string]::IsNullOrWhiteSpace($PreferredRoot)) {
        $candMod = Join-Path $PreferredRoot 'modules\LSUClient\LSUClient.psd1'
        if (Test-Path -LiteralPath $candMod -PathType Leaf) {
            return $PreferredRoot
        }
    }

    try {
        foreach ($drv in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $cand = Join-Path $drv.Root 'ThinkPad-Logo-Remover'
            $candMod = Join-Path $cand 'modules\LSUClient\LSUClient.psd1'
            if (Test-Path -LiteralPath $candMod -PathType Leaf) {
                return $cand
            }
        }
    } catch {}

    return $null
}

function Resolve-UsbLogsDir {
    param([string]$OriginalUsbRoot)

    if (-not [string]::IsNullOrWhiteSpace($OriginalUsbRoot)) {
        $origLogs = Join-Path $OriginalUsbRoot 'logs'
        if (Test-Path -LiteralPath $origLogs -PathType Container) {
            return $origLogs
        }
        if (Test-Path -LiteralPath $OriginalUsbRoot -PathType Container) {
            try {
                $null = New-Item -Path $origLogs -ItemType Directory -Force -ErrorAction Stop
                return $origLogs
            } catch {}
        }
    }

    try {
        foreach ($drv in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $candRoot = Join-Path $drv.Root 'ThinkPad-Logo-Remover'
            $candLogs = Join-Path $candRoot 'logs'
            if (Test-Path -LiteralPath $candLogs -PathType Container) {
                return $candLogs
            }
            if (Test-Path -LiteralPath $candRoot -PathType Container) {
                try {
                    $null = New-Item -Path $candLogs -ItemType Directory -Force -ErrorAction Stop
                    return $candLogs
                } catch {}
            }
        }
    } catch {}

    $localLogs = 'C:\Temp\TPLogoRemover\logs'
    if (-not (Test-Path -LiteralPath $localLogs -PathType Container)) {
        $null = New-Item -Path $localLogs -ItemType Directory -Force
    }
    return $localLogs
}

function Invoke-BiosSetupOrReboot {
    Write-Host ""
    Write-Host "[*] Attempting direct reboot into UEFI BIOS Setup (shutdown /r /fw /t 0)..." -ForegroundColor Cyan
    & shutdown.exe /r /fw /t 0 2>$null
    if ($LASTEXITCODE -eq 0) {
        Start-Sleep -Seconds 2
        exit 0
    }
    Write-Warning "Direct firmware setup entry (/fw) is not supported on this system."
    Write-Host "Restarting normally - press F1 (or Enter -> F1) at the Lenovo splash screen to enter BIOS Setup." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    exit 0
}

function Start-DisableRollbackRebootFlow {
    param(
        [hashtable]$StateData,
        [string]$SecureRollbackKeyName,
        [string]$ReadyMessage,
        [string]$ResumeActionHint,
        [string]$ScriptSelfPath,
        [string]$ResumeRoot,
        [string]$ResumeStatePath,
        [string]$ResumeScriptPath,
        [string]$ResumeTaskName
    )

    $regMethod = Register-ResumeAfterReboot -StateData $StateData -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName

    Write-Host "[*] Trying to disable SecureRollBackPrevention via Lenovo WMI..." -ForegroundColor Cyan
    $wmiRes = Set-LenovoSecureRollback -SettingKeyName $SecureRollbackKeyName -Value 'Disable'
    if ($wmiRes.Success) {
        Write-Host "[OK] SecureRollBackPrevention disabled via Lenovo WMI! Rebooting in 5 seconds..." -ForegroundColor Green
        Start-Sleep -Seconds 5
        Restart-Computer -Force
        exit 0
    }

    Write-Host ""
    Write-Host ("[INFO] ThinkPad BIOS blocked disabling SecureRollBackPrevention from Windows (WMI: Set='{0}', Save='{1}')." -f $wmiRes.SetReturn, $wmiRes.SaveReturn) -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($ReadyMessage)) {
        Write-Host "Auto-resume ($regMethod) is ALREADY SCHEDULED." -ForegroundColor Green
    } else {
        Write-Host ("Auto-resume ({0}) is ALREADY SCHEDULED; {1}" -f $regMethod, $ReadyMessage) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  [1] Reboot DIRECTLY into BIOS Setup (Security -> Secure RollBack Prevention -> Disabled -> F10)" -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($ResumeActionHint)) {
        Write-Host ("      -> {0}" -f $ResumeActionHint) -ForegroundColor Cyan
    }
    Write-Host "  [2] Normal reboot (press F1 manually at boot) + auto-resume"
    Write-Host "  [0] Cancel"
    $fwChoice = Read-Host "Select option [1]"
    if ([string]::IsNullOrWhiteSpace($fwChoice)) { $fwChoice = '1' }

    if ($fwChoice -eq '1') {
        Invoke-BiosSetupOrReboot
    } elseif ($fwChoice -eq '2') {
        Write-Host "Rebooting in 3 seconds (press F1 to enter BIOS Setup)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        Restart-Computer -Force
        exit 0
    } else {
        Clear-ResumeRegistration -TaskName $ResumeTaskName -StatePath $ResumeStatePath
        Write-Host "Auto-cycle cancelled." -ForegroundColor Gray
    }
}

function Remove-LooseLogoFiles {
    param([string]$Directory)
    $patterns = @('LOGO.*', 'LOGO1.*', 'LOGO2.*')
    $removed = @()
    foreach ($pat in $patterns) {
        $hits = @(Get-ChildItem -LiteralPath $Directory -Filter $pat -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(bmp|jpg|jpeg|gif|png)$' })
        foreach ($f in $hits) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            $removed += $f.Name
        }
    }
    return $removed
}

function Expand-CachedPackage {
    param(
        [string]$WorkDir,
        [string]$ExtractCommand
    )

    $alreadyExtracted = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(winuptp\.exe|winuptp64\.exe|WinFlash64\.exe|WinFlash\.exe|H2OFFT.*\.exe|Flash\.cmd)$' })
    if ($alreadyExtracted.Count -gt 0) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ExtractCommand)) {
        Write-Host "[*] Extracting package using command: $ExtractCommand" -ForegroundColor Cyan
        $resolved = $ExtractCommand -replace '%PACKAGEPATH%', ($WorkDir.TrimEnd('\') + '\')
        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $resolved" -WorkingDirectory $WorkDir -Wait -PassThru -NoNewWindow
        $after = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(winuptp\.exe|winuptp64\.exe|WinFlash64\.exe|WinFlash\.exe|H2OFFT.*\.exe|Flash\.cmd)$' })
        if ($after.Count -gt 0 -or $proc.ExitCode -eq 0) {
            return $true
        }
    }

    $exe = Get-ChildItem -LiteralPath $WorkDir -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { return $false }

    Write-Host "[*] Trying silent extraction ($($exe.Name) /VERYSILENT /DIR=. /EXTRACT=YES)..." -ForegroundColor Cyan
    $null = Start-Process -FilePath $exe.FullName -ArgumentList "/VERYSILENT /DIR=`"$WorkDir`" /EXTRACT=YES" -WorkingDirectory $WorkDir -Wait -PassThru
    $after = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(winuptp\.exe|winuptp64\.exe|WinFlash64\.exe|WinFlash\.exe|H2OFFT.*\.exe|Flash\.cmd)$' })
    if ($after.Count -gt 0) { return $true }

    Write-Host "[!] Silent extraction did not yield a known flasher. Launching manual extractor - choose EXTRACT ONLY (not Install) into: $WorkDir" -ForegroundColor Yellow
    $null = Start-Process -FilePath $exe.FullName -WorkingDirectory $WorkDir -Wait -PassThru
    return $true
}

function Find-FlashArtifacts {
    param([string]$WorkDir)

    $allFiles = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue)

    $winuptp = $allFiles | Where-Object { $_.Name -ieq 'winuptp.exe' } | Select-Object -First 1
    if (-not $winuptp) {
        $winuptp = $allFiles | Where-Object { $_.Name -ieq 'winuptp64.exe' } | Select-Object -First 1
    }

    $winflash = $null
    if ([Environment]::Is64BitOperatingSystem) {
        $winflash = $allFiles | Where-Object { $_.Name -ieq 'WinFlash64.exe' } | Select-Object -First 1
    }
    if (-not $winflash) {
        $winflash = $allFiles | Where-Object { $_.Name -ieq 'WinFlash.exe' } | Select-Object -First 1
    }

    $bcpEvs = $allFiles | Where-Object { $_.Name -ieq 'bcp.evs' } | Select-Object -First 1
    $others = @($allFiles | Where-Object { $_.Name -match '^(H2OFFT.*\.exe|Flash\.cmd|afuwin.*\.exe)$' })

    return [PSCustomObject]@{
        Winuptp  = $winuptp
        Winflash = $winflash
        BcpEvs   = $bcpEvs
        Others   = $others
    }
}

function Sync-LocalLogsToUsb {
    param([string]$UsbLogsDir)

    $localLogsDir = 'C:\Temp\TPLogoRemover\logs'
    if ([string]::IsNullOrWhiteSpace($UsbLogsDir)) { return }
    if ($UsbLogsDir.TrimEnd('\') -ieq $localLogsDir.TrimEnd('\')) { return }
    if (-not (Test-Path -LiteralPath $localLogsDir -PathType Container)) { return }

    if (-not (Test-Path -LiteralPath $UsbLogsDir -PathType Container)) {
        try { $null = New-Item -Path $UsbLogsDir -ItemType Directory -Force -ErrorAction Stop } catch { return }
    }

    $movedAny = $false
    foreach ($lf in @(Get-ChildItem -LiteralPath $localLogsDir -Filter 'winuptp_*.log' -File -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $UsbLogsDir $lf.Name
        try {
            if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
                Copy-Item -LiteralPath $lf.FullName -Destination $dest -ErrorAction Stop
            }
            Remove-Item -LiteralPath $lf.FullName -Force -ErrorAction SilentlyContinue
            $movedAny = $true
        } catch {}
    }

    $localCsv = Join-Path $localLogsDir 'history.csv'
    if (Test-Path -LiteralPath $localCsv -PathType Leaf) {
        try {
            $localRows = @(Import-Csv -LiteralPath $localCsv -Encoding UTF8 -ErrorAction Stop)
            if ($localRows.Count -gt 0) {
                $usbCsv = Join-Path $UsbLogsDir 'history.csv'
                $localRows | Export-Csv -LiteralPath $usbCsv -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                $movedAny = $true
            }
            Remove-Item -LiteralPath $localCsv -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warning ("Unable to sync local history.csv to USB: {0}" -f $_.Exception.Message)
        }
    }

    if ($movedAny) {
        Write-Host ("[OK] Synced local logs from {0} to USB: {1}" -f $localLogsDir, $UsbLogsDir) -ForegroundColor Green
    }
}

function Clear-TempWorkDirectory {
    param([string]$WorkRoot = 'C:\Temp\TPLogoRemover\work')

    if ([string]::IsNullOrWhiteSpace($WorkRoot)) { return }
    if (Test-Path -LiteralPath $WorkRoot -PathType Container) {
        try {
            Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop
            Write-Host "[OK] Cleaned up temporary working files ($WorkRoot)." -ForegroundColor Green
        } catch {
            Write-Warning ("Could not completely remove {0}: {1}" -f $WorkRoot, $_.Exception.Message)
        }
    }
}

function Get-WinuptpLogAnalysis {
    param(
        [string]$FlasherDir,
        $ExitCode
    )

    $hasLog          = $false
    $hasError        = $false
    $rbBlocked       = $false
    $wrongBios       = $false
    $flashCompleted  = $false
    $flashStarted    = $false
    $defaultLogo     = $false
    $errorLines      = @()

    if (-not [string]::IsNullOrWhiteSpace($FlasherDir)) {
        $winuptpLogPath = Join-Path $FlasherDir 'winuptp.log'
        if (Test-Path -LiteralPath $winuptpLogPath -PathType Leaf) {
            $hasLog = $true
            $lines = @(Get-Content -LiteralPath $winuptpLogPath -ErrorAction SilentlyContinue)
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -match '<ERROR>|\[Flash Error\]|Failed to update BIOS|BIOS image file.*(?:invalid|does not match|not for this)|Invalid BIOS|not match this system') {
                    $hasError = $true
                    $errorLines += $line.Trim()
                }
                if ($line -match 'Secure RollBack prevention is enabled|Failed to update BIOS \(182\)') {
                    $rbBlocked = $true
                }
                if ($line -match 'BIOS image file.*(?:invalid|does not match|not for this)|Invalid BIOS|not match this system') {
                    $wrongBios = $true
                }
                if ($line -match 'BIOS Flash completed|Flash completed|Update completed successfully|BIOS update is complete') {
                    $flashCompleted = $true
                }
                if ($line -match 'BIOS Flashing|Flashing BIOS') {
                    $flashStarted = $true
                }
                if ($line -match 'Apply the default start up image|restore factory default image') {
                    $defaultLogo = $true
                }
            }
        }
    }

    $ecInt = $null
    if ($null -ne $ExitCode -and "$ExitCode" -match '^-?\d+$') {
        $ecInt = [int]$ExitCode
    }

    $effectiveSuccess = $false
    $summaryOverride  = ''

    if ($null -eq $ecInt) {
        $effectiveSuccess = $false
        $summaryOverride  = 'Cancelled'
    } elseif ($ecInt -eq -999) {
        $effectiveSuccess = $false
        $summaryOverride  = 'ABORTED ([Q]): WINUPTP stalled before flashing (check winuptp.log or try Interactive WINUPTP / Full Cycle)'
    } elseif ($ecInt -notin @(0, 1)) {
        $effectiveSuccess = $false
        if (@($errorLines).Count -gt 0) {
            $summaryOverride = ("Failed (ExitCode {0}): {1}" -f $ecInt, $errorLines[0])
        } else {
            $summaryOverride = ("Failed (ExitCode {0})" -f $ecInt)
        }
    } elseif ($hasLog) {
        if ($rbBlocked) {
            $effectiveSuccess = $false
            $summaryOverride  = 'FAILED: Secure RollBack Prevention is enabled (Error 182)'
        } elseif ($wrongBios) {
            $effectiveSuccess = $false
            $summaryOverride  = 'FAILED: BIOS image does not match this system (check winuptp.log)'
        } elseif ($hasError) {
            $errSnippet = if (@($errorLines).Count -gt 0) { $errorLines[0] } else { 'unknown error' }
            $effectiveSuccess = $false
            $summaryOverride  = ("FAILED: Error in winuptp.log ({0})" -f $errSnippet)
        } elseif ($flashCompleted) {
            $effectiveSuccess = $true
        } elseif ($ecInt -eq 0) {
            $effectiveSuccess = $true
        } elseif (-not $flashStarted) {
            $effectiveSuccess = $false
            $summaryOverride  = 'FAILED: WINUPTP returned ExitCode 1 without flashing BIOS (check winuptp.log)'
        } else {
            $effectiveSuccess = $true
        }
    } else {
        $effectiveSuccess = $true
    }

    return [PSCustomObject]@{
        HasLog                = $hasLog
        HasError              = $hasError
        SecureRollbackBlocked = $rbBlocked
        WrongBiosFile         = $wrongBios
        FlashCompleted        = $flashCompleted
        FlashStarted          = $flashStarted
        DefaultLogoApplied    = $defaultLogo
        ErrorLines            = @($errorLines)
        EffectiveSuccess      = $effectiveSuccess
        SummaryOverride       = $summaryOverride
    }
}

function Write-PendingExecutionLog {
    param(
        [string]$UsbLogsDir,
        [hashtable]$Record
    )

    $stampStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try {
        if (-not (Test-Path -LiteralPath $UsbLogsDir -PathType Container)) {
            $null = New-Item -Path $UsbLogsDir -ItemType Directory -Force -ErrorAction Stop
        }
        $csvPath = Join-Path $UsbLogsDir 'history.csv'
        $row = [PSCustomObject]@{
            Timestamp          = $stampStr
            Serial             = $Record.Serial
            Model4             = $Record.Model4
            FullModel          = $Record.FullModel
            ProductName        = $Record.ProductName
            CurrentBios        = $Record.CurrentBios
            PackageID          = $Record.PackageID
            PackageVersion     = $Record.PackageVersion
            WasSameVersion     = $Record.WasSameVersion
            Mode               = $Record.Mode
            ExitCode           = 'PENDING'
            BitLockerSuspended = $Record.BitLockerSuspended
            Summary            = 'Launched WINUPTP (awaiting completion or immediate reboot)'
        }
        $row | Export-Csv -LiteralPath $csvPath -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        return $stampStr
    } catch {
        return ''
    }
}

function Write-ExecutionLog {
    param(
        [string]$UsbLogsDir,
        [string]$FlasherDir,
        [hashtable]$Record,
        [string]$PendingStamp = ''
    )

    if (-not (Test-Path -LiteralPath $UsbLogsDir -PathType Container)) {
        $null = New-Item -Path $UsbLogsDir -ItemType Directory -Force
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeSerial = ($Record.Serial -replace '[^A-Za-z0-9_-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeSerial)) { $safeSerial = 'NOSERIAL' }

    if (-not [string]::IsNullOrWhiteSpace($FlasherDir)) {
        $winuptpLogPath = Join-Path $FlasherDir 'winuptp.log'
        if (Test-Path -LiteralPath $winuptpLogPath -PathType Leaf) {
            Write-Section "Contents of winuptp.log"
            $logContent = Get-Content -LiteralPath $winuptpLogPath -ErrorAction SilentlyContinue
            foreach ($line in $logContent) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Write-Host "  $line" -ForegroundColor Gray
                }
            }
            $destLog = Join-Path $UsbLogsDir ("winuptp_{0}_{1}_{2}.log" -f $stamp, $Record.Model4, $safeSerial)
            try {
                Copy-Item -LiteralPath $winuptpLogPath -Destination $destLog -Force
                Write-Host "[OK] Log saved to USB: $destLog" -ForegroundColor Green
            } catch {
                Write-Warning "Failed to copy winuptp.log to USB: $($_.Exception.Message)"
            }
        }
    }

    $csvPath = Join-Path $UsbLogsDir 'history.csv'
    $row = [PSCustomObject]@{
        Timestamp          = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Serial             = $Record.Serial
        Model4             = $Record.Model4
        FullModel          = $Record.FullModel
        ProductName        = $Record.ProductName
        CurrentBios        = $Record.CurrentBios
        PackageID          = $Record.PackageID
        PackageVersion     = $Record.PackageVersion
        WasSameVersion     = $Record.WasSameVersion
        Mode               = $Record.Mode
        ExitCode           = $Record.ExitCode
        BitLockerSuspended = $Record.BitLockerSuspended
        Summary            = $Record.Summary
    }

    $replaced = $false
    if (-not [string]::IsNullOrWhiteSpace($PendingStamp) -and (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        try {
            $existingRows = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8 -ErrorAction Stop)
            $newRows = @()
            foreach ($er in $existingRows) {
                if (-not $replaced -and "$($er.Timestamp)" -eq $PendingStamp -and "$($er.Serial)" -eq "$($Record.Serial)" -and "$($er.ExitCode)" -eq 'PENDING') {
                    $newRows += $row
                    $replaced = $true
                } else {
                    $newRows += $er
                }
            }
            if ($replaced) {
                @($newRows) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                Write-Host "[OK] Updated history: $csvPath" -ForegroundColor Green
                return
            }
        } catch {
            $replaced = $false
        }
    }

    try {
        $row | Export-Csv -LiteralPath $csvPath -Append -NoTypeInformation -Encoding UTF8
        Write-Host "[OK] Appended to history: $csvPath" -ForegroundColor Green
    } catch {
        Write-Warning "Unable to write history.csv: $($_.Exception.Message)"
    }
}

function Read-FileLinesShared {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $list = New-Object System.Collections.Generic.List[string]
    $fs = $null
    $sr = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $sr.ReadLine())) {
            $list.Add($line)
        }
    } catch {
        return @()
    } finally {
        if ($null -ne $sr) { try { $sr.Dispose() } catch {} }
        if ($null -ne $fs) { try { $fs.Dispose() } catch {} }
    }
    return @($list.ToArray())
}

function Get-WinuptpLiveEvent {
    param([string]$LogLine)

    if ([string]::IsNullOrWhiteSpace($LogLine)) { return $null }

    if ($LogLine -match '<ERROR>|\[Flash Error\]|Failed to update BIOS') {
        return [PSCustomObject]@{ Phase = 'Error detected in WINUPTP!'; Message = $LogLine.Trim(); Color = 'Red' }
    } elseif ($LogLine -match 'LenovoBiosUpdateTool starting') {
        return [PSCustomObject]@{ Phase = 'Loading Lenovo flash driver...'; Message = 'WINUPTP started - loading driver...'; Color = 'Cyan' }
    } elseif ($LogLine -match 'Driver has been installed|Driver Loading') {
        return [PSCustomObject]@{ Phase = 'Checking BIOS version (30-50s)...'; Message = 'Driver loaded - verifying BIOS version and image (may take 30-50s)...'; Color = 'Cyan' }
    } elseif ($LogLine -match 'System BIOS Version ->\s*(.+)$') {
        return [PSCustomObject]@{ Phase = ''; Message = ("Current BIOS : {0}" -f $Matches[1].Trim()); Color = 'Gray' }
    } elseif ($LogLine -match 'Applying BIOS Version ->\s*(.+)$') {
        return [PSCustomObject]@{ Phase = 'Preparing BIOS flash...'; Message = ("Target BIOS  : {0}" -f $Matches[1].Trim()); Color = 'White' }
    } elseif ($LogLine -match 'Apply the default start up image|restore factory default image') {
        return [PSCustomObject]@{ Phase = 'Applying default Lenovo logo...'; Message = 'Restoring default Lenovo startup logo (clearing custom logo)...'; Color = 'Green' }
    } elseif ($LogLine -match 'Keep the custom start up image') {
        return [PSCustomObject]@{ Phase = ''; Message = 'Tool notice: Keep custom start up image'; Color = 'Yellow' }
    } elseif ($LogLine -match 'Power status OK|Battery check.*OK') {
        return [PSCustomObject]@{ Phase = 'Power check OK - preparing flash...'; Message = 'Power check: OK'; Color = 'Gray' }
    } elseif ($LogLine -match 'BIOS Flash completed') {
        return [PSCustomObject]@{ Phase = 'BIOS flash completed!'; Message = 'BIOS flash completed successfully!'; Color = 'Green' }
    } elseif ($LogLine -match 'BIOS Flashing') {
        return [PSCustomObject]@{ Phase = 'FLASHING BIOS (DO NOT POWER OFF!)...'; Message = 'Flashing BIOS (~25-40s) - DO NOT POWER OFF!'; Color = 'Yellow' }
    } elseif ($LogLine -match 'EC Flash completed') {
        return [PSCustomObject]@{ Phase = 'EC flash completed - closing tool...'; Message = 'EC flash completed!'; Color = 'Green' }
    } elseif ($LogLine -match 'EC Flashing') {
        return [PSCustomObject]@{ Phase = 'FLASHING EC firmware (DO NOT POWER OFF!)...'; Message = 'Flashing EC firmware (~10s) - DO NOT POWER OFF!'; Color = 'Yellow' }
    } elseif ($LogLine -notmatch 'UnobservedTaskException|SwissArmyKnife|System\.|^\s*at\s|---|--->|^\s*$') {
        return [PSCustomObject]@{ Phase = ''; Message = $LogLine.Trim(); Color = 'Gray' }
    }

    return $null
}

function Invoke-FlashBinary {
    param(
        [string]$ExePath,
        [string]$WorkingDir,
        [string]$Arguments,
        [string]$ModeLabel,
        [bool]$BitLockerActive,
        [ref]$BitLockerSuspendedRef
    )

    if ($BitLockerActive -and -not $BitLockerSuspendedRef.Value) {
        $ok = Suspend-BitLockerSafe -MountPoint $env:SystemDrive
        if ($ok) {
            $BitLockerSuspendedRef.Value = $true
        } else {
            Write-Host "[WARNING] Failed to suspend BitLocker!" -ForegroundColor Red
            Write-Host "If you continue without suspending BitLocker, Windows will prompt for the Recovery Key after reboot." -ForegroundColor Red
            $ans = Read-Host "Continue anyway? (Y/N)"
            if ($ans -notmatch '^(Y|y)$') {
                return $null
            }
        }
    }

    $staleLog = Join-Path $WorkingDir 'winuptp.log'
    if (Test-Path -LiteralPath $staleLog -PathType Leaf) {
        Remove-Item -LiteralPath $staleLog -Force -ErrorAction SilentlyContinue
    }

    $isSilent = ($Arguments -match '(^|\s)-s(\s|$)') -or ($ModeLabel -match 'SILENT')

    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Yellow
    Write-Host " LAUNCHING : $ExePath $Arguments" -ForegroundColor Yellow
    Write-Host " MODE      : $ModeLabel" -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Yellow
    if ($isSilent) {
        Write-Host "[INFO] Silent BIOS flashing typically takes 1 to 2 minutes (driver + check + flash)." -ForegroundColor Cyan
        Write-Host "[INFO] Live status updates below - DO NOT power off or close this window!" -ForegroundColor Yellow
    } else {
        Write-Host "[INFO] Interactive BIOS utility launched (follow the utility window; live status shown below)..." -ForegroundColor Cyan
    }

    if ([string]::IsNullOrWhiteSpace($Arguments)) {
        $proc = Start-Process -FilePath $ExePath -WorkingDirectory $WorkingDir -PassThru
    } else {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments -WorkingDirectory $WorkingDir -PassThru
    }
    # Cache .Handle immediately so $proc.ExitCode never becomes $null on PowerShell 5.1
    try { $null = $proc.Handle } catch {}

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $spinChars = @('|', '/', '-', '\')
    $spinIdx = 0
    $seenLineCount = 0
    $currentPhase = if ($isSilent) { 'Starting WINUPTP and waiting for initialization...' } else { 'Waiting for confirmation in flash window...' }
    $lastInlineLen = 0
    $finalFlushDone = $false
    $flashingActive = $false
    $lastLogActivitySec = 0
    $stallWarnedEmpty = $false
    $stallWarnedIdle = $false

    while ($true) {
        $lines = @(Read-FileLinesShared -Path $staleLog)
        if ($lines.Count -gt $seenLineCount) {
            $lastLogActivitySec = [int]$sw.Elapsed.TotalSeconds
            for ($i = $seenLineCount; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'BIOS Flashing|Flashing BIOS|EC Flashing') {
                    $flashingActive = $true
                }
                $ev = Get-WinuptpLiveEvent -LogLine $lines[$i]
                if ($null -ne $ev) {
                    if ($lastInlineLen -gt 0) {
                        Write-Host ("`r" + (' ' * $lastInlineLen) + "`r") -NoNewline
                        $lastInlineLen = 0
                    }
                    Write-Host ("  [{0}] {1}" -f $sw.Elapsed.ToString('mm\:ss'), $ev.Message) -ForegroundColor $ev.Color
                    if (-not [string]::IsNullOrWhiteSpace($ev.Phase)) {
                        $currentPhase = $ev.Phase
                    }
                }
            }
            $seenLineCount = $lines.Count
        }

        if ($proc.HasExited) {
            if (-not $finalFlushDone) {
                $finalFlushDone = $true
                try { $proc.WaitForExit() } catch {}
                Start-Sleep -Milliseconds 250
                continue
            } else {
                if ($lastInlineLen -gt 0) {
                    Write-Host ("`r" + (' ' * $lastInlineLen) + "`r") -NoNewline
                    $lastInlineLen = 0
                }
                break
            }
        }

        $idleSec = [int]$sw.Elapsed.TotalSeconds - $lastLogActivitySec
        if ($isSilent -and (-not $flashingActive) -and ($seenLineCount -eq 0) -and ($idleSec -ge 45) -and (-not $stallWarnedEmpty)) {
            if ($lastInlineLen -gt 0) {
                Write-Host ("`r" + (' ' * $lastInlineLen) + "`r") -NoNewline
                $lastInlineLen = 0
            }
            $stallWarnedEmpty = $true
            Write-Host "[WARNING] WINUPTP has written nothing to winuptp.log for 45s!" -ForegroundColor Yellow
            Write-Host "          Check Alt+Tab to see if a hidden dialog/prompt appeared behind this window." -ForegroundColor Yellow
            Write-Host '          If this model stalls on silent "-s -bcp", press [Q] to abort safely (flashing has NOT started), then try Interactive WINUPTP or Full Cycle.' -ForegroundColor Yellow
        } elseif ($isSilent -and (-not $flashingActive) -and ($seenLineCount -gt 0) -and ($idleSec -ge 90) -and (-not $stallWarnedIdle)) {
            if ($lastInlineLen -gt 0) {
                Write-Host ("`r" + (' ' * $lastInlineLen) + "`r") -NoNewline
                $lastInlineLen = 0
            }
            $stallWarnedIdle = $true
            Write-Host "[WARNING] No new winuptp.log entries for 90s (check Alt+Tab for a hidden dialog!)." -ForegroundColor Yellow
            Write-Host "          If stalled and flashing has not started, press [Q] to abort safely and try Interactive WINUPTP." -ForegroundColor Yellow
        }

        if (-not $flashingActive) {
            try {
                if ([Console]::KeyAvailable) {
                    $keyInfo = [Console]::ReadKey($true)
                    if ($keyInfo.Key -eq [System.ConsoleKey]::Q) {
                        if ($lastInlineLen -gt 0) {
                            Write-Host ("`r" + (' ' * $lastInlineLen) + "`r") -NoNewline
                            $lastInlineLen = 0
                        }
                        Write-Host "[!] Aborted wait ([Q]) before flashing started. Stopping process..." -ForegroundColor Yellow
                        try {
                            if (-not $proc.HasExited) {
                                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            }
                        } catch {}
                        Start-Sleep -Milliseconds 300
                        $sw.Stop()
                        return -999
                    }
                }
            } catch {}
        }

        $maxW = 78
        try {
            $winW = $Host.UI.RawUI.WindowSize.Width
            if ($winW -gt 20) { $maxW = $winW - 2 }
        } catch {}

        $spinChar = $spinChars[$spinIdx % $spinChars.Count]
        $spinIdx++
        $elapsedTxt = $sw.Elapsed.ToString('mm\:ss')
        $hintTxt = if (($stallWarnedEmpty -or $stallWarnedIdle) -and (-not $flashingActive)) {
            ' ([Q]=abort, Alt+Tab=check dialog)'
        } elseif ($isSilent) {
            ' (typically 1-2 min)'
        } else {
            ''
        }
        $statusText = "  [{0}] {1} {2}{3}" -f $spinChar, $elapsedTxt, $currentPhase, $hintTxt
        if ($statusText.Length -gt $maxW) {
            if ($maxW -gt 3) {
                $statusText = $statusText.Substring(0, $maxW - 3) + '...'
            } else {
                $statusText = $statusText.Substring(0, $maxW)
            }
        }
        $padCount = 0
        if ($lastInlineLen -gt $statusText.Length) {
            $padCount = $lastInlineLen - $statusText.Length
        }
        $lineOut = "`r" + $statusText + (' ' * $padCount)
        Write-Host $lineOut -NoNewline -ForegroundColor DarkCyan
        $lastInlineLen = $statusText.Length

        Start-Sleep -Milliseconds 500
    }

    $sw.Stop()
    Write-Host ("  [DONE] Process finished in {0} (ExitCode: {1})" -f $sw.Elapsed.ToString('mm\:ss'), $proc.ExitCode) -ForegroundColor Gray
    return $proc.ExitCode
}

function Invoke-TrackedFlash {
    param(
        [string]$UsbLogsDir,
        [string]$Serial,
        [string]$Model4,
        [string]$FullModel,
        [string]$ProductName,
        [string]$CurrentBios,
        [string]$PackageID,
        [string]$PackageVersion,
        [bool]$WasSameVersion,
        [string]$ModeLabel,
        [string]$ExePath,
        [string]$WorkingDir,
        [string]$Arguments,
        [bool]$BitLockerActive
    )

    $blSuspended = $false
    $pStamp = Write-PendingExecutionLog -UsbLogsDir $UsbLogsDir -Record @{
        Serial             = $Serial
        Model4             = $Model4
        FullModel          = $FullModel
        ProductName        = $ProductName
        CurrentBios        = $CurrentBios
        PackageID          = $PackageID
        PackageVersion     = $PackageVersion
        WasSameVersion     = $WasSameVersion
        Mode               = $ModeLabel
        BitLockerSuspended = $BitLockerActive
    }

    $ec = Invoke-FlashBinary -ExePath $ExePath -WorkingDir $WorkingDir -Arguments $Arguments -ModeLabel $ModeLabel -BitLockerActive $BitLockerActive -BitLockerSuspendedRef ([ref]$blSuspended)
    return [PSCustomObject]@{
        ExitCode           = $ec
        PendingStamp       = $pStamp
        BitLockerSuspended = $blSuspended
    }
}

function Invoke-ReEnableRollbackPhase {
    param(
        [string]$Model4,
        [string]$FullModel,
        [string]$ProductName,
        [string]$Serial,
        [string]$CurrentBios,
        [string]$PackageID,
        [string]$PackageVersion,
        [string]$SecureRollbackKeyName,
        [string]$UsbLogsDir,
        [PSCustomObject]$SecurityInfo,
        [string]$ResumeScriptPath
    )

    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Green
    Write-Host "   FINAL STEP: RE-ENABLING SecureRollBackPrevention" -ForegroundColor Green
    Write-Host "========================================================================" -ForegroundColor Green
    Write-Host ("  Model / MTM   : {0}  (Model4: {1})  |  Serial: {2}" -f $FullModel, $Model4, $Serial)
    Write-Host ("  Current BIOS  : {0}" -f $CurrentBios)

    $keyName = if (-not [string]::IsNullOrWhiteSpace($SecureRollbackKeyName)) { $SecureRollbackKeyName } else { 'SecureRollBackPrevention' }

    if ($SecurityInfo.Available -and ($SecurityInfo.SecureRollback -match 'Enable')) {
        Write-Host "[OK] SecureRollBackPrevention is already Enabled! All steps completed successfully." -ForegroundColor Green
        Write-ExecutionLog -UsbLogsDir $UsbLogsDir -FlasherDir '' -Record @{
            Serial             = $Serial
            Model4             = $Model4
            FullModel          = $FullModel
            ProductName        = $ProductName
            CurrentBios        = $CurrentBios
            PackageID          = $PackageID
            PackageVersion     = $PackageVersion
            WasSameVersion     = $false
            Mode               = 'REENABLE_ROLLBACK_ALREADY_ON'
            ExitCode           = 0
            BitLockerSuspended = $false
            Summary            = 'SecureRollBackPrevention already Enabled'
        }
    } else {
        Write-Host "[*] Attempting to re-enable $keyName via Lenovo WMI..." -ForegroundColor Cyan
        $wmiRes = Set-LenovoSecureRollback -SettingKeyName $keyName -Value 'Enable'
        if ($wmiRes.Success) {
            Write-Host "[OK] SecureRollBackPrevention re-enabled via Lenovo WMI!" -ForegroundColor Green
            Write-Host "     Change takes effect on next reboot - laptop is ready." -ForegroundColor Green
            Write-ExecutionLog -UsbLogsDir $UsbLogsDir -FlasherDir '' -Record @{
                Serial             = $Serial
                Model4             = $Model4
                FullModel          = $FullModel
                ProductName        = $ProductName
                CurrentBios        = $CurrentBios
                PackageID          = $PackageID
                PackageVersion     = $PackageVersion
                WasSameVersion     = $false
                Mode               = 'REENABLE_ROLLBACK_OK'
                ExitCode           = 0
                BitLockerSuspended = $false
                Summary            = 'SecureRollBackPrevention re-enabled via WMI'
            }
        } else {
            Write-Host ("[WARNING] Could not automatically re-enable $keyName via WMI (Set='{0}', Save='{1}')." -f $wmiRes.SetReturn, $wmiRes.SaveReturn) -ForegroundColor Yellow
            Write-ExecutionLog -UsbLogsDir $UsbLogsDir -FlasherDir '' -Record @{
                Serial             = $Serial
                Model4             = $Model4
                FullModel          = $FullModel
                ProductName        = $ProductName
                CurrentBios        = $CurrentBios
                PackageID          = $PackageID
                PackageVersion     = $PackageVersion
                WasSameVersion     = $false
                Mode               = 'REENABLE_ROLLBACK_MANUAL'
                ExitCode           = 1
                BitLockerSuspended = $false
                Summary            = "Manual BIOS re-enable of SecureRollBackPrevention required ($($wmiRes.ErrorMessage))"
            }
            Write-Host ""
            Write-Host "  [1] Reboot into BIOS Setup now (shutdown /r /fw /t 0) -> Security -> Secure RollBack Prevention -> Enabled -> F10" -ForegroundColor Cyan
            Write-Host "  [0] Finish without rebooting"
            $endC = Read-Host "Select option [0]"
            if ($endC -eq '1') {
                try {
                    if (Test-Path -LiteralPath $ResumeScriptPath -PathType Leaf) {
                        Remove-Item -LiteralPath $ResumeScriptPath -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
                Clear-TempWorkDirectory
                Invoke-BiosSetupOrReboot
            }
        }
    }

    Clear-TempWorkDirectory
    try {
        if (Test-Path -LiteralPath $ResumeScriptPath -PathType Leaf) {
            Remove-Item -LiteralPath $ResumeScriptPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Invoke-DowngradePhase {
    param(
        [string]$Model4,
        [string]$FullModel,
        [string]$ProductName,
        [string]$Serial,
        [string]$CurrentBios,
        [string]$DowngradeWorkDir,
        [string]$DowngradePackageID,
        [string]$DowngradePackageVersion,
        [string]$LatestWorkDir,
        [string]$LatestPackageID,
        [string]$LatestPackageVersion,
        [bool]$ReEnableRollbackAtEnd,
        [string]$SecureRollbackKeyName,
        [string]$ToolRoot,
        [string]$UsbLogsDir,
        [PSCustomObject]$BitLockerState,
        [PSCustomObject]$SecurityInfo,
        [switch]$SkipPower,
        [string]$ScriptSelfPath,
        [string]$ResumeRoot,
        [string]$ResumeStatePath,
        [string]$ResumeScriptPath,
        [string]$ResumeTaskName
    )

    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "   DOWNGRADE PHASE: v$DowngradePackageVersion ($DowngradePackageID) -> Clear Custom Logo" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host ("  Current BIOS      : {0}" -f $CurrentBios)
    Write-Host ("  Downgrade package : {0} (v{1}) at {2}" -f $DowngradePackageID, $DowngradePackageVersion, $DowngradeWorkDir)
    Write-Host ("  Saved latest      : {0} (v{1}) for automatic restore" -f $LatestPackageID, $LatestPackageVersion) -ForegroundColor Green

    Test-PowerBeforeFlash -SkipCheck:$SkipPower
    $blColor = if ($BitLockerState.Active) { 'Yellow' } else { 'Green' }
    Write-Host ("  BitLocker         : {0}" -f $BitLockerState.Detail) -ForegroundColor $blColor

    if ($SecurityInfo.Available -and ($SecurityInfo.SecureRollback -match 'Enable')) {
        Write-Host ""
        Write-Host "[WARNING] SecureRollBackPrevention is STILL Enabled! Downgrade will likely be rejected." -ForegroundColor Red
        Write-Host "  [1] Continue anyway"
        Write-Host "  [2] Reboot into BIOS Setup again (with auto-resume)"
        Write-Host "  [0] Cancel"
        $rChoice = Read-Host "Select option [2]"
        if ([string]::IsNullOrWhiteSpace($rChoice)) { $rChoice = '2' }
        if ($rChoice -eq '0') { return }
        if ($rChoice -eq '2') {
            $null = Register-ResumeAfterReboot -StateData @{
                Phase                   = 'DOWNGRADE'
                CreatedAt               = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                Model4                  = $Model4
                FullModel               = $FullModel
                ProductName             = $ProductName
                Serial                  = $Serial
                CurrentBios             = $CurrentBios
                DowngradeWorkDir        = $DowngradeWorkDir
                DowngradePackageID      = $DowngradePackageID
                DowngradePackageVersion = $DowngradePackageVersion
                LatestWorkDir           = $LatestWorkDir
                LatestPackageID         = $LatestPackageID
                LatestPackageVersion    = $LatestPackageVersion
                ReEnableRollbackAtEnd   = $ReEnableRollbackAtEnd
                SecureRollbackKeyName   = $SecureRollbackKeyName
                OriginalUsbRoot         = $ToolRoot
            } -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName
            Invoke-BiosSetupOrReboot
        }
    }

    $dgArtifacts = Find-FlashArtifacts -WorkDir $DowngradeWorkDir
    if (-not $dgArtifacts.Winuptp) {
        Write-Host "[ERROR] winuptp.exe not found in downgrade folder: $DowngradeWorkDir" -ForegroundColor Red
        return
    }

    $flashExe = $dgArtifacts.Winuptp.FullName
    $flashDir = $dgArtifacts.Winuptp.DirectoryName

    Write-Host ""
    Write-Host ("  [1] Silent WINUPTP (-s -bcp) downgrade to v{0} (RECOMMENDED - clears logo unattended)" -f $DowngradePackageVersion) -ForegroundColor Green
    Write-Host ("  [2] Interactive WINUPTP downgrade to v{0} (click NO on custom logo prompt)" -f $DowngradePackageVersion)
    Write-Host "  [0] Cancel"
    $dgChoice = Read-Host "Select option [1]"
    if ([string]::IsNullOrWhiteSpace($dgChoice)) { $dgChoice = '1' }
    if ($dgChoice -notin @('1', '2')) {
        Write-Host "Cancelled." -ForegroundColor Gray
        return
    }

    $argsToUse = if ($dgChoice -eq '2') { '' } else { '-s -bcp' }
    $modeLabel = if ($dgChoice -eq '2') { 'DOWNGRADE_WINUPTP_INTERACTIVE' } else { 'DOWNGRADE_WINUPTP_SILENT_BCP' }

    # Schedule UPGRADE_BACK before running WINUPTP (safe even if ExitCode 0 triggers immediate reboot)
    $null = Register-ResumeAfterReboot -StateData @{
        Phase                 = 'UPGRADE_BACK'
        CreatedAt             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Model4                = $Model4
        FullModel             = $FullModel
        ProductName           = $ProductName
        Serial                = $Serial
        PreDowngradeBios      = $CurrentBios
        LatestWorkDir         = $LatestWorkDir
        LatestPackageID       = $LatestPackageID
        LatestPackageVersion  = $LatestPackageVersion
        ReEnableRollbackAtEnd = $ReEnableRollbackAtEnd
        SecureRollbackKeyName = $SecureRollbackKeyName
        OriginalUsbRoot       = $ToolRoot
    } -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName

    if ($dgChoice -eq '2') {
        Write-Host ""
        Write-Host ">>> IMPORTANT: When WINUPTP prompts about keeping the custom start up image file, click NO! <<<" -ForegroundColor Black -BackgroundColor Yellow
    }

    $trackRes = Invoke-TrackedFlash `
        -UsbLogsDir $UsbLogsDir -Serial $Serial -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName `
        -CurrentBios $CurrentBios -PackageID $DowngradePackageID -PackageVersion $DowngradePackageVersion -WasSameVersion:$false `
        -ModeLabel $modeLabel -ExePath $flashExe -WorkingDir $flashDir -Arguments $argsToUse -BitLockerActive $BitLockerState.Active
    $pendingStamp       = $trackRes.PendingStamp
    $bitlockerSuspended = $trackRes.BitLockerSuspended
    $execExitCode       = $trackRes.ExitCode

    $logCheck = Get-WinuptpLogAnalysis -FlasherDir $flashDir -ExitCode $execExitCode

    if (-not $logCheck.EffectiveSuccess) {
        Clear-ResumeRegistration -TaskName $ResumeTaskName -StatePath $ResumeStatePath
        Write-Host ""
        Write-Host ("[ERROR] Downgrade BIOS flash FAILED: {0}" -f $logCheck.SummaryOverride) -ForegroundColor Red
        foreach ($el in @($logCheck.ErrorLines)) {
            Write-Host ("  {0}" -f $el) -ForegroundColor Red
        }
        if ($logCheck.SecureRollbackBlocked) {
            Write-Host "[TIP] SecureRollBackPrevention is enabled in BIOS and blocked the downgrade!" -ForegroundColor Yellow
            Write-Host "      Enter BIOS Setup (Security -> Secure RollBack Prevention -> Disabled -> F10) and re-run." -ForegroundColor Yellow
        }
        $summary = $logCheck.SummaryOverride
    } elseif ($execExitCode -eq 0) {
        $summary = 'Downgrade staged - system rebooting (next step: restore latest BIOS)'
    } else {
        $summary = 'Downgrade ready - reboot required (next step: restore latest BIOS)'
    }

    Write-ExecutionLog -UsbLogsDir $UsbLogsDir -FlasherDir $flashDir -PendingStamp $pendingStamp -Record @{
        Serial             = $Serial
        Model4             = $Model4
        FullModel          = $FullModel
        ProductName        = $ProductName
        CurrentBios        = $CurrentBios
        PackageID          = $DowngradePackageID
        PackageVersion     = $DowngradePackageVersion
        WasSameVersion     = $false
        Mode               = $modeLabel
        ExitCode           = $(if ($null -ne $execExitCode) { $execExitCode } else { '' })
        BitLockerSuspended = $bitlockerSuspended
        Summary            = $summary
    }

    if ($logCheck.EffectiveSuccess -and ($execExitCode -eq 1)) {
        Write-Host ""
        Write-Host "After this reboot completes the downgrade BIOS flash, this tool will auto-launch and restore BIOS v$LatestPackageVersion!" -ForegroundColor Green
        Write-Host "DO NOT POWER OFF the laptop while the BIOS flash screen is running!" -ForegroundColor Black -BackgroundColor Yellow
        $rb = Read-Host "Reboot now? (Y/N)"
        if ($rb -match '^(Y|y)$') {
            Restart-Computer -Force
        }
    }
}

function Invoke-UpgradeBackPhase {
    param(
        [string]$Model4,
        [string]$FullModel,
        [string]$ProductName,
        [string]$Serial,
        [string]$CurrentBios,
        [string]$LatestWorkDir,
        [string]$LatestPackageID,
        [string]$LatestPackageVersion,
        [string]$PreDowngradeBios,
        [bool]$ReEnableRollbackAtEnd,
        [string]$SecureRollbackKeyName,
        [string]$ToolRoot,
        [string]$UsbLogsDir,
        [PSCustomObject]$BitLockerState,
        [PSCustomObject]$SecurityInfo,
        [switch]$SkipPower,
        [string]$ScriptSelfPath,
        [string]$ResumeRoot,
        [string]$ResumeStatePath,
        [string]$ResumeScriptPath,
        [string]$ResumeTaskName
    )

    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Green
    Write-Host "   RESTORE PHASE: Updating back to latest BIOS v$LatestPackageVersion ($LatestPackageID)" -ForegroundColor Green
    Write-Host "========================================================================" -ForegroundColor Green
    Write-Host ("  Pre-downgrade BIOS    : {0}" -f $PreDowngradeBios)
    Write-Host ("  Current BIOS (reboot) : {0}" -f $CurrentBios)
    Write-Host ("  Target latest package : {0} (v{1}) at {2}" -f $LatestPackageID, $LatestPackageVersion, $LatestWorkDir)

    $latestLevels = @(Get-BiosLevelsFromCacheFolder -Folder $LatestWorkDir)
    $relNow = Get-BiosVersionRelation -CurrentBios $CurrentBios -DetectBiosLevels $latestLevels -PkgVersion $LatestPackageVersion

    if ($relNow -eq 'OLDER_ON_LAPTOP') {
        Write-Host "[OK] Downgrade succeeded (current BIOS: $CurrentBios). Restoring latest BIOS v$LatestPackageVersion..." -ForegroundColor Green
    } elseif ($relNow -eq 'SAME') {
        Write-Host "[WARNING] Current BIOS is still '$CurrentBios' (downgrade does not appear to have been applied)." -ForegroundColor Yellow
    }

    Test-PowerBeforeFlash -SkipCheck:$SkipPower
    $blColor = if ($BitLockerState.Active) { 'Yellow' } else { 'Green' }
    Write-Host ("  BitLocker     : {0}" -f $BitLockerState.Detail) -ForegroundColor $blColor

    $upArtifacts = Find-FlashArtifacts -WorkDir $LatestWorkDir
    if (-not $upArtifacts.Winuptp) {
        Write-Host "[ERROR] winuptp.exe not found in latest BIOS folder: $LatestWorkDir" -ForegroundColor Red
        return
    }

    $flashExe = $upArtifacts.Winuptp.FullName
    $flashDir = $upArtifacts.Winuptp.DirectoryName

    Write-Host ""
    Write-Host ("  [1] Silent WINUPTP (-s -bcp) -> restore v{0} (RECOMMENDED)" -f $LatestPackageVersion) -ForegroundColor Green
    Write-Host ("  [2] Interactive WINUPTP -> restore v{0}" -f $LatestPackageVersion)
    if ($ReEnableRollbackAtEnd) {
        Write-Host "  [3] Skip BIOS restore and go straight to re-enabling SecureRollBackPrevention"
    }
    Write-Host "  [0] Cancel"

    $defaultOpt = if ($relNow -eq 'SAME') { '' } else { '1' }
    $upChoice = Read-Host ($(if ($defaultOpt -eq '1') { "Select option [1]" } else { "Select option" }))
    if ([string]::IsNullOrWhiteSpace($upChoice) -and $defaultOpt -eq '1') { $upChoice = '1' }

    if ($upChoice -eq '3' -and $ReEnableRollbackAtEnd) {
        Invoke-ReEnableRollbackPhase -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName -Serial $Serial -CurrentBios $CurrentBios -PackageID $LatestPackageID -PackageVersion $LatestPackageVersion -SecureRollbackKeyName $SecureRollbackKeyName -UsbLogsDir $UsbLogsDir -SecurityInfo $SecurityInfo -ResumeScriptPath $ResumeScriptPath
        return
    }

    if ($upChoice -notin @('1', '2')) {
        Write-Host "Cancelled." -ForegroundColor Gray
        return
    }

    $argsToUse = if ($upChoice -eq '2') { '' } else { '-s -bcp' }
    $modeLabel = if ($upChoice -eq '2') { 'UPGRADE_BACK_WINUPTP_INTERACTIVE' } else { 'UPGRADE_BACK_WINUPTP_SILENT_BCP' }

    if ($ReEnableRollbackAtEnd) {
        $null = Register-ResumeAfterReboot -StateData @{
            Phase                 = 'REENABLE_ROLLBACK'
            CreatedAt             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Model4                = $Model4
            FullModel             = $FullModel
            ProductName           = $ProductName
            Serial                = $Serial
            PackageID             = $LatestPackageID
            PackageVersion        = $LatestPackageVersion
            SecureRollbackKeyName = $SecureRollbackKeyName
            OriginalUsbRoot       = $ToolRoot
        } -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName
    }

    if ($upChoice -eq '2') {
        Write-Host ""
        Write-Host ">>> NOTE: If WINUPTP asks about a custom logo again, click NO! <<<" -ForegroundColor Black -BackgroundColor Yellow
    }

    $trackRes = Invoke-TrackedFlash `
        -UsbLogsDir $UsbLogsDir -Serial $Serial -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName `
        -CurrentBios $CurrentBios -PackageID $LatestPackageID -PackageVersion $LatestPackageVersion -WasSameVersion:($relNow -eq 'SAME') `
        -ModeLabel $modeLabel -ExePath $flashExe -WorkingDir $flashDir -Arguments $argsToUse -BitLockerActive $BitLockerState.Active
    $pendingStamp       = $trackRes.PendingStamp
    $bitlockerSuspended = $trackRes.BitLockerSuspended
    $execExitCode       = $trackRes.ExitCode

    $logCheck = Get-WinuptpLogAnalysis -FlasherDir $flashDir -ExitCode $execExitCode

    if (-not $logCheck.EffectiveSuccess) {
        Clear-ResumeRegistration -TaskName $ResumeTaskName -StatePath $ResumeStatePath
        Write-Host ""
        Write-Host ("[ERROR] Restore to v{0} FAILED: {1}" -f $LatestPackageVersion, $logCheck.SummaryOverride) -ForegroundColor Red
        foreach ($el in @($logCheck.ErrorLines)) {
            Write-Host ("  {0}" -f $el) -ForegroundColor Red
        }
        $summary = $logCheck.SummaryOverride
    } elseif ($execExitCode -eq 0) {
        $summary = "Restore to v$LatestPackageVersion staged - system rebooting"
    } else {
        $summary = "Restore to v$LatestPackageVersion ready - reboot required"
    }

    Write-ExecutionLog -UsbLogsDir $UsbLogsDir -FlasherDir $flashDir -PendingStamp $pendingStamp -Record @{
        Serial             = $Serial
        Model4             = $Model4
        FullModel          = $FullModel
        ProductName        = $ProductName
        CurrentBios        = $CurrentBios
        PackageID          = $LatestPackageID
        PackageVersion     = $LatestPackageVersion
        WasSameVersion     = ($relNow -eq 'SAME')
        Mode               = $modeLabel
        ExitCode           = $(if ($null -ne $execExitCode) { $execExitCode } else { '' })
        BitLockerSuspended = $bitlockerSuspended
        Summary            = $summary
    }

    if ($logCheck.EffectiveSuccess -and ($execExitCode -eq 1)) {
        Write-Host ""
        if ($ReEnableRollbackAtEnd) {
            Write-Host "After this reboot, the tool will run once more to automatically re-enable SecureRollBackPrevention!" -ForegroundColor Green
        }
        Write-Host "DO NOT POWER OFF the laptop while the BIOS flash screen is running!" -ForegroundColor Black -BackgroundColor Yellow
        $rb = Read-Host "Reboot now? (Y/N)"
        if ($rb -match '^(Y|y)$') {
            Restart-Computer -Force
        }
    }
}

# ==============================================================================
# MAIN WORKFLOW
# ==============================================================================
Initialize-TlsAndEncoding
Write-Banner

if (-not (Test-IsAdministrator)) {
    Write-Host "[ERROR] This tool must be run as Administrator!" -ForegroundColor Red
    Write-Host "Double-click START-Logo-Remover.bat (or Run as administrator)." -ForegroundColor Yellow
    Pause-Exit 1
}

$ResumeRoot       = 'C:\Temp\TPLogoRemover\resume'
$ResumeStatePath  = Join-Path $ResumeRoot 'resume-state.json'
$ResumeScriptPath = Join-Path $ResumeRoot 'Remove-ThinkPadLogo.ps1'
$ResumeTaskName   = 'ThinkPadLogoRemover_Resume'
$WorkRoot         = 'C:\Temp\TPLogoRemover\work'
$FallbackCache    = 'C:\Temp\TPLogoRemover\cache'
$ScriptSelfPath   = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($ScriptSelfPath)) {
    $ScriptSelfPath = $MyInvocation.MyCommand.Path
}

$resumedMode     = $false
$resumeValid     = $false
$resumeData      = $null
$origUsbFromJson = ''

if ($Resume) {
    if (Test-Path -LiteralPath $ResumeStatePath -PathType Leaf) {
        try {
            $rawState = Get-Content -LiteralPath $ResumeStatePath -Raw -Encoding UTF8 -ErrorAction Stop
            $resumeData = $rawState | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Unable to read resume-state.json: $($_.Exception.Message)"
        }
    }
    # Immediately remove scheduled task and state file to prevent an infinite resume loop
    Clear-ResumeRegistration -TaskName $ResumeTaskName -StatePath $ResumeStatePath

    if ($resumeData) {
        $origUsbFromJson = "$($resumeData.OriginalUsbRoot)"
        $ageOk = $false
        try {
            $created = [datetime]::ParseExact("$($resumeData.CreatedAt)", 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            if (([datetime]::Now - $created).TotalHours -le 24) {
                $ageOk = $true
            }
        } catch {}

        if ($ageOk) {
            $resumeValid = $true
        } else {
            Write-Warning "Saved resume state has expired (>24h). Falling back to normal startup..."
        }
    } else {
        Write-Warning "No saved resume state found (-Resume). Falling back to normal startup..."
    }
} else {
    Clear-ResumeRegistration -TaskName $ResumeTaskName -StatePath $ResumeStatePath
}

$ToolRootCandidate = Split-Path -Parent $PSScriptRoot
$ResolvedRoot = Resolve-ToolRootFromSystem -PreferredRoot $(if (-not [string]::IsNullOrWhiteSpace($origUsbFromJson)) { $origUsbFromJson } else { $ToolRootCandidate })
$ToolRoot = if ($ResolvedRoot) { $ResolvedRoot } else { $ToolRootCandidate }

$ModuleManifest = Join-Path $ToolRoot 'modules\LSUClient\LSUClient.psd1'
$UsbCacheDir    = Join-Path $ToolRoot 'cache'
$UsbLogsDir     = Join-Path $ToolRoot 'logs'

if ($resumeValid) {
    $resumedMode = $true
    $live = Get-LiveSystemInfo
    $Model4      = "$($resumeData.Model4)"
    $FullModel   = if (-not [string]::IsNullOrWhiteSpace($live.FullModel)) { $live.FullModel } else { "$($resumeData.FullModel)" }
    $ProductName = if (-not [string]::IsNullOrWhiteSpace($live.ProductName)) { $live.ProductName } else { "$($resumeData.ProductName)" }
    $Serial      = if (-not [string]::IsNullOrWhiteSpace($live.Serial)) { $live.Serial } else { "$($resumeData.Serial)" }
    $CurrentBios = if (-not [string]::IsNullOrWhiteSpace($live.CurrentBios)) { $live.CurrentBios } else { "$($resumeData.CurrentBios)" }
    $UsbLogsDir  = Resolve-UsbLogsDir -OriginalUsbRoot $origUsbFromJson
    Sync-LocalLogsToUsb -UsbLogsDir $UsbLogsDir
    $bl          = Get-BitLockerState -MountPoint $env:SystemDrive
    $sec         = Get-LenovoBiosSecurityInfo

    $phase = if ($resumeData.PSObject.Properties['Phase'] -and -not [string]::IsNullOrWhiteSpace("$($resumeData.Phase)")) { "$($resumeData.Phase)" } else { 'SAMEVER_FLASH' }
    $reEnableAtEnd = $false
    if ($resumeData.PSObject.Properties['ReEnableRollbackAtEnd']) {
        $reEnableAtEnd = [bool]$resumeData.ReEnableRollbackAtEnd
    }
    $rbKeyName = if ($resumeData.PSObject.Properties['SecureRollbackKeyName'] -and -not [string]::IsNullOrWhiteSpace("$($resumeData.SecureRollbackKeyName)")) { "$($resumeData.SecureRollbackKeyName)" } else { $sec.SecureRollbackKeyName }

    if ($phase -eq 'DOWNGRADE') {
        $dgDir = "$($resumeData.DowngradeWorkDir)"
        $ltDir = "$($resumeData.LatestWorkDir)"
        if ((Test-Path -LiteralPath $dgDir -PathType Container) -and (Test-Path -LiteralPath $ltDir -PathType Container)) {
            Invoke-DowngradePhase `
                -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName -Serial $Serial -CurrentBios $CurrentBios `
                -DowngradeWorkDir $dgDir -DowngradePackageID "$($resumeData.DowngradePackageID)" -DowngradePackageVersion "$($resumeData.DowngradePackageVersion)" `
                -LatestWorkDir $ltDir -LatestPackageID "$($resumeData.LatestPackageID)" -LatestPackageVersion "$($resumeData.LatestPackageVersion)" `
                -ReEnableRollbackAtEnd $reEnableAtEnd -SecureRollbackKeyName $rbKeyName `
                -ToolRoot $ToolRoot -UsbLogsDir $UsbLogsDir -BitLockerState $bl -SecurityInfo $sec -SkipPower:$SkipPowerCheck `
                -ScriptSelfPath $ScriptSelfPath -ResumeRoot $ResumeRoot -ResumeStatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -ResumeTaskName $ResumeTaskName
            Pause-Exit 0
        } else {
            Write-Warning "Files for the DOWNGRADE phase were not found. Falling back to normal startup..."
            $resumeValid = $false
            $resumedMode = $false
        }
    } elseif ($phase -eq 'UPGRADE_BACK') {
        $ltDir = "$($resumeData.LatestWorkDir)"
        if (Test-Path -LiteralPath $ltDir -PathType Container) {
            $preDg = if ($resumeData.PSObject.Properties['PreDowngradeBios']) { "$($resumeData.PreDowngradeBios)" } else { '' }
            Invoke-UpgradeBackPhase `
                -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName -Serial $Serial -CurrentBios $CurrentBios `
                -LatestWorkDir $ltDir -LatestPackageID "$($resumeData.LatestPackageID)" -LatestPackageVersion "$($resumeData.LatestPackageVersion)" `
                -PreDowngradeBios $preDg -ReEnableRollbackAtEnd $reEnableAtEnd -SecureRollbackKeyName $rbKeyName `
                -ToolRoot $ToolRoot -UsbLogsDir $UsbLogsDir -BitLockerState $bl -SecurityInfo $sec -SkipPower:$SkipPowerCheck `
                -ScriptSelfPath $ScriptSelfPath -ResumeRoot $ResumeRoot -ResumeStatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -ResumeTaskName $ResumeTaskName
            Pause-Exit 0
        } else {
            Write-Warning "Folder for restoring the target BIOS ($ltDir) was not found. Falling back to normal startup..."
            $resumeValid = $false
            $resumedMode = $false
        }
    } elseif ($phase -eq 'REENABLE_ROLLBACK') {
        Invoke-ReEnableRollbackPhase `
            -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName -Serial $Serial -CurrentBios $CurrentBios `
            -PackageID "$($resumeData.PackageID)" -PackageVersion "$($resumeData.PackageVersion)" `
            -SecureRollbackKeyName $rbKeyName -UsbLogsDir $UsbLogsDir -SecurityInfo $sec -ResumeScriptPath $ResumeScriptPath
        Pause-Exit 0
    } else {
        # SAMEVER_FLASH
        $WorkDir = "$($resumeData.WorkDir)"
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
            Write-Warning "Extracted folder ($WorkDir) was not found. Falling back to normal startup..."
            $resumeValid = $false
            $resumedMode = $false
        } else {
            $biosRelation  = "$($resumeData.BiosRelation)"
            $isSameOrNewer = ($biosRelation -in @('SAME', 'NEWER_ON_LAPTOP'))
            $selected = [PSCustomObject]@{
                Source         = "$($resumeData.SourceMode)"
                ID             = "$($resumeData.PackageID)"
                Version        = "$($resumeData.PackageVersion)"
                ReleaseDate    = ''
                IsInstalled    = $isSameOrNewer
                BiosRelation   = $biosRelation
                Title          = "$($resumeData.PackageTitle)"
                InstallCommand = "$($resumeData.InstallCommand)"
                XmlUrl         = ''
            }
            $reEnableRollbackOnSameVer = $reEnableAtEnd
            $autoRunFastSameVer        = $false
            $secureRbKeySaved          = $rbKeyName

            Write-Host ""
            Write-Host "========================================================================" -ForegroundColor Green
            Write-Host "   AUTOMATIC RESUME AFTER REBOOT (RESUME)" -ForegroundColor Green
            Write-Host "========================================================================" -ForegroundColor Green
            Write-Host ("  Model / MTM   : {0}  (Model4: {1})  |  Serial: {2}" -f $FullModel, $Model4, $Serial)
            Write-Host ("  Current BIOS  : {0}" -f $CurrentBios)
            Write-Host ("  Ready Package : {0} (v{1}) in {2}" -f $selected.ID, $selected.Version, $WorkDir)
            Write-Host ("  Log Folder    : {0}" -f $UsbLogsDir) -ForegroundColor Gray

            Test-PowerBeforeFlash -SkipCheck:$SkipPowerCheck
            $blColor = if ($bl.Active) { 'Yellow' } else { 'Green' }
            Write-Host ("  BitLocker     : {0}" -f $bl.Detail) -ForegroundColor $blColor
            if ($sec.Available) {
                Write-Host ("  BIOS Setting  : FlashByEndUsers={0} | SecureRollBack={1} | WinUEFI={2} | SupervisorPW={3}" -f `
                    $sec.FlashByEndUsers, $sec.SecureRollback, $sec.WindowsUefiUpdate, $sec.SupervisorPasswordSet) -ForegroundColor Gray
            }

            if ($sec.Available -and ($sec.SecureRollback -match 'Disable')) {
                Write-Host ""
                Write-Host "[OK] SecureRollBackPrevention is now DISABLED! Resuming right where we left off..." -ForegroundColor Green
            } elseif ($sec.Available -and ($sec.SecureRollback -match 'Enable')) {
                Write-Host ""
                Write-Host "[WARNING] SecureRollBackPrevention is STILL Enable! (The BIOS change may not have been saved with F10)." -ForegroundColor Red
                Write-Host "  [1] Continue to the launch menu anyway"
                Write-Host "  [2] Reboot back into BIOS Setup (with auto-resume)"
                Write-Host "  [0] Exit"
                $rChoice = Read-Host "Select option [1]"
                if ($rChoice -eq '0') { Pause-Exit 0 }
                if ($rChoice -eq '2') {
                    $null = Register-ResumeAfterReboot -StateData @{
                        Phase                 = 'SAMEVER_FLASH'
                        CreatedAt             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        Model4                = $Model4
                        FullModel             = $FullModel
                        ProductName           = $ProductName
                        Serial                = $Serial
                        CurrentBios           = $CurrentBios
                        PackageID             = $selected.ID
                        PackageVersion        = $selected.Version
                        PackageTitle          = $selected.Title
                        WorkDir               = $WorkDir
                        InstallCommand        = $selected.InstallCommand
                        SourceMode            = $selected.Source
                        BiosRelation          = $biosRelation
                        ReEnableRollbackAtEnd = $reEnableRollbackOnSameVer
                        SecureRollbackKeyName = $secureRbKeySaved
                        OriginalUsbRoot       = $(if (-not [string]::IsNullOrWhiteSpace($origUsbFromJson)) { $origUsbFromJson } else { $ToolRoot })
                    } -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName
                    Invoke-BiosSetupOrReboot
                }
            }
        }
    }
}

if (-not $resumeValid) {
    $reEnableRollbackOnSameVer = $false
    $autoRunFastSameVer = $false
    $secureRbKeySaved = 'SecureRollBackPrevention'

    foreach ($d in @($UsbCacheDir, $UsbLogsDir, $WorkRoot)) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            try { $null = New-Item -Path $d -ItemType Directory -Force } catch {}
        }
    }
    Sync-LocalLogsToUsb -UsbLogsDir $UsbLogsDir

    $EffectiveCacheDir = $UsbCacheDir
    $UsingFallbackCache = $false
    if ($UsbCacheDir.Contains(' ')) {
        Write-Warning "USB cache path contains spaces ($UsbCacheDir) - LSUClient does not support spaces in -Path."
        Write-Warning "Using local cache: $FallbackCache"
        $EffectiveCacheDir = $FallbackCache
        $UsingFallbackCache = $true
    } else {
        try {
            $probeFile = Join-Path $UsbCacheDir (".write_test_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($probeFile, 'ok')
            Remove-Item -LiteralPath $probeFile -Force
        } catch {
            Write-Warning "USB cache is not writable ($UsbCacheDir). Using local cache: $FallbackCache"
            $EffectiveCacheDir = $FallbackCache
            $UsingFallbackCache = $true
        }
    }
    if (-not (Test-Path -LiteralPath $EffectiveCacheDir -PathType Container)) {
        $null = New-Item -Path $EffectiveCacheDir -ItemType Directory -Force
    }

    $IndexPath = Join-Path $UsbCacheDir 'model-index.json'

    # 1. System check
    Write-Section "1. System Information & Security Checks"
    $live = Get-LiveSystemInfo
    $Manufacturer = if ($live.Manufacturer) { $live.Manufacturer } else { 'Unknown' }
    $FullModel    = $live.FullModel
    $ProductName  = if ($live.ProductName) { $live.ProductName } else { 'Unknown' }
    $Serial       = if ($live.Serial) { $live.Serial } else { 'Unknown' }
    $CurrentBios  = if ($live.CurrentBios) { $live.CurrentBios } else { 'Unknown' }
    $BiosDate     = if ($live.BiosDate) { $live.BiosDate } else { 'Unknown' }

    if (-not [string]::IsNullOrWhiteSpace($ModelOverride)) {
        $Model4 = $ModelOverride.Trim().ToUpper()
        if ($Model4.Length -gt 4) { $Model4 = $Model4.Substring(0, 4) }
    } elseif ($FullModel.Length -ge 4) {
        $Model4 = $FullModel.Substring(0, 4).ToUpper()
    } else {
        $Model4 = ''
    }

    Write-Host ("  Manufacturer  : {0}" -f $Manufacturer)
    Write-Host ("  Model / MTM   : {0}  (Model4: {1})" -f $FullModel, $Model4)
    Write-Host ("  Model Name    : {0}" -f $ProductName)
    Write-Host ("  Serial Number : {0}" -f $Serial)
    Write-Host ("  Current BIOS  : {0}  ({1})" -f $CurrentBios, $BiosDate)

    if (($Manufacturer -notmatch 'LENOVO') -and [string]::IsNullOrWhiteSpace($ModelOverride)) {
        Write-Host "[WARNING] Manufacturer is not Lenovo ($Manufacturer)!" -ForegroundColor Red
        $cont = Read-Host "Are you sure you want to continue? (Y/N)"
        if ($cont -notmatch '^(Y|y)$') {
            Pause-Exit 0
        }
    }

    if ([string]::IsNullOrWhiteSpace($Model4)) {
        $Model4 = (Read-Host "Could not read the 4-character model code. Enter manually (e.g. 20S0)").Trim().ToUpper()
        if ([string]::IsNullOrWhiteSpace($Model4)) {
            Write-Host "[ERROR] Model code is required." -ForegroundColor Red
            Pause-Exit 1
        }
    }

    Test-PowerBeforeFlash -SkipCheck:$SkipPowerCheck

    $bl = Get-BitLockerState -MountPoint $env:SystemDrive
    $blColor = if ($bl.Active) { 'Yellow' } else { 'Green' }
    Write-Host ("  BitLocker     : {0}" -f $bl.Detail) -ForegroundColor $blColor

    $sec = Get-LenovoBiosSecurityInfo
    if ($sec.Available) {
        $secureRbKeySaved = $sec.SecureRollbackKeyName
        Write-Host ("  BIOS Setting  : FlashByEndUsers={0} | SecureRollBack={1} | WinUEFI={2} | SupervisorPW={3}" -f `
            $sec.FlashByEndUsers, $sec.SecureRollback, $sec.WindowsUefiUpdate, $sec.SupervisorPasswordSet) -ForegroundColor Gray

        if ($sec.FlashByEndUsers -match 'Disable') {
            Write-Host "[WARNING] 'Flash BIOS Updating by End-Users' is DISABLED in BIOS! Flashing will likely be blocked." -ForegroundColor Red
        }
        if ($sec.SupervisorPasswordSet -eq $true) {
            Write-Host "[WARNING] A BIOS Supervisor Password is set (may block flashing or prompt for password on reboot)." -ForegroundColor Yellow
        }
        if ($sec.SecureRollback -match 'Enable') {
            Write-Host "[INFO] SecureRollBackPrevention = Enable (normal on newer BIOS; blocks downgrade until temporarily disabled)." -ForegroundColor Yellow
        }
    }

    # 2. Load LSUClient module
    Write-Section "2. Loading LSUClient Module"
    if (-not (Import-BundledLSUClient -ManifestPath $ModuleManifest)) {
        Write-Host "[ERROR] LSUClient module was not found at $ModuleManifest" -ForegroundColor Red
        Pause-Exit 1
    }
    Write-Host "[OK] LSUClient loaded from: $ModuleManifest" -ForegroundColor Green

    # 3. Locate BIOS package
    $osOrder = Get-OsSearchOrder
    $sourceMode = ''
    $candidates = @()

    while ($true) {
        Write-Section "3. Searching BIOS Packages for Model $Model4"
        $diagLines = New-Object System.Collections.Generic.List[string]
        $diagLines.Add(("Timestamp={0} | Model4={1} | FullModel={2} | CurrentBios={3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Model4, $FullModel, $CurrentBios))
        $candidates = @()
        $sourceMode = ''

        if (-not $OfflineOnly) {
            foreach ($osTry in $osOrder) {
                try {
                    Write-Host ("[*] Querying Lenovo catalog (LSUClient, Win{0}) for model {1}..." -f $osTry, $Model4) -ForegroundColor Cyan
                    $lsuErr = @()
                    $allPkgs = @(Get-LSUpdate -Model $Model4 -All -NoTestApplicable -NoTestInstalled -NoTestSeverityOverride `
                        -MachineCharacteristicsOverride @{ '_OS' = $osTry } `
                        -ErrorAction SilentlyContinue -ErrorVariable lsuErr)
                    $diagLines.Add(("[LSUClient Win{0}] Total packages: {1}; non-terminating errors: {2}" -f $osTry, $allPkgs.Count, $lsuErr.Count))
                    foreach ($e in $lsuErr) {
                        $diagLines.Add(("  - LSU err: {0}" -f $e.Exception.Message))
                    }

                    $biosPkgs = @(Select-BiosPackages -Packages $allPkgs)
                    $diagLines.Add(("[LSUClient Win{0}] BIOS packages after filter: {1}" -f $osTry, $biosPkgs.Count))

                    if ($biosPkgs.Count -gt 0) {
                        $sourceMode = "ONLINE_LSU_WIN$osTry"
                        foreach ($p in $biosPkgs) {
                            $cachedDir = Join-Path $UsbCacheDir $p.ID
                            $isCached = (Test-Path -LiteralPath $cachedDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $cachedDir -File -ErrorAction SilentlyContinue).Count -gt 0)
                            $meta = Get-PackageXmlMeta -XmlUrl $p.URL -CacheFolder $(if ($isCached) { $cachedDir } else { '' })
                            $levels = @($meta.Levels)
                            $verDisplay = "$($p.Version)"
                            if (($verDisplay -eq '0.0.0.0') -and -not [string]::IsNullOrWhiteSpace($meta.RawVersion)) {
                                $verDisplay = $meta.RawVersion -replace '^v', ''
                            }
                            $rel = Get-BiosVersionRelation -CurrentBios $CurrentBios -DetectBiosLevels $levels -PkgVersion $verDisplay
                            $isInst = if ($rel -in @('SAME', 'NEWER_ON_LAPTOP')) { $true } elseif ($rel -eq 'OLDER_ON_LAPTOP') { $false } else { $null }
                            $candidates += [PSCustomObject]@{
                                Source           = 'ONLINE'
                                ID               = $p.ID
                                Version          = $verDisplay
                                ReleaseDate      = $p.ReleaseDate.ToString('yyyy-MM-dd')
                                IsInstalled      = $isInst
                                BiosRelation     = $rel
                                Title            = $p.Title
                                CachedOnUsb      = $isCached
                                PackageObj       = $p
                                DirectObj        = $null
                                ExtractCommand   = $p.Installer.ExtractCommand
                                InstallCommand   = $p.Installer.Command
                                XmlUrl           = $p.URL
                                CacheFolder      = $cachedDir
                                DetectBiosLevels = $levels
                            }
                        }
                        break
                    }
                } catch {
                    $diagLines.Add(("[LSUClient Win{0}] Exception: {1}" -f $osTry, $_.Exception.Message))
                    Write-Warning ("LSUClient Win{0} failed: {1}" -f $osTry, $_.Exception.Message)
                }
            }

            if ($candidates.Count -eq 0) {
                Write-Host "[*] LSUClient did not return a BIOS package. Trying direct Lenovo XML catalog..." -ForegroundColor Yellow
                $directPkgs = @(Get-BiosPackagesFromLenovoDirect -Model4 $Model4 -OsOrder $osOrder -Diagnostics $diagLines)
                if ($directPkgs.Count -gt 0) {
                    $sourceMode = "ONLINE_DIRECT"
                    foreach ($dp in $directPkgs) {
                        $cachedDir = Join-Path $UsbCacheDir $dp.ID
                        $isCached = (Test-Path -LiteralPath $cachedDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $cachedDir -File -ErrorAction SilentlyContinue).Count -gt 0)
                        $rel = Get-BiosVersionRelation -CurrentBios $CurrentBios -DetectBiosLevels $dp.DetectBiosLevels -PkgVersion $dp.Version
                        $isInst = if ($rel -in @('SAME', 'NEWER_ON_LAPTOP')) { $true } elseif ($rel -eq 'OLDER_ON_LAPTOP') { $false } else { $null }
                        $candidates += [PSCustomObject]@{
                            Source           = 'ONLINE_DIRECT'
                            ID               = $dp.ID
                            Version          = $dp.Version
                            ReleaseDate      = $dp.ReleaseDate
                            IsInstalled      = $isInst
                            BiosRelation     = $rel
                            Title            = $dp.Title
                            CachedOnUsb      = $isCached
                            PackageObj       = $null
                            DirectObj        = $dp
                            ExtractCommand   = $dp.ExtractCommand
                            InstallCommand   = $dp.InstallCommand
                            XmlUrl           = $dp.XmlUrl
                            CacheFolder      = $cachedDir
                            DetectBiosLevels = $dp.DetectBiosLevels
                        }
                    }
                }
            }
        }

        if ($candidates.Count -eq 0) {
            $indexMap = Read-ModelIndex -IndexPath $IndexPath
            if ($null -ne $indexMap -and $indexMap.ContainsKey($Model4)) {
                foreach ($entry in @($indexMap[$Model4])) {
                    $cDir = Join-Path $UsbCacheDir $entry.ID
                    if ((Test-Path -LiteralPath $cDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $cDir -File -ErrorAction SilentlyContinue).Count -gt 0)) {
                        $levels = @()
                        if ($entry.PSObject.Properties['DetectBiosLevels'] -and $entry.DetectBiosLevels) {
                            $levels = @($entry.DetectBiosLevels)
                        } else {
                            $levels = @(Get-BiosLevelsFromCacheFolder -Folder $cDir)
                        }
                        $rel = Get-BiosVersionRelation -CurrentBios $CurrentBios -DetectBiosLevels $levels -PkgVersion "$($entry.Version)"
                        $isInst = if ($rel -in @('SAME', 'NEWER_ON_LAPTOP')) { $true } elseif ($rel -eq 'OLDER_ON_LAPTOP') { $false } else { $null }
                        $candidates += [PSCustomObject]@{
                            Source           = 'OFFLINE_CACHE'
                            ID               = $entry.ID
                            Version          = "$($entry.Version)"
                            ReleaseDate      = "$($entry.ReleaseDate)"
                            IsInstalled      = $isInst
                            BiosRelation     = $rel
                            Title            = "$($entry.Title)"
                            CachedOnUsb      = $true
                            PackageObj       = $null
                            DirectObj        = $null
                            ExtractCommand   = "$($entry.ExtractCommand)"
                            InstallCommand   = "$($entry.InstallCommand)"
                            XmlUrl           = ''
                            CacheFolder      = $cDir
                            DetectBiosLevels = $levels
                        }
                    }
                }
                if ($candidates.Count -gt 0) { $sourceMode = 'OFFLINE_CACHE' }
            }
        }

        $manualDir = Join-Path (Join-Path $UsbCacheDir 'manual') $Model4
        if (($candidates.Count -eq 0) -and (Test-Path -LiteralPath $manualDir -PathType Container)) {
            $manualFiles = @(Get-ChildItem -LiteralPath $manualDir -File -ErrorAction SilentlyContinue)
            if ($manualFiles.Count -gt 0) {
                $sourceMode = 'MANUAL_USB'
                $candidates += [PSCustomObject]@{
                    Source           = 'MANUAL_USB'
                    ID               = "MANUAL_$Model4"
                    Version          = 'Manual package'
                    ReleaseDate      = '-'
                    IsInstalled      = $null
                    BiosRelation     = 'UNKNOWN'
                    Title            = "Manually placed files in cache\manual\$Model4"
                    CachedOnUsb      = $true
                    PackageObj       = $null
                    DirectObj        = $null
                    ExtractCommand   = ''
                    InstallCommand   = ''
                    XmlUrl           = ''
                    CacheFolder      = $manualDir
                    DetectBiosLevels = @()
                }
            }
        }

        if ($candidates.Count -gt 0) {
            break
        }

        $diagFile = Join-Path $UsbLogsDir ("diag_{0}_{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Model4)
        try {
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllLines($diagFile, $diagLines, $utf8Bom)
        } catch {}

        Write-Host "[ERROR] No BIOS package found for model '$Model4' (neither online nor in USB cache)." -ForegroundColor Red
        Write-Host "Diagnostics:" -ForegroundColor Yellow
        foreach ($dl in $diagLines) {
            Write-Host ("  {0}" -f $dl) -ForegroundColor Gray
        }
        Write-Host ("Diagnostics saved: {0}" -f $diagFile) -ForegroundColor Gray
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Yellow
        Write-Host "  - If the WMI model code is inaccurate, enter a different 4-character MTM prefix (e.g. 20S0)."
        Write-Host "  - Or download the official Lenovo BIOS .exe and place it into: $manualDir"
        $retryModel = (Read-Host "Enter 4 characters to retry or press ENTER to exit").Trim().ToUpper()
        if ([string]::IsNullOrWhiteSpace($retryModel)) {
            Pause-Exit 1
        }
        if ($retryModel.Length -gt 4) { $retryModel = $retryModel.Substring(0, 4) }
        $Model4 = $retryModel
    }

    Write-Host ""
    Write-Host ("Found BIOS packages (source: {0}):" -f $sourceMode) -ForegroundColor Green
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        $instTxt = if ($c.BiosRelation -eq 'SAME') { 'ALREADY INSTALLED (same version)' } elseif ($c.BiosRelation -eq 'NEWER_ON_LAPTOP') { 'LAPTOP HAS NEWER BIOS' } elseif ($c.BiosRelation -eq 'OLDER_ON_LAPTOP') { 'UPDATE AVAILABLE / NOT INSTALLED' } else { 'Unknown status' }
        $usbTxt = if ($c.CachedOnUsb) { 'On USB' } else { 'Online' }
        Write-Host ("  [{0}] ID: {1,-10} | Ver: {2,-12} | Date: {3,-10} | {4} | {5}" -f ($i + 1), $c.ID, $c.Version, $c.ReleaseDate, $instTxt, $usbTxt)
        Write-Host ("      {0}" -f $c.Title) -ForegroundColor Gray
    }

    $selectedIdx = 0
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        if ($candidates[$i].IsInstalled -eq $false) { $selectedIdx = $i; break }
    }

    if ($candidates.Count -gt 1) {
        $selInput = Read-Host ("Select package [1-{0}] (ENTER for #{1})" -f $candidates.Count, ($selectedIdx + 1))
        if (-not [string]::IsNullOrWhiteSpace($selInput)) {
            $parsed = 0
            if ([int]::TryParse($selInput, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $candidates.Count) {
                $selectedIdx = $parsed - 1
            }
        }
    }
    $selected = $candidates[$selectedIdx]
    $biosRelation = $selected.BiosRelation
    $isSameOrNewer = ($biosRelation -in @('SAME', 'NEWER_ON_LAPTOP'))

    # 4. Download into cache and extract to local WorkDir
    Write-Section "4. Preparing & Extracting Package $($selected.ID)"
    $WorkDir = Join-Path $WorkRoot $selected.ID
    if (Test-Path -LiteralPath $WorkDir -PathType Container) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $null = New-Item -Path $WorkDir -ItemType Directory -Force

    if ($selected.Source -eq 'ONLINE') {
        $pkgCacheDir = Join-Path $EffectiveCacheDir $selected.ID
        Write-Host "[*] Downloading / verifying BIOS package in cache ($pkgCacheDir)..." -ForegroundColor Cyan
        Save-LSUpdate -Package $selected.PackageObj -Path $EffectiveCacheDir -ShowProgress -ErrorAction Continue

        $downloadedExe = @(Get-ChildItem -LiteralPath $pkgCacheDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        if ($downloadedExe.Count -eq 0) {
            Write-Warning "Save-LSUpdate did not download an .exe file. Trying direct download..."
            $directFallback = @(Get-BiosPackagesFromLenovoDirect -Model4 $Model4 -OsOrder $osOrder) | Where-Object { $_.ID -eq $selected.ID } | Select-Object -First 1
            if ($directFallback) {
                $null = Save-DirectBiosPackage -PackageInfo $directFallback -CacheRoot $EffectiveCacheDir
            } else {
                Write-Host "[ERROR] Failed to download BIOS package $($selected.ID)." -ForegroundColor Red
                Pause-Exit 1
            }
        }

        if (-not $UsingFallbackCache) {
            Save-ModelIndexEntry -IndexPath $IndexPath -Model4 $Model4 -Entry @{
                ID               = $selected.ID
                Title            = $selected.Title
                Version          = $selected.Version
                ReleaseDate      = $selected.ReleaseDate
                ExtractCommand   = $selected.ExtractCommand
                InstallCommand   = $selected.InstallCommand
                DetectBiosLevels = @($selected.DetectBiosLevels)
                CachedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }

        Write-Host "[*] Copying package to fast local working folder ($WorkDir)..." -ForegroundColor Cyan
        Copy-Item -Path (Join-Path $pkgCacheDir '*') -Destination $WorkDir -Recurse -Force

        Write-Host "[*] Extracting BIOS package..." -ForegroundColor Cyan
        Expand-LSUpdate -Package $selected.PackageObj -Path $WorkRoot -ErrorAction Continue
        $null = Expand-CachedPackage -WorkDir $WorkDir -ExtractCommand $selected.ExtractCommand
    } elseif ($selected.Source -eq 'ONLINE_DIRECT') {
        try {
            $pkgCacheDir = Save-DirectBiosPackage -PackageInfo $selected.DirectObj -CacheRoot $EffectiveCacheDir
        } catch {
            Write-Host ("[ERROR] Download failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Pause-Exit 1
        }

        if (-not $UsingFallbackCache) {
            Save-ModelIndexEntry -IndexPath $IndexPath -Model4 $Model4 -Entry @{
                ID               = $selected.ID
                Title            = $selected.Title
                Version          = $selected.Version
                ReleaseDate      = $selected.ReleaseDate
                ExtractCommand   = $selected.ExtractCommand
                InstallCommand   = $selected.InstallCommand
                DetectBiosLevels = @($selected.DetectBiosLevels)
                CachedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }

        Write-Host "[*] Copying package to fast local working folder ($WorkDir)..." -ForegroundColor Cyan
        Copy-Item -Path (Join-Path $pkgCacheDir '*') -Destination $WorkDir -Recurse -Force
        $null = Expand-CachedPackage -WorkDir $WorkDir -ExtractCommand $selected.ExtractCommand
    } else {
        Write-Host "[*] Copying cached package from USB to local working folder ($WorkDir)..." -ForegroundColor Cyan
        Copy-Item -Path (Join-Path $selected.CacheFolder '*') -Destination $WorkDir -Recurse -Force
        $null = Expand-CachedPackage -WorkDir $WorkDir -ExtractCommand $selected.ExtractCommand
    }

    $removedLogos = @(Remove-LooseLogoFiles -Directory $WorkDir)
    if ($removedLogos.Count -gt 0) {
        Write-Host ("[INFO] Removed bundled logo files from extracted package: {0}" -f ($removedLogos -join ', ')) -ForegroundColor Yellow
    }

    $preArtifacts = Find-FlashArtifacts -WorkDir $WorkDir

    # 4b. If same/newer BIOS: fast silent flash (-s -bcp) or full cycle (downgrade + restore -> re-enable rollback)
    if ($isSameOrNewer -and ($null -ne $preArtifacts.Winuptp)) {
        $rollbackEnabled = ($sec.Available -and ($sec.SecureRollback -match 'Enable'))
        $prevPkg = $null
        if (($biosRelation -eq 'SAME') -and (-not $OfflineOnly) -and ($selected.Source -ne 'MANUAL_USB')) {
            Write-Host ""
            Write-Host "[*] Checking previous official BIOS version in Lenovo README table (for downgrade + restore option)..." -ForegroundColor Cyan
            $prevPkg = Get-PreviousBiosPackageFromReadme -LatestPkgId $selected.ID -LatestXmlUrl $selected.XmlUrl -CurrentBios $CurrentBios -CacheFolder $WorkDir
        }

        if (($null -ne $prevPkg) -or $rollbackEnabled) {
            Write-Host ""
            Write-Host "========================================================================" -ForegroundColor Yellow
            Write-Host " SAME OR NEWER BIOS DETECTED ($CurrentBios)" -ForegroundColor Yellow
            Write-Host "========================================================================" -ForegroundColor Yellow
            Write-Host ("  Target Package    : {0} (v{1}) in {2}" -f $selected.ID, $selected.Version, $WorkDir) -ForegroundColor Green
            if ($prevPkg) {
                Write-Host ("  Previous Version  : {0} (v{1}) available on Lenovo server" -f $prevPkg.ID, $prevPkg.Version) -ForegroundColor Cyan
            }
            Write-Host ("  SecureRollBack    : {0}" -f $(if ($sec.Available) { $sec.SecureRollback } else { 'Unknown' }))
            Write-Host ""

            if ($rollbackEnabled) {
                Write-Host ("  [1] FAST MODE (RECOMMENDED, ~2 min): Disable SecureRollBack + silent WINUPTP -s -bcp (v{0}) -> re-enable" -f $selected.Version) -ForegroundColor Green
            } else {
                $rbSuffix = if ($sec.Available) { ' -> re-enable SecureRollBack' } else { '' }
                Write-Host ("  [1] FAST MODE (RECOMMENDED, ~2 min): Silent WINUPTP -s -bcp (v{0}){1}" -f $selected.Version, $rbSuffix) -ForegroundColor Green
            }
            if ($prevPkg) {
                Write-Host ("  [2] FULL CYCLE (Downgrade + Restore, ~15-20 min): Keep v{0} + downgrade to v{1}" -f $selected.Version, $prevPkg.Version) -ForegroundColor Cyan
                Write-Host ("      -> AUTO restore to v{0} -> re-enable SecureRollBackPrevention (for models where same-version flash keeps logo)" -f $selected.Version) -ForegroundColor Cyan
            }
            Write-Host "  [0] Skip automation and open manual launch menu"
            Write-Host ""
            $cycleChoice = Read-Host "Select option [1]"
            if ([string]::IsNullOrWhiteSpace($cycleChoice)) { $cycleChoice = '1' }

            if ($cycleChoice -eq '1') {
                if ($rollbackEnabled) {
                    Start-DisableRollbackRebootFlow -StateData @{
                        Phase                 = 'SAMEVER_FLASH'
                        CreatedAt             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        Model4                = $Model4
                        FullModel             = $FullModel
                        ProductName           = $ProductName
                        Serial                = $Serial
                        CurrentBios           = $CurrentBios
                        PackageID             = $selected.ID
                        PackageVersion        = $selected.Version
                        PackageTitle          = $selected.Title
                        WorkDir               = $WorkDir
                        InstallCommand        = $selected.InstallCommand
                        SourceMode            = $selected.Source
                        BiosRelation          = $biosRelation
                        ReEnableRollbackAtEnd = $true
                        SecureRollbackKeyName = $sec.SecureRollbackKeyName
                        OriginalUsbRoot       = $ToolRoot
                    } -SecureRollbackKeyName $sec.SecureRollbackKeyName `
                      -ReadyMessage '' `
                      -ResumeActionHint 'As soon as Windows boots after F10, the tool will AUTO-RESUME silent WINUPTP -s -bcp -> re-enable RollBack!' `
                      -ScriptSelfPath $ScriptSelfPath -ResumeRoot $ResumeRoot -ResumeStatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -ResumeTaskName $ResumeTaskName
                } else {
                    $reEnableRollbackOnSameVer = $sec.Available
                    $autoRunFastSameVer = $true
                }
            } elseif (($cycleChoice -eq '2') -and ($null -ne $prevPkg)) {
                Write-Section ("4b. Downloading & Extracting Previous BIOS Package {0} (v{1})" -f $prevPkg.ID, $prevPkg.Version)
                try {
                    $prevCacheDir = Save-DirectBiosPackage -PackageInfo $prevPkg -CacheRoot $EffectiveCacheDir
                    if (-not $UsingFallbackCache) {
                        Save-ModelIndexEntry -IndexPath $IndexPath -Model4 $Model4 -Entry @{
                            ID               = $prevPkg.ID
                            Title            = $prevPkg.Title
                            Version          = $prevPkg.Version
                            ReleaseDate      = $prevPkg.ReleaseDate
                            ExtractCommand   = $prevPkg.ExtractCommand
                            InstallCommand   = $prevPkg.InstallCommand
                            DetectBiosLevels = @($prevPkg.DetectBiosLevels)
                            CachedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        }
                    }

                    $DowngradeWorkDir = Join-Path $WorkRoot $prevPkg.ID
                    if (Test-Path -LiteralPath $DowngradeWorkDir -PathType Container) {
                        Remove-Item -LiteralPath $DowngradeWorkDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    $null = New-Item -Path $DowngradeWorkDir -ItemType Directory -Force
                    Copy-Item -Path (Join-Path $prevCacheDir '*') -Destination $DowngradeWorkDir -Recurse -Force
                    $null = Expand-CachedPackage -WorkDir $DowngradeWorkDir -ExtractCommand $prevPkg.ExtractCommand
                    $null = Remove-LooseLogoFiles -Directory $DowngradeWorkDir
                    $dgCheck = Find-FlashArtifacts -WorkDir $DowngradeWorkDir

                    if (-not $dgCheck.Winuptp) {
                        throw "Extracted previous package ($($prevPkg.ID)) does not contain winuptp.exe."
                    }

                    if ($rollbackEnabled) {
                        Start-DisableRollbackRebootFlow -StateData @{
                            Phase                   = 'DOWNGRADE'
                            CreatedAt               = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                            Model4                  = $Model4
                            FullModel               = $FullModel
                            ProductName             = $ProductName
                            Serial                  = $Serial
                            CurrentBios             = $CurrentBios
                            DowngradeWorkDir        = $DowngradeWorkDir
                            DowngradePackageID      = $prevPkg.ID
                            DowngradePackageVersion = $prevPkg.Version
                            LatestWorkDir           = $WorkDir
                            LatestPackageID         = $selected.ID
                            LatestPackageVersion    = $selected.Version
                            ReEnableRollbackAtEnd   = $true
                            SecureRollbackKeyName   = $sec.SecureRollbackKeyName
                            OriginalUsbRoot         = $ToolRoot
                        } -SecureRollbackKeyName $sec.SecureRollbackKeyName `
                          -ReadyMessage 'both BIOS packages are ready in C:\Temp!' `
                          -ResumeActionHint 'As soon as Windows boots after F10, the tool will AUTO-RESUME downgrade -> restore -> re-enable RollBack!' `
                          -ScriptSelfPath $ScriptSelfPath -ResumeRoot $ResumeRoot -ResumeStatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -ResumeTaskName $ResumeTaskName
                    } else {
                        Invoke-DowngradePhase `
                            -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName -Serial $Serial -CurrentBios $CurrentBios `
                            -DowngradeWorkDir $DowngradeWorkDir -DowngradePackageID $prevPkg.ID -DowngradePackageVersion $prevPkg.Version `
                            -LatestWorkDir $WorkDir -LatestPackageID $selected.ID -LatestPackageVersion $selected.Version `
                            -ReEnableRollbackAtEnd $true -SecureRollbackKeyName $sec.SecureRollbackKeyName `
                            -ToolRoot $ToolRoot -UsbLogsDir $UsbLogsDir -BitLockerState $bl -SecurityInfo $sec -SkipPower:$SkipPowerCheck `
                            -ScriptSelfPath $ScriptSelfPath -ResumeRoot $ResumeRoot -ResumeStatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -ResumeTaskName $ResumeTaskName
                        Pause-Exit 0
                    }
                } catch {
                    Write-Warning ("Preparation of previous BIOS package failed: {0}" -f $_.Exception.Message)
                }
            }
        }
    }
}

# Remove any bundled custom LOGO files before Step 5
$removedLogos = @(Remove-LooseLogoFiles -Directory $WorkDir)
if ($removedLogos.Count -gt 0) {
    Write-Host ("[INFO] Removed bundled logo files from extracted package: {0}" -f ($removedLogos -join ', ')) -ForegroundColor Yellow
}

$artifacts = Find-FlashArtifacts -WorkDir $WorkDir
$isSameVersion = $isSameOrNewer
$bitlockerSuspended = $false
$execExitCode = $null
$execModeLabel = 'CANCELLED'
$summaryText = 'Cancelled by user'
$logDirToRead = $WorkDir
$pendingStamp = ''
$armedFinalReEnable = $false

$flashExeToRun = ''
$flashDirToRun = ''
$flashArgsToRun = ''
$openManualFolder = $false
$manualFolderTarget = $WorkDir

# 5. Launch menu
Write-Section "5. Select BIOS Flash Launch Mode"

if ($artifacts.Winuptp) {
    $flashExe = $artifacts.Winuptp.FullName
    $flashDir = $artifacts.Winuptp.DirectoryName
    $logDirToRead = $flashDir
    $manualFolderTarget = $flashDir
    Write-Host ("  Detected tool: {0}" -f $flashExe) -ForegroundColor Green

    if ($isSameOrNewer) {
        $hasWinflashBcp = ($null -ne $artifacts.Winflash -and $null -ne $artifacts.BcpEvs)
        if ($autoRunFastSameVer) {
            Write-Host ("[*] Launching fast silent WINUPTP (-s -bcp) for v{0}..." -f $selected.Version) -ForegroundColor Cyan
            $choice = '1'
        } else {
            Write-Host ""
            if ($resumedMode -and $sec.Available -and ($sec.SecureRollback -match 'Disable')) {
                Write-Host "  [READY] SecureRollBackPrevention is DISABLED! You can run WINUPTP right away." -ForegroundColor Green
            } else {
                Write-Host "  [WARNING] This laptop ALREADY has the same or newer BIOS version ($CurrentBios)!" -ForegroundColor Yellow
                Write-Host "  Standard WINUPTP may reject flashing while SecureRollBackPrevention is enabled." -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "  [1] Silent WINUPTP -s -bcp (RECOMMENDED - removes custom logo automatically)" -ForegroundColor Green
            Write-Host "  [2] Interactive WINUPTP (click NO when asked about custom startup image)"
            if ($hasWinflashBcp) {
                Write-Host ("  [3] Advanced: {0} -patch -bcp {1}" -f $artifacts.Winflash.Name, $artifacts.BcpEvs.Name) -ForegroundColor Magenta
                Write-Host "  [4] Open extracted folder (Explorer + CMD) for manual flashing / downgrade"
            } else {
                Write-Host "  [3] Open extracted folder (Explorer + CMD) for manual flashing / downgrade"
            }
            Write-Host "  [0] Cancel"
            Write-Host ""

            $choice = Read-Host "Select option [1]"
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
        }

        switch ($choice) {
            '1' {
                $execModeLabel = 'WINUPTP_SILENT_BCP'
                $flashExeToRun = $flashExe
                $flashDirToRun = $flashDir
                $flashArgsToRun = '-s -bcp'
            }
            '2' {
                $execModeLabel = 'WINUPTP_INTERACTIVE_SAMEVER'
                Write-Host ""
                Write-Host ">>> IMPORTANT: When prompted for 'custom start up image file', click NO! <<<" -ForegroundColor Black -BackgroundColor Yellow
                $flashExeToRun = $flashExe
                $flashDirToRun = $flashDir
                $flashArgsToRun = ''
            }
            '3' {
                if ($hasWinflashBcp) {
                    Write-Host ""
                    Write-Host "Detected BCP patch files:" -ForegroundColor Magenta
                    Write-Host ("  WinFlash : {0}" -f $artifacts.Winflash.FullName)
                    Write-Host ("  bcp.evs  : {0}" -f $artifacts.BcpEvs.FullName)
                    $confirm = Read-Host "Are you sure you want to run WinFlash -patch -bcp? (Type YES to confirm)"
                    if ($confirm -ceq 'YES') {
                        $execModeLabel = 'WINFLASH_PATCH_BCP'
                        $flashExeToRun = $artifacts.Winflash.FullName
                        $flashDirToRun = $artifacts.Winflash.DirectoryName
                        $flashArgsToRun = ("-patch -bcp `"{0}`"" -f $artifacts.BcpEvs.Name)
                    } else {
                        Write-Host "Cancelled." -ForegroundColor Gray
                    }
                } else {
                    $execModeLabel = 'MANUAL_FOLDER'
                    $openManualFolder = $true
                }
            }
            '4' {
                if ($hasWinflashBcp) {
                    $execModeLabel = 'MANUAL_FOLDER'
                    $openManualFolder = $true
                } else {
                    Write-Host "Cancelled." -ForegroundColor Gray
                }
            }
            default {
                Write-Host "Cancelled." -ForegroundColor Gray
            }
        }
    } else {
        Write-Host ""
        Write-Host "  [1] Silent WINUPTP -s -bcp (RECOMMENDED - updates BIOS and restores stock logo automatically)" -ForegroundColor Green
        Write-Host "  [2] Interactive WINUPTP (click NO when asked to keep custom logo)"
        Write-Host "  [3] Open extracted folder (Explorer + CMD) for manual operation"
        Write-Host "  [0] Cancel"
        Write-Host ""
        $choice = Read-Host "Select option [1]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

        switch ($choice) {
            '1' {
                $execModeLabel = 'WINUPTP_SILENT_BCP'
                $flashExeToRun = $flashExe
                $flashDirToRun = $flashDir
                $flashArgsToRun = '-s -bcp'
            }
            '2' {
                $execModeLabel = 'WINUPTP_INTERACTIVE'
                Write-Host ""
                Write-Host ">>> IMPORTANT: In the next window, click NO when asked about keeping the custom logo! <<<" -ForegroundColor Black -BackgroundColor Yellow
                $flashExeToRun = $flashExe
                $flashDirToRun = $flashDir
                $flashArgsToRun = ''
            }
            '3' {
                $execModeLabel = 'MANUAL_FOLDER'
                $openManualFolder = $true
            }
            default {
                Write-Host "Cancelled." -ForegroundColor Gray
            }
        }
    }
} else {
    Write-Host "[WARNING] winuptp.exe / winuptp64.exe was not found in the extracted package." -ForegroundColor Yellow
    if ($selected.InstallCommand) {
        Write-Host ("  Original Lenovo install command: {0}" -f $selected.InstallCommand) -ForegroundColor Gray
    }
    if ($artifacts.Others.Count -gt 0) {
        Write-Host "  Other flash tools found:" -ForegroundColor Cyan
        foreach ($o in $artifacts.Others) {
            Write-Host ("    - {0}" -f $o.FullName)
        }
    }
    Write-Host ""
    if ($artifacts.Others.Count -gt 0) {
        Write-Host "  [1] Launch detected tool interactively ($($artifacts.Others[0].Name))"
        Write-Host "  [2] Open extracted folder (Explorer + CMD)"
        Write-Host "  [0] Cancel"
        $c2 = Read-Host "Select option"
        if ($c2 -eq '1') {
            $other = $artifacts.Others[0]
            $execModeLabel = "OTHER_$($other.Name)"
            $flashExeToRun = $other.FullName
            $flashDirToRun = $other.DirectoryName
            $flashArgsToRun = ''
        } elseif ($c2 -eq '2') {
            $execModeLabel = 'MANUAL_FOLDER'
            $openManualFolder = $true
        }
    } else {
        Write-Host "  [1] Open extracted folder (Explorer + CMD)"
        Write-Host "  [0] Cancel"
        $c2 = Read-Host "Select option"
        if ($c2 -eq '1') {
            $execModeLabel = 'MANUAL_FOLDER'
            $openManualFolder = $true
        }
    }
}

if ($openManualFolder) {
    Start-Process explorer.exe -ArgumentList $manualFolderTarget
    Start-Process cmd.exe -ArgumentList "/k cd /d `"$manualFolderTarget`""
    $summaryText = 'Opened folder for manual operation'
} elseif (-not [string]::IsNullOrWhiteSpace($flashExeToRun)) {
    $logDirToRead = $flashDirToRun
    $rollbackIsDisabledNow = ($isSameOrNewer -and $sec.Available -and ($sec.SecureRollback -match 'Disable'))
    if ($reEnableRollbackOnSameVer -or $rollbackIsDisabledNow) {
        $reEnableRollbackOnSameVer = $true
        $null = Register-ResumeAfterReboot -StateData @{
            Phase                 = 'REENABLE_ROLLBACK'
            CreatedAt             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Model4                = $Model4
            FullModel             = $FullModel
            ProductName           = $ProductName
            Serial                = $Serial
            PackageID             = $selected.ID
            PackageVersion        = $selected.Version
            SecureRollbackKeyName = $secureRbKeySaved
            OriginalUsbRoot       = $ToolRoot
        } -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName
        $armedFinalReEnable = $true
    }

    $trackRes = Invoke-TrackedFlash `
        -UsbLogsDir $UsbLogsDir -Serial $Serial -Model4 $Model4 -FullModel $FullModel -ProductName $ProductName `
        -CurrentBios $CurrentBios -PackageID $selected.ID -PackageVersion $selected.Version -WasSameVersion:$isSameVersion `
        -ModeLabel $execModeLabel -ExePath $flashExeToRun -WorkingDir $flashDirToRun -Arguments $flashArgsToRun -BitLockerActive $bl.Active
    $pendingStamp       = $trackRes.PendingStamp
    $bitlockerSuspended = $trackRes.BitLockerSuspended
    $execExitCode       = $trackRes.ExitCode
}

# 6. Result analysis & log write
$logCheck = $null
if ($null -ne $execExitCode) {
    $logCheck = Get-WinuptpLogAnalysis -FlasherDir $logDirToRead -ExitCode $execExitCode
    Write-Section "6. Execution Result"
    if ($logCheck.EffectiveSuccess) {
        switch ($execExitCode) {
            0 {
                $summaryText = 'Success - system rebooting'
                Write-Host "[OK] ExitCode 0: BIOS update prepared / system is restarting." -ForegroundColor Green
            }
            1 {
                $summaryText = 'Success - manual reboot required'
                Write-Host "[OK] ExitCode 1: BIOS update is staged. REBOOT REQUIRED to apply!" -ForegroundColor Green
            }
        }
    } else {
        if ($armedFinalReEnable) {
            Clear-ResumeRegistration -TaskName $ResumeTaskName -StatePath $ResumeStatePath
        }
        $summaryText = $logCheck.SummaryOverride
        Write-Host ("[ERROR] BIOS flash was NOT applied: {0}" -f $summaryText) -ForegroundColor Red
        foreach ($el in @($logCheck.ErrorLines)) {
            Write-Host ("  {0}" -f $el) -ForegroundColor Red
        }
        if ($execExitCode -eq -999) {
            Write-Host '[TIP] This model may not support silent "-s -bcp" mode - re-run the tool and choose Interactive WINUPTP or Full Cycle (downgrade).' -ForegroundColor Yellow
        }
    }
}

Write-ExecutionLog -UsbLogsDir $UsbLogsDir -FlasherDir $logDirToRead -PendingStamp $pendingStamp -Record @{
    Serial             = $Serial
    Model4             = $Model4
    FullModel          = $FullModel
    ProductName        = $ProductName
    CurrentBios        = $CurrentBios
    PackageID          = $selected.ID
    PackageVersion     = $selected.Version
    WasSameVersion     = $isSameVersion
    Mode               = $execModeLabel
    ExitCode           = $(if ($null -ne $execExitCode) { $execExitCode } else { '' })
    BitLockerSuspended = $bitlockerSuspended
    Summary            = $summaryText
}

if ($null -ne $logCheck -and (-not $logCheck.EffectiveSuccess) -and $logCheck.SecureRollbackBlocked) {
    Write-Host ""
    Write-Host "[TIP] WINUPTP rejected the flash because SecureRollBackPrevention is enabled in BIOS." -ForegroundColor Yellow
    Write-Host "  [1] Reboot into BIOS Setup now (shutdown /r /fw /t 0) with auto-resume -> disable SecureRollBack -> F10" -ForegroundColor Cyan
    Write-Host "  [0] Exit"
    $sbFix = Read-Host "Select option [1]"
    if ([string]::IsNullOrWhiteSpace($sbFix)) { $sbFix = '1' }
    if ($sbFix -eq '1') {
        $null = Register-ResumeAfterReboot -StateData @{
            Phase                 = 'SAMEVER_FLASH'
            CreatedAt             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Model4                = $Model4
            FullModel             = $FullModel
            ProductName           = $ProductName
            Serial                = $Serial
            CurrentBios           = $CurrentBios
            PackageID             = $selected.ID
            PackageVersion        = $selected.Version
            PackageTitle          = $selected.Title
            WorkDir               = $WorkDir
            InstallCommand        = $selected.InstallCommand
            SourceMode            = $selected.Source
            BiosRelation          = $biosRelation
            ReEnableRollbackAtEnd = $true
            SecureRollbackKeyName = $secureRbKeySaved
            OriginalUsbRoot       = $ToolRoot
        } -SourceScriptPath $ScriptSelfPath -ResumeRoot $ResumeRoot -StatePath $ResumeStatePath -ResumeScriptPath $ResumeScriptPath -TaskName $ResumeTaskName
        Invoke-BiosSetupOrReboot
    }
} elseif ($null -ne $logCheck -and $logCheck.EffectiveSuccess) {
    if ($reEnableRollbackOnSameVer -and ($execExitCode -in @(0, 1))) {
        Write-Host ""
        Write-Host "After this reboot, the tool will launch once more to automatically re-enable SecureRollBackPrevention!" -ForegroundColor Green
    }

    if ($execExitCode -eq 1) {
        Write-Host ""
        Write-Host "Do NOT power off the laptop during reboot while the BIOS flash screen is active!" -ForegroundColor Black -BackgroundColor Yellow
        $rb = Read-Host "Reboot now? (Y/N)"
        if ($rb -match '^(Y|y)$') {
            Restart-Computer -Force
        }
    }
}

Pause-Exit 0
