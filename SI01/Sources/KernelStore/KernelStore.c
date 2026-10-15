#include "KernelStore.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

struct SI01KernelStore {
    size_t taps;
    _Atomic unsigned published;
    _Atomic unsigned reader;
    double *slots[3];
};

struct SI01JobState { _Atomic unsigned state; };

SI01KernelStore *si01_kernel_store_create(size_t taps) {
    if (taps == 0) return NULL;
    SI01KernelStore *s = (SI01KernelStore *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->taps = taps;
    atomic_init(&s->published, 0);
    atomic_init(&s->reader, UINT_MAX);
    for (unsigned i = 0; i < 3; ++i) {
        s->slots[i] = (double *)calloc(taps, sizeof(double));
        if (!s->slots[i]) {
            for (unsigned j = 0; j < i; ++j) free(s->slots[j]);
            free(s);
            return NULL;
        }
    }
    return s;
}

void si01_kernel_store_destroy(SI01KernelStore *s) {
    if (!s) return;
    for (unsigned i = 0; i < 3; ++i) free(s->slots[i]);
    free(s);
}

const double *si01_kernel_read_begin(SI01KernelStore *s) {
    if (!s) return NULL;
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
        unsigned idx = atomic_load_explicit(&s->published, memory_order_acquire);
        atomic_store_explicit(&s->reader, idx, memory_order_release);
        if (atomic_load_explicit(&s->published, memory_order_acquire) == idx)
            return s->slots[idx];
        atomic_store_explicit(&s->reader, UINT_MAX, memory_order_release);
    }
    return NULL;
}

void si01_kernel_read_end(SI01KernelStore *s) {
    if (s) atomic_store_explicit(&s->reader, UINT_MAX, memory_order_release);
}

bool si01_kernel_publish(SI01KernelStore *s, const double *taps, size_t count) {
    if (!s || !taps || count != s->taps) return false;
    unsigned active = atomic_load_explicit(&s->published, memory_order_acquire);
    unsigned reader = atomic_load_explicit(&s->reader, memory_order_acquire);
    unsigned target = UINT_MAX;
    for (unsigned i = 0; i < 3; ++i) {
        if (i != active && i != reader) { target = i; break; }
    }
    if (target == UINT_MAX) return false;
    memcpy(s->slots[target], taps, count * sizeof(double));
    atomic_store_explicit(&s->published, target, memory_order_release);
    return true;
}

SI01JobState *si01_job_state_create(void) {
    SI01JobState *s = (SI01JobState *)calloc(1, sizeof(*s));
    if (s) atomic_init(&s->state, 0);
    return s;
}
void si01_job_state_destroy(SI01JobState *s) { free(s); }
bool si01_job_begin_write(SI01JobState *s) {
    if (!s) return false;
    unsigned expected = 0;
    return atomic_compare_exchange_strong_explicit(&s->state, &expected, 2,
        memory_order_acq_rel, memory_order_acquire);
}
void si01_job_finish_write(SI01JobState *s) {
    if (s) atomic_store_explicit(&s->state, 1, memory_order_release);
}
bool si01_job_take(SI01JobState *s) {
    if (!s) return false;
    unsigned expected = 1;
    return atomic_compare_exchange_strong_explicit(&s->state, &expected, 2,
        memory_order_acq_rel, memory_order_acquire);
}
void si01_job_finish_read(SI01JobState *s) {
    if (s) atomic_store_explicit(&s->state, 0, memory_order_release);
}
bool si01_job_is_pending(SI01JobState *s) {
    return s && atomic_load_explicit(&s->state, memory_order_acquire) == 1;
}
