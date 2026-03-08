#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <cuda_runtime.h>

#include "uint256.cuh"
#include "secp256k1.cuh"
#include "keccak256.cuh"
#include "matcher.cuh"

// ============================================================
// Control de ventiladores via NVML (carga dinámica)
// NVML reemplaza la antigua NVAPI para GPUs modernas (RTX 30xx+)
// ============================================================
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// Tipos y punteros a funciones NVML (carga dinámica, sin necesidad de nvml.lib)
typedef void* nvmlDevice_t;
typedef int   nvmlReturn_t;
// Políticas de ventilador y temperatura
#define NVML_FAN_POLICY_TEMPERATURE_CONTINOUS_SW 0  // auto
#define NVML_FAN_POLICY_MANUAL                   1  // manual
#define NVML_TEMPERATURE_GPU                     0

typedef nvmlReturn_t (*pfnNvmlInit)(void);
typedef nvmlReturn_t (*pfnNvmlShutdown)(void);
typedef nvmlReturn_t (*pfnNvmlDeviceGetHandleByIndex)(unsigned int, nvmlDevice_t*);
typedef nvmlReturn_t (*pfnNvmlDeviceGetNumFans)(nvmlDevice_t, unsigned int*);
typedef nvmlReturn_t (*pfnNvmlDeviceSetFanControlPolicy)(nvmlDevice_t, unsigned int, unsigned int);
typedef nvmlReturn_t (*pfnNvmlDeviceSetFanSpeed_v2)(nvmlDevice_t, unsigned int, unsigned int);
typedef nvmlReturn_t (*pfnNvmlDeviceGetTemperature)(nvmlDevice_t, unsigned int, unsigned int*);
typedef nvmlReturn_t (*pfnNvmlDeviceGetPowerUsage)(nvmlDevice_t, unsigned int*);

static HMODULE      s_nvml_lib    = NULL;
static nvmlDevice_t s_nvml_device = NULL;
static unsigned int s_fan_count   = 0;
static int          s_fan_ready   = 0;

static pfnNvmlInit                      s_nvmlInit                   = NULL;
static pfnNvmlShutdown                  s_nvmlShutdown               = NULL;
static pfnNvmlDeviceGetHandleByIndex    s_nvmlDeviceGetHandleByIndex = NULL;
static pfnNvmlDeviceGetNumFans          s_nvmlDeviceGetNumFans       = NULL;
static pfnNvmlDeviceSetFanControlPolicy s_nvmlSetPolicy              = NULL;
static pfnNvmlDeviceSetFanSpeed_v2      s_nvmlSetFanSpeed            = NULL;
static pfnNvmlDeviceGetTemperature      s_nvmlGetTemp                = NULL;
static pfnNvmlDeviceGetPowerUsage       s_nvmlGetPower               = NULL;

static int fan_init(void) {
    // nvml.dll puede estar en System32 o en la carpeta de drivers NVIDIA
    const char* paths[] = {
        "nvml.dll",
        "C:\\Windows\\System32\\nvml.dll",
        "C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvml.dll",
        NULL
    };
    for (int p = 0; paths[p] && !s_nvml_lib; p++)
        s_nvml_lib = LoadLibraryA(paths[p]);
    if (!s_nvml_lib) return 0;

    s_nvmlInit                   = (pfnNvmlInit)                  GetProcAddress(s_nvml_lib, "nvmlInit_v2");
    s_nvmlShutdown               = (pfnNvmlShutdown)              GetProcAddress(s_nvml_lib, "nvmlShutdown");
    s_nvmlDeviceGetHandleByIndex = (pfnNvmlDeviceGetHandleByIndex)GetProcAddress(s_nvml_lib, "nvmlDeviceGetHandleByIndex_v2");
    s_nvmlDeviceGetNumFans       = (pfnNvmlDeviceGetNumFans)      GetProcAddress(s_nvml_lib, "nvmlDeviceGetNumFans");
    s_nvmlSetPolicy              = (pfnNvmlDeviceSetFanControlPolicy)GetProcAddress(s_nvml_lib, "nvmlDeviceSetFanControlPolicy");
    s_nvmlSetFanSpeed            = (pfnNvmlDeviceSetFanSpeed_v2)  GetProcAddress(s_nvml_lib, "nvmlDeviceSetFanSpeed_v2");
    s_nvmlGetTemp                = (pfnNvmlDeviceGetTemperature)   GetProcAddress(s_nvml_lib, "nvmlDeviceGetTemperature");
    s_nvmlGetPower               = (pfnNvmlDeviceGetPowerUsage)    GetProcAddress(s_nvml_lib, "nvmlDeviceGetPowerUsage");

    if (!s_nvmlInit || !s_nvmlShutdown || !s_nvmlDeviceGetHandleByIndex ||
        !s_nvmlDeviceGetNumFans || !s_nvmlSetPolicy || !s_nvmlSetFanSpeed) {
        FreeLibrary(s_nvml_lib); s_nvml_lib = NULL; return 0;
    }
    if (s_nvmlInit() != 0) { FreeLibrary(s_nvml_lib); s_nvml_lib = NULL; return 0; }
    if (s_nvmlDeviceGetHandleByIndex(0, &s_nvml_device) != 0) {
        s_nvmlShutdown(); FreeLibrary(s_nvml_lib); s_nvml_lib = NULL; return 0;
    }
    if (s_nvmlDeviceGetNumFans(s_nvml_device, &s_fan_count) != 0 || s_fan_count == 0) {
        s_nvmlShutdown(); FreeLibrary(s_nvml_lib); s_nvml_lib = NULL; return 0;
    }
    s_fan_ready = 1;
    return 1;
}

