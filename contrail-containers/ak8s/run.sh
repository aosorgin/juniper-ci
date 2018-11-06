#!/bin/bash -e

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

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs '1-'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

if [[ "$CONTAINER_REGISTRY" == 'build' ]]; then
  $SCP -r "$WORKSPACE/contrail-container-builder" ${SSH_USER}@$build_ip:./
  $SCP "$my_dir/../__build-containers.sh" ${SSH_USER}@$build_ip:build-containers.sh
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
  ssh_env+=" CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD ${SSH_USER}@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  CONTAINER_REGISTRY="$build_ip:5000"
  CONTRAIL_VERSION="$OPENSTACK_VERSION-$CONTRAIL_VERSION"
fi

# deploy cloud
source "$my_dir/../common/${HOST}/${ENVIRONMENT_OS}"

IP_CONT_01=`echo $nodes_cont_ips | cut -d ' ' -f 1`
IP_CONT_02=`echo $nodes_cont_ips | cut -d ' ' -f 2`
IP_CONT_03=`echo $nodes_cont_ips | cut -d ' ' -f 3`
IP_COMP_01=`echo $nodes_comp_ips | cut -d ' ' -f 1`
IP_COMP_02=`echo $nodes_comp_ips | cut -d ' ' -f 2`

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
templ=$(cat $my_dir/instances.yaml.${HA}.tmpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
echo "INFO: cloud config ------------------------- $(date)"
cat $config
cp $config $WORKSPACE/logs/

image=`docker images -a -q centos-soft`
if [[ -z "$image" ]]; then
  docker pull centos
  docker run -i --name cprep-$JOB_RND --entrypoint /bin/bash centos -c "yum install -y epel-release && yum install -y python-ipaddress git python-pip sudo vim gcc python-devel && pip install pip --upgrade && hash -r && pip install 'ansible<2.5.0' pycrypto oslo_utils oslo_config jinja2"
  docker commit cprep-$JOB_RND centos-soft
  docker rm cprep-$JOB_RND
fi

mkdir -p $WORKSPACE/logs/deployer
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $WORKSPACE/logs/deployer:/root/logs"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
docker run -i --rm --entrypoint /bin/bash $volumes --network host centos-soft -c "/root/run-gate.sh"

# TODO: wait till cluster up and initialized
sleep 300

# Validate cluster's introspection ports
for dest in $nodes_ips ; do
  $SCP "$my_dir/../__check_introspection.sh" $SSH_USER@${dest}:./check_introspection.sh
done
source "$my_dir/../common/check-functions"
res=0
ips=($nodes_ips)
dest_to_check="${SSH_USER}@${ips[0]}"
for ip in ${ips[@]:1} ; do
  dest_to_check="$dest_to_check,${SSH_USER}@$ip"
done
count=1
limit=3
while ! check_introspection "$dest_to_check" ; do
  echo "INFO: check_introspection ${count}/${limit} failed"
  if (( count == limit )) ; then
    echo "ERROR: Cloud was not up during timeout"
    res=1
    break
  fi
  (( count+=1 ))
  sleep 30
done
test $res == '0'

function check_cluster() {
  cat <<EOM | ssh $SSH_OPTS root@${master_ip}
set -x
kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
wget -nv https://storage.googleapis.com/kubernetes-helm/helm-v2.9.0-linux-amd64.tar.gz
tar -xvf helm-v2.9.0-linux-amd64.tar.gz
mv linux-amd64/helm /usr/bin/
helm init
kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller", "automountServiceAccountToken": true}}}}'
helm init --service-account tiller --upgrade
sleep 60
helm version
kubectl get pods --all-namespaces
helm repo update
helm install --name wordpress --set mariadb.master.persistence.enabled=false --set persistence.enabled=false stable/wordpress
sleep 90
kubectl get pods
kubectl get svc wordpress-wordpress
set +x
EOM

  # this is needed if we want to enable persistence
  # ? helm repo add nfs-provisioner https://raw.githubusercontent.com/IlyaSemenov/nfs-provisioner-chart/master/repo
  # ? helm install --name nfs-provisioner --namespace nfs-provisioner nfs-provisioner/nfs-provisioner && sleep 5
  # ? kubectl patch storageclass local-nfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

check_cluster

# save logs and exit
trap - ERR
save_logs '1-'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res
