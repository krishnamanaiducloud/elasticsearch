# syntax=docker/dockerfile:1.7
ARG WOLFI_IMAGE=cgr.dev/chainguard/wolfi-base:latest@sha256:24f549a7fcace88e69b9557941168c74645688ecc4acf7fb6d734a6b74e9019d

FROM --platform=$BUILDPLATFORM ${WOLFI_IMAGE} AS unpack
ARG TARGETARCH
ARG ELASTIC_VERSION=9.5.6
ARG ES_SHA512_AMD64=e98a3abbca2c25e75b0908015d6ea30ff6bf11285e95b105a3a1f2825b2e71e79116c2bdd598b098a6e9c34cbfeab7ae91b0f3daa4adc3b2a41e31d004dbd339
ARG ES_SHA512_ARM64=892fa02ac9196b5576cbc942f65f14e3bae28297f4cf153341ec5a862ffb0f95b0eb2469dd087ac92656219d9536e74565ba24dc5984561b40b29b31da979f40
ARG CONTEXT_SHA512=fc9ab74c3d918b96c6f35302a62e2aa2709cabd1f0f22a18bb28fc097db1ec5f96eca0a218b922cf456b20da2af668c9c80707ae724b81cfba799c0aa07ac74c
ARG APK_REPOSITORY
# openjdk-25 runs build/Reshade.java on the build platform; it is not part of the image.
RUN --mount=type=bind,source=build/apk-install.sh,target=/tmp/apk-install.sh \
    sh /tmp/apk-install.sh bash coreutils curl findutils gnutar gzip openjdk-25-default-jdk sed unzip zip
WORKDIR /work
RUN case "${TARGETARCH}" in \
      amd64) arch=x86_64 sum="${ES_SHA512_AMD64}" ;; \
      arm64) arch=aarch64 sum="${ES_SHA512_ARM64}" ;; \
      *) exit 1 ;; \
    esac \
    && base=https://artifacts.elastic.co/downloads/elasticsearch \
    && fetch() { curl -fsSL --retry 8 --retry-all-errors --speed-limit 1024 --speed-time 60 -o "$1" "$2"; } \
    && fetch es.tar.gz "${base}/elasticsearch-${ELASTIC_VERSION}-linux-${arch}.tar.gz" \
    && echo "${sum}  es.tar.gz" | sha512sum -c - \
    && fetch ctx.tar.gz "${base}/elasticsearch-wolfi-${ELASTIC_VERSION}-docker-build-context.tar.gz" \
    && echo "${CONTEXT_SHA512}  ctx.tar.gz" | sha512sum -c - \
    && mkdir -p /out ctx \
    && tar -xzf es.tar.gz -C /out --strip-components=1 \
    && tar -xzf ctx.tar.gz -C ctx \
    && rm -f es.tar.gz ctx.tar.gz \
    && grep -E '^JAVA_VERSION="27\.' /out/jdk/release
COPY build/patch-jars.sh build/jars.txt build/Reshade.java /work/
RUN --mount=type=cache,id=elasticsearch-jars,target=/tmp/jar-cache,sharing=locked \
    RESHADE_JAVA=/usr/lib/jvm/default-jvm/bin/java bash /work/patch-jars.sh /out /work/jars.txt
RUN cd /out \
    && cp /work/ctx/config/elasticsearch.yml config/elasticsearch.yml \
    && mv config/log4j2.properties config/log4j2.file.properties \
    && cp /work/ctx/config/log4j2.properties config/log4j2.properties \
    && sed -i -e 's/ES_DISTRIBUTION_TYPE=tar/ES_DISTRIBUTION_TYPE=docker/' bin/elasticsearch-env \
    && grep -q '^ES_DISTRIBUTION_TYPE=docker' bin/elasticsearch-env \
    && mkdir -p data \
    && find . -type d -exec chmod 0555 {} + \
    && find . -type f -perm /111 -exec chmod 0555 {} + \
    && find . -type f ! -perm /111 -exec chmod 0444 {} + \
    && chmod 0775 bin config config/jvm.options.d data logs plugins \
    && find config -type f -exec chmod 0664 {} +

FROM ${WOLFI_IMAGE}
ARG ELASTIC_VERSION=9.5.6
ARG APK_REPOSITORY
RUN --mount=type=bind,source=build/apk-install.sh,target=/tmp/apk-install.sh \
    sh /tmp/apk-install.sh bash ca-certificates curl java-cacerts libstdc++ libsystemd netcat-openbsd \
      p11-kit p11-kit-trust posix-libc-utils shadow tini unzip zip zstd \
    && groupadd -g 1000 elasticsearch \
    && useradd -u 1000 -g 1000 -G 0 -d /usr/share/elasticsearch -M -s /bin/bash elasticsearch
ENV ELASTIC_CONTAINER=true \
    GLIBC_TUNABLES=glibc.malloc.hugetlb=0 \
    PATH=/usr/share/elasticsearch/bin:$PATH \
    SHELL=/bin/bash
WORKDIR /usr/share/elasticsearch
COPY --from=unpack --chown=0:0 /out/ /usr/share/elasticsearch/
COPY --from=unpack --chown=0:0 --chmod=0555 /work/ctx/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod g=u /etc/passwd \
    && find / -xdev -perm -4000 -exec chmod ug-s {} + \
    && chmod 0775 /usr/share/elasticsearch \
    && chown 1000:0 bin config config/jvm.options.d data logs plugins \
    && ln -sf /etc/ssl/certs/java/cacerts /usr/share/elasticsearch/jdk/lib/security/cacerts \
    && mkdir /licenses \
    && ln LICENSE.txt /licenses/LICENSE
LABEL org.opencontainers.image.title="Elasticsearch" \
      org.opencontainers.image.version="${ELASTIC_VERSION}.1-patched" \
      org.opencontainers.image.source="https://github.com/elastic/elasticsearch" \
      org.opencontainers.image.licenses="Elastic-2.0 OR AGPL-3.0-only OR SSPL-1.0"
USER 1000:0
EXPOSE 9200 9300
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["eswrapper"]
