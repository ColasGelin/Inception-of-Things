mkdir -p /goinfre/cgelin/VirtualBox_VMs
VBoxManage setproperty machinefolder /goinfre/cgelin/VirtualBox_VMs

mkdir -p /goinfre/cgelin/vagrant.d
export VAGRANT_HOME=/goinfre/cgelin/vagrant.d
echo 'export VAGRANT_HOME=/goinfre/cgelin/vagrant.d' >> ~/.zshrc