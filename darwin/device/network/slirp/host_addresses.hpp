// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

/*
 * The addresses of the host's own network interfaces, for the rule that keeps
 * the guest off the host itself. SLiRP connects a guest's flow with a socket
 * of the application, so a guest that addresses one of these addresses would
 * reach the application's own machine, services bound to every address
 * included. The provider refuses those flows (dns_frames.hpp) and judges
 * them against this table, not the system, for each frame: the table is read
 * again, on the provider's worker, when a frame that needs it finds it older
 * than a second.
 *
 * A family is its own sorted table. IPv4 is the only one the guest has; an
 * IPv6 table with its `contains` and its case in `read_host_addresses` adds
 * the second family.
 */

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace uml::network {

using HostIpv4 = std::array<std::uint8_t, 4>;

class HostAddresses final {
public:
	/* A table that holds every address an interface could hold: what the
	 * provider judges traffic by while it cannot tell which addresses
	 * the host has (the system has not listed them for too long), so that
	 * nothing is let through on the strength of a list it no longer trusts.
	 * It lacks what no table holds: 0.0.0.0, 255.255.255.255 and the
	 * multicast groups, so the guest's DHCP broadcast and its group traffic
	 * are judged as they are by any other table. */
	[[nodiscard]] static const HostAddresses &everything() noexcept;

	/* Replaces the IPv4 table with `addresses` (host byte order), in any
	 * order and with repeats. 0.0.0.0 and 255.255.255.255 are not kept. */
	void assign_ipv4(std::vector<std::uint32_t> addresses);

	/* Whether an interface of the host holds `address` or, for an interface
	 * with a broadcast address, that broadcast address, which a local
	 * socket bound to every address receives as well. */
	[[nodiscard]] bool contains(const HostIpv4 &address) const noexcept;

	[[nodiscard]] bool empty() const noexcept { return !all_ && ipv4_.empty(); }
	[[nodiscard]] std::size_t size() const noexcept { return ipv4_.size(); }

	[[nodiscard]] bool operator==(const HostAddresses &) const noexcept = default;

private:
	std::vector<std::uint32_t> ipv4_;
	bool all_{};
};

/* Every address the system lists for an interface now, up or down: a local
 * address is local whatever the state of its interface. Nothing when the
 * system cannot list them. */
[[nodiscard]] std::optional<HostAddresses> read_host_addresses();

} // namespace uml::network
