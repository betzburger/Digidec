// Digidec: Definitionen, die fldigi über config.h / util.h / hamlib bereitstellt
#ifndef DIGIDEC_COMPAT_H
#define DIGIDEC_COMPAT_H
#define HAVE_STD_HASH 1
#define HAMLIB_API
// Hamlib-Rückgabewerte wie in hamlib/rig.h (Funktionen liefern -RIG_EINVAL)
#define RIG_OK 0
#define RIG_EINVAL 1
#ifndef likely
#  define likely(x)   __builtin_expect (!!(x), 1)
#  define unlikely(x) __builtin_expect (!!(x), 0)
#endif
#endif
