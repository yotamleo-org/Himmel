# RED: a PowerShell entry point that runs git with the inherited environment.
param([string]$Repo)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$top = & git -C $Repo rev-parse --show-toplevel
Write-Output $top
