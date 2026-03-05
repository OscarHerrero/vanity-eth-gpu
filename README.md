# Vanity ETH Address Generator (GPU)

Generador de direcciones Ethereum personalizadas usando aceleración GPU NVIDIA CUDA.
Encuentra una dirección con el **prefijo** y/o **sufijo** hexadecimal que quieras, a velocidades de cientos de millones de intentos por segundo.

> **Solo GPUs NVIDIA** — Requiere CUDA (Compute Capability ≥ 5.0).
> Las GPUs AMD no están soportadas.
> macOS no está soportado (NVIDIA dejó CUDA en macOS tras la versión 10.2).

---

## Descarga rápida (Windows)

Si tienes Windows y una GPU NVIDIA RTX 20xx o superior, puedes descargar el binario precompilado directamente:

**[Descargar vanity_eth.exe](https://github.com/OscarHerrero/vanity-eth-gpu/releases/latest/download/vanity_eth.exe)**

No necesitas instalar CUDA Toolkit ni Visual Studio. Descarga, ejecuta y listo.

> Para GTX 10xx o inferiores, o para Linux, compila desde el código fuente (ver [Compilación](#compilación)).

---

## Índice

- [Requisitos](#requisitos)
- [Instalación de dependencias](#instalación-de-dependencias)
  - [Windows](#windows)
  - [Linux](#linux)
- [Compilación](#compilación)
  - [Windows](#compilación-en-windows)
  - [Linux](#compilación-en-linux)
- [Uso](#uso)
- [GPUs soportadas y arquitecturas CUDA](#gpus-soportadas-y-arquitecturas-cuda)
- [Rendimiento](#rendimiento)
- [Control de ventiladores](#control-de-ventiladores)
- [Probabilidad y tiempos estimados](#probabilidad-y-tiempos-estimados)
- [Seguridad](#seguridad)
- [Estructura del proyecto](#estructura-del-proyecto)

---

## Requisitos

### Todos los sistemas

| Componente | Mínimo |
|---|---|
| GPU | NVIDIA, Compute Capability ≥ 5.0 (GTX 750 Ti / GTX 900 / GTX 10xx o posterior) |
| Driver NVIDIA | 520+ (recomendado 560+) |
| CUDA Toolkit | 11.0+ (12.x recomendado) |
| RAM | 4 GB |

### Windows (adicional)

| Componente | Versión |
|---|---|
| Sistema operativo | Windows 10 / 11 (64-bit) |
| Visual Studio | 2019 o 2022 con el workload **"Desktop development with C++"** |

### Linux (adicional)

| Componente | Versión |
|---|---|
| Sistema operativo | Ubuntu 20.04+, Debian 11+, Arch, Fedora… (64-bit) |
| Compilador C++ | GCC 9+ (normalmente incluido en `build-essential`) |

---

## Instalación de dependencias

### Windows

#### 1. Instalar CUDA Toolkit

Descarga desde: **https://developer.nvidia.com/cuda-downloads**

Selecciona: `Windows → x86_64 → tu versión de Windows → exe (local)`.

Sigue el instalador. CUDA Toolkit incluye `nvcc` (el compilador de NVIDIA).

#### 2. Instalar Visual Studio

Descarga **Visual Studio 2022 Community** (gratuito):
**https://visualstudio.microsoft.com/**

Durante la instalación, selecciona el workload:
**"Desarrollo para el escritorio con C++"** (Desktop development with C++)

> También vale Visual Studio 2019. Solo se necesita el compilador C++ (`cl.exe`), no el IDE completo.

#### 3. Verificar la instalación

Abre un terminal (cmd o PowerShell) y ejecuta:

```bat
nvcc --version
nvidia-smi
```

Debes ver la versión de CUDA y la información de tu GPU.

---

### Linux

#### Ubuntu / Debian

```bash
# Instalar herramientas de compilación
sudo apt update && sudo apt install -y build-essential

# Instalar CUDA Toolkit (ejemplo para Ubuntu 22.04)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update && sudo apt install -y cuda-toolkit

# Añadir CUDA al PATH (añadir a ~/.bashrc o ~/.zshrc para que persista)
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc
```

> Para otras versiones de Ubuntu o instrucciones específicas visita:
> https://developer.nvidia.com/cuda-downloads (selecciona tu distribución)

#### Arch Linux / Manjaro

```bash
sudo pacman -S cuda base-devel

# Añadir al PATH
echo 'export PATH=/opt/cuda/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

#### Fedora / RHEL / CentOS

```bash
# Sigue las instrucciones en: https://developer.nvidia.com/cuda-downloads
# Selecciona: Linux → x86_64 → tu distribución → rpm (network)

# Ejemplo Fedora 38+:
sudo dnf install cuda-toolkit
```

#### Verificar la instalación (Linux)

```bash
nvcc --version
nvidia-smi
```

---

## Compilación

### Compilación en Windows

Desde la **raíz del proyecto**, ejecuta:

```bat
build.bat
```

El script automáticamente:
1. Verifica que `nvcc` esté disponible.
2. Detecta la arquitectura de tu GPU con `nvidia-smi`.
3. Compila y genera `vanity_eth.exe`.

**Si `nvcc` no está en el PATH**, ábrelo desde:
*Inicio → Visual Studio 2022 → "x64 Native Tools Command Prompt for VS 2022"*
y navega al directorio del proyecto antes de ejecutar `build.bat`.

#### Compilación manual en Windows

```bat
nvcc -O3 -arch=sm_86 -o vanity_eth.exe src/main.cu -lcuda
```

Sustituye `sm_86` por la arquitectura de tu GPU (ver [tabla](#gpus-soportadas-y-arquitecturas-cuda)).

---

### Compilación en Linux

#### Opción 1: Script automático

```bash
chmod +x build.sh
./build.sh
```

#### Opción 2: Makefile

```bash
make
```

Ambas opciones auto-detectan la arquitectura de tu GPU con `nvidia-smi`.

#### Opción 3: Makefile con arquitectura manual

```bash
make ARCH=sm_86   # RTX 30xx
make ARCH=sm_89   # RTX 40xx
make ARCH=sm_75   # RTX 20xx / GTX 16xx
make ARCH=sm_61   # GTX 10xx
```

#### Opción 4: Compilación manual en Linux

```bash
nvcc -O3 -arch=sm_86 -o vanity_eth src/main.cu -lcuda
```

#### Limpiar archivos de compilación

```bash
make clean
```

---

## Uso

### Windows

```bat
vanity_eth.exe [opciones]
```

### Linux

```bash
./vanity_eth [opciones]
```

### Opciones

| Parámetro | Descripción | Defecto |
|---|---|---|
| `-p <hex>` | Prefijo hexadecimal a buscar (sin `0x`) | — |
| `-s <hex>` | Sufijo hexadecimal a buscar (sin `0x`) | — |
| `-i` | Case insensitive: `a` y `A` se tratan igual | activo |
| `-c` | Case sensitive: distingue mayúsculas/minúsculas | — |
| `-t <N>` | Total de threads GPU (múltiplo de 256) | auto |
| `-f <0-100>` | Velocidad **máxima** de ventiladores en % (solo Windows + NVIDIA) | `100` |
| `-h` | Mostrar ayuda | — |

Se requiere al menos `-p` o `-s`.

### Ejemplos

```bash
# Dirección que empiece con "dead"
vanity_eth -p dead

# Dirección que termine en "beef"
vanity_eth -s beef

# Prefijo Y sufijo a la vez
vanity_eth -p dead -s beef

# Threads manuales y ventiladores con máximo al 80%
vanity_eth -p 1337 -t 19456 -f 80

# Sin control de ventiladores
vanity_eth -p cafe -f 0

# Case sensitive (busca exactamente "Dead...")
vanity_eth -p Dead -c
```

### Salida de ejemplo

```
=== Vanity ETH Address Generator ===
Prefijo: dead
Sufijo:  (ninguno)
Case sensitive: no

GPU: NVIDIA GeForce RTX 3060 Ti
Compute capability: 8.6
Threads totales: 19456  (76 bloques x 256 threads) [auto]

Ventiladores: control dinamico (max: 100%)

Buscando...
Comprobadas: 45 M | Vel: 2.30 M/s | Temp: 62C | Fan: 73% | 195W

=== ENCONTRADO! ===
Direccion:    0xdead1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
Clave privada: 0xabcdef...

Finalizado.
```

---

## GPUs soportadas y arquitecturas CUDA

### Tabla de arquitecturas

| Serie GPU | Compute Capability | `-arch` flag |
|---|---|---|
| GTX 750 / GTX 700 series (Kepler/Maxwell) | 3.5 – 5.0 | `sm_35` / `sm_50` |
| GTX 900 series (Maxwell) | 5.2 | `sm_52` |
| GTX 10xx (Pascal) | 6.1 | `sm_61` |
| GTX 16xx / RTX 20xx (Turing) | 7.5 | `sm_75` |
| RTX 30xx (Ampere) | 8.6 | `sm_86` |
| RTX 40xx (Ada Lovelace) | 8.9 | `sm_89` |
| RTX 50xx (Blackwell) | 10.0 | `sm_100` |

> **¿No sabes tu Compute Capability?** Ejecútalo en terminal:
> ```bash
> nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader
> ```

### Threads óptimos por GPU

El programa auto-detecta los threads al arrancar usando la fórmula `SMs × 2 × 256`.
Usa `-t` solo si quieres ajustar manualmente.

> **Importante:** el rendimiento es óptimo con threads que sean **múltiplo exacto del número de SMs × 256**.
> El valor auto (2× SMs) es el punto mínimo garantizado. El sugerido (3× SMs) da un ~3% más.

| GPU | SMs | Threads auto (2×) | `-t` sugerido (3×) |
|---|---|---|---|
| RTX 4090 | 128 | 65,536 | 98,304 |
| RTX 4080 Super | 80 | 40,960 | 61,440 |
| RTX 4080 | 76 | 38,912 | 58,368 |
| RTX 4070 Ti Super | 66 | 33,792 | 50,688 |
| RTX 4070 Ti | 60 | 30,720 | 46,080 |
| RTX 4070 Super | 56 | 28,672 | 43,008 |
| RTX 4070 | 46 | 23,552 | 35,328 |
| RTX 4060 Ti | 34 | 17,408 | 26,112 |
| RTX 3090 Ti / 3090 | 82 | 41,984 | 62,976 |
| RTX 3080 Ti | 80 | 40,960 | 61,440 |
| RTX 3080 | 68 | 34,816 | 52,224 |
| RTX 3070 Ti / 3070 | 46 | 23,552 | 35,328 |
| **RTX 3060 Ti** | **38** | **19,456** | **29,184** |
| RTX 3060 | 28 | 14,336 | 21,504 |
| RTX 2080 Ti | 68 | 34,816 | 52,224 |
| RTX 2080 Super | 48 | 24,576 | 36,864 |
| RTX 2070 | 36 | 18,432 | 27,648 |
| GTX 1080 Ti | 28 | 14,336 | 21,504 |
| GTX 1080 | 20 | 10,240 | 15,360 |
| GTX 1070 | 15 | 7,680 | 11,520 |
| GTX 1060 6GB | 10 | 5,120 | 7,680 |

---

## Rendimiento

Velocidades aproximadas (pueden variar según driver, temperatura y configuración):

| GPU | M addr/s aprox. |
|---|---|
| RTX 4090 | ~8 M/s |
| RTX 4080 | ~6.5 M/s |
| RTX 3090 | ~5 M/s |
| RTX 3080 | ~4 M/s |
| **RTX 3060 Ti** | **~2.3 M/s** ✓ medido |
| RTX 3060 | ~1.7 M/s |
| RTX 2080 Ti | ~4 M/s |
| GTX 1080 Ti | ~1.7 M/s |
| GTX 1070 | ~0.9 M/s |

> Valores estimados escalando por número de SMs, excepto RTX 3060 Ti que es valor medido.
> La arquitectura también influye: RTX 40xx puede rendir más de lo estimado.

---

## Control de ventiladores y monitorización

- Disponible **solo en Windows** con GPU NVIDIA. En Linux el programa funciona normalmente sin tocar los ventiladores.
- Usa la librería NVML (carga dinámica, no requiere instalar nada extra ni permisos especiales).
- No se requiere ejecutar como Administrador.
- Si aparece "control no disponible", actualiza los drivers NVIDIA (520+).

### Control dinámico por temperatura

El programa ajusta los ventiladores automáticamente según la temperatura de la GPU:

| Temperatura | Velocidad ventilador |
|---|---|
| ≤ 55°C | 50% |
| 62°C | ~73% |
| ≥ 70°C | 100% |

El parámetro `-f` es el **límite máximo** (ej: `-f 80` nunca superará el 80% aunque la GPU llegue a 70°C).
Usa `-f 0` para desactivar el control de ventiladores completamente.

Al terminar o pulsar `Ctrl+C`, los ventiladores vuelven al modo automático de la GPU.

### Monitorización en tiempo real

Cuando NVML está disponible (control de ventiladores activo), la línea de progreso muestra:
```
Comprobadas: 45 M | Vel: 2.30 M/s | Temp: 62C | Fan: 73% | 195W
```
- **Temp**: temperatura actual de la GPU en °C
- **Fan**: velocidad de ventiladores actualmente aplicada
- **W**: consumo eléctrico de la GPU en vatios

> Con `-f 0` no se inicializa NVML y no se muestran temperatura ni vatios.

**En Linux**, para controlar ventiladores manualmente usa `nvidia-settings` o `nvidia-smi`:
```bash
# Ver temperatura
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader

# Controlar ventiladores (requiere X server y configuración previa)
nvidia-settings -a "[gpu:0]/GPUFanControlState=1" -a "[fan:0]/GPUTargetFanSpeed=80"
```

---

## Probabilidad y tiempos estimados

Cada carácter hex reduce la probabilidad en 1/16 (prefijos y sufijos son independientes).

| Longitud | Probabilidad | RTX 3060 Ti (~2.3 M/s) | RTX 4090 (~8 M/s) |
|---|---|---|---|
| 1 hex | 1/16 | < 1 segundo | < 1 segundo |
| 2 hex | 1/256 | < 1 segundo | < 1 segundo |
| 3 hex | 1/4,096 | < 1 segundo | < 1 segundo |
| 4 hex | 1/65,536 | < 1 segundo | < 1 segundo |
| 5 hex | 1/1,048,576 | ~1 segundo | < 1 segundo |
| 6 hex | 1/16,777,216 | ~7 segundos | ~2 segundos |
| 7 hex | 1/268,435,456 | ~2 minutos | ~30 segundos |
| 8 hex | 1/4,294,967,296 | ~31 minutos | ~9 minutos |

> Tiempos promedio estadístico. El resultado puede llegar antes o después.
> Con prefijo **y** sufijo simultáneos, multiplica las probabilidades.

---

## Seguridad

- La clave privada **nunca se transmite ni guarda** en ningún fichero automáticamente; aparece solo en pantalla.
- Anota la clave privada inmediatamente en un lugar seguro (gestor de contraseñas, papel, etc.).
- **Nunca compartas tu clave privada con nadie.**
- Para importar en MetaMask: *Importar cuenta → Clave privada*.
- Usa este programa en un equipo de confianza, sin malware.

---

## Estructura del proyecto

```
vanity_eth_gpu/
├── src/
│   ├── main.cu          # Punto de entrada, kernel launcher, CLI
│   ├── secp256k1.cuh    # Operaciones de curva elíptica secp256k1 (GPU)
│   ├── uint256.cuh      # Aritmética de 256 bits (GPU)
│   ├── keccak256.cuh    # Hash Keccak-256 (GPU)
│   └── matcher.cuh      # Comparación de prefijo/sufijo (GPU)
├── build.bat            # Script de compilación para Windows
├── build.sh             # Script de compilación para Linux
├── Makefile             # Makefile para Linux
└── README.md
```

---

## Preguntas frecuentes

**¿Funciona en un PC sin tarjeta gráfica?**
No. El programa necesita una GPU NVIDIA para ejecutarse. Sin ella, compilará sin problemas pero al lanzarlo mostrará:
```
Error: No se encontro ninguna GPU NVIDIA compatible con CUDA.
```
No hay modo CPU alternativo. Las GPUs AMD e Intel tampoco son compatibles (CUDA es tecnología exclusiva de NVIDIA).

**¿Funciona en una máquina virtual (VM)?**
Solo si la VM tiene passthrough de GPU NVIDIA configurado correctamente. En VMs sin passthrough (VirtualBox, VMware sin GPU passthrough) no funcionará.

**¿Puedo compilar en un PC sin GPU?**
Sí. La compilación con `nvcc` no requiere GPU, solo CUDA Toolkit instalado.

**¿Por qué no soporta AMD?**
El código usa la API CUDA, exclusiva de NVIDIA. Portarlo a AMD requeriría reescribir todo usando HIP (el equivalente de AMD), lo cual es un proyecto separado.

---

## Invítame a un café

Si este proyecto te ha sido útil, puedes invitarme a un café enviando ETH a:

```
0x09A94F7F1Af24aeaf182a74B70B4e4f5298f0da0
```

¡Gracias!

---

## Aviso legal

Este software se proporciona **tal cual**, sin garantías de ningún tipo.

- El autor no se hace responsable de ningún daño en el hardware (GPU, sistema de refrigeración u otros componentes) derivado del uso de este programa, incluyendo el uso sin el control de ventiladores activo o sin permisos de administrador.
- Es responsabilidad del usuario asegurarse de que su equipo cuenta con una refrigeración adecuada durante el uso prolongado.
- El uso de este software implica la aceptación de estos términos.

---

## Licencia

MIT — úsalo libremente, modifícalo y compártelo.
