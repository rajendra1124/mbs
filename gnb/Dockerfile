# OCUDU gNB with 3GPP Rel-17 MBS broadcast (PTM) support, USRP B210 ready.
#
# Build:  docker build -t mbs-gnb:latest gnb/          (from the repo root; ~15-30 min)
# Run:    gnb/start.sh                                  (privileged, host network, USB pass-through)
#
# Reproduces the tested stack: Ubuntu 22.04, UHD 4.1 (distro), FFTW (no MKL), no DPDK.
# The binary is built for x86-64-v3 (AVX2, Intel Haswell / AMD Zen or newer), not -march=native,
# so the image runs on other PCs.

ARG OCUDU_REPO=https://gitlab.com/ocudu/ocudu.git
ARG OCUDU_COMMIT=1ba4cdf2ed3ca624521fa956a9ee09e0bffecf0a
ARG MARCH=x86-64-v3

########################################################################## build
FROM ubuntu:22.04 AS builder
ARG OCUDU_REPO
ARG OCUDU_COMMIT
ARG MARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git cmake make gcc g++ pkg-config \
        libfftw3-dev libmbedtls-dev libsctp-dev libyaml-cpp-dev libzmq3-dev \
        libuhd-dev libboost-program-options-dev libboost-dev \
    && rm -rf /var/lib/apt/lists/*

# Upstream OCUDU at the pinned commit + our MBS patch
RUN git clone ${OCUDU_REPO} /src/ocudu && cd /src/ocudu && git checkout -q ${OCUDU_COMMIT}
COPY patches/ /src/patches/
RUN cd /src/ocudu && for p in /src/patches/*.patch; do echo "applying $p"; git apply --whitespace=nowarn "$p"; done

RUN cmake -S /src/ocudu -B /src/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DMARCH=${MARCH} \
        -DENABLE_UHD=ON -DENABLE_ZEROMQ=ON \
        -DENABLE_MKL=OFF -DENABLE_FFTZ=OFF -DENABLE_ARMPL=OFF -DENABLE_DPDK=OFF \
        -DBUILD_TESTING=OFF -DENABLE_WERROR=OFF -DENABLE_PLUGINS=OFF \
    && cmake --build /src/build --target gnb -j"$(nproc)" \
    && strip /src/build/apps/gnb/gnb

########################################################################## runtime
FROM ubuntu:22.04
ARG OCUDU_COMMIT
ARG MARCH
ENV DEBIAN_FRONTEND=noninteractive
LABEL org.opencontainers.image.title="mbs-gnb" \
      org.opencontainers.image.description="OCUDU gNB with 5G NR MBS broadcast (PTM), USRP B210" \
      org.opencontainers.image.source="https://github.com/rajendra1124/mbs" \
      ocudu.commit="${OCUDU_COMMIT}" ocudu.march="${MARCH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libuhd4.1.0 uhd-host python3 \
        libfftw3-single3 libmbedtls14 libmbedcrypto7 libsctp1 libyaml-cpp0.7 libzmq5 \
        libboost-program-options1.74.0 iproute2 procps usbutils \
    && rm -rf /var/lib/apt/lists/*

# USRP B2xx firmware + FPGA images, baked into the image (no download at run time)
RUN uhd_images_downloader -t b2xx && ls /usr/share/uhd/images/ | grep -i b2

COPY --from=builder /src/build/apps/gnb/gnb /usr/local/bin/gnb
COPY --from=builder /src/ocudu/LICENSE /usr/share/doc/ocudu/LICENSE
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && ldd /usr/local/bin/gnb | (! grep "not found")

WORKDIR /logs
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["-c", "/config/gnb.yml"]
