param(
    [Parameter(Mandatory = $true)]
    [string]$SourceIso,

    [Parameter(Mandatory = $true)]
    [string]$WorkDir,

    [int]$ImageIndex = 1,

    [Parameter(Mandatory = $true)]
    [string]$AppManifest,

    [string[]]$RemoveFilePatterns = @("Edge.wim", "*Edge*.wim"),

    [Parameter(Mandatory = $true)]
    [string]$OutputIso,

    [string]$OscdimgPath = "oscdimg.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Assert-PathExists {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Name does not exist: $Path"
    }
}

function Invoke-External {
    param([string]$FilePath, [string[]]$Arguments)
    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Copy-IsoContent {
    param([string]$IsoPath, [string]$Destination)

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $disk = Mount-DiskImage -ImagePath $IsoPath -PassThru
    try {
        $volume = $disk | Get-Volume | Select-Object -First 1
        if (-not $volume.DriveLetter) {
            throw "Mounted ISO has no drive letter."
        }
        $sourceRoot = "$($volume.DriveLetter):\"
        robocopy $sourceRoot $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 | Out-Host
        if ($LASTEXITCODE -gt 7) {
            throw "robocopy failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
}

function Convert-EsdToWimIfNeeded {
    param([string]$SourcesDir)

    $wimPath = Join-Path $SourcesDir "install.wim"
    $esdPath = Join-Path $SourcesDir "install.esd"
    if (Test-Path -LiteralPath $wimPath) {
        return $wimPath
    }
    if (-not (Test-Path -LiteralPath $esdPath)) {
        throw "Neither install.wim nor install.esd was found in $SourcesDir"
    }

    Invoke-External dism.exe @(
        "/Export-Image",
        "/SourceImageFile:$esdPath",
        "/SourceIndex:$ImageIndex",
        "/DestinationImageFile:$wimPath",
        "/Compress:max",
        "/CheckIntegrity"
    )
    Remove-Item -LiteralPath $esdPath -Force
    return $wimPath
}

function Add-SetupCompleteInstallers {
    param(
        [string]$MountDir,
        [object[]]$Apps
    )

    $setupScriptsDir = Join-Path $MountDir "Windows\Setup\Scripts"
    $payloadDir = Join-Path $MountDir "InstallPayload\Apps"
    New-Item -ItemType Directory -Force -Path $setupScriptsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null

    $commands = @(
        "@echo off",
        "setlocal EnableExtensions",
        "set LOG=%SystemRoot%\Temp\offline-app-install.log",
        "echo SetupComplete started %DATE% %TIME% > %LOG%"
    )

    foreach ($app in $Apps) {
        $source = [string]$app.Path
        Assert-PathExists $source "Installer"
        $fileName = Split-Path $source -Leaf
        $dest = Join-Path $payloadDir $fileName
        Copy-Item -LiteralPath $source -Destination $dest -Force

        $args = if ($app.Args) { [string]$app.Args } else { "" }
        $target = "%SystemDrive%\InstallPayload\Apps\$fileName"
        if ($app.Type -eq "Msi") {
            $commands += "echo Installing $fileName >> %LOG%"
            $commands += "msiexec /i `"$target`" $args /qn /norestart >> %LOG% 2>&1"
        }
        elseif ($app.Type -eq "Exe") {
            $commands += "echo Installing $fileName >> %LOG%"
            $commands += "`"$target`" $args >> %LOG% 2>&1"
        }
        else {
            throw "Unsupported SetupComplete app type: $($app.Type)"
        }
    }

    $commands += "echo SetupComplete finished %DATE% %TIME% >> %LOG%"
    $commands += "exit /b 0"
    Set-Content -LiteralPath (Join-Path $setupScriptsDir "SetupComplete.cmd") -Value $commands -Encoding ASCII
}

function Add-OfflineApps {
    param([string]$MountDir, [string]$ManifestPath)

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $setupCompleteApps = @()

    foreach ($app in $manifest.Apps) {
        $type = [string]$app.Type
        $path = [string]$app.Path
        Assert-PathExists $path "Application payload"

        switch ($type) {
            "Cab" {
                Add-WindowsPackage -Path $MountDir -PackagePath $path -NoRestart | Out-Host
            }
            "Msu" {
                Add-WindowsPackage -Path $MountDir -PackagePath $path -NoRestart | Out-Host
            }
            "Appx" {
                $deps = @()
                if ($app.DependencyPath) { $deps = @($app.DependencyPath) }
                Add-AppxProvisionedPackage -Path $MountDir -PackagePath $path -DependencyPackagePath $deps -SkipLicense | Out-Host
            }
            "AppxBundle" {
                $deps = @()
                if ($app.DependencyPath) { $deps = @($app.DependencyPath) }
                Add-AppxProvisionedPackage -Path $MountDir -PackagePath $path -DependencyPackagePath $deps -SkipLicense | Out-Host
            }
            "Msi" {
                $setupCompleteApps += $app
            }
            "Exe" {
                $setupCompleteApps += $app
            }
            "Copy" {
                $dest = Join-Path $MountDir ([string]$app.Destination).TrimStart("\")
                New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
                Copy-Item -LiteralPath $path -Destination $dest -Recurse -Force
            }
            default {
                throw "Unsupported app type: $type"
            }
        }
    }

    if ($setupCompleteApps.Count -gt 0) {
        Add-SetupCompleteInstallers -MountDir $MountDir -Apps $setupCompleteApps
    }
}

function Remove-ImageFiles {
    param([string]$IsoRoot, [string]$MountDir, [string[]]$Patterns)

    foreach ($pattern in $Patterns) {
        Get-ChildItem -LiteralPath $IsoRoot -Recurse -Force -File -Filter $pattern -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "Removing ISO file: $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Force
            }

        Get-ChildItem -LiteralPath $MountDir -Recurse -Force -File -Filter $pattern -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "Removing mounted image file: $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Force
            }
    }
}

function Build-Iso {
    param([string]$IsoRoot, [string]$DestinationIso, [string]$ToolPath)

    $bootData = @()
    $etfsboot = Join-Path $IsoRoot "boot\etfsboot.com"
    $efisys = Join-Path $IsoRoot "efi\microsoft\boot\efisys.bin"
    Assert-PathExists $etfsboot "BIOS boot image"
    Assert-PathExists $efisys "UEFI boot image"

    $bootData += "2#p0,e,b$etfsboot#pEF,e,b$efisys"
    Invoke-External $ToolPath @(
        "-m",
        "-o",
        "-u2",
        "-udfver102",
        "-bootdata:$($bootData[0])",
        $IsoRoot,
        $DestinationIso
    )
}

Assert-Admin
Assert-PathExists $SourceIso "Source ISO"
Assert-PathExists $AppManifest "App manifest"

$isoRoot = Join-Path $WorkDir "iso"
$mountDir = Join-Path $WorkDir "mount"
$exportedWim = Join-Path $WorkDir "install.exported.wim"

if (Test-Path -LiteralPath $WorkDir) {
    throw "WorkDir already exists. Use an empty new directory: $WorkDir"
}

New-Item -ItemType Directory -Force -Path $isoRoot, $mountDir | Out-Null
Copy-IsoContent -IsoPath $SourceIso -Destination $isoRoot

$sourcesDir = Join-Path $isoRoot "sources"
$installWim = Convert-EsdToWimIfNeeded -SourcesDir $sourcesDir

try {
    Mount-WindowsImage -ImagePath $installWim -Index $ImageIndex -Path $mountDir | Out-Host
    Add-OfflineApps -MountDir $mountDir -ManifestPath $AppManifest
    Remove-ImageFiles -IsoRoot $isoRoot -MountDir $mountDir -Patterns $RemoveFilePatterns
    Dismount-WindowsImage -Path $mountDir -Save | Out-Host
}
catch {
    Write-Warning "Servicing failed. Discarding mounted image changes."
    Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    throw
}

Invoke-External dism.exe @(
    "/Export-Image",
    "/SourceImageFile:$installWim",
    "/SourceIndex:$ImageIndex",
    "/DestinationImageFile:$exportedWim",
    "/Compress:max",
    "/CheckIntegrity"
)
Move-Item -LiteralPath $exportedWim -Destination $installWim -Force

Build-Iso -IsoRoot $isoRoot -DestinationIso $OutputIso -ToolPath $OscdimgPath
Write-Host "Done: $OutputIso"