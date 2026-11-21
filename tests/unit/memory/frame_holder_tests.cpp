// SPDX-License-Identifier: GPL-2.0-or-later
/* The x86-64 guest's frame holders: for each 4 KiB frame of a backing, the
 * locations at which a translator registered it, the retirement debt a
 * registration owes the write translations that may predate it, and the
 * publication of a store or a kernel write at every holder.
 *
 * Every row drives the mapping primitives and the registration entries
 * through the bridge, and reads the holders through the test variant. The
 * diagnostics that must stay 0 (accounting errors, holders that outlived their
 * state, removals the generation had not quiesced, allocations under a stripe
 * lock) are required to, whatever a row did. */
#include "domain_contract.hpp"
#include "frame_accounting.hpp"
#include "allocation_fault.hpp"
#include "address_space_types.hpp"
#include "require.hpp"
#include "scratch_backing.hpp"
#include "stripe_allocation_probe.hpp"
#include "uml_darwin_guest.h"
#include "uml_darwin_static_mmu.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <new>
#include <sys/mman.h>
#include <thread>
#include <utility>
#include <vector>

namespace {

using uml::memory::FrameAccounting;
using uml::memory::WriterLocation;
using uml::memory::testing::AllocationSite;
using uml::testing::ScratchBacking;
using uml::testing::require;

constexpr unsigned long page = DARWIN_UML_GUEST_PAGE_SIZE;
constexpr int rw = PROT_READ | PROT_WRITE;
constexpr int rx = PROT_READ | PROT_EXEC;
constexpr int rwx = PROT_READ | PROT_WRITE | PROT_EXEC;
constexpr int ro = PROT_READ;

std::atomic_uint64_t active_domain{};

bool provide_domain(std::uint64_t &domain) noexcept
{
	domain = active_domain.load(std::memory_order_acquire);
	return domain != 0;
}

/* The steps of a row run on a thread of their own, in a domain of their own,
 * so retiring the domain ends everything the row cached. */
class Domain final {
public:
	explicit Domain(std::uint64_t id) : id_{id} {}

	void run(const std::function<void()> &steps)
	{
		std::thread thread{[&] {
			active_domain.store(id_, std::memory_order_release);
			steps();
			active_domain.store(0, std::memory_order_release);
		}};
		thread.join();
	}

	void retire() { uml::memory::retire_domain(id_); }
	[[nodiscard]] std::uint64_t id() const noexcept { return id_; }

private:
	std::uint64_t id_;
};

/* A kernel write the table does not resolve, with every allocation of this
 * thread refused: the bytes have changed by the time the fallback publishes,
 * so it can fail neither by an allocation nor by any other means. Refused
 * attempts are counted, whether or not the path survives them. */
int copy_kernel_write_refusing(unsigned long address, const void *bytes,
	std::size_t length)
{
	const auto before = uml::memory::testing::refused_allocations();
	uml::memory::testing::refuse_allocations(true);
	const int result = darwin_uml_static_vm_copy_kernel_write(
		address, bytes, length);
	uml::memory::testing::refuse_allocations(false);
	require(uml::memory::testing::refused_allocations() == before,
		"the all-generations fallback allocated");
	return result;
}

int map(unsigned long generation, unsigned long address, ScratchBacking &backing,
	unsigned long first_page, unsigned long pages, int protection,
	int guest_code = 1)
{
	return darwin_uml_static_vm_map_generation(generation,
		reinterpret_cast<void *>(address), backing.descriptor(),
		first_page * page, pages * page, protection, guest_code, 1);
}

int protect(unsigned long address, unsigned long pages, int protection)
{
	return darwin_uml_static_vm_protect(
		reinterpret_cast<void *>(address), pages * page, protection);
}

int unmap(unsigned long generation, unsigned long address, unsigned long pages)
{
	return darwin_uml_static_vm_unmap_generation(generation,
		reinterpret_cast<void *>(address), pages * page);
}

struct Hold final {
	int result;
	darwin_uml_static_frame_hold hold;
	std::array<darwin_uml_static_frame_location, 16> owed;
};

Hold hold_frame(unsigned long generation, unsigned long address)
{
	Hold held{};
	held.result = darwin_uml_static_vm_hold_code_frame(nullptr, generation,
		address, held.owed.data(), held.owed.size(), &held.hold);
	return held;
}

/* A hold with a buffer of `capacity` locations and, optionally, the fallback
 * for a debt that does not fit. */
struct BigHold final {
	int result;
	darwin_uml_static_frame_hold hold;
	std::vector<darwin_uml_static_frame_location> owed;
};

BigHold hold_frame_with(unsigned long generation, unsigned long address,
	std::size_t capacity, bool global_ok)
{
	BigHold held{};
	held.owed.resize(capacity);
	held.hold.global_ok = global_ok ? 1 : 0;
	held.result = darwin_uml_static_vm_hold_code_frame(nullptr, generation,
		address, held.owed.data(), capacity, &held.hold);
	return held;
}

bool owes(const Hold &held, unsigned long generation, unsigned long address)
{
	for (std::size_t index = 0; index < held.hold.owed; ++index)
		if (held.owed[index].generation == generation &&
		    held.owed[index].page == address)
			return true;
	return false;
}

std::vector<WriterLocation> holders_of(
	const std::shared_ptr<uml::memory::MappedBacking> &backing,
	unsigned long frame)
{
	std::vector<WriterLocation> holders;
	FrameAccounting::holders_for_testing(*backing, frame * page, holders);
	return holders;
}

std::uint64_t stamp_of(unsigned long generation, unsigned long address)
{
	void *handle = nullptr;
	darwin_uml_static_code_page_stamp stamp{};
	require(darwin_uml_static_vm_code_page(
		generation, address, &handle, &stamp) == DARWIN_UML_STATIC_TRANSLATED);
	return stamp.version;
}

/* The code changes a generation published after `sequence`; -1 when the ring
 * no longer says. */
struct Changes final {
	std::vector<darwin_uml_static_code_change> ranges;
	std::uint64_t sequence{};
	int count{};
};

Changes changes_since(unsigned long generation, std::uint64_t sequence)
{
	Changes result;
	result.ranges.resize(64);
	void *context = darwin_uml_static_vm_execution_context_create(generation);
	require(context != nullptr);
	result.count = darwin_uml_static_vm_execution_context_code_change_ranges(
		context, sequence, result.ranges.data(), result.ranges.size(),
		&result.sequence);
	darwin_uml_static_vm_execution_context_destroy(context);
	if (result.count > 0)
		result.ranges.resize(static_cast<std::size_t>(result.count));
	else
		result.ranges.clear();
	return result;
}

std::uint64_t sequence_of(unsigned long generation)
{
	return changes_since(generation, ~std::uint64_t{0} >> 1).sequence;
}

bool covers(const Changes &changes, unsigned long address, unsigned long length)
{
	for (const auto &range : changes.ranges)
		if (range.length == 0 ||
		    (range.address <= address &&
		     range.address + range.length >= address + length))
			return true;
	return false;
}

/* Whether the generation was told of the range itself and not only that
 * everything changed. */
bool precisely(const Changes &changes, unsigned long address,
	unsigned long length)
{
	for (const auto &range : changes.ranges)
		if (range.length != 0 && range.address <= address &&
		    range.address + range.length >= address + length)
			return true;
	return false;
}

std::uint64_t flush_serial_of(unsigned long generation)
{
	void *context = darwin_uml_static_vm_execution_context_create(generation);
	require(context != nullptr);
	const auto serial =
		darwin_uml_static_vm_execution_context_flush_serial(context);
	darwin_uml_static_vm_execution_context_destroy(context);
	return serial;
}

struct Baseline final {
	FrameAccounting::Diagnostics start{FrameAccounting::diagnostics()};
	std::size_t stripe_allocations{
		uml::memory::testing::allocations_under_stripe_lock()};

