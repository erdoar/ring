#ifndef SI01_KERNEL_STORE_H
#define SI01_KERNEL_STORE_H
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SI01KernelStore SI01KernelStore;
typedef struct SI01JobState SI01JobState;

SI01KernelStore *si01_kernel_store_create(size_t taps);
void si01_kernel_store_destroy(SI01KernelStore *store);
/* Pins an immutable published slot for the caller. Returns NULL on a bounded retry miss. */
const double *si01_kernel_read_begin(SI01KernelStore *store);
void si01_kernel_read_end(SI01KernelStore *store);
/* Publishes into a slot that is neither active nor currently read. */
bool si01_kernel_publish(SI01KernelStore *store, const double *taps, size_t count);

SI01JobState *si01_job_state_create(void);
void si01_job_state_destroy(SI01JobState *state);
/* 0 = idle, 1 = pending, 2 = being written/read. */
bool si01_job_begin_write(SI01JobState *state);
void si01_job_finish_write(SI01JobState *state);
bool si01_job_take(SI01JobState *state);
void si01_job_finish_read(SI01JobState *state);
bool si01_job_is_pending(SI01JobState *state);

#ifdef __cplusplus
}
#endif
#endif
