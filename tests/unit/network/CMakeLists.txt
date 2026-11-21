# SPDX-License-Identifier: GPL-2.0-or-later

if(TARGET uml_network_dns_rules)
    add_executable(uml_dns_rules_tests dns_rules_tests.cpp)
    target_include_directories(uml_dns_rules_tests PRIVATE
        ${PROJECT_SOURCE_DIR}/darwin/device/network/slirp)
    target_link_libraries(uml_dns_rules_tests PRIVATE UML::NetworkDnsRules)
    uml_add_unit_test(NAME network-dns-rules
        COMMAND uml_dns_rules_tests
        LABELS network;slirp)
endif()

# What the guest's network counts: a resolver error's class and the DHCP and
# TCP set-up read off the provider's frames.
if(TARGET uml_network_dns_rules)
    add_executable(uml_network_counters_tests network_counters_tests.cpp)
    target_include_directories(uml_network_counters_tests PRIVATE
        ${PROJECT_SOURCE_DIR}/darwin/device/network/slirp)
    target_link_libraries(uml_network_counters_tests PRIVATE
        UML::NetworkDnsRules)
    uml_add_unit_test(NAME network-counters
        COMMAND uml_network_counters_tests
        LABELS network;slirp)
endif()

# What keeps the guest off the host itself: the table of the host's addresses,
# the frames the provider refuses because they address one of them, and the
# frames that make it look the table up again.
if(TARGET uml_network_dns_rules)
    add_executable(uml_host_isolation_tests host_isolation_tests.cpp)
    target_include_directories(uml_host_isolation_tests PRIVATE
        ${PROJECT_SOURCE_DIR}/darwin/device/network/slirp)
    target_link_libraries(uml_host_isolation_tests PRIVATE
        UML::NetworkDnsRules)
    uml_add_unit_test(NAME network-host-isolation-rules
        COMMAND uml_host_isolation_tests
        LABELS network;slirp)
endif()
