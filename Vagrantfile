LOGIN = "cgelin"

Vagrant.configure("2") do |config|

  config.vm.define "#{LOGIN}S" do |server|
    server.vm.box = "debian/bookworm64"
    server.vm.hostname = "#{LOGIN}S"
    server.vm.network "private_network", ip: "192.168.56.110"
    server.vm.provider "virtualbox" do |vb|
      vb.memory = 1024
      vb.cpus = 1
    end
    server.vm.provision "shell", path: "scripts/install_k3s_server.sh"
  end

  config.vm.define "#{LOGIN}SW" do |worker|
    worker.vm.box = "debian/bookworm64"
    worker.vm.hostname = "#{LOGIN}SW"
    worker.vm.network "private_network", ip: "192.168.56.111"
    worker.vm.provider "virtualbox" do |vb|
      vb.memory = 1024
      vb.cpus = 1
    end
    worker.vm.provision "shell", path: "scripts/install_k3s_agent.sh"
  end

end