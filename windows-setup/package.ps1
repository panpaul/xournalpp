# Windows packaging script

# Environment variables:
# - VCPKG_ROOT: path to vcpkg installation
# - VCPKG_TRIPLET: default triplet to use for vcpkg
# - TARGET_ARCH: target architecture passing to cmake
# - IMAGE_MAGICK_DIR: path to ImageMagick executables
# - ICON_THEME_DIR: path to icon theme directory

$InformationPreference = 'Continue'
$ErrorActionPreference = 'Stop'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") { "x64" } else { "arm64" }
function CheckLastExitCode {
	if ($LASTEXITCODE -ne 0) {
		Write-Error "Last exit code: $LASTEXITCODE, callstack: $(Get-PSCallStack | Out-String)"
		exit $LASTEXITCODE
	}
}

# 1. Check environment

# 1.1 Check required environment variables
if (-not $env:VCPKG_TRIPLET) { Write-Error "VCPKG_TRIPLET not set" }
if (-not $env:TARGET_ARCH) { Write-Error "TARGET_ARCH not set" }
if (-not $env:IMAGE_MAGICK_DIR) { Write-Error "IMAGE_MAGICK_DIR not set" }
if (-not $env:ICON_THEME_DIR) { Write-Error "ICON_THEME_DIR not set" }

# 1.2 Find vcpkg
if (-not ($env:VCPKG_ROOT)) {
	$vcpkg = Get-Command vcpkg -ErrorAction SilentlyContinue
	if ($vcpkg) { $VCPKG_ROOT = $vcpkg.Path -replace '\\vcpkg.exe$' }
	else { Write-Error "vcpkg not found" }
} else { $VCPKG_ROOT = $env:VCPKG_ROOT }

# 2. Configure & Build

# 2.1 Clean
Remove-Item -Recurse -Force dist    -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force build   -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force install -ErrorAction SilentlyContinue
New-Item -Type Directory -Name dist    | Out-Null
New-Item -Type Directory -Name build   | Out-Null
New-Item -Type Directory -Name install | Out-Null

# 2.2 Configure
Write-Information "Configuring"
$env:GETTEXT_TOOL_DIR = "$VCPKG_ROOT\installed\$arch-windows\tools\gettext\bin"
& cmake -B build -S ..                                                                      `
    -T ClangCl                                                                              `
    -A $env:TARGET_ARCH                                                                     `
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT\scripts\buildsystems\vcpkg.cmake"                   `
    -DCMAKE_BUILD_TYPE=Release                                                              `
    -DCMAKE_INSTALL_PREFIX="$PWD\install"                                                   `
    -DPKG_CONFIG_EXECUTABLE="$VCPKG_ROOT\installed\$arch-windows\tools\pkgconf\pkgconf.exe" `
    -DImageMagick_EXECUTABLE_DIR="$env:IMAGE_MAGICK_DIR"
CheckLastExitCode

# 2.3 Build
Write-Information "Building"
& cmake --build build --config Release -- "-p:UseMultiToolTask=true" "-p:CL_MPCount=8"
CheckLastExitCode
& cmake --build build --config Release --target install
CheckLastExitCode

# 3 Package
Write-Information "Packaging"

# 3.1 copy binaries
New-Item -Type Directory -Name dist\bin | Out-Null
Copy-Item -Path build\Release\* -Destination dist\bin -Force

# 3.2 copy missing dependencies
$BASE_DIR = "$VCPKG_ROOT\installed\$env:VCPKG_TRIPLET"
foreach ($dll in @("croco-0.6.dll", "rsvg-2.dll")) {
    Copy-Item -Path "$BASE_DIR\bin\$dll" -Destination dist\bin -Force
}
foreach ($exe in @("gdbus.exe", "gspawn-win64-helper.exe", "gspawn-win64-helper-console.exe")) {
    Copy-Item -Path "$BASE_DIR\tools\glib\$exe" -Destination dist\bin -Force
}

# 3.3 copy lib
New-Item -Type Directory -Name dist\lib | Out-Null
Copy-Item -Path "$BASE_DIR\lib\gdk-pixbuf-2.0" -Destination dist\lib -Force -Recurse
Copy-Item -Path "loaders.cache" -Destination dist\lib\gdk-pixbuf-2.0\2.10.0 -Force
Pop-Location

# 3.4 copy share
New-Item -Type Directory -Name "dist\share" | Out-Null

# 3.4.1 glib-2.0 schema
Copy-Item -Path "$BASE_DIR\share\glib-2.0" -Destination "dist\share" -Force -Recurse
& "$VCPKG_ROOT\installed\$arch-windows\tools\glib\glib-compile-schemas.exe" "dist\share\glib-2.0\schemas"
CheckLastExitCode
Copy-Item -Path "dist\share\glib-2.0\schemas\gschemas.compiled" -Destination "dist\share" -Force
Remove-Item -Path "dist\share\glib-2.0\" -Recurse -Force
New-Item -Type Directory -Name "dist\share\glib-2.0\schemas" | Out-Null
Move-Item -Path "dist\share\gschemas.compiled" -Destination "dist\share\glib-2.0\schemas" -Force

# 3.4.2 xournalpp
Copy-Item -Path "install\share\*" -Destination "dist\share" -Force -Recurse

# 3.4.5 icons
New-Item -Type Directory -Name "dist\share\icons" | Out-Null
New-Item -Type Directory -Name "dist\share\icons\Adwaita" | Out-Null
New-Item -Type Directory -Name "dist\share\icons\hicolor" | Out-Null
Copy-Item -Path "$env:ICON_THEME_DIR\Adwaita\*" -Destination "dist\share\icons\Adwaita" -Force -Recurse -Container
Copy-Item -Path "$env:ICON_THEME_DIR\hicolor\*" -Destination "dist\share\icons\hicolor" -Force -Recurse -Container

# 3.6 bump version
$version = Get-Content -Path "build/VERSION" -TotalCount 1
Set-Content -Path xournalpp_version.nsh -Value "!define XOURNALPP_VERSION `"$version`""

# 3.7 create installer
& "C:\Program Files (x86)\NSIS\Bin\makensis.exe" xournalpp.nsi
CheckLastExitCode
