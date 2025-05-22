require 'json'
require 'ipaddress'

search_list = node.fetch(:dns, {}).fetch(:search_list, "")
servers = node.fetch(:dns, {}).fetch(:servers, "")

for keyalgo in [:rsa, :ecdsa, :ed25519] do
  privkey = node.fetch(:ssh, {}).fetch(:host_key, {}).fetch(keyalgo, {}).fetch(:private, "")
  pubkey = node.fetch(:ssh, {}).fetch(:host_key, {}).fetch(keyalgo, {}).fetch(:public, "")

  next if privkey.empty? || pubkey.empty?

  privfile = "/etc/ssh/ssh_host_#{keyalgo}_key"
  file privfile do
    content privkey
    # fix permissions screwed up by cloud-init
    mode "0640"
    group "ssh_keys"
  end

  file "#{privfile}.pub" do
    content pubkey
    mode "0644"
  end
end

file "/etc/ssh/ssh_config.d/90-hostbased.conf" do
  content <<-EOH
    HostbasedAuthentication yes
    EnableSSHKeysign yes
  EOH
  mode "0644"
end

# no drop files for ssh server yet
ruby_block "sshd enable hostbased and password authentications" do
  block do
    fe = Chef::Util::FileEdit.new("/etc/ssh/sshd_config")
    fe.search_file_replace_line(/^#HostbasedAuthentication /,
                               "HostbasedAuthentication yes")
    fe.search_file_replace_line(/^HostbasedAuthentication /,
                               "HostbasedAuthentication yes")
    fe.search_file_replace_line(/^PasswordAuthentication /,
                               "PasswordAuthentication yes")
    fe.write_file
  end
  notifies :restart, "service[sshd]"
end

service "sshd" do
  action :nothing
end

netips = []
interfaces = JSON.parse(shell_out!("ip -j a").stdout)
for interface in interfaces do
  next if interface["link_type"] != "ether"
  next if interface["operstate"] != "UP"

  for addr_info in interface["addr_info"] do
    next if addr_info["family"] != "inet"

    addr = IPAddress "#{addr_info["local"]}/#{ addr_info["prefixlen"]}"
    netips.concat(addr.first.to(addr.last))
  end
end

file "/etc/hosts.equiv" do
  content "# managed by cyclecloud\n\n" + netips.join("\n") + "\n"
  mode "0644"
end

use_nodename_as_hostname = node.fetch(:pbspro, {}).fetch(:use_nodename_as_hostname, false) || node.fetch(:slurm, {}).fetch(:use_nodename_as_hostname, false)
if use_nodename_as_hostname
  node_prefix = node.fetch(:pbspro, {}).fetch(:node_prefix, node.fetch(:slurm, {}).fetch(:node_prefix, ""))

  search_list = node.fetch(:dns, {}).fetch(:search_list, "").split(",") + ["internal.cloudapp.net"]
  # determine from CC?
  node_arrays = "execute hpc login gpu"
  num_nodes = 20

  scheduler = cluster.scheduler
  scheduler_ip = cluster.scheduler_ip
  hosts = [scheduler_ip, scheduler]
  hosts.concat(netips)
  for domain in search_list do
    hosts << "#{scheduler}.#{domain}"

    for nodearray in ["execute", "hpc", "login", "gpu"] do
      (1..num_nodes).each do |instance|
        node = "#{node_prefix}#{nodearray}-#{instance}"
        hosts << node
        hosts << "#{node}.#{domain}"
      end
    end

    (1..num_nodes).each do |instance|
      node = "#{node_prefix}ood%02d" % instance
      hosts << node
      hosts << "#{node}.#{domain}"
    end
  end

  lines = []
  for keyalgo in [:rsa, :ecdsa, :ed25519] do
    pubkey = node.fetch(:ssh, {}).fetch(:host_key, {}).fetch(keyalgo, {}).fetch(:public, "")
    next if pubkey.empty?

    lines << hosts.join(",") + " #{pubkey}"
  end

  file "/etc/ssh/ssh_known_hosts" do
    content "# managed by cyclecloud\n\n" + lines.join("\n") + "\n"
    mode "0644"
  end
end
