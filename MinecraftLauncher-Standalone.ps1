# Minecraft Portable Launcher - With Image Background Support
# Seamless transition between GUI and loading screen

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Get script/exe directory FIRST
$scriptDir = $null

# Try multiple methods to get the directory
try {
    # Method 1: PSScriptRoot (works for scripts)
    if ($PSScriptRoot) {
        $scriptDir = $PSScriptRoot
    }
    # Method 2: MyInvocation (works for scripts)
    elseif ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    # Method 3: Assembly location (works for EXE)
    elseif ([System.Reflection.Assembly]::GetExecutingAssembly().Location) {
        $scriptDir = [System.IO.Path]::GetDirectoryName([System.Reflection.Assembly]::GetExecutingAssembly().Location)
    }
    # Method 4: Current process (works for EXE)
    elseif ($Host.UI.RawUI) {
        $scriptDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
    # Method 5: Fallback to current directory
    else {
        $scriptDir = Get-Location | Select-Object -ExpandProperty Path
    }
}
catch {
    # Final fallback
    $scriptDir = [System.Environment]::CurrentDirectory
}

# Ensure we have a valid directory
if ([string]::IsNullOrEmpty($scriptDir) -or -not (Test-Path $scriptDir)) {
    $scriptDir = [System.Environment]::CurrentDirectory
}

Set-Location $scriptDir

# Server config file path
$serverConfigPath = Join-Path $scriptDir "server_config.json"

function Load-ServerConfig {
    if (Test-Path $serverConfigPath) {
        try {
            $config = Get-Content -Path $serverConfigPath -Raw | ConvertFrom-Json
            return $config
        } catch {
            Write-Host "Failed to load server config: $_"
            return $null
        }
    }
    return $null
}

function Save-ServerConfig {
    param(
        [string]$Version,
        [string]$ServerType,
        [int]$Memory
    )
    
    $config = @{
        LastVersion = $Version
        LastServerType = $ServerType
        LastMemory = $Memory
        LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    
    try {
        $config | ConvertTo-Json | Set-Content -Path $serverConfigPath
        Write-Host "Server config saved: $Version, $ServerType, ${Memory}GB"
    } catch {
        Write-Host "Failed to save server config: $_"
    }
}

# Error logging (now that we have scriptDir)
$ErrorActionPreference = "Continue"
$errorLogFile = Join-Path $scriptDir "launcher_errors.txt"

try {

#region UUID Management
function Get-ComputerUUID {
    $uuidFile = Join-Path $scriptDir "computer_uuid.dat"
    
    if (Test-Path $uuidFile) {
        $uuid = Get-Content $uuidFile -Raw
        return $uuid.Trim()
    }
    
    $computerName = $env:COMPUTERNAME
    $tempFile = Join-Path $scriptDir "temp_uuid.txt"
    $hashFile = Join-Path $scriptDir "temp_hash.txt"
    
    try {
        $computerName | Out-File -FilePath $tempFile -Encoding ASCII -NoNewline
        $null = certutil -hashfile $tempFile MD5 > $hashFile 2>&1
        
        $hashContent = Get-Content $hashFile
        if ($hashContent.Count -gt 1) {
            $hash = $hashContent[1].Trim()
            $uuid = "$($hash.Substring(0,8))-$($hash.Substring(8,4))-$($hash.Substring(12,4))-$($hash.Substring(16,4))-$($hash.Substring(20,12))"
        } else {
            $uuid = [guid]::NewGuid().ToString()
        }
        
        $uuid | Out-File -FilePath $uuidFile -Encoding ASCII -NoNewline
        
        Remove-Item $tempFile -ErrorAction SilentlyContinue
        Remove-Item $hashFile -ErrorAction SilentlyContinue
        
        return $uuid
    }
    catch {
        $uuid = [guid]::NewGuid().ToString()
        $uuid | Out-File -FilePath $uuidFile -Encoding ASCII -NoNewline
        return $uuid
    }
}

function Reset-ComputerUUID {
    $uuidFile = Join-Path $scriptDir "computer_uuid.dat"
    if (Test-Path $uuidFile) {
        Remove-Item $uuidFile
    }
}
#endregion

#region Skin Management
function Get-SkinPath {
    param([string]$Version)
    
    # OfflineSkins mod looks for skins in: versions/[version]/config/offlineskins/
    if ($Version) {
        $versionDir = Join-Path $scriptDir "versions\$Version"
        $offlineSkinsDir = Join-Path $versionDir "config\offlineskins"
    } else {
        # Fallback to general skins folder
        $offlineSkinsDir = Join-Path $scriptDir "skins"
    }
    
    if (-not (Test-Path $offlineSkinsDir)) {
        New-Item -Path $offlineSkinsDir -ItemType Directory -Force | Out-Null
    }
    
    return $offlineSkinsDir
}

function Get-CurrentSkin {
    param([string]$Username, [string]$Version)
    
    $skinsDir = Get-SkinPath -Version $Version
    $currentSkinFile = Join-Path $skinsDir "$Username.png"
    
    if (Test-Path $currentSkinFile) {
        return $currentSkinFile
    }
    
    return $null
}

function Set-MinecraftSkin {
    param(
        [string]$SkinFilePath,
        [string]$Username,
        [string]$Version
    )
    
    if (-not (Test-Path $SkinFilePath)) {
        throw "Skin file not found: $SkinFilePath"
    }
    
    # Validate it's a PNG
    $extension = [System.IO.Path]::GetExtension($SkinFilePath)
    if ($extension -ne ".png") {
        throw "Skin file must be a PNG image"
    }
    
    # Save to OfflineSkins mod location: versions/[version]/config/offlineskins/[username].png
    $skinsDir = Get-SkinPath -Version $Version
    $userSkinFile = Join-Path $skinsDir "$Username.png"
    
    # If file exists and is locked, try to copy anyway with force and retry
    $maxRetries = 3
    $retryCount = 0
    $copied = $false
    
    while (-not $copied -and $retryCount -lt $maxRetries) {
        try {
            # Force copy even if file exists
            Copy-Item -Path $SkinFilePath -Destination $userSkinFile -Force -ErrorAction Stop
            $copied = $true
        }
        catch {
            $retryCount++
            if ($retryCount -lt $maxRetries) {
                Start-Sleep -Milliseconds 200
            }
            else {
                throw "Failed to save skin after $maxRetries attempts: $($_.Exception.Message)"
            }
        }
    }
    
    # Update config.json to tell OfflineSkins mod which skin to use
    $configFile = Join-Path $skinsDir "config.json"
    $config = @{
        selectedSkinName = $Username
        defaultModel = "steve"
    }
    
    # Convert to JSON and save
    $configJson = $config | ConvertTo-Json
    $configJson | Out-File -FilePath $configFile -Encoding UTF8 -Force
    
    return $userSkinFile
}

function Show-SkinPicker {
    param(
        [string]$Username,
        [string]$Version
    )
    
    $skinForm = New-Object System.Windows.Forms.Form
    $skinForm.Text = "Skin Picker - OfflineSkins Integration"
    $skinForm.Size = New-Object System.Drawing.Size(600, 520)
    $skinForm.StartPosition = "CenterScreen"
    $skinForm.FormBorderStyle = "FixedDialog"
    $skinForm.MaximizeBox = $false
    $skinForm.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    
    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.Size = New-Object System.Drawing.Size(560, 30)
    $titleLabel.Text = "Choose Your Minecraft Skin"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $skinForm.Controls.Add($titleLabel)
    
    # Preview
    $previewLabel = New-Object System.Windows.Forms.Label
    $previewLabel.Location = New-Object System.Drawing.Point(20, 60)
    $previewLabel.Size = New-Object System.Drawing.Size(200, 200)
    $previewLabel.Text = "Skin Preview"
    $previewLabel.TextAlign = "MiddleCenter"
    $previewLabel.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $previewLabel.ForeColor = [System.Drawing.Color]::White
    $previewLabel.BorderStyle = "FixedSingle"
    $skinForm.Controls.Add($previewLabel)
    
    # Load current skin
    $currentSkin = Get-CurrentSkin -Username $Username -Version $Version
    if ($currentSkin -and (Test-Path $currentSkin)) {
        try {
            # Load image into memory without locking the file
            $bytes = [System.IO.File]::ReadAllBytes($currentSkin)
            $ms = New-Object System.IO.MemoryStream($bytes, 0, $bytes.Length)
            $skinImage = [System.Drawing.Image]::FromStream($ms)
            $previewLabel.Image = $skinImage
            $previewLabel.Text = ""
            # Keep the MemoryStream in a variable so it doesn't get disposed
            $previewLabel.Tag = $ms
        } catch { }
    }
    
    # Upload Button
    $uploadButton = New-Object System.Windows.Forms.Button
    $uploadButton.Location = New-Object System.Drawing.Point(240, 60)
    $uploadButton.Size = New-Object System.Drawing.Size(340, 40)
    $uploadButton.Text = "Upload Custom Skin (.png)"
    $uploadButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $uploadButton.ForeColor = [System.Drawing.Color]::White
    $uploadButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $uploadButton.FlatStyle = "Flat"
    $uploadButton.Add_Click({
        $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $openFileDialog.Filter = "PNG Images (*.png)|*.png"
        $openFileDialog.Title = "Select Minecraft Skin"
        
        if ($openFileDialog.ShowDialog() -eq "OK") {
            try {
                $newSkinPath = Set-MinecraftSkin -SkinFilePath $openFileDialog.FileName -Username $Username -Version $Version
                
                # Dispose old image and stream
                if ($previewLabel.Image) {
                    $previewLabel.Image.Dispose()
                }
                if ($previewLabel.Tag -is [System.IO.MemoryStream]) {
                    $previewLabel.Tag.Dispose()
                }
                
                # Load new image without locking the file
                $bytes = [System.IO.File]::ReadAllBytes($newSkinPath)
                $ms = New-Object System.IO.MemoryStream($bytes, 0, $bytes.Length)
                $skinImage = [System.Drawing.Image]::FromStream($ms)
                $previewLabel.Image = $skinImage
                $previewLabel.Text = ""
                $previewLabel.Tag = $ms
                
                [System.Windows.Forms.MessageBox]::Show("Skin saved as: $Username.png`n`nIt will automatically load with OfflineSkins mod!", "Success", "OK", "Information")
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Failed to apply skin: $($_.Exception.Message)", "Error", "OK", "Error")
            }
        }
    })
    $skinForm.Controls.Add($uploadButton)
    
    # Info
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Location = New-Object System.Drawing.Point(240, 120)
    $infoLabel.Size = New-Object System.Drawing.Size(340, 120)
    $infoLabel.Text = "✅ Integrated with OfflineSkins mod!`n`nYour skin is saved to:`nconfig/offlineskins/$Username.png`n`nMake sure you have the OfflineSkins mod installed for Fabric!`n`nSupports 64x32 or 64x64 format skins.`nWorks with 3D Skin Layers and other cosmetic mods!"
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $infoLabel.ForeColor = [System.Drawing.Color]::LightGray
    $skinForm.Controls.Add($infoLabel)
    
    # Skin location label
    $locationLabel = New-Object System.Windows.Forms.Label
    $locationLabel.Location = New-Object System.Drawing.Point(20, 280)
    $locationLabel.Size = New-Object System.Drawing.Size(560, 60)
    $skinsDir = Get-SkinPath -Version $Version
    $locationLabel.Text = "Skin saved to:`n$skinsDir\$Username.png"
    $locationLabel.Font = New-Object System.Drawing.Font("Consolas", 8)
    $locationLabel.ForeColor = [System.Drawing.Color]::Yellow
    $skinForm.Controls.Add($locationLabel)
    
    # Instructions
    $instructionsLabel = New-Object System.Windows.Forms.Label
    $instructionsLabel.Location = New-Object System.Drawing.Point(20, 350)
    $instructionsLabel.Size = New-Object System.Drawing.Size(560, 60)
    $instructionsLabel.Text = "After uploading, your skin will automatically load when you start the game!`n`nNo commands needed - just launch Minecraft with OfflineSkins mod installed."
    $instructionsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $instructionsLabel.ForeColor = [System.Drawing.Color]::LightGreen
    $skinForm.Controls.Add($instructionsLabel)
    
    # Close Button
    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Location = New-Object System.Drawing.Point(240, 430)
    $closeButton.Size = New-Object System.Drawing.Size(340, 40)
    $closeButton.Text = "Close"
    $closeButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $closeButton.ForeColor = [System.Drawing.Color]::White
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $closeButton.FlatStyle = "Flat"
    $closeButton.Add_Click({
        if ($previewLabel.Image) {
            $previewLabel.Image.Dispose()
        }
        if ($previewLabel.Tag -is [System.IO.MemoryStream]) {
            $previewLabel.Tag.Dispose()
        }
        $skinForm.Close()
    })
    $skinForm.Controls.Add($closeButton)
    
    $skinForm.Add_FormClosing({
        if ($previewLabel.Image) {
            $previewLabel.Image.Dispose()
        }
        if ($previewLabel.Tag -is [System.IO.MemoryStream]) {
            $previewLabel.Tag.Dispose()
        }
    })
    
    [void]$skinForm.ShowDialog()
}
#endregion

#region Game Launcher Core
function Start-MinecraftGame {
    param(
        [string]$Version,
        [string]$LoaderType,
        [string]$Username,
        [int]$Memory
    )
    
    $versionsDir = Join-Path $scriptDir "versions"
    $versionDir = Join-Path $versionsDir $Version
    $libsDir = Join-Path $versionDir "libraries"
    $natives = Join-Path $versionDir "natives"
    $gameDir = $versionDir
    $runtimeDir = Join-Path $scriptDir "runtime"
    
    $uuid = Get-ComputerUUID
    
    $versionJson = $null
    
    if ($LoaderType -eq "FABRIC") {
        $fabricJsons = Get-ChildItem (Join-Path $versionDir "versions") -Filter "fabric-loader*.json" -ErrorAction SilentlyContinue
        if ($fabricJsons) {
            $versionJson = $fabricJsons[0].FullName
        }
    }
    elseif ($LoaderType -eq "FORGE") {
        $forgeJsons = Get-ChildItem (Join-Path $versionDir "versions") -Filter "forge*.json" -ErrorAction SilentlyContinue
        if ($forgeJsons) {
            $versionJson = $forgeJsons[0].FullName
        }
    }
    
    # Default to vanilla if no mod loader JSON found
    if (-not $versionJson -or -not (Test-Path $versionJson)) {
        $versionJson = Join-Path $versionDir "versions\$Version.json"
        $LoaderType = "VANILLA"
    }
    
    if (-not $versionJson -or -not (Test-Path $versionJson)) {
        $versionJson = Join-Path $versionDir "versions\$Version.json"
        $LoaderType = "VANILLA"
    }
    
    if (-not (Test-Path $versionJson)) {
        throw "Version JSON not found: $versionJson"
    }
    
    $jsonContent = Get-Content $versionJson -Raw | ConvertFrom-Json
    
    $javaVersion = 25
    if ($jsonContent.javaVersion.majorVersion) {
        $javaVersion = $jsonContent.javaVersion.majorVersion
    }
    
    $javaExe = Join-Path $runtimeDir "$javaVersion\bin\java.exe"
    if (-not (Test-Path $javaExe)) {
        throw "Java $javaVersion not found at: $javaExe"
    }
    
    $mainClass = $jsonContent.mainClass
    
    $assetIndex = $Version
    $assetIndexFiles = Get-ChildItem (Join-Path $versionDir "assets\indexes") -Filter "*.json" -ErrorAction SilentlyContinue
    if ($assetIndexFiles) {
        $assetIndex = $assetIndexFiles[0].BaseName
    }
    
    $libraries = @()
    
    # Match the batch file logic EXACTLY: create temp files for debugging
    $tempMerged = Join-Path $scriptDir "~temp_libs_merged.txt"
    $tempFiltered = Join-Path $scriptDir "~temp_libs_filtered.txt"
    
    if ($LoaderType -eq "FABRIC" -or $LoaderType -eq "FORGE") {
        # Step 1: Merge mod loader + vanilla libraries
        $allLibs = @()
        
        # Add mod loader libraries first
        if ($jsonContent.libraries) {
            foreach ($lib in $jsonContent.libraries) {
                if ($lib.name) {
                    $allLibs += $lib.name
                }
            }
        }
        
        # Then add vanilla libraries
        $vanillaJsonPath = Join-Path $versionDir "versions\$Version.json"
        if (Test-Path $vanillaJsonPath) {
            $vanillaJson = Get-Content $vanillaJsonPath -Raw | ConvertFrom-Json
            if ($vanillaJson.libraries) {
                foreach ($lib in $vanillaJson.libraries) {
                    if ($lib.name) {
                        $allLibs += $lib.name
                    }
                }
            }
        }
        
        # Remove duplicates (keep order - mod loader first)
        $allLibs = $allLibs | Select-Object -Unique
        
        # Write merged libraries to temp file (for debugging)
        $allLibs | Out-File -FilePath $tempMerged -Encoding ASCII
        
        # Step 2: Filter to keep only latest version of each library
        $latest = @{}
        foreach ($lib in $allLibs) {
            $parts = $lib -split ':'
            if ($parts.Length -ge 3) {
                $key = "$($parts[0]):$($parts[1])"
                # If there's a classifier (4th part), add it to the key
                if ($parts.Length -eq 4) {
                    $key += ":$($parts[3])"
                }
                $ver = $parts[2]
                
                if (-not $latest.ContainsKey($key)) {
                    $latest[$key] = $ver
                } else {
                    # Keep newer version
                    if ($ver -gt $latest[$key]) {
                        $latest[$key] = $ver
                    }
                }
            }
        }
        
        # Step 3: Rebuild library list from filtered versions
        $libraries = @()
        foreach ($key in $latest.Keys) {
            $keyParts = $key -split ':'
            $group = $keyParts[0]
            $artifact = $keyParts[1]
            $classifier = if ($keyParts.Length -eq 3) { $keyParts[2] } else { $null }
            $ver = $latest[$key]
            
            if ($classifier) {
                $libraries += "$group`:$artifact`:$ver`:$classifier"
            } else {
                $libraries += "$group`:$artifact`:$ver"
            }
        }
        
        # Write filtered libraries to temp file (for debugging)
        $libraries | Out-File -FilePath $tempFiltered -Encoding ASCII
    }
    else {
        # Vanilla: just get libraries from JSON and filter
        $allLibs = @()
        if ($jsonContent.libraries) {
            foreach ($lib in $jsonContent.libraries) {
                if ($lib.name) {
                    $allLibs += $lib.name
                }
            }
        }
        
        # Write merged libraries (same as all libs for vanilla)
        $allLibs | Out-File -FilePath $tempMerged -Encoding ASCII
        
        # Filter to keep only latest version of each library
        $latest = @{}
        foreach ($lib in $allLibs) {
            $parts = $lib -split ':'
            if ($parts.Length -eq 3) {
                $key = "$($parts[0]):$($parts[1])"
                $ver = $parts[2]
                
                if (-not $latest.ContainsKey($key)) {
                    $latest[$key] = $ver
                } else {
                    if ($ver -gt $latest[$key]) {
                        $latest[$key] = $ver
                    }
                }
            }
        }
        
        # Rebuild library list
        $libraries = @()
        foreach ($key in $latest.Keys) {
            $group, $artifact = $key -split ':'
            $ver = $latest[$key]
            $libraries += "$group`:$artifact`:$ver"
        }
        
        # Write filtered libraries to temp file (for debugging)
        $libraries | Out-File -FilePath $tempFiltered -Encoding ASCII
    }
    
    $classpathEntries = @()
    
    # Build classpath with RELATIVE paths
    foreach ($lib in $libraries) {
        $parts = $lib -split ':'
        if ($parts.Length -ge 3) {
            $group = $parts[0]
            $artifact = $parts[1]
            $libVersion = $parts[2]
            $classifier = if ($parts.Length -eq 4) { $parts[3] } else { $null }
            
            $groupPath = $group -replace '\.', '\'
            
            # Build JAR name with classifier if present
            if ($classifier) {
                $jarName = "$artifact-$libVersion-$classifier.jar"
            } else {
                $jarName = "$artifact-$libVersion.jar"
            }
            
            # Use FULL path to check if file exists
            $fullPath = Join-Path $libsDir "$groupPath\$artifact\$libVersion\$jarName"
            
            # But use RELATIVE path in classpath
            $relPath = "versions\$Version\libraries\$groupPath\$artifact\$libVersion\$jarName"
            
            if (Test-Path $fullPath) {
                $classpathEntries += $relPath
            }
        }
    }
    
    # Add client JAR with RELATIVE path (EXCEPT for Forge)
    if ($LoaderType -ne "FORGE") {
        $clientJar = Join-Path $versionDir "versions\$Version-client.jar"
        
        if (-not (Test-Path $clientJar)) {
            $clientJar = Join-Path $versionDir "versions\$Version.jar"
        }
        
        if (-not (Test-Path $clientJar)) {
            $versionsFolder = Join-Path $versionDir "versions"
            $existingFiles = ""
            if (Test-Path $versionsFolder) {
                $files = Get-ChildItem $versionsFolder -Filter "*.jar"
                $existingFiles = ($files | ForEach-Object { $_.Name }) -join ", "
            }
            
            throw "Client JAR not found!`n`nLooking for: $Version-client.jar or $Version.jar`nIn folder: $versionsFolder`nFound JARs: $existingFiles"
        }
        
        # Add as relative path
        if (Test-Path (Join-Path $versionDir "versions\$Version-client.jar")) {
            $classpathEntries += "versions\$Version\versions\$Version-client.jar"
        } else {
            $classpathEntries += "versions\$Version\versions\$Version.jar"
        }
    }
    
    $classpath = $classpathEntries -join ';'
    
    $javaArgs = @(
        "-Djava.library.path=`"$natives`""
        "-Xmx$($Memory)G"
        "-Xmn128M"
        "-Dorg.lwjgl.librarypath=`"$natives`""
    )
    
    # Add JVM arguments from JSON (ONLY for Forge!)
    if ($LoaderType -eq "FORGE" -and $jsonContent.arguments -and $jsonContent.arguments.jvm) {
        foreach ($arg in $jsonContent.arguments.jvm) {
            if ($arg -is [string]) {
                # Replace variables in JVM arguments
                $processedArg = $arg
                $processedArg = $processedArg -replace '\$\{library_directory\}', (Join-Path $versionDir "libraries")
                $processedArg = $processedArg -replace '\$\{classpath_separator\}', ';'
                $processedArg = $processedArg -replace '\$\{version_name\}', $Version
                
                $javaArgs += $processedArg
            }
        }
    }
    
    # Add classpath and main class
    $javaArgs += "-cp"
    $javaArgs += "`"$classpath`""
    $javaArgs += $mainClass
    
    $gameArgs = @(
        "--username", $Username
        "--version", $Version
        "--gameDir", "`"$gameDir`""
        "--assetsDir", "`"$(Join-Path $versionDir 'assets')`""
        "--assetIndex", $assetIndex
        "--uuid", $uuid
        "--accessToken", "0"
        "--userType", "legacy"
    )
    
    # Add game arguments from JSON (ONLY for Forge!)
    if ($LoaderType -eq "FORGE" -and $jsonContent.arguments -and $jsonContent.arguments.game) {
        foreach ($arg in $jsonContent.arguments.game) {
            if ($arg -is [string]) {
                $gameArgs += $arg
            }
        }
    }
    
    $allArgs = $javaArgs + $gameArgs
    
    # Build the command line
    $argsString = $allArgs -join ' '
    
    # Create a temporary batch file to run the command
    $tempBatchFile = Join-Path $scriptDir "~temp_launch.bat"
    $batchContent = @"
@echo off
cd /d "$scriptDir"
"$javaExe" $argsString
"@
    
    $batchContent | Out-File -FilePath $tempBatchFile -Encoding ASCII
    
    # Run the batch file hidden
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $tempBatchFile
    $psi.WorkingDirectory = $scriptDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    
    $process = [System.Diagnostics.Process]::Start($psi)
    
    # Clean up temp files after a short delay
    Start-Sleep -Milliseconds 500
    if (Test-Path $tempBatchFile) { Remove-Item $tempBatchFile -Force }
    $tempMerged = Join-Path $scriptDir "~temp_libs_merged.txt"
    $tempFiltered = Join-Path $scriptDir "~temp_libs_filtered.txt"
    if (Test-Path $tempMerged) { Remove-Item $tempMerged -Force }
    if (Test-Path $tempFiltered) { Remove-Item $tempFiltered -Force }
    
    # Clean up temp files
    $tempMerged = Join-Path $scriptDir "~temp_libs_merged.txt"
    $tempFiltered = Join-Path $scriptDir "~temp_libs_filtered.txt"
    if (Test-Path $tempMerged) { Remove-Item $tempMerged -Force }
    if (Test-Path $tempFiltered) { Remove-Item $tempFiltered -Force }
    
    return 0
}
#endregion

#region Configuration
function Get-Config {
    $configFile = Join-Path $scriptDir "config.txt"
    $config = @{
        Username = ""
        Memory = 2
    }
    
    if (Test-Path $configFile) {
        Get-Content $configFile | ForEach-Object {
            if ($_ -match "NICK=(.+)") { $config.Username = $matches[1] }
            if ($_ -match "max_MEM=(.+)") { $config.Memory = [int]$matches[1] }
        }
    }
    
    return $config
}

function Save-Config {
    param($Username, $Memory)
    
    $configFile = Join-Path $scriptDir "config.txt"
    @"
NICK=$Username
max_MEM=$Memory
"@ | Out-File -FilePath $configFile -Encoding ASCII
}
#endregion

#region Server Management
function Get-ServerPath {
    param([string]$Version, [string]$LoaderType)
    
    $serverName = "$LoaderType-$Version".ToLower()
    $serverDir = Join-Path $scriptDir "servers\$serverName"
    
    if (-not (Test-Path $serverDir)) {
        New-Item -Path $serverDir -ItemType Directory -Force | Out-Null
    }
    
    return $serverDir
}

function Download-ServerJar {
    param(
        [string]$Version,
        [string]$LoaderType,
        [string]$ServerDir
    )
    
    $serverJar = Join-Path $ServerDir "server.jar"
    
    # If server.jar already exists, skip download
    if (Test-Path $serverJar) {
        return $true
    }
    
    Write-Host "Downloading $LoaderType server JAR for version $Version..."
    
    try {
        switch ($LoaderType.ToLower()) {
            "vanilla" {
                # Download Vanilla server from Mojang
                $manifestUrl = "https://launchermeta.mojang.com/mc/game/version_manifest.json"
                $manifest = Invoke-RestMethod -Uri $manifestUrl
                
                $versionData = $manifest.versions | Where-Object { $_.id -eq $Version } | Select-Object -First 1
                if (-not $versionData) {
                    throw "Version $Version not found in manifest"
                }
                
                $versionJson = Invoke-RestMethod -Uri $versionData.url
                $serverUrl = $versionJson.downloads.server.url
                
                if (-not $serverUrl) {
                    throw "No server download available for version $Version"
                }
                
                Invoke-WebRequest -Uri $serverUrl -OutFile $serverJar
                Write-Host "Vanilla server downloaded successfully!"
                return $true
            }
            
            "fabric" {
                # Download Fabric server launcher
                $fabricVersion = "0.19.2" # Latest stable Fabric loader
                $fabricUrl = "https://meta.fabricmc.net/v2/versions/loader/$Version/$fabricVersion/1.0.1/server/jar"
                
                Invoke-WebRequest -Uri $fabricUrl -OutFile $serverJar
                Write-Host "Fabric server downloaded successfully!"
                return $true
            }
            
            "forge" {
                # Download Forge installer
                Write-Host "Downloading Forge installer for $Version..."
                
                try {
                    # Get Forge promotions (recommended versions)
                    $promotionsUrl = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
                    $promotions = Invoke-RestMethod -Uri $promotionsUrl
                    
                    # Try to find recommended version for this Minecraft version
                    $promoKey = "$Version-recommended"
                    $latestKey = "$Version-latest"
                    
                    $forgeVersion = $null
                    if ($promotions.promos.$promoKey) {
                        $forgeVersion = $promotions.promos.$promoKey
                        Write-Host "Found recommended Forge version: $forgeVersion"
                    } elseif ($promotions.promos.$latestKey) {
                        $forgeVersion = $promotions.promos.$latestKey
                        Write-Host "Found latest Forge version: $forgeVersion"
                    }
                    
                    if (-not $forgeVersion) {
                        # If no promotion found, try to get from version list
                        Write-Host "No promoted version found, checking available versions..."
                        $versionListUrl = "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
                        $versionXml = Invoke-RestMethod -Uri $versionListUrl
                        
                        # Find versions matching this Minecraft version
                        $matchingVersions = $versionXml.metadata.versioning.versions.version | Where-Object { $_ -like "$Version-*" }
                        
                        if ($matchingVersions) {
                            # Get the latest matching version
                            $forgeVersion = ($matchingVersions | Select-Object -Last 1) -replace "$Version-", ""
                            Write-Host "Found Forge version: $forgeVersion"
                        } else {
                            throw "No Forge version found for Minecraft $Version"
                        }
                    }
                } catch {
                    throw "Failed to fetch Forge version info: $_`n`nPlease download Forge installer manually from: https://files.minecraftforge.net/"
                }
                
                $installerUrl = "https://maven.minecraftforge.net/net/minecraftforge/forge/$Version-$forgeVersion/forge-$Version-$forgeVersion-installer.jar"
                $installerPath = Join-Path $ServerDir "forge-installer.jar"
                
                Write-Host "Downloading from: $installerUrl"
                
                try {
                    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
                } catch {
                    throw "Failed to download Forge installer: $_`n`nPlease download manually from: https://files.minecraftforge.net/`nPlace installer in: $ServerDir"
                }
                
                # Run Forge installer
                Write-Host "Running Forge installer (this may take a few minutes)..."
                
                # Get Java path
                $javaExe = $null
                foreach ($javaVer in @("25", "23", "21", "17", "8")) {
                    $testJava = Join-Path $scriptDir "runtime\$javaVer\bin\java.exe"
                    if (Test-Path $testJava) {
                        $javaExe = $testJava
                        break
                    }
                }
                
                if (-not $javaExe) {
                    throw "Java runtime not found - cannot install Forge"
                }
                
                # Run installer with --installServer flag
                $installProcess = Start-Process -FilePath $javaExe -ArgumentList "-jar","`"$installerPath`"","--installServer" -WorkingDirectory $ServerDir -Wait -PassThru -NoNewWindow
                
                if ($installProcess.ExitCode -eq 0) {
                    # Find the generated server JAR (usually forge-VERSION-shim.jar or similar)
                    $forgeJars = Get-ChildItem -Path $ServerDir -Filter "forge-*.jar" | Where-Object { $_.Name -notlike "*installer*" }
                    
                    if ($forgeJars) {
                        # Rename to server.jar
                        Move-Item -Path $forgeJars[0].FullName -Destination $serverJar -Force
                        
                        # Also check for run.bat/run.sh that Forge creates
                        $forgeBat = Join-Path $ServerDir "run.bat"
                        if (Test-Path $forgeBat) {
                            # Forge creates its own run script, we'll use that
                            Write-Host "Forge installed with run.bat - server will use Forge's launcher"
                        }
                        
                        Write-Host "Forge server installed successfully!"
                        return $true
                    } else {
                        throw "Forge installation completed but server JAR not found"
                    }
                } else {
                    throw "Forge installer failed with exit code: $($installProcess.ExitCode)"
                }
            }
            
            "paper" {
                # Download Paper server using API v2
                Write-Host "Downloading Paper server for $Version..."
                
                try {
                    # Get version builds info
                    $buildsUrl = "https://api.papermc.io/v2/projects/paper/versions/$Version/builds"
                    $buildsData = Invoke-RestMethod -Uri $buildsUrl
                    
                    # Find latest build
                    $latestBuild = $buildsData.builds | Select-Object -Last 1
                    
                    if (-not $latestBuild) {
                        throw "No Paper builds found for version $Version"
                    }
                    
                    $buildNumber = $latestBuild.build
                    $jarName = $latestBuild.downloads.application.name
                    
                    # Construct download URL
                    $paperUrl = "https://api.papermc.io/v2/projects/paper/versions/$Version/builds/$buildNumber/downloads/$jarName"
                    
                    Write-Host "Downloading Paper build #$buildNumber..."
                    Invoke-WebRequest -Uri $paperUrl -OutFile $serverJar
                    
                    Write-Host "Paper server downloaded successfully!"
                    return $true
                } catch {
                    throw "Failed to download Paper server: $_`n`nPlease download manually from: https://papermc.io/downloads/paper"
                }
            }
            
            "purpur" {
                # Download Purpur server using API v2
                Write-Host "Downloading Purpur server for $Version..."
                
                try {
                    # Purpur has a simple latest download endpoint
                    $purpurUrl = "https://api.purpurmc.org/v2/purpur/$Version/latest/download"
                    
                    Write-Host "Downloading latest Purpur build..."
                    Invoke-WebRequest -Uri $purpurUrl -OutFile $serverJar
                    
                    Write-Host "Purpur server downloaded successfully!"
                    return $true
                } catch {
                    throw "Failed to download Purpur server: $_`n`nPlease download manually from: https://purpurmc.org/downloads/purpur"
                }
            }
        }
    } catch {
        Write-Host "ERROR: Failed to download server JAR: $_"
        return $false
    }
}

function Initialize-MinecraftServer {
    param(
        [string]$Version,
        [string]$LoaderType,
        [string]$Port = "25565",
        [string]$Gamemode = "survival",
        [string]$Difficulty = "normal",
        [int]$MaxPlayers = 20,
        [bool]$PVP = $true,
        [int]$Memory = 2
    )
    
    $serverDir = Get-ServerPath -Version $Version -LoaderType $LoaderType
    
    # Create eula.txt (auto-accept)
    $eulaFile = Join-Path $serverDir "eula.txt"
    "eula=true" | Out-File -FilePath $eulaFile -Encoding ASCII -Force
    
    # Create server.properties
    $propsFile = Join-Path $serverDir "server.properties"
    
    # Handle hardcore mode (hardcore overrides gamemode)
    $isHardcore = ($Gamemode -eq "Hardcore")
    $actualGamemode = if ($isHardcore) { "survival" } else { $Gamemode.ToLower() }
    
    $properties = @"
server-port=$Port
gamemode=$actualGamemode
difficulty=$($Difficulty.ToLower())
hardcore=$($isHardcore.ToString().ToLower())
max-players=$MaxPlayers
pvp=$($PVP.ToString().ToLower())
view-distance=10
online-mode=false
white-list=false
enable-command-block=true
spawn-protection=0
motd=Minecraft Portable Server - $Version
"@
    
    $properties | Out-File -FilePath $propsFile -Encoding ASCII -Force
    
    return $serverDir
}

function Start-MinecraftServer {
    param(
        [string]$Version,
        [string]$LoaderType,
        [int]$Memory,
        [hashtable]$Config
    )
    
    # Initialize server with config
    $serverDir = Initialize-MinecraftServer -Version $Version -LoaderType $LoaderType `
        -Port $Config.Port -Gamemode $Config.Gamemode -Difficulty $Config.Difficulty `
        -MaxPlayers $Config.MaxPlayers -PVP $Config.PVP -Memory $Memory
    
    # Find or download server JAR
    $serverJar = Join-Path $serverDir "server.jar"
    
    if (-not (Test-Path $serverJar)) {
        Write-Host "Server JAR not found, attempting to download..."
        
        $downloadSuccess = Download-ServerJar -Version $Version -LoaderType $LoaderType -ServerDir $serverDir
        
        if (-not $downloadSuccess -or -not (Test-Path $serverJar)) {
            throw "Failed to download server JAR for $LoaderType $Version`n`nPlease manually place server.jar in:`n$serverDir"
        }
    }
    
    # Get Java path
    $javaExe = $null
    
    # Try different Java runtime locations
    foreach ($javaVer in @("25", "23", "21", "17", "8")) {
        $testJava = Join-Path $scriptDir "runtime\$javaVer\bin\java.exe"
        if (Test-Path $testJava) {
            $javaExe = $testJava
            break
        }
    }
    
    if (-not $javaExe) {
        throw "Java runtime not found"
    }
    
    # Build server start command
    $serverArgs = @(
        "-Xmx$($Memory)G"
        "-Xms$($Memory)G"
        "-jar"
        "`"$serverJar`""
        "nogui"
    )
    
    # Create batch file to run server
    $batchFile = Join-Path $serverDir "start_server.bat"
    $batchContent = @"
@echo off
title Minecraft Server - $LoaderType $Version
cd /d "$serverDir"
echo Starting Minecraft Server...
echo Version: $Version
echo Loader: $LoaderType
echo Port: $($Config.Port)
echo Memory: $($Memory)GB
echo.
"$javaExe" $($serverArgs -join ' ')
echo.
echo Server stopped. Press any key to close...
pause >nul
"@
    
    $batchContent | Out-File -FilePath $batchFile -Encoding ASCII -Force
    
    # Start server in new window
    Start-Process -FilePath $batchFile -WorkingDirectory $serverDir
    
    return @{
        ServerDir = $serverDir
        Port = $Config.Port
        Running = $true
    }
}
#endregion

function Get-OfflineUUID {
    param(
        [string]$Username
    )
    
    # Calculate offline UUID from username (same as Minecraft server does)
    $input = "OfflinePlayer:$Username"
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($input))
    
    # Set version to 3 (name-based UUID) and variant bits
    $hash[6] = ($hash[6] -band 0x0F) -bor 0x30
    $hash[8] = ($hash[8] -band 0x3F) -bor 0x80
    
    # Format as UUID
    $uuid = "{0:x2}{1:x2}{2:x2}{3:x2}-{4:x2}{5:x2}-{6:x2}{7:x2}-{8:x2}{9:x2}-{10:x2}{11:x2}{12:x2}{13:x2}{14:x2}{15:x2}" -f `
        $hash[0], $hash[1], $hash[2], $hash[3], `
        $hash[4], $hash[5], `
        $hash[6], $hash[7], `
        $hash[8], $hash[9], `
        $hash[10], $hash[11], $hash[12], $hash[13], $hash[14], $hash[15]
    
    return $uuid
}

function Get-UsernameFromDatFile {
    param(
        [string]$FilePath
    )
    
    try {
        # Read file as bytes
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        
        # Decompress GZIP (NBT files are GZIP compressed)
        $memStream = New-Object System.IO.MemoryStream
        $memStream.Write($bytes, 0, $bytes.Length)
        $memStream.Position = 0
        
        $gzipStream = New-Object System.IO.Compression.GZipStream($memStream, [System.IO.Compression.CompressionMode]::Decompress)
        $decompressed = New-Object System.IO.MemoryStream
        $gzipStream.CopyTo($decompressed)
        $gzipStream.Close()
        $memStream.Close()
        
        $data = $decompressed.ToArray()
        $decompressed.Close()
        
        # Convert to string and search for username patterns
        $text = [System.Text.Encoding]::UTF8.GetString($data)
        
        # Look for Minecraft username patterns (3-16 chars, alphanumeric + underscore)
        # Common NBT tags: "lastKnownName", or just the username itself
        $patterns = @(
            'lastKnownName.{1,5}([A-Za-z0-9_]{3,16})',  # Bukkit/Spigot/Paper
            '([A-Za-z0-9_]{3,16})\x00',                  # Username followed by null byte
            'playerName.{1,5}([A-Za-z0-9_]{3,16})'       # Some mods
        )
        
        foreach ($pattern in $patterns) {
            if ($text -match $pattern) {
                $username = $matches[1]
                # Validate it looks like a real username (not random data)
                if ($username -match '^[A-Za-z0-9_]{3,16}$' -and $username -notmatch '^\d+$') {
                    return $username
                }
            }
        }
        
        # Fallback: Search for any valid username pattern in the data
        $allMatches = [regex]::Matches($text, '[A-Za-z][A-Za-z0-9_]{2,15}')
        $candidates = @{}
        
        foreach ($match in $allMatches) {
            $candidate = $match.Value
            # Count occurrences (username usually appears multiple times)
            if (-not $candidates.ContainsKey($candidate)) {
                $candidates[$candidate] = 0
            }
            $candidates[$candidate]++
        }
        
        # Return most common candidate (likely the username)
        $mostCommon = $candidates.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
        if ($mostCommon -and $mostCommon.Value -ge 2) {
            return $mostCommon.Key
        }
        
        return $null
        
    } catch {
        Write-Host "Could not extract username from $FilePath : $_"
        return $null
    }
}

function Show-WorldImportDialog {
    # Create import dialog
    $importForm = New-Object System.Windows.Forms.Form
    $importForm.Text = "Import LAN/Singleplayer World"
    $importForm.Size = New-Object System.Drawing.Size(600, 500)
    $importForm.StartPosition = "CenterScreen"
    $importForm.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $importForm.FormBorderStyle = "FixedDialog"
    $importForm.MaximizeBox = $false
    
    # Instructions
    $instructionsLabel = New-Object System.Windows.Forms.Label
    $instructionsLabel.Location = New-Object System.Drawing.Point(20, 20)
    $instructionsLabel.Size = New-Object System.Drawing.Size(550, 90)
    $instructionsLabel.Text = "⚠️ Converting LAN/Singleplayer World to Server`n`nLAN worlds use hardware-based UUIDs for players.`nServers use username-based UUIDs.`n`nThis tool will automatically detect usernames from cache and convert player data!"
    $instructionsLabel.ForeColor = [System.Drawing.Color]::White
    $instructionsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $importForm.Controls.Add($instructionsLabel)
    
    # World folder selection
    $worldLabel = New-Object System.Windows.Forms.Label
    $worldLabel.Location = New-Object System.Drawing.Point(20, 120)
    $worldLabel.Size = New-Object System.Drawing.Size(100, 20)
    $worldLabel.Text = "World Folder:"
    $worldLabel.ForeColor = [System.Drawing.Color]::White
    $worldLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $importForm.Controls.Add($worldLabel)
    
    $worldPathBox = New-Object System.Windows.Forms.TextBox
    $worldPathBox.Location = New-Object System.Drawing.Point(20, 145)
    $worldPathBox.Size = New-Object System.Drawing.Size(450, 25)
    $worldPathBox.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $importForm.Controls.Add($worldPathBox)
    
    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Location = New-Object System.Drawing.Point(480, 143)
    $browseButton.Size = New-Object System.Drawing.Size(80, 28)
    $browseButton.Text = "Browse..."
    $browseButton.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $browseButton.ForeColor = [System.Drawing.Color]::White
    $browseButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $browseButton.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select your Minecraft world folder"
        $folderBrowser.RootFolder = "MyComputer"
        
        if ($folderBrowser.ShowDialog() -eq "OK") {
            $worldPathBox.Text = $folderBrowser.SelectedPath
        }
    })
    $importForm.Controls.Add($browseButton)
    
    # Scan button
    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Location = New-Object System.Drawing.Point(20, 185)
    $scanButton.Size = New-Object System.Drawing.Size(150, 35)
    $scanButton.Text = "Scan for Players"
    $scanButton.BackColor = [System.Drawing.Color]::FromArgb(50, 100, 150)
    $scanButton.ForeColor = [System.Drawing.Color]::White
    $scanButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $scanButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $importForm.Controls.Add($scanButton)
    
    # Results area
    $resultsLabel = New-Object System.Windows.Forms.Label
    $resultsLabel.Location = New-Object System.Drawing.Point(20, 230)
    $resultsLabel.Size = New-Object System.Drawing.Size(550, 20)
    $resultsLabel.Text = "Found Players:"
    $resultsLabel.ForeColor = [System.Drawing.Color]::White
    $resultsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $resultsLabel.Visible = $false
    $importForm.Controls.Add($resultsLabel)
    
    $resultsBox = New-Object System.Windows.Forms.TextBox
    $resultsBox.Location = New-Object System.Drawing.Point(20, 255)
    $resultsBox.Size = New-Object System.Drawing.Size(550, 100)
    $resultsBox.Multiline = $true
    $resultsBox.ScrollBars = "Vertical"
    $resultsBox.ReadOnly = $true
    $resultsBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $resultsBox.Visible = $false
    $importForm.Controls.Add($resultsBox)
    
    # Username input
    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Location = New-Object System.Drawing.Point(20, 365)
    $usernameLabel.Size = New-Object System.Drawing.Size(550, 20)
    $usernameLabel.Text = "Usernames (auto-detected, edit if needed):"
    $usernameLabel.ForeColor = [System.Drawing.Color]::White
    $usernameLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $usernameLabel.Visible = $false
    $importForm.Controls.Add($usernameLabel)
    
    $usernameBox = New-Object System.Windows.Forms.TextBox
    $usernameBox.Location = New-Object System.Drawing.Point(20, 380)
    $usernameBox.Size = New-Object System.Drawing.Size(550, 25)
    $usernameBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $usernameBox.Visible = $false
    $importForm.Controls.Add($usernameBox)
    
    # Convert button
    $convertButton = New-Object System.Windows.Forms.Button
    $convertButton.Location = New-Object System.Drawing.Point(200, 415)
    $convertButton.Size = New-Object System.Drawing.Size(200, 40)
    $convertButton.Text = "Convert & Import"
    $convertButton.BackColor = [System.Drawing.Color]::FromArgb(50, 150, 50)
    $convertButton.ForeColor = [System.Drawing.Color]::White
    $convertButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $convertButton.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $convertButton.Visible = $false
    $importForm.Controls.Add($convertButton)
    
    # Store found player files
    $script:foundPlayers = @()
    
    # Scan button click
    $scanButton.Add_Click({
        $worldPath = $worldPathBox.Text
        
        if (-not $worldPath -or -not (Test-Path $worldPath)) {
            [System.Windows.Forms.MessageBox]::Show("Please select a valid world folder!", "Error", "OK", "Error")
            return
        }
        
        $playerdataPath = Join-Path $worldPath "playerdata"
        
        if (-not (Test-Path $playerdataPath)) {
            [System.Windows.Forms.MessageBox]::Show("No playerdata folder found!`n`nMake sure you selected the world folder (contains level.dat)", "Error", "OK", "Error")
            return
        }
        
        # Scan for .dat files
        $datFiles = Get-ChildItem -Path $playerdataPath -Filter "*.dat" | Where-Object { $_.Name -ne "player.dat" }
        
        if ($datFiles.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No player data files found in world!", "Info", "OK", "Information")
            return
        }
        
        # Try to find usercache.json to map UUIDs to usernames
        $uuidToUsername = @{}
        
        # Look for usercache.json in multiple locations
        $cacheLocations = @(
            (Join-Path $worldPath "usercache.json"),                    # In world folder (LAN)
            (Join-Path (Split-Path $worldPath -Parent) "usercache.json"), # In saves folder
            (Join-Path (Split-Path (Split-Path $worldPath -Parent) -Parent) "usercache.json") # In .minecraft folder
        )
        
        foreach ($cachePath in $cacheLocations) {
            if (Test-Path $cachePath) {
                try {
                    $cacheContent = Get-Content -Path $cachePath -Raw | ConvertFrom-Json
                    
                    foreach ($entry in $cacheContent) {
                        # Store mapping (remove hyphens from UUID for matching)
                        $cleanUUID = $entry.uuid -replace '-', ''
                        $uuidToUsername[$cleanUUID] = $entry.name
                    }
                    
                    Write-Host "Found usercache.json with $($uuidToUsername.Count) entries"
                    break
                } catch {
                    Write-Host "Failed to parse usercache.json: $_"
                }
            }
        }
        
        # Store found players with username info
        $script:foundPlayers = @()
        $script:playerMappings = @()
        
        # Display results with usernames if available
        $resultsText = ""
        $autoUsernames = @()
        
        foreach ($file in $datFiles) {
            $script:foundPlayers += $file
            
            # Extract UUID from filename (remove .dat extension)
            $fileUUID = $file.BaseName -replace '-', ''
            
            # Check if we have a username for this UUID
            if ($uuidToUsername.ContainsKey($fileUUID)) {
                $username = $uuidToUsername[$fileUUID]
                $resultsText += "✓ $username → $($file.Name)`n"
                $autoUsernames += $username
                $script:playerMappings += @{ UUID = $file.BaseName; Username = $username }
            } else {
                $resultsText += "? Unknown → $($file.Name)`n"
                $script:playerMappings += @{ UUID = $file.BaseName; Username = $null }
            }
        }
        
        $resultsText += "`nTotal: $($datFiles.Count) player(s)"
        
        if ($uuidToUsername.Count -gt 0) {
            $resultsText += "`n`n✓ = Username detected from cache"
            $resultsText += "`n? = Username unknown (enter manually)"
            
            # Auto-fill detected usernames
            $usernameBox.Text = ($autoUsernames -join ', ')
        } else {
            $resultsText += "`n`n⚠️ No usercache.json found"
            $resultsText += "`nPlease enter usernames manually"
        }
        
        $resultsBox.Text = $resultsText
        $resultsLabel.Visible = $true
        $resultsBox.Visible = $true
        $usernameLabel.Visible = $true
        $usernameBox.Visible = $true
        $convertButton.Visible = $true
    })
    
    # Convert button click
    $convertButton.Add_Click({
        $worldPath = $worldPathBox.Text
        $usernames = $usernameBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        
        if ($usernames.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please enter at least one username!", "Error", "OK", "Error")
            return
        }
        
        if ($usernames.Count -ne $script:foundPlayers.Count) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "Number of usernames ($($usernames.Count)) doesn't match found players ($($script:foundPlayers.Count)).`n`nContinue anyway?`n`n- If MORE usernames: extras ignored`n- If FEWER usernames: remaining players won't be converted",
                "Mismatch Warning",
                "YesNo",
                "Warning"
            )
            
            if ($result -ne "Yes") {
                return
            }
        }
        
        try {
            # Get selected server version and type
            $version = $serverVersionDropdown.SelectedItem
            $loaderType = "vanilla"
            if ($serverFabricRadio.Checked) { $loaderType = "fabric" }
            elseif ($serverForgeRadio.Checked) { $loaderType = "forge" }
            elseif ($serverPaperRadio.Checked) { $loaderType = "paper" }
            elseif ($serverPurpurRadio.Checked) { $loaderType = "purpur" }
            
            $serverDir = Join-Path $scriptDir "servers\$loaderType-$version"
            $newWorldPath = Join-Path $serverDir "world"
            
            # Check if world already exists
            if (Test-Path $newWorldPath) {
                $result = [System.Windows.Forms.MessageBox]::Show(
                    "A world already exists in this server!`n`nOverwrite?",
                    "Overwrite Warning",
                    "YesNo",
                    "Warning"
                )
                
                if ($result -ne "Yes") {
                    return
                }
                
                Remove-Item -Path $newWorldPath -Recurse -Force
            }
            
            # Create server directory if needed
            if (-not (Test-Path $serverDir)) {
                New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
            }
            
            # Copy world
            Write-Host "Copying world to server directory..."
            Copy-Item -Path $worldPath -Destination $newWorldPath -Recurse -Force
            
            # Convert player UUIDs
            $playerdataPath = Join-Path $newWorldPath "playerdata"
            $converted = 0
            
            for ($i = 0; $i -lt [Math]::Min($usernames.Count, $script:foundPlayers.Count); $i++) {
                $username = $usernames[$i]
                $oldFile = $script:foundPlayers[$i]
                
                # Calculate new UUID
                $newUUID = Get-OfflineUUID -Username $username
                
                # Rename file
                $oldPath = Join-Path $playerdataPath $oldFile.Name
                $newPath = Join-Path $playerdataPath "$newUUID.dat"
                
                if (Test-Path $oldPath) {
                    Move-Item -Path $oldPath -Destination $newPath -Force
                    Write-Host "Converted: $username -> $newUUID"
                    $converted++
                }
            }
            
            $importForm.Close()
            
            [System.Windows.Forms.MessageBox]::Show(
                "World imported successfully!`n`n- Converted $converted player(s)`n- Location: $newWorldPath`n`nYou can now start your server!",
                "Success",
                "OK",
                "Information"
            )
            
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to import world:`n`n$($_.Exception.Message)", "Error", "OK", "Error")
        }
    })
    
    [void]$importForm.ShowDialog()
}

