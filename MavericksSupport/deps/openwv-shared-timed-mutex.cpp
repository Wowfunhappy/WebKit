// std::shared_timed_mutex, which 10.9's libc++ predates (it arrived in 10.12). LLVM 14's
// libclang.dylib -- the newest libclang that loads on this host, and the one bindgen needs to
// parse the CDM headers when building OpenWV -- is linked against it. Build-time only: this is
// inserted into cargo/rustc, never shipped.
//
// The class is libc++'s, so it is reproduced here as libc++ defines it rather than as something
// merely large enough to fit: same member order and types, and the same __state_ encoding (the
// high bit means a writer holds the lock, the remaining bits count readers). The header's
// try_lock_for/try_lock_until/try_lock_shared_for/try_lock_shared_until are inline templates
// that operate on these members directly in the caller, so they only work if the layout and the
// encoding both match.

#include <climits>
#include <condition_variable>
#include <mutex>

namespace std {
inline namespace __1 {

class shared_timed_mutex {
public:
    shared_timed_mutex();
    ~shared_timed_mutex() = default;

    shared_timed_mutex(const shared_timed_mutex&) = delete;
    shared_timed_mutex& operator=(const shared_timed_mutex&) = delete;

    void lock();
    bool try_lock();
    void unlock();

    void lock_shared();
    bool try_lock_shared();
    void unlock_shared();

private:
    mutex __mut_;
    condition_variable __gate1_;
    condition_variable __gate2_;
    unsigned __state_;

    static const unsigned __write_entered_ = 1U << (sizeof(unsigned) * CHAR_BIT - 1);
    static const unsigned __n_readers_ = ~__write_entered_;
};

shared_timed_mutex::shared_timed_mutex()
    : __mut_()
    , __gate1_()
    , __gate2_()
    , __state_(0)
{
}

void shared_timed_mutex::lock()
{
    unique_lock<mutex> lk(__mut_);
    while (__state_ & __write_entered_)
        __gate1_.wait(lk);
    __state_ |= __write_entered_;
    while (__state_ & __n_readers_)
        __gate2_.wait(lk);
}

bool shared_timed_mutex::try_lock()
{
    unique_lock<mutex> lk(__mut_);
    if (__state_ == 0) {
        __state_ = __write_entered_;
        return true;
    }
    return false;
}

void shared_timed_mutex::unlock()
{
    lock_guard<mutex> lk(__mut_);
    __state_ = 0;
    __gate1_.notify_all();
}

void shared_timed_mutex::lock_shared()
{
    unique_lock<mutex> lk(__mut_);
    while ((__state_ & __write_entered_) || (__state_ & __n_readers_) == __n_readers_)
        __gate1_.wait(lk);
    unsigned num_readers = (__state_ & __n_readers_) + 1;
    __state_ &= ~__n_readers_;
    __state_ |= num_readers;
}

bool shared_timed_mutex::try_lock_shared()
{
    unique_lock<mutex> lk(__mut_);
    unsigned num_readers = __state_ & __n_readers_;
    if (!(__state_ & __write_entered_) && num_readers != __n_readers_) {
        ++num_readers;
        __state_ &= ~__n_readers_;
        __state_ |= num_readers;
        return true;
    }
    return false;
}

void shared_timed_mutex::unlock_shared()
{
    lock_guard<mutex> lk(__mut_);
    unsigned num_readers = (__state_ & __n_readers_) - 1;
    __state_ &= ~__n_readers_;
    __state_ |= num_readers;
    if (__state_ & __write_entered_) {
        if (num_readers == 0)
            __gate2_.notify_one();
    } else {
        if (num_readers == __n_readers_ - 1)
            __gate1_.notify_one();
    }
}

} // namespace __1
} // namespace std
