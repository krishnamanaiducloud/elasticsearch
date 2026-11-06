# syntax=docker/dockerfile:1.7
ARG WOLFI_IMAGE=cgr.dev/chainguard/wolfi-base:latest@sha256:8acb3a7694eda954b3ad4256aec3291bdd92715d7a8c030abd1a21546337b4e4

FROM --platform=$BUILDPLATFORM ${WOLFI_IMAGE} AS unpack
ARG TARGETARCH
ARG ELASTIC_VERSION=8.19.24
ARG ES_SHA512_AMD64=eec27510b18a3f658ebe6e1390af92267185c6d798e0a5c1826a5318be67f5cb638e983c134394a26d83ee8d2158af1feef0f8305bf8fa8c9c28a7005fb0da0c
ARG ES_SHA512_ARM64=b349b0e65f6cdc616b8c3ebe47d14134b8d3dce87b76c9b3b701db2253169bb6dab4d4ffa87c3114989dfe303421e2a0cb9112d7ab74f1a510541b48efa87598
ARG CONTEXT_SHA512=8a7438fc4213c8f62973cf9b080eab48d7169d585f966973ddb671f30b746aa79ccb830dc3c018712d4f8026670b6081ad0cbd052c94388ef64c5bac050f65df
# JDK: the one Elastic bundles with this release line's newest patch (8.19.24, OpenJDK 27.0.1)
ARG JDK_FROM_VERSION=8.19.24
ARG JDK_FROM_SHA512_AMD64=eec27510b18a3f658ebe6e1390af92267185c6d798e0a5c1826a5318be67f5cb638e983c134394a26d83ee8d2158af1feef0f8305bf8fa8c9c28a7005fb0da0c
ARG JDK_FROM_SHA512_ARM64=b349b0e65f6cdc616b8c3ebe47d14134b8d3dce87b76c9b3b701db2253169bb6dab4d4ffa87c3114989dfe303421e2a0cb9112d7ab74f1a510541b48efa87598
ARG APK_REPOSITORY
RUN --mount=type=bind,source=build/apk-install.sh,target=/tmp/apk-install.sh \
    sh /tmp/apk-install.sh bash coreutils curl findutils gnutar gzip sed unzip zip
WORKDIR /work
RUN case "${TARGETARCH}" in \
      amd64) arch=x86_64 sum="${ES_SHA512_AMD64}" jdksum="${JDK_FROM_SHA512_AMD64}" ;; \
      arm64) arch=aarch64 sum="${ES_SHA512_ARM64}" jdksum="${JDK_FROM_SHA512_ARM64}" ;; \
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
    && if [ "${JDK_FROM_VERSION}" != "${ELASTIC_VERSION}" ]; then \
         fetch jdk.tar.gz "${base}/elasticsearch-${JDK_FROM_VERSION}-linux-${arch}.tar.gz" \
         && echo "${jdksum}  jdk.tar.gz" | sha512sum -c - \
         && rm -rf /out/jdk \
         && tar -xzf jdk.tar.gz -C /out --strip-components=1 --wildcards "elasticsearch-${JDK_FROM_VERSION}/jdk/*" \
         && rm -f jdk.tar.gz; \
       fi \
    && grep -E '^JAVA_VERSION="27\.' /out/jdk/release
COPY build/patch-jars.sh build/jars.txt /work/
RUN --mount=type=cache,id=elasticsearch-jars,target=/tmp/jar-cache,sharing=locked \
    bash /work/patch-jars.sh /out /work/jars.txt
RUN cd /out \
    && cp /work/ctx/config/elasticsearch.yml config/elasticsearch.yml \
    && mv config/log4j2.properties config/log4j2.file.properties \
    && cp /work/ctx/config/log4j2.properties config/log4j2.properties \
    && sed -i -e 's/ES_DISTRIBUTION_TYPE=tar/ES_DISTRIBUTION_TYPE=docker/' bin/elasticsearch-env \
    && grep -q '^ES_DISTRIBUTION_TYPE=docker' bin/elasticsearch-env \
    && mkdir -p data \
    && find . -type d -exec chmod 0555 {} + \
    && find . -type f -exec chmod 0444 {} + \
    && chmod 0555 bin/* jdk/bin/* jdk/lib/jspawnhelper modules/x-pack-ml/platform/linux-*/bin/* \
    && chmod 0775 bin config config/jvm.options.d data logs plugins \
    && find config -type f -exec chmod 0664 {} +

FROM ${WOLFI_IMAGE}
ARG ELASTIC_VERSION=8.19.24
ARG APK_REPOSITORY
RUN --mount=type=bind,source=build/apk-install.sh,target=/tmp/apk-install.sh \
    sh /tmp/apk-install.sh bash ca-certificates java-cacerts libstdc++ libsystemd netcat-openbsd \
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
    && ln -sf /etc/ssl/certs/java/cacerts /usr/share/elasticsearch/jdk/lib/security/cacerts
LABEL org.opencontainers.image.title="Elasticsearch" \
      org.opencontainers.image.version="${ELASTIC_VERSION}-patched" \
      org.opencontainers.image.source="https://github.com/elastic/elasticsearch" \
      org.opencontainers.image.licenses="Elastic-2.0 OR AGPL-3.0-only OR SSPL-1.0"
USER 1000:0
EXPOSE 9200 9300
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["eswrapper"]