static void fan_set(int percent) {
    if (!s_fan_ready) return;
    for (unsigned int i = 0; i < s_fan_count; i++) {
        s_nvmlSetPolicy(s_nvml_device, i, NVML_FAN_POLICY_MANUAL);
        s_nvmlSetFanSpeed(s_nvml_device, i, (unsigned int)percent);
    }
}

// Devuelve temperatura GPU en °C, o -1 si no disponible
static int temp_read(void) {
    if (!s_fan_ready || !s_nvmlGetTemp) return -1;
    unsigned int t = 0;
    return (s_nvmlGetTemp(s_nvml_device, NVML_TEMPERATURE_GPU, &t) == 0) ? (int)t : -1;
}

// Devuelve consumo en vatios, o -1 si no disponible
static int power_read(void) {
    if (!s_fan_ready || !s_nvmlGetPower) return -1;
    unsigned int mw = 0;
    return (s_nvmlGetPower(s_nvml_device, &mw) == 0) ? (int)(mw / 1000) : -1;
}

// Curva agresiva: 50% a <=55°C, 100% a >=70°C. Devuelve el % aplicado.
static int fan_update_by_temp(int temp, int max_pct) {
    if (!s_fan_ready || temp < 0) return -1;
    int pct;
    if      (temp <= 55) pct = 50;
    else if (temp >= 70) pct = 100;
    else                 pct = 50 + (temp - 55) * 50 / 15;
    if (pct > max_pct) pct = max_pct;
    fan_set(pct);
    return pct;
}

static void fan_restore(void) {
    if (!s_fan_ready) return;
    for (unsigned int i = 0; i < s_fan_count; i++)
        s_nvmlSetPolicy(s_nvml_device, i, NVML_FAN_POLICY_TEMPERATURE_CONTINOUS_SW);
}

static void fan_cleanup(void) {
    fan_restore();
    if (s_fan_ready && s_nvmlShutdown) s_nvmlShutdown();
    if (s_nvml_lib) { FreeLibrary(s_nvml_lib); s_nvml_lib = NULL; }
    s_fan_ready = 0;
}

// Handler Ctrl+C: restaura ventiladores antes de salir
static void sig_handler(int sig) {
    (void)sig;
    printf("\n[!] Interrumpido. Restaurando ventiladores...\n");
    fan_cleanup();
    exit(1);
}

#else
static int  fan_init(void)       { return 0; }
static void fan_set(int p)       { (void)p; }
static void fan_restore(void)    {}
static void fan_cleanup(void)    {}
static void sig_handler(int sig) { (void)sig; exit(1); }
#endif

// Configuración
#define THREADS_PER_BLOCK 256
#define BLOCKS 256
#define ITERATIONS_PER_THREAD 1024
#define MAX_TARGETS 64

// Estructura para resultados encontrados
typedef struct {
    uint256_t private_key;
    uint8_t address[20];
    int found;
    int target_idx;   // índice del target que coincidió
} result_t;

// Patrones en constant memory
__constant__ pattern_t d_patterns[MAX_TARGETS];
__constant__ int       d_num_patterns;