#region GUI
$config = Get-Config
$currentUUID = Get-ComputerUUID

# Create main form with background image support
$form = New-Object System.Windows.Forms.Form
$form.Text = "Minecraft Portable Launcher"
$form.Size = New-Object System.Drawing.Size(1344, 756)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true
$form.MinimizeBox = $true

# Try to load background image (background.png or background.jpg)
$backgroundImage = $null
$bgImagePath = Join-Path $scriptDir "background.png"
if (-not (Test-Path $bgImagePath)) {
    $bgImagePath = Join-Path $scriptDir "background.jpg"
}

if (Test-Path $bgImagePath) {
    try {
        $backgroundImage = [System.Drawing.Image]::FromFile($bgImagePath)
        $form.BackgroundImage = $backgroundImage
        $form.BackgroundImageLayout = "Stretch"
    }
    catch {
        $form.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    }
} else {
    # Default dark background if no image
    $form.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
}

# Main GUI Panel (will be hidden during loading)
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Size = New-Object System.Drawing.Size(1328, 720)
$mainPanel.Location = New-Object System.Drawing.Point(0, 0)
$mainPanel.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($mainPanel)

# Navigation Text - CLIENT
$clientNavLabel = New-Object System.Windows.Forms.Label
$clientNavLabel.Location = New-Object System.Drawing.Point(560, 240)
$clientNavLabel.Size = New-Object System.Drawing.Size(100, 30)
$clientNavLabel.Text = "CLIENT"
$clientNavLabel.ForeColor = [System.Drawing.Color]::White
$clientNavLabel.BackColor = [System.Drawing.Color]::Transparent
$clientNavLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$clientNavLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$clientNavLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$clientNavLabel.Add_Click({
    $clientPanel.Visible = $true
    $serverPanel.Visible = $false
    $clientNavLabel.ForeColor = [System.Drawing.Color]::White
    $serverNavLabel.ForeColor = [System.Drawing.Color]::Gray
    $mainPanel.Refresh()
})
$mainPanel.Controls.Add($clientNavLabel)

