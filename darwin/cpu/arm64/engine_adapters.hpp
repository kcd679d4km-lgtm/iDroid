/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include "cpu/aot_selection.hpp"
#include "cpu/engine.hpp"

#include <memory>

namespace uml::cpu::arm64::detail {

[[nodiscard]] std::unique_ptr<CpuEngine> make_gadget_engine(
	EngineConfiguration configuration);
[[nodiscard]] std::unique_ptr<CpuEngine> make_jit_engine(
	EngineConfiguration configuration);
[[nodiscard]] bool native_jit_engine_available() noexcept;
/* A launch's word on the ahead-of-time component for the gadget engine and the
 * release it boots, before its first executor; false when it cannot be kept
 * (cpu/arm64/aot). A build without the component keeps `off` and `automatic`
 * and refuses `on`. */
[[nodiscard]] bool select_aot(AotSelection selection,
	const AotRelease *release) noexcept;

} // namespace uml::cpu::arm64::detail
