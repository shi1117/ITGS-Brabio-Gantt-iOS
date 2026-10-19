Write-Host "=== ITGS iOS Signing Base64 Helper ===" -ForegroundColor Cyan
$p12 = Read-Host "請輸入 .p12 完整路徑"
$profile = Read-Host "請輸入 .mobileprovision 完整路徑"

if (!(Test-Path $p12)) { throw "找不到 .p12：$p12" }
if (!(Test-Path $profile)) { throw "找不到 .mobileprovision：$profile" }

$p12b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p12))
$profb64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($profile))

$p12Out = Join-Path $PWD "IOS_CERT_P12_BASE64.txt"
$profOut = Join-Path $PWD "IOS_PROVISION_PROFILE_BASE64.txt"

[IO.File]::WriteAllText($p12Out, $p12b64)
[IO.File]::WriteAllText($profOut, $profb64)

Write-Host "完成：" -ForegroundColor Green
Write-Host $p12Out
Write-Host $profOut
Write-Host "把文字內容貼到 GitHub Repository Secrets，不要上傳到公開 Repo。" -ForegroundColor Yellow
