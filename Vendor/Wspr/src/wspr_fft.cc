// wspr_fft.cc -- Digidec: FFTW-Ersatz für wsprd auf pocketfft (BSD-3). Siehe wspr_fftw.h.
#include <complex>
#include <cstdlib>
#include <cstddef>
#include "pocketfft_hdronly.h"
#include "wspr_fftw.h"

struct digidec_fftwf_plan_s {
    int kind;      // 0 r2c, 1 c2c
    int n;
    int sign;
    float *rin;
    fftwf_complex *in;
    fftwf_complex *out;
};

extern "C" {

void *fftwf_malloc(size_t n) { return std::malloc(n); }
void fftwf_free(void *p) { std::free(p); }

fftwf_plan fftwf_plan_dft_r2c_1d(int n, float *in, fftwf_complex *out, unsigned)
{ return new digidec_fftwf_plan_s{0, n, FFTW_FORWARD, in, nullptr, out}; }

fftwf_plan fftwf_plan_dft_1d(int n, fftwf_complex *in, fftwf_complex *out, int sign, unsigned)
{ return new digidec_fftwf_plan_s{1, n, sign, nullptr, in, out}; }

void fftwf_destroy_plan(fftwf_plan p) { delete p; }

void fftwf_execute(const fftwf_plan p)
{
    pocketfft::shape_t shape{(size_t)p->n};
    if (p->kind == 0) {
        pocketfft::r2c(shape, {(ptrdiff_t)sizeof(float)}, {(ptrdiff_t)sizeof(std::complex<float>)}, 0,
                       pocketfft::FORWARD, p->rin, reinterpret_cast<std::complex<float> *>(p->out), 1.0f, 1);
    } else {
        pocketfft::stride_t st{(ptrdiff_t)sizeof(std::complex<float>)};
        pocketfft::c2c(shape, st, st, {0}, p->sign == FFTW_FORWARD,
                       reinterpret_cast<std::complex<float> *>(p->in),
                       reinterpret_cast<std::complex<float> *>(p->out), 1.0f, 1);
    }
}

}
