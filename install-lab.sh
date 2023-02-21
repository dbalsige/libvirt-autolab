#!/usr/bin/env bash

######################################################################################
# This script is part of libvirt-autolab, Copyright 2021, dbalsige@bluewin.ch
#
# See LICENSE file for licensing information.
# 
# In short, this script:
# - Checks the host requirements, but never modifies it (e.g. install pkgs). 
# - Creates the libvirt network from templates/libvirt-net-${libvirt_network}.xml.
# - Prepares a temporary iPXE HTTP bootserver for Debian automatic installation.
# - Creates the libvirt storage resources according the storage_profile_* defined.
# - Creates and provisions the VMs defined in the XML definiton with iPXE.
# - Can be re-executed, it will detect already provisioned resources.
#
######################################################################################
# Configuration section, use carefully, normally no changes are required.
#
# Use the local hypervisor, other values are not tested (yet).
libvirt_uri="qemu:///system"
# The existing libvirt storage pool used for volumes.
libvirt_pool="default"
# The script uses the XML definition in templates/libvirt-net-${libvirt_network}.xml
# to create the libvirt network. Make sure a template exists when changing this value.
libvirt_network="local"
# RAM and vCPU settings are defined statically for each VM class:
# If a VM name begins with "node" it belongs to the class ${compute_profile_node},
# otherwise it belongs to the ${compute_profile_default} class.
# The compute profiles are defined the following way: "vcpu_count,ram_size".
compute_profile_default="1,1024"
compute_profile_node="4,8192"
#compute_profile_worker="32,65536"
# Storage is defined statically for each VM class, like RAM and vCPU above:
# If a VM name begins with "node" it belongs to the class ${storage_profile_node},
# otherwise it belongs to the ${storage_profile_default} class.
# The storage profiles are defined: "vol_name_suffix,vol_size,vol_type,vol_guestdev".
storage_profile_default="disk1,10,qcow2,vda disk2,10,qcow2,vdb"
storage_profile_node="disk1,20,qcow2,vda disk2,25,raw,vdb"
#storage_profile_worker="disk1,100,qcow2,vda disk2,2000,raw,vdb disk3,2000,raw,vdc"
# SSH public key installed to the VMs.
ssh_key=~/.ssh/id_rsa.pub
# Root directory for iPXE booting, will be created and set up automatically.
bootdir=ipxeboot
# Installation url for netboot base
inst_url="http://ftp.debian.org/debian/dists/bullseye/main/installer-amd64"

# End configuration section
######################################################################################

# Creates the libvirt network from templates/libvirt-net-${libvirt_network}.xml
# Returns 0 on success, non-zero otherwise
function create_libvirt_net() {
  sudo virsh net-define templates/libvirt-net-${libvirt_network}.xml >/dev/null && \
  sudo virsh net-autostart ${libvirt_network} >/dev/null && \
  sudo virsh net-start ${libvirt_network} >/dev/null
  return ${?}
}

# Creates a libvirt storage volume in the ${libvirt_pool} storage pool
# Required arguments: arg1: volume definition as string,
# Example_argment: "vol_name,vol_size,vol_type,vol_guestdev"
# Returns 0 on success, non-zero otherwise
function create_volume() {
  local err=0
  if [ -z "${1}" ] ; then
    echo "Error: no volume specified."
    err=1 
  else
    local name=$(echo ${1} | cut -f1 -d,)
    local size=$(echo ${1} | cut -f2 -d,)
    local type=$(echo ${1} | cut -f3 -d,)
    case ${type} in
      raw)
        sudo virsh vol-create-as ${libvirt_pool} \
           ${name} ${size}G --format raw --allocation ${size}G >/dev/null
        err=${?}
        if [ ${err} -eq 0 ] ; then
          echo "   - Volume '${name}' successfully created"
        fi
        ;;
      qcow2)
        sudo virsh vol-create-as ${libvirt_pool} \
           ${name} ${size}G --format qcow2 --prealloc-metadata >/dev/null
        err=${?}
        if [ ${err} -eq 0 ] ; then 
          echo "   - Volume '${name}' successfully created"
        fi
        ;;
      *)
        echo "Error: volume type not supported."
        err=1
        ;;
    esac
  fi
  return ${err}
}

