# ---------- 第一阶段：下载llvm ----------
FROM debian:12 AS llvm
# Dockerfile(BuildKit)内置参数
ARG TARGETPLATFORM
# install package: wget, tar(xz)
RUN apt-get update > /dev/null && \
    apt-get install -y --no-install-recommends wget ca-certificates xz-utils > /dev/null

ARG LLVM_VERSION=22.1.8
RUN case "$TARGETPLATFORM" in \
      "linux/amd64") LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/LLVM-${LLVM_VERSION}-Linux-X64.tar.xz" ;; \
      "linux/arm64") LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/LLVM-${LLVM_VERSION}-Linux-ARM64.tar.xz" ;; \
      *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    wget -q "$LLVM_URL" -O /tmp/llvm.tar.xz && \
    mkdir -p /opt/llvm && \
    tar -xJf /tmp/llvm.tar.xz -C /opt/llvm --strip-components=1 && \
    rm /tmp/llvm.tar.xz

# ---------- 第二阶段：构建最小C++编译环境 ----------
FROM debian:12 AS builder-basic
COPY --from=llvm /opt/llvm/ /usr/local/
# libxml2: fix lld;
# uuid-dev: used by qykernel/qyserver
RUN apt-get update >/dev/null && \
    apt-get install -y --no-install-recommends libxml2 libc6-dev uuid-dev libpq-dev git > /dev/null && \
    git config --global advice.detachedHead false
# set ENV
ENV CXXFLAGS="-stdlib=libc++"
ENV LDFLAGS="-fuse-ld=lld -lc++abi -rtlib=compiler-rt -lunwind"

# ---------- 第三阶段：构建编译环境 ----------
# 编译结果放在/usr/local中

FROM builder-basic AS compiler
ARG TARGETPLATFORM
RUN apt-get install -y --no-install-recommends wget ca-certificates unzip > /dev/null

# ---- CMake ----
ARG CMAKE_VERSION=3.31.8

RUN case "$TARGETPLATFORM" in \
      "linux/amd64") CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh" ;; \
      "linux/arm64") CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-aarch64.sh" ;; \
      *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    wget -q "$CMAKE_URL" -O cmake.sh
RUN chmod +x cmake.sh
RUN ./cmake.sh --skip-license --prefix=/usr/local >/dev/null

# ---- ninja ----
ARG NINJA_VERSION=v1.13.1

RUN case "$TARGETPLATFORM" in \
      "linux/amd64") NINJA_URL="https://github.com/ninja-build/ninja/releases/download/${NINJA_VERSION}/ninja-linux.zip" ;; \
      "linux/arm64") NINJA_URL="https://github.com/ninja-build/ninja/releases/download/${NINJA_VERSION}/ninja-linux-aarch64.zip" ;; \
      *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
    esac && \
    wget -q "$NINJA_URL" -O ninja.zip
RUN unzip ninja.zip >/dev/null
RUN chmod +x ninja && mv ninja /usr/local/bin


# ---------- 第四阶段：编译第三方库 ----------

# CMAKE Command
ARG BUILD="cmake -S . -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_CXX_STANDARD=20 -DCMAKE_INSTALL_MESSAGE=NEVER"

# ---- Protobuf (动态库) ----
RUN git clone --branch v31.1 --depth 1 https://github.com/protocolbuffers/protobuf.git /protobuf > /dev/null
RUN cd /protobuf && git submodule update --init --recursive
RUN cd /protobuf && $BUILD -Dprotobuf_BUILD_SHARED_LIBS=ON -Dprotobuf_BUILD_TESTS=OFF > /dev/null
RUN cd /protobuf && cmake --build build -j$(nproc) > /dev/null
RUN cd /protobuf && cmake --install build > /dev/null

# ---- PostgreSQL C++ Client ----
RUN git clone --branch 7.10.1 --depth 1 https://github.com/jtv/libpqxx.git /libpqxx > /dev/null
RUN cd /libpqxx && $BUILD -DBUILD_SHARED_LIBS=off -DSKIP_BUILD_TEST=on -DBUILD_DOC=off > /dev/null
RUN cd /libpqxx && cmake --build build -j$(nproc) > /dev/null
RUN cd /libpqxx && cmake --install build > /dev/null

# ---- spdlog ----
RUN git clone --branch v1.15.3 --depth 1 https://github.com/gabime/spdlog.git /spdlog > /dev/null
RUN cd /spdlog && $BUILD -DSPDLOG_BUILD_SHARED=OFF -DSPDLOG_BUILD_EXAMPLE=OFF > /dev/null
RUN cd /spdlog && cmake --build build -j$(nproc) > /dev/null
RUN cd /spdlog && cmake --install build > /dev/null

# ---- hiredis ----
RUN git clone --branch v1.3.0 --depth 1 https://github.com/redis/hiredis.git /hiredis > /dev/null
RUN cd /hiredis && $BUILD -DBUILD_SHARED_LIBS=OFF -DDISABLE_TESTS=ON > /dev/null
RUN cd /hiredis && cmake --build build -j$(nproc) > /dev/null
RUN cd /hiredis && cmake --install build > /dev/null

# ---- redis-plus-plus ----
RUN git clone --branch 1.3.14 --depth 1 https://github.com/sewenew/redis-plus-plus.git /rpp > /dev/null
RUN cd /rpp && $BUILD -DREDIS_PLUS_PLUS_BUILD_SHARED=OFF -DREDIS_PLUS_PLUS_BUILD_TEST=OFF > /dev/null
RUN cd /rpp && cmake --build build -j$(nproc) > /dev/null
RUN cd /rpp && cmake --install build > /dev/null

# ---- boost (header only) ----
RUN wget https://archives.boost.io/release/1.92.0/source/boost_1_92_0.tar.gz -O /tmp/boost.tar.gz >/dev/null
RUN tar -zxf /tmp/boost.tar.gz -C /tmp >/dev/null
RUN cp -r /tmp/boost_*/boost /usr/local/include/

# ---- tomlplusplus ----
RUN git clone --branch v3.4.0 --depth 1 https://github.com/marzer/tomlplusplus.git /tomlplusplus > /dev/null
RUN cd /tomlplusplus && $BUILD -DBUILD_SHARED_LIBS=OFF > /dev/null
RUN cd /tomlplusplus && cmake --build build -j$(nproc) > /dev/null
RUN cd /tomlplusplus && cmake --install build > /dev/null

# ---- GoogleTest ----
RUN git clone --branch v1.16.0 --depth 1 https://github.com/google/googletest.git /googletest > /dev/null
RUN cd /googletest && $BUILD -DBUILD_SHARED_LIBS=OFF -DINSTALL_GTEST=ON > /dev/null
RUN cd /googletest && cmake --build build -j$(nproc) > /dev/null
RUN cd /googletest && cmake --install build > /dev/null

# ---------- 第五阶段：发布 ----------
FROM builder-basic

# 获取compiler的结果
COPY --from=compiler /usr/local/bin /usr/local/bin
COPY --from=compiler /usr/local/lib /usr/local/lib
COPY --from=compiler /usr/local/include /usr/local/include
COPY --from=compiler /usr/local/share /usr/local/share

RUN apt-get update > /dev/null && \
    apt-get install -y --no-install-recommends ca-certificates wget > /dev/null && \
    install -m 0755 -d /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/docker.asc https://download.docker.com/linux/debian/gpg && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo ${VERSION_CODENAME}) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update > /dev/null && \
    apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin > /dev/null && \
    rm -rf /var/lib/apt/lists/*
