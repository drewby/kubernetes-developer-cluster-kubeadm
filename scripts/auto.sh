#!/bin/bash

##################################
# automatically replaced with $USER (bash) or %USERNAME% (Windows)
export ME=akdc
##################################

# make some directories we will need
mkdir -p /home/${ME}/.ssh
mkdir -p /home/${ME}/.kube
mkdir -p /home/${ME}/bin
mkdir -p /home/${ME}/.local/bin
mkdir -p /home/${ME}/.k9s
mkdir -p /etc/containerd
mkdir -p /etc/systemd/system/docker.service.d
mkdir -p /etc/docker

cd /home/${ME}
echo "starting (1/15)" > status

cp /usr/share/zoneinfo/America/Chicago /etc/localtime

# create / add to groups
groupadd docker
usermod -aG sudo ${ME}
usermod -aG admin ${ME}
usermod -aG docker ${ME}
gpasswd -a ${ME} sudo

echo "${ME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/90-cloud-init-users

# oh my bash
git clone --depth=1 https://github.com/ohmybash/oh-my-bash.git .oh-my-bash
cp .oh-my-bash/templates/bashrc.osh-template .bashrc

# add to .bashrc
echo "" >> .bashrc
echo "alias k='kubectl'" >> .bashrc
echo "alias kga='kubectl get all'" >> .bashrc
echo "alias kgaa='kubectl get all --all-namespaces'" >> .bashrc
echo "alias kaf='kubectl apply -f'" >> .bashrc
echo "alias kdelf='kubectl delete -f'" >> .bashrc
echo "alias kl='kubectl logs'" >> .bashrc
echo "alias kccc='kubectl config current-context'" >> .bashrc
echo "alias kcgc='kubectl config get-contexts'" >> .bashrc

echo "export GO111MODULE=on" >> .bashrc
echo "alias ipconfig='ip -4 a show eth0 | grep inet | sed \"s/inet//g\" | sed \"s/ //g\" | cut -d / -f 1'" >> .bashrc
echo 'export PIP=$(ipconfig | tail -n 1)' >> .bashrc
echo 'export PATH="$PATH:$HOME/.dotnet/tools:$HOME/go/bin"' >> .bashrc
echo 'source /usr/share/bash-completion/bash_completion' >> .bashrc
echo 'source <(kubectl completion bash)' >> .bashrc
echo 'complete -F __start_kubectl k' >> .bashrc

# change ownership of home directory
chown -R ${ME}:${ME} /home/${ME}

# set the permissions on .ssh
chmod 700 /home/${ME}/.ssh
chmod 600 /home/${ME}/.ssh/*

# set the IP address
export PIP=$(ip -4 a show eth0 | grep inet | sed "s/inet//g" | sed "s/ //g" | cut -d '/' -f 1 | tail -n 1)

echo "updating (2/15)" >> status
apt-get update

echo "install base (3/15)" >> status
apt-get install -y apt-utils dialog apt-transport-https ca-certificates curl software-properties-common

echo "add repos (4/15)" >> status

# add Docker repo
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key --keyring /etc/apt/trusted.gpg.d/docker.gpg add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# add dotnet repo
echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-$(lsb_release -cs)-prod $(lsb_release -cs) main" > /etc/apt/sources.list.d/dotnetdev.list

# add Azure CLI repo
curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.asc.gpg
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/azure-cli.list

# add kubenetes repo
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list

apt-get update

echo "install utils (5/15)" >> status
apt-get install -y git wget nano jq zip unzip httpie dnsutils

echo "install libs (6/15)" >> status
apt-get install -y libssl-dev libffi-dev python-dev build-essential lsb-release gnupg-agent bash-completion

echo "install Azure CLI (7/15)" >> status
apt-get install -y azure-cli
echo "  (optional) you can run az login and az account set -s YourSubscriptionName now" >> status

echo "install k8s (8/15)" >> status
apt-get install -y containerd.io kubectl kubelet kubeadm kubernetes-cni

# Set up the Docker daemon to use systemd
cat <<'EOF' > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
  "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

# Setup required sysctl params
cat <<EOF >> /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# set network for containerd
cat <<EOF >> /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# config crictl to use containerd
cat <<EOF >> /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 2
debug: false
pull-image-on-create: true
EOF

# Apply sysctl params
sysctl --system

# apply network changes
modprobe overlay
modprobe br_netfilter

# Configure containerd
containerd config default > /etc/containerd/config.toml

# Restart containerd
systemctl restart containerd

echo "pulling images (9/15)" >> status
kubeadm config images pull

echo "kubeadm init (10/15)" >> status
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address $PIP --cri-socket /run/containerd/containerd.sock

echo "k8s setup (11/15)" >> status

# copy config file
cp -i /etc/kubernetes/admin.conf /home/${ME}/.kube/config

# add flannel network overlay
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml --namespace=kube-system

# add the taint to schedule normal pods on the control plane
#   this let you run a "one node" cluster for development
kubectl taint nodes --all node-role.kubernetes.io/master-

# patch kube-proxy for metal LB
kubectl get configmap kube-proxy -n kube-system -o yaml | \
sed -e "s/strictARP: false/strictARP: true/" | \
sed -e 's/mode: ""/mode: "ipvs"/' | \
kubectl apply -f - -n kube-system

# change ownership
chown -R ${ME}:${ME} /home/${ME}

echo "install docker (12/15)" >> status
apt-get install -y docker-ce docker-ce-cli

# upgrade Ubuntu
echo "upgrade (13/15)" >> status
apt-get dist-upgrade -y
apt-mark hold kubelet kubeadm kubectl

# CLI for CRI-compatible container runtimes
echo "install crictl (14/15)" >> status
VERSION=$(curl -i https://github.com/kubernetes-sigs/cri-tools/releases/latest | grep "location: https://github.com/" | rev | cut -f 1 -d / | rev | sed 's/\r//')
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
tar -zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-amd64.tar.gz

echo "install tools (15/15)" >> status
VERSION=$(curl -i https://github.com/derailed/k9s/releases/latest | grep "location: https://github.com/" | rev | cut -f 1 -d / | rev | sed 's/\r//')
wget https://github.com/derailed/k9s/releases/download/$VERSION/k9s_Linux_x86_64.tar.gz
tar -zxvf k9s_Linux_x86_64.tar.gz -C /usr/local/bin
rm -f k9s_Linux_x86_64.tar.gz

# kubectl auto complete
kubectl completion bash > /etc/bash_completion.d/kubectl
source /usr/share/bash-completion/bash_completion
source <(kubectl completion bash)
complete -F __start_kubectl k

# install jp (jmespath)
VERSION=$(curl -i https://github.com/jmespath/jp/releases/latest | grep "location: https://github.com/" | rev | cut -f 1 -d / | rev | sed 's/\r//')
wget https://github.com/jmespath/jp/releases/download/$VERSION/jp-linux-amd64 -O /usr/local/bin/jp
chmod +x /usr/local/bin/jp

echo "done" >> status
