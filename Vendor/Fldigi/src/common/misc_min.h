// ----------------------------------------------------------------------------
// misc_min.h  --  Auszug aus fldigi 4.2.13 (src/include/misc.h, modem.h, util.h)
//
// Nur die Helfer, die der RTTY-Empfänger braucht. Inhalte 1:1 übernommen.
// Copyright (C) 2006-2013 Dave Freese, W1HKJ, und fldigi-Autoren. GPLv3 (siehe UPSTREAM.md).
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_MISC_MIN_H
#define DIGIDEC_MISC_MIN_H

#include <cmath>

// modem.h
#define TWOPI (2.0 * M_PI)
#define SIGSEARCH 5

// util.h
#define CLAMP(x, low, high) (((x)>(high))?(high):(((x)<(low))?(low):(x)))

// misc.h
inline double sinc(double x)
{
	return (fabs(x) < 1e-10) ? 1.0 : (sin(M_PI * x) / (M_PI * x));
}

inline double decayavg(double average, double input, int weight)
{
	if (weight <= 1) return input;
	return ( ( input - average ) / (double)weight ) + average ;
}

// misc.cxx (Bitzähler für den Viterbi-Decoder, 1:1)
inline unsigned long hweight32(unsigned long w)
{
	unsigned long res = (w & 0x55555555) + ((w >> 1) & 0x55555555);
	res = (res & 0x33333333) + ((res >> 2) & 0x33333333);
	res = (res & 0x0F0F0F0F) + ((res >> 4) & 0x0F0F0F0F);
	res = (res & 0x00FF00FF) + ((res >> 8) & 0x00FF00FF);
	return (res & 0x0000FFFF) + ((res >> 16) & 0x0000FFFF);
}

inline int parity(unsigned long w)
{
	return hweight32(w) & 1;
}

#endif
