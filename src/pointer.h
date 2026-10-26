/*
 * Copyright (c) 2026, BC (https://github.com/bciuca).
 * SPDX-License-Identifier: MIT
 * See LICENSE in the project root for the full license text.
 */

#ifndef MAGIC_POINTER_H
#define MAGIC_POINTER_H

/* These signatures and event IDs must be checked against the target firmware.
 */
typedef int (*mp_position_fn)(void *, int, int);
typedef int (*mp_wheel_fn)(void *, int);
typedef int (*mp_custom_fn)(void *, int, unsigned int);

/* Returns 0 only after all replacements are installed; never hooks buttons. */
int mp_install(void);
/* Revert patches, retaining library/trampolines until process exit. */
void mp_restore(void);

#endif
