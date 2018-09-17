#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins/.ssh"

if [[ -z "$WORKSPACE" ]] ; then
  echo "Please set WORKSPACE variable"
  exit 1
fi

export NUM=${NUM:-0}
export ENVIRONMENT_OS=${ENVIRONMENT_OS:-'centos'}
export TLS=${TLS:-'false'}
export DPDK=${DPDK:-'false'}
export TSN=${TSN:-'false'}
export SRIOV=${SRIOV:-'false'}
export CLEAN_ENV=${CLEAN_ENV:-'auto'}
export OPENSTACK_VERSION=${OPENSTACK_VERSION:-'newton'}
export RHEL_CERT_TEST=${RHEL_CERT_TEST:-'false'}
export CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
export CONTRAIL_CONTROLLER_COUNT=${CONTRAIL_CONTROLLER_COUNT:-1}
export CONTRAIL_ANALYTICS_COUNT=${CONTRAIL_ANALYTICS_COUNT:-1}
export CONTRAIL_ANALYTICSDB_COUNT=${CONTRAIL_ANALYTICSDB_COUNT:-1}
export NETWORK_ISOLATION=${NETWORK_ISOLATION:-'single'}
export BASE_ADDR=${BASE_ADDR:-172}
export USE_DEVELOPMENT_PUPPETS=${USE_DEVELOPMENT_PUPPETS:-true}
export CONTRAIL_SERIES=${CONTRAIL_SERIES:-'release'}

((env_addr=BASE_ADDR+NUM*10))
ip_addr="192.168.${env_addr}.2"
ssh_opts="-i $ssh_key_dir/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_addr="root@${ip_addr}"


function cleanup_environment() {
# /opt/jenkins/clean_env.sh is available for modifying only for root,
# this script should point to correct clean_env.sh.
# It should be set manually once during jenkins slave preparation.
  sudo -E /opt/jenkins/tripleo_contrail_clean_env.sh
}

function save_logs() {
  rm -rf logs
  mkdir logs
  scp $ssh_opts $ssh_addr:/home/stack/heat.log logs/heat.log
  for lf in `ssh $ssh_opts $ssh_addr ls /home/stack/*-logs.tar` ; do
    nm=`echo $lf | rev | cut -d '/' -f 1 | rev`
    scp $ssh_opts $ssh_addr:$lf $nm
    mkdir logs/$nm
    tar xf $nm -C logs/$nm
  done
  # patch +x flag for next archiving, rhcert doesnt have it
  chmod -R +x logs
}

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR

  # sleep some time to flush logs
  sleep 20
  save_logs

  if [[ $CLEAN_ENV == 'always' ]] ; then
    cleanup_environment
  fi

  exit $exit_code
}

trap 'catch_errors $LINENO' ERR

if [[ $CLEAN_ENV != 'never' ]] ; then
  cleanup_environment
fi

# /opt/jenkins/tripleo_contrail_deploy_all.sh is available for modifying only for root,
# this script should point to correct deploy_all.sh.
# It should be set manually once during jenkins slave preparation.
sudo -E /opt/jenkins/tripleo_contrail_deploy_all.sh "check-contrail-proxy.sh"

trap - ERR

save_logs

if [[ $CLEAN_ENV != 'never' && $CLEAN_ENV != 'before_only' ]] ; then
  cleanup_environment
fi
