FROM debian:trixie

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev libgnutls28-dev python3 \
    python3-setuptools swig device-tree-compiler mmdebstrap e2fsprogs fdisk \
    gdisk dosfstools zstd xz-utils ca-certificates git wget file \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
