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

## The calls of libuv that wait. Its file calls run at once, on the calling thread, when they are given no callback:
## the rules count one as blocking only when its last argument is NULL or 0.
export LIBUV_BLOCKING = Set.new([
  "uv_run", "uv_sleep", "uv_thread_join", "uv_mutex_lock", "uv_rwlock_rdlock", "uv_rwlock_wrlock", "uv_cond_wait",
  "uv_cond_timedwait", "uv_sem_wait", "uv_barrier_wait", "uv_once", "uv_fs_close", "uv_fs_open", "uv_fs_read",
  "uv_fs_unlink", "uv_fs_write", "uv_fs_copyfile", "uv_fs_mkdir", "uv_fs_mkdtemp", "uv_fs_mkstemp", "uv_fs_rmdir",
  "uv_fs_opendir", "uv_fs_closedir", "uv_fs_readdir", "uv_fs_scandir", "uv_fs_stat", "uv_fs_fstat", "uv_fs_lstat",
  "uv_fs_statfs", "uv_fs_rename", "uv_fs_fsync", "uv_fs_fdatasync", "uv_fs_ftruncate", "uv_fs_sendfile",
  "uv_fs_access", "uv_fs_chmod", "uv_fs_fchmod", "uv_fs_utime", "uv_fs_futime", "uv_fs_lutime", "uv_fs_link",
  "uv_fs_symlink", "uv_fs_readlink", "uv_fs_realpath", "uv_fs_chown", "uv_fs_fchown", "uv_fs_lchown",
])

## The calls of the Boehm GC that wait: a full collection stops the world.
export LIBGC_BLOCKING = Set.new(["GC_gcollect"])

## The families of blocking calls, in the order of the README.
export BLOCKING_FAMILIES = [
  Family(flag: "libc_blocking", calls: LIBC_BLOCKING),
  Family(flag: "pthread_blocking", calls: PTHREAD_BLOCKING),
  Family(flag: "libuv_blocking", calls: LIBUV_BLOCKING),
  Family(flag: "libgc_blocking", calls: LIBGC_BLOCKING),
]

## Every call that can block, whatever the settings: each enters the kernel, which the CC_HOT rule forbids.
export BLOCKING = LIBC_BLOCKING.union(PTHREAD_BLOCKING).union(LIBUV_BLOCKING).union(LIBGC_BLOCKING)

## The `[library]` flag of the roots inferred from `LOOP_CALLBACKS`.
export CALLBACKS_FLAG = "libuv_callbacks_short"

## The libuv calls that run a callback on the loop thread, and the places of those callbacks among their arguments
## (from 0). Such a callback runs on the event loop, so it is a CC_SHORT root. The `work_cb` of `uv_queue_work`
## (place 2) runs on a thread of the pool and is not one; its `after_work_cb` is.
export LOOP_CALLBACKS: Map[String, List[Int]] = {
  "uv_timer_start": [1],
  "uv_poll_start": [2],
  "uv_async_init": [2],
  "uv_close": [1],
  "uv_read_start": [1, 2],
  "uv_write": [4],
  "uv_write2": [5],
  "uv_shutdown": [2],
  "uv_tcp_connect": [3],
  "uv_pipe_connect": [3],
  "uv_pipe_connect2": [5],
  "uv_queue_work": [3],
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
  "unlinkat", "rename", "renameat", "mkdir", "mkdirat", "rmdir", "chdir", "fchdir", "getcwd", "truncate", "ftruncate",
  "fallocate", "chmod", "fchmod", "chown", "fchown", "utimensat", "opendir", "readdir", "closedir", "mmap", "munmap",
  "mremap", "mprotect", "madvise", "mlock", "munlock", "brk", "sbrk", "ioctl", "fcntl", "dup", "dup2", "dup3", "pipe",
  "pipe2", "socket", "socketpair", "bind", "listen", "shutdown", "setsockopt", "getsockopt", "getsockname",
  "getpeername", "epoll_create", "epoll_create1", "epoll_ctl", "eventfd", "timerfd_create", "timerfd_settime",
  "signalfd", "inotify_init", "inotify_init1", "inotify_add_watch", "kill", "tgkill", "raise", "sigaction", "signal",
  "sigprocmask", "pthread_sigmask", "sigaltstack", "fork", "vfork", "execve", "execv", "execvp", "execl", "execlp",
  "posix_spawn", "posix_spawnp", "_exit", "getpid", "getppid", "gettid", "syscall", "sched_yield", "prctl", "uname",
  "getrandom", "getrlimit", "setrlimit", "pthread_create", "pthread_kill", "pthread_cond_signal",
  "pthread_cond_broadcast", "pthread_mutex_unlock", "sem_post", "uv_thread_create", "uv_async_send", "uv_cond_signal",
  "uv_cond_broadcast", "uv_mutex_unlock",
])

## A family of library knowledge: the flag of `[library]` that turns it on or off, and the calls it says block.
export struct Family
  flag: String
  calls: Set[String]
end
