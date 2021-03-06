#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh || /bin/true
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

# definition for job deployment
source $my_dir/${HOST}-defs
source $my_dir/../common/functions
source $my_dir/../common/check-functions

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs '2,3'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

for dest in $nodes_ips ; do
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@${dest}:./
done
$my_dir/setup-nodes.sh

run_env=''
if [[ "$CONTAINER_REGISTRY" == 'build' || "$CONTAINER_REGISTRY" == 'fullbuild' ]]; then
  build_containers
  run_env="CONTRAIL_REGISTRY=$build_ip:5000 CONTRAIL_VERSION=$CONTRAIL_VERSION REGISTRY_INSECURE=1"
  run_env+=" CONTRAIL_CONTAINER_TAG=${OPENSTACK_VERSION}-${CONTRAIL_VERSION}"
else
  run_env="CONTRAIL_REGISTRY=$CONTAINER_REGISTRY REGISTRY_INSECURE=0"
  run_env+=" CONTRAIL_CONTAINER_TAG=$CONTRAIL_VERSION"
fi

# when compute has only one interface dpdk images must be pre-pulled to avoid errors when network is not initialized yet
eval $run_env
for dest in $nodes_comp_ips ; do
  cat <<EOF | $SSH_CMD ${SSH_USER}@$dest
docker pull $CONTRAIL_REGISTRY/contrail-vrouter-agent:$CONTRAIL_CONTAINER_TAG
docker pull $CONTRAIL_REGISTRY/contrail-vrouter-agent-dpdk:$CONTRAIL_CONTAINER_TAG
docker pull $CONTRAIL_REGISTRY/contrail-vrouter-kernel-init:$CONTRAIL_CONTAINER_TAG
docker pull $CONTRAIL_REGISTRY/contrail-vrouter-kernel-init-dpdk:$CONTRAIL_CONTAINER_TAG
docker pull $CONTRAIL_REGISTRY/contrail-vrouter-kernel-build-init:$CONTRAIL_CONTAINER_TAG
EOF
done

$SCP "$my_dir/__run-gate.sh" ${SSH_USER}@$master_ip:run-gate.sh
timeout -s 9 60m $SSH_CMD ${SSH_USER}@$master_ip "$run_env AGENT_MODE=$AGENT_MODE ./run-gate.sh"

check_introspection_cloud

trap - ERR
save_logs '2,3'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
