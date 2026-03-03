#ifndef MATCHER_CUH
#define MATCHER_CUH

#include <cuda_runtime.h>
#include <stdint.h>
#include "uint256.cuh"

// Estructura para el patrón de búsqueda
typedef struct {
    uint8_t prefix[20];      // Prefijo a buscar
    uint8_t suffix[20];      // Sufijo a buscar
    int prefix_len;          // Longitud del prefijo (en nibbles/hex chars)
    int suffix_len;          // Longitud del sufijo (en nibbles/hex chars)
    int case_sensitive;      // 1 = case sensitive, 0 = case insensitive
} pattern_t;

// Convertir un carácter hex a su valor
__host__ __device__ __forceinline__ int hex_char_to_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Convertir valor a carácter hex
__host__ __device__ __forceinline__ char val_to_hex_char(int v, int uppercase) {
    if (v < 10) return '0' + v;
    return (uppercase ? 'A' : 'a') + v - 10;
}

// Parsear string hex a bytes (host function)
__host__ inline int parse_hex_pattern(const char* hex_str, uint8_t* bytes, int* nibble_len) {
    int len = 0;
    while (hex_str[len] != '\0') len++;
    
    *nibble_len = len;
    
    // Rellenar con 0s si es impar
    int byte_idx = 0;
    int high_nibble = 1;
    
    if (len % 2 == 1) {
        // Primer nibble va solo
        int val = hex_char_to_val(hex_str[0]);
        if (val < 0) return -1;
        bytes[0] = val;
        byte_idx = 0;
        high_nibble = 0;
        
        for (int i = 1; i < len; i++) {
            int v = hex_char_to_val(hex_str[i]);
            if (v < 0) return -1;
            
            if (high_nibble) {
                byte_idx++;
                bytes[byte_idx] = v << 4;
                high_nibble = 0;
            } else {
                bytes[byte_idx] |= v;
                high_nibble = 1;
            }
        }
    } else {
        for (int i = 0; i < len; i += 2) {
            int high = hex_char_to_val(hex_str[i]);
            int low = hex_char_to_val(hex_str[i + 1]);
            if (high < 0 || low < 0) return -1;
            bytes[byte_idx++] = (high << 4) | low;
        }
    }
    
    return 0;
}

// Comprobar si la dirección coincide con el patrón
__device__ int match_address(const uint8_t* address, const pattern_t* pattern) {
    // Comprobar prefijo
    if (pattern->prefix_len > 0) {
        int nibbles = pattern->prefix_len;
        int bytes = (nibbles + 1) / 2;
        
        for (int i = 0; i < bytes; i++) {
            uint8_t addr_byte = address[i];
            uint8_t pat_byte = pattern->prefix[i];
            
            if (!pattern->case_sensitive) {
                // Para case insensitive, comparamos directamente ya que
                // los patrones ya están en minúsculas
            }
            
            if (i == bytes - 1 && nibbles % 2 == 1) {
                // Último byte, solo comparar nibble alto
                if ((addr_byte >> 4) != (pat_byte >> 4)) {
                    return 0;
                }
            } else {
                if (addr_byte != pat_byte) {
                    return 0;
                }
            }
        }
    }
    
    // Comprobar sufijo
    if (pattern->suffix_len > 0) {
        int nibbles = pattern->suffix_len;
        int bytes = (nibbles + 1) / 2;
        int start_byte = 20 - bytes;
        
        for (int i = 0; i < bytes; i++) {
            uint8_t addr_byte = address[start_byte + i];
            uint8_t pat_byte = pattern->suffix[i];
            
            if (i == 0 && nibbles % 2 == 1) {
                // Primer byte del sufijo, solo comparar nibble bajo
                if ((addr_byte & 0x0F) != (pat_byte & 0x0F)) {
                    return 0;
                }
            } else {
                if (addr_byte != pat_byte) {
                    return 0;
                }
            }
        }
    }
    
    return 1;
}

// Convertir dirección a string hex
__device__ void address_to_hex(const uint8_t* address, char* hex_str) {
    const char hex_chars[] = "0123456789abcdef";
    
    #pragma unroll
    for (int i = 0; i < 20; i++) {
        hex_str[i * 2] = hex_chars[address[i] >> 4];
        hex_str[i * 2 + 1] = hex_chars[address[i] & 0x0F];
    }
    hex_str[40] = '\0';
}

// Convertir clave privada (uint256) a string hex
__device__ void privkey_to_hex(const uint256_t* key, char* hex_str) {
    const char hex_chars[] = "0123456789abcdef";
    
    // Big-endian output
    #pragma unroll
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

#endif // MATCHER_CUH
