@echo off
pushd "Y:\temp-ma"
if errorlevel 1 (
    echo Erreur: Impossible d'acc‚der au dossier
    pause
    exit /b 1
)
for /d %%i in (*) do (
    if not exist "Y:\upload-ma\%%i.zip" (
        echo Compression du dossier %%i...
        powershell -command "Compress-Archive -Path '%%~fi' -DestinationPath 'Y:\upload-ma\%%i.zip' -Force"
    ) else (
        echo Le fichier Y:\upload-ma\%%i.zip existe d‚j…, passage...
    )
)
echo Toutes les archives ZIP ont ‚t‚ cr‚‚es avec succŠs.
