#!/bin/bash -ex

# suffix for deployment
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=newton)"
  exit 1
fi

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

if [[ -z "$DPDK" ]] ; then
  echo "DPDK is expected (e.g. export DPDK=true/false)"
  exit 1
fi

if [[ -z "$TSN" ]] ; then
  echo "TSN is expected (e.g. export TSN=true/false)"
  exit 1
fi

if [[ -z "$SRIOV" ]] ; then
  echo "SRIOV is expected (e.g. export SRIOV=true/false)"
  exit 1
fi

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ -z "$RHEL_ACCOUNT_FILE" ]] ; then
    echo "ERROR: for rhel environemnt the environment variable RHEL_ACCOUNT_FILE is required"
    exit 1
  fi
else
  if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
    echo "ERROR: RHEL_CERT_TEST is supported only for RHEL environment"
    exit 1
  fi
fi

# VBMC base port for IPMI management
(( VBMC_PORT_BASE_DEFAULT=16000 + NUM*100))
VBMC_PORT_BASE=${VBMC_PORT_BASE:-${VBMC_PORT_BASE_DEFAULT}}


if [[ "$DPDK" == 'true' ]] ; then
  compute_machine_name='compdpdk'
elif [[ "$TSN" == 'true' ]] ; then
  compute_machine_name='comptsn'
else
  compute_machine_name='comp'
fi

RHEL_CERT_TEST=${RHEL_CERT_TEST:-'false'}

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins/.ssh"

# base image for VMs
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.qcow2"
else
  DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.qcow2"
fi
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
mkdir -p ${BASE_IMAGE_DIR}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"
echo BASE_IMAGE $BASE_IMAGE

# network names and settings
(( netnum=100+$NUM*10 ))
NET_ADDR_MGMT=${NET_ADDR_MGMT:-"192.168.${netnum}.0"}
(( netnum+=5 ))
NET_ADDR_PROV=${NET_ADDR_PROV:-"192.168.${netnum}.0"}

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-0}
CONTRAIL_CONTROLLER_COUNT=${CONTRAIL_CONTROLLER_COUNT:-1}
CONTRAIL_ANALYTICS_COUNT=${CONTRAIL_ANALYTICS_COUNT:-1}
CONTRAIL_ANALYTICSDB_COUNT=${CONTRAIL_ANALYTICSDB_COUNT:-1}

# ready image for undercloud - using CentOS cloud image. just run and ssh into it.
if [[ ! -f ${BASE_IMAGE} ]] ; then
  if [[ "$ENVIRONMENT_OS" == "centos" ]] ; then
    wget -O ${BASE_IMAGE} https://cloud.centos.org/centos/7/images/${BASE_IMAGE_NAME}
  else
    echo "Download of image is implemented only for CentOS based environment"
    exit 1
  fi
fi

# disk size for overcloud machines
vm_disk_size="30G"

net_driver=${net_driver:-e1000}

source "$my_dir/env_desc.sh"
source "$my_dir/../common/virsh/functions"

# check if environment is present
assert_env_exists $undercloud_vmname

# define MAC's
mgmt_mac="00:16:00:00:0$NUM:02"
mgmt_mac_cert="00:16:00:01:0$NUM:02"
mgmt_cert_ip="${mgmt_subnet}.3"

prov_mac="00:16:00:00:0$NUM:06"
prov_mac_cert="00:16:00:01:0$NUM:06"
prov_cert_ip="${prov_subnet}.3"

# create networks and setup DHCP rules
create_network_dhcp $NET_NAME_MGMT $mgmt_subnet $BRIDGE_NAME_MGMT
update_network_dhcp $NET_NAME_MGMT $undercloud_vmname $mgmt_mac $mgmt_ip
update_network_dhcp $NET_NAME_MGMT $undercloud_cert_vmname $mgmt_mac_cert $mgmt_cert_ip

create_network_dhcp $NET_NAME_PROV $prov_subnet $BRIDGE_NAME_PROV
update_network_dhcp $NET_NAME_PROV $undercloud_vmname $prov_mac $prov_ip
update_network_dhcp $NET_NAME_PROV $undercloud_cert_vmname $prov_mac_cert $prov_cert_ip

# create pool
create_pool $poolname
pool_path=$(get_pool_path $poolname)

function create_root_volume() {
  local name=$1
  create_volume $name $poolname $vm_disk_size
}

function create_store_volume() {
  local name="${1}-store"
  create_volume $name $poolname 100G
}

