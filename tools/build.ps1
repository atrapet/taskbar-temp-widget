# Compiles Widget.exe with the C# compiler that ships with the .NET Framework.
# No .NET SDK, no NuGet, no build system -- csc.exe is present on every Windows
# install, so this repo has zero build dependencies.

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $repo 'src\Widget.cs'
$out  = Join-Path $repo 'src\Widget.exe'

$fw  = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $fw 'csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }

# The widget is normally running, and csc cannot overwrite a loaded image --
# it reports CS0016, which does not hint at the cause. Say so plainly instead.
if (Get-Process Widget -ErrorAction SilentlyContinue) {
    throw 'Widget.exe is running and cannot be overwritten. Stop it first: Get-Process Widget | Stop-Process'
}

# The source contains non-ASCII literals (the degree sign and a triangle
# glyph). Without a UTF-8 BOM csc decodes them as ANSI and they render wrong,
# so make sure the BOM is there before compiling.
$text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($src, $text, (New-Object System.Text.UTF8Encoding($true)))

# No manual quoting here: PowerShell quotes each element of a splatted array
# when calling a native executable. Adding quotes ourselves makes them part of
# the value and csc rejects the path as invalid.
$refs = @(
    "$fw\WPF\PresentationFramework.dll"
    "$fw\WPF\PresentationCore.dll"
    "$fw\WPF\WindowsBase.dll"
    "$fw\System.Xaml.dll"
    "$fw\System.dll"
    "$fw\System.Core.dll"
) | ForEach-Object { '/reference:' + $_ }

# /target:winexe keeps a console window from flashing on launch.
$argList = @(
    '/nologo'
    '/target:winexe'
    '/platform:x64'
    '/optimize+'
    ('/out:' + $out)
) + $refs + @($src)

Write-Host "compiling $src"
& $csc @argList
if ($LASTEXITCODE -ne 0) { throw "compilation failed (exit $LASTEXITCODE)" }

$size = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host "built $out  ($size KB)"
