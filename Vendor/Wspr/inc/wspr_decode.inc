// ----------------------------------------------------------------------------
// wspr_decode.inc  --  Digidec: Ersatz für main() aus wsprd.c (WSJT-X lib/wsprd, K1JT/K9AN, GPLv3).
//
// Wird am Ende von wspr_rx.c eingefügt (siehe port_wspr.py). Der Rumpf folgt main() Zeile für Zeile;
// jede Abweichung ist mit "ABWEICHUNG wsprd (Digidec)" gekennzeichnet:
//   - Audio kommt aus dem Speicher (12 kHz) statt aus einer .wav-/.c2-Datei, Ergebnisse gehen an einen Rückruf
//   - keine Kommandozeile: Voreinstellungen von wsprd (Fano-Decoder, 3 Durchgänge, Subtraktion, Hashtabelle)
//   - keine Dateien (ALL_WSPR.TXT, wspr_spots.txt, Zeitdatei, FFTW-Wisdom); die Hashtabelle liegt im Speicher
//   - ps[][] liegt auf dem Heap (735 kB auf dem Stack überfordern Arbeitsthreads)
//   - die optionale OSD-Stufe (Fortran, "-o") fehlt
// ----------------------------------------------------------------------------
#include <pthread.h>
#include "wspr_digidec.h"

static pthread_mutex_t g_wspr_mu = PTHREAD_MUTEX_INITIALIZER;
static char *g_hashtab = NULL;     // ABWEICHUNG wsprd (Digidec): bleibt zwischen den Aufrufen erhalten
static char *g_loctab = NULL;

static void wspr_tables_init(void)
{
    if (!g_hashtab) g_hashtab = calloc(32768*13, sizeof(char));
    if (!g_loctab) g_loctab = calloc(32768*5, sizeof(char));
}

// ABWEICHUNG wsprd (Digidec): readwavfile() für Daten aus dem Speicher (gleiche Rechnung, 12 kHz → 375 Hz komplex)
static unsigned long wspr_downsample(const float *samples, int count, float *idat, float *qdat)
{
    size_t i, j, npoints;
    int nfft1, nfft2, nh2, i0;
    double df;

    nfft2=46080;
    nh2=nfft2/2;
    nfft1=nfft2*32;
    df=12000.0/nfft1;
    i0=1500.0/df+0.5;
    npoints=114*12000;

    float *realin=(float*) fftwf_malloc(sizeof(float)*nfft1);
    fftwf_complex *fftout=(fftwf_complex*) fftwf_malloc(sizeof(fftwf_complex)*(nfft1/2+1));
    fftwf_plan plan1 = fftwf_plan_dft_r2c_1d(nfft1, realin, fftout, PATIENCE);

    for (i=0; i<npoints; i++) {
        realin[i] = ((int)i < count) ? samples[i] : 0.0f;   // fehlendes Ende = Stille
    }
    for (i=npoints; i<(size_t)nfft1; i++) {
        realin[i]=0.0;
    }
    fftwf_execute(plan1);
    fftwf_free(realin);

    fftwf_complex *fftin=(fftwf_complex*) fftwf_malloc(sizeof(fftwf_complex)*nfft2);
    for (i=0; i<(size_t)nfft2; i++) {
        j=i0+i;
        if( i>(size_t)nh2 ) j=j-nfft2;
        fftin[i][0]=fftout[j][0];
        fftin[i][1]=fftout[j][1];
    }
    fftwf_free(fftout);
    fftout=(fftwf_complex*) fftwf_malloc(sizeof(fftwf_complex)*nfft2);
    fftwf_plan plan2 = fftwf_plan_dft_1d(nfft2, fftin, fftout, FFTW_BACKWARD, PATIENCE);
    fftwf_execute(plan2);

    // Eingang war in Volt-Einheiten ±1 (wsprd: Int16/32768); gleiche Skalierung
    for (i=0; i<(size_t)nfft2; i++) {
        idat[i]=fftout[i][0]/1000.0;
        qdat[i]=fftout[i][1]/1000.0;
    }
    fftwf_free(fftin);
    fftwf_free(fftout);
    fftwf_destroy_plan(plan1);
    fftwf_destroy_plan(plan2);
    return nfft2;
}

