#ifndef KECCAK256_CUH
#define KECCAK256_CUH

#include <cuda_runtime.h>
#include <stdint.h>
#include "uint256.cuh"

// Constantes de rotación de Keccak
__constant__ int KECCAK_ROTC[24] = {
    1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
    27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
};

__constant__ int KECCAK_PILN[24] = {
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
};

__constant__ uint64_t KECCAK_RNDC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

// Rotación de 64 bits
__device__ __forceinline__ uint64_t rotl64(uint64_t x, int n) {
    return (x << n) | (x >> (64 - n));
}

// Función de permutación Keccak-f[1600]
__device__ void keccak_f(uint64_t* state) {
    uint64_t bc[5];
    uint64_t temp;
    
    for (int round = 0; round < 24; round++) {
        // Theta
        #pragma unroll
        for (int i = 0; i < 5; i++) {
            bc[i] = state[i] ^ state[i + 5] ^ state[i + 10] ^ state[i + 15] ^ state[i + 20];
        }
        
        #pragma unroll
        for (int i = 0; i < 5; i++) {
            temp = bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1);
            #pragma unroll
            for (int j = 0; j < 25; j += 5) {
                state[j + i] ^= temp;
            }
        }
        
        // Rho y Pi
        temp = state[1];
        #pragma unroll
        for (int i = 0; i < 24; i++) {
            int j = KECCAK_PILN[i];
            bc[0] = state[j];
            state[j] = rotl64(temp, KECCAK_ROTC[i]);
            temp = bc[0];
        }
        
        // Chi
        #pragma unroll
        for (int j = 0; j < 25; j += 5) {
            #pragma unroll
            for (int i = 0; i < 5; i++) {
                bc[i] = state[j + i];
            }
            #pragma unroll
            for (int i = 0; i < 5; i++) {
                state[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5];
            }
        }
        
        // Iota
        state[0] ^= KECCAK_RNDC[round];
    }
}

// Keccak-256 para entrada de exactamente 64 bytes (clave pública sin comprimir sin prefijo)
// Input: 64 bytes (X || Y de la clave pública)
// Output: 32 bytes (hash)
__device__ void keccak256_64bytes(const uint8_t* input, uint8_t* output) {
    uint64_t state[25];
    
    // Inicializar estado a 0
    #pragma unroll
    for (int i = 0; i < 25; i++) {
        state[i] = 0;
    }
    
    // Absorber los 64 bytes de entrada
    // Keccak-256 usa rate = 136 bytes (1088 bits)
    // Como 64 < 136, todo cabe en un bloque
    
    // Copiar input al estado (little-endian)
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        state[i] = ((uint64_t)input[i * 8 + 0]) |
                   ((uint64_t)input[i * 8 + 1] << 8) |
                   ((uint64_t)input[i * 8 + 2] << 16) |
                   ((uint64_t)input[i * 8 + 3] << 24) |
                   ((uint64_t)input[i * 8 + 4] << 32) |
                   ((uint64_t)input[i * 8 + 5] << 40) |
                   ((uint64_t)input[i * 8 + 6] << 48) |
                   ((uint64_t)input[i * 8 + 7] << 56);
    }
    
    // Padding: 0x01 en el byte 64, 0x80 en el byte 135
    // Byte 64 está en state[8], offset 0
    state[8] ^= 0x01ULL;
    
    // Byte 135 está en state[16], offset 7
    state[16] ^= 0x8000000000000000ULL;
    
    // Aplicar permutación
    keccak_f(state);
    
    // Extraer los primeros 32 bytes como output
    #pragma unroll
    for (int i = 0; i < 4; i++) {
        output[i * 8 + 0] = (uint8_t)(state[i]);
        output[i * 8 + 1] = (uint8_t)(state[i] >> 8);
        output[i * 8 + 2] = (uint8_t)(state[i] >> 16);
        output[i * 8 + 3] = (uint8_t)(state[i] >> 24);
        output[i * 8 + 4] = (uint8_t)(state[i] >> 32);
        output[i * 8 + 5] = (uint8_t)(state[i] >> 40);
        output[i * 8 + 6] = (uint8_t)(state[i] >> 48);
        output[i * 8 + 7] = (uint8_t)(state[i] >> 56);
    }
}

// Versión que toma directamente las coordenadas x,y como uint256
__device__ void keccak256_pubkey(const uint256_t* pub_x, const uint256_t* pub_y, uint8_t* output) {
    uint8_t input[64];
    
    // Convertir X a bytes (big-endian para Ethereum)
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        uint32_t word = pub_x->d[7 - i];
        input[i * 4 + 0] = (uint8_t)(word >> 24);
        input[i * 4 + 1] = (uint8_t)(word >> 16);
        input[i * 4 + 2] = (uint8_t)(word >> 8);
        input[i * 4 + 3] = (uint8_t)(word);
    }
    
    // Convertir Y a bytes (big-endian para Ethereum)
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        uint32_t word = pub_y->d[7 - i];
        input[32 + i * 4 + 0] = (uint8_t)(word >> 24);
        input[32 + i * 4 + 1] = (uint8_t)(word >> 16);
        input[32 + i * 4 + 2] = (uint8_t)(word >> 8);
        input[32 + i * 4 + 3] = (uint8_t)(word);
    }
    
    keccak256_64bytes(input, output);
}

// Obtener dirección Ethereum (últimos 20 bytes del hash)
__device__ void get_eth_address(const uint256_t* pub_x, const uint256_t* pub_y, uint8_t* address) {
    uint8_t hash[32];
    keccak256_pubkey(pub_x, pub_y, hash);
    
    // Copiar últimos 20 bytes
    #pragma unroll
    for (int i = 0; i < 20; i++) {
        address[i] = hash[12 + i];
    }
}

#endif // KECCAK256_CUH
