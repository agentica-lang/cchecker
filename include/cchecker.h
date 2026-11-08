/* Annotations for cchecker, the rule checker for C (https://github.com/agentica-lang/cchecker).
 *
 * Each macro expands to an `annotate` attribute that clang keeps in its AST, where cchecker reads it. For every other
 * compiler the macros are empty, so a project can annotate its code and still build with gcc, MSVC or tcc.
 *
 *   CC_SHORT                    the function never blocks and does bounded work
 *   CC_BLOCKING                 the function may block
 *   CC_HOT                      the function never allocates and makes no system call
 *   CC_OWNS                     the pointer owns its memory: free it or hand it on on every path
 *   CC_PAIR(set, restore)       the function changes state that `restore` puts back
 *   CC_NO_SYSCALL_UNDER(lock)   the function makes no system call while `lock` is held
 *   CC_IGNORE("CODE", "reason") a finding of the rules on the function is a false positive, for this reason
 *
 * Put an annotation before the declaration, or before the type of a parameter:
 *
 *   CC_SHORT int next_id(void);
 *   void adopt(CC_OWNS char *name);
 */
#ifndef CCHECKER_H
#define CCHECKER_H

#if defined(__clang__) && defined(CCHECKER_AST)
/* cchecker defines CCHECKER_AST when it dumps the AST: clang 19 leaves the text of `annotate` out of its JSON AST, and
 * keeps the message of `deprecated`. The dump hides the warnings this gives. */
#define CC_ANNOTATE_(text) __attribute__((deprecated("cchecker:" text)))
#elif defined(__clang__)
#define CC_ANNOTATE_(text) __attribute__((annotate("cchecker:" text)))
#endif

#if defined(__clang__)
/* The arguments are kept as written, so `CC_PAIR(mask_signals, restore_signals)` is "pair(mask_signals, ...)". */
#define CC_ANNOTATE_ARGS_(name, ...) CC_ANNOTATE_(name "(" #__VA_ARGS__ ")")
#define CC_SHORT CC_ANNOTATE_("short")
#define CC_BLOCKING CC_ANNOTATE_("blocking")
#define CC_HOT CC_ANNOTATE_("hot")
#define CC_OWNS CC_ANNOTATE_("owns")
#define CC_PAIR(...) CC_ANNOTATE_ARGS_("pair", __VA_ARGS__)
#define CC_NO_SYSCALL_UNDER(...) CC_ANNOTATE_ARGS_("no_syscall_under", __VA_ARGS__)
/* The code and the reason are string literals: `CC_IGNORE("CC-EFFECT-SHORT-BLOCKS", "...")` is "ignore(CODE: ...)". */
#define CC_IGNORE(code, reason) CC_ANNOTATE_("ignore(" code ": " reason ")")
#else
#define CC_SHORT
#define CC_BLOCKING
#define CC_HOT
#define CC_OWNS
#define CC_PAIR(...)
#define CC_NO_SYSCALL_UNDER(...)
#define CC_IGNORE(code, reason)
#endif

#endif
