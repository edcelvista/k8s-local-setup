#!/bin/bash
set -e
set -o pipefail
set -u

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m"  # No Color

source ./cluster.env

declare TMP_DIR="./tmp"
declare CFG_DIR=".cfg"
declare STATE_FILE="state.log"
declare KUBESPRAYPATH="./kubespray"

info(){
  echo -e "✅ [INFO] $1\n"
}

warn(){
  echo -e "⚠️ [WARN] $1\n"
}

fatal(){
  echo -e "❌ ERROR] $1\n"
  exit 1
}

checkBinary(){
  local listOfBins=$1
  for cmd in $listOfBins; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      fatal "$cmd is missing"
    else
      info "$cmd is installed"
    fi
  done
}

checkFileExists(){
  local file=$1
  if [ ! -f "$file" ]; then
    fatal "$file not found..."
  else
    info "$file found!"
  fi
}

checkIfZip(){
  local file=$1
  if ! file "$file" | grep -q "Zip archive"; then
    fatal "$file Package not zip file..."
  fi
}

isEmpty() { # if isEmpty "$HCV_URI"; then
  [[ -z "$(xargs <<<"$1")" ]]
}

folderExists() { # if folderExists "$DIR"; then
  [[ -d "$1" ]]
}

fileExists() { # if fileExists "$FILE"; then
  [[ -f "$1" ]]
}

fileContains() { # if fileContains "file.txt" "hello"; then
  grep -qF -- "$2" "$1"
}

runExitOnError() { # runExitOnError uv venv
  "$@"  # executes the command exactly as passed
  rc=$?

  if [ $rc -ne 0 ]; then
    fatal "Command failed (exit=$rc): $*"
    return $rc
  fi

  info "Command succeeded: $*"
}

flightCheck(){
  for cmd in pip3 python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      fatal "$cmd is missing"
    else
      info "$cmd is installed"
    fi
  done
}

createTmpDir(){
  TMP_DIR=$(mktemp -d)
  info "Temp dir created: $TMP_DIR"
}

createDirIfNotExists(){
  if [[ ! -e "$1" ]]; then
    mkdir -p $1
  fi
}

createFileIfNotExists(){
  if [[ ! -f "$1" ]]; then
    touch $1
  fi
}

cleanup(){
  rm -rf $TMP_DIR
}

usage(){
  fatal "Usage: $0 -a <action | init,scale>"
}

init(){
  info "Initializing, checking env and cloud-init configuration..."

  if python3 -c "import sys; raise SystemExit(0 if sys.prefix != getattr(sys, 'base_prefix', sys.prefix) else 1)"; then
    info "Virtual environment is active"
  else
    fatal "No virtual environment...RUN: ./_00_create_pyenv.sh"
  fi
  
  checkBinary "python3 pip3 git uv $MULTIPASS_BIN sed ansible-playbook"  
  createTmpDir
  checkFileExists "$CLOUD_INIT"
  flightCheck
  createDirIfNotExists "$CFG_DIR"
  createFileIfNotExists "$PROJECT_HOME/$CFG_DIR/$STATE_FILE"

  KUBESPRAYPATH="$PROJECT_HOME/kubespray"
}

displayConfig(){
  info "VM Configuration:"
  echo "    PROJECT_HOME: $PROJECT_HOME"
  echo "    MULTIPASS_KEY: $MULTIPASS_KEY"
  echo "    UBUNTU_REL: $UBUNTU_REL"
  echo "    NODE_COUNT: $NODE_COUNT"
  echo "    NODE_PREFIX: $NODE_PREFIX"
  echo "    CPU: $CPU"
  echo "    MEM: $MEM"
  echo "    DISK: $DISK"
  echo "    K8S_VERSION: $K8S_VERSION"
  echo "    CLUSTER_NAME: $CLUSTER_NAME"
  echo "    CLOUD_INIT: $CLOUD_INIT"
  echo "    KUBESPRAY_VER: $KUBESPRAY_VER"
  
  echo
  info "Cloud Init Configuration:"
  cat $CLOUD_INIT

  echo
  echo
}

provision(){
  info "🖥️ Provisioning VMs..."
  count=1
  until [ $count -gt $NODE_COUNT ]
  do  
    if $MULTIPASS_BIN list | awk '{print $1}' | grep -x "$NODE_PREFIX$count"; then
      warn "$NODE_PREFIX$count already exists... ignoring.."
        if [[ "$($MULTIPASS_BIN list | awk '$1 == "'$NODE_PREFIX$count'" {print $2}')" == "Stopped" ]]; then
          warn "⚡️ $NODE_PREFIX$count is Stopped. Starting VM..."
          $MULTIPASS_BIN start "$NODE_PREFIX$count"
        fi
      ((count=count+1))
      continue
    fi
    $MULTIPASS_BIN launch $UBUNTU_REL -n "$NODE_PREFIX$count" -c $CPU -m $MEM -d $DISK --cloud-init ./cloud-init.yml
    ((count=count+1))
  done

  info "🖥️ VM list..."
  $MULTIPASS_BIN list
}

