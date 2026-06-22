Add-Type -AssemblyName System.IO.Compression.FileSystem
$src = 'd:\gz\new\build\windows\x64\runner\Release'
$dst = 'd:\gz\new\build\app.zip'

# 杀任何可能锁住文件或 .exe 的进程
Get-Process -Name "tvbox","node" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# 用 C# 强制删
try {
    [System.IO.File]::Delete($dst)
    Write-Output "[zip] old file deleted"
} catch {
    Write-Output ("[zip] delete failed: " + $_.Exception.Message)
    # 用垃圾回收尝试释放句柄
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2
    try {
        [System.IO.File]::Delete($dst)
        Write-Output "[zip] old file deleted (retry)"
    } catch {
        Write-Output ("[zip] delete failed again: " + $_.Exception.Message)
        exit 1
    }
}

# 创建新 zip
[System.IO.Compression.ZipFile]::CreateFromDirectory($src, $dst, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$fi = Get-Item $dst
Write-Output ("[zip] created: " + $dst + " (" + $fi.Length + " bytes) " + $fi.LastWriteTime)

# 验证
$a = [System.IO.Compression.ZipFile]::OpenRead($dst)
Write-Output ("[zip] total entries: " + $a.Entries.Count)
$i = 0
foreach ($e in $a.Entries) {
    $i++
    if ($i -le 3) { Write-Output ("[zip] [" + $i + "] " + $e.FullName) }
}
$a.Dispose()