static int wspr_decode_locked(const float *samples, int count, int wide, int deep,
                              wsprdd_decode_fn on_decode, void *ctx)
{
    int i,j,k;
    unsigned char *symbols, *decdata, *channel_symbols;
    signed char message[]={-9,13,-35,123,57,-39,64,0,0,0,0};
    char *callsign, *grid,  *call_loc_pow;
    int delta,maxpts=65536,more_candidates=deep,quickmode=0;
    int ipass, nblocksize;
    int nhardmin;
    int maxdrift;
    int shift1, lagmin, lagmax, lagstep, ifmin, ifmax, not_decoded;
    unsigned int nbits=81;
    unsigned int npoints, cycles=0, maxnp, metric=0;
    float df=375.0/256.0/2;
    float dt=1.0/375.0, dt_print;
    float fmin=-110, fmax=110;
    float f1, fstep, sync1, drift1;
    float psavg[512];
    float *idat, *qdat;
    const int wspr_type=2;

    struct cand { float freq; float snr; int shift; float drift; float sync; };
    struct cand candidates[200];

    struct result { float sync; float snr;
        float dt; double freq; char message[23]; float drift;
        unsigned int cycles; int ipass; };
    struct result decodes[50];

    char *hashtab = g_hashtab;
    char *loctab = g_loctab;
    symbols=calloc(nbits*2,sizeof(unsigned char));
    decdata=calloc(11,sizeof(unsigned char));
    channel_symbols=calloc(nbits*2,sizeof(unsigned char));
    callsign=calloc(13,sizeof(char));
    grid=calloc(5,sizeof(char));
    call_loc_pow=calloc(23,sizeof(char));
    float allfreqs[100];
    char allcalls[100][13];
    for (i=0; i<100; i++) allfreqs[i]=0.0;
    memset(allcalls,0,sizeof(char)*100*13);

    int uniques=0, noprint=0, ndecodes_pass=0;

    // Parameters used for performance-tuning (Voreinstellungen von wsprd):
    unsigned int maxcycles=10000;            //Decoder timeout limit
    float minsync1=0.10;                     //First sync limit
    float minsync2=0.12;                     //Second sync limit
    int iifac=8;                             //Step size in final DT peakup
    int symfac=50;                           //Soft-symbol normalizing factor
    int subtraction=1;
    int npasses=3;

    float minrms=52.0 * (symfac/64.0);      //Final test for plausible decoding
    delta=60;                                //Fano threshold step
    float bias=0.45;                        //Fano metric bias (used for both Fano and stack algorithms)

    fftwf_complex *fftin, *fftout;
#include "metric_tables.inc"

    int mettab[2][256];

    idat=calloc(maxpts,sizeof(float));
    qdat=calloc(maxpts,sizeof(float));

    if (wide) { fmin=-150.0; fmax=150.0; }

    // setup metric table
    for(i=0; i<256; i++) {
        mettab[0][i]=round( 10*(metric_tables[2][i]-bias) );
        mettab[1][i]=round( 10*(metric_tables[2][255-i]-bias) );
    }

    npoints=wspr_downsample(samples, count, idat, qdat);

    // Do windowed ffts over 2 symbols, stepped by half symbols
    int nffts=4*floor(npoints/512)-1;
    fftin=(fftwf_complex*) fftwf_malloc(sizeof(fftwf_complex)*512);
    fftout=(fftwf_complex*) fftwf_malloc(sizeof(fftwf_complex)*512);
    PLAN3 = fftwf_plan_dft_1d(512, fftin, fftout, FFTW_FORWARD, PATIENCE);

    float (*ps)[nffts] = malloc(sizeof(float)*512*nffts);   // ABWEICHUNG wsprd (Digidec): Heap statt Stack
    float w[512];
    for(i=0; i<512; i++) {
        w[i]=sin(0.006147931*i);
    }

    //*************** main loop starts here *****************
    for (ipass=0; ipass<npasses; ipass++) {
        if(ipass==1 && ndecodes_pass == 0 && npasses>2) ipass=2;
        if(ipass < 2) {
            nblocksize=1;
            maxdrift=4;
            minsync2=0.12;
        }
        if(ipass == 2 ) {
            nblocksize=4;  // try 3 blocksizes plus bitbybit normalization
            maxdrift=0;    // no drift for smaller frequency estimator variance
            minsync2=0.10;
        }
        ndecodes_pass=0;   // still needed?

        for (i=0; i<nffts; i++) {
            for(j=0; j<512; j++ ) {
                k=i*128+j;
                fftin[j][0]=idat[k] * w[j];
                fftin[j][1]=qdat[k] * w[j];
            }
            fftwf_execute(PLAN3);
            for (j=0; j<512; j++ ) {
                k=j+256;
                if( k>511 )
                    k=k-512;
                ps[j][i]=fftout[k][0]*fftout[k][0]+fftout[k][1]*fftout[k][1];
            }
        }

        // Compute average spectrum
        for (i=0; i<512; i++) psavg[i]=0.0;
        for (i=0; i<nffts; i++) {
            for (j=0; j<512; j++) {
                psavg[j]=psavg[j]+ps[j][i];
            }
        }

        // Smooth with 7-point window and limit spectrum to +/-150 Hz
        int window[7]={1,1,1,1,1,1,1};
        float smspec[411];
        for (i=0; i<411; i++) {
            smspec[i]=0.0;
            for(j=-3; j<=3; j++) {
                k=256-205+i+j;
                smspec[i]=smspec[i]+window[j+3]*psavg[k];
            }
        }

        // Sort spectrum values, then pick off noise level as a percentile
        float tmpsort[411];
        for (j=0; j<411; j++) {
            tmpsort[j]=smspec[j];
        }
        qsort(tmpsort, 411, sizeof(float), floatcomp);

        // Noise level of spectrum is estimated as 123/411= 30'th percentile
        float noise_level = tmpsort[122];

        /* Renormalize spectrum so that (large) peaks represent an estimate of snr.
         * We know from experience that threshold snr is near -7dB in wspr bandwidth,
         * corresponding to -7-26.3=-33.3dB in 2500 Hz bandwidth.
         * The corresponding threshold is -42.3 dB in 2500 Hz bandwidth for WSPR-15. */

        float min_snr, snr_scaling_factor;
        min_snr = pow(10.0,-8.0/10.0); //this is min snr in wspr bw
        if( wspr_type == 2 ) {
            snr_scaling_factor=26.3;
        } else {
            snr_scaling_factor=35.3;
        }
        for (j=0; j<411; j++) {
            smspec[j]=smspec[j]/noise_level - 1.0;
            if( smspec[j] < min_snr) smspec[j]=0.1*min_snr;
            continue;
        }

        // Find all local maxima in smoothed spectrum.
        for (i=0; i<200; i++) {
            candidates[i].freq=0.0;
            candidates[i].snr=0.0;
            candidates[i].drift=0.0;
            candidates[i].shift=0;
            candidates[i].sync=0.0;
        }

        int npk=0;
        unsigned char candidate;
        for(j=1; j<410; j++) {
            candidate = (smspec[j]>smspec[j-1]) &&
            (smspec[j]>smspec[j+1]) &&
            (npk<200);
            if ( candidate ) {
                candidates[npk].freq = (j-205)*df;
                candidates[npk].snr  = 10*log10(smspec[j])-snr_scaling_factor;
                npk++;
            }
        }
        if( more_candidates ) {
            for(j=0; j<411; j=j+3) {
                candidate = (smspec[j]>min_snr) && (npk<200);
                if ( candidate ) {
                    candidates[npk].freq = (j-205)*df;
                    candidates[npk].snr  = 10*log10(smspec[j])-snr_scaling_factor;
                    npk++;
                }
            }
        }

        // Don't waste time on signals outside of the range [fmin,fmax].
        // (Dial-Fehler-Korrektur von wsprd entfällt: fmin/fmax werden hier nicht verschoben.)
        i=0;
        for( j=0; j<npk; j++) {
            if( candidates[j].freq >= fmin && candidates[j].freq <= fmax ) {
                candidates[i]=candidates[j];
                i++;
            }
        }
        npk=i;

        // bubble sort on snr
        int pass;
        struct cand tmp;
        for (pass = 1; pass <= npk - 1; pass++) {
            for (k = 0; k < npk - pass ; k++) {
                if (candidates[k].snr < candidates[k+1].snr) {
                    tmp = candidates[k];
                    candidates[k]=candidates[k+1];
                    candidates[k+1] = tmp;
                }
            }
        }

        /* Make coarse estimates of shift (DT), freq, and drift

         * Look for time offsets up to +/- 8 symbols (about +/- 5.4 s) relative
         to nominal start time, which is 2 seconds into the file

         * Calculates shift relative to the beginning of the file

         * Negative shifts mean that signal started before start of file

         * The program prints DT = shift-2 s

         * Shifts that cause sync vector to fall off of either end of the data
         vector are accommodated by "partial decoding", such that missing
         symbols produce a soft-decision symbol value of 128

         * The frequency drift model is linear, deviation of +/- drift/2 over the
         span of 162 symbols, with deviation equal to 0 at the center of the
         signal vector.
         */

        int idrift,ifr,if0,ifd,k0;
        int kindex;
        float smax,ss,pow,p0,p1,p2,p3;
        for(j=0; j<npk; j++) {                              //For each candidate...
            smax=-1e30;
            if0=candidates[j].freq/df+256;
            for (ifr=if0-2; ifr<=if0+2; ifr++) {                      //Freq search
                for( k0=-10; k0<22; k0++) {                             //Time search
                    for (idrift=-maxdrift; idrift<=maxdrift; idrift++) {  //Drift search
                        ss=0.0;
                        pow=0.0;
                        for (k=0; k<162; k++) {                             //Sum over symbols
                            ifd=ifr+((float)k-81.0)/81.0*( (float)idrift )/(2.0*df);
                            kindex=k0+2*k;
                            if( kindex >= 0 && kindex < nffts ) {
                                p0=ps[ifd-3][kindex];
                                p1=ps[ifd-1][kindex];
                                p2=ps[ifd+1][kindex];
                                p3=ps[ifd+3][kindex];

                                p0=sqrt(p0);
                                p1=sqrt(p1);
                                p2=sqrt(p2);
                                p3=sqrt(p3);

                                ss=ss+(2*pr3[k]-1)*((p1+p3)-(p0+p2));
                                pow=pow+p0+p1+p2+p3;
                            }
                        }
                        sync1=ss/pow;
                        if( sync1 > smax ) {                  //Save coarse parameters
                            smax=sync1;
                            candidates[j].shift=128*(k0+1);
                            candidates[j].drift=idrift;
                            candidates[j].freq=(ifr-256)*df;
                            candidates[j].sync=sync1;
                        }
                    }
                }
            }
        }

        /*
         Refine the estimates of freq, shift using sync as a metric.
         Sync is calculated such that it is a float taking values in the range
         [0.0,1.0].

         Function sync_and_demodulate has three modes of operation
         mode is the last argument:

         0 = no frequency or drift search. find best time lag.
         1 = no time lag or drift search. find best frequency.
         2 = no frequency or time lag search. Calculate soft-decision
         symbols using passed frequency and shift.
         */
        for (j=0; j<npk; j++) {

            f1=candidates[j].freq;
            drift1=candidates[j].drift;
            shift1=candidates[j].shift;
            sync1=candidates[j].sync;

            // coarse-grid lag and freq search, then if sync>minsync1 continue
            fstep=0.0; ifmin=0; ifmax=0;
            lagmin=shift1-128;
            lagmax=shift1+128;
            lagstep=64;
            sync_and_demodulate(idat, qdat, npoints, symbols, &f1, ifmin, ifmax, fstep, &shift1,
                                lagmin, lagmax, lagstep, &drift1, symfac, &sync1, 0);

            fstep=0.25; ifmin=-2; ifmax=2;
            sync_and_demodulate(idat, qdat, npoints, symbols, &f1, ifmin, ifmax, fstep, &shift1,
                                lagmin, lagmax, lagstep, &drift1, symfac, &sync1, 1);

            if(ipass < 2) {
                // refine drift estimate
                fstep=0.0; ifmin=0; ifmax=0;
                float driftp,driftm,syncp,syncm;
                driftp=drift1+0.5;
                sync_and_demodulate(idat, qdat, npoints, symbols, &f1, ifmin, ifmax, fstep, &shift1,
                                    lagmin, lagmax, lagstep, &driftp, symfac, &syncp, 1);

                driftm=drift1-0.5;
                sync_and_demodulate(idat, qdat, npoints, symbols, &f1, ifmin, ifmax, fstep, &shift1,
                                    lagmin, lagmax, lagstep, &driftm, symfac, &syncm, 1);

                if(syncp>sync1) {
                    drift1=driftp;
                    sync1=syncp;
                } else if (syncm>sync1) {
                    drift1=driftm;
                    sync1=syncm;
                }
            }

            // fine-grid lag and freq search
            if( sync1 > minsync1 ) {

                lagmin=shift1-32; lagmax=shift1+32; lagstep=16;
                sync_and_demodulate(idat, qdat, npoints, symbols, &f1, ifmin, ifmax, fstep, &shift1,
                                    lagmin, lagmax, lagstep, &drift1, symfac, &sync1, 0);

                // fine search over frequency
                fstep=0.05; ifmin=-2; ifmax=2;
                sync_and_demodulate(idat, qdat, npoints, symbols, &f1, ifmin, ifmax, fstep, &shift1,
                                    lagmin, lagmax, lagstep, &drift1, symfac, &sync1, 1);

                candidates[j].freq=f1;
                candidates[j].shift=shift1;
                candidates[j].drift=drift1;
                candidates[j].sync=sync1;
            }
        }

        int nwat=0;
        int idupe;
        for ( j=0; j<npk; j++) {
            idupe=0;
            for (k=0;k<nwat;k++) {
                if( fabsf(candidates[j].freq - candidates[k].freq) < 0.05  &&
                   abs(candidates[j].shift - candidates[k].shift) < 16 ) {
                    idupe=1;
                    break;
                }
            }
            if( idupe == 1 ) {
                if(candidates[j].sync > candidates[k].sync) candidates[k]=candidates[j];
            } else if ( candidates[j].sync > minsync2 ) {
                candidates[nwat]=candidates[j];
                nwat++;
            }
        }

        int idt, ii, jittered_shift;
        float y,sq,rms;
        int ib, blocksize, bitmetric;
        for (j=0; j<nwat; j++) {
            memset(symbols,0,sizeof(char)*nbits*2);
            memset(callsign,0,sizeof(char)*13);
            memset(grid,0,sizeof(char)*5);
            memset(call_loc_pow,0,sizeof(char)*23);
            f1=candidates[j].freq;
            shift1=candidates[j].shift;
            drift1=candidates[j].drift;
            not_decoded=1;

            ib=1;
            while( ib <= nblocksize && not_decoded ) {
                if (ib < 4) { blocksize=ib; bitmetric=0; }
                if (ib == 4) { blocksize=1; bitmetric=1; }

                idt=0; ii=0;
                while ( not_decoded && idt<=(128/iifac)) {
                    ii=(idt+1)/2;
                    if( idt%2 == 1 ) ii=-ii;
                    ii=iifac*ii;
                    jittered_shift=shift1+ii;
                    nhardmin=0;

                    // Get soft-decision symbols
                    noncoherent_sequence_detection(idat, qdat, npoints, symbols, &f1,
                                                   &jittered_shift, &drift1, symfac, &blocksize, &bitmetric);

                    sq=0.0;
                    for(i=0; i<162; i++) {
                        y=(float)symbols[i] - 128.0;
                        sq += y*y;
                    }
                    rms=sqrt(sq/162.0);

                    if(rms > minrms) {
                        deinterleave(symbols);

                        not_decoded = fano(&metric,&cycles,&maxnp,decdata,symbols,nbits,
                                           mettab,delta,maxcycles);
                        // ABWEICHUNG wsprd (Digidec): OSD-Stufe (osdwspr_, Fortran) entfällt
                    }
                    idt++;
                    if( quickmode ) break;
                }
                ib++;
            }

            if( !not_decoded ) {
                ndecodes_pass++;

                for(i=0; i<11; i++) {

                    if( decdata[i]>127 ) {
                        message[i]=decdata[i]-256;
                    } else {
                        message[i]=decdata[i];
                    }

                }

                // Unpack the decoded message, update the hashtable, apply
                // sanity checks on grid and power, and return
                // call_loc_pow string and also callsign (for de-duping).
                noprint=unpk_(message,hashtab,loctab,call_loc_pow,callsign);
                if( subtraction && !noprint ) {
                    if( get_wspr_channel_symbols(call_loc_pow, hashtab, loctab, channel_symbols) ) {
                        subtract_signal2(idat, qdat, npoints, f1, shift1, drift1, channel_symbols);
                        nhardmin=count_hard_errors(symbols,channel_symbols);
                    } else {
                        break;
                    }
                }

                // Remove dupes (same callsign and freq within 4 Hz)
                int dupe=0;
                for (i=0; i<uniques; i++) {
                    if(!strcmp(callsign,allcalls[i]) &&
                       (fabs(f1-allfreqs[i]) <4.0)) dupe=1;
                }
                if( !dupe && !noprint && uniques < 50 ) {
                    strcpy(allcalls[uniques],callsign);
                    allfreqs[uniques]=f1;
                    uniques++;

                    dt_print=shift1*dt-1.0;

                    decodes[uniques-1].sync=candidates[j].sync;
                    decodes[uniques-1].snr=candidates[j].snr;
                    decodes[uniques-1].dt=dt_print;
                    decodes[uniques-1].freq=1500+f1;     // ABWEICHUNG wsprd (Digidec): NF-Frequenz statt Funkfrequenz
                    strcpy(decodes[uniques-1].message,call_loc_pow);
                    decodes[uniques-1].drift=drift1;
                    decodes[uniques-1].cycles=cycles;
                    decodes[uniques-1].ipass=ipass;
                }
            }
        }
    }

    // sort the result in order of increasing frequency
    struct result temp;
    for (j = 1; j <= uniques - 1; j++) {
        for (k = 0; k < uniques - j ; k++) {
            if (decodes[k].freq > decodes[k+1].freq) {
                temp = decodes[k];
                decodes[k]=decodes[k+1];;
                decodes[k+1] = temp;
            }
        }
    }

    // ABWEICHUNG wsprd (Digidec): Rückruf statt Ausgabe in Datei und Konsole
    if (on_decode) {
        for (i=0; i<uniques; i++) {
            wsprdd_decode d;
            memset(&d, 0, sizeof d);
            strncpy(d.message, decodes[i].message, sizeof d.message - 1);
            d.snr_db = decodes[i].snr;
            d.dt = decodes[i].dt;
            d.freq_hz = decodes[i].freq;
            d.drift = decodes[i].drift;
            d.sync = decodes[i].sync;
            d.pass = decodes[i].ipass + 1;
            d.cycles = (int)decodes[i].cycles;
            on_decode(ctx, &d);
        }
    }

    fftwf_free(fftin);
    fftwf_free(fftout);
    fftwf_destroy_plan(PLAN3);

    free(ps);
    free(symbols);
    free(decdata);
    free(channel_symbols);
    free(callsign);
    free(grid);
    free(call_loc_pow);
    free(idat);
    free(qdat);

    return uniques;
}