# Navigation Separator
$navSeparator = New-Object System.Windows.Forms.Label
$navSeparator.Location = New-Object System.Drawing.Point(660, 240)
$navSeparator.Size = New-Object System.Drawing.Size(20, 30)
$navSeparator.Text = "|"
$navSeparator.ForeColor = [System.Drawing.Color]::Gray
$navSeparator.BackColor = [System.Drawing.Color]::Transparent
$navSeparator.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$navSeparator.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$mainPanel.Controls.Add($navSeparator)

# Navigation Text - SERVER
$serverNavLabel = New-Object System.Windows.Forms.Label
$serverNavLabel.Location = New-Object System.Drawing.Point(680, 240)
$serverNavLabel.Size = New-Object System.Drawing.Size(100, 30)
$serverNavLabel.Text = "SERVER"
$serverNavLabel.ForeColor = [System.Drawing.Color]::Gray
$serverNavLabel.BackColor = [System.Drawing.Color]::Transparent
$serverNavLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$serverNavLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$serverNavLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$serverNavLabel.Add_Click({
    $clientPanel.Visible = $false
    $serverPanel.Visible = $true
    $clientNavLabel.ForeColor = [System.Drawing.Color]::Gray
    $serverNavLabel.ForeColor = [System.Drawing.Color]::White
    $mainPanel.Refresh()
})
$mainPanel.Controls.Add($serverNavLabel)

