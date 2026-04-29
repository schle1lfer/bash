#include <arpa/inet.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

struct NextHop {
    std::string gateway;
    std::string iface;
    int weight = 1;
};

struct EcmpRoute {
    std::string prefix;
    int prefix_len = 0;
    std::vector<NextHop> nexthops;
};

// Snapshot of all current ECMP routes keyed by "prefix/len"
static std::map<std::string, EcmpRoute> g_ecmp_table;

// ──────────────────────────────────────────────────────────────────────────────

static std::string addr_to_str(int family, const void *addr) {
    char buf[INET6_ADDRSTRLEN] = {};
    inet_ntop(family, addr, buf, sizeof(buf));
    return buf;
}

static std::string iface_name(int ifindex) {
    char buf[IF_NAMESIZE] = {};
    if (if_indextoname(ifindex, buf))
        return buf;
    return "if" + std::to_string(ifindex);
}

static void print_ecmp_table() {
    std::cout << "\n=== ECMP routes (" << g_ecmp_table.size() << " entries) ===\n";
    for (const auto &[key, r] : g_ecmp_table) {
        std::cout << "  " << r.prefix << "/" << r.prefix_len
                  << "  nexthops(" << r.nexthops.size() << "):\n";
        for (const auto &nh : r.nexthops)
            std::cout << "    via " << nh.gateway
                      << "  dev " << nh.iface
                      << "  weight " << nh.weight << "\n";
    }
    std::cout << std::flush;
}

// Parse RTA_MULTIPATH payload into a list of NextHop structs.
static std::vector<NextHop> parse_multipath(int family,
                                            const void *data, int len) {
    std::vector<NextHop> result;
    const auto *nh = static_cast<const rtnexthop *>(data);

    while (len >= static_cast<int>(sizeof(*nh)) &&
           nh->rtnh_len <= static_cast<unsigned>(len)) {
        NextHop hop;
        hop.iface  = iface_name(nh->rtnh_ifindex);
        hop.weight = nh->rtnh_hops + 1; // kernel stores weight-1

        // Walk nested RTAs inside this nexthop
        const struct rtattr *rta = RTNH_DATA(nh);
        int rta_len = nh->rtnh_len - sizeof(*nh);
        while (RTA_OK(rta, rta_len)) {
            if (rta->rta_type == RTA_GATEWAY)
                hop.gateway = addr_to_str(family, RTA_DATA(rta));
            rta = RTA_NEXT(rta, rta_len);
        }
        result.push_back(hop);
        len -= NLMSG_ALIGN(nh->rtnh_len);
        nh   = RTNH_NEXT(nh);
    }
    return result;
}

