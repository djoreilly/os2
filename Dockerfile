FROM opensuse/leap:15.3 as base
RUN sed -i -s 's/^# rpm.install.excludedocs/rpm.install.excludedocs/' /etc/zypp/zypp.conf
RUN zypper ref

FROM base AS build
RUN zypper in -y squashfs xorriso go1.16 upx busybox-static curl tar git gzip
RUN curl -Lo /usr/bin/luet https://github.com/mudler/luet/releases/download/0.20.6/luet-0.20.6-linux-$(go env GOARCH) && \
    chmod +x /usr/bin/luet && \
    upx /usr/bin/luet
RUN curl -Lo /usr/bin/rancherd https://github.com/rancher/rancherd/releases/download/v0.0.1-alpha11/rancherd-$(go env GOARCH) && \
    chmod +x /usr/bin/rancherd && \
    upx /usr/bin/rancherd
RUN curl -L https://get.helm.sh/helm-v3.7.1-linux-$(go env GOARCH).tar.gz | tar xzf - -C /usr/bin --strip-components=1 && \
    upx /usr/bin/helm
COPY go.mod go.sum /usr/src/
COPY cmd /usr/src/cmd
COPY pkg /usr/src/pkg
COPY scripts /usr/src/scripts
COPY chart /usr/src/chart
ARG IMAGE_TAG=latest
RUN TAG=${IMAGE_TAG} /usr/src/scripts/package-helm && \
    cp /usr/src/dist/artifacts/rancheros-operator-*.tgz /usr/src/dist/rancheros-operator-chart.tgz
RUN cd /usr/src && \
    CGO_ENABLED=0 go build -ldflags "-extldflags -static -s" -o /usr/sbin/ros-operator ./cmd/ros-operator && \
    upx /usr/sbin/ros-operator
RUN cd /usr/src && \
    CGO_ENABLED=0 go build -ldflags "-extldflags -static -s" -o /usr/sbin/ros-installer ./cmd/ros-installer && \
    upx /usr/sbin/ros-installer

FROM scratch AS framework
COPY --from=build /usr/bin/busybox-static /usr/bin/busybox
COPY --from=build /usr/bin/rancherd /usr/bin/rancherd
COPY --from=build /usr/bin/luet /usr/bin/luet
COPY --from=build /usr/bin/helm /usr/bin/helm
COPY --from=build /usr/src/dist/rancheros-operator-chart.tgz /usr/share/rancher/os2/
COPY framework/files/etc/luet/luet.yaml /etc/luet/luet.yaml
COPY --from=build /etc/ssl/certs /etc/ssl/certs

ARG CACHEBUST
ENV LUET_NOLOCK=true
RUN ["/usr/bin/busybox", "sh", "-c", "if [ -e /etc/luet/luet.yaml.$(busybox uname -m) ]; then busybox mv -f /etc/luet/luet.yaml.$(busybox uname -m) /etc/luet/luet.yaml; fi && busybox rm -f /etc/luet/luet.yaml.*"]
RUN ["luet", \
    "install", "--no-spinner", "-d", "-y", \
    "selinux/k3s", \
    "selinux/rancher", \
    "meta/cos-minimal", \
    "utils/k9s", \
    "utils/nerdctl"]

COPY --from=build /usr/sbin/ros-installer /usr/sbin/ros-installer
COPY --from=build /usr/sbin/ros-operator /usr/sbin/ros-operator
COPY framework/files/ /
RUN ["/usr/bin/busybox", "rm", "-rf", "/var", "/etc/ssl", "/usr/bin/busybox"]

# Make OS image
FROM base as os
RUN zypper addrepo https://download.opensuse.org/repositories/openSUSE:/Leap:/Micro:/5.1/images/repo/Leap-Micro-5.1-x86_64-Media/ LeapMicro
RUN zypper --non-interactive ref --repo LeapMicro
RUN zypper --non-interactive install --repo LeapMicro \
    apparmor-parser \
    coreutils \
    curl \
    device-mapper \
    dmidecode \
    dosfstools \
    dracut \
    e2fsprogs \
    ethtool \
    findutils \
    gawk \
    gptfdisk \
    glibc-locale-base \
    grub2-i386-pc \
    grub2-x86_64-efi \
    haveged \
    iproute2 \
    iptables \
    iputils \
    issue-generator \
    jq \
    kernel-default \
    kernel-firmware-bnx2 \
    kernel-firmware-chelsio \
    kernel-firmware-i915 \
    kernel-firmware-intel \
    kernel-firmware-iwlwifi \
    kernel-firmware-liquidio \
    kernel-firmware-marvell \
    kernel-firmware-mediatek \
    kernel-firmware-mellanox \
    kernel-firmware-network \
    kernel-firmware-platform \
    kernel-firmware-qlogic \
    kernel-firmware-realtek \
    kernel-firmware-usb-network \
    -kubic-locale-archive \
    less \
    lsof \
    lvm2 \
    mdadm \
    multipath-tools \
    netcat-openbsd \
    nfs-utils \
    open-iscsi \
    open-vm-tools \
    openssh \
    parted \
    -perl \
    pigz \
    procps \
    psmisc \
    rsync \
    squashfs \
    sysstat \
    systemd \
    systemd-sysvinit \
    tar \
    timezone \
    vim-small \
    which \
    wicked \
    wicked-service

# Copy in some local OS customizations
COPY opensuse/files /

ARG IMAGE_TAG=latest
RUN cat /etc/os-release.tmpl | env \
    "VERSION=${IMAGE_TAG}" \
    "VERSION_ID=$(echo ${IMAGE_TAG} | sed s/^v//)" \
    "PRETTY_NAME=RancherOS ${IMAGE_TAG}" \
    envsubst > /etc/os-release && \
    rm /etc/os-release.tmpl

# Starting from here are the lines needed for RancherOS to work

# IMPORTANT: Setup rancheros-release used for versioning/upgrade. The
# values here should reflect the tag of the image being built
ARG IMAGE_REPO=norepo
RUN echo "IMAGE_REPO=${IMAGE_REPO}"          > /usr/lib/rancheros-release && \
    echo "IMAGE_TAG=${IMAGE_TAG}"           >> /usr/lib/rancheros-release && \
    echo "IMAGE=${IMAGE_REPO}:${IMAGE_TAG}" >> /usr/lib/rancheros-release

# Copy in framework runtime
COPY --from=framework / /

# Rebuild initrd to setup dracut with the boot configurations
RUN mkinitrd && \
    # aarch64 has an uncompressed kernel so we need to link it to vmlinuz
    kernel=$(ls /boot/Image-* | head -n1) && \
    if [ -e "$kernel" ]; then ln -sf "${kernel#/boot/}" /boot/vmlinuz; fi

# Save some space
RUN zypper clean --all && \
    rm -rf /var/log/update* && \
    >/var/log/lastlog && \
    rm -rf /boot/vmlinux*

FROM scratch as default
COPY --from=os / /