# Creates a libvirt VM, returns 0 on success, non-zero otherwise
# Required arguments: arg1: VM name as string
function create_vm() {
  local err=0
  if [ -z "${1}" ] ; then
    echo "Error: no VM name specified."
    err=1
  else
    # get the configuration from storage and compute classes for this VM
    local vcpu=0
    local ram=0
    local vol=""
    local vols=""
    case ${1} in
      node*)
        for vol in ${storage_profile_node} ; do
          vols="${vols} $(echo ${vol} | cut -f1 -d,),$(echo ${vol} | \
            cut -f4 -d,)"
        done
        vcpu=$(echo ${compute_profile_node} | cut -f1 -d,)
        ram=$(echo ${compute_profile_node} | cut -f2 -d,)
        ;;
      *)
        for vol in ${storage_profile_default} ; do
          vols="${vols} $(echo ${vol} | cut -f1 -d,),$(echo ${vol} | \
            cut -f4 -d,)"
        done
        vcpu=$(echo ${compute_profile_default} | cut -f1 -d,)
        ram=$(echo ${compute_profile_default} | cut -f2 -d,)
        ;;
    esac
    local diskoptions=""
    local mac=$(sudo virsh net-dumpxml ${libvirt_network} | \
      grep "${1}" | awk '{ print $2 }' | sed -e "s|'||g" -e "s|mac=||")
    for vol in ${vols} ; do
      local name=$(echo ${vol} | cut -f1 -d,)
      local device=$(echo ${vol} | cut -f2 -d,)
      diskoptions="${diskoptions} \
        --disk vol=${libvirt_pool}/${1}-${name},bus=virtio,target=${device}"
    done
    local command="sudo virt-install --name ${1} --vcpu ${vcpu} --memory ${ram} \
      --os-variant debiantesting --pxe --sound none --graphics none --noautoconsole \
      --network network=${libvirt_network},mac=${mac},model=virtio \
      ${diskoptions} --boot menu=on,useserial=on"
    ${command} >/dev/null
    err=${?}
    if [ ${err} -eq 0 ] ; then
      echo "   - VM '${1}' installation started (in background)"
    fi
  fi
  return ${err}
}

# Creates the iPXE bootdir for the server
function create_bootdir() {
  mkdir -p ${bootdir}
  cd ${bootdir}
  # Get the latest debian installer and unpack it
  curl --silent -L -O ${inst_url}/current/images/netboot/netboot.tar.gz
  curl --silent -L -O ${inst_url}/current/images/SHA256SUMS
  local checksum=$(grep netboot/netboot.tar.gz SHA256SUMS | awk '{print $1}')
  if [ "${checksum}" != "$(sha256sum netboot.tar.gz | awk '{print $1}')" ] ; then
    echo "Error: netboot.tar.gz verification failed, download corrupt."
    exit 10
  fi
  tar -xf netboot.tar.gz
  # Create the preseed dir and fetch the safe default
  mkdir preseed
  curl --silent https://www.debian.org/releases/stable/example-preseed.txt \
    > preseed/example-preseed.cfg 2>/dev/null
  cd - >/dev/null
}