# Client Panel (contains all client controls)
$clientPanel = New-Object System.Windows.Forms.Panel
$clientPanel.Size = New-Object System.Drawing.Size(1328, 450)
$clientPanel.Location = New-Object System.Drawing.Point(0, 270)
$clientPanel.BackColor = [System.Drawing.Color]::Transparent
$clientPanel.Visible = $true
$mainPanel.Controls.Add($clientPanel)

# Server Panel (contains all server controls)
$serverPanel = New-Object System.Windows.Forms.Panel
$serverPanel.Size = New-Object System.Drawing.Size(1328, 450)
$serverPanel.Location = New-Object System.Drawing.Point(0, 270)
$serverPanel.BackColor = [System.Drawing.Color]::Transparent
$serverPanel.Visible = $false
$mainPanel.Controls.Add($serverPanel)

# UUID Display (top left area)
$uuidLabel = New-Object System.Windows.Forms.Label
$uuidLabel.Location = New-Object System.Drawing.Point(325, 0)
$uuidLabel.Size = New-Object System.Drawing.Size(500, 20)
$uuidLabel.Text = "Computer ID: $currentUUID"
$uuidLabel.ForeColor = [System.Drawing.Color]::White
$uuidLabel.BackColor = [System.Drawing.Color]::Transparent
$uuidLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$clientPanel.Controls.Add($uuidLabel)

