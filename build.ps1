param(
    [string]$ProductVersion=$null,
    [switch]$SkipInstall
)

###############################################################################
# Functions
###############################################################################
function Get-ScriptDirectory {
	if (Test-Path variable:\hostinvocation) {
		$FullPath = $hostinvocation.MyCommand.Path
	} else {
        $FullPath = (get-variable myinvocation -scope script).value.Mycommand.Definition 
	}    
    if (Test-Path $FullPath) {
        (Split-Path $FullPath) 
    } else {
        $FullPath=(Get-Location).path
        Write-Warning ("Get-ScriptDirectory: Powershell Host <" + $Host.name + "> may not be compatible with this function, the current directory <" + $FullPath + "> will be used.")
        $FullPath
	}
}

function Install-Dnvm
{
    & where.exe dnvm 2>&1 | Out-Null
    if(($LASTEXITCODE -ne 0) -Or ((Test-Path Env:\APPVEYOR) -eq $true))
    {
        Write-Host "DNVM not found"
        &{$Branch='dev';iex ((New-Object net.webclient).DownloadString('https://raw.githubusercontent.com/aspnet/Home/dev/dnvminstall.ps1'))}

        # Normally this happens automatically during install but AppVeyor has
	        # an issue where you may need to manually re-run setup from within this process.
        if($env:DNX_HOME -eq $NULL)
        {
            Write-Host "Initial DNVM environment setup failed; running manual setup"
            $tempDnvmPath = Join-Path $env:TEMP "dnvminstall"
            $dnvmSetupCmdPath = Join-Path $tempDnvmPath "dnvm.ps1"
            & $dnvmSetupCmdPath setup
        }
    }
}

function Get-DnxVersion
{
	param([string]$ScriptDir)
    $globalJson = Join-Path $ScriptDir "global.json"
    $jsonData = Get-Content -Path $globalJson -Raw | ConvertFrom-JSON
    return $jsonData.sdk.version
}

function Restore-Packages
{
    param([string] $DirectoryName)
    & dnu restore ("""" + $DirectoryName + """")
}

function Update-ProjectVersions
{
    param(
        [string]$DirectoryName,
        [string]$ProductVersion
    )    
	if (-not [String]::IsNullOrEmpty($ProductVersion)) 
	{

		$projectFiles = Get-ChildItem -Path $DirectoryName -Filter project.json -Recurse
		foreach($projectFile in $projectFiles)
		{
			$projectFilePath = $projectFile.FullName
			$projectJson = Get-Content -Path $projectFilePath -Raw | ConvertFrom-Json

			if($projectJson -ne $null){
				$versionProperty = $projectJson | Get-Member -Name version
				if($versionProperty -ne $null){
					if($projectJson.version -ne $ProductVersion){
						$projectJson.version = $ProductVersion
						ConvertTo-Json $projectJson |Set-Content -Path $projectFilePath
					}					
				}				
			} 
		}		
	} 
}

function Build-Projects
{
    param([string] $DirectoryName)
	$projectName =  Split-Path $DirectoryName -Leaf
    & dnu build ("""" + $DirectoryName + """") --configuration Release --out .\artifacts\testbin; if($LASTEXITCODE -ne 0) { exit 1 }
    & dnu pack ("""" + $DirectoryName + """") --configuration Release --out ".\artifacts\packages\$ProjectName"; if($LASTEXITCODE -ne 0) { exit 1 }
}

function Build-TestProjects
{
    param([string] $DirectoryName)
    & dnu build ("""" + $DirectoryName + """") --configuration Release --out .\artifacts\testbin; if($LASTEXITCODE -ne 0) { exit 1 }
}

function Test-Projects
{
    param([string] $DirectoryName)
    & dnx -p ("""" + $DirectoryName + """") ci-test; if($LASTEXITCODE -ne 0) { exit 2 }
}

function Remove-PathVariable
{
    param([string] $VariableToRemove)
    $path = [Environment]::GetEnvironmentVariable("PATH", "User")
    $newItems = $path.Split(';') | Where-Object { $_.ToString() -inotlike $VariableToRemove }
    [Environment]::SetEnvironmentVariable("PATH", [System.String]::Join(';', $newItems), "User")
    $path = [Environment]::GetEnvironmentVariable("PATH", "Process")
    $newItems = $path.Split(';') | Where-Object { $_.ToString() -inotlike $VariableToRemove }
    [Environment]::SetEnvironmentVariable("PATH", [System.String]::Join(';', $newItems), "Process")
}

$ScriptDir = Get-ScriptDirectory
Push-Location $ScriptDir

$dnxVersion = Get-DnxVersion $ScriptDir

# Clean
if(Test-Path .\artifacts) { Remove-Item .\artifacts -Force -Recurse }

# Remove the installed DNVM from the path and force use of
# per-user DNVM (which we can upgrade as needed without admin permissions)
Remove-PathVariable "*Program Files\Microsoft DNX\DNVM*"

if ($SkipInstall) {
	# Make sure per-user DNVM is installed
	Install-Dnvm

	# Install DNX
	dnvm install $dnxVersion -r CoreCLR -NoNative
	dnvm install $dnxVersion -r CLR -NoNative
}

# Use the dnxVersion we discovered before
dnvm use $dnxVersion -r CLR

# Package restore
Get-ChildItem -Path . -Filter *.xproj -Recurse | ForEach-Object { Restore-Packages $_.DirectoryName }

# Set build number
$env:DNX_BUILD_VERSION = @{ $true = $env:APPVEYOR_BUILD_NUMBER; $false = 1 }[$env:APPVEYOR_BUILD_NUMBER -ne $NULL];
Write-Host "##### Build number: " $env:DNX_BUILD_VERSION

#Update project version numbers - still buggy
#Update-ProjectVersions -DirectoryName "$ScriptDir" -ProductVersion $ProductVersion

# Build/package
Get-ChildItem -Path .\src -Filter *.xproj -Recurse | ForEach-Object { Build-Projects $_.DirectoryName }
Get-ChildItem -Path .\test -Filter *.xproj -Recurse | ForEach-Object { Build-TestProjects $_.DirectoryName }

# Test
Get-ChildItem -Path .\test -Filter *.xproj -Recurse | ForEach-Object { Test-Projects $_.DirectoryName }

# Switch to Core CLR
#dnvm use $dnxVersion -r CoreCLR

# Test again
#Get-ChildItem -Path .\test -Filter *.xproj -Recurse | ForEach-Object { Test-Projects $_.DirectoryName }

Pop-Location