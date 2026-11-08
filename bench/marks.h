/* The annotations that the bench adds to the VM of Agentica (.bench/agentica) with `-include`, as a project would write
 * them in its own headers: its allocators return values of the collector. */
#include <stddef.h>
#include "cchecker.h"
CC_GC_ALLOC void *agc_alloc(size_t size);
CC_GC_ALLOC void *agc_alloc_atomic(size_t size);
