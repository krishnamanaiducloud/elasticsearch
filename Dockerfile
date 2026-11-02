# syntax=docker/dockerfile:1.7
ARG WOLFI_IMAGE=cgr.dev/chainguard/wolfi-base:latest@sha256:fd50bd0cdeb808cf4f45c9c9189e0cc7f7fcc27195d69abd6622c80527e7e021
FROM ${WOLFI_IMAGE} AS unpack
ARG TARGETARCH
RUN apk add --no-cache bash gnutar gzip
COPY --from=dist / /dist/
RUN case "${TARGETARCH}" in \
      amd64) archive="$(find /dist -name '*linux-x86_64.tar.gz' -type f | head -1)" ;; \
      arm64) archive="$(find /dist -name '*linux-aarch64.tar.gz' -type f | head -1)" ;; \
      *) exit 1 ;; \
    esac \
    && test -n "${archive}" \
    && mkdir -p /out \
    && tar -xzf "${archive}" -C /out --strip-components=1 \
    && rm -rf /out/jdk /out/jdk.app \
    && chmod -R g=u /out

FROM ${WOLFI_IMAGE}
ARG ELASTIC_VERSION=9.5.6
RUN apk upgrade --no-cache \
    && apk add --no-cache bash busybox coreutils grep openjdk-21-jre-headless \
    && addgroup -S -g 1000 elasticsearch \
    && adduser -S -D -H -u 1000 -G elasticsearch elasticsearch
ENV ES_JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    PATH=/usr/share/elasticsearch/bin:$PATH
WORKDIR /usr/share/elasticsearch
COPY --from=unpack --chown=1000:0 /out/ /usr/share/elasticsearch/
RUN chgrp -R 0 /usr/share/elasticsearch \
    && chmod -R g=u /usr/share/elasticsearch \
    && mkdir -p /usr/share/elasticsearch/data \
    && chmod 0770 /usr/share/elasticsearch/data
LABEL org.opencontainers.image.title="Elasticsearch" \
      org.opencontainers.image.version="${ELASTIC_VERSION}-patched" \
      org.opencontainers.image.source="https://github.com/elastic/elasticsearch" \
      org.opencontainers.image.licenses="Elastic-2.0 OR AGPL-3.0-only OR SSPL-1.0"
USER 1000:0
EXPOSE 9200 9300
ENTRYPOINT ["/usr/share/elasticsearch/bin/elasticsearch"]