// RNG xorshift128: periodo 2^128-1, permite explorar todo el espacio de claves privadas
__device__ uint32_t xorshift128(uint32_t s[4]) {
    uint32_t t = s[3];
    uint32_t tmp = s[0];
    s[3] = s[2];
    s[2] = s[1];
    s[1] = tmp;
    t ^= t << 11;
    t ^= t >> 8;
    s[0] = t ^ tmp ^ (tmp >> 19);
    return s[0];
}

// Kernel principal
__global__ void vanity_search_kernel(
    uint32_t* seeds,
    result_t* results,
    uint64_t* total_checked,
    int max_results
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    // Estado del RNG (128 bits = 4 x uint32)
    uint32_t s[4];
    s[0] = seeds[idx * 4 + 0];
    s[1] = seeds[idx * 4 + 1];
    s[2] = seeds[idx * 4 + 2];
    s[3] = seeds[idx * 4 + 3];
    
    // Clave privada
    uint256_t privkey;
    
    // Resultados locales
    int local_found = 0;
    
    for (int iter = 0; iter < ITERATIONS_PER_THREAD && local_found == 0; iter++) {
        // Generar clave privada aleatoria
        #pragma unroll
        for (int i = 0; i < 8; i++) {
            privkey.d[i] = xorshift128(s);
        }
        
        // Asegurar que la clave está en el rango válido [1, n-1]
        // Por simplicidad, solo nos aseguramos de que no sea 0
        if (uint256_is_zero(&privkey)) {
            privkey.d[0] = 1;
        }
        
        // Calcular clave pública: pubkey = privkey * G
        point_jacobian_t pub_jacobian;
        point_mul_generator(&pub_jacobian, &privkey);
        
        // Convertir a coordenadas afines
        point_affine_t pub_affine;
        point_jacobian_to_affine(&pub_affine, &pub_jacobian);
        
        // Calcular dirección Ethereum
        uint8_t address[20];
        get_eth_address(&pub_affine.x, &pub_affine.y, address);
        
        // Comprobar si coincide con algún target
        int matched = -1;
        for (int ti = 0; ti < d_num_patterns; ti++) {
            if (match_address(address, &d_patterns[ti])) {
                matched = ti;
                break;
            }
        }
        if (matched >= 0) {
            int slot = atomicAdd((int*)&results[0].found, 1);
            if (slot < max_results) {
                uint256_copy(&results[slot].private_key, &privkey);
                #pragma unroll
                for (int i = 0; i < 20; i++) {
                    results[slot].address[i] = address[i];
                }
                results[slot].target_idx = matched;
            }
            local_found = 1;
        }
    }
    
    // Guardar estado del RNG para la siguiente iteración
    seeds[idx * 4 + 0] = s[0];
    seeds[idx * 4 + 1] = s[1];
    seeds[idx * 4 + 2] = s[2];
    seeds[idx * 4 + 3] = s[3];
    
    // Actualizar contador total
    atomicAdd((unsigned long long*)total_checked, ITERATIONS_PER_THREAD);
}

void print_usage(const char* prog) {
    printf("Uso: %s [opciones]\n", prog);
    printf("Opciones:\n");
    printf("  -p <prefijo>      Prefijo hex a buscar (sin 0x). Repetible para multiples targets.\n");
    printf("  -s <sufijo>       Sufijo hex a buscar (sin 0x). Repetible para multiples targets.\n");
    printf("  --targets <file>  Cargar targets desde archivo (se acumulan con -p/-s)\n");
    printf("  -i                Case insensitive (por defecto)\n");
    printf("  -c                Case sensitive\n");
    printf("  -a                Buscar TODOS los targets (no para al primero)\n");
    printf("  -o <file>         Archivo de salida para resultados (defecto: found.txt)\n");
    printf("  -t <threads>      Total de threads GPU (multiplo de 256, defecto: auto)\n");
    printf("  -f <0-100>        Velocidad de ventiladores en %% (defecto: 100, 0=sin cambio)\n");
    printf("  -h                Mostrar esta ayuda\n");
    printf("\nEjemplos:\n");
    printf("  %s -p dead -s beef\n", prog);
    printf("  %s -p 0000 -s 1234 -p dead -s beef\n", prog);
    printf("  %s --targets targets.txt -a -o resultados.txt\n", prog);
    printf("\nFormato de archivo --targets (una linea por target):\n");
    printf("  # Comentario\n");
    printf("  0000 1234        <- prefijo y sufijo\n");
    printf("  dead -           <- solo prefijo\n");
    printf("  - beef           <- solo sufijo\n");
}