int wsprdd_decode_slot(const float *samples, int count, int wide, int deep, wsprdd_decode_fn on_decode, void *ctx)
{
    if (!samples || count < 12000 * 60) return -1;
    pthread_mutex_lock(&g_wspr_mu);
    wspr_tables_init();
    int n = wspr_decode_locked(samples, count, wide, deep, on_decode, ctx);
    pthread_mutex_unlock(&g_wspr_mu);
    return n;
}

int wsprdd_hash_load(const char *path)
{
    pthread_mutex_lock(&g_wspr_mu);
    wspr_tables_init();
    FILE *f = fopen(path, "r");
    if (!f) { pthread_mutex_unlock(&g_wspr_mu); return -1; }
    char line[80], hcall[13], hgrid[5];
    int nh;
    while (fgets(line, sizeof(line), f) != NULL) {
        hgrid[0] = '\0';
        if (sscanf(line, "%d %12s %4s", &nh, hcall, hgrid) < 2) continue;
        if (nh < 0 || nh >= 32768) continue;
        strcpy(g_hashtab + nh*13, hcall);
        if (strlen(hgrid) > 0) strcpy(g_loctab + nh*5, hgrid);
    }
    fclose(f);
    pthread_mutex_unlock(&g_wspr_mu);
    return 0;
}

