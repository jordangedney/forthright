#!/bin/sh
# Build the forthright kernel. Freestanding: GNU as + ld, no libc.
set -e
cd "$(dirname "$0")"
as --gstabs -o fr.o fr.s
ld -o fr fr.o
echo "built ./fr ($(size -d fr | awk 'NR==2{print $1}') bytes text), run it with: ./fr"
