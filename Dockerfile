FROM rust:1.69-slim-bullseye as BUILDER

WORKDIR /build

RUN apt-get update && \
    apt-get -y install pkg-config libssl-dev build-essential

RUN mkdir .cargo && \
    echo "[registries.crates-io]" >> .cargo/config.toml && \
    echo "protocol = \"sparse\"" >> .cargo/config.toml

COPY src ./src
COPY Cargo.toml .
COPY Cargo.lock .

RUN cargo build --release

FROM debian:bullseye-slim as RUNNER

WORKDIR /app
COPY --from=BUILDER /build/target/release/grasshopper .

ENTRYPOINT ["mv", "/app/grasshopper", "/out/"]

