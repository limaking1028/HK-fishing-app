# 用法：喺 Bubblewrap 項目資料夾（有 app\build.gradle 嗰個）執行：
#   powershell -ExecutionPolicy Bypass -File <呢個 repo>\android-overrides\apply.ps1
# 每次 `bubblewrap update` 之後都要再行一次（update 會重新生成 DelegationService.java）。
$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "app\src\main\java\app\hkfishing\twa"
$dst = "app\src\main\java\app\hkfishing\twa"
if (!(Test-Path "app\build.gradle")) { throw "請喺 Bubblewrap 項目資料夾執行（搵唔到 app\build.gradle）" }
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item "$src\HkLocationHandler.java" $dst -Force
Copy-Item "$src\DelegationService.java" $dst -Force
$g = Get-Content "app\build.gradle" -Raw
if ($g -notmatch "play-services-location") {
  $g = $g -replace "(dependencies\s*\{)", "`$1`n    implementation 'com.google.android.gms:play-services-location:21.0.1'"
  Set-Content "app\build.gradle" $g -Encoding UTF8
}
Write-Host "已套用：HkLocationHandler.java、DelegationService.java、play-services-location 依賴"
