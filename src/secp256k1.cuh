#ifndef SECP256K1_CUH
#define SECP256K1_CUH

#include "uint256.cuh"

// Punto en coordenadas Jacobianas (X, Y, Z)
// Punto afín (x, y) = (X/Z^2, Y/Z^3)
typedef struct {
    uint256_t x;
    uint256_t y;
    uint256_t z;
} point_jacobian_t;

// Punto en coordenadas afines
typedef struct {
    uint256_t x;
    uint256_t y;
} point_affine_t;

// ============== Operaciones de punto ==============

__device__ __forceinline__ void point_set_infinity(point_jacobian_t* p) {
    uint256_set_zero(&p->x);
    uint256_set_zero(&p->y);
    uint256_set_zero(&p->z);
    p->x.d[0] = 1;
    p->y.d[0] = 1;
}

__device__ __forceinline__ int point_is_infinity(const point_jacobian_t* p) {
    return uint256_is_zero(&p->z);
}

// Convertir afín a Jacobiano
__device__ void point_affine_to_jacobian(point_jacobian_t* r, const point_affine_t* p) {
    uint256_copy(&r->x, &p->x);
    uint256_copy(&r->y, &p->y);
    uint256_set_zero(&r->z);
    r->z.d[0] = 1;
}

// Convertir Jacobiano a afín (requiere inversión)
__device__ void point_jacobian_to_affine(point_affine_t* r, const point_jacobian_t* p) {
    if (point_is_infinity(p)) {
        uint256_set_zero(&r->x);
        uint256_set_zero(&r->y);
        return;
    }
    
    uint256_t z_inv, z_inv2, z_inv3;
    
    // z_inv = 1/z
    uint256_mod_inv(&z_inv, &p->z);
    
    // z_inv2 = z_inv^2
    uint256_mod_sqr(&z_inv2, &z_inv);
    
    // z_inv3 = z_inv^3
    uint256_mod_mul(&z_inv3, &z_inv2, &z_inv);
    
    // x = X * z_inv^2
    uint256_mod_mul(&r->x, &p->x, &z_inv2);
    
    // y = Y * z_inv^3
    uint256_mod_mul(&r->y, &p->y, &z_inv3);
}

// Duplicación de punto: r = 2 * p
// Usando fórmulas para coordenadas Jacobianas
__device__ void point_double(point_jacobian_t* r, const point_jacobian_t* p) {
    if (point_is_infinity(p) || uint256_is_zero(&p->y)) {
        point_set_infinity(r);
        return;
    }
    
    uint256_t s, m, x3, y3, z3, tmp, y2;
    
    // Y^2
    uint256_mod_sqr(&y2, &p->y);
    
    // S = 4 * X * Y^2
    uint256_mod_mul(&s, &p->x, &y2);
    uint256_mod_add(&s, &s, &s);
    uint256_mod_add(&s, &s, &s);
    
    // M = 3 * X^2 (a = 0 para secp256k1)
    uint256_mod_sqr(&m, &p->x);
    uint256_mod_add(&tmp, &m, &m);
    uint256_mod_add(&m, &tmp, &m);
    
    // X3 = M^2 - 2*S
    uint256_mod_sqr(&x3, &m);
    uint256_mod_sub(&x3, &x3, &s);
    uint256_mod_sub(&x3, &x3, &s);
    
    // Z3 = 2 * Y * Z
    uint256_mod_mul(&z3, &p->y, &p->z);
    uint256_mod_add(&z3, &z3, &z3);
    
    // Y3 = M * (S - X3) - 8 * Y^4
    uint256_mod_sub(&tmp, &s, &x3);
    uint256_mod_mul(&y3, &m, &tmp);
    uint256_mod_sqr(&tmp, &y2);  // Y^4
    uint256_mod_add(&tmp, &tmp, &tmp);  // 2*Y^4
    uint256_mod_add(&tmp, &tmp, &tmp);  // 4*Y^4
    uint256_mod_add(&tmp, &tmp, &tmp);  // 8*Y^4
    uint256_mod_sub(&y3, &y3, &tmp);
    
    uint256_copy(&r->x, &x3);
    uint256_copy(&r->y, &y3);
    uint256_copy(&r->z, &z3);
}

