.text

# WTF::Mutex::Mutex() - C1 constructor
.globl __ZN3WTF5MutexC1Ev
__ZN3WTF5MutexC1Ev:
    # this pointer in %rdi - initialize pthread_mutex
    pushq   %rbp
    movq    %rsp, %rbp
    subq    $16, %rsp
    movq    %rdi, -8(%rbp)
    movq    -8(%rbp), %rdi
    xorq    %rsi, %rsi
    callq   _pthread_mutex_init
    addq    $16, %rsp
    popq    %rbp
    retq

# WTF::ThreadCondition::ThreadCondition() - C1 constructor
.globl __ZN3WTF15ThreadConditionC1Ev
__ZN3WTF15ThreadConditionC1Ev:
    pushq   %rbp
    movq    %rsp, %rbp
    subq    $16, %rsp
    movq    %rdi, -8(%rbp)
    movq    -8(%rbp), %rdi
    xorq    %rsi, %rsi
    callq   _pthread_cond_init
    addq    $16, %rsp
    popq    %rbp
    retq

# WTF::callOnMainThread(WTF::Function<void()> const&)
# The old Function type is essentially a std::function-like wrapper
# We just need to call the function pointer inside it
.globl __ZN3WTF16callOnMainThreadERKNS_8FunctionIFvvEEE
__ZN3WTF16callOnMainThreadERKNS_8FunctionIFvvEEE:
    # %rdi = const WTF::Function<void()>*
    # Just return for now - this is called but not critical for initial launch
    retq

# WTF::Function_void::operator()() const - stub  
.globl __ZNK3WTF13Function_voidclEv
__ZNK3WTF13Function_voidclEv:
    retq