# Reset UUID Button
$resetUUIDButton = New-Object System.Windows.Forms.Button
$resetUUIDButton.Location = New-Object System.Drawing.Point(585, 30)
$resetUUIDButton.Size = New-Object System.Drawing.Size(130, 28)
$resetUUIDButton.Text = "Reset ID"
$resetUUIDButton.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$resetUUIDButton.ForeColor = [System.Drawing.Color]::White
$resetUUIDButton.BackColor = [System.Drawing.Color]::FromArgb(100, 60, 60, 60)
$resetUUIDButton.FlatStyle = "Flat"
$resetUUIDButton.FlatAppearance.BorderColor = [System.Drawing.Color]::Gray
$resetUUIDButton.FlatAppearance.BorderSize = 1
$resetUUIDButton.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Reset your computer ID? This will create a new player on LAN worlds!",
        "Reset ID",
        "YesNo",
        "Warning"
    )
    if ($result -eq "Yes") {
        Reset-ComputerUUID
        $newUUID = Get-ComputerUUID
        $uuidLabel.Text = "Computer ID: $newUUID"
        [System.Windows.Forms.MessageBox]::Show("Computer ID reset!", "Success", "OK", "Information")
    }
})
$clientPanel.Controls.Add($resetUUIDButton)

# Version Label
$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Location = New-Object System.Drawing.Point(325, 80)
$versionLabel.Size = New-Object System.Drawing.Size(170, 30)
$versionLabel.Text = "Version:"
$versionLabel.ForeColor = [System.Drawing.Color]::White
$versionLabel.BackColor = [System.Drawing.Color]::Transparent
$versionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$clientPanel.Controls.Add($versionLabel)