int wsprdd_hash_save(const char *path)
{
    pthread_mutex_lock(&g_wspr_mu);
    wspr_tables_init();
    FILE *f = fopen(path, "w");
    if (!f) { pthread_mutex_unlock(&g_wspr_mu); return -1; }
    for (int i = 0; i < 32768; i++) {
        if (strncmp(g_hashtab + i*13, "\0", 1) != 0) {
            fprintf(f, "%5d %s %s\n", i, g_hashtab + i*13, g_loctab + i*5);
        }
    }
    fclose(f);
    pthread_mutex_unlock(&g_wspr_mu);
    return 0;
}

// Testsignal: wie add_signal_vector() in wsprsim.c, aber reell bei 12 kHz (Töne 1,4648 Hz auseinander)
int wsprdd_synthesize(const char *message, double f0, double start_s, float *out, int max_samples)
{
    const int rate = 12000, total = 120 * rate;
    if (!out || max_samples < total) return -1;
    char msg[40];
    strncpy(msg, message, sizeof msg - 1);
    msg[sizeof msg - 1] = 0;
    pthread_mutex_lock(&g_wspr_mu);
    wspr_tables_init();
    unsigned char sym[162];
    int ok = get_wspr_channel_symbols(msg, g_hashtab, g_loctab, sym);
    pthread_mutex_unlock(&g_wspr_mu);
    if (!ok) return -2;
    memset(out, 0, sizeof(float) * total);
    const double df = 375.0/256.0, twopi = 8.0*atan(1.0);
    double phi = 0.0;
    long i0 = (long)(start_s * rate + 0.5);
    for (int i = 0; i < 162; i++) {
        double dphi = twopi * (f0 + ((double)sym[i] - 1.5) * df) / rate;
        for (int j = 0; j < 8192; j++) {
            long ii = i0 + (long)8192 * i + j;
            if (ii >= 0 && ii < total) out[ii] = (float)cos(phi);
            phi += dphi;
        }
    }
    return total;
}