# Fixes the default Debian installer initrd
function fix_installer_initrd() {
  # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=788634
  mkdir ${bootdir}/initrd-fix
  cd ${bootdir}/initrd-fix
  mkdir -p var/lib/dpkg/info
  cp ../debian-installer/amd64/initrd.gz{,.orig}
  zcat ../debian-installer/amd64/initrd.gz.orig | \
    cpio -i -H newc var/lib/dpkg/info/network-preseed.postinst 2>/dev/null
  cp var/lib/dpkg/info/network-preseed.postinst{,.orig}
  cat > var/lib/dpkg/info/network-preseed.postinst << __EOF
#!/bin/sh
set -e

. /usr/share/debconf/confmodule
. /lib/preseed/preseed.sh

# Re-enable locale and kbd selection
echo 0 >/var/run/auto-install.active

/lib/preseed/auto-install.sh

# This behavior stops auto install with (libvirt) networks
# configured for iPXE HTTP boot from httpboot_url/pxelinux.0
# provided by DHCP server.
# In such a scenario the preseed file will always be
# httpboot_url/pxelinux.0, which prevents auto install.
#
# A fix could be to prefer whatever url came from kernel 
# command line over what the DHCP sends, but this needs
# further investigation, if it breaks other possible setups.
#
# Therefore commented out.
#dhcp_url=\$(dhcp_preseed_url)
#if [ -n "\$dhcp_url" ]; then
#       preseed_location "\$dhcp_url"
#fi
preseed preseed/url
preseed_command preseed/early_command
__EOF
  zcat ../debian-installer/amd64/initrd.gz.orig > initrd
  echo "var/lib/dpkg/info/network-preseed.postinst" | \
    cpio -o -H newc --append -F initrd 2>/dev/null
  cat initrd | gzip -9 > ../debian-installer/amd64/initrd.gz
  rm initrd
  cd - >/dev/null
}

# Creates the boot templates for all hosts
function create_boot_templates() {
  cat templates/preseed.cfg.tmpl | \
    sed -e "s|%%%TMPL_SHADOW%%%|${shadow}|" \
        -e "s|%%%TMPL_BOOTDEV%%%|${bootdev}|g" \
        -e "s|%%%TMPL_BOOTURL%%%|${booturl}|" \
    > ${bootdir}/preseed/preseed.cfg
  cat templates/finish.sh.tmpl | \
    sed -e "s|%%%TMPL_BOOTURL%%%|${booturl}|" \
    > ${bootdir}/preseed/finish.sh
  cp ${ssh_key} ${bootdir}/preseed/authorized_keys
  for vm in ${vms} ; do
    # the network should be active at this time, get the live values
    mac=$(sudo virsh net-dumpxml ${libvirt_network} | \
      grep "${vm}" | awk '{ print $2 }' | sed -e "s|'||g" -e "s|mac=||")
    cat > ${bootdir}/pxelinux.cfg/01-$(echo ${mac} | sed -e 's|:|-|g') << __EOF
default ipxeinstall
timeout 0
prompt 0
label ipxeinstall
  kernel debian-installer/amd64/linux
  append initrd=debian-installer/amd64/initrd.gz auto=true priority=critical \
    console=ttyS0 url=${booturl}/${vm}/preseed.cfg interface=auto --- quiet
  ipappend 2
__EOF
    ln -s . ${bootdir}/preseed/${vm}
  done
}

# Start the bootserver, serving ${bootdir}, return 0 on success, 1 otherwise
function start_bootserver() {
  PYTHONUNBUFFERED=x python3 -m http.server --directory ${bootdir} \
    --bind ${boothost} ${bootport} &> ${bootlog} &
  return ${?}
}

# Wait until all installtion success messages are found in ${bootlog}
# When all are found kill the bootserver by its PID and return the result of the kill
function wait_for_finish() {
  local waiting="${vms}"
  tail -f ${bootlog} | while read line ; do
    local host=""
    if echo $line | grep -q "installation-finished " ; then
      host=$(echo ${line} | awk '{print $7}' | sed -e 's|/preseed/||' \
        -e 's|/installation-finished||')
      echo "   - VM '${host}' successfully installed"
      # remove from waiting
      local h=""
      local tmp_waiting=""
      for h in ${waiting} ; do
        if [ "${h}" != "${host}" ] ; then
          tmp_waiting="${tmp_waiting} ${h}"
        fi
      done
      waiting=${tmp_waiting}
      # the last one is done
      if [ -z "${waiting}" ] ; then
        echo " * All VMs installed successfully, stopping the bootserver"
        kill -s SIGTERM ${bootserver_pid}
        return $?
      else
        echo "     - Still waiting for remaining VMs:${waiting}"
      fi
    fi
  done
}

