#ifndef UINT256_CUH
#define UINT256_CUH

#include <cuda_runtime.h>
#include <stdint.h>

// Entero de 256 bits representado como 8 palabras de 32 bits (little-endian)
typedef struct {
    uint32_t d[8];
} uint256_t;

// Constantes de secp256k1
__constant__ uint256_t SECP256K1_P = {{
    0xFFFFFC2F, 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF,
    0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
}};

__constant__ uint256_t SECP256K1_N = {{
    0xD0364141, 0xBFD25E8C, 0xAF48A03B, 0xBAAEDCE6,
    0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
}};

// ============== Operaciones básicas ==============

__device__ __forceinline__ void uint256_set_zero(uint256_t* r) {
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        r->d[i] = 0;
    }
}

__device__ __forceinline__ void uint256_copy(uint256_t* r, const uint256_t* a) {
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        r->d[i] = a->d[i];
    }
}

__device__ __forceinline__ int uint256_is_zero(const uint256_t* a) {
    uint32_t r = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        r |= a->d[i];
    }
    return r == 0;
}

// Comparación: retorna -1 si a < b, 0 si a == b, 1 si a > b
__device__ __forceinline__ int uint256_cmp(const uint256_t* a, const uint256_t* b) {
    #pragma unroll
    for (int i = 7; i >= 0; i--) {
        if (a->d[i] < b->d[i]) return -1;
        if (a->d[i] > b->d[i]) return 1;
    }
    return 0;
}

// ============== Suma y Resta ==============

// r = a + b, retorna carry
__device__ __forceinline__ uint32_t uint256_add(uint256_t* r, const uint256_t* a, const uint256_t* b) {
    uint64_t carry = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        carry += (uint64_t)a->d[i] + (uint64_t)b->d[i];
        r->d[i] = (uint32_t)carry;
        carry >>= 32;
    }
    return (uint32_t)carry;
}

// r = a - b, retorna borrow
__device__ __forceinline__ uint32_t uint256_sub(uint256_t* r, const uint256_t* a, const uint256_t* b) {
    int64_t borrow = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        borrow = (int64_t)a->d[i] - (int64_t)b->d[i] - borrow;
        r->d[i] = (uint32_t)borrow;
        borrow = (borrow >> 63) & 1;
    }
    return (uint32_t)borrow;
}

// ============== Operaciones modulares ==============

// r = a mod p (asume a < 2p)
__device__ __forceinline__ void uint256_mod_p(uint256_t* r, const uint256_t* a) {
    uint256_t tmp;
    uint32_t borrow = uint256_sub(&tmp, a, &SECP256K1_P);
    if (borrow) {
        uint256_copy(r, a);
    } else {
        uint256_copy(r, &tmp);
    }
}

// r = (a + b) mod p
__device__ __forceinline__ void uint256_mod_add(uint256_t* r, const uint256_t* a, const uint256_t* b) {
    uint256_t tmp;
    uint32_t carry = uint256_add(&tmp, a, b);
    
    if (carry || uint256_cmp(&tmp, &SECP256K1_P) >= 0) {
        uint256_sub(r, &tmp, &SECP256K1_P);
    } else {
        uint256_copy(r, &tmp);
    }
}

// r = (a - b) mod p
__device__ __forceinline__ void uint256_mod_sub(uint256_t* r, const uint256_t* a, const uint256_t* b) {
    uint256_t tmp;
    uint32_t borrow = uint256_sub(&tmp, a, b);
    
    if (borrow) {
        uint256_add(r, &tmp, &SECP256K1_P);
    } else {
        uint256_copy(r, &tmp);
    }
}

// ============== Multiplicación modular ==============

// Multiplicación 256x256 -> 512 bits
__device__ void uint256_mul_full(uint32_t* r, const uint256_t* a, const uint256_t* b) {
    uint64_t carry;
    
    // Inicializar resultado a 0
    #pragma unroll
    for (int i = 0; i < 16; i++) {
        r[i] = 0;
    }
    
    // Multiplicación schoolbook
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        carry = 0;
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint64_t prod = (uint64_t)a->d[i] * (uint64_t)b->d[j] + (uint64_t)r[i + j] + carry;
            r[i + j] = (uint32_t)prod;
            carry = prod >> 32;
        }
        r[i + 8] = (uint32_t)carry;
    }
}