function define_overcloud_vms() {
  local name=$1
  local count=$2
  local mem=$3
  local vbmc_port=$4
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vol_name="overcloud-$NUM-${name}-$i"
      create_root_volume $vol_name
      local vm_name="rd-$vol_name"
      define_machine $vm_name 2 $mem rhel7 $NET_NAME_PROV "${pool_path}/${vol_name}.qcow2"
      start_vbmc $vbmc_port $vm_name $mgmt_gateway stack qwe123QWE
      (( vbmc_port+=1 ))
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

CTRL_MEM=8192
COMP_MEM=4096
if [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then
  CTRL_MEM=24576
  COMP_MEM=8192
fi

# just define overcloud machines
vbmc_port=$VBMC_PORT_BASE
define_overcloud_vms 'cont' $CONTROLLER_COUNT 8192 $vbmc_port
(( vbmc_port+=CONTROLLER_COUNT ))
define_overcloud_vms $compute_machine_name $COMPUTE_COUNT $COMP_MEM $vbmc_port
(( vbmc_port+=COMPUTE_COUNT ))
define_overcloud_vms 'stor' $STORAGE_COUNT 4096 $vbmc_port
(( vbmc_port+=STORAGE_COUNT ))
define_overcloud_vms 'ctrlcont' $CONTRAIL_CONTROLLER_COUNT $CTRL_MEM $vbmc_port
(( vbmc_port+=CONTRAIL_CONTROLLER_COUNT ))
define_overcloud_vms 'ctrlanalytics' $CONTRAIL_ANALYTICS_COUNT 4096 $vbmc_port
(( vbmc_port+=CONTRAIL_ANALYTICS_COUNT ))
define_overcloud_vms 'ctrlanalyticsdb' $CONTRAIL_ANALYTICSDB_COUNT 8192 $vbmc_port
(( vbmc_port+=CONTRAIL_ANALYTICSDB_COUNT ))

# copy image for undercloud and resize them
cp -p $BASE_IMAGE $pool_path/$undercloud_vm_volume

# for RHEL make a copy of disk to run one more VM for test server
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
    cp $pool_path/$undercloud_vm_volume $pool_path/$undercloud_cert_vm_volume
  fi
fi

#check that nbd kernel module is loaded
if ! lsmod |grep '^nbd ' ; then
  modprobe nbd max_part=8
fi

function _start_vm() {
  local name=$1
  local image=$2
  local mgmt_mac=$3
  local prov_mac=$4
  local ram=${5:-16384}

  # define and start machine
  virt-install --name=$name \
    --ram=$ram \
    --vcpus=2,cores=2 \
    --cpu host \
    --memorybacking hugepages=on \
    --os-type=linux \
    --os-variant=rhel7 \
    --virt-type=kvm \
    --disk "path=$image",size=40,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --boot hd \
    --noautoconsole \
    --network network=$NET_NAME_MGMT,model=$net_driver,mac=$mgmt_mac \
    --network network=$NET_NAME_PROV,model=$net_driver,mac=$prov_mac \
    --graphics vnc,listen=0.0.0.0
}

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  rhel_register_system_and_customize "$pool_path/$undercloud_vm_volume" 'undercloud'
fi

_start_vm $undercloud_vmname "$pool_path/$undercloud_vm_volume" \
  $mgmt_mac $prov_mac

if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
  rhel_register_system_and_customize "$pool_path/$undercloud_cert_vm_volume" 'undercloud'

  _start_vm \
    undercloud_cert_vmname "$pool_path/$undercloud_cert_vm_volume" \
    $mgmt_mac_cert $prov_mac_cert 4096
fi


ssh_opts="-i $ssh_key_dir/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_cmd="ssh -T $ssh_opts"

# wait for undercloud machine
function _wait_machine() {
  local addr=$1
  wait_ssh $addr "$ssh_key_dir/id_rsa"
}

function _prepare_network() {
  local addr=$1
  local my_host=$2
  local short_host=$(echo $my_host | cut -d '.' -f 1)
  cat <<EOF | $ssh_cmd root@${addr}
set -x
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf
hostnamectl set-hostname $my_host
hostnamectl set-hostname --transient $my_host
echo "$addr       $my_host $short_host" > /etc/hosts
echo "127.0.0.1   localhost" >> /etc/hosts
systemctl restart network
sleep 5
EOF
}

function _update_contrail_packages() {
  aws s3 sync s3://contrailrhel7 $CONTRAIL_PACKAGES_DIR
}

function _prepare_contrail() {
  local addr=$1
  local tmpdir=$(mktemp -d)

  # copy stack's keys
  scp $ssh_opts /home/stack/.ssh/id_rsa root@${addr}:/root/stack_id_rsa
  scp $ssh_opts /home/stack/.ssh/id_rsa.pub root@${addr}:/root/stack_id_rsa.pub

  # prepare contrail pkgs
  if [[ "$CONTRAIL_SERIES" == 'release' ]] ; then
    build_series=''
  else
    build_series='cb-'
  fi
  if [[ "$prepare_contrail_pkgs" == 'yes' ]] ; then
    mkdir -p $tmpdir/contrail_packages
    latest_ver_rpm=`ls ${CONTRAIL_PACKAGES_DIR}/${build_series}contrail-install* -vr  | grep $CONTRAIL_VERSION | grep $OPENSTACK_VERSION | head -n1`
    cp $latest_ver_rpm $tmpdir/contrail_packages/
    # WORKAROUND to bug #1767456
    # TODO: remove net-snmp after fix bug #1767456
    mkdir -p $tmpdir/contrail_packages/net_snmp
    cp /home/jenkins/net-snmp/* $tmpdir/contrail_packages/net_snmp/
    scp $ssh_opts -r $tmpdir/contrail_packages root@${addr}:/root/
    rm -rf $tmpdir || ret=3
  fi
}

function _prepare_rhel_account() {
  local addr=$1
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    local tmpdir=$(mktemp -d)
    local rhel_account_file_dir=$(dirname "$RHEL_ACCOUNT_FILE")
    local rhel_account_file_name=$(echo $RHEL_ACCOUNT_FILE | awk -F '/' '{print($NF)}')
    mkdir -p $tmpdir/$rhel_account_file_dir
    cp $RHEL_ACCOUNT_FILE $tmpdir/$rhel_account_file_dir/
    cat <<EOF >> $tmpdir/$rhel_account_file_dir/$rhel_account_file_name
export RHEL_REPOS="$(rhel_get_repos_for_os | tr ' ' ',')"
EOF
    chmod -R 644 $tmpdir/$rhel_account_file_dir
    chmod +x $tmpdir/$rhel_account_file_dir
    scp $ssh_opts -r $tmpdir/$rhel_account_file_dir root@${addr}:/
    rm -rf $tmpdir || ret=3
  fi
}

function _prepare_host() {
  local addr=$1
  if [[ "$ENVIRONMENT_OS" != 'rhel' ]] ; then
    return
  fi
  # copy base image
  local env_os_ver=$(echo ${ENVIRONMENT_OS_VERSION:-'7_5'} | tr '_' '.')
  scp $ssh_opts /home/root/images/rhel-server-${env_os_ver}-x86_64-kvm.qcow2 \
    root@${addr}:/root/overcloud-base-image.qcow2
  # rhel registration
  set +x
  . $RHEL_ACCOUNT_FILE
  local register_opts=''
  [ -n "$RHEL_USER" ] && register_opts+=" --username $RHEL_USER"
  [ -n "$RHEL_PASSWORD" ] && register_opts+=" --password $RHEL_PASSWORD"
  [ -n "$RHEL_ORG" ] && register_opts+=" --org $RHEL_ORG"
  [ -n "$RHEL_ACTIVATION_KEY" ] && register_opts+=" --activationkey $RHEL_ACTIVATION_KEY"
  set -x
  local attach_opts='--auto'
  if [[ -n "$RHEL_POOL_ID" ]] ; then
    attach_opts="--pool $RHEL_POOL_ID"
  fi
  local repos_list=$(rhel_get_repos_for_os)
  local repos_opts=''
  declare r
  for r in $repos_list ; do
    repos_opts+=" --enable=$r"
  done
  echo "INFO: enable repos: $repos_list"

  cat <<EOF | $ssh_cmd root@${addr}
subscription-manager unregister || true
subscription-manager register $register_opts
subscription-manager attach $attach_opts
subscription-manager repos $repos_opts
EOF
}

_update_contrail_packages

# wait udnercloud and register it in redhat if rhel env
_wait_machine $mgmt_ip
_prepare_network $mgmt_ip "myhost.my${NUM}domain"
_prepare_contrail $mgmt_ip
_prepare_rhel_account $mgmt_ip
_prepare_host $mgmt_ip

if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
  _wait_machine $mgmt_cert_ip
  _prepare_network $mgmt_cert_ip "myhost.my${NUM}certdomain"
  _prepare_rhel_account $mgmt_cert_ip
  _prepare_host $mgmt_cert_ip

  cat <<EOF | $ssh_cmd $mgmt_cert_ip
set -x
iptables -I INPUT 1 -p udp -m multiport --dports 8009 -m comment --comment \"rhcertd\" -m state --state NEW -j ACCEPT
iptables -I INPUT 1 -p tcp -m multiport --dports 8009 -m comment --comment \"rhcertd\" -m state --state NEW -j ACCEPT
iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -m comment --comment \"http_https\" -m state --state NEW -j ACCEPT
yum install -y redhat-certification
systemctl start httpd
rhcertd start
sed -i "s/ALLOWED_HOSTS =.*/ALLOWED_HOSTS = ['myhost.my${NUM}certdomain', '$mgmt_cert_ip', '$prov_cert_ip', 'localhost.localdomain', 'localhost', '127.0.0.1']/" /var/www/rhcert/project/settings.py
systemctl restart httpd
EOF

fi