# Returns 0 if all ${dependencies} are installed, 1 otherwise
function check_dependencies() {
  if [ ! -x /usr/bin/which ] ; then
    echo "Error: '/usr/bin/which' executable not found."
    return 1
  fi
  for prog in ${dependencies} ; do
    if ! which ${prog} >/dev/null ; then
      echo "Error: Required executable ${prog} not found in \$PATH."
      return 1
    fi
  done
  return 0
}

# Returns 0 if virsh can connect to ${libvirt_uri}, 1 otherwise
function check_libvirt() {
  if ! sudo virsh connect --name ${libvirt_uri} >/dev/null; then
    echo "Error: Could not connect to libvirt on ${libvirt_uri}."
    return 1
  fi
  return 0
}

# Returns 0 if the SSH key defined in ${ssh_authkey} is readable, 1 otherwise
function check_ssh_key() {
  if [ ! -r ${ssh_key} ] ; then
    echo "Error: No public SSH key found in ${ssh_key}."
    return 1
  fi
  return 0
}

# Returns 0 if the Internet is accessible, 1 otherwise
function check_inet() {
  if ! ping -q -c1 debian.ethz.ch >/dev/null 2>&1 ; then
    echo "Error: No Internet connectivity available."
    return 1
  fi
  return 0
}

# Returns 0 if the pysical resources are available, 1 otherwise
function check_physics_available() {
  local available=0
  # These checks make only sense if the local hypervisor is used
  if [ "${libvirt_uri}=" == "qemu:///system" ] ; then
    if [ $(cat /proc/cpuinfo | grep processor | wc | awk '{print $1}') -lt 4 ] ; then
      echo "Error: Less than 4 local physical CPU cores found."
      available=1
    fi
    if grep -q -E "vmx|svm" /proc/cpuinfo ; then
      echo "Error: There is no local hardware virtualization available."
      available=1
    fi
    local free_local_ram=$(free | grep Mem: | awk '{print $7}')
    let free_local_ram=${free_local_ram}/1024
    if [ ${ram_required} -gt ${free_local_ram} ] ; then
      echo "Error: Not enough local RAM available (${ram_required}) for request."
    fi
  fi
  # This should work on any ${libvirt_uri}
  if [ ${vcpu_required} -gt $(sudo virsh maxvcpus) ] ; then
    echo "Error: Connection does not support request for ${vcpu_required} vCPUs."
    available=1
  fi
  if  [ "${libvirt_uri}" != "qemu:///system" ] ; then
    local ram_free=$(sudo virsh nodememstats | grep free | awk '{print $3}')
    let ram_free=${ram_free}/1024
    if [ ${ram_required} -gt ${ram_free} ] ; then
      echo "Error: Not enough RAM available on remote hypervisor (${ram_required})."
      available=1
    fi
  fi
  local storage_free=$(sudo virsh pool-info ${libvirt_pool} | \
    grep Available: | awk '{print $2}')
  if [ ${storage_required} -gt ${storage_free%.*} ] ; then
    echo "Error: Not enough storage in pool (${storage_required}) for request."
    available=1
  fi
  return ${available}
}

# Returns 0 if all resources are absent, 1 otherwise
function check_resources_absent() {
  local conflict=0
  if sudo virsh net-list --all | grep -q "${libvirt_network} " ; then
    echo "Error: Naming conflict, network ${libvirt_network} is already defined."
    conflict=1
  fi
  for vol in ${volumes} ; do
    vol_name=$(echo ${vol} | cut -f1 -d,)
    if sudo virsh vol-list ${libvirt_pool} | grep -q "${vol_name} " ; then
      echo "Error: Naming conflict, volume ${vol_name}, pool ${libvirt_pool} exists."
      conflict=1
    fi
  done
  for vm in ${vms} ; do
    if sudo virsh list --all | grep -q "${vm} " ; then
      echo "Error: Naming conflict, VM ${vm} is already defined."
      conflict=1
    fi
  done
  return ${conflict}
}

