# Install BPF SDK
FROM solanalabs/rust:1.52.0 AS builder
WORKDIR /opt
RUN sh -c "$(curl -sSfL https://release.solana.com/v1.6.9/install)" && \
    /root/.local/share/solana/install/releases/1.6.9/solana-release/bin/sdk/bpf/scripts/install.sh
ENV PATH=/root/.local/share/solana/install/active_release/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build evm_loader
# Note: create stub Cargo.toml to speedup build
FROM builder AS evm-loader-builder
COPY ./evm_loader/ /opt/evm_loader/
WORKDIR /opt/evm_loader/program
RUN cargo build-bpf --features no-logs
RUN cd ../cli && cargo build --release

# Download and build spl-token
FROM builder AS spl-token-builder
ADD http://github.com/solana-labs/solana-program-library/archive/refs/tags/token-cli-v2.0.11.tar.gz /opt/
RUN tar -xvf /opt/token-cli-v2.0.11.tar.gz
WORKDIR /opt/solana-program-library-token-cli-v2.0.11/token/cli
RUN cargo build --release
RUN mv /opt/solana-program-library-token-cli-v2.0.11/target/release/spl-token /opt/

# Build Solidity contracts
FROM ethereum/solc:0.7.0 AS solc
FROM ubuntu:20.04 AS contracts
RUN apt-get update && \
    DEBIAN_FRONTEND=nontineractive apt-get -y install xxd && \
    rm -rf /var/lib/apt/lists/* /var/lib/apt/cache/*
COPY evm_loader/*.sol /opt/
COPY --from=solc /usr/bin/solc /usr/bin/solc
WORKDIR /opt/
RUN solc --output-dir . --bin *.sol && \
    for file in $(ls *.bin); do xxd -r -p $file >${file}ary; done && \
        ls -l
COPY evm_loader/ERC20/src/*.sol /ERC20/
WORKDIR /ERC20/
RUN solc --output-dir . --bin *.sol && \
    for file in $(ls *.bin); do xxd -r -p $file >${file}ary; done && \
        ls -l

# Define solana-image that contains utility
FROM cybercoredev/solana:v1.6.9-resources AS solana

# Build target image
FROM ubuntu:20.04 AS base
WORKDIR /opt
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install openssl ca-certificates curl python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

COPY evm_loader/test_requirements.txt solana-py.patch /tmp/
RUN pip3 install -r /tmp/test_requirements.txt
RUN cd /usr/local/lib/python3.8/dist-packages/ && patch -p0 </tmp/solana-py.patch

COPY --from=solana /opt/solana/bin/solana /opt/solana/bin/solana-keygen /opt/solana/bin/solana-faucet /opt/solana/bin/
COPY --from=evm-loader-builder /opt/evm_loader/program/target/deploy/evm_loader.so /opt/
COPY --from=evm-loader-builder /opt/evm_loader/cli/target/release/neon-cli /opt/
COPY --from=spl-token-builder /opt/spl-token /opt/
COPY --from=contracts /opt/ /opt/solidity/
COPY evm_loader/*.py evm_loader/deploy-test.sh /opt/

COPY --from=contracts /ERC20/ /opt/ERC20/
COPY evm_loader/ERC20/test/* evm_loader/deploy-test.sh /opt/ERC20/
RUN ln -s /opt/evm_loader.so /opt/ERC20/evm_loader.so
RUN ln -s /opt/neon-cli /opt/ERC20/neon-cli
RUN ln -s /opt/spl-token /opt/ERC20/spl-token
ENV EVM_LOADER_PATH=/opt/evm_loader.so

ENV CONTRACTS_DIR=/opt/solidity/
ENV PATH=/opt/solana/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt
