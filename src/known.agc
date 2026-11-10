## The library functions whose effects the rules know: those that block, allocate or make a system call. A function
## of the project is judged by its body (or by its annotation), and a library function not listed here by nothing:
## it has no effect.

## The calls of the C library and POSIX that can wait without a bound: on a file, a socket, a child, a lock of C11, a
## condition or the clock.
export LIBC_BLOCKING = Set.new([
  "accept", "accept4", "connect", "recv", "recvfrom", "recvmsg", "send", "sendto", "sendmsg", "sendmmsg", "recvmmsg",
  "read", "write", "pread", "pwrite", "readv", "writev", "preadv", "pwritev", "open", "openat", "creat", "fsync",
  "fdatasync", "sync", "syncfs", "msync", "flock", "lockf", "poll", "ppoll", "select", "pselect", "epoll_wait",
  "epoll_pwait", "sleep", "usleep", "nanosleep", "clock_nanosleep", "pause", "sigsuspend", "sigwait", "sigwaitinfo",
  "sigtimedwait", "wait", "waitpid", "waitid", "wait3", "wait4", "system", "popen", "pclose", "fopen", "fdopen",
  "freopen", "fclose", "fflush", "fread", "fwrite", "fgets", "fgetc", "getc", "getchar", "fputs", "fputc", "putc",
  "putchar", "puts", "printf", "fprintf", "vprintf", "vfprintf", "scanf", "fscanf", "getline", "getdelim", "perror",
  "getaddrinfo", "gethostbyname", "gethostbyaddr", "getnameinfo", "dlopen", "msgrcv", "msgsnd", "semop", "semtimedop",
  "mq_receive", "mq_send", "mq_timedreceive", "mq_timedsend", "sem_wait", "sem_timedwait", "sem_clockwait",
  "thrd_join", "thrd_sleep", "mtx_lock", "mtx_timedlock", "cnd_wait", "cnd_timedwait", "call_once", "remove",
  "dprintf", "vdprintf", "fseek", "ftell", "rewind", "sendfile", "mkstemp", "tmpfile", "realpath", "dlsym", "dlclose",
])

## The calls of POSIX threads that wait for another thread.
export PTHREAD_BLOCKING = Set.new([
  "pthread_join", "pthread_timedjoin_np", "pthread_mutex_lock", "pthread_mutex_timedlock", "pthread_mutex_clocklock",
  "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "pthread_rwlock_timedrdlock", "pthread_rwlock_timedwrlock",
  "pthread_cond_wait", "pthread_cond_timedwait", "pthread_cond_clockwait", "pthread_barrier_wait", "pthread_spin_lock",
  "pthread_once",
])

# The libuv lists (`LIBUV_BLOCKING`, `LIBUV_SYSTEM`, `LOOP_CALLBACKS`) match the calls and argument places of `uv.h`
# of libuv 1.50.0. A newer libuv may add or change calls: check its `uv.h` against them before relying on it.

## The calls of libuv that wait. Its file calls run at once, on the calling thread, when they are given no callback:
## the rules count one as blocking only when its last argument is NULL or 0, and only when the libc call it makes
## blocks (`open`, `read`, `fsync`, `realpath`). The others are in `LIBUV_SYSTEM`.
export LIBUV_BLOCKING = Set.new([
  "uv_run", "uv_sleep", "uv_thread_join", "uv_mutex_lock", "uv_rwlock_rdlock", "uv_rwlock_wrlock", "uv_cond_wait",
  "uv_cond_timedwait", "uv_sem_wait", "uv_barrier_wait", "uv_once", "uv_fs_open", "uv_fs_read", "uv_fs_write",
  "uv_fs_copyfile", "uv_fs_mkstemp", "uv_fs_fsync", "uv_fs_fdatasync", "uv_fs_sendfile", "uv_fs_realpath",
])

## The file calls of libuv that, run at once (no callback), make a system call that does not wait, as the libc call
## they make (`close`, `stat`, `unlink`, `mkdir`) is in `SYSTEM`.
export LIBUV_SYSTEM = Set.new([
  "uv_fs_close", "uv_fs_unlink", "uv_fs_mkdir", "uv_fs_mkdtemp", "uv_fs_rmdir", "uv_fs_opendir", "uv_fs_closedir",
  "uv_fs_readdir", "uv_fs_scandir", "uv_fs_stat", "uv_fs_fstat", "uv_fs_lstat", "uv_fs_statfs", "uv_fs_rename",
  "uv_fs_ftruncate", "uv_fs_access", "uv_fs_chmod", "uv_fs_fchmod", "uv_fs_utime", "uv_fs_futime", "uv_fs_lutime",
  "uv_fs_link", "uv_fs_symlink", "uv_fs_readlink", "uv_fs_chown", "uv_fs_fchown", "uv_fs_lchown",
])

## The calls of the Boehm GC that wait: a full collection stops the world.
export LIBGC_BLOCKING = Set.new(["GC_gcollect"])

## The families of blocking calls, in the order of docs/settings.md.
export BLOCKING_FAMILIES = [
  Family(flag: "libc_blocking", calls: LIBC_BLOCKING),
  Family(flag: "pthread_blocking", calls: PTHREAD_BLOCKING),
  Family(flag: "libuv_blocking", calls: LIBUV_BLOCKING),
  Family(flag: "libgc_blocking", calls: LIBGC_BLOCKING),
]

## Every call that can block, whatever the settings: each enters the kernel, which the CC_HOT rule forbids.
export BLOCKING = LIBC_BLOCKING.union(PTHREAD_BLOCKING).union(LIBUV_BLOCKING).union(LIBGC_BLOCKING)

## The `[library]` flag of the jumps inferred through the calls: a function that calls one that may jump out may jump
## out too (`Effects.with_jumps`).
export JUMP_CALLERS_FLAG = "may_jump_callers"

## The `[library]` flag of the short locks inferred from their critical sections: a lock that no call made while it is
## held reaches a blocking call is short (`Effects.check`).
export SECTIONS_FLAG = "short_lock_sections"

## The `[library]` flag of the roots inferred from `LOOP_CALLBACKS`.
export CALLBACKS_FLAG = "libuv_callbacks_short"

## The libuv calls that run a callback on the loop thread, and the places of those callbacks among their arguments
## (from 0). Such a callback runs on the event loop, so it is a CC_SHORT root. The `work_cb` of `uv_queue_work`
## (place 2) runs on a thread of the pool and is not one; its `after_work_cb` is. A `uv_fs_*` call given a callback
## runs it on the loop too, when the request ends.
export LOOP_CALLBACKS: Map[String, List[Int]] = {
  "uv_timer_start": [1],
  "uv_poll_start": [2],
  "uv_async_init": [2],
  "uv_close": [1],
  "uv_walk": [1],
  "uv_read_start": [1, 2],
  "uv_write": [4],
  "uv_write2": [5],
  "uv_shutdown": [2],
  "uv_tcp_connect": [3],
  "uv_pipe_connect": [3],
  "uv_pipe_connect2": [5],
  "uv_queue_work": [3],
  "uv_listen": [2],
  "uv_idle_start": [1],
  "uv_prepare_start": [1],
  "uv_check_start": [1],
  "uv_signal_start": [1],
  "uv_signal_start_oneshot": [1],
  "uv_tcp_close_reset": [1],
  "uv_udp_recv_start": [1, 2],
  "uv_udp_send": [5],
  "uv_getaddrinfo": [2],
  "uv_getnameinfo": [2],
  "uv_random": [5],
  "uv_fs_event_start": [1],
  "uv_fs_poll_start": [1],
  "uv_fs_access": [4],
  "uv_fs_chmod": [4],
  "uv_fs_chown": [5],
  "uv_fs_close": [3],
  "uv_fs_closedir": [3],
  "uv_fs_copyfile": [5],
  "uv_fs_fchmod": [4],
  "uv_fs_fchown": [5],
  "uv_fs_fdatasync": [3],
  "uv_fs_fstat": [3],
  "uv_fs_fsync": [3],
  "uv_fs_ftruncate": [4],
  "uv_fs_futime": [5],
  "uv_fs_lchown": [5],
  "uv_fs_link": [4],
  "uv_fs_lstat": [3],
  "uv_fs_lutime": [5],
  "uv_fs_mkdir": [4],
  "uv_fs_mkdtemp": [3],
  "uv_fs_mkstemp": [3],
  "uv_fs_open": [5],
  "uv_fs_opendir": [3],
  "uv_fs_read": [6],
  "uv_fs_readdir": [3],
  "uv_fs_readlink": [3],
  "uv_fs_realpath": [3],
  "uv_fs_rename": [4],
  "uv_fs_rmdir": [3],
  "uv_fs_scandir": [4],
  "uv_fs_sendfile": [6],
  "uv_fs_stat": [3],
  "uv_fs_statfs": [3],
  "uv_fs_symlink": [5],
  "uv_fs_unlink": [3],
  "uv_fs_utime": [5],
  "uv_fs_write": [6],
}

## The function pointer fields (slots, `field:Struct.field`) that libuv calls on the loop thread, with the name that
## the root shows. The struct is named by its tag (`uv_process_options_s`) and by its typedef, as a project may use
## either. `exit_cb` is called when the process that `uv_spawn` starts with these options ends.
export LOOP_CALLBACK_FIELDS: Map[String, String] = {
  "field:uv_process_options_s.exit_cb": "uv_process_options_t.exit_cb",
  "field:uv_process_options_t.exit_cb": "uv_process_options_t.exit_cb",
}

## The calls that take or give back memory of the heap.
export ALLOCATING = Set.new([
  "malloc", "calloc", "realloc", "reallocarray", "free", "aligned_alloc", "posix_memalign", "memalign", "valloc",
  "pvalloc", "strdup", "strndup", "asprintf", "vasprintf", "getline", "getdelim", "open_memstream", "GC_malloc",
  "GC_malloc_atomic", "GC_malloc_uncollectable", "GC_malloc_atomic_uncollectable", "GC_realloc", "GC_free",
  "GC_strdup", "GC_strndup", "GC_debug_malloc", "GC_debug_malloc_atomic", "GC_debug_realloc", "GC_debug_free",
  "realpath", "SSL_new", "SSL_CTX_new", "BIO_new",
])

## The calls that enter the kernel, besides the blocking ones (which all do). An unlock or a signal of a condition is
## one: it wakes a waiter with a futex call.
export SYSTEM = Set.new([
  "close", "lseek", "stat", "fstat", "lstat", "fstatat", "statx", "access", "faccessat", "readlink", "unlink",
  "unlinkat", "link", "linkat", "symlink", "symlinkat", "rename", "renameat", "mkdir", "mkdirat", "mkdtemp", "rmdir",
  "chdir", "fchdir", "getcwd", "truncate", "ftruncate", "fallocate", "chmod", "fchmod", "chown", "fchown", "lchown",
  "utime", "utimes", "utimensat", "statfs", "fstatfs", "opendir", "readdir", "closedir", "mmap", "munmap", "mremap",
  "mprotect", "madvise", "mlock", "munlock", "brk", "sbrk", "ioctl", "fcntl", "dup", "dup2", "dup3", "pipe", "pipe2",
  "socket", "socketpair", "bind", "listen", "shutdown", "setsockopt", "getsockopt", "getsockname", "getpeername",
  "epoll_create", "epoll_create1", "epoll_ctl", "eventfd", "timerfd_create", "timerfd_settime", "signalfd",
  "inotify_init", "inotify_init1", "inotify_add_watch", "kill", "tgkill", "raise", "sigaction", "signal",
  "sigprocmask", "pthread_sigmask", "sigaltstack", "fork", "vfork", "execve", "execv", "execvp", "execl", "execlp",
  "posix_spawn", "posix_spawnp", "_exit", "getpid", "getppid", "gettid", "syscall", "sched_yield", "prctl", "uname",
  "getrandom", "getrlimit", "setrlimit", "pthread_create", "pthread_kill", "pthread_cond_signal",
  "pthread_cond_broadcast", "pthread_mutex_unlock", "sem_post", "uv_thread_create", "uv_async_send", "uv_cond_signal",
  "uv_cond_broadcast", "uv_mutex_unlock",
]).union(LIBUV_SYSTEM)

## The calls that take the lock of their first argument, and wait for it.
export TAKES = Set.new([
  "pthread_mutex_lock", "pthread_spin_lock", "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "mtx_lock",
  "uv_mutex_lock", "uv_rwlock_rdlock", "uv_rwlock_wrlock", "EnterCriticalSection", "AcquireSRWLockExclusive",
  "AcquireSRWLockShared",
])

## The calls that take the lock of their first argument only when they return 0: in a condition, the lock is held on
## the branch where the call gave 0. The calls of `TAKES` that return a number count as these in a condition.
export TRIES = Set.new([
  "pthread_mutex_trylock", "pthread_spin_trylock", "pthread_rwlock_tryrdlock", "pthread_rwlock_trywrlock",
  "pthread_mutex_timedlock", "pthread_mutex_clocklock", "pthread_rwlock_timedrdlock", "pthread_rwlock_timedwrlock",
  "mtx_trylock", "mtx_timedlock", "uv_mutex_trylock", "uv_rwlock_tryrdlock", "uv_rwlock_trywrlock",
  "pthread_mutex_lock", "pthread_spin_lock", "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "mtx_lock",
])

## The calls of `TRIES` that never wait for their lock, so a trylock is never out of the lock order.
export NO_WAIT = Set.new([
  "pthread_mutex_trylock", "pthread_spin_trylock", "pthread_rwlock_tryrdlock", "pthread_rwlock_trywrlock",
  "mtx_trylock", "uv_mutex_trylock", "uv_rwlock_tryrdlock", "uv_rwlock_trywrlock",
])

## The calls that release the lock of their first argument.
export DROPS = Set.new([
  "pthread_mutex_unlock", "pthread_spin_unlock", "pthread_rwlock_unlock", "mtx_unlock", "uv_mutex_unlock",
  "uv_rwlock_rdunlock", "uv_rwlock_wrunlock", "LeaveCriticalSection", "ReleaseSRWLockExclusive",
  "ReleaseSRWLockShared",
])

## The calls that wait on a condition with the lock of their second argument, which they give back while they wait.
export WAITS = Set.new([
  "pthread_cond_wait", "pthread_cond_timedwait", "pthread_cond_clockwait", "cnd_wait", "cnd_timedwait", "uv_cond_wait",
  "uv_cond_timedwait", "SleepConditionVariableCS", "SleepConditionVariableSRW",
])

## The calls that catch a jump: a `longjmp` lands in the function that called one. glibc's `setjmp` and `sigsetjmp`
## are macros of `_setjmp` and `__sigsetjmp`.
export SETJMP = Set.new(["setjmp", "_setjmp", "__setjmp", "sigsetjmp", "__sigsetjmp", "__builtin_setjmp"])

## The calls that never come back, besides those whose type says `noreturn`.
export NORETURN = Set.new([
  "abort", "exit", "_exit", "_Exit", "quick_exit", "longjmp", "siglongjmp", "_longjmp", "pthread_exit", "thrd_exit",
  "__assert_fail", "__builtin_unreachable", "__builtin_trap", "err", "errx", "verr", "verrx",
])

## The calls that return memory of the heap for the caller to free: a pointer that owns gets a new value from them.
export OWNED = Set.new([
  "malloc", "calloc", "realloc", "reallocarray", "aligned_alloc", "memalign", "valloc", "pvalloc", "strdup", "strndup",
])

## The calls that free the memory of their first argument.
export FREES = Set.new(["free"])

## The calls that fill memory with a byte (`memset(&p, 0, sizeof p)`), as the builtins of a fortified build name them
## too.
export FILLS = Set.new(["memset", "__builtin_memset", "__builtin___memset_chk"])

## The builtins that read only the type of their argument, as `sizeof` does: the argument is not evaluated.
export UNEVALUATED = Set.new(["__builtin_object_size", "__builtin_dynamic_object_size"])

## The calls that move the memory of their first argument to the pointer they return; when that pointer is null, the
## first argument still owns it.
export RESIZES = Set.new(["realloc", "reallocarray"])

## The `[library]` flag of the allocators of the Boehm collector (`LIBGC_ALLOC`) in the collector rule.
export LIBGC_ALLOC_FLAG = "libgc_alloc"

## The allocators of the Boehm collector whose memory it manages (not the uncollectable ones, which are roots).
export LIBGC_ALLOC = Set.new([
  "GC_malloc", "GC_malloc_atomic", "GC_realloc", "GC_strdup", "GC_strndup", "GC_malloc_ignore_off_page",
  "GC_malloc_atomic_ignore_off_page", "GC_debug_malloc", "GC_debug_malloc_atomic", "GC_debug_realloc",
  "GC_debug_strdup", "GC_debug_strndup", "GC_debug_malloc_ignore_off_page", "GC_debug_malloc_atomic_ignore_off_page",
  "GC_memalign",
])

## The `[library]` flag of the flags that make a blocking call return at once (`FLAG_ARGUMENTS`).
export NONBLOCKING_FLAG = "libc_nonblocking_flags"