# Returns 0 if all resources are found in the desired state, 1 otherwise
function check_resource_status() {
  local warn=0
  if ! sudo virsh net-list --all | grep -q "${libvirt_network} " ; then
    echo "Warning: Network ${libvirt_network} is not defined."
    warn=1
  else
    if ! sudo virsh net-list --all | \
      grep "${libvirt_network} " | grep -q active ; then
      echo "Warning: Network ${libvirt_network} is defined but not active."
      warn=1
    fi
  fi
  for vol in ${volumes} ; do
    vol_name=$(echo ${vol} | cut -f1 -d,)
    if ! sudo virsh vol-list ${libvirt_pool} | grep -q "${vol_name} " ; then
      echo "Warning: Volume ${vol_name} in pool ${libvirt_pool} is not defined."
      warn=1
    fi
  done
  for vm in ${vms} ; do
    if ! sudo virsh list --all | grep -q "${vm} " ; then
      echo "Warning: VM ${vm} is not defined."
      warn=1
    else
      if ! sudo virsh list --all | grep "${vm} " | grep -q running ; then
        echo "Warning: VM ${vm} is defined but not running."
        warn=1
      fi
    fi
  done
  return ${warn}
}

# Main program

# These programs should be installed on the host as they are used inside this script
dependencies="
sudo
virsh
virt-install
python3
curl
tar
gzip
cpio
openssl
sed
grep
awk
cut
cat
zcat
sha256sum
wc
free
ping
mkdir
echo
rm
cp
kill
tail
tee
sleep
"

if ! check_dependencies || ! check_libvirt || ! check_ssh_key || ! check_inet ; then
  exit 1
fi

# Calculate boothost, bootport, booturl from XML definiton
booturl=$(cat templates/libvirt-net-${libvirt_network}.xml | grep pxelinux.0 | \
  awk '{print $2}')