# Version Dropdown
$versionDropdown = New-Object System.Windows.Forms.ComboBox
$versionDropdown.Location = New-Object System.Drawing.Point(500, 80)
$versionDropdown.Size = New-Object System.Drawing.Size(515, 35)
$versionDropdown.DropDownStyle = "DropDownList"
$versionDropdown.Font = New-Object System.Drawing.Font("Segoe UI", 12)

$versionsDir = Join-Path $scriptDir "versions"
if (Test-Path $versionsDir) {
    Get-ChildItem $versionsDir -Directory | ForEach-Object {
        [void]$versionDropdown.Items.Add($_.Name)
    }
}
if ($versionDropdown.Items.Count -gt 0) {
    $versionDropdown.SelectedIndex = 0
}
$clientPanel.Controls.Add($versionDropdown)

# Mod Loader Label
$loaderLabel = New-Object System.Windows.Forms.Label
$loaderLabel.Location = New-Object System.Drawing.Point(325, 130)
$loaderLabel.Size = New-Object System.Drawing.Size(170, 30)
$loaderLabel.Text = "Mod Loader:"
$loaderLabel.ForeColor = [System.Drawing.Color]::White
$loaderLabel.BackColor = [System.Drawing.Color]::Transparent
$loaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$clientPanel.Controls.Add($loaderLabel)

# Radio Buttons
$vanillaRadio = New-Object System.Windows.Forms.RadioButton
$vanillaRadio.Location = New-Object System.Drawing.Point(500, 130)
$vanillaRadio.Size = New-Object System.Drawing.Size(140, 28)
$vanillaRadio.Text = "Vanilla"
$vanillaRadio.ForeColor = [System.Drawing.Color]::White
$vanillaRadio.BackColor = [System.Drawing.Color]::Transparent
$vanillaRadio.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$vanillaRadio.Checked = $true
$clientPanel.Controls.Add($vanillaRadio)

$fabricRadio = New-Object System.Windows.Forms.RadioButton
$fabricRadio.Location = New-Object System.Drawing.Point(660, 130)
$fabricRadio.Size = New-Object System.Drawing.Size(140, 28)
$fabricRadio.Text = "Fabric"
$fabricRadio.ForeColor = [System.Drawing.Color]::White
$fabricRadio.BackColor = [System.Drawing.Color]::Transparent
$fabricRadio.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$clientPanel.Controls.Add($fabricRadio)

