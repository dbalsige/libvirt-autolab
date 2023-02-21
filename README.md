## README for libvirt-autolab ##

* `libvirt-autolab` is a collection of shell scripts to create your libvirt infrastructure fully automatically.

### Requirements ###

* One physical Linux Host with:
  * Minimum 32G RAM
  * Minimum 4 physical CPUs
  * Minimum 155 GB free disk space for virtual machine images
  * Hardware virtualization support enabled
  * User with root access (e.g. by sudo)
  * Internet acccess
  * A readable SSH public key in `~/.ssh/id_rsa.pub`
  * This repository cloned locally

* Tested on Debian 10 as host system, it should run on any recent Linux distribution with libvirt support.

* The following virtual infrastructure will be created in the `./install-lab.sh` default configuration:
  * A Libvirt network network `local`
  * 4 Libvirt qemu/KVM VMs: `spray`, `node1`, `node2` and `node3` running Debian 11 (Buster)
  * 8 Libvirt volumes in the `default` libvirt storage pool, 2 for each VM, 155GiB in total size
  * A temporary HTTP server to perform iPXE boot and automatic installation

### TL;DR ###

* Lab Installation
  ```
  ./install-lab.sh
  ```