// Versiones host de las funciones de conversión
void host_address_to_hex(const uint8_t* address, char* hex_str) {
    const char hex_chars[] = "0123456789abcdef";
    for (int i = 0; i < 20; i++) {
        hex_str[i * 2] = hex_chars[address[i] >> 4];
        hex_str[i * 2 + 1] = hex_chars[address[i] & 0x0F];
    }
    hex_str[40] = '\0';
}

void host_privkey_to_hex(const uint256_t* key, char* hex_str) {
    const char hex_chars[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        uint32_t word = key->d[7 - i];
        hex_str[i * 8 + 0] = hex_chars[(word >> 28) & 0xF];
        hex_str[i * 8 + 1] = hex_chars[(word >> 24) & 0xF];
        hex_str[i * 8 + 2] = hex_chars[(word >> 20) & 0xF];
        hex_str[i * 8 + 3] = hex_chars[(word >> 16) & 0xF];
        hex_str[i * 8 + 4] = hex_chars[(word >> 12) & 0xF];
        hex_str[i * 8 + 5] = hex_chars[(word >> 8) & 0xF];
        hex_str[i * 8 + 6] = hex_chars[(word >> 4) & 0xF];
        hex_str[i * 8 + 7] = hex_chars[word & 0xF];
    }
    hex_str[64] = '\0';
}

// Convierte un string a minúsculas hex y parsea. Devuelve 0 ok, -1 error.
static int parse_pattern_str(const char* str, uint8_t* bytes, int* nibble_len) {
    char lower[41];
    int len = (int)strlen(str);
    if (len > 40) return -1;
    for (int i = 0; i < len; i++)
        lower[i] = (str[i] >= 'A' && str[i] <= 'F') ? str[i] + 32 : str[i];
    lower[len] = '\0';
    return parse_hex_pattern(lower, bytes, nibble_len);
}

// Añade un target al array. disp_pre/disp_suf guardan los strings originales para display.
// Devuelve 0 ok, -1 error.
static int add_target(pattern_t* patterns, char disp_pre[][41], char disp_suf[][41],
                      int* count, int case_sensitive,
                      const char* prefix, const char* suffix) {
    if (*count >= MAX_TARGETS) {
        printf("Aviso: maximo de targets (%d) alcanzado, ignorando el resto.\n", MAX_TARGETS);
        return 0;
    }
    pattern_t* p = &patterns[*count];
    memset(p, 0, sizeof(pattern_t));
    p->case_sensitive = case_sensitive;

    int has_prefix = (prefix && strlen(prefix) > 0 && strcmp(prefix, "-") != 0);
    int has_suffix = (suffix && strlen(suffix) > 0 && strcmp(suffix, "-") != 0);

    if (has_prefix) {
        if (parse_pattern_str(prefix, p->prefix, &p->prefix_len) < 0) {
            printf("Error: prefijo invalido '%s'\n", prefix);
            return -1;
        }
        strncpy(disp_pre[*count], prefix, 40);
        // normalizar a minúsculas para display
        for (int j = 0; disp_pre[*count][j]; j++)
            if (disp_pre[*count][j] >= 'A' && disp_pre[*count][j] <= 'F')
                disp_pre[*count][j] += 32;
    } else {
        disp_pre[*count][0] = '\0';
    }

    if (has_suffix) {
        if (parse_pattern_str(suffix, p->suffix, &p->suffix_len) < 0) {
            printf("Error: sufijo invalido '%s'\n", suffix);
            return -1;
        }
        strncpy(disp_suf[*count], suffix, 40);
        for (int j = 0; disp_suf[*count][j]; j++)
            if (disp_suf[*count][j] >= 'A' && disp_suf[*count][j] <= 'F')
                disp_suf[*count][j] += 32;
    } else {
        disp_suf[*count][0] = '\0';
    }

    if (p->prefix_len == 0 && p->suffix_len == 0) {
        printf("Error: target sin prefijo ni sufijo (usa - para omitir uno)\n");
        return -1;
    }
    (*count)++;
    return 0;
}