## The calls that a flag makes return at once, and the place of their flags among their arguments (from 0):
## O_NONBLOCK for `open` and `openat`, MSG_DONTWAIT for `recv`, `send`, `recvfrom` and `sendto`, WNOHANG for
## `waitpid`, `wait3`, `wait4` and `waitid`, and the mode UV_RUN_NOWAIT for `uv_run`.
export FLAG_ARGUMENTS: Map[String, Int] = {
  "open": 1, "openat": 2, "recv": 3, "send": 3, "recvfrom": 3, "sendto": 3, "uv_run": 1, "waitpid": 2, "wait3": 1,
  "wait4": 2, "waitid": 3,
}

## The calls on a descriptor that return at once when it is non-blocking (O_NONBLOCK): those of the functions of
## `[assume] nonblocking` are not blocking for CC_SHORT. The setting asserts that every descriptor they use there is a
## socket, a pipe or a terminal: O_NONBLOCK does not make a `read` or `write` of a regular file return at once, and
## such a call in a listed function is hidden too. `pread` and `pwrite`, which only read files, are not among them.
export FD_CALLS = Set.new([
  "read", "write", "readv", "writev", "recv", "send", "recvfrom", "sendto", "recvmsg", "sendmsg", "recvmmsg",
  "sendmmsg", "accept", "accept4", "connect",
])

# The calls whose flag is WNOHANG.
WAIT_CALLS = ["waitpid", "wait3", "wait4", "waitid"]

# The value of UV_RUN_NOWAIT, the same on every target: libuv's `uv_run_mode` is an enum (DEFAULT 0, ONCE 1, NOWAIT 2).
UV_RUN_NOWAIT_VALUE = 2

## A family of library knowledge: the flag of `[library]` that turns it on or off, and the calls it says block.
export struct Family
  flag: String
  calls: Set[String]
end

## Returns the name of the flag that makes a call of `FLAG_ARGUMENTS` return at once. A C library may define it as
## a constant of an enum (glibc does for MSG_DONTWAIT), which the AST names.
export def nonblocking_name(call: String) -> String
  if call == "uv_run"
    return "UV_RUN_NOWAIT"
  end

  if call == "open" or call == "openat"
    return "O_NONBLOCK"
  end

  if WAIT_CALLS.include?(call)
    return "WNOHANG"
  end

  return "MSG_DONTWAIT"
end

## Returns whether the argument of a call of `FLAG_ARGUMENTS` is one value to compare (the mode of `uv_run`), not
## flags to test bit by bit.
export def one_value?(call: String) -> Bool
  return call == "uv_run"
end

## Returns the bit of the flag that makes a call of `FLAG_ARGUMENTS` return at once on `target`, a triple of clang
## (`x86_64-pc-linux-gnu`), or 0 when the rules do not know its value there: Linux, but on MIPS, SPARC, Alpha and
## PA-RISC, whose values differ, and macOS. WNOHANG is 1 on Linux (every architecture) and macOS.
export def nonblocking_bit(target: String, call: String) -> Int
  if one_value?(call)
    return UV_RUN_NOWAIT_VALUE
  end

  if WAIT_CALLS.include?(call)
    if apple?(target) or target.include?("-linux")
      return 1
    end

    return 0
  end

  dontwait = call != "open" and call != "openat"
  if apple?(target)
    if dontwait
      return 0x80
    end

    return 0x4
  end

  arch = target.split("-").first
  odd = ["mips", "sparc", "alpha", "hppa", "parisc"].any? do |prefix| arch.start_with?(prefix) end
  if target.include?("-linux") and not odd
    if dontwait
      return 0x40
    end

    return 0x800
  end

  return 0
end

## Returns whether the constant `flags` of a call of `FLAG_ARGUMENTS` makes it return at once, given its `bit`. The
## flags of the others are bits to test; the mode of `uv_run` is one value, so `UV_RUN_ONCE` (1) is not `NOWAIT` (2).
export def flags_return_at_once?(call: String, flags: Int, bit: Int) -> Bool
  if one_value?(call)
    return flags == bit
  end

  return Int.bit_and(flags, bit) != 0
end

# Whether a triple of clang is one of Apple's (`arm64-apple-macos`, `x86_64-apple-darwin23`).
def apple?(target: String) -> Bool
  return target.include?("-apple-") or target.include?("-darwin") or target.include?("-macos")
end
