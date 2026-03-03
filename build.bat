@echo off
setlocal enabledelayedexpansion

echo === Vanity ETH Address Generator - Build (Windows) ===
echo.

REM ─────────────────────────────────────────────────────────────────────────────
REM 1. Verificar que nvcc este en el PATH
REM ─────────────────────────────────────────────────────────────────────────────
where nvcc >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] nvcc no encontrado en PATH.
    echo.
    echo Opciones para resolverlo:
    echo   a) Instala CUDA Toolkit:
    echo        https://developer.nvidia.com/cuda-downloads
    echo.
    echo   b) Si ya esta instalado, ejecuta este script desde:
    echo        Inicio ^> Visual Studio 2022 ^> x64 Native Tools Command Prompt for VS 2022
    echo      O busca "x64 Native Tools" en el menu de inicio.
    echo.
    echo   c) Tambien puedes ejecutar manualmente:
    echo        nvcc -O3 -arch=sm_86 -o vanity_eth.exe src/main.cu -lcuda
    echo      (cambia sm_86 segun tu GPU, ver README.md)
    echo.
    pause
    exit /b 1
)

for /f "tokens=5 delims= " %%V in ('nvcc --version ^| findstr "release"') do (
    if "!NVCC_VER!"=="" set NVCC_VER=%%V
)
echo nvcc: !NVCC_VER!

REM ─────────────────────────────────────────────────────────────────────────────
REM 2. Auto-detectar arquitectura de la GPU con nvidia-smi
REM ─────────────────────────────────────────────────────────────────────────────
set ARCH_FLAG=
set COMPUTE_CAP=

for /f "tokens=*" %%C in ('nvidia-smi --query-gpu^=compute_cap --format^=csv^,noheader 2^>nul') do (
    if "!COMPUTE_CAP!"=="" set COMPUTE_CAP=%%C
)

if not "!COMPUTE_CAP!"=="" (
    REM Eliminar el punto: "8.6" -> "86"
    set SM_NUM=!COMPUTE_CAP:.=!
    set ARCH_FLAG=-arch=sm_!SM_NUM!

    for /f "tokens=*" %%N in ('nvidia-smi --query-gpu^=name --format^=csv^,noheader 2^>nul') do (
        if "!GPU_NAME!"=="" set GPU_NAME=%%N
    )
    echo GPU detectada: !GPU_NAME! ^(compute !COMPUTE_CAP!^)
    echo Arquitectura:  sm_!SM_NUM! ^(auto^)
) else (
    echo [AVISO] No se pudo detectar la GPU con nvidia-smi.
    echo         Compilando sin -arch ^(nvcc usara sm_52 por defecto^).
    echo         Si hay errores, edita build.bat y cambia la linea nvcc a:
    echo           nvcc -O3 -arch=sm_XX -o vanity_eth.exe src/main.cu -lcuda
    echo         Ver tabla de arquitecturas en README.md
)

echo.

REM ─────────────────────────────────────────────────────────────────────────────
REM 3. Compilar
REM ─────────────────────────────────────────────────────────────────────────────
echo Comando: nvcc -O3 !ARCH_FLAG! -o vanity_eth.exe src/main.cu -lcuda
echo.

nvcc -O3 !ARCH_FLAG! -o vanity_eth.exe src/main.cu -lcuda

if %errorlevel% equ 0 (
    echo.
    echo === Compilacion exitosa! ===
    echo Ejecutable: vanity_eth.exe
    echo.
    echo Uso rapido:
    echo   vanity_eth.exe -p dead -s beef
    echo   vanity_eth.exe -p 1337
    echo   vanity_eth.exe -h
) else (
    echo.
    echo [ERROR] Compilacion fallida.
    echo.
    echo Posibles causas:
    echo   - Falta el compilador C++. Ejecuta desde:
    echo       "x64 Native Tools Command Prompt for VS 2022"
    echo     o instala Visual Studio con "Desktop development with C++"
    echo   - Arquitectura incompatible. Prueba especificando manualmente:
    echo       nvcc -O3 -arch=sm_86 -o vanity_eth.exe src/main.cu -lcuda
    echo     Ver tabla de arquitecturas en README.md
)

echo.
pause