$forgeRadio = New-Object System.Windows.Forms.RadioButton
$forgeRadio.Location = New-Object System.Drawing.Point(805, 130)
$forgeRadio.Size = New-Object System.Drawing.Size(140, 28)
$forgeRadio.Text = "Forge"
$forgeRadio.ForeColor = [System.Drawing.Color]::White
$forgeRadio.BackColor = [System.Drawing.Color]::Transparent
$forgeRadio.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$clientPanel.Controls.Add($forgeRadio)

# Username Label
$usernameLabel = New-Object System.Windows.Forms.Label
$usernameLabel.Location = New-Object System.Drawing.Point(325, 175)
$usernameLabel.Size = New-Object System.Drawing.Size(170, 30)
$usernameLabel.Text = "Username:"
$usernameLabel.ForeColor = [System.Drawing.Color]::White
$usernameLabel.BackColor = [System.Drawing.Color]::Transparent
$usernameLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$clientPanel.Controls.Add($usernameLabel)

# Username TextBox
$usernameTextBox = New-Object System.Windows.Forms.TextBox
$usernameTextBox.Location = New-Object System.Drawing.Point(500, 175)
$usernameTextBox.Size = New-Object System.Drawing.Size(515, 35)
$usernameTextBox.Text = $config.Username
$usernameTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$clientPanel.Controls.Add($usernameTextBox)

# Memory Label
$memoryLabel = New-Object System.Windows.Forms.Label
$memoryLabel.Location = New-Object System.Drawing.Point(325, 225)
$memoryLabel.Size = New-Object System.Drawing.Size(170, 30)
$memoryLabel.Text = "Memory (GB):"
$memoryLabel.ForeColor = [System.Drawing.Color]::White
$memoryLabel.BackColor = [System.Drawing.Color]::Transparent
$memoryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$clientPanel.Controls.Add($memoryLabel)

# Memory Slider
$memorySlider = New-Object System.Windows.Forms.TrackBar
$memorySlider.Location = New-Object System.Drawing.Point(500, 225)
$memorySlider.Size = New-Object System.Drawing.Size(400, 45)
$memorySlider.Minimum = 1
$memorySlider.Maximum = 16
$memorySlider.TickFrequency = 1
$memorySlider.Value = $config.Memory
$clientPanel.Controls.Add($memorySlider)

# Memory Value Label
$memoryValueLabel = New-Object System.Windows.Forms.Label
$memoryValueLabel.Location = New-Object System.Drawing.Point(920, 225)
$memoryValueLabel.Size = New-Object System.Drawing.Size(95, 30)
$memoryValueLabel.Text = "$($memorySlider.Value) GB"
$memoryValueLabel.ForeColor = [System.Drawing.Color]::LightGreen
$memoryValueLabel.BackColor = [System.Drawing.Color]::Transparent
$memoryValueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$clientPanel.Controls.Add($memoryValueLabel)

$memorySlider.add_ValueChanged({
    $memoryValueLabel.Text = "$($memorySlider.Value) GB"
})

# Info Label
$infoLabel = New-Object System.Windows.Forms.Label
$infoLabel.Location = New-Object System.Drawing.Point(325, 280)
$infoLabel.Size = New-Object System.Drawing.Size(690, 25)
$infoLabel.Text = "Each computer has a unique ID to prevent identity theft on LAN worlds"
$infoLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$infoLabel.BackColor = [System.Drawing.Color]::Transparent
$infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$infoLabel.TextAlign = "MiddleCenter"
$clientPanel.Controls.Add($infoLabel)

# Status Label (removed - not in mockup)

# Play Button
$playButton = New-Object System.Windows.Forms.Button
$playButton.Location = New-Object System.Drawing.Point(450, 330)
$playButton.Size = New-Object System.Drawing.Size(330, 65)
$playButton.Text = "PLAY"
$playButton.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
$playButton.ForeColor = [System.Drawing.Color]::White
$playButton.BackColor = [System.Drawing.Color]::FromArgb(0, 180, 0)
$playButton.FlatStyle = "Flat"
$playButton.FlatAppearance.BorderSize = 0
$playButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$playButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a username", "Error", "OK", "Error")
        return
    }
    
    if ($versionDropdown.SelectedIndex -eq -1) {
        [System.Windows.Forms.MessageBox]::Show("Please select a version", "Error", "OK", "Error")
        return
    }
    
    $username = $usernameTextBox.Text
    $memory = $memorySlider.Value
    $version = $versionDropdown.SelectedItem
    
    $loaderType = "VANILLA"
    if ($fabricRadio.Checked) { $loaderType = "FABRIC" }
    elseif ($forgeRadio.Checked) { $loaderType = "FORGE" }
    
    Save-Config -Username $username -Memory $memory
    
    try {
        Start-MinecraftGame -Version $version -LoaderType $loaderType -Username $username -Memory $memory | Out-Null
        
        # Close the launcher after successful launch
        $form.Close()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to launch: $($_.Exception.Message)", "Launch Error", "OK", "Error")
    }
})

$clientPanel.Controls.Add($playButton)

# Change Skin Button
$skinButton = New-Object System.Windows.Forms.Button
$skinButton.Location = New-Object System.Drawing.Point(880, 330)
$skinButton.Size = New-Object System.Drawing.Size(200, 65)
$skinButton.Text = "Change Skin"
$skinButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$skinButton.ForeColor = [System.Drawing.Color]::White
$skinButton.BackColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$skinButton.FlatStyle = "Flat"
$skinButton.FlatAppearance.BorderSize = 0
$skinButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$skinButton.Add_Click({
    $username = $usernameTextBox.Text
    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = "Player"
    }
    
    $version = $versionDropdown.SelectedItem
    if ([string]::IsNullOrWhiteSpace($version)) {
        [System.Windows.Forms.MessageBox]::Show("Please select a version first!", "No Version Selected", "OK", "Warning")
        return
    }
    
    Show-SkinPicker -Username $username -Version $version
})
$clientPanel.Controls.Add($skinButton)

#region Server Tab Controls
# Server Version Label
$serverVersionLabel = New-Object System.Windows.Forms.Label
$serverVersionLabel.Location = New-Object System.Drawing.Point(325, 10)
$serverVersionLabel.Size = New-Object System.Drawing.Size(100, 20)
$serverVersionLabel.Text = "Version:"
$serverVersionLabel.ForeColor = [System.Drawing.Color]::White
$serverVersionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($serverVersionLabel)

# Server Version Dropdown
$serverVersionDropdown = New-Object System.Windows.Forms.ComboBox
$serverVersionDropdown.Location = New-Object System.Drawing.Point(500, 10)
$serverVersionDropdown.Size = New-Object System.Drawing.Size(300, 30)
$serverVersionDropdown.DropDownStyle = "DropDownList"
$serverVersionDropdown.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# Populate server versions from versions directory
$versionsDir = Join-Path $scriptDir "versions"
if (Test-Path $versionsDir) {
    Get-ChildItem $versionsDir -Directory | ForEach-Object {
        [void]$serverVersionDropdown.Items.Add($_.Name)
    }
}
if ($serverVersionDropdown.Items.Count -gt 0) {
    $serverVersionDropdown.SelectedIndex = 0
}
$serverPanel.Controls.Add($serverVersionDropdown)

# Server Type Label (changed from "Loader")
$serverLoaderLabel = New-Object System.Windows.Forms.Label
$serverLoaderLabel.Location = New-Object System.Drawing.Point(325, 50)
$serverLoaderLabel.Size = New-Object System.Drawing.Size(100, 20)
$serverLoaderLabel.Text = "Server Type:"
$serverLoaderLabel.ForeColor = [System.Drawing.Color]::White
$serverLoaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($serverLoaderLabel)

# Server Type Radio Buttons
$serverVanillaRadio = New-Object System.Windows.Forms.RadioButton
$serverVanillaRadio.Location = New-Object System.Drawing.Point(450, 50)
$serverVanillaRadio.Size = New-Object System.Drawing.Size(80, 25)
$serverVanillaRadio.Text = "Vanilla"
$serverVanillaRadio.ForeColor = [System.Drawing.Color]::White
$serverVanillaRadio.Checked = $true
$serverPanel.Controls.Add($serverVanillaRadio)

$serverFabricRadio = New-Object System.Windows.Forms.RadioButton
$serverFabricRadio.Location = New-Object System.Drawing.Point(550, 50)
$serverFabricRadio.Size = New-Object System.Drawing.Size(80, 25)
$serverFabricRadio.Text = "Fabric"
$serverFabricRadio.ForeColor = [System.Drawing.Color]::White
$serverPanel.Controls.Add($serverFabricRadio)

$serverForgeRadio = New-Object System.Windows.Forms.RadioButton
$serverForgeRadio.Location = New-Object System.Drawing.Point(650, 50)
$serverForgeRadio.Size = New-Object System.Drawing.Size(80, 25)
$serverForgeRadio.Text = "Forge"
$serverForgeRadio.ForeColor = [System.Drawing.Color]::White
$serverPanel.Controls.Add($serverForgeRadio)

$serverPaperRadio = New-Object System.Windows.Forms.RadioButton
$serverPaperRadio.Location = New-Object System.Drawing.Point(750, 50)
$serverPaperRadio.Size = New-Object System.Drawing.Size(80, 25)
$serverPaperRadio.Text = "Paper"
$serverPaperRadio.ForeColor = [System.Drawing.Color]::White
$serverPanel.Controls.Add($serverPaperRadio)

$serverPurpurRadio = New-Object System.Windows.Forms.RadioButton
$serverPurpurRadio.Location = New-Object System.Drawing.Point(850, 50)
$serverPurpurRadio.Size = New-Object System.Drawing.Size(80, 25)
$serverPurpurRadio.Text = "Purpur"
$serverPurpurRadio.ForeColor = [System.Drawing.Color]::White
$serverPanel.Controls.Add($serverPurpurRadio)

# Port Label & Input
$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Location = New-Object System.Drawing.Point(325, 90)
$portLabel.Size = New-Object System.Drawing.Size(100, 20)
$portLabel.Text = "Port:"
$portLabel.ForeColor = [System.Drawing.Color]::White
$portLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($portLabel)

