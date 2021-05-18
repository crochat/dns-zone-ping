#!/usr/bin/env bash

DNS_CONF_DIR="/etc/bind"

ACTION="check"
ALL=0

result=""

positional=()
while [[ $# -gt 0 ]]; do
	case $1 in
		--list)
			ACTION="list"
			shift
			;;
		--all)
			ALL=1
			shift
			;;
		-h|--help)
			cat << EOF
$0 [OPTIONS] (ZONE)

OPTIONS
=======
--list		List the configured zones
--all		Check all the zones
EOF
			shift
			;;
		*)
			positional+=("$1")
			shift
			;;
	esac
done
set -- "${positional[@]}"

if [[ $ALL -eq 1 ]]; then
	if [[ "$ACTION" = "list" ]]; then
		ALL=0
	elif [[ ${#positional[@]} -gt 0 ]]; then
		positional=""
	fi
fi

check_zone="$positional"
conffile_exclude="rndc.key zones.rfc1918"
zones_exclude=". localhost 127.in-addr.arpa 0.in-addr.arpa 255.in-addr.arpa"
skip_external=1

zones=()
reverse_zones=()

for conffile in $(ls $DNS_CONF_DIR); do
	parse_ok=1
	for exclude in $(echo "$conffile_exclude"); do
		if [[ "$conffile" = "$exclude" ]]; then
			parse_ok=0
			break
		fi
	done

	if [[ $parse_ok -eq 1 ]]; then
		conffile=$(realpath $DNS_CONF_DIR/$conffile)
		if [[ "$(grep '^zone ' $conffile)" != "" ]]; then
			tmp_zones=$(grep '^zone ' $conffile | awk '{print $2}')
			if [[ "$(echo $tmp_zones | grep '^".*"$')" != "" ]]; then
				tmp_zones=$(echo "$tmp_zones" | cut -c2- | rev | cut -c2- | rev)
				while IFS=$'\n' read -r zone; do
					for exclude in $(echo "$zones_exclude"); do
						if [[ "$zone" = "$exclude" ]]; then
							parse_ok=0
							break
						fi
					done

					if [[ $parse_ok -eq 1 ]]; then
						if [[ "$(echo $zone | grep '.in-addr.arpa$')" != "" ]]; then
							zone=$(echo $zone | rev | cut -c14- | rev)
							append_ok=1
							for tmp_zone in ${reverse_zones[@]}; do
								if [[ "$zone" = "$tmp_zone" ]]; then
									append_ok=0
									break
								fi
							done
							if [[ $append_ok -eq 1 ]]; then
								reverse_zones+=("$zone")
							fi
						else
							append_ok=1
							for tmp_zone in ${zones[@]}; do
								if [[ "$zone" = "$tmp_zone" ]]; then
									append_ok=0
									break
								fi
							done
							if [[ $append_ok -eq 1 ]]; then
								zones+=("$zone")
							fi
						fi
					fi
				done <<< "$(echo "$tmp_zones")"
			fi
		fi
	fi
done

found=0
if [[ ${#zones[@]} -gt 0 ]]; then
	for zone in $(echo ${zones[@]} | uniq); do
		if [[ "$check_zone" != "" ]]; then
			if [[ "$check_zone" = "$zone" ]]; then
				found=1
				break
			fi
		else
			if [[ "$ACTION" = "list" ]]; then
				if [[ "$result" != "" ]]; then
					result+="@@"
				fi
				result+="zone:$zone"
			fi
		fi
	done
fi

if [[ $found -ne 1 && ${#reverse_zones[@]} -gt 0 ]]; then
	for zone in $(echo ${reverse_zones[@]} | uniq); do
		if [[ "$check_zone" != "" ]]; then
			if [[ "$check_zone" = "$zone" ]]; then
				check_zone="$zone.in-addr.arpa"
				found=1
			fi
		else
			if [[ "$ACTION" = "list" ]]; then
				if [[ "$result" != "" ]]; then
					result+="@@"
				fi
				result+="reverse zone:$zone.in-addr.arpa"
			fi
		fi
	done
fi

check_zones=()
if [[ "$ACTION" = "check" ]]; then
	if [[ $ALL -eq 1 ]]; then
		for zone in ${zones[@]}; do
			check_zones+=("$zone")
		done
	elif [[ "$check_zone" != "" ]]; then
		if [[ $found -eq 1 ]]; then
			check_zones+=("$check_zone")
		fi
	fi

	if [[ ${#check_zones[@]} -eq 0 ]]; then
		ACTION=""
	fi
fi

if [[ "$ACTION" = "check" ]]; then
	for zone in ${check_zones[@]}; do
		zone_file=""
		hosts=()
		for conffile in $(ls $DNS_CONF_DIR); do
			parse_ok=1
			for exclude in $(echo "$conffile_exclude"); do
				if [[ "$conffile" = "$exclude" ]]; then
					parse_ok=0
					break
				fi
			done

			if [[ $parse_ok -eq 1 ]]; then
				conffile="$DNS_CONF_DIR/$conffile"
				check=$(grep -A 3 "^zone .*\"$zone\"" $conffile)
				if [[ "$check" != "" ]]; then
					if [[ $skip_external -eq 1 && "$(echo "$check" | grep external)" != "" ]]; then
						continue
					fi

					check_zone_file=$(echo "$check" | grep -A3 'type master' | grep 'file ' | awk '{print $NF}' | cut -c2- | rev | cut -c3- | rev)
					if [[ -f $check_zone_file ]]; then
						zone_file="$check_zone_file"
						check_hosts=$(cat $check_zone_file | awk '/IN[ \t]+A[ \t]+/ {print $1";"$4}')
						if [[ "$check_hosts" != "" ]]; then
							while IFS=$'\n' read -r line; do
								if [[ "$(echo $line | cut -d';' -f1)" = "@" ]]; then
									line="$zone;$(echo $line | cut -d';' -f2)"
								fi
								if [[ "$line" != "" ]]; then
									hosts+=("$line")
								fi
							done <<< "$(echo "$check_hosts")"
						fi
					fi
				fi
			fi
		done

		if [[ ${#hosts[@]} -gt 0 && "$zone_file" != "" ]]; then
			if [[ "$result" != "" ]]; then
				result+="@@"
			fi
			result+="ZONE $zone::@@===================================:=================:====="
			for item in ${hosts[@]}; do
				name=$(echo $item | cut -d';' -f1)
				address=$(echo $item | cut -d';' -f2)
				check=$(ping -c1 -W1 $address | grep '1 received')
				if [[ "$result" != "" ]]; then
					result+="@@"
				fi
				if [[ "$check" != "" ]]; then
					result+="$name:$address:OK"
				else
					result+="$name:$address:KO /!\\"
				fi
			done
		fi
	done
fi

if [[ "$result" != "" ]]; then
	echo $result | sed 's/@@/\n/g' | column -s ':' -t
fi