// Suma de punto Jacobiano + punto afín: r = p + q
// Mixta es más eficiente porque q.z = 1
__device__ void point_add_mixed(point_jacobian_t* r, const point_jacobian_t* p, const point_affine_t* q) {
    if (point_is_infinity(p)) {
        point_affine_to_jacobian(r, q);
        return;
    }
    
    uint256_t z1z1, u2, s2, h, hh, i, j, rr, v, tmp;
    
    // Z1Z1 = Z1^2
    uint256_mod_sqr(&z1z1, &p->z);
    
    // U2 = X2 * Z1Z1 (X2 = q->x ya que q es afín)
    uint256_mod_mul(&u2, &q->x, &z1z1);
    
    // S2 = Y2 * Z1 * Z1Z1
    uint256_mod_mul(&s2, &z1z1, &p->z);
    uint256_mod_mul(&s2, &s2, &q->y);
    
    // H = U2 - X1
    uint256_mod_sub(&h, &u2, &p->x);
    
    // Si H == 0
    if (uint256_is_zero(&h)) {
        // r = S2 - Y1
        uint256_mod_sub(&tmp, &s2, &p->y);
        if (uint256_is_zero(&tmp)) {
            // p == q, duplicar
            point_double(r, p);
            return;
        } else {
            // p == -q, resultado es infinito
            point_set_infinity(r);
            return;
        }
    }
    
    // HH = H^2
    uint256_mod_sqr(&hh, &h);
    
    // I = 4 * HH
    uint256_mod_add(&i, &hh, &hh);
    uint256_mod_add(&i, &i, &i);
    
    // J = H * I
    uint256_mod_mul(&j, &h, &i);
    
    // rr = 2 * (S2 - Y1)
    uint256_mod_sub(&rr, &s2, &p->y);
    uint256_mod_add(&rr, &rr, &rr);
    
    // V = X1 * I
    uint256_mod_mul(&v, &p->x, &i);
    
    // X3 = rr^2 - J - 2*V
    uint256_mod_sqr(&r->x, &rr);
    uint256_mod_sub(&r->x, &r->x, &j);
    uint256_mod_sub(&r->x, &r->x, &v);
    uint256_mod_sub(&r->x, &r->x, &v);
    
    // Y3 = rr * (V - X3) - 2 * Y1 * J
    // IMPORTANTE: calcular 2*Y1*J ANTES de escribir r->y,
    // porque cuando r==p escribir r->y destruye p->y.
    uint256_t two_y1_j;
    uint256_mod_mul(&two_y1_j, &p->y, &j);
    uint256_mod_add(&two_y1_j, &two_y1_j, &two_y1_j);
    uint256_mod_sub(&tmp, &v, &r->x);
    uint256_mod_mul(&r->y, &rr, &tmp);
    uint256_mod_sub(&r->y, &r->y, &two_y1_j);
    
    // Z3 = (Z1 + H)^2 - Z1Z1 - HH
    uint256_mod_add(&r->z, &p->z, &h);
    uint256_mod_sqr(&r->z, &r->z);
    uint256_mod_sub(&r->z, &r->z, &z1z1);
    uint256_mod_sub(&r->z, &r->z, &hh);
}

// ============== Tabla precomputada para el generador ==============

#define WINDOW_SIZE 4
#define TABLE_SIZE (1 << WINDOW_SIZE)  // 16

