#!/bin/bash -ex

# this script file should be copied to undercloud machine and run there.

cd ~

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

if [[ -z "$MGMT_IP" ]] ; then
  echo "MGMT_IP is expected"
  exit 1
fi

if [[ -z "$PROV_IP" ]] ; then
  echo "PROV_IP is expected"
  exit 1
fi

if [[ -z "$NETDEV" ]] ; then
  echo "NETDEV is expected (e.g. export NETDEV=eth1)"
  exit 1
fi

prov_ip=$PROV_IP
prov_ip_base=$(echo $prov_ip | cut -d '.' -f 1,2,3)
mgmt_ip=$MGMT_IP
dns_nameserver="8.8.8.8"

# create undercloud configuration file. all IP addresses are relevant to create_env.sh script
if [[ -f /usr/share/instack-undercloud/undercloud.conf.sample ]] ; then
  cp /usr/share/instack-undercloud/undercloud.conf.sample ~/undercloud.conf
fi
cat << EOF >> undercloud.conf
[DEFAULT]
local_ip = ${prov_ip}/24
undercloud_public_vip = $prov_ip_base.10
undercloud_admin_vip = $prov_ip_base.11
local_interface = $NETDEV
masquerade_network = $prov_ip_base.0/24
dhcp_start = $prov_ip_base.50
dhcp_end = $prov_ip_base.70
network_cidr = $prov_ip_base.0/24
network_gateway = $prov_ip
discovery_iprange = $prov_ip_base.71,$prov_ip_base.99
EOF

# install undercloud
openstack undercloud install

# function to build images if needed
function create_images() {
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    echo "Image creation works for ContOS based only for now"
    exit 1
  fi

  mkdir -p images
  cd images

  # next line is needed only if undercloud's OS is deifferent
  #export NODE_DIST=centos7
  export STABLE_RELEASE="$OPENSTACK_VERSION"
  export USE_DELOREAN_TRUNK=1
  export DELOREAN_REPO_FILE="delorean.repo"
  export DELOREAN_TRUNK_REPO="http://trunk.rdoproject.org/centos7-$OPENSTACK_VERSION/current/"
  export DIB_YUM_REPO_CONF=/etc/yum.repos.d/delorean*

  # package redhat-lsb-core is absent due to some bug in newton image
  # workaround is to add ceph repo:
  # there is enabled jewel repo in centos image
  # export DIB_YUM_REPO_CONF="$DIB_YUM_REPO_CONF /etc/yum.repos.d/CentOS-Ceph-Hammer.repo"

  #export DELOREAN_TRUNK_REPO="http://buildlogs.centos.org/centos/7/cloud/x86_64/rdo-trunk-master-tripleo/"
  #export DIB_INSTALLTYPE_puppet_modules=source

  openstack overcloud image build

  cd ..
}

cd ~
if [ -f /tmp/images.tar ] ; then
  # but right now script will use previously built images
  tar -xf /tmp/images.tar
else
  create_images
  tar -cf images.tar images
fi

source ./stackrc
cd ~/images
openstack overcloud image upload
cd ..

# update undercloud's network information
sid=`neutron subnet-list | grep " $prov_ip_base.0" | awk '{print $2}'`
neutron subnet-update $sid --dns-nameserver $dns_nameserver
