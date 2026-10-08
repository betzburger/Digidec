// SPDX-License-Identifier: GPL-3.0-or-later
// jsc_lookup.c  --  Digidec: Wort zu einem Index des JSC-Wörterbuchs (jsc_words.c). Der Offsettisch wird beim ersten Aufruf gebildet.
#include "jsc_words.h"
#include <pthread.h>
#include <stdlib.h>

static unsigned *offsets;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void build(void)
{
    unsigned *table = malloc(sizeof(unsigned) * (jsc_word_count + 1));
    if (!table) return;
    unsigned long pos = 0;
    for (unsigned i = 0; i < jsc_word_count; i++) {
        table[i] = (unsigned)pos;
        while (jsc_words[pos] != 0) pos++;
        pos++;
    }
    table[jsc_word_count] = (unsigned)pos;
    offsets = table;
}

const char *jsc_word(unsigned index, unsigned *length)
{
    pthread_once(&once, build);
    if (!offsets || index >= jsc_word_count) { if (length) *length = 0; return 0; }
    if (length) *length = offsets[index + 1] - offsets[index] - 1;
    return jsc_words + offsets[index];
}
