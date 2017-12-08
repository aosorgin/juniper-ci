#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"
source "$my_dir/../common/functions"

export WORKSPACE="${WORKSPACE:-$HOME}"
# prepare environment for common openstack functions
OPENSTACK_VERSION="$VERSION"
SSH_CMD="juju-ssh"
export PASSWORD=password

cd $WORKSPACE
create_stackrc
source $WORKSPACE/stackrc

virtualenv .venv
source .venv/bin/activate
pip install python-openstackclient

openstack catalog list

openstack project create demo
openstack role add --project demo --user admin Member

openstack network create --share --external --provider-network-type flat --provider-physical-network external public
openstack subnet create --network public --subnet-range 10.20.0.0/24 --no-dhcp --gateway 10.20.0.1 public

openstack flavor create --ram 256 --vcpus 1 --public small

rm cirros-0.3.5-x86_64-disk.img
wget http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img
openstack image create --public --file cirros-0.3.5-x86_64-disk.img cirros

export OS_PROJECT_NAME=demo

openstack network create private
openstack subnet create --network private --subnet-range 192.168.1.0/24 --gateway 192.168.1.1 private

openstack router create rt
openstack router set --external-gateway public rt
openstack router add subnet rt private

openstack server create --image cirros --flavor small --network private --min 2 --max 2 ttt
