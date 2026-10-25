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
$gf = Join-Path (Get-Location) "app\build.gradle"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$g = [IO.File]::ReadAllText($gf, $utf8)
if ($g -notmatch "play-services-location") {
  $g = $g -replace "(dependencies\s*\{)", "`$1`n    implementation 'com.google.android.gms:play-services-location:21.0.1'"
  [IO.File]::WriteAllText($gf, $g, $utf8)
}
# 喺 LauncherActivity 嘅 autoVerify VIEW intent-filter 後面加一個只配對根網址 "/" 嘅 filter（冇 autoVerify）。
# 原因：Chrome 嘅 InstalledWebappGeolocationBridge 用 origin 根（https://limaking1028.github.io/）搵 TWA；
# androidx TrustedWebActivityServiceConnectionPool 用 ACTION_VIEW + queryIntentActivities 解析 scope；
# Bubblewrap 範本對子路徑 scope 會加 pathPrefix，所以根網址配對唔到 →「No TWA candidates」→ 定位失敗。
# 參考：https://github.com/GoogleChromeLabs/bubblewrap/issues/1062
# 用 [IO.File] + 無 BOM UTF-8 讀寫，避免 Get-Content/Set-Content 整壞中文 launcherName。
$mf = Join-Path (Get-Location) "app\src\main\AndroidManifest.xml"
$m = [IO.File]::ReadAllText($mf, $utf8)
if ($m -match 'android:path="/"') {
  Write-Host "AndroidManifest.xml 已有根網址 filter，跳過"
} else {
  $rx = [regex]'(?s)<intent-filter\s+android:autoVerify="true"\s*>.*?</intent-filter>'
  $hit = $rx.Match($m)
  if (!$hit.Success) { throw "AndroidManifest.xml 搵唔到 LauncherActivity 嘅 autoVerify intent-filter，冇改動" }
  $filter = @"

            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https"
                    android:host="@string/hostName"
                    android:path="/"/>
            </intent-filter>
"@
  $m = $m.Insert($hit.Index + $hit.Length, $filter)
  [IO.File]::WriteAllText($mf, $m, $utf8)
  Write-Host "已加入根網址 intent-filter 到 AndroidManifest.xml"
}
Write-Host "已套用：HkLocationHandler.java、DelegationService.java、play-services-location 依賴"