$portTextBox = New-Object System.Windows.Forms.TextBox
$portTextBox.Location = New-Object System.Drawing.Point(500, 90)
$portTextBox.Size = New-Object System.Drawing.Size(100, 25)
$portTextBox.Text = "25565"
$portTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($portTextBox)

# Gamemode Label & Dropdown
$gamemodeLabel = New-Object System.Windows.Forms.Label
$gamemodeLabel.Location = New-Object System.Drawing.Point(325, 130)
$gamemodeLabel.Size = New-Object System.Drawing.Size(100, 20)
$gamemodeLabel.Text = "Gamemode:"
$gamemodeLabel.ForeColor = [System.Drawing.Color]::White
$gamemodeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($gamemodeLabel)

$gamemodeDropdown = New-Object System.Windows.Forms.ComboBox
$gamemodeDropdown.Location = New-Object System.Drawing.Point(500, 130)
$gamemodeDropdown.Size = New-Object System.Drawing.Size(150, 30)
$gamemodeDropdown.DropDownStyle = "DropDownList"
$gamemodeDropdown.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$gamemodeDropdown.Items.AddRange(@("Survival", "Creative", "Adventure", "Hardcore"))
$gamemodeDropdown.SelectedIndex = 0
$serverPanel.Controls.Add($gamemodeDropdown)

# Difficulty Label & Dropdown
$difficultyLabel = New-Object System.Windows.Forms.Label
$difficultyLabel.Location = New-Object System.Drawing.Point(325, 170)
$difficultyLabel.Size = New-Object System.Drawing.Size(100, 20)
$difficultyLabel.Text = "Difficulty:"
$difficultyLabel.ForeColor = [System.Drawing.Color]::White
$difficultyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($difficultyLabel)

$difficultyDropdown = New-Object System.Windows.Forms.ComboBox
$difficultyDropdown.Location = New-Object System.Drawing.Point(500, 170)
$difficultyDropdown.Size = New-Object System.Drawing.Size(150, 30)
$difficultyDropdown.DropDownStyle = "DropDownList"
$difficultyDropdown.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$difficultyDropdown.Items.AddRange(@("Peaceful", "Easy", "Normal", "Hard"))
$difficultyDropdown.SelectedIndex = 2
$serverPanel.Controls.Add($difficultyDropdown)

# Max Players Label & Input
$maxPlayersLabel = New-Object System.Windows.Forms.Label
$maxPlayersLabel.Location = New-Object System.Drawing.Point(325, 210)
$maxPlayersLabel.Size = New-Object System.Drawing.Size(100, 20)
$maxPlayersLabel.Text = "Max Players:"
$maxPlayersLabel.ForeColor = [System.Drawing.Color]::White
$maxPlayersLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($maxPlayersLabel)

$maxPlayersTextBox = New-Object System.Windows.Forms.TextBox
$maxPlayersTextBox.Location = New-Object System.Drawing.Point(500, 210)
$maxPlayersTextBox.Size = New-Object System.Drawing.Size(100, 25)
$maxPlayersTextBox.Text = "20"
$maxPlayersTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($maxPlayersTextBox)

# PVP Checkbox
$pvpCheckbox = New-Object System.Windows.Forms.CheckBox
$pvpCheckbox.Location = New-Object System.Drawing.Point(500, 250)
$pvpCheckbox.Size = New-Object System.Drawing.Size(150, 25)
$pvpCheckbox.Text = "Enable PVP"
$pvpCheckbox.ForeColor = [System.Drawing.Color]::White
$pvpCheckbox.Checked = $true
$pvpCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($pvpCheckbox)

# Server Memory Label
$serverMemoryLabelControl = New-Object System.Windows.Forms.Label
$serverMemoryLabelControl.Location = New-Object System.Drawing.Point(750, 180)
$serverMemoryLabelControl.Size = New-Object System.Drawing.Size(150, 20)
$serverMemoryLabelControl.Text = "Server Memory (GB):"
$serverMemoryLabelControl.ForeColor = [System.Drawing.Color]::White
$serverMemoryLabelControl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$serverPanel.Controls.Add($serverMemoryLabelControl)

# Server Memory Slider
$serverMemorySlider = New-Object System.Windows.Forms.TrackBar
$serverMemorySlider.Location = New-Object System.Drawing.Point(750, 210)
$serverMemorySlider.Size = New-Object System.Drawing.Size(250, 45)
$serverMemorySlider.Minimum = 1
$serverMemorySlider.Maximum = 16
$serverMemorySlider.Value = 2
$serverMemorySlider.TickFrequency = 1
$serverPanel.Controls.Add($serverMemorySlider)

# Server Memory Value Label
$serverMemoryValueLabel = New-Object System.Windows.Forms.Label
$serverMemoryValueLabel.Location = New-Object System.Drawing.Point(1020, 210)
$serverMemoryValueLabel.Size = New-Object System.Drawing.Size(60, 20)
$serverMemoryValueLabel.Text = "2 GB"
$serverMemoryValueLabel.ForeColor = [System.Drawing.Color]::White
$serverMemoryValueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$serverPanel.Controls.Add($serverMemoryValueLabel)

$serverMemorySlider.Add_ValueChanged({
    $serverMemoryValueLabel.Text = "$($serverMemorySlider.Value) GB"
})

# Load saved server config
$savedConfig = Load-ServerConfig
if ($savedConfig) {
    # Apply saved memory
    if ($savedConfig.LastMemory) {
        $serverMemorySlider.Value = [Math]::Max(1, [Math]::Min(16, $savedConfig.LastMemory))
        $serverMemoryValueLabel.Text = "$($serverMemorySlider.Value) GB"
    }
    
    # Apply saved version (if exists in dropdown)
    if ($savedConfig.LastVersion) {
        $versionIndex = $serverVersionDropdown.Items.IndexOf($savedConfig.LastVersion)
        if ($versionIndex -ge 0) {
            $serverVersionDropdown.SelectedIndex = $versionIndex
        }
    }
    
    # Apply saved server type
    if ($savedConfig.LastServerType) {
        switch ($savedConfig.LastServerType.ToUpper()) {
            "VANILLA" { $serverVanillaRadio.Checked = $true }
            "FABRIC"  { $serverFabricRadio.Checked = $true }
            "FORGE"   { $serverForgeRadio.Checked = $true }
            "PAPER"   { $serverPaperRadio.Checked = $true }
            "PURPUR"  { $serverPurpurRadio.Checked = $true }
        }
    }
}

# Start Server Button
$startServerButton = New-Object System.Windows.Forms.Button
$startServerButton.Location = New-Object System.Drawing.Point(525, 320)
$startServerButton.Size = New-Object System.Drawing.Size(200, 65)
$startServerButton.Text = "Start Server"
$startServerButton.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$startServerButton.ForeColor = [System.Drawing.Color]::White
$startServerButton.BackColor = [System.Drawing.Color]::FromArgb(0, 150, 0)
$startServerButton.FlatStyle = "Flat"
$startServerButton.FlatAppearance.BorderSize = 0
$startServerButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$startServerButton.Add_Click({
    $version = $serverVersionDropdown.SelectedItem
    $memory = $serverMemorySlider.Value
    
    if ([string]::IsNullOrWhiteSpace($version)) {
        [System.Windows.Forms.MessageBox]::Show("Please select a version!", "No Version", "OK", "Warning")
        return
    }
    
    $loaderType = "VANILLA"
    if ($serverFabricRadio.Checked) { $loaderType = "FABRIC" }
    elseif ($serverForgeRadio.Checked) { $loaderType = "FORGE" }
    elseif ($serverPaperRadio.Checked) { $loaderType = "PAPER" }
    elseif ($serverPurpurRadio.Checked) { $loaderType = "PURPUR" }
    
    $config = @{
        Port = $portTextBox.Text
        Gamemode = $gamemodeDropdown.SelectedItem
        Difficulty = $difficultyDropdown.SelectedItem
        MaxPlayers = [int]$maxPlayersTextBox.Text
        PVP = $pvpCheckbox.Checked
    }
    
    try {
        $result = Start-MinecraftServer -Version $version -LoaderType $loaderType -Memory $memory -Config $config
        
        # Save config after successful server start
        Save-ServerConfig -Version $version -ServerType $loaderType -Memory $memory
        
        [System.Windows.Forms.MessageBox]::Show("Server started successfully!`n`nPort: $($config.Port)`nConnect using: localhost:$($config.Port)", "Server Started", "OK", "Information")
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to start server:`n`n$($_.Exception.Message)", "Server Error", "OK", "Error")
    }
})
$serverPanel.Controls.Add($startServerButton)

# Server Info Label
$serverInfoLabel = New-Object System.Windows.Forms.Label
$serverInfoLabel.Location = New-Object System.Drawing.Point(325, 280)
$serverInfoLabel.Size = New-Object System.Drawing.Size(250, 80)
$serverInfoLabel.Text = "Note: Server JAR must be placed in:`nservers\[loader]-[version]\server.jar`n`nServer will open in a new window."
$serverInfoLabel.ForeColor = [System.Drawing.Color]::Yellow
$serverInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$serverPanel.Controls.Add($serverInfoLabel)

# Import World Button
$importWorldButton = New-Object System.Windows.Forms.Button
$importWorldButton.Location = New-Object System.Drawing.Point(600, 280)
$importWorldButton.Size = New-Object System.Drawing.Size(150, 40)
$importWorldButton.Text = "Import LAN World"
$importWorldButton.BackColor = [System.Drawing.Color]::FromArgb(100, 100, 150)
$importWorldButton.ForeColor = [System.Drawing.Color]::White
$importWorldButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$importWorldButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$importWorldButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$importWorldButton.Add_Click({
    Show-WorldImportDialog
})
$serverPanel.Controls.Add($importWorldButton)
#endregion

[void]$form.ShowDialog()

if ($backgroundImage) {
    $backgroundImage.Dispose()
}
#endregion

} catch {
    $errorMessage = "Error: $($_.Exception.Message)`n`nStack Trace:`n$($_.ScriptStackTrace)"
    $errorMessage | Out-File -FilePath $errorLogFile -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show($errorMessage, "Launcher Error", "OK", "Error")
    exit 1
}
