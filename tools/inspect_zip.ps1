Add-Type -AssemblyName System.IO.Compression.FileSystem
$a = [System.IO.Compression.ZipFile]::OpenRead('d:\gz\new\build\app.zip')
Write-Output ("[inspect] total entries: " + $a.Entries.Count)
$i = 0
foreach ($e in $a.Entries) {
    $i++
    if ($i -le 5 -or $i -gt 63) {
        Write-Output ("[" + $i + "] " + $e.FullName)
    }
}
$a.Dispose()
