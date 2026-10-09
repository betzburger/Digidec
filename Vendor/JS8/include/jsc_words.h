// jsc_words.h  --  JSC-Wörterbuch von JS8Call (Latin-1, durch NUL getrennt, in Indexreihenfolge), siehe port_jsc.py
#ifndef JSC_WORDS_H
#define JSC_WORDS_H

#ifdef __cplusplus
extern "C" {
#endif

extern const char jsc_words[];
extern const unsigned long jsc_words_size;   ///< Byte einschließlich des letzten NUL
extern const unsigned jsc_word_count;        ///< 262 144

/// Wort Nr. `index` (Latin-1, NUL-terminiert) und seine Länge in Byte; NULL außerhalb
const char *jsc_word(unsigned index, unsigned *length);

#ifdef __cplusplus
}
#endif

#endif
