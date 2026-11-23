// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "verilated.h"

#include <atomic>
#include <thread>

struct Item final : VlDeletable {
    VlDeleter& queue;
    std::atomic<unsigned>& count;
    const bool cascade;
    Item(VlDeleter& q, std::atomic<unsigned>& c, bool child)
        : queue{q}, count{c}, cascade{child} {}
    ~Item() override {
        ++count;
        if (cascade) queue.put(new Item{queue, count, false});
    }
};

int main() {
    std::atomic<unsigned> count{0};
    {
        VlDeleter queue;
        const auto post = [&]() {
            for (unsigned i = 0; i < 4000; ++i) queue.put(new Item{queue, count, true});
        };
        std::thread a{post}, b{post};
        for (unsigned i = 0; i < 4000; ++i) queue.deleteAll();
        a.join();
        b.join();
        queue.deleteAll();
        if (count != 16000) return 1;
        queue.put(new Item{queue, count, true});  // Also drain while destroying the queue
    }
    return count != 16002;
}
