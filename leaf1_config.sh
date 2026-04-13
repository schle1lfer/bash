#!/usr/bin/env bash
# Configure Leaf1 via vtysh

vtysh << 'EOF'
configure terminal

interface Ethernet0
 ip address 192.168.1.2/30
exit

interface Ethernet120
 ip address 192.168.0.1/30
 ip ospf area 0
 ip ospf network point-to-point
exit

interface Ethernet124
 ip address 192.168.0.5/30
 ip ospf area 0
 ip ospf network point-to-point
exit

interface lo
 ip address 1.1.1.1/32
 ip ospf area 0
 ip ospf passive
exit

router ospf
 ospf router-id 1.1.1.1
exit

end
write memory
EOF