booturl=${booturl#*\'}
booturl=${booturl%/pxelinux.0*}
bootport=${booturl##*:}
boothost=${booturl##*/}
boothost=${boothost%:*}
booturl=${booturl}/preseed

# Set log file for bootserver
bootlog=${bootdir}/bootserver.log

# Set the guest boot device
# TODO check if the value matches the definitions in storage_profile_*
# In virtual environments this should be ok, and allows having only one preseed.cfg
bootdev=vda

# Get the VM names from the XML definition
vms=""
for hostdef in $(grep host templates/libvirt-net-${libvirt_network}.xml | \
  awk '{print $3}' | sed -e "s|'||g") ; do
  vms="${vms} ${hostdef#*=}"
done

# Calculate total storage vCPUs and RAM required final volume names 
# from ${storage_profile_*} and ${compute_profile_*}
volumes=""
storage_required=0
vcpu_required=0
ram_required=0
for vm in ${vms} ; do
  case ${vm} in
    node*)
      let vcpu_required=${vcpu_required}+$(echo ${compute_profile_node} | \
        cut -f1 -d,)
      let ram_required=${ram_required}+$(echo ${compute_profile_node} | \
        cut -f2 -d,)
      for vol in ${storage_profile_node} ; do
        vol_name=${vm}-$(echo ${vol} | cut -f1 -d,)
        vol_size=$(echo ${vol} | cut -f2 -d,)
        volumes="${volumes} ${vol_name},${vol_size},$(echo ${vol} | \
          cut -f3 -d,),$(echo ${vol} | cut -f4 -d,)"
        let storage_required=${storage_required}+${vol_size}
      done
      ;;
    *)
      let vcpu_required=${vcpu_required}+$(echo ${compute_profile_default} | \
        cut -f1 -d,)
      let ram_required=${ram_required}+$(echo ${compute_profile_default} | \
        cut -f2 -d,)
      for vol in ${storage_profile_default} ; do
        vol_name=${vm}-$(echo ${vol} | cut -f1 -d,)
        vol_size=$(echo ${vol} | cut -f2 -d,)
        volumes="${volumes} ${vol_name},${vol_size},$(echo ${vol} | \
          cut -f3 -d,),$(echo ${vol} | cut -f4 -d,)"
        let storage_required=${storage_required}+${vol_size}
      done
      ;;
  esac
done

# In case ${bootdir} exists, the script does only check for resource status
# but never creates or modifies resources and does not start the bootserver
# This behavior ensures the script can be re-executed safely after successfull 
# installation.
if [ -d ${bootdir} ] ; then
  echo "iPXE boot directory exists, no action taken, checking resource status:"
  if check_resource_status ; then
    echo "OK: Status ok, all resources in desired state."
    exit 0
  else
    echo "WARN: Warnings found, manual intervention may be required."
    exit 1
  fi
fi

# To avoid any conflict check if any of the resources to be created already exists
if ! check_resources_absent ; then
  exit 2
fi

# Check if enough physical resources are available before creating anything
if ! check_physics_available ; then
  exit 3
fi

# Inform the user and wait for confirmation
echo "All tests passed successfully, ready for installation!"
echo "Please provide a password for the 'debian' user on the VMs:"
shadow=$(openssl passwd -6)
echo "The installation will create the following resources on '${libvirt_uri}':"
echo " * Network '${libvirt_network}' (templates/libvirt-net-${libvirt_network}.xml)"
echo " * Volumes in pool '${libvirt_pool}' (${storage_required}G in total):"
for vol in ${volumes} ; do echo "   - ${vol}" ; done
echo " * Virtual Machines (${vcpu_required} vCPU / ${ram_required}M RAM in total):"
for vm in ${vms} ; do echo "   - ${vm}" ; done
echo " * iPXE boot configuration in directory: ${bootdir}"
echo " * VM preconfiguration in directory: ${bootdir}/preseed"
echo " * The SSH public key in ${ssh_key} will be used to aceess all VMs"
echo
echo -n "Ready to perform installation? Type 'yes' to continue: "
read answer
if [ "${answer}" != "yes" ] ; then
  echo "Aborting on user request."
  exit 0
fi
echo

# Create the network
create_libvirt_net || exit 1
echo " * Network '${libvirt_network}' successfully started"

# Prepare the bootdir for the bootserver
create_bootdir
echo " * Downloaded Debian installer to bootdir '${bootdir}'"
fix_installer_initrd
echo " * Fixed Debian installer initrd.gz in bootdir '${bootdir}'"
create_boot_templates
echo " * Created boot templates in bootdir '${bootdir}'"

echo " * Creating volumes in pool '${libvirt_pool}':"
# Create the volumes
for vol in ${volumes} ; do
  create_volume ${vol} || exit 1
done
echo " * All volumes created succcessfully"

# Start the bootserver
start_bootserver 2>/dev/null
bootserver_pid=${!}
echo " * Bootserver listening on ${booturl}"

# Create, start and auto install the VMs
echo " * Creating VMs:"
for vm in ${vms} ; do
  create_vm ${vm} || exit 1
done
echo " * Installation is progressing, VM consoles: 'sudo virsh console <name>'"
echo " * Waiting for finish callbacks in '${bootlog}':"
# Wait until the last VM is installed
if wait_for_finish ; then
  # After install the VM will shut down, wait until this happens
  sleep 60
  for vm in ${vms} ; do
    sudo virsh start ${vm} >/dev/null
  done
  domain=$(sudo virsh net-dumpxml ${libvirt_network} | grep "domain" | \
    awk '{print $2}' |  sed  -e "s|'/>||" -e "s|name='||")
  echo "Installation successful! Available VMs:"
  echo "This information can also be found in './hosts.lab':"
  echo "# /etc/hosts addon for the libvirt lab" | tee hosts.lab
  for vm in ${vms} ; do
    ip=$(sudo virsh net-dumpxml ${libvirt_network} | grep "${vm}" | \
      awk '{ print $4 }' | sed -e "s|'||g" -e "s|/>||" -e "s|ip=||")
    echo "${ip} ${vm}.${domain} ${vm}" | tee -a hosts.lab
  done
else
  "Error: bootserver could not be stopped."
  exit 1
fi