	/* The counters that must stay 0 did, whatever the row did. */
	void clean(const char *row, std::uint64_t refusals = 0) const
	{
		const auto now = FrameAccounting::diagnostics();
		if (now.errors != start.errors ||
		    now.nonempty_state_destructions != start.nonempty_state_destructions ||
		    now.holder_leaks != start.holder_leaks ||
		    now.unquiesced_holder_removals != start.unquiesced_holder_removals ||
		    now.unmarked_holder_removals != start.unmarked_holder_removals ||
		    now.walked_refusals != start.walked_refusals + refusals ||
		    uml::memory::testing::allocations_under_stripe_lock() !=
			    stripe_allocations) {
			std::printf("%s: errors +%llu, nonempty destructions +%llu, "
				    "leaks +%llu, unquiesced +%llu, unmarked +%llu, "
				    "walked refusals +%llu, stripe allocations +%zu\n", row,
				static_cast<unsigned long long>(now.errors - start.errors),
				static_cast<unsigned long long>(
					now.nonempty_state_destructions -
					start.nonempty_state_destructions),
				static_cast<unsigned long long>(
					now.holder_leaks - start.holder_leaks),
				static_cast<unsigned long long>(
					now.unquiesced_holder_removals -
					start.unquiesced_holder_removals),
				static_cast<unsigned long long>(
					now.unmarked_holder_removals -
					start.unmarked_holder_removals),
				static_cast<unsigned long long>(
					now.walked_refusals - start.walked_refusals - refusals),
				uml::memory::testing::allocations_under_stripe_lock() -
					stripe_allocations);
			require(false, "a counter that must stay 0 moved");
		}
	}
};

/* M1 (holders): each primitive that ends a translatable word removes its
 * holder from the frame; one that keeps it leaves the holder; a flush, a
 * destroy and a retired domain leave none, and the alias count says so. */
void test_holders_follow_every_primitive()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x100'0000;
	ScratchBacking backing{"uml-frame-holders-XXXXXX", 16 * page};
	Domain domain{73'001};
	std::shared_ptr<uml::memory::MappedBacking> kept;
	std::uint32_t alias_601 = 0;
	domain.run([&] {
		require(map(701, base, backing, 0, 4, rx) == 0);
		kept = uml::memory::testing::mapped_backing(backing.descriptor());
		require(kept != nullptr);
		const auto state = uml::memory::testing::generation_state(701);
		require(state != nullptr && state->accounting.alias != 0);
		alias_601 = state->accounting.alias;
		require(holders_of(kept, 0).empty(), "a mapping registered a holder");

		for (unsigned long frame = 0; frame < 4; ++frame)
			require(hold_frame(701, base + frame * page).result ==
				DARWIN_UML_STATIC_FRAME_SETTLED);
		require(FrameAccounting::alias_holders_for_testing(*kept, alias_601) == 4);
		require(holders_of(kept, 2).size() == 1 &&
			holders_of(kept, 2)[0] == WriterLocation{alias_601, base + 2 * page});
		/* A repeat adds nothing. */
		require(hold_frame(701, base).result == DARWIN_UML_STATIC_FRAME_SETTLED);
		require(FrameAccounting::alias_holders_for_testing(*kept, alias_601) == 4);

		/* A protection that keeps execute keeps the holder; one that drops
		 * it removes it. */
		require(darwin_uml_static_vm_activate(701) == 0);
		require(protect(base, 1, rwx) == 0);
		require(holders_of(kept, 0).size() == 1, "protect kept execute");
		require(protect(base, 1, rw) == 0);
		require(holders_of(kept, 0).empty(), "protect without execute");
		require(hold_frame(701, base).result == DARWIN_UML_STATIC_FRAME_REFUSED,
			"a page without execute was registered");
		require(FrameAccounting::alias_holders_for_testing(*kept, alias_601) == 3);

		/* Unmap removes it; so does a page that moves to another frame. */
		require(unmap(701, base + page, 1) == 0);
		require(holders_of(kept, 1).empty());
		require(map(701, base + 2 * page, backing, 9, 1, rx) == 0);
		require(holders_of(kept, 2).empty() && holders_of(kept, 9).empty());
		require(FrameAccounting::alias_holders_for_testing(*kept, alias_601) == 1);
		require(hold_frame(701, base + 2 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);
		require(holders_of(kept, 9).size() == 1);

		/* A mapping that changes nothing about the frame keeps the holder; a
		 * flush takes every holder and the state stays usable. */
		require(map(701, base + 2 * page, backing, 9, 1, rx) == 0);
		require(holders_of(kept, 9).size() == 1);
		const auto serial = flush_serial_of(701);
		const auto diagnostics = FrameAccounting::diagnostics();
		require(darwin_uml_static_vm_flush_generation(701) == 0);
		require(holders_of(kept, 3).empty() && holders_of(kept, 9).empty());
		require(FrameAccounting::alias_holders_for_testing(*kept, alias_601) == 0);
		require(flush_serial_of(701) != serial, "a flush kept its serial");
		require(FrameAccounting::diagnostics().serial_bumps ==
			diagnostics.serial_bumps + 1);
		require(!state->accounting.walked);
		require(map(701, base, backing, 0, 2, rx) == 0);
		require(hold_frame(701, base).result == DARWIN_UML_STATIC_FRAME_SETTLED);
		require(holders_of(kept, 0).size() == 1);

		/* Destroy walks it for good. */
		require(darwin_uml_static_vm_destroy(701) == 0);
		require(holders_of(kept, 0).empty());
		require(FrameAccounting::alias_holders_for_testing(*kept, alias_601) == 0);
		require(state->accounting.walked &&
			kept->domain().state_of(alias_601) == nullptr);
	});
	/* A retired domain: its states are walked without their words going. */
	domain.run([&] {
		require(map(702, base, backing, 4, 2, rx) == 0);
		require(hold_frame(702, base).result == DARWIN_UML_STATIC_FRAME_SETTLED);
		require(holders_of(kept, 4).size() == 1);
	});
	domain.retire();
	require(holders_of(kept, 4).empty(), "a retired domain left a holder");
	baseline.clean("M1 holders");
}

/* M2: the debt a registration owes: every writer but itself when the frame had
 * no holder, the one holder when that is a writer, nothing for two or more.
 * A repeat and a second holder both return a debt that is still owed, and a
 * stale clear leaves a newer debt. */
void test_debts()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x200'0000;
	ScratchBacking backing{"uml-frame-debt-XXXXXX", 16 * page};
	Domain domain{73'002};
	domain.run([&] {
		/* H0 empty: the writer elsewhere is owed. */
		require(map(711, base, backing, 0, 1, rw, 0) == 0);
		require(map(711, base + 4 * page, backing, 0, 1, rx) == 0);
		require(map(711, base + 5 * page, backing, 0, 1, rx) == 0);
		auto first = hold_frame(711, base + 4 * page);
		require(first.result == DARWIN_UML_STATIC_FRAME_OWED);
		require(first.hold.owed == 1 && owes(first, 711, base));
		require(first.hold.debt_sequence == 1);
		/* A repeat is owed the same debt, and so is a second holder. */
		auto repeat = hold_frame(711, base + 4 * page);
		require(repeat.result == DARWIN_UML_STATIC_FRAME_OWED &&
			owes(repeat, 711, base) &&
			repeat.hold.record_identity == first.hold.record_identity);
		auto second = hold_frame(711, base + 5 * page);
		require(second.result == DARWIN_UML_STATIC_FRAME_OWED &&
			owes(second, 711, base), "a second holder inherits the debt");
		/* A completed retirement clears it. */
		darwin_uml_static_vm_clear_code_debt(nullptr, 711, base + 4 * page,
			first.hold.record_identity, first.hold.debt_sequence);
		require(hold_frame(711, base + 4 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);
		require(hold_frame(711, base + 5 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);

		/* H0 = {h1 not a writer}, and a third holder: nothing new owed. */
		require(map(711, base + 6 * page, backing, 0, 1, rx) == 0);
		require(hold_frame(711, base + 6 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);

		/* All holders gone; the next registration owes the writer again, and a
		 * stale clear leaves the newer debt. */
		require(unmap(711, base + 4 * page, 3) == 0);
		require(map(711, base + 4 * page, backing, 0, 1, rx) == 0);
		auto again = hold_frame(711, base + 4 * page);
		require(again.result == DARWIN_UML_STATIC_FRAME_OWED &&
			owes(again, 711, base) && again.hold.debt_sequence == 2);
		darwin_uml_static_vm_clear_code_debt(nullptr, 711, base + 4 * page,
			again.hold.record_identity, 1);
		require(hold_frame(711, base + 4 * page).result ==
			DARWIN_UML_STATIC_FRAME_OWED, "a stale clear removed a newer debt");
		/* A clear for another record changes nothing. */
		darwin_uml_static_vm_clear_code_debt(nullptr, 711, base + 4 * page,
			again.hold.record_identity + 1000, 2);
		require(hold_frame(711, base + 4 * page).result ==
			DARWIN_UML_STATIC_FRAME_OWED);
		darwin_uml_static_vm_clear_code_debt(nullptr, 711, base + 4 * page,
			again.hold.record_identity, 2);
		require(hold_frame(711, base + 4 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);

		/* H0 = {h1 a writer}: a page that is both writable and translatable
		 * owes nothing to itself, and a second location owes it. */
		require(map(712, base + 8 * page, backing, 3, 1, rwx) == 0);
		require(hold_frame(712, base + 8 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);
		require(map(712, base + 9 * page, backing, 3, 1, rx) == 0);
		auto aliased = hold_frame(712, base + 9 * page);
		require(aliased.result == DARWIN_UML_STATIC_FRAME_OWED &&
			aliased.hold.owed == 1 && owes(aliased, 712, base + 8 * page));
		darwin_uml_static_vm_clear_code_debt(nullptr, 712, base + 9 * page,
			aliased.hold.record_identity, aliased.hold.debt_sequence);
		/* Two or more holders: a third location owes nothing new. */
		require(map(712, base + 10 * page, backing, 3, 1, rx) == 0);
		require(hold_frame(712, base + 10 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);
	});
	domain.retire();
	baseline.clean("M2");
}

/* M3, M4 and M5: a store's publication moves the stamp once and publishes the
 * exact range at each holder in two generations; the explicit invalidation of
 * a generation fans out to the frame's other holders; a kernel write through
 * the kernel's alias of a frame does too, with or without the writer's own
 * word. */
void test_publication()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x300'0000;
	ScratchBacking backing{"uml-frame-publish-XXXXXX", 16 * page};
	Domain domain{73'003};
	darwin_uml_static_vm_require_coherent_kernel_code_writes();
	/* The kernel's alias of the whole backing. */
	void *alias = mmap(nullptr, 16 * page, PROT_READ | PROT_WRITE, MAP_SHARED,
		backing.descriptor(), 0);
	require(alias != MAP_FAILED);
	FrameAccounting::note_direct_map(alias, 16 * page, backing.descriptor(), 0);
	domain.run([&] {
		/* Two generations translate frame 2; generation 721 also writes it
		 * through another address. */
		require(map(721, base, backing, 2, 1, rx) == 0);
		require(map(721, base + page, backing, 2, 1, rw, 0) == 0);
		require(map(722, base + 8 * page, backing, 2, 1, rx) == 0);
		require(hold_frame(721, base).result == DARWIN_UML_STATIC_FRAME_OWED);
		require(hold_frame(722, base + 8 * page).result ==
			DARWIN_UML_STATIC_FRAME_OWED);
		darwin_uml_static_vm_clear_code_debt(nullptr, 721, base,
			hold_frame(721, base).hold.record_identity,
			hold_frame(721, base).hold.debt_sequence);

		/* M3 */
		const auto stamp = stamp_of(721, base);
		const auto before721 = sequence_of(721);
		const auto before722 = sequence_of(722);
		std::array<std::uint64_t, 4> own{};
		darwin_uml_static_frame_publication publication{};
		require(darwin_uml_static_vm_publish_frame_store(nullptr, 721,
			base + page + 0x40, 6, own.data(), own.size(), &publication) == 1,
			"a store through an alias was not published");
		require(stamp_of(721, base) == stamp + 1, "the stamp did not move once");
		require(stamp_of(722, base + 8 * page) == stamp + 1);
		require(publication.own_count == 1 && own[0] == base + 0x40 &&
			publication.own_records == 1 && publication.overflow == 0);
		const auto after721 = changes_since(721, before721);
		const auto after722 = changes_since(722, before722);
		require(after721.count == 1 && covers(after721, base + 0x40, 6));
		require(after722.count == 1 && covers(after722, base + 8 * page + 0x40, 6));

		/* A page whose only holder is the writer's own location publishes
		 * nothing: the caller's own path does. */
		require(map(723, base + 12 * page, backing, 5, 1, rwx) == 0);
		require(hold_frame(723, base + 12 * page).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED);
		const auto own_stamp = stamp_of(723, base + 12 * page);
		require(darwin_uml_static_vm_publish_frame_store(nullptr, 723,
			base + 12 * page + 8, 4, own.data(), own.size(), &publication) == 0);
		require(stamp_of(723, base + 12 * page) == own_stamp);
		/* A frame with no holder publishes nothing either. */
		require(map(723, base + 14 * page, backing, 7, 1, rw, 0) == 0);
		require(darwin_uml_static_vm_publish_frame_store(nullptr, 723,
			base + 14 * page, 4, own.data(), own.size(), &publication) == 0);

		/* M4: invalidate_code of the writer's page reaches the other
		 * holders, in both generations. */
		const auto stamp4 = stamp_of(722, base + 8 * page);
		const auto seq4 = sequence_of(722);
		require(darwin_uml_static_vm_invalidate_code_generation(
			721, base, page) == 0);
		require(stamp_of(722, base + 8 * page) > stamp4);
		require(covers(changes_since(722, seq4), base + 8 * page, page));

		/* M5: the kernel writes the frame through its alias; the user word
		 * of the writer is present. */
		require(darwin_uml_static_vm_activate(721) == 0);
		const auto stamp5 = stamp_of(721, base);
		const auto seq5 = sequence_of(722);
		const auto seq5_721 = sequence_of(721);
		auto *bytes = static_cast<unsigned char *>(alias) + 2 * page + 0x80;
		std::memset(bytes, 0xcc, 4);
		require(darwin_uml_static_vm_copy_kernel_write(
			base + page + 0x80, bytes, 4) == 0);
		require(stamp_of(721, base) > stamp5);
		require(covers(changes_since(722, seq5), base + 8 * page + 0x80, 4));
		require(covers(changes_since(721, seq5_721), base + 0x80, 4));

		/* M5b: the writer's word is absent; the alias alone names the frame. */
		const auto stamp5b = stamp_of(722, base + 8 * page);
		const auto seq5b = sequence_of(721);
		const auto unresolved = FrameAccounting::diagnostics().unresolved_kernel_writes;
		std::memset(bytes + 0x40, 0xdd, 8);
		require(darwin_uml_static_vm_copy_kernel_write(
			base + 11 * page + 0x40, bytes + 0x40, 8) == 0);
		require(stamp_of(722, base + 8 * page) > stamp5b);
		require(covers(changes_since(721, seq5b), base + 0xc0, 8));
		require(FrameAccounting::diagnostics().unresolved_kernel_writes ==
			unresolved, "a write through the alias was unresolved");

		/* A buffer that is no alias, with no word: every generation reads
		 * every translation again. */
		std::array<unsigned char, 8> loose{};
		const auto serial = flush_serial_of(721);
		const auto seq_all = sequence_of(722);
		require(copy_kernel_write_refusing(
			base + 11 * page, loose.data(), loose.size()) == 0,
			"the fallback failed without memory");
		require(FrameAccounting::diagnostics().unresolved_kernel_writes ==
			unresolved + 1);
		require(flush_serial_of(721) != serial);
		require(changes_since(722, seq_all).count != 0);
	});
	FrameAccounting::note_direct_unmap(alias, 16 * page);
	domain.retire();
	munmap(alias, 16 * page);
	baseline.clean("M3 M4 M5");
}

/* M7: a writer removal that finds no such location marks the frame unknown.
 * The writers are then not known, so a registration on it registers the
 * holder and answers that the debt is every write translation; it is not a
 * failure, and nothing keeps the frame from being registered again. */
void test_unknown_frame()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x400'0000;
	ScratchBacking backing{"uml-frame-unknown-XXXXXX", 8 * page};
	Domain domain{73'004};
	domain.run([&] {
		require(map(731, base, backing, 1, 1, rx) == 0);
		require(map(731, base + page, backing, 1, 1, rw, 0) == 0);
		const auto kept = uml::memory::testing::mapped_backing(backing.descriptor());
		require(kept != nullptr);
		const auto errors = FrameAccounting::diagnostics().errors;
		FrameAccounting::remove_writer(*kept, page, {777'777, base});
		require(FrameAccounting::diagnostics().errors == errors + 1);
		const auto failures = FrameAccounting::diagnostics().registration_failures;
		const auto first = hold_frame(731, base);
		require(first.result == DARWIN_UML_STATIC_FRAME_GLOBAL,
			"a frame of unknown writers did not take the fallback");
		require(FrameAccounting::diagnostics().registration_failures == failures,
			"the fallback was counted as a failure");
		require(holders_of(kept, 1).size() == 1, "the fallback did not register");
		/* The first holder's wait has not completed. A frame of unknown
		 * writers carries no debt of its own, so every holder after the
		 * first takes the fallback by itself and waits for what it must:
		 * the unknown kind does not go away, and nothing is left owed to
		 * one that registers meanwhile. */
		require(map(732, base + 2 * page, backing, 1, 1, rx) == 0);
		require(hold_frame(732, base + 2 * page).result ==
			DARWIN_UML_STATIC_FRAME_GLOBAL,
			"a later holder of a frame of unknown writers did not take the "
			"fallback while the first one's wait was pending");
		require(holders_of(kept, 1).size() == 2);
		darwin_uml_static_vm_clear_code_debt(nullptr, 731, base,
			first.hold.record_identity, first.hold.debt_sequence);
		require(hold_frame(731, base).result == DARWIN_UML_STATIC_FRAME_GLOBAL,
			"a frame of unknown writers settled");
		/* The unknown frame is a test's doing: its error is the one counted
		 * above. */
		require(unmap(731, base, 1) == 0);
		require(unmap(732, base + 2 * page, 1) == 0);
	});
	domain.retire();
	const auto now = FrameAccounting::diagnostics();
	require(now.holder_leaks == baseline.start.holder_leaks);
	require(now.nonempty_state_destructions ==
		baseline.start.nonempty_state_destructions);
}

/* M15: a frame with more writers than the caller's buffer holds is not
 * failed. The first registration is told how many to make room for and
 * changes nothing; the second, with room, names every one of them; with no
 * room at all it may take the fallback, which registers the holder and
 * settles with a single clearing. */
void test_a_debt_larger_than_the_buffer()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x700'0000;
	constexpr unsigned long writers = 17;
	ScratchBacking backing{"uml-frame-crowded-XXXXXX", 8 * page};
	Domain domain{73'007};
	domain.run([&] {
		for (unsigned long frame : {1UL, 2UL}) {
			for (unsigned long writer = 0; writer < writers; ++writer)
				require(map(950 + writer, base + frame * 0x10000, backing,
					frame, 1, rw, 0) == 0);
			require(map(990, base + frame * page, backing, frame, 1, rx) == 0);
		}
		const auto kept = uml::memory::testing::mapped_backing(backing.descriptor());
		require(kept != nullptr);

		const auto failures = FrameAccounting::diagnostics().registration_failures;
		const auto crowded = hold_frame_with(990, base + page, 16, false);
		require(crowded.result == DARWIN_UML_STATIC_FRAME_CROWDED &&
			crowded.hold.owed == writers,
			"a debt larger than the buffer did not say how large it is");
		require(holders_of(kept, 1).empty(), "a crowded hold registered");
		require(FrameAccounting::diagnostics().registration_failures == failures,
			"a crowded hold was counted as a failure");

		const auto roomy = hold_frame_with(990, base + page, 32, false);
		require(roomy.result == DARWIN_UML_STATIC_FRAME_OWED &&
			roomy.hold.owed == writers, "a hold with room did not owe all");
		for (unsigned long writer = 0; writer < writers; ++writer) {
			bool found = false;
			for (std::size_t index = 0; index < roomy.hold.owed; ++index)
				found = found || (roomy.owed[index].generation == 950 + writer &&
					roomy.owed[index].page == base + 0x10000);
			require(found, "a writer's location was not named");
		}
		require(holders_of(kept, 1).size() == 1, "the hold did not register");
		darwin_uml_static_vm_clear_code_debt(nullptr, 990, base + page,
			roomy.hold.record_identity, roomy.hold.debt_sequence);
		require(hold_frame_with(990, base + page, 0, false).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED, "a cleared debt was still owed");

		/* No room at all: the fallback registers the holder and one clearing
		 * settles it. */
		const auto globals = FrameAccounting::diagnostics().global_holds;
		const auto global = hold_frame_with(990, base + 2 * page, 0, true);
		require(global.result == DARWIN_UML_STATIC_FRAME_GLOBAL &&
			global.hold.owed == writers, "the fallback did not report its debt");
		require(FrameAccounting::diagnostics().global_holds == globals + 1,
			"a global hold was not counted");
		require(holders_of(kept, 2).size() == 1, "the fallback did not register");
		darwin_uml_static_vm_clear_code_debt(nullptr, 990, base + 2 * page,
			global.hold.record_identity, global.hold.debt_sequence);
		require(hold_frame_with(990, base + 2 * page, 0, false).result ==
			DARWIN_UML_STATIC_FRAME_SETTLED, "a cleared fallback was still owed");
		require(FrameAccounting::diagnostics().registration_failures == failures);
	});
	domain.retire();
	baseline.clean("M15");
}

/* M11 (serial): the flush serial moves at a walk and not at a stamp, and a
 * state made again under a generation number the last one used never repeats
 * a value. */
void test_flush_serial()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x500'0000;
	ScratchBacking backing{"uml-frame-serial-XXXXXX", 8 * page};
	Domain domain{73'005};
	domain.run([&] {
		std::vector<std::uint64_t> seen;
		require(map(741, base, backing, 0, 1, rx) == 0);
		require(hold_frame(741, base).result == DARWIN_UML_STATIC_FRAME_SETTLED);
		seen.push_back(flush_serial_of(741));
		const auto stamp = stamp_of(741, base);
		require(darwin_uml_static_vm_flush_generation(741) == 0);
		seen.push_back(flush_serial_of(741));
		require(map(741, base, backing, 0, 1, rx) == 0);
		require(stamp_of(741, base) == stamp,
			"a walk moved a stamp");
		require(darwin_uml_static_vm_destroy(741) == 0);
		/* Created again under the same number. */
		require(map(741, base, backing, 0, 1, rx) == 0);
		seen.push_back(flush_serial_of(741));
		require(darwin_uml_static_vm_destroy(741) == 0);
		for (std::size_t first = 0; first < seen.size(); ++first)
			for (std::size_t second = first + 1; second < seen.size(); ++second)
				require(seen[first] != seen[second],
					"two moments of a generation shared a serial");
		/* A walk of a state with nothing in it moves it too. */
		require(map(742, base, backing, 1, 1, ro) == 0);
		const auto before = flush_serial_of(742);
		require(darwin_uml_static_vm_flush_generation(742) == 0);
		require(flush_serial_of(742) != before);
		/* The pages of another generation sharing the frame keep their stamp
		 * when a different generation is flushed. */
		require(map(743, base, backing, 2, 1, rx) == 0);
		require(map(744, base, backing, 2, 1, rx) == 0);
		const auto other = stamp_of(743, base);
		require(darwin_uml_static_vm_destroy(744) == 0);
		require(stamp_of(743, base) == other);
		require(darwin_uml_static_vm_destroy(742) == 0);
		require(darwin_uml_static_vm_destroy(743) == 0);
	});
	domain.retire();
	baseline.clean("M11 serial");
}

/* M13: an allocation that fails at any of the points of a registration (the
 * frame's record, the holder list at its first use and at each growth)
 * returns "failed" with the frame as it was, and the registration made again
 * succeeds. No allocation is made under a stripe lock. */
void test_registration_allocation_failures()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x600'0000;
	constexpr unsigned long locations = 7;
	for (const auto site : {AllocationSite::records, AllocationSite::holders}) {
		std::size_t points = 0;
		for (std::size_t failing = 0; failing <= points; ++failing) {
			ScratchBacking backing{"uml-frame-alloc-XXXXXX", 8 * page};
			Domain domain{74'000 + failing + (site == AllocationSite::records ? 0 : 100)};
			const unsigned long generation =
				750 + failing + (site == AllocationSite::records ? 0 : 100);
			domain.run([&] {
				require(map(generation, base, backing, 3, 1, rx) == 0);
				const auto kept = uml::memory::testing::mapped_backing(
					backing.descriptor());
				require(kept != nullptr);
				uml::memory::testing::reset_allocation_attempt_counts();
				if (failing != 0)
					uml::memory::testing::fail_allocation_at(site, failing);
				std::size_t held = 0;
				std::size_t failures = 0;
				/* Several locations hold one frame, so the holder list grows
				 * from none to more than its first room. */
				for (unsigned long index = 0; index < locations; ++index) {
					const auto address = base + (index + 1) * page;
					require(map(generation, address, backing, 3, 1, rx) == 0);
					const auto before = holders_of(kept, 3);
					const auto changes = FrameAccounting::diagnostics();
					const auto result = hold_frame(generation, address);
					if (result.result == DARWIN_UML_STATIC_FRAME_FAILED) {
						++failures;
						require(holders_of(kept, 3) == before,
							"a failed registration changed the holders");
						require(FrameAccounting::diagnostics().holder_additions ==
							changes.holder_additions);
						/* Made again, it succeeds. */
						require(hold_frame(generation, address).result ==
							DARWIN_UML_STATIC_FRAME_SETTLED);
					}
					++held;
					require(holders_of(kept, 3).size() == held);
				}
				uml::memory::testing::clear_allocation_failure();
				if (failing == 0) {
					points = uml::memory::testing::allocation_attempt_count(site);
					require(points != 0, "the registration made no allocation");
				} else {
					require(failures == 1, "the injected failure did not fail once");
				}
			});
			domain.retire();
		}
		std::printf("%s: %zu allocation points in registration\n",
			site == AllocationSite::records ? "records" : "holders", points);
	}
	baseline.clean("M13");
}

/* M9: a writer reservation and a registration of one frame from two
 * generations, paused between the two in both orders. The registration that
 * follows the reservation owes the writer; the one that precedes it makes the
 * writer's fill tag. The two generations share nothing but the frame's stripe
 * lock, so one is held at an allocation checkpoint while the other completes. */
std::atomic_bool pause_armed{};
std::atomic_bool paused{};
std::atomic_bool resume{};
std::atomic<AllocationSite> pause_site{};

void pausing_observer(AllocationSite site) noexcept
{
	if (!pause_armed.load(std::memory_order_acquire) ||
	    site != pause_site.load(std::memory_order_acquire))
		return;
	pause_armed.store(false, std::memory_order_release);
	paused.store(true, std::memory_order_release);
	while (!resume.load(std::memory_order_acquire))
		std::this_thread::yield();
}

void test_reservation_and_registration_race()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x700'0000;
	ScratchBacking backing{"uml-frame-race-XXXXXX", 8 * page};
	for (const bool registration_first : {false, true}) {
		Domain domain{std::uint64_t{75'000} + (registration_first ? 1U : 0U)};
		const unsigned long reader = 760 + (registration_first ? 2 : 0);
		const unsigned long writer = reader + 1;
		domain.run([&] {
			require(map(reader, base, backing, 0, 1, rx) == 0);
			/* The writer's state exists, so the pause below is the
			 * reservation's and not the state's. */
			require(map(writer, base + 4 * page, backing, 4, 1, rw, 0) == 0);
			paused.store(false);
			resume.store(false);
			pause_site.store(registration_first ? AllocationSite::holders :
				AllocationSite::writers);
			pause_armed.store(true, std::memory_order_release);
			uml::memory::testing::set_allocation_observer(&pausing_observer);
			Hold held{};
			if (!registration_first) {
				/* The reservation is held before it takes the frame's lock;
				 * the registration completes first. */
				std::thread blocked{[&] {
					require(map(writer, base + page, backing, 0, 1, rw, 0) == 0);
				}};
				while (!paused.load(std::memory_order_acquire))
					std::this_thread::yield();
				held = hold_frame(reader, base);
				require(held.result == DARWIN_UML_STATIC_FRAME_SETTLED,
					"a registration owed a writer that was not there");
				resume.store(true, std::memory_order_release);
				blocked.join();
				uml::memory::testing::set_allocation_observer(nullptr);
				darwin_uml_static_frame_state state{};
				require(darwin_uml_static_vm_frame_state(nullptr, writer,
					base + page, &state) == 0);
				require(state.other_holder != 0,
					"the writer's fill did not see the holder");
			} else {
				/* The registration is held before it takes the frame's lock;
				 * the writer completes first. */
				std::thread blocked{[&] { held = hold_frame(reader, base); }};
				while (!paused.load(std::memory_order_acquire))
					std::this_thread::yield();
				require(map(writer, base + page, backing, 0, 1, rw, 0) == 0);
				resume.store(true, std::memory_order_release);
				blocked.join();
				uml::memory::testing::set_allocation_observer(nullptr);
				require(held.result == DARWIN_UML_STATIC_FRAME_OWED &&
					owes(held, writer, base + page),
					"a registration missed a writer that preceded it");
			}
		});
		domain.retire();
	}
	baseline.clean("M9");
}

/* M10: one thread stores and publishes while another registers a fresh holder
 * and reads. A store the registration did not see in the bytes it read has a
 * record in the new holder's ring. */
void test_store_against_registration()
{
	const Baseline baseline;
	constexpr unsigned long base_writer = 0x800'0000;
	constexpr unsigned long base_reader = 0x900'0000;
	constexpr unsigned long rounds = 500'000;
	ScratchBacking backing{"uml-frame-store-XXXXXX", 4 * page};
	Domain domain{76'001};
	void *alias = mmap(nullptr, 4 * page, PROT_READ | PROT_WRITE, MAP_SHARED,
		backing.descriptor(), 0);
	require(alias != MAP_FAILED);
	auto *cell = static_cast<std::atomic_uint64_t *>(
		static_cast<void *>(static_cast<unsigned char *>(alias) + page));
	domain.run([&] {
		require(map(771, base_writer, backing, 1, 1, rw, 0) == 0);
		require(map(771, base_writer + page, backing, 1, 1, rx) == 0);
		require(hold_frame(771, base_writer + page).result !=
			DARWIN_UML_STATIC_FRAME_FAILED);
		require(map(772, base_reader, backing, 1, 1, rx) == 0);
		std::atomic_bool stop{};
		std::atomic_uint64_t published{};
		std::thread writer{[&] {
			std::array<std::uint64_t, 2> own{};
			darwin_uml_static_frame_publication publication{};
			for (std::uint64_t value = 1; !stop.load(std::memory_order_acquire);
			     ++value) {
				cell->store(value, std::memory_order_release);
				require(darwin_uml_static_vm_publish_frame_store(nullptr, 771,
					base_writer, 8, own.data(), own.size(), &publication) >= 0);
				published.store(value, std::memory_order_release);
			}
		}};
		for (unsigned long round = 0; round < rounds; ++round) {
			require(unmap(772, base_reader, 1) == 0);
			require(map(772, base_reader, backing, 1, 1, rx) == 0);
			require(hold_frame(772, base_reader).result !=
				DARWIN_UML_STATIC_FRAME_FAILED);
			const auto before = sequence_of(772);
			const auto read = cell->load(std::memory_order_acquire);
			/* Wait for a store the read cannot have seen. */
			const auto limit = std::chrono::steady_clock::now() +
				std::chrono::seconds(5);
			while (published.load(std::memory_order_acquire) <= read &&
			       std::chrono::steady_clock::now() < limit)
				std::this_thread::yield();
			require(published.load(std::memory_order_acquire) > read,
				"the writer stopped");
			require(sequence_of(772) > before,
				"a store the registration missed reached no record");
		}
		stop.store(true, std::memory_order_release);
		writer.join();
	});
	munmap(alias, 4 * page);
	domain.retire();
	baseline.clean("M10");
}

/* The ranges of the kernel's linear map the host knows, as the table answers
 * for one address. */
bool resolves(const void *address, int expected_fd, std::uint64_t expected_offset)
{
	int fd = -1;
	std::uint64_t offset = 0;
	return FrameAccounting::resolve_direct(address, fd, offset) &&
		fd == expected_fd && offset == expected_offset;
}

bool unresolved(const void *address)
{
	int fd = -1;
	std::uint64_t offset = 0;
	return !FrameAccounting::resolve_direct(address, fd, offset);
}

/* K3 (table): an unmap inside a range splits it and keeps both ends, a map
 * over part of a range keeps what it does not cover, a range that continues
 * its neighbour joins it, and a range the table has no slot for is counted
 * and not lost silently. */
void test_direct_table()
{
	const auto drops = FrameAccounting::diagnostics().direct_range_drops;
	void *area = mmap(nullptr, 80 * page, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
	require(area != MAP_FAILED);
	const auto at = [&](unsigned long frame) {
		return static_cast<unsigned char *>(area) + frame * page;
	};
	FrameAccounting::note_direct_map(at(0), 16 * page, 5, 0x1000);
	require(resolves(at(0), 5, 0x1000) && resolves(at(15) + 7, 5, 0x1000 + 15 * page + 7));
	/* The middle goes; both ends stay. */
	FrameAccounting::note_direct_unmap(at(4), 2 * page);
	require(resolves(at(3) + 9, 5, 0x1000 + 3 * page + 9),
		"a partial unmap lost the range below it");
	require(unresolved(at(4)) && unresolved(at(5) + page - 1));
	require(resolves(at(6), 5, 0x1000 + 6 * page),
		"a partial unmap lost the range above it");
	require(resolves(at(15), 5, 0x1000 + 15 * page));
	/* A map over a middle part keeps the rest of the range it overlaps. */
	FrameAccounting::note_direct_map(at(8), 2 * page, 6, 0x9000);
	require(resolves(at(7), 5, 0x1000 + 7 * page) && resolves(at(10), 5, 0x1000 + 10 * page),
		"an overlapping map dropped what it does not cover");
	require(resolves(at(8) + 3, 6, 0x9000 + 3) && resolves(at(9), 6, 0x9000 + page));
	/* An unmap that spans several ranges and holes. */
	FrameAccounting::note_direct_unmap(at(2), 9 * page);
	require(resolves(at(1), 5, 0x1000 + page) && unresolved(at(2)) &&
		unresolved(at(8)) && unresolved(at(10)) && resolves(at(11), 5, 0x1000 + 11 * page));
	FrameAccounting::note_direct_unmap(at(0), 16 * page);
	require(unresolved(at(0)) && unresolved(at(11)) && unresolved(at(15)));
	require(FrameAccounting::diagnostics().direct_range_drops == drops,
		"a range was dropped while the table had room");

	/* Ranges that continue each other join, so a long linear map in many
	 * calls takes one slot. */
	for (unsigned long frame = 0; frame < 40; ++frame)
		FrameAccounting::note_direct_map(at(frame), page, 7,
			0x20000 + frame * page);
	require(FrameAccounting::diagnostics().direct_range_drops == drops,
		"adjacent ranges of one descriptor took a slot each");
	require(resolves(at(0), 7, 0x20000) && resolves(at(39) + 5, 7, 0x20000 + 39 * page + 5));
	FrameAccounting::note_direct_unmap(at(0), 40 * page);
	require(unresolved(at(20)));

	/* More separate ranges than slots: each one that finds no slot is
	 * counted, and every other range still answers. */
	for (unsigned long index = 0; index < 33; ++index)
		FrameAccounting::note_direct_map(at(2 * index), page, 8,
			0x40000 + index * 3 * page);
	require(FrameAccounting::diagnostics().direct_range_drops == drops + 1,
		"a range the table had no slot for was not counted");
	unsigned long answered = 0;
	for (unsigned long index = 0; index < 33; ++index)
		if (!unresolved(at(2 * index)))
			++answered;
	require(answered == 32, "the table lost more than the range it dropped");
	FrameAccounting::note_direct_unmap(at(0), 80 * page);
	for (unsigned long index = 0; index < 33; ++index)
		require(unresolved(at(2 * index)));
	munmap(area, 80 * page);
}

/* K1 and K2: a kernel write is published at the frame of the user word
 * whenever it is present, and at the frame the kernel's alias names when the
 * table resolves it; a buffer the table does not resolve is counted and
 * takes the fallback, whether or not the word is present. */
void test_kernel_write_frames()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x600'0000;
	ScratchBacking backing{"uml-frame-kernel-XXXXXX", 16 * page};
	Domain domain{73'006};
	darwin_uml_static_vm_require_coherent_kernel_code_writes();
	void *alias = mmap(nullptr, 16 * page, PROT_READ | PROT_WRITE, MAP_SHARED,
		backing.descriptor(), 0);
	require(alias != MAP_FAILED);
	domain.run([&] {
		/* Frame 2 is translated in 801 and 803; 802 writes it through a
		 * data mapping (its word is present). */
		require(map(801, base, backing, 2, 1, rx) == 0);
		require(map(803, base + 8 * page, backing, 2, 1, rx) == 0);
		require(map(802, base + page, backing, 2, 1, rw, 0) == 0);
		require(hold_frame(801, base).result != DARWIN_UML_STATIC_FRAME_FAILED);
		require(hold_frame(803, base + 8 * page).result !=
			DARWIN_UML_STATIC_FRAME_FAILED);
		require(darwin_uml_static_vm_activate(802) == 0);

		/* K1: the buffer is no alias, and the word is present. */
		std::array<unsigned char, 8> loose{};
		loose.fill(0xe9);
		const auto stamp = stamp_of(801, base);
		const auto seq801 = sequence_of(801);
		const auto seq803 = sequence_of(803);
		const auto serial = flush_serial_of(803);
		const auto counted = FrameAccounting::diagnostics().unresolved_kernel_writes;
		require(copy_kernel_write_refusing(
			base + page + 0x40, loose.data(), loose.size()) == 0,
			"the fallback failed without memory");
		require(FrameAccounting::diagnostics().unresolved_kernel_writes ==
			counted + 1, "a buffer outside the table was not counted");
		require(flush_serial_of(803) != serial,
			"a buffer outside the table took no fallback");
		require(stamp_of(801, base) > stamp,
			"the word's frame was not published");
		require(precisely(changes_since(801, seq801), base + 0x40, 8) &&
			precisely(changes_since(803, seq803), base + 8 * page + 0x40, 8),
			"a holder at another address was not told the range");

		/* K2: the buffer names frame 3, the word frame 4: both are
		 * published. */
		FrameAccounting::note_direct_map(alias, 16 * page, backing.descriptor(), 0);
		require(map(811, base + 2 * page, backing, 3, 1, rx) == 0);
		require(map(812, base + 3 * page, backing, 4, 1, rx) == 0);
		require(map(813, base + 4 * page, backing, 4, 1, rw, 0) == 0);
		require(hold_frame(811, base + 2 * page).result !=
			DARWIN_UML_STATIC_FRAME_FAILED);
		require(hold_frame(812, base + 3 * page).result !=
			DARWIN_UML_STATIC_FRAME_FAILED);
		require(darwin_uml_static_vm_activate(813) == 0);
		auto *bytes = static_cast<unsigned char *>(alias) + 3 * page + 0x20;
		std::memset(bytes, 0xcc, 4);
		const auto seq811 = sequence_of(811);
		const auto seq812 = sequence_of(812);
		const auto counted2 = FrameAccounting::diagnostics().unresolved_kernel_writes;
		require(darwin_uml_static_vm_copy_kernel_write(
			base + 4 * page + 0x20, bytes, 4) == 0);
		require(precisely(changes_since(812, seq812), base + 3 * page + 0x20, 4),
			"the frame the word names was not published");
		require(precisely(changes_since(811, seq811), base + 2 * page + 0x20, 4),
			"the frame the alias names was not published");
		require(FrameAccounting::diagnostics().unresolved_kernel_writes == counted2,
			"a write through the table was counted unresolved");
	});
	FrameAccounting::note_direct_unmap(alias, 16 * page);
	domain.retire();
	munmap(alias, 16 * page);
	baseline.clean("K1 K2");
}

/* R1: a frame is translated at X and written at W (one generation each); the
 * kernel's table holds the frame's alias in a range, a later host page of that
 * range is unmapped, and the kernel then copies through what is still mapped
 * into the word W holds present. The unmap must leave the rest of the range
 * in the table, so the write is published at the frame: X's stamp moves and
 * nothing is counted unresolved. */
void test_kernel_write_after_a_partial_unmap()
{
	const Baseline baseline;
	constexpr unsigned long base = 0xa00'0000;
	ScratchBacking backing{"uml-frame-partial-XXXXXX", 16 * page};
	Domain domain{73'009};
	darwin_uml_static_vm_require_coherent_kernel_code_writes();
	void *alias = mmap(nullptr, 16 * page, PROT_READ | PROT_WRITE, MAP_SHARED,
		backing.descriptor(), 0);
	require(alias != MAP_FAILED);
	domain.run([&] {
		FrameAccounting::note_direct_map(alias, 16 * page, backing.descriptor(), 0);
		require(map(831, base, backing, 2, 1, rx) == 0);
		require(map(832, base + page, backing, 2, 1, rw, 0) == 0);
		require(hold_frame(831, base).result != DARWIN_UML_STATIC_FRAME_FAILED);
		require(darwin_uml_static_vm_activate(832) == 0);
		/* W's word is present: the process wrote through it. */
		require(darwin_uml_static_vm_copy_kernel_write(base + page + 0x10,
			static_cast<unsigned char *>(alias) + 2 * page + 0x10, 4) == 0);

		/* The table loses the upper half; the lower half stays mapped. */
		FrameAccounting::note_direct_unmap(
			static_cast<unsigned char *>(alias) + 8 * page, 8 * page);
		auto *bytes = static_cast<unsigned char *>(alias) + 2 * page + 0x80;
		std::memset(bytes, 0xcc, 4);
		const auto stamp = stamp_of(831, base);
		const auto counted =
			FrameAccounting::diagnostics().unresolved_kernel_writes;
		require(darwin_uml_static_vm_copy_kernel_write(
			base + page + 0x80, bytes, 4) == 0);
		require(stamp_of(831, base) > stamp,
			"the kernel's write did not reach the translation of the frame");
		require(FrameAccounting::diagnostics().unresolved_kernel_writes ==
			counted, "the unmap of a later page lost the range");
	});
	FrameAccounting::note_direct_unmap(alias, 8 * page);
	domain.retire();
	munmap(alias, 16 * page);
	baseline.clean("R1");
}

/* E9: an address space is retired. Its states are walked after the table of
 * generations is unlocked, every holder is gone when the walk ends, a
 * registration and a reservation on a walked state are refused (counted, for
 * the first), and the state, dropped later, destructs with empty tables: no
 * state destroyed with its walk missing, no holder that outlived its state,
 * no removal the generation had not quiesced. */
void test_a_retired_address_space()
{
	const Baseline baseline;
	constexpr unsigned long base = 0xb00'0000;
	ScratchBacking backing{"uml-frame-retire-XXXXXX", 4 * page};
	Domain domain{73'010};
	std::shared_ptr<uml::memory::GenerationState> state;
	std::shared_ptr<uml::memory::MappedBacking> kept;
	domain.run([&] {
		require(map(851, base, backing, 1, 1, rx) == 0);
		require(hold_frame(851, base).result != DARWIN_UML_STATIC_FRAME_FAILED);
		kept = uml::memory::testing::mapped_backing(backing.descriptor());
		state = uml::memory::testing::generation_state(851);
		require(state != nullptr && kept != nullptr);
		std::vector<WriterLocation> holders;
		FrameAccounting::holders_for_testing(*kept, page, holders);
		require(holders.size() == 1, "the frame had no holder before the retire");
	});
	const auto locked = uml::memory::testing::retire_walks_under_lock();
	domain.retire();
	require(uml::memory::testing::retire_walks_under_lock() == locked,
		"the retire walk ran with the table of generations locked");
	require(state->accounting.walked, "the retire did not walk the state");
	std::vector<WriterLocation> holders;
	FrameAccounting::holders_for_testing(*kept, page, holders);
	require(holders.empty(), "a retired address space left a holder");

	std::array<darwin_uml_static_frame_location, 4> owed{};
	const auto refusals = FrameAccounting::diagnostics().walked_refusals;
	const auto report = FrameAccounting::hold(
		*state, base, owed.data(), owed.size(), false);
	require(report.result == FrameAccounting::HoldResult::refused,
		"a walked state took a registration");
	require(FrameAccounting::diagnostics().walked_refusals == refusals + 1,
		"the refusal of a registration on a walked state was not counted");
	bool refused = false;
	try {
		state->accounting.reservation.add(*state, *kept, 3 * page, base);
	} catch (const std::bad_alloc &) {
		refused = true;
	}
	require(refused, "a walked state took a reservation");
	std::vector<WriterLocation> left;
	require(FrameAccounting::locations_for_testing(*kept, 3 * page, left) &&
		left.empty(), "a refused reservation left a location");
	holders.clear();
	FrameAccounting::holders_for_testing(*kept, page, holders);
	require(holders.empty(), "a refused registration left a holder");
	state.reset();
	baseline.clean("E9", 1);
}

/* M16: two vCPUs of one generation register frames at once. Registrations
 * hold the generation's mapping lock shared, so everything they write in the
 * state is atomic or under a stripe lock: the thread sanitizer says whether it
 * is. */
void test_concurrent_registrations_of_one_state()
{
	const Baseline baseline;
	constexpr unsigned long base = 0x800'0000;
	ScratchBacking backing{"uml-frame-concurrent-XXXXXX", 8 * page};
	Domain domain{73'008};
	domain.run([&] {
		for (unsigned long frame = 1; frame <= 4; ++frame)
			require(map(960, base + frame * page, backing, frame, 1, rx) == 0);
		std::array<std::thread, 4> threads;
		std::atomic_bool go{};
		for (unsigned long index = 0; index < threads.size(); ++index)
			threads[index] = std::thread{[&, index] {
				while (!go.load(std::memory_order_acquire))
					std::this_thread::yield();
				for (unsigned round = 0; round < 200; ++round)
					require(hold_frame(960, base + (index + 1) * page).result ==
						DARWIN_UML_STATIC_FRAME_SETTLED);
			}};
		go.store(true, std::memory_order_release);
		for (auto &thread : threads)
			thread.join();
		const auto kept = uml::memory::testing::mapped_backing(backing.descriptor());
		for (unsigned long frame = 1; frame <= 4; ++frame)
			require(holders_of(kept, frame).size() == 1);
	});
	domain.retire();
	baseline.clean("M16");
}

} // namespace

int main()
{
	uml::memory::set_domain_provider(&provide_domain);
	const auto stripe_before =
		uml::memory::testing::allocations_under_stripe_lock();
	test_holders_follow_every_primitive();
	test_debts();
	test_publication();
	test_direct_table();
	test_kernel_write_frames();
	test_kernel_write_after_a_partial_unmap();
	test_a_retired_address_space();
	test_unknown_frame();
	test_a_debt_larger_than_the_buffer();
	test_concurrent_registrations_of_one_state();
	test_flush_serial();
	test_registration_allocation_failures();
	test_reservation_and_registration_race();
	test_store_against_registration();
	/* M13 (stripe): no registration, removal, publication or debt copy-out
	 * of any row allocated, made a record or took the records' mutex under a
	 * stripe lock, through any allocator. */
	require(uml::memory::testing::allocations_under_stripe_lock() ==
			stripe_before,
		"an allocation was made under a stripe lock");
	uml::memory::set_domain_provider(nullptr);
	std::puts("frame holder tests passed");
	return EXIT_SUCCESS;
}