// Process a single RTM_NEWROUTE / RTM_DELROUTE message.
static void handle_rtmsg(const struct nlmsghdr *nlh) {
    const auto *rtm = static_cast<const struct rtmsg *>(NLMSG_DATA(nlh));

    // Only care about main table, IPv4/IPv6
    if (rtm->rtm_table != RT_TABLE_MAIN)  return;
    if (rtm->rtm_family != AF_INET &&
        rtm->rtm_family != AF_INET6)       return;
    if (rtm->rtm_type   != RTN_UNICAST)    return;

    // Walk route attributes
    const struct rtattr *rta = RTM_RTA(rtm);
    int rta_len = RTM_PAYLOAD(nlh);

    std::string dst;
    std::vector<NextHop> multipath;
    bool has_multipath = false;

    while (RTA_OK(rta, rta_len)) {
        switch (rta->rta_type) {
        case RTA_DST:
            dst = addr_to_str(rtm->rtm_family, RTA_DATA(rta));
            break;
        case RTA_MULTIPATH:
            multipath    = parse_multipath(rtm->rtm_family,
                                           RTA_DATA(rta), RTA_PAYLOAD(rta));
            has_multipath = true;
            break;
        default:
            break;
        }
        rta = RTA_NEXT(rta, rta_len);
    }

    // We only care about ECMP routes (multipath with ≥2 nexthops)
    if (!has_multipath || multipath.size() < 2)
        return;

    if (dst.empty()) {
        // Use default representation for 0.0.0.0 / ::
        dst = (rtm->rtm_family == AF_INET) ? "0.0.0.0" : "::";
    }
    const std::string key = dst + "/" + std::to_string(rtm->rtm_dst_len);

    bool changed = false;

    if (nlh->nlmsg_type == RTM_DELROUTE) {
        if (g_ecmp_table.erase(key)) {
            std::cout << "[DEL] ECMP route " << key << "\n";
            changed = true;
        }
    } else { // RTM_NEWROUTE
        EcmpRoute route;
        route.prefix     = dst;
        route.prefix_len = rtm->rtm_dst_len;
        route.nexthops   = multipath;

        auto it = g_ecmp_table.find(key);
        if (it == g_ecmp_table.end()) {
            std::cout << "[ADD] ECMP route " << key << "\n";
            changed = true;
        } else {
            // Simple change detection: compare serialised nexthop list
            std::ostringstream old_s, new_s;
            for (auto &nh : it->second.nexthops)
                old_s << nh.gateway << nh.iface << nh.weight;
            for (auto &nh : route.nexthops)
                new_s << nh.gateway << nh.iface << nh.weight;
            if (old_s.str() != new_s.str()) {
                std::cout << "[MOD] ECMP route " << key << "\n";
                changed = true;
            }
        }
        g_ecmp_table[key] = route;
    }

    if (changed)
        print_ecmp_table();
}

// ──────────────────────────────────────────────────────────────────────────────

// Dump existing ECMP routes from the kernel at startup.
static void dump_routes(int fd) {
    struct {
        struct nlmsghdr nlh;
        struct rtmsg    rtm;
    } req = {};

    req.nlh.nlmsg_len   = NLMSG_LENGTH(sizeof(req.rtm));
    req.nlh.nlmsg_type  = RTM_GETROUTE;
    req.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    req.nlh.nlmsg_seq   = 1;
    req.rtm.rtm_family  = AF_UNSPEC; // both IPv4 and IPv6

    if (send(fd, &req, req.nlh.nlmsg_len, 0) < 0) {
        perror("send RTM_GETROUTE");
        return;
    }

    char buf[32768];
    while (true) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n < 0) { perror("recv"); break; }

        for (auto *nlh = reinterpret_cast<struct nlmsghdr *>(buf);
             NLMSG_OK(nlh, static_cast<unsigned>(n));
             nlh = NLMSG_NEXT(nlh, n)) {
            if (nlh->nlmsg_type == NLMSG_DONE)  return;
            if (nlh->nlmsg_type == NLMSG_ERROR)  return;
            if (nlh->nlmsg_type == RTM_NEWROUTE) handle_rtmsg(nlh);
        }
    }
}

int main() {
    // Open a Netlink/RTNETLINK socket
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_nl addr = {};
    addr.nl_family = AF_NETLINK;
    addr.nl_groups = RTMGRP_IPV4_ROUTE | RTMGRP_IPV6_ROUTE; // subscribe

    if (bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0) {
        perror("bind"); close(fd); return 1;
    }

    std::cout << "ECMP monitor started. Dumping existing routes...\n";
    dump_routes(fd);

    if (g_ecmp_table.empty())
        std::cout << "(no ECMP routes found at startup)\n";
    else
        print_ecmp_table();

    std::cout << "\nListening for route changes (Ctrl+C to stop)...\n";

    char buf[32768];
    while (true) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n < 0) { perror("recv"); break; }

        for (auto *nlh = reinterpret_cast<struct nlmsghdr *>(buf);
             NLMSG_OK(nlh, static_cast<unsigned>(n));
             nlh = NLMSG_NEXT(nlh, n)) {
            if (nlh->nlmsg_type == RTM_NEWROUTE ||
                nlh->nlmsg_type == RTM_DELROUTE)
                handle_rtmsg(nlh);
        }
    }

    close(fd);
    return 0;
}
