#!/bin/sh

for keyalgo in rsa ecdsa ed25519 ; do
	privkey=$(jetpack config ssh.host_key.$keyalgo.private "")
	pubkey=$(jetpack config ssh.host_key.$keyalgo.public "")

	[ -n "$privkey" -a -n "$pubkey" ] || continue

	privfile=/etc/ssh/ssh_host_${keyalgo}_key
	echo "$privkey" > "$privfile"

	# fix permissions screwed up by cloud-init
	chgrp ssh_keys "$privfile"
	chmod 640 "$privfile"

	pubfile="$privfile".pub
	echo "$pubkey" > "$pubfile"
	chmod 644 "$pubfile"
done

cat <<EOF >/etc/ssh/ssh_config.d/90-hostbased.conf
HostbasedAuthentication yes
EnableSSHKeysign yes
EOF

sed -i -e "s,#HostbasedAuthentication no,HostbasedAuthentication yes," \
	-e "s/PasswordAuthentication no/PasswordAuthentication yes/g" \
	/etc/ssh/sshd_config

systemctl restart sshd

rm -f /etc/hosts.equiv
echo "# managed by cyclecloud" > /etc/hosts.equiv

dnf install -y ipcalc nmap

localips=$(ip -j a  | jq -r '.[] | select(.link_type=="ether" and .operstate=="UP").addr_info[] | select(.family == "inet") | "\(.local)/\(.prefixlen)"')
netips=""
for ip in $localips ; do
	invalid_re=$(ipcalc --network --broadcast $ip | cut -d= -f2 | tr '\n' '|' | sed -e 's,^,^,' -e 's,|$,$,' -e 's,\.,\\.,g' -e 's,|,$\\|^,g')
	netips="$netips $(nmap -sL -n $ip | grep 'Nmap scan report for ' | cut -d' ' -f5 | grep -v "$invalid_re")"
done

hosts=""
for ip in $netips ; do
	echo $ip >> /etc/hosts.equiv
	hosts="$hosts,$ip"
done

use_nodename_as_hostname=$(jetpack config slurm.use_nodename_as_hostname $(jetpack config pbspro.use_nodename_as_hostname ""))
if [ "$use_nodename_as_hostname" = True ] ; then
	node_prefix=$(jetpack config slurm.node_prefix $(jetpack config pbspro.node_prefix ""))

	search_list=$(jetpack config dns.search_list)
	partitions="execute hpc login gpu"

	for domain in ${search_list/,/ } internal.cloudapp.net ; do
		for scheduler in ${node_prefix}s ${node_prefix}server ; do
			hosts="$hosts,$scheduler,$scheduler.$domain"
		done

		for partition in $partitions ; do
			for instance in `seq 1 20` ; do
				node=${node_prefix}$partition-$instance
				hosts="$hosts,$node,$node.$domain"
			done
		done

		for instance in `seq -w 01 10` ; do
			node=${node_prefix}ood$instance
			hosts="$hosts,$node,$node.$domain"
		done
	done

	rm -f /etc/ssh/ssh_known_hosts
	echo "# managed by cyclecloud" > /etc/ssh/ssh_known_hosts

	hosts=${hosts#,}
	for keyalgo in rsa ecdsa ed25519 ; do
		hostpub=$(cat /etc/ssh/ssh_host_${keyalgo}_key.pub)
		echo "$hosts $hostpub" >> /etc/ssh/ssh_known_hosts
	done
fi
