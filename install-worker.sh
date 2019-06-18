#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit
IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

sudo systemctl stop apt-daily.timer
sudo systemctl stop apt-daily.service
sudo systemctl kill --kill-who=all apt-daily.service
sudo systemctl disable apt-daily.service # disable run when system boot
sudo systemctl disable apt-daily.timer   # disable timer run
sudo systemctl mask apt-daily.service
sudo systemctl daemon-reload

# wait until `apt-get updated` has been killed
while ! (systemctl list-units --all apt-daily.service | egrep -q '(dead|failed)')
do
  sleep 1;
done


################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
    (
        set +o nounset

        if [ -z "${!1}" ]; then
            echo "Packer variable '$1' was not set. Aborting"
            exit 1
        fi
    )
}

validate_env_set BINARY_BUCKET_NAME
validate_env_set BINARY_BUCKET_REGION
validate_env_set DOCKER_VERSION
validate_env_set CNI_VERSION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
    ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
    ARCH="arm64"
else
    echo "Unknown machine architecture '$MACHINE'" >&2
    exit 1
fi

################################################################################
### Packages ###################################################################
################################################################################

# Update the OS to begin with to catch up to the latest packages.

sudo apt-get update -y

sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install necessary packages

sudo apt-get -y install software-properties-common
sudo apt-add-repository -y universe

sudo apt-get -y update

# Installing Python 2.7
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install python2.7
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install python-pip

sudo -H pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz

# pip3 installation of awscli gives a sane version
sudo apt-get -y install python3-pip
sudo pip3 install awscli

sudo apt-get -y install \
     chrony \
     conntrack \
     curl \
     jq \
     nfs-common \
     socat \
     unzip \
     wget


################################################################################
### Time #######################################################################
################################################################################

# Make sure that chronyd syncs RTC clock to the kernel.
cat <<EOF | sudo tee -a /etc/chrony.conf
# This directive enables kernel synchronisation (every 11 minutes) of the
# real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
rtcsync
EOF

# Make tsc the clock source
if grep --quiet tsc /sys/devices/system/clocksource/clocksource0/available_clocksource; then
    echo "tsc" | sudo tee /sys/devices/system/clocksource/clocksource0/current_clocksource
else
    echo "tsc as a clock source is not applicable, skipping."
fi

################################################################################
### Firewall ###################################################################
################################################################################

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo apt install -y -q iptables-persistent netfilter-persistent

sudo ufw default allow incoming
sudo ufw default allow outgoing

sudo bash -c "/sbin/iptables-save > /etc/iptables/rules.v4"
sudo netfilter-persistent save

sudo mv $TEMPLATE_DIR/iptables-restore.service /etc/systemd/system/iptables-restore.service

sudo systemctl daemon-reload
sudo systemctl enable iptables-restore

sudo mv $TEMPLATE_DIR/sysctl-sane /etc/sysctl.conf

################################################################################
### Docker #####################################################################
################################################################################

sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
if [[ "$INSTALL_DOCKER" == "true" ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

    sudo apt-key fingerprint 0EBFCD88

    sudo add-apt-repository \
       "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
       $(lsb_release -cs) \
       stable"

    sudo apt-get update

    sudo apt-get install -y \
         docker-ce \
         docker-ce-cli \
         containerd.io

    sudo usermod -aG docker $USER

    sudo mkdir -p /etc/docker
    sudo mv $TEMPLATE_DIR/docker-daemon.json /etc/docker/daemon.json
    sudo chown root:root /etc/docker/daemon.json

    # Enable docker daemon to start on boot.
    sudo systemctl daemon-reload
    sudo systemctl enable docker
fi

################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin



wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz
sudo tar -xvf cni-${ARCH}-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-${ARCH}-${CNI_VERSION}.tgz

wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGIN_VERSION}.tgz
sudo tar -xvf cni-plugins-linux-${ARCH}-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-linux-${ARCH}-${CNI_PLUGIN_VERSION}.tgz

echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="s3-$BINARY_BUCKET_REGION"
if [ "$BINARY_BUCKET_REGION" = "us-east-1" ]; then
    S3_DOMAIN="s3"
fi
S3_URL_BASE="https://$S3_DOMAIN.amazonaws.com/$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

BINARIES=(
    kubelet
    kubectl
    aws-iam-authenticator
)
for binary in ${BINARIES[*]} ; do
    if [[ ! -z "$AWS_ACCESS_KEY_ID" ]]; then
        echo "AWS cli present - using it to copy binaries from s3."
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary .
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary.sha256 .
    else
        echo "AWS cli missing - using wget to fetch binaries from s3. Note: This won't work for private bucket."
        sudo wget $S3_URL_BASE/$binary
        sudo wget $S3_URL_BASE/$binary.sha256
    fi
    sudo sha256sum -c $binary.sha256
    sudo chmod +x $binary
    sudo mv $binary /usr/bin/
done
sudo rm *.sha256

KUBELET_CONFIG=""
KUBERNETES_MINOR_VERSION=${KUBERNETES_VERSION%.*}
if [ "$KUBERNETES_MINOR_VERSION" = "1.10" ] || [ "$KUBERNETES_MINOR_VERSION" = "1.11" ]; then
    KUBELET_CONFIG=kubelet-config.json
else
    # For newer versions use this config to fix https://github.com/kubernetes/kubernetes/issues/74412.
    KUBELET_CONFIG=kubelet-config-with-secret-polling.json
fi

sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig
sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
sudo mv $TEMPLATE_DIR/$KUBELET_CONFIG /etc/kubernetes/kubelet/kubelet-config.json
sudo chown root:root /etc/kubernetes/kubelet/kubelet-config.json


sudo systemctl daemon-reload
# Disable the kubelet until the proper dropins have been configured
sudo systemctl disable kubelet

################################################################################
### EKS ########################################################################
################################################################################

sudo mkdir -p /etc/eks
sudo mv $TEMPLATE_DIR/eni-max-pods.txt /etc/eks/eni-max-pods.txt
sudo mv $TEMPLATE_DIR/bootstrap.sh /etc/eks/bootstrap.sh
sudo chmod +x /etc/eks/bootstrap.sh

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(curl -s  http://169.254.169.254/latest/meta-data/ami-id)
cat <<EOF > /tmp/release
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
ARCH="$(uname -m)"
EOF
sudo mv /tmp/release /etc/eks/release
sudo chown root:root /etc/eks/*

################################################################################
### Cleanup ####################################################################
################################################################################

# Clean up yum caches to reduce the image size
sudo apt-get clean
sudo rm -rf \
    $TEMPLATE_DIR

    sudo rm -rf \
        /etc/hostname \
        /etc/machine-id \
        /etc/ssh/ssh_host* \
        /home/ubuntu/.ssh/authorized_keys \
        /root/.ssh/authorized_keys \
        /var/lib/cloud/data \
        /var/lib/cloud/instance \
        /var/lib/cloud/instances \
        /var/lib/cloud/sem \
        /var/log/cloud-init-output.log \
        /var/log/cloud-init.log \
        /var/log/wtmp

    sudo touch /etc/machine-id
