/* wspr_fftw.h -- Digidec: Ersatz für die FFTW-3-Aufrufe (Gleitkomma, "fftwf_") von wsprd auf pocketfft.
 * Gleiche Konventionen wie FFTW: unnormiert, r2c liefert n/2+1 Werte, FORWARD = -1.
 * Reines C-Interface; die Umsetzung steht in wspr_fft.cc. */
#ifndef DIGIDEC_WSPR_FFTW_H
#define DIGIDEC_WSPR_FFTW_H

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef float fftwf_complex[2];
typedef struct digidec_fftwf_plan_s *fftwf_plan;

#define FFTW_MEASURE   0U
#define FFTW_ESTIMATE  64U
#define FFTW_FORWARD   (-1)
#define FFTW_BACKWARD  (+1)

void *fftwf_malloc(size_t n);
void fftwf_free(void *p);
fftwf_plan fftwf_plan_dft_r2c_1d(int n, float *in, fftwf_complex *out, unsigned flags);
fftwf_plan fftwf_plan_dft_1d(int n, fftwf_complex *in, fftwf_complex *out, int sign, unsigned flags);
void fftwf_execute(const fftwf_plan p);
void fftwf_destroy_plan(fftwf_plan p);

#ifdef __cplusplus
}
#endif
#endif
