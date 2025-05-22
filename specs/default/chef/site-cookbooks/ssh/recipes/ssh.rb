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
  content <<~EOH
    HostbasedAuthentication yes
    EnableSSHKeysign yes
  EOH
  mode "0644"
end

if ::Dir.exist?('/etc/ssh/sshd_config.d')
  file "/etc/ssh/sshd_config.d/30-hostbased.conf" do
    content <<~EOH
      HostbasedAuthentication yes
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
    EOH
    mode "0644"
    notifies :restart, "service[sshd]"
  end
else
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

scheduler = cluster.scheduler
scheduler_ip = cluster.scheduler_ip
hosts = [scheduler_ip, scheduler]
hosts.concat(netips)
search_list = node.fetch(:dns, {}).fetch(:search_list, "").split(",") + ["internal.cloudapp.net"]
for domain in search_list do
  hosts << "#{scheduler}.#{domain}"
end

# retrieve cluster status from cyclecloud API for list of node arrays, their
# names and maximum node count in each array
config = cluster.blackboard_config
uri = "/clusters/#{node[:cyclecloud][:cluster][:id]}/status"

# If a context path is defined, prepend it to the URI
uri = config['path'] + uri if config.fetch(:path, '/') != "/"

http = Net::HTTP.new(config['host'], config['port'])
if config['use_https']
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE if node[:cyclecloud][:skip_ssl_validation]
end

req = Net::HTTP::Get.new(URI.escape(uri))
req.basic_auth(config['username'], config['password'])
response = http.start { |http_conn| http_conn.request(req) }
cluster_status = JSON.parse(response.body, :symbolize_names => true)

for nodearray in cluster_status.fetch(:nodearrays, []) do
  config = nodearray[:nodearray][:Configuration]
  node_prefix = config.fetch(:pbspro, {}).fetch(:node_prefix,
                  config.fetch(:slurm, {}).fetch(:node_prefix, ""))
  # more than a thousand nodes is excessive and likely some default value
  nodecount = nodearray[:maxCount].clamp(1, 1000)
  (1..nodecount).each do |instance|
    node = "#{node_prefix}#{nodearray[:name]}-#{instance}"
    hosts << node
    for domain in search_list do
      hosts << "#{node}.#{domain}"
    end
  end
end

# special case OOD add-on - this is very much a heuristic - we'd need to find
# and query the OOD cluster status here
config = cluster_status.fetch(:nodearrays, [{}])[0].fetch(:nodearray, {}).fetch(:Configuration, {})
node_prefix = config.fetch(:pbspro, {}).fetch(:node_prefix,
                config.fetch(:slurm, {}).fetch(:node_prefix, ""))
if node_prefix != ""
  # five ood server per cluster for now
  (1..5).each do |instance|
    node = "#{node_prefix}ood%02d" % instance
    hosts << node
    for domain in search_list do
      hosts << "#{node}.#{domain}"
    end
  end
end

lines = []
for keyalgo in [:rsa, :ecdsa, :ed25519] do
  pubkey = node.fetch(:ssh, {}).fetch(:host_key, {}).fetch(keyalgo, {}).fetch(:public, "")
  next if pubkey.empty?

  # keep line length in check
  hosts.each_slice(100) do |slice|
    lines << slice.join(",") + " #{pubkey}"
  end
end

file "/etc/ssh/ssh_known_hosts" do
  content "# managed by cyclecloud\n\n" + lines.join("\n") + "\n"
  mode "0644"
end