cloneKubeSpray(){
  local state="clone-kubespray"
  local ENVPY=".venv/bin/python"
  
  if fileContains "$PROJECT_HOME/$CFG_DIR/$STATE_FILE" "$state"; then
    warn "🎉 Skipping $state... already completed..."
  else
    echo
    info "📦 Getting Kubespray Package..."
    if folderExists "./kubespray"; then
      warn "⚡️ Kubespray Directory exists... ignoring clone..."
    else
      git clone --branch $KUBESPRAY_VER --single-branch https://github.com/kubernetes-sigs/kubespray.git && cd $KUBESPRAYPATH
    fi

    info "📁 Changing Working Dir: $KUBESPRAYPATH"
    cd $KUBESPRAYPATH && git reflog
    if folderExists "$KUBESPRAYPATH/.venv"; then
      warn "⚡️ .venv Directory exists... ignoring creating py virutal env..."
    else
      uv venv && uv pip install --python $KUBESPRAYPATH/$ENVPY -r requirements.txt
    fi

    info "📦 Checking require packages..."
    uv pip check --python $KUBESPRAYPATH/$ENVPY && uv pip list --python $KUBESPRAYPATH/$ENVPY

    echo "$state" >> $PROJECT_HOME/$CFG_DIR/$STATE_FILE
  fi
}

