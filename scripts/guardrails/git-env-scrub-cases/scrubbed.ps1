# GREEN: every repository-redirecting variable is removed before git runs.
param([string]$Repo)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
foreach ($v in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
    'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX',
    'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE',
    'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT') {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
$top = & git -C $Repo rev-parse --show-toplevel
Write-Output $top