// Tabla precomputada: [0*G, 1*G, 2*G, ..., 15*G]
// Valores calculados con precisión para secp256k1
__constant__ point_affine_t G_TABLE[TABLE_SIZE] = {
    // 0*G (punto en infinito)
    {{{0, 0, 0, 0, 0, 0, 0, 0}}, {{0, 0, 0, 0, 0, 0, 0, 0}}},
    // 1*G
    {{{0x16F81798, 0x59F2815B, 0x2DCE28D9, 0x029BFCDB, 0xCE870B07, 0x55A06295, 0xF9DCBBAC, 0x79BE667E}},
     {{0xFB10D4B8, 0x9C47D08F, 0xA6855419, 0xFD17B448, 0x0E1108A8, 0x5DA4FBFC, 0x26A3C465, 0x483ADA77}}},
    // 2*G
    {{{0x5C709EE5, 0xABAC09B9, 0x8CEF3CA7, 0x5C778E4B, 0x95C07CD8, 0x3045406E, 0x41ED7D6D, 0xC6047F94}},
     {{0x50CFE52A, 0x236431A9, 0x3266D0E1, 0xF7F63265, 0x466CEAEE, 0xA3C58419, 0xA63DC339, 0x1AE168FE}}},
    // 3*G
    {{{0xBCE036F9, 0x8601F113, 0x836F99B0, 0xB531C845, 0xF89D5229, 0x49344F85, 0x9258C310, 0xF9308A01}},
     {{0x84B8E672, 0x6CB9FD75, 0x34C2231B, 0x6500A999, 0x2A37F356, 0x0FE337E6, 0x632DE814, 0x388F7B0F}}},
    // 4*G
    {{{0xE8C4CD13, 0x74FA94AB, 0x0EE07584, 0xCC6C1390, 0x930B1404, 0x581E4904, 0xC10D80F3, 0xE493DBF1}},
     {{0x47739922, 0xCFE97BDC, 0xBFBDFE40, 0xD967AE33, 0x8EA51448, 0x5642E209, 0xA0D455B7, 0x51ED993E}}},
    // 5*G
    {{{0xB240EFE4, 0xCBA8D569, 0xDC619AB7, 0xE88B84BD, 0x0A5C5128, 0x55B4A725, 0x1A072093, 0x2F8BDE4D}},
     {{0xA6AC62D6, 0xDCA87D3A, 0xAB0D6840, 0xF788271B, 0xA6C9C426, 0xD4DBA9DD, 0x36E5E3D6, 0xD8AC2226}}},
    // 6*G
    {{{0x60297556, 0x2F057A14, 0x8568A18B, 0x82F6472F, 0x355235D3, 0x20453A14, 0x755EEEA4, 0xFFF97BD5}},
     {{0xB075F297, 0x3C870C36, 0x518FE4A0, 0xDE80F0F6, 0x7F45C560, 0xF3BE9601, 0xACFBB620, 0xAE12777A}}},
    // 7*G
    {{{0xCAC4F9BC, 0xE92BDDED, 0x0330E39C, 0x3D419B7E, 0xF2EA7A0E, 0xA398F365, 0x6E5DB4EA, 0x5CBDF064}},
     {{0x087264DA, 0xA5082628, 0x13FDE7B5, 0xA813D0B8, 0x861A54DB, 0xA3178D6D, 0xBA255960, 0x6AEBCA40}}},
    // 8*G
    {{{0xE10A2A01, 0x67784EF3, 0xE5AF888A, 0x0A1BDD05, 0xB70F3C2F, 0xAFF3843F, 0x5CCA351D, 0x2F01E5E1}},
     {{0x6CBDE904, 0xB5DA2CB7, 0xBA5B7617, 0xC2E213D6, 0x132D13B4, 0x293D082A, 0x41539949, 0x5C4DA8A7}}},
    // 9*G
    {{{0xFC27CCBE, 0xC35F110D, 0x4C57E714, 0xE0979697, 0x9F559ABD, 0x09AD178A, 0xF0C7F653, 0xACD484E2}},
     {{0xC64F9C37, 0x05CC262A, 0x375F8E0F, 0xADD888A4, 0x763B61E9, 0x64380971, 0xB0A7D9FD, 0xCC338921}}},
    // 10*G
    {{{0x47E247C7, 0x52A68E2A, 0x1943C2B7, 0x3442D49B, 0x1AE6AE5D, 0x35477C7B, 0x47F3C862, 0xA0434D9E}},
     {{0x037368D7, 0x3CBEE53B, 0xD877A159, 0x6F794C2E, 0x93A24C69, 0xA3B6C7E6, 0x5419BC27, 0x893ABA42}}},
    // 11*G
    {{{0x5DA008CB, 0xBBEC1789, 0xE5C17891, 0x5649980B, 0x70C65AAC, 0x5EF4246B, 0x58A9411E, 0x774AE7F8}},
     {{0xC953C61B, 0x301D74C9, 0xDFF9D6A8, 0x372DB1E2, 0xD7B7B365, 0x0243DD56, 0xEB6B5E19, 0xD984A032}}},
    // 12*G
    {{{0x70AFE85A, 0xC5B0F470, 0x9620095B, 0x687CF441, 0x4D734633, 0x15C38F00, 0x48E7561B, 0xD01115D5}},
     {{0xF4062327, 0x6B051B13, 0xD9A86D52, 0x79238C5D, 0xE17BD815, 0xA8B64537, 0xC815E0D7, 0xA9F34FFD}}},
    // 13*G
    {{{0x19405AA8, 0xDEEDDF8F, 0x610E58CD, 0xB075FBC6, 0xC3748651, 0xC7D1D205, 0xD975288B, 0xF28773C2}},
     {{0xDB03ED81, 0x29B5CB52, 0x521FA91F, 0x3A1A06DA, 0x65CDAF47, 0x758212EB, 0x8D880A89, 0x0AB0902E}}},
    // 14*G
    {{{0x60E823E4, 0xE49B241A, 0x678949E6, 0x26AA7B63, 0x07D38E32, 0xFD64E67F, 0x895E719C, 0x499FDF9E}},
     {{0x03A13F5B, 0xC65F40D4, 0x7A3F95BC, 0x464279C2, 0xA7B3D464, 0x90F044E4, 0xB54E8551, 0xCAC2F6C4}}},
    // 15*G
    {{{0xE27E080E, 0x44ADBCF8, 0x3C85F79E, 0x31E5946F, 0x095FF411, 0x5A465AE3, 0x7D43EA96, 0xD7924D4F}},
     {{0xF6A26B58, 0xC504DC9F, 0xD896D3A5, 0xEA40AF2B, 0x28CC6DEF, 0x83842EC2, 0xA86C72A6, 0x581E2872}}}
};

// Multiplicación escalar: r = k * G
// Usa double-and-add clásico sobre G_TABLE[1] = G (constante estándar secp256k1 conocida).
// Las entradas G_TABLE[2..15] NO se usan para evitar depender de valores precomputados
// que podrían haberse generado con una implementación incorrecta.
__device__ void point_mul_generator(point_jacobian_t* r, const uint256_t* k) {
    point_set_infinity(r);

    // Procesar bit a bit de MSB (bit 255) a LSB (bit 0)
    for (int i = 255; i >= 0; i--) {
        point_double(r, r);

        int word_idx  = i / 32;
        int bit_offset = i % 32;
        if ((k->d[word_idx] >> bit_offset) & 1u) {
            point_add_mixed(r, r, &G_TABLE[1]);  // G_TABLE[1] = G estándar
        }
    }
}

#endif // SECP256K1_CUH