// Carga targets desde archivo. Formato por linea: <prefijo> <sufijo> (- para ninguno)
static int load_targets_file(const char* filename, pattern_t* patterns,
                             char disp_pre[][41], char disp_suf[][41],
                             int* count, int case_sensitive) {
    FILE* f = fopen(filename, "r");
    if (!f) {
        printf("Error: no se pudo abrir '%s'\n", filename);
        return -1;
    }
    char line[256];
    int line_num = 0;
    while (fgets(line, sizeof(line), f)) {
        line_num++;
        int len = (int)strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r' || line[len-1] == ' '))
            line[--len] = '\0';
        if (len == 0 || line[0] == '#') continue;

        char tok1[41] = "", tok2[41] = "";
        int n = sscanf(line, "%40s %40s", tok1, tok2);
        if (n < 1) continue;

        const char* pref = tok1;
        const char* suff = (n >= 2) ? tok2 : "-";

        if (add_target(patterns, disp_pre, disp_suf, count, case_sensitive, pref, suff) < 0) {
            printf("  (linea %d: '%s')\n", line_num, line);
            fclose(f);
            return -1;
        }
    }
    fclose(f);
    return 0;
}

// Mezcla de bits de alta calidad para expandir semillas
static uint64_t splitmix64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

// Rellena buf con n uint32 criptograficamente aleatorios
static void csprng_fill(uint32_t* buf, int n) {
#ifdef _WIN32
    // RtlGenRandom (SystemFunction036) via carga dinamica - disponible en todos los Windows
    typedef BOOLEAN (WINAPI* pRtlGenRandom_t)(PVOID, ULONG);
    HMODULE advapi = LoadLibraryA("Advapi32.dll");
    pRtlGenRandom_t pRtlGenRandom = advapi
        ? (pRtlGenRandom_t)GetProcAddress(advapi, "SystemFunction036") : NULL;
    if (pRtlGenRandom && pRtlGenRandom(buf, (ULONG)(n * sizeof(uint32_t)))) {
        FreeLibrary(advapi);
        return;
    }
    if (advapi) FreeLibrary(advapi);
    // Fallback: mezcla de fuentes de alta resolucion
    LARGE_INTEGER qpc;
    QueryPerformanceCounter(&qpc);
    uint64_t s0 = (uint64_t)qpc.QuadPart ^ ((uint64_t)GetCurrentProcessId() << 32);
    uint64_t s1 = (uint64_t)GetTickCount64() ^ ((uint64_t)time(NULL) * 6364136223846793005ULL);
    for (int i = 0; i < n; i++)
        buf[i] = (uint32_t)(splitmix64(s0 + (uint64_t)i) ^ splitmix64(s1 - (uint64_t)i));
#else
    FILE* f = fopen("/dev/urandom", "rb");
    if (f) {
        fread(buf, sizeof(uint32_t), n, f);
        fclose(f);
    } else {
        for (int i = 0; i < n; i++)
            buf[i] = (uint32_t)time(NULL) ^ (uint32_t)(i * 2654435761U);
    }
#endif
}