// Reducción modular usando el truco de secp256k1: p = 2^256 - 2^32 - 977
// Esto permite una reducción muy eficiente
__device__ void uint256_mod_reduce(uint256_t* r, const uint32_t* a) {
    uint64_t carry = 0;
    uint32_t tmp[9];
    
    // Primera reducción: a_hi * (2^32 + 977)
    // a = a_lo + a_hi * 2^256
    // a mod p = a_lo + a_hi * (2^32 + 977)
    
    // Copiar parte baja
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        tmp[i] = a[i];
    }
    tmp[8] = 0;
    
    // Sumar a_hi * 2^32 (shift left by 1 word)
    carry = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        uint64_t sum = (uint64_t)tmp[i + 1] + (uint64_t)a[i + 8] + carry;
        tmp[i + 1] = (uint32_t)sum;
        carry = sum >> 32;
    }
    
    // Sumar a_hi * 977
    carry = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        uint64_t sum = (uint64_t)tmp[i] + (uint64_t)a[i + 8] * 977ULL + carry;
        tmp[i] = (uint32_t)sum;
        carry = sum >> 32;
    }
    tmp[8] += (uint32_t)carry;
    
    // Segunda reducción si es necesario
    while (tmp[8] > 0) {
        uint32_t overflow = tmp[8];
        tmp[8] = 0;
        
        carry = 0;
        uint64_t sum = (uint64_t)tmp[0] + (uint64_t)overflow * 977ULL;
        tmp[0] = (uint32_t)sum;
        carry = sum >> 32;
        
        sum = (uint64_t)tmp[1] + (uint64_t)overflow + carry;
        tmp[1] = (uint32_t)sum;
        carry = sum >> 32;
        
        #pragma unroll
        for (int i = 2; i < 9; i++) {
            sum = (uint64_t)tmp[i] + carry;
            tmp[i] = (uint32_t)sum;
            carry = sum >> 32;
        }
    }
    
    // Copiar resultado
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        r->d[i] = tmp[i];
    }
    
    // Reducción final si >= p
    uint256_mod_p(r, r);
}

// r = (a * b) mod p
__device__ void uint256_mod_mul(uint256_t* r, const uint256_t* a, const uint256_t* b) {
    uint32_t product[16];
    uint256_mul_full(product, a, b);
    uint256_mod_reduce(r, product);
}

// r = a^2 mod p (optimizado)
__device__ void uint256_mod_sqr(uint256_t* r, const uint256_t* a) {
    uint256_mod_mul(r, a, a);  // Por ahora, usar mul. Se puede optimizar después.
}

// ============== Inversión modular ==============

// Inversión modular usando exponenciación: a^(-1) = a^(p-2) mod p
// Usamos una cadena de adición optimizada para secp256k1
__device__ void uint256_mod_inv(uint256_t* r, const uint256_t* a) {
    uint256_t x2, x3, x6, x9, x11, x22, x44, x88, x176, x220, x223, t1;
    
    // x2 = a^(2^2-1) = a^3
    uint256_mod_sqr(&x2, a);
    uint256_mod_mul(&x2, &x2, a);
    // x3 = a^(2^3-1) = a^7
    uint256_mod_sqr(&x3, &x2);
    uint256_mod_mul(&x3, &x3, a);
    // x6 = a^(2^6-1) = a^63
    uint256_mod_sqr(&x6, &x3);
    uint256_mod_sqr(&x6, &x6);
    uint256_mod_sqr(&x6, &x6);
    uint256_mod_mul(&x6, &x6, &x3);
    // x9 = a^(2^9-1) = a^511
    uint256_mod_sqr(&x9, &x6);
    uint256_mod_sqr(&x9, &x9);
    uint256_mod_sqr(&x9, &x9);
    uint256_mod_mul(&x9, &x9, &x3);
    // x11 = a^(2^11-1) = a^2047
    uint256_mod_sqr(&x11, &x9);
    uint256_mod_sqr(&x11, &x11);
    uint256_mod_mul(&x11, &x11, &x2);
    // x22 = a^(2^22 - 1)
    uint256_mod_sqr(&x22, &x11);
    for (int i = 1; i < 11; i++) uint256_mod_sqr(&x22, &x22);
    uint256_mod_mul(&x22, &x22, &x11);
    // x44 = a^(2^44 - 1)
    uint256_mod_sqr(&x44, &x22);
    for (int i = 1; i < 22; i++) uint256_mod_sqr(&x44, &x44);
    uint256_mod_mul(&x44, &x44, &x22);
    // x88 = a^(2^88 - 1)
    uint256_mod_sqr(&x88, &x44);
    for (int i = 1; i < 44; i++) uint256_mod_sqr(&x88, &x88);
    uint256_mod_mul(&x88, &x88, &x44);
    // x176 = a^(2^176 - 1)
    uint256_mod_sqr(&x176, &x88);
    for (int i = 1; i < 88; i++) uint256_mod_sqr(&x176, &x176);
    uint256_mod_mul(&x176, &x176, &x88);
    // x220 = a^(2^220 - 1)
    uint256_mod_sqr(&x220, &x176);
    for (int i = 1; i < 44; i++) uint256_mod_sqr(&x220, &x220);
    uint256_mod_mul(&x220, &x220, &x44);
    // x223 = a^(2^223 - 1)
    uint256_mod_sqr(&x223, &x220);
    for (int i = 1; i < 3; i++) uint256_mod_sqr(&x223, &x223);
    uint256_mod_mul(&x223, &x223, &x3);
    
    // t1 = a^(2^256 - 2^32 - 2^9 - 2^8 - 2^7 - 2^6 - 2^4 - 1)
    // = a^(p - 2)
    uint256_mod_sqr(&t1, &x223);
    for (int i = 1; i < 23; i++) uint256_mod_sqr(&t1, &t1);
    uint256_mod_mul(&t1, &t1, &x22);
    for (int i = 0; i < 5; i++) uint256_mod_sqr(&t1, &t1);
    uint256_mod_mul(&t1, &t1, a);
    for (int i = 0; i < 3; i++) uint256_mod_sqr(&t1, &t1);
    uint256_mod_mul(&t1, &t1, &x2);
    for (int i = 0; i < 2; i++) uint256_mod_sqr(&t1, &t1);
    uint256_mod_mul(r, &t1, a);
}

#endif // UINT256_CUH
