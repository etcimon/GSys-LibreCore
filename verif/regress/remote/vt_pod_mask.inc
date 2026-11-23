// VlMTaskDoneMask -- POD-layout variant (fallback design, guide §19.1).
// Keeps the mask layout-identical to upstream (m_word[16] only) so generated
// model class offsets never change -> immune to incremental/ccache ODR.
// Sleep state lives in a shared function-local-static sync object; a signal
// on any mask wakes all sleepers and each re-checks its own ready() predicate.
class VlMTaskDoneMask final {
    static constexpr unsigned WORDS = 16;
    static constexpr unsigned SLEEP_AFTER_YIELDS = 4;

    std::atomic<uint64_t> m_word[WORDS];

    struct SleepSync {
        std::mutex mutex;
        std::condition_variable cv;
        std::atomic<unsigned> waiters{0};
    };
    static SleepSync& sleepSync() {
        static SleepSync s;  // function-local static: one instance, thread-safe init
        return s;
    }

    bool wordReady(unsigned word, bool evenCycle, uint64_t pred) const {
        const uint64_t got = m_word[word].load(std::memory_order_acquire);
        return evenCycle ? ((got & pred) == pred) : ((got & pred) == 0);
    }
    void blockUntilReady(bool evenCycle, const uint64_t* predp, unsigned nWords) const {
        SleepSync& sync = sleepSync();
        std::unique_lock<std::mutex> lock{sync.mutex};
        ++sync.waiters;
        sync.cv.wait(lock, [&] { return ready(evenCycle, predp, nWords); });
        --sync.waiters;
    }
    void spinUntil(bool evenCycle, const uint64_t* predp, unsigned nWords) const {
        unsigned ct = 0;
        unsigned yields = 0;
        while (VL_UNLIKELY(!ready(evenCycle, predp, nWords))) {
            VL_CPU_RELAX();
            ++ct;
            if (VL_UNLIKELY(ct > VL_LOCK_SPINS)) {
                ct = 0;
                if (VL_UNLIKELY(++yields >= SLEEP_AFTER_YIELDS)) {
                    blockUntilReady(evenCycle, predp, nWords);
                    return;
                }
                VlMTaskVertex::yieldThread();
            }
        }
    }

public:
    static constexpr unsigned words() { return WORDS; }

    VlMTaskDoneMask() {
        for (unsigned i = 0; i < WORDS; ++i) m_word[i].store(0, std::memory_order_relaxed);
    }
    ~VlMTaskDoneMask() = default;

    void signal(uint32_t bit, bool evenCycle) {
        const uint32_t word = bit >> 6;
        const uint64_t mask = static_cast<uint64_t>(1) << (bit & 63);
        assert(word < WORDS);
        if (evenCycle) {
            m_word[word].fetch_or(mask, std::memory_order_release);
        } else {
            m_word[word].fetch_and(static_cast<uint64_t>(~mask), std::memory_order_release);
        }
        SleepSync& sync = sleepSync();
        if (VL_UNLIKELY(sync.waiters.load(std::memory_order_acquire) != 0)) {
            const std::lock_guard<std::mutex> lock{sync.mutex};
            sync.cv.notify_all();
        }
    }

    bool ready(bool evenCycle, const uint64_t* predp, unsigned nWords) const {
        assert(nWords <= WORDS);
        for (unsigned i = 0; i < nWords; ++i) {
            if (predp[i] && !wordReady(i, evenCycle, predp[i])) return false;
        }
        return true;
    }
    bool ready(bool evenCycle, uint64_t pred) const { return wordReady(0, evenCycle, pred); }

    void wait(bool evenCycle, const uint64_t* predp, unsigned nWords) const {
        spinUntil(evenCycle, predp, nWords);
    }
    void wait(bool evenCycle, uint64_t pred) const {
        if (!pred) return;
        const uint64_t storage = pred;
        spinUntil(evenCycle, &storage, 1);
    }
};
