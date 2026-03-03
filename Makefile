# Vanity ETH Address Generator - Makefile (Linux / macOS)
# Uso:
#   make              - auto-detecta arquitectura GPU
#   make ARCH=sm_86   - especifica arquitectura manualmente
#   make clean        - elimina binarios generados
#   make help         - muestra esta ayuda

NVCC   = nvcc
TARGET = vanity_eth
SRC    = src/main.cu

# Auto-detectar arquitectura GPU con nvidia-smi.
# Si nvidia-smi no está disponible, compila sin -arch (nvcc usará su defecto).
ifeq ($(ARCH),)
    COMPUTE_CAP := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
    ifneq ($(COMPUTE_CAP),)
        ARCH_FLAG := -arch=sm_$(COMPUTE_CAP)
    else
        ARCH_FLAG :=
    endif
else
    ARCH_FLAG := -arch=$(ARCH)
endif

NVCCFLAGS := -O3 $(ARCH_FLAG)

.PHONY: all clean help

all: $(TARGET)
	@echo ""
	@echo "=== Compilacion exitosa! ==="
	@echo "Ejecutable: ./$(TARGET)"
	@echo ""
	@echo "Uso rapido:"
	@echo "  ./$(TARGET) -p dead -s beef"
	@echo "  ./$(TARGET) -p 1337"
	@echo "  ./$(TARGET) -h"

$(TARGET): $(SRC) src/secp256k1.cuh src/keccak256.cuh src/matcher.cuh src/uint256.cuh
	@if [ -n "$(ARCH_FLAG)" ]; then \
		echo "Compilando con $(ARCH_FLAG) ..."; \
	else \
		echo "Compilando sin -arch (nvcc usara arquitectura por defecto) ..."; \
		echo "Si tienes errores, especifica: make ARCH=sm_XX"; \
	fi
	$(NVCC) $(NVCCFLAGS) -o $@ $(SRC) -lcuda

clean:
	rm -f $(TARGET) *.o

help:
	@echo "Uso: make [ARCH=sm_XX]"
	@echo ""
	@echo "Ejemplos:"
	@echo "  make                 # Auto-detecta GPU"
	@echo "  make ARCH=sm_89      # RTX 40xx (Ada Lovelace)"
	@echo "  make ARCH=sm_86      # RTX 30xx (Ampere)"
	@echo "  make ARCH=sm_75      # RTX 20xx / GTX 16xx (Turing)"
	@echo "  make ARCH=sm_61      # GTX 10xx (Pascal)"
	@echo "  make ARCH=sm_52      # GTX 900 (Maxwell)"
	@echo "  make clean           # Eliminar binarios"
	@echo ""
	@echo "Detectar tu GPU: nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader"
