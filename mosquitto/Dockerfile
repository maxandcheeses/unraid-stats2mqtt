FROM --platform=linux/amd64 alpine:3.19

ARG MOSQUITTO_VERSION=2.0.18

RUN apk add --no-cache \
      build-base \
      cmake \
      openssl-dev \
      openssl-libs-static \
      c-ares-dev \
      c-ares-static \
      cjson-dev \
      libxslt \
      wget \
      binutils

RUN wget -q "https://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz" \
    && tar xzf "mosquitto-${MOSQUITTO_VERSION}.tar.gz" \
    && cd "mosquitto-${MOSQUITTO_VERSION}" \
    && cmake \
         -DWITH_BROKER=OFF \
         -DWITH_APPS=ON \
         -DWITH_CLIENTS=ON \
         -DWITH_STATIC_LIBRARIES=ON \
         -DWITH_SHARED_LIBRARIES=OFF \
         -DWITH_TLS=OFF \
         -DWITH_THREADING=OFF \
         -DDOCUMENTATION=OFF \
         -DCMAKE_EXE_LINKER_FLAGS="-static" \
         -DCMAKE_BUILD_TYPE=Release \
         . \
    && make -j"$(nproc)" mosquitto_pub mosquitto_sub \
    && strip client/mosquitto_pub client/mosquitto_sub \
    && cp client/mosquitto_pub client/mosquitto_sub /usr/local/bin/ \
    && cd / && rm -rf "mosquitto-${MOSQUITTO_VERSION}" "mosquitto-${MOSQUITTO_VERSION}.tar.gz"

RUN file /usr/local/bin/mosquitto_pub | grep -q "statically linked" \
    || (echo "ERROR: binary is not statically linked" && exit 1)
