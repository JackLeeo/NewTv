Add-Type -AssemblyName System.IO.Compression.FileSystem
$src = 'd:\gz\new\build\app.zip'
$dst = 'd:\gz\new\build\app.fixed.zip'

if (Test-Path $dst) { Remove-Item $dst -Force }

$srcArchive = [System.IO.Compression.ZipFile]::OpenRead($src)
$dstStream = [System.IO.File]::Create($dst)
$dstArchive = New-Object System.IO.Compression.ZipArchive($dstStream, [System.IO.Compression.ZipArchiveMode]::Create)

# 收集所有 entry 的顶级目录前缀（处理 \ 和 / 两种分隔符）
$topPrefix = ''
$prefixCounts = @{}
foreach ($e in $srcArchive.Entries) {
    $name = $e.FullName
    # 找第一个分隔符
    $idx = -1
    for ($k = 0; $k -lt $name.Length; $k++) {
        $ch = $name[$k]
        if ($ch -eq '\' -or $ch -eq '/') { $idx = $k; break }
    }
    if ($idx -gt 0) {
        $pfx = $name.Substring(0, $idx)
        if (-not $prefixCounts.ContainsKey($pfx)) { $prefixCounts[$pfx] = 0 }
        $prefixCounts[$pfx]++
    }
}
Write-Output "[rewriter] prefix counts:"
foreach ($k in $prefixCounts.Keys) {
    Write-Output ("  " + $k + " = " + $prefixCounts[$k])
}
# 如果有且仅有一个顶级目录且覆盖绝大多数 entry，则去掉
if ($prefixCounts.Count -eq 1) {
    $single = ''
    $singleCount = 0
    foreach ($k in $prefixCounts.Keys) { $single = $k; $singleCount = $prefixCounts[$k] }
    if ($singleCount -eq $srcArchive.Entries.Count) {
        $topPrefix = $single
        Write-Output ("[rewriter] will strip top prefix: " + $topPrefix)
    }
}

$count = 0
foreach ($entry in $srcArchive.Entries) {
    $origName = $entry.FullName
    $newName = $origName
    if ($topPrefix -ne '') {
        # 跳过 "TopDir\" 或 "TopDir/"
        if ($newName.StartsWith($topPrefix + '\')) {
            $newName = $newName.Substring($topPrefix.Length + 1)
        } elseif ($newName.StartsWith($topPrefix + '/')) {
            $newName = $newName.Substring($topPrefix.Length + 1)
        } elseif ($newName -eq $topPrefix) {
            continue
        }
    }
    if ($newName -eq '') { continue }
    # 把 zip 内的分隔符统一换成 /（zip 标准）
    $newName = $newName -replace '\\', '/'

    $newEntry = $dstArchive.CreateEntry($newName, [System.IO.Compression.CompressionLevel]::Optimal)
    if (-not $newName.EndsWith('/')) {
        $srcStream = $entry.Open()
        $dstEntry = $newEntry.Open()
        $srcStream.CopyTo($dstEntry)
        $dstEntry.Dispose()
        $srcStream.Dispose()
    }
    $count++
    if ($count % 20 -eq 0) { Write-Output ("[rewriter] rewritten " + $count) }
}
Write-Output ("[rewriter] total rewritten: " + $count)

$dstArchive.Dispose()
$dstStream.Dispose()
$srcArchive.Dispose()

$fi = Get-Item $dst
Write-Output ("[rewriter] saved to: " + $dst + " size: " + $fi.Length)