setupKubeSpray(){
  local state="setup-kubespray"
  
  local ENVPY=".venv/bin/python"
  local INVENTORYBUILDERPATH="$KUBESPRAYPATH/contrib/inventory_builder"
  
  if fileContains "$PROJECT_HOME/$CFG_DIR/$STATE_FILE" "$state"; then
    warn "⚡️ Skipping $state... already completed..."
  else
    ## ANSIBLE CFG SETUP
    echo
    info "⚙️ Setting up kubespray config... appending values after [defaults] in ansible.cfg"

    info "📁 Changing Working Dir: $KUBESPRAYPATH"
    cd $KUBESPRAYPATH
    if ! fileContains "ansible.cfg" "private_key_file"; then
    sed -i '' '/^\[defaults\]/a\
private_key_file = '"$MULTIPASS_KEY"' \
    ' ansible.cfg
    else
      warn "⚡️ skipping appending private_key_file in $KUBESPRAYPATH/ansible.cfg already exists..."
    fi

    if ! fileContains "ansible.cfg" "log_path"; then
    sed -i '' '/^\[defaults\]/a\
log_path = '"$PROJECT_HOME"'/kubespray/playbook.log \
    ' ansible.cfg
    else
      warn "⚡️ skipping appending log_path in $KUBESPRAYPATH/ansible.cfg already exists..."
    fi

    if ! fileContains "ansible.cfg" "interpreter_python"; then
    sed -i '' '/^\[defaults\]/a\
interpreter_python = /usr/bin/python3.12 \
    ' ansible.cfg
    else
      warn "⚡️ skipping appending interpreter_python in $KUBESPRAYPATH/ansible.cfg already exists..."
    fi

    info "Starting KubeSpray Configuration Setup..."

    info "Deleting default variable files inside inventory..."
    if folderExists "$KUBESPRAYPATH/inventory/local"; then
      rm -rf $KUBESPRAYPATH/inventory/local
    fi
    if folderExists "$KUBESPRAYPATH/inventory/sample"; then
      rm -rf $KUBESPRAYPATH/inventory/local
    fi

    ## HARDENING
    info "Copying hardening.yml to kubespray directory..."
    cp $PROJECT_HOME/hardening.yml $KUBESPRAYPATH/hardening.yml

    info "Creating new inventory from sample..."
    cp -rfp $KUBESPRAYPATH/inventory/sample $KUBESPRAYPATH/inventory/k8cluster # NOTE ymls under sample will not be used. unless inventory.ini under sample are used.

    info "Backing up original files..."
    info "Changing Working Dir: $KUBESPRAYPATH/inventory/k8cluster/group_vars/k8s_cluster"
    cd $KUBESPRAYPATH/inventory/k8cluster/group_vars/k8s_cluster && cp k8s-cluster.yml k8s-cluster.yml.BAK ; cp addons.yml addons.yml.BAK ; mv k8s-net-custom-cni.yml k8s-net-custom-cni.yml.BAK

    info "Setting up custom_cni configuration..."
    cp $PROJECT_HOME/k8s-net-custom-cni.yml $KUBESPRAYPATH/inventory/k8cluster/group_vars/k8s_cluster/k8s-net-custom-cni.yml

    info "Set K8s version" # TODO CHECK if has effect
    sed -i '' "s~^kube_version:.*~kube_version: $K8S_VERSION~g" k8s-cluster.yml

    info "Set cluster name"
    sed -i '' "s~^cluster_name:.*~cluster_name: $CLUSTER_NAME~g" k8s-cluster.yml

    info "Set network plugin to custom_cni."
    sed -i '' 's~^kube_network_plugin:.*~kube_network_plugin: custom_cni~g' k8s-cluster.yml

    info "Enable encryption of secret data at rest in etcd"
    sed -i '' 's~^kube_encrypt_secret_data:.*~kube_encrypt_secret_data: true~g' k8s-cluster.yml

    info "Setting Auto renew certs."
    sed -i '' 's~^auto_renew_certificates:.*~auto_renew_certificates: true~g' k8s-cluster.yml

    # info "Install Kubernetes dashboard"
    # sed -i '' "s~^# dashboard_enabled:.*~dashboard_enabled: true~g" addons.yml

    info "Install Helm client"
    sed -i '' "s~^helm_enabled:.*~helm_enabled: true~g" addons.yml

    info "Install metrics server"
    sed -i '' "s~^metrics_server_enabled:.*~metrics_server_enabled: true~g" addons.yml

    info "Enable NTP sync"
    info "📁 Changing Working Dir: $KUBESPRAYPATH/inventory/k8cluster/group_vars/all"
    cd $KUBESPRAYPATH/inventory/k8cluster/group_vars/all && cp all.yml all.yml.BAK && cp etcd.yml etcd.yml.BAK
    sed -i '' "s~^ntp_enabled:.*~ntp_enabled: true~g" all.yml

    info "Deploy etcd with kubeadm"
    cd $KUBESPRAYPATH/inventory/k8cluster/group_vars/all && cp etcd.yml etcd.yml.BAK
    sed -i '' "s~^etcd_deployment_type:.*~etcd_deployment_type: kubeadm~g" etcd.yml

    echo "$state" >> $PROJECT_HOME/$CFG_DIR/$STATE_FILE
  fi

  ## INVENTORY SETUP
  info "⚙️ Generate ansible host inventory..."
  if ! folderExists "$INVENTORYBUILDERPATH"; then
    warn "Trying to fix missing inventory builder..."
    cp -r $PROJECT_HOME/libs/inventory_builder $INVENTORYBUILDERPATH
    if ! folderExists "$INVENTORYBUILDERPATH"; then
      fatal "Missing inventory builder dependecy..."
    fi
  fi
  
  info "📁 Changing Working Dir: $INVENTORYBUILDERPATH"
  cd $INVENTORYBUILDERPATH
  if folderExists "$INVENTORYBUILDERPATH/.venv"; then
    warn "⚡️ .venv Directory exists... ignoring creating py virutal env..."
  else
    uv venv && uv pip install --python $ENVPY -r requirements.txt
  fi

  info "⚡️ Updating Inventory Host for new VMs detected..."

  declare -a IPS=( $($MULTIPASS_BIN list --format csv |tail -n +2 |cut -d "," -f3 | xargs) ) && \
  CONFIG_FILE=$KUBESPRAYPATH/inventory/k8cluster/hosts.yml HOST_PREFIX=$NODE_PREFIX $INVENTORYBUILDERPATH/$ENVPY $INVENTORYBUILDERPATH/inventory.py ${IPS[@]}

  cp $PROJECT_HOME/misc.yml $KUBESPRAYPATH/inventory/k8cluster/group_vars/k8s_cluster/misc.yml

  if [[ "$(printf '%s' "$RESOLVABLE_HOSTS" | tr '[:upper:]' '[:lower:]')" == "false" ]]; then
    info "Setting up other vars e.g. DNS ETC HOSTS"
    ETC_HOST_IPS=$($MULTIPASS_BIN list --format csv | awk -F',' 'NR>1{print "  "$3" "$1}')
    echo """
dns_etchosts: |
$ETC_HOST_IPS
    """ >> $KUBESPRAYPATH/inventory/k8cluster/group_vars/k8s_cluster/misc.yml
  fi

  IPS_CSV=$(IFS=,; echo "${IPS[*]}")
  sed -i '' "s~^# supplementary_addresses_in_ssl_keys:.*~supplementary_addresses_in_ssl_keys: [$IPS_CSV,$KUBE_API_SAN]~g" $KUBESPRAYPATH/inventory/k8cluster/group_vars/k8s_cluster/k8s-cluster.yml

  echo
  info "⚙️ Generated Hosts file $KUBESPRAYPATH/inventory/k8cluster/hosts.yml ..."
  cat $KUBESPRAYPATH/inventory/k8cluster/hosts.yml
}