int main(int argc, char** argv) {
    // Parsear argumentos
    char cli_prefixes[MAX_TARGETS][41];
    char cli_suffixes[MAX_TARGETS][41];
    int  n_prefixes    = 0;
    int  n_suffixes    = 0;
    char targets_file[256] = "";
    char output_file[256]  = "found.txt";
    int  case_sensitive    = 0;
    int  search_all        = 0;
    int  total_threads     = 0;
    int  threads_user_set  = 0;
    int  fan_percent       = 100;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            if (n_prefixes < MAX_TARGETS) strncpy(cli_prefixes[n_prefixes++], argv[++i], 40);
            else { printf("Error: demasiados -p (max %d)\n", MAX_TARGETS); return 1; }
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            if (n_suffixes < MAX_TARGETS) strncpy(cli_suffixes[n_suffixes++], argv[++i], 40);
            else { printf("Error: demasiados -s (max %d)\n", MAX_TARGETS); return 1; }
        } else if (strcmp(argv[i], "--targets") == 0 && i + 1 < argc) {
            strncpy(targets_file, argv[++i], 255);
        } else if (strcmp(argv[i], "-a") == 0) {
            search_all = 1;
        } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            strncpy(output_file, argv[++i], 255);
        } else if (strcmp(argv[i], "-i") == 0) {
            case_sensitive = 0;
        } else if (strcmp(argv[i], "-c") == 0) {
            case_sensitive = 1;
        } else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            total_threads = atoi(argv[++i]);
            total_threads = ((total_threads + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK) * THREADS_PER_BLOCK;
            if (total_threads < THREADS_PER_BLOCK) total_threads = THREADS_PER_BLOCK;
            threads_user_set = 1;
        } else if (strcmp(argv[i], "-f") == 0 && i + 1 < argc) {
            fan_percent = atoi(argv[++i]);
            if (fan_percent < 0)   fan_percent = 0;
            if (fan_percent > 100) fan_percent = 100;
        } else if (strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
    }

    // Construir lista de patrones
    pattern_t h_patterns[MAX_TARGETS];
    char      disp_pre[MAX_TARGETS][41];
    char      disp_suf[MAX_TARGETS][41];
    int       h_num_patterns = 0;
    memset(disp_pre, 0, sizeof(disp_pre));
    memset(disp_suf, 0, sizeof(disp_suf));

    // Combinar -p y -s por índice (padding con "-" si hay diferente cantidad)
    int max_cli = n_prefixes > n_suffixes ? n_prefixes : n_suffixes;
    for (int i = 0; i < max_cli; i++) {
        const char* pref = (i < n_prefixes) ? cli_prefixes[i] : "-";
        const char* suff = (i < n_suffixes) ? cli_suffixes[i] : "-";
        if (add_target(h_patterns, disp_pre, disp_suf, &h_num_patterns, case_sensitive, pref, suff) < 0)
            return 1;
    }

    // Cargar desde archivo si se indicó
    if (strlen(targets_file) > 0) {
        if (load_targets_file(targets_file, h_patterns, disp_pre, disp_suf,
                              &h_num_patterns, case_sensitive) < 0)
            return 1;
    }

    if (h_num_patterns == 0) {
        printf("Error: Debes especificar al menos un target (-p, -s, o --targets)\n\n");
        print_usage(argv[0]);
        return 1;
    }

    // Mostrar targets cargados
    printf("=== Vanity ETH Address Generator ===\n");
    printf("Targets (%d):\n", h_num_patterns);
    for (int i = 0; i < h_num_patterns; i++) {
        const char* pstr = (strlen(disp_pre[i]) > 0) ? disp_pre[i] : "(ninguno)";
        const char* sstr = (strlen(disp_suf[i]) > 0) ? disp_suf[i] : "(ninguno)";
        printf("  [%d] prefijo: %-20s sufijo: %s\n", i, pstr, sstr);
    }
    printf("Case sensitive: %s\n\n", case_sensitive ? "si" : "no");

    // Verificar CUDA
    int device_count;
    cudaGetDeviceCount(&device_count);
    if (device_count == 0) {
        printf("Error: No se encontro ninguna GPU NVIDIA compatible con CUDA.\n\n");
        printf("Este programa requiere una GPU NVIDIA (Compute Capability >= 5.0).\n");
        printf("Las GPUs AMD, Intel y las graficas integradas no son compatibles.\n\n");
        printf("Si tienes una GPU NVIDIA instalada:\n");
        printf("  - Asegurate de tener los drivers NVIDIA actualizados (520+).\n");
        printf("  - Comprueba con: nvidia-smi\n");
        return 1;
    }
    
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);

    // Auto-detectar threads óptimos: 2x el nº de SMs garantiza reparto
    // simétrico (1 bloque por SM mínimo) con mínimo overhead
    if (!threads_user_set) {
        total_threads = prop.multiProcessorCount * 2 * THREADS_PER_BLOCK;
    }

    printf("GPU: %s\n", prop.name);
    printf("Compute capability: %d.%d\n", prop.major, prop.minor);
    printf("Threads totales: %d  (%d bloques x %d threads)%s\n\n",
           total_threads, total_threads / THREADS_PER_BLOCK, THREADS_PER_BLOCK,
           threads_user_set ? "" : " [auto]");

    // Inicializar control de ventiladores
    signal(SIGINT, sig_handler);
    if (fan_percent > 0) {
        if (fan_init()) {
            printf("Ventiladores: control dinamico (max: %d%%)\n\n", fan_percent);
        } else {
            printf("Ventiladores: control no disponible\n");
            printf("  (actualiza los drivers NVIDIA a 520+)\n\n");
        }
    } else {
        printf("Ventiladores: sin cambio (-f 0)\n\n");
    }
    
    // La tabla G_TABLE ya está inicializada en constant memory (secp256k1.cuh)

    // Copiar patrones a constant memory
    cudaMemcpyToSymbol(d_patterns,     h_patterns,     h_num_patterns * sizeof(pattern_t));
    cudaMemcpyToSymbol(d_num_patterns, &h_num_patterns, sizeof(int));
    
    // Calcular bloques a partir de total_threads
    int blocks = total_threads / THREADS_PER_BLOCK;

    // Alojar memoria
    
    uint32_t* h_seeds = (uint32_t*)malloc(total_threads * 4 * sizeof(uint32_t));
    uint32_t* d_seeds;
    cudaMalloc(&d_seeds, total_threads * 4 * sizeof(uint32_t));

    // Semillas CSPRNG: cada thread tiene 128 bits de estado unico e independiente
    {
        uint32_t base[4];
        csprng_fill(base, 4);
        uint64_t b0 = ((uint64_t)base[1] << 32) | base[0];
        uint64_t b1 = ((uint64_t)base[3] << 32) | base[2];
        for (int i = 0; i < total_threads; i++) {
            uint64_t h1 = splitmix64(b0 + (uint64_t)i);
            uint64_t h2 = splitmix64(b1 ^ ((uint64_t)i * 0x9e3779b97f4a7c15ULL));
            h_seeds[i*4+0] = (uint32_t)(h1);
            h_seeds[i*4+1] = (uint32_t)(h1 >> 32);
            h_seeds[i*4+2] = (uint32_t)(h2);
            h_seeds[i*4+3] = (uint32_t)(h2 >> 32);
            if (!h_seeds[i*4+0] && !h_seeds[i*4+1] && !h_seeds[i*4+2] && !h_seeds[i*4+3])
                h_seeds[i*4+0] = 1;
        }
    }
    cudaMemcpy(d_seeds, h_seeds, total_threads * 4 * sizeof(uint32_t), cudaMemcpyHostToDevice);
    
    // Resultados (MAX_TARGETS para poder capturar multiples en --all)
    int max_results = MAX_TARGETS;
    result_t* h_results = (result_t*)calloc(max_results, sizeof(result_t));
    result_t* d_results;
    cudaMalloc(&d_results, max_results * sizeof(result_t));
    cudaMemset(d_results, 0, max_results * sizeof(result_t));
    
    // Contador total
    uint64_t* d_total_checked;
    cudaMalloc(&d_total_checked, sizeof(uint64_t));
    cudaMemset(d_total_checked, 0, sizeof(uint64_t));
    
    // Tracking multi-target
    int target_found_flags[MAX_TARGETS];
    memset(target_found_flags, 0, sizeof(target_found_flags));
    int targets_remaining = h_num_patterns;

    // Abrir archivo de salida si se buscan todos
    FILE* out_f = NULL;
    if (search_all) {
        out_f = fopen(output_file, "a");
        if (!out_f)
            printf("Aviso: no se pudo abrir '%s' — resultados solo en pantalla.\n\n", output_file);
        else
            printf("Guardando resultados en: %s\n\n", output_file);
    }

    // Loop principal
    printf("Buscando%s...\n", search_all ? " todos los targets" : "");

    clock_t start_time = clock();
    uint64_t last_checked = 0;
    int found = 0;
    
    while (!found) {
        // Lanzar kernel
        vanity_search_kernel<<<blocks, THREADS_PER_BLOCK>>>(
            d_seeds, d_results, d_total_checked, max_results
        );
        
        cudaDeviceSynchronize();
        
        // Verificar errores
        cudaError_t err = cudaGetLastError();
        if (err != cudaSuccess) {
            printf("Error CUDA: %s\n", cudaGetErrorString(err));
            break;
        }
        
        // Comprobar resultados
        cudaMemcpy(h_results, d_results, max_results * sizeof(result_t), cudaMemcpyDeviceToHost);
        
        if (h_results[0].found > 0) {
            int nfound = h_results[0].found;
            if (nfound > max_results) nfound = max_results;

            // Deduplicar por target_idx y procesar cada resultado nuevo
            int found_this_round[MAX_TARGETS];
            memset(found_this_round, 0, sizeof(found_this_round));

            for (int r = 0; r < nfound; r++) {
                int tidx = h_results[r].target_idx;
                if (tidx < 0 || tidx >= h_num_patterns) continue;
                if (target_found_flags[tidx]) continue;   // ya encontrado antes
                if (found_this_round[tidx])   continue;   // duplicado en este lanzamiento
                found_this_round[tidx] = 1;
                target_found_flags[tidx] = 1;
                targets_remaining--;

                char hex_addr[41], hex_key[65];
                host_address_to_hex(h_results[r].address, hex_addr);
                host_privkey_to_hex(&h_results[r].private_key, hex_key);

                const char* pstr = (strlen(disp_pre[tidx]) > 0) ? disp_pre[tidx] : "(ninguno)";
                const char* sstr = (strlen(disp_suf[tidx]) > 0) ? disp_suf[tidx] : "(ninguno)";

                if (search_all)
                    printf("\n=== ENCONTRADO [%d/%d]! ===\n",
                           h_num_patterns - targets_remaining, h_num_patterns);
                else
                    printf("\n=== ENCONTRADO! ===\n");

                printf("Target [%d]:  prefijo: %-20s sufijo: %s\n", tidx, pstr, sstr);
                printf("Direccion:     0x%s\n", hex_addr);
                printf("Clave privada: 0x%s\n", hex_key);

                // Guardar en archivo
                if (out_f) {
                    time_t ts = time(NULL);
                    struct tm* tm_info = localtime(&ts);
                    char tsbuf[32];
                    strftime(tsbuf, sizeof(tsbuf), "%Y-%m-%d %H:%M:%S", tm_info);
                    fprintf(out_f, "[%s] Target [%d]:  prefijo: %s  sufijo: %s\n",
                            tsbuf, tidx, pstr, sstr);
                    fprintf(out_f, "Direccion:     0x%s\n", hex_addr);
                    fprintf(out_f, "Clave privada: 0x%s\n\n", hex_key);
                    fflush(out_f);
                }
            }

            // Parar si no es modo --all o si ya encontramos todos
            if (!search_all || targets_remaining == 0) {
                if (search_all)
                    printf("\nTodos los targets encontrados.\n");
                found = 1;
                break;
            }

            // Reconstruir patrones activos (sin los ya encontrados)
            pattern_t active_pats[MAX_TARGETS];
            int n_active = 0;
            for (int i = 0; i < h_num_patterns; i++) {
                if (!target_found_flags[i])
                    active_pats[n_active++] = h_patterns[i];
            }
            cudaMemcpyToSymbol(d_patterns,     active_pats, n_active * sizeof(pattern_t));
            cudaMemcpyToSymbol(d_num_patterns, &n_active,   sizeof(int));

            // Resetear buffer de resultados para el siguiente lanzamiento
            cudaMemset(d_results, 0, max_results * sizeof(result_t));

            printf("\n[%d/%d encontrados - buscando los %d restantes...]\n",
                   h_num_patterns - targets_remaining, h_num_patterns, targets_remaining);
        }
        
        // Leer sensores y ajustar ventilador
        int gpu_temp  = temp_read();
        int gpu_watts = power_read();
        int cur_fan   = -1;
        if (fan_percent > 0) cur_fan = fan_update_by_temp(gpu_temp, fan_percent);

        // Mostrar progreso
        uint64_t total_checked;
        cudaMemcpy(&total_checked, d_total_checked, sizeof(uint64_t), cudaMemcpyDeviceToHost);

        clock_t current_time = clock();
        double elapsed = (double)(current_time - start_time) / CLOCKS_PER_SEC;

        if (elapsed > 0) {
            double speed = (total_checked - last_checked) / elapsed / 1000000.0;
            char temp_str[16]  = "";
            char fan_str[16]   = "";
            char power_str[16] = "";
            if (gpu_temp  >= 0) snprintf(temp_str,  sizeof(temp_str),  " | Temp: %dC", gpu_temp);
            if (cur_fan   >= 0) snprintf(fan_str,   sizeof(fan_str),   " | Fan: %d%%", cur_fan);
            if (gpu_watts >= 0) snprintf(power_str, sizeof(power_str), " | %dW", gpu_watts);
            if (search_all)
                printf("\r[%d/%d] Comprobadas: %llu M | Vel: %.2f M/s%s%s%s   ",
                       h_num_patterns - targets_remaining, h_num_patterns,
                       (unsigned long long)(total_checked / 1000000), speed,
                       temp_str, fan_str, power_str);
            else
                printf("\rComprobadas: %llu M | Vel: %.2f M/s%s%s%s   ",
                       (unsigned long long)(total_checked / 1000000), speed,
                       temp_str, fan_str, power_str);
            fflush(stdout);

            last_checked = total_checked;
            start_time = current_time;
        }
    }
    
    // Cerrar archivo de resultados
    if (out_f) fclose(out_f);

    // Restaurar ventiladores y limpiar
    fan_cleanup();

    free(h_seeds);
    free(h_results);
    cudaFree(d_seeds);
    cudaFree(d_results);
    cudaFree(d_total_checked);

    printf("\nFinalizado.\n");
    
    return 0;
}
