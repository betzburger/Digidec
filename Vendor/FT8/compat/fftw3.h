// ----------------------------------------------------------------------------
// fftw3.h  --  Digidec: Ersatz für die Teile von FFTW 3, die ft8mon (fft.cc, ft8.cc) benutzt, auf pocketfft.
// Gleiche Konventionen wie FFTW: unnormiert, r2c liefert n/2+1 Werte, c2r erwartet sie, Vorzeichen FORWARD = −1.
// pocketfft (Max-Planck-Gesellschaft, BSD-3) rechnet beliebige Längen und ist threadsicher.
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_FFTW3_COMPAT_H
#define DIGIDEC_FFTW3_COMPAT_H

#include <complex>
#include <cstdlib>
#include <cstddef>
#include "pocketfft_hdronly.h"

typedef double fftw_complex[2];

#define FFTW_MEASURE   0U
#define FFTW_PATIENT   32U
#define FFTW_ESTIMATE  64U
#define FFTW_FORWARD   (-1)
#define FFTW_BACKWARD  (+1)

struct digidec_fftw_plan_s {
	int kind;   // 0 r2c, 1 c2r, 2 c2c
	int n;
	int sign;
};
typedef digidec_fftw_plan_s *fftw_plan;

inline void *fftw_malloc(size_t n) { return std::malloc(n); }
inline void fftw_free(void *p) { std::free(p); }
inline void fftw_set_timelimit(double) {}
inline void fftw_make_planner_thread_safe(void) {}

inline fftw_plan fftw_plan_dft_r2c_1d(int n, double *, fftw_complex *, unsigned)
{ return new digidec_fftw_plan_s{0, n, FFTW_FORWARD}; }
inline fftw_plan fftw_plan_dft_c2r_1d(int n, fftw_complex *, double *, unsigned)
{ return new digidec_fftw_plan_s{1, n, FFTW_BACKWARD}; }
inline fftw_plan fftw_plan_dft_1d(int n, fftw_complex *, fftw_complex *, int sign, unsigned)
{ return new digidec_fftw_plan_s{2, n, sign}; }
inline void fftw_destroy_plan(fftw_plan p) { delete p; }

inline void fftw_execute_dft_r2c(const fftw_plan p, double *in, fftw_complex *out)
{
	pocketfft::shape_t shape{(size_t)p->n};
	pocketfft::r2c(shape, {(ptrdiff_t)sizeof(double)}, {(ptrdiff_t)sizeof(std::complex<double>)}, 0,
	               pocketfft::FORWARD, in, reinterpret_cast<std::complex<double> *>(out), 1.0, 1);
}

inline void fftw_execute_dft_c2r(const fftw_plan p, fftw_complex *in, double *out)
{
	pocketfft::shape_t shape{(size_t)p->n};
	pocketfft::c2r(shape, {(ptrdiff_t)sizeof(std::complex<double>)}, {(ptrdiff_t)sizeof(double)}, 0,
	               pocketfft::BACKWARD, reinterpret_cast<std::complex<double> *>(in), out, 1.0, 1);
}

inline void fftw_execute_dft(const fftw_plan p, fftw_complex *in, fftw_complex *out)
{
	pocketfft::shape_t shape{(size_t)p->n};
	pocketfft::stride_t st{(ptrdiff_t)sizeof(std::complex<double>)};
	pocketfft::c2c(shape, st, st, {0}, p->sign == FFTW_FORWARD,
	               reinterpret_cast<std::complex<double> *>(in), reinterpret_cast<std::complex<double> *>(out), 1.0, 1);
}

#endif