initialBootstrap(){
  local state="init-bootstrap"

  echo
  info "⚡️ Running Initial Bootstrap Step..."
  info "📁 Changing Working Dir: $KUBESPRAYPATH"

  cd $KUBESPRAYPATH && \
  ANSIBLE_CONFIG=$KUBESPRAYPATH/ansible.cfg \
  .venv/bin/ansible-playbook -i $KUBESPRAYPATH/inventory/k8cluster/hosts.yml $PROJECT_HOME/initialsetup.yml -e ansible_user=$SSH_USER
}

bootstrapK8s(){
  info "⚡️ Run the deployment with Hardening Profile..."
  info "📁 Changing Working Dir: $KUBESPRAYPATH"
  cd $KUBESPRAYPATH && .venv/bin/ansible-playbook -i ./inventory/k8cluster/hosts.yml ./cluster.yml -e "@hardening.yml" -e ansible_user=$SSH_USER -b --become-user=root
}

scaleK8s(){
  info "⚡️ Run the deployment with Hardening Profile..."
  info "📁 Changing Working Dir: $KUBESPRAYPATH"
  cd $KUBESPRAYPATH && .venv/bin/ansible-playbook -i ./inventory/k8cluster/hosts.yml ./scale.yml -e "@hardening.yml" -e ansible_user=$SSH_USER -b --become-user=root
}

_initProvision(){

  read -rp "📦 Provision the VMs via $MULTIPASS_BIN - Continue? (y/n): " answer

  case "$answer" in
    [Yy]|[Yy][Ee][Ss])
      echo
      info "Continuing..."
      provision
      cloneKubeSpray
      setupKubeSpray
      initialBootstrap

      read -rp "Modify the ./kubespray/inventory/k8cluster/hosts.yml to arrange the nodes & Continue? (y/n): " answer

      case "$answer" in
        [Yy]|[Yy][Ee][Ss])
          echo "Continuing..."
            info "Host Configuration:"
            cat $KUBESPRAYPATH/inventory/k8cluster/hosts.yml
            bootstrapK8s
          ;;
        [Nn]|[Nn][Oo])
          echo "Aborting.."
          exit 0
          ;;
        *)
          echo "Invalid input. Please enter y or n."
          exit 1
          ;;
      esac

      ;;
    [Nn]|[Nn][Oo])
      warn "Aborting..."
      ;;
    *)
      info "Invalid input. Please enter y or n."
      ;;
  esac
}

_scale(){
  read -rp "📦 Scale the VMs via $MULTIPASS_BIN - Continue? (y/n): " answer

  case "$answer" in
  [Yy]|[Yy][Ee][Ss])
    echo
    info "You selected Yes"
    provision
    cloneKubeSpray
    setupKubeSpray
    initialBootstrap

    read -rp "Modify the ./kubespray/inventory/k8cluster/hosts.yml to arrange the nodes & Continue? (y/n): " answer

    case "$answer" in
      [Yy]|[Yy][Ee][Ss])
        echo "Continuing..."
          scaleK8s
        ;;
      [Nn]|[Nn][Oo])
        echo "Aborting.."
        exit 0
        ;;
      *)
        echo "Invalid input. Please enter y or n."
        exit 1
        ;;
    esac

    ;;
  [Nn]|[Nn][Oo])
    warn "Aborting..."
    ;;
  *)
    info "Invalid input. Please enter y or n."
    ;;
  esac
}

_labelWorkerNodes(){
  multipass exec "${NODE_PREFIX}1" -- bash -c "sudo kubectl get nodes --no-headers | awk '\$3 != \"control-plane\" {print \$1}' | while read n; do sudo kubectl label node \$n node-role.kubernetes.io/worker=worker; done"
}

## RUN ###
trap cleanup EXIT

if [[ -z "${1:-}" ]]; then
  usage
fi

if [[ "$1" != "-a" ]]; then
  usage
fi

case "$2" in
  init)
    init
    displayConfig
    _initProvision
    _labelWorkerNodes
    ;;
  scale)
    init
    displayConfig
    _scale
    _labelWorkerNodes
    ;;
  *)
    warn "Unknown action: $2"
    fatal "Valid actions: init, scale"
    ;;
esac
