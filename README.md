# Setup Kubernetes on Local Machine using Multipass & Kubespray 🎉 !

## Pre-req:
- **Python** 3.11.13
- **multipass** 1.16.3+mac
- **multipassd** 1.16.3+mac
- **git** version 2.50.1 (Apple Git-155)
- **uv** 0.11.28 (ebf0f43d7 2026-07-07 aarch64-apple-darwin)
- **ansible-playbook** [core 2.20.1]

## ⚙️ Create Python Virtual Environment
```
$ ./_00_create_pyenv.sh
$ source .venv/bin/activate
$ uv pip install --python .venv/bin/python ansible-core==2.18.0
```

## ⚙️ Provision Virtual Machines

### Generate SSH keys
```
$ mkdir .ssh && ssh-keygen -t rsa -b 4096 -C "administrator@edcelvista.com" -f .ssh/id_rsa
```

### Modify `cluster.env` to customize the cluster_
```
# Set desired Project Home
export PROJECT_HOME=/Users/edcelvista/Documents/edcel@leandevinc.com/CurrentFiles/DevOps/_k8s-multipass-build
export SSH_USER=ubuntu
# No Change - mkdir .ssh && ssh-keygen -t rsa -b 4096 -C "administrator@edcelvista.com" -f .ssh/id_rsa
export MULTIPASS_KEY=$PROJECT_HOME/.ssh/id_rsa
# Set Ubuntu version. 
export UBUNTU_REL=24.04
# Set desired number of nodes for multi-node K8s cluster. Set 2 if 8GB RAM.
# Best Practice: Odd number to prevent Split Brain 
export NODE_COUNT=2
# Desired multipass node name prefix
export NODE_PREFIX=edcelvistacom-local-
# Compute for the Virtual nodes
export CPU=2
export MEM=4G
# Disk can be expanded if required but can't be shrinked
export DISK=10G
# Set stable K8s version
export K8S_VERSION=v1.33.7
# Set Desired cluster name. Avoid using "." in cluster name for eg homelab.local. Cilium installation will fail.
export CLUSTER_NAME=edcelvistacom-k8s
# Cloud Init
export CLOUD_INIT=./cloud-init.yml
# Kubespray Version
export KUBESPRAY_VER=v2.29.0
# Multipass Binary
export MULTIPASS_BIN=/usr/local/bin/multipass
```

### Update `cloud-init.yml > users[].ssh_authorized_keys` with the correct public key.
```
package_update: true
package_upgrade: true
users:
  - default
  - name: ubuntu
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC6Jln3co3ajwBwYr+QIgxltLsdhAccy2Q3w+MsfiCWz2X3qTSzcKRoZAW54LaUSndYJzM8mt6T7hmtxfPyeiCUvYld0xn12bEuzpPvWeFem8EgODptUwzUyO91vbtmN1o7meQFU65p/tH0vs6srRzib58sSYIgnzCVLI4Ss2cBJvCqwn4d18meEekC6/Qj1f4jIHHP7Lt3tPk2bN5WwvqA30uu2G0YRaku+Nv0CardauBQLFmBcE1k5mRh7TrSQFKjn3xZbhVQ/gPM2HHtaA7RhdRG4c0/0E6sZAaCm1fjInG9JHyk6piLdu3KDMIHYf5/IbcGUiV+OSwLNCsnH4hU57zMlbhmWpTT1T8s3cJbOsAMhbvnPOLm6tUxho254hb8tmwuER4yZ0cQAQMPRybPfKOMQd3ket0ZvdodvfHOYT+Ybm6fo7t+hjsbobFOYFL8ppMlx20FH+rFix7dIypLsoMHitXRvtAzZ5mHf/DxfnY+EF+yalNrqb52qlmTVwjIvS0BaredNWYx0PfZWSSVwWSQKUk6bD5ErXGFTBDT1mPKmIRVE023h0q1AytlUSz/aBaWniLe/Ui76SIk6MNOI8H2kNbY8RW2NE4LkVuYnlPE9N+h7HFImDYfd+kHeJqZZN8xmTSHpMomXGLv0ucf/yd2PUor5pnbtoPk4W0CqQ== administrator@edcelvista.com
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: False
packages:
  - net-tools
  - python3
  - python3-pip
  - python3-venv
# Run additional commands after setup:
runcmd:
  - echo 'VM setup complete!' > /tmp/cloud-init.log
  # - curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Cluster Provisioning
```
$ ./_01_init-vms.sh -a init
```
## Scaling - Add new nodes

### Modify `cluster.env` to customize the cluster
```
export NODE_COUNT=3
```

```
$ ./_01_init-vms.sh -a scale
```

## Custom RUN e.g. kube-api cert SSL Regenerate with new SANs
```
# If your goal is only to add a new DNS name or IP to the API server certificate, you do not need to rerun the full cluster.yml. A minimal sequence is:
.venv/bin/ansible-playbook -i ./inventory/k8cluster/hosts.yml ./cluster.yml -e "@hardening.yml" -e ansible_user=ubuntu -b --become-user=root --tags facts,control-plane
```