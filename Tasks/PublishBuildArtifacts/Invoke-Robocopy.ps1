[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Target)

# This script translates the output from robocopy into UTF8. Node has limited
# built-in support for encodings.
#
# Robocopy uses the system default code page. The system default code page varies
# depending on the locale configuration. On an en-US box, the system default code
# page is Windows-1252.
#
# Note, on a typical en-US box, testing with the 'ç' character is a good way to
# determine whether data is passed correctly between processes. This is because
# the 'ç' character has a different code point across each of the common encodings
# on a typical en-US box, i.e.
#   1) the default console-output code page (IBM437)
#   2) the system default code page (i.e. CP_ACP) (Windows-1252)
#   3) UTF8

$ErrorActionPreference = 'Stop'

# Redefine the wrapper over STDOUT to use UTF8. Node expects UTF8 by default.
$stdout = [System.Console]::OpenStandardOutput()
$utf8 = New-Object System.Text.UTF8Encoding($false) # do not emit BOM
$writer = New-Object System.IO.StreamWriter($stdout, $utf8)
[System.Console]::SetOut($writer)

# All subsequent output must be written using [System.Console]::WriteLine(). In
# PowerShell 4, Write-Host and Out-Default do not consider the updated stream writer.

# Fixup the $Source and $Target due to a robocopy quirk with trailing backslashes.
#
# According to http://ss64.com/nt/robocopy.html:
#   If either the source or desination are a "quoted long foldername" do not include a
#   trailing backslash as this will be treated as an escape character, i.e. "C:\some path\"
#   will fail but "C:\some path\\" or "C:\some path\." or "C:\some path" will work.
#
# Furthermore, PowerShell implicitly double-quotes arguments to external commands only when the
# argument contains unquoted spaces.
#
# So we need to fixup trailing spaces when both: A) the path contains a space AND B) the path
# ends with a single backslash.
#
# Note, any spaces in the path will always be unquoted in this scenario. The upstream logic in
# publishbuildartifacts.ts explicitly removes double-quotes from the paths.
#
# Note, details on PowerShell quoting rules for external commands can be found in the
# source code here:
# https://github.com/PowerShell/PowerShell/blob/v0.6.0/src/System.Management.Automation/engine/NativeCommandParameterBinder.cs
function Update-PathArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path)

    # Test whether the path contains a space and ends with a single backslash.
    if ($Path -like '* *\' -and $Path[-2] -ne '\') {
        return "$Path\"
    }

    return $Path
}
$Source = Update-PathArgument -Path $Source
$Target = Update-PathArgument -Path $Target

# Print the ##command.
[System.Console]::WriteLine("##[command]robocopy.exe /E /COPY:DA /NP /R:3 `"$Source`" `"$Target`" *")

# The $OutputEncoding variable instructs PowerShell how to interpret the output
# from the external command.
$OutputEncoding = [System.Text.Encoding]::Default

#             Usage :: ROBOCOPY source destination [file [file]...] [options]
#            source :: Source Directory (drive:\path or \\server\share\path).
#       destination :: Destination Dir  (drive:\path or \\server\share\path).
#              file :: File(s) to copy  (names/wildcards: default is "*.*").
#                /E :: copy subdirectories, including Empty ones.
# /COPY:copyflag[s] :: what to COPY for files (default is /COPY:DAT).
#                      (copyflags : D=Data, A=Attributes, T=Timestamps).
#                      (S=Security=NTFS ACLs, O=Owner info, U=aUditing info).
#               /NP :: No Progress - don't display percentage copied.
#              /R:n :: number of Retries on failed copies: default 1 million.
#
# Note, the output from robocopy needs to be iterated over. Otherwise PowerShell.exe
# will launch the external command in such a way that it inherits the streams.
& robocopy.exe /E /COPY:DA /NP /R:3 $Source $Target * 2>&1 |
    ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            [System.Console]::WriteLine($_.Exception.Message)
        }
        else {
            [System.Console]::WriteLine($_)
        }
    }
[System.Console]::WriteLine("##[debug]robocopy exit code '$LASTEXITCODE'")
[System.Console]::Out.Flush()
if ($LASTEXITCODE -ge 8) {
    exit $LASTEXITCODE
}