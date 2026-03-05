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

// Estructura para resultados encontrados
typedef struct {
    uint256_t private_key;
    uint8_t address[20];
    int found;
} result_t;

// Patrón en constant memory
__constant__ pattern_t d_pattern;

// Generador de números aleatorios simple (xorshift)
__device__ uint32_t xorshift32(uint32_t* state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

// Kernel principal
__global__ void vanity_search_kernel(
    uint32_t* seeds,
    result_t* results,
    uint64_t* total_checked,
    int max_results
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Estado del RNG
    uint32_t rng_state = seeds[idx];
    
    // Clave privada
    uint256_t privkey;
    
    // Resultados locales
    int local_found = 0;
    
    for (int iter = 0; iter < ITERATIONS_PER_THREAD && local_found == 0; iter++) {
        // Generar clave privada aleatoria
        #pragma unroll
        for (int i = 0; i < 8; i++) {
            privkey.d[i] = xorshift32(&rng_state);
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
        
        // Comprobar si coincide con el patrón
        if (match_address(address, &d_pattern)) {
            // Encontrado! Guardar resultado
            int slot = atomicAdd((int*)&results[0].found, 1);
            if (slot < max_results) {
                uint256_copy(&results[slot].private_key, &privkey);
                #pragma unroll
                for (int i = 0; i < 20; i++) {
                    results[slot].address[i] = address[i];
                }
            }
            local_found = 1;
        }
    }
    
    // Guardar estado del RNG para la siguiente iteración
    seeds[idx] = rng_state;
    
    // Actualizar contador total
    atomicAdd((unsigned long long*)total_checked, ITERATIONS_PER_THREAD);
}

void print_usage(const char* prog) {
    printf("Uso: %s [opciones]\n", prog);
    printf("Opciones:\n");
    printf("  -p <prefijo>   Prefijo hexadecimal a buscar (sin 0x)\n");
    printf("  -s <sufijo>    Sufijo hexadecimal a buscar (sin 0x)\n");
    printf("  -i             Case insensitive (por defecto)\n");
    printf("  -c             Case sensitive\n");
    printf("  -t <threads>   Total de threads GPU (multiplo de 256, defecto: auto desde GPU)\n");
    printf("  -f <0-100>     Velocidad de ventiladores en %% (defecto: 100, 0=sin cambio)\n");
    printf("  -h             Mostrar esta ayuda\n");
    printf("\nEjemplos:\n");
    printf("  %s -p dead -s beef\n", prog);
    printf("  %s -p 1337 -t 131072 -f 80\n", prog);
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

int main(int argc, char** argv) {
    // Parsear argumentos
    char prefix[41] = "";
    char suffix[41] = "";
    int case_sensitive = 0;
    int total_threads     = 0;     // 0 = auto-detectar desde GPU
    int threads_user_set  = 0;
    int fan_percent       = 100;   // defecto: 100%

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            strncpy(prefix, argv[++i], 40);
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            strncpy(suffix, argv[++i], 40);
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
    
    if (strlen(prefix) == 0 && strlen(suffix) == 0) {
        printf("Error: Debes especificar al menos un prefijo (-p) o sufijo (-s)\n\n");
        print_usage(argv[0]);
        return 1;
    }
    
    printf("=== Vanity ETH Address Generator ===\n");
    printf("Prefijo: %s\n", strlen(prefix) > 0 ? prefix : "(ninguno)");
    printf("Sufijo:  %s\n", strlen(suffix) > 0 ? suffix : "(ninguno)");
    printf("Case sensitive: %s\n\n", case_sensitive ? "si" : "no");
    
    // Preparar patrón
    pattern_t h_pattern;
    memset(&h_pattern, 0, sizeof(pattern_t));
    
    if (strlen(prefix) > 0) {
        // Convertir a minúsculas si case insensitive
        char prefix_lower[41];
        for (int i = 0; prefix[i]; i++) {
            prefix_lower[i] = (prefix[i] >= 'A' && prefix[i] <= 'F') ? 
                              prefix[i] + 32 : prefix[i];
        }
        prefix_lower[strlen(prefix)] = '\0';
        
        if (parse_hex_pattern(prefix_lower, h_pattern.prefix, &h_pattern.prefix_len) < 0) {
            printf("Error: Prefijo invalido\n");
            return 1;
        }
    }
    
    if (strlen(suffix) > 0) {
        char suffix_lower[41];
        for (int i = 0; suffix[i]; i++) {
            suffix_lower[i] = (suffix[i] >= 'A' && suffix[i] <= 'F') ? 
                              suffix[i] + 32 : suffix[i];
        }
        suffix_lower[strlen(suffix)] = '\0';
        
        if (parse_hex_pattern(suffix_lower, h_pattern.suffix, &h_pattern.suffix_len) < 0) {
            printf("Error: Sufijo invalido\n");
            return 1;
        }
    }
    
    h_pattern.case_sensitive = case_sensitive;
    
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
    
    // Copiar patrón a constant memory
    cudaMemcpyToSymbol(d_pattern, &h_pattern, sizeof(pattern_t));
    
    // Calcular bloques a partir de total_threads
    int blocks = total_threads / THREADS_PER_BLOCK;

    // Alojar memoria
    
    uint32_t* h_seeds = (uint32_t*)malloc(total_threads * sizeof(uint32_t));
    uint32_t* d_seeds;
    cudaMalloc(&d_seeds, total_threads * sizeof(uint32_t));
    
    // Inicializar semillas aleatorias
    srand((unsigned int)time(NULL));
    for (int i = 0; i < total_threads; i++) {
        h_seeds[i] = rand() ^ (rand() << 16);
        if (h_seeds[i] == 0) h_seeds[i] = 1;
    }
    cudaMemcpy(d_seeds, h_seeds, total_threads * sizeof(uint32_t), cudaMemcpyHostToDevice);
    
    // Resultados
    int max_results = 10;
    result_t* h_results = (result_t*)calloc(max_results, sizeof(result_t));
    result_t* d_results;
    cudaMalloc(&d_results, max_results * sizeof(result_t));
    cudaMemset(d_results, 0, max_results * sizeof(result_t));
    
    // Contador total
    uint64_t* d_total_checked;
    cudaMalloc(&d_total_checked, sizeof(uint64_t));
    cudaMemset(d_total_checked, 0, sizeof(uint64_t));
    
    // Loop principal
    printf("Buscando...\n");
    
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
            found = 1;
            
            printf("\n=== ENCONTRADO! ===\n");
            
            // Mostrar resultado
            char hex_addr[41];
            char hex_key[65];
            
            host_address_to_hex(h_results[0].address, hex_addr);
            host_privkey_to_hex(&h_results[0].private_key, hex_key);
            
            printf("Direccion:    0x%s\n", hex_addr);
            printf("Clave privada: 0x%s\n", hex_key);
            
            break;
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
            printf("\rComprobadas: %llu M | Vel: %.2f M/s%s%s%s   ",
                   (unsigned long long)(total_checked / 1000000), speed,
                   temp_str, fan_str, power_str);
            fflush(stdout);

            last_checked = total_checked;
            start_time = current_time;
        }
    }
    
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
