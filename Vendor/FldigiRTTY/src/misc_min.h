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

#endif
