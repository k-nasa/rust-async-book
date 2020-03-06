FROM rust:1.41

ENV MDBOOK_VERSION=0.3.5
RUN cargo install mdbook --version "${MDBOOK_VERSION}"

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

WORKDIR /book
ENTRYPOINT [ "/usr/local/cargo/bin/mdbook" ]
