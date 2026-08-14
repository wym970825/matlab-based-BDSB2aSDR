/*
 * correlateB2aMs_mex.c — B2a 1-ms dual-channel E/P/L correlator
 *
 * Optimizations (mexBaseFast):
 *   - Carrier NCO: uint32 phase accumulator (cycles in Q32)
 *   - Cos/sin: 4096-entry float LUT (no libm sin/cos per sample)
 *   - SSE2: 2-sample carrier wipe-off + partial MAC where aligned
 *   - Code early/prompt/late still per-sample (variable index)
 *
 * [corr, remCodePhase, remCarrPhase] = correlateB2aMs_mex(...)
 * corr 1x12: [I_E Q_E I_P Q_P I_L Q_L pIE pQE pIP pQP pIL pQL]
 *
 * mex -O -R2018a correlateB2aMs_mex.c -output correlateB2aMs_mex
 */

#include "mex.h"
#include "matrix.h"
#include <math.h>
#include <stdint.h>
#include <string.h>

#ifdef _MSC_VER
#  include <intrin.h>
#else
#  include <emmintrin.h>  /* SSE2 */
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define LUT_BITS    12
#define LUT_SIZE    (1u << LUT_BITS)
#define LUT_MASK    (LUT_SIZE - 1u)
#define PHASE_SHIFT (32 - LUT_BITS)

static float g_cosLUT[LUT_SIZE];
static float g_sinLUT[LUT_SIZE];
static int   g_lutReady = 0;

static void ensureLUT(void)
{
    unsigned i;
    double scale;
    if (g_lutReady) return;
    scale = 2.0 * M_PI / (double)LUT_SIZE;
    for (i = 0; i < LUT_SIZE; ++i) {
        double ph = scale * (double)i;
        g_cosLUT[i] = (float)cos(ph);
        g_sinLUT[i] = (float)sin(ph);
    }
    g_lutReady = 1;
}

static uint32_t phaseToNco(double phaseRad)
{
    double x = phaseRad * (1.0 / (2.0 * M_PI));
    x -= floor(x);
    if (x < 0.0) x += 1.0;
    return (uint32_t)(x * 4294967296.0);
}

static double getScalar(const mxArray *a, const char *name)
{
    if (!mxIsDouble(a) || mxIsComplex(a) || mxGetNumberOfElements(a) != 1)
        mexErrMsgIdAndTxt("correlateB2aMs:arg", "%s must be real scalar double", name);
    return mxGetScalar(a);
}

/* Clamp code index to [1, nCode] (MATLAB 1-based into padded table) */
static mwIndex clampIdx(double tchip, mwSize nCode)
{
    mwIndex idx = (mwIndex)ceil(tchip) + 1;
    if (idx < 1) idx = 1;
    if (idx > nCode) idx = nCode;
    return idx;
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    mwSize nSig, nCode, blksize, i;
    mxComplexDouble *raw;
    double *codeData, *codePilot;
    double remCodePhase, remCarrPhase, codeFreq, carrFreq, fs, codeLength, elSpc, nh;
    double codePhaseStep, remCodeOut, remCarrOut;
    double IE, QE, IP, QP, IL, QL, pIE, pQE, pIP, pQP, pIL, pQL;
    uint32_t phaseNco, dphiNco;
    double *o;

    /* SSE2 accumulators (pairs): we still accumulate to double for stability */
    __m128d accIE = _mm_setzero_pd(), accQE = _mm_setzero_pd();
    __m128d accIP = _mm_setzero_pd(), accQP = _mm_setzero_pd();
    __m128d accIL = _mm_setzero_pd(), accQL = _mm_setzero_pd();
    __m128d accpIE = _mm_setzero_pd(), accpQE = _mm_setzero_pd();
    __m128d accpIP = _mm_setzero_pd(), accpQP = _mm_setzero_pd();
    __m128d accpIL = _mm_setzero_pd(), accpQL = _mm_setzero_pd();

    if (nrhs != 11)
        mexErrMsgIdAndTxt("correlateB2aMs:nrhs", "Need 11 inputs");
    if (nlhs < 1)
        mexErrMsgIdAndTxt("correlateB2aMs:nlhs", "Need at least 1 output");

    ensureLUT();

    if (!mxIsDouble(prhs[0]) || !mxIsComplex(prhs[0]))
        mexErrMsgIdAndTxt("correlateB2aMs:raw", "rawSignal must be complex double");
    nSig = mxGetNumberOfElements(prhs[0]);
    raw  = mxGetComplexDoubles(prhs[0]);

    if (!mxIsDouble(prhs[1]) || mxIsComplex(prhs[1]) ||
        !mxIsDouble(prhs[2]) || mxIsComplex(prhs[2]))
        mexErrMsgIdAndTxt("correlateB2aMs:code", "codes must be real double");
    codeData  = mxGetPr(prhs[1]);
    codePilot = mxGetPr(prhs[2]);
    nCode = mxGetNumberOfElements(prhs[1]);
    if (mxGetNumberOfElements(prhs[2]) != nCode)
        mexErrMsgIdAndTxt("correlateB2aMs:code", "code length mismatch");

    remCodePhase = getScalar(prhs[3], "remCodePhase");
    remCarrPhase = getScalar(prhs[4], "remCarrPhase");
    codeFreq     = getScalar(prhs[5], "codeFreq");
    carrFreq     = getScalar(prhs[6], "carrFreq");
    fs           = getScalar(prhs[7], "fs");
    codeLength   = getScalar(prhs[8], "codeLength");
    elSpc        = getScalar(prhs[9], "elSpc");
    nh           = getScalar(prhs[10], "nh");

    codePhaseStep = codeFreq / fs;
    blksize = (mwSize)ceil((codeLength - remCodePhase) / codePhaseStep);
    if (blksize < 1) blksize = 1;
    if (blksize > nSig) blksize = nSig;

    phaseNco = phaseToNco(remCarrPhase);
    {
        double df = carrFreq / fs;
        df -= floor(df);
        if (df < 0.0) df += 1.0;
        dphiNco = (uint32_t)(df * 4294967296.0 + 0.5);
    }

    /* Process 2 samples at a time with SSE2 multiply-add pattern */
    for (i = 0; i + 1 < blksize; i += 2) {
        double t0 = remCodePhase + (double)i * codePhaseStep;
        double t1 = t0 + codePhaseStep;
        mwIndex iE0, iL0, iP0, iE1, iL1, iP1;
        unsigned li0, li1;
        float cs0, sn0, cs1, sn1;
        double xr0, xi0, xr1, xi1;
        double qbb0, ibb0, qbb1, ibb1;
        double cE0, cL0, cP0, cE1, cL1, cP1;
        double qE0, qL0, qP0, qE1, qL1, qP1;
        __m128d v_ibb, v_qbb, v_c, v_q;

        iE0 = clampIdx(t0 - elSpc, nCode);
        iL0 = clampIdx(t0 + elSpc, nCode);
        iP0 = clampIdx(t0, nCode);
        iE1 = clampIdx(t1 - elSpc, nCode);
        iL1 = clampIdx(t1 + elSpc, nCode);
        iP1 = clampIdx(t1, nCode);

        cE0 = codeData[iE0 - 1]; cL0 = codeData[iL0 - 1]; cP0 = codeData[iP0 - 1];
        cE1 = codeData[iE1 - 1]; cL1 = codeData[iL1 - 1]; cP1 = codeData[iP1 - 1];
        qE0 = nh * codePilot[iE0 - 1]; qL0 = nh * codePilot[iL0 - 1]; qP0 = nh * codePilot[iP0 - 1];
        qE1 = nh * codePilot[iE1 - 1]; qL1 = nh * codePilot[iL1 - 1]; qP1 = nh * codePilot[iP1 - 1];

        li0 = (unsigned)(phaseNco >> PHASE_SHIFT) & LUT_MASK;
        cs0 = g_cosLUT[li0]; sn0 = g_sinLUT[li0];
        phaseNco += dphiNco;
        li1 = (unsigned)(phaseNco >> PHASE_SHIFT) & LUT_MASK;
        cs1 = g_cosLUT[li1]; sn1 = g_sinLUT[li1];
        phaseNco += dphiNco;

        xr0 = raw[i].real;   xi0 = raw[i].imag;
        xr1 = raw[i+1].real; xi1 = raw[i+1].imag;

        qbb0 = xr0 * (double)cs0 - xi0 * (double)sn0;
        ibb0 = xr0 * (double)sn0 + xi0 * (double)cs0;
        qbb1 = xr1 * (double)cs1 - xi1 * (double)sn1;
        ibb1 = xr1 * (double)sn1 + xi1 * (double)cs1;

        v_ibb = _mm_set_pd(ibb1, ibb0);
        v_qbb = _mm_set_pd(qbb1, qbb0);

        v_c = _mm_set_pd(cE1, cE0);
        accIE = _mm_add_pd(accIE, _mm_mul_pd(v_c, v_ibb));
        accQE = _mm_add_pd(accQE, _mm_mul_pd(v_c, v_qbb));

        v_c = _mm_set_pd(cP1, cP0);
        accIP = _mm_add_pd(accIP, _mm_mul_pd(v_c, v_ibb));
        accQP = _mm_add_pd(accQP, _mm_mul_pd(v_c, v_qbb));

        v_c = _mm_set_pd(cL1, cL0);
        accIL = _mm_add_pd(accIL, _mm_mul_pd(v_c, v_ibb));
        accQL = _mm_add_pd(accQL, _mm_mul_pd(v_c, v_qbb));

        v_q = _mm_set_pd(qE1, qE0);
        accpIE = _mm_add_pd(accpIE, _mm_mul_pd(v_q, v_ibb));
        accpQE = _mm_add_pd(accpQE, _mm_mul_pd(v_q, v_qbb));

        v_q = _mm_set_pd(qP1, qP0);
        accpIP = _mm_add_pd(accpIP, _mm_mul_pd(v_q, v_ibb));
        accpQP = _mm_add_pd(accpQP, _mm_mul_pd(v_q, v_qbb));

        v_q = _mm_set_pd(qL1, qL0);
        accpIL = _mm_add_pd(accpIL, _mm_mul_pd(v_q, v_ibb));
        accpQL = _mm_add_pd(accpQL, _mm_mul_pd(v_q, v_qbb));
    }

    /* Horizontal sum SSE2 accumulators */
    {
        double t[2];
        _mm_storeu_pd(t, accIE); IE = t[0] + t[1];
        _mm_storeu_pd(t, accQE); QE = t[0] + t[1];
        _mm_storeu_pd(t, accIP); IP = t[0] + t[1];
        _mm_storeu_pd(t, accQP); QP = t[0] + t[1];
        _mm_storeu_pd(t, accIL); IL = t[0] + t[1];
        _mm_storeu_pd(t, accQL); QL = t[0] + t[1];
        _mm_storeu_pd(t, accpIE); pIE = t[0] + t[1];
        _mm_storeu_pd(t, accpQE); pQE = t[0] + t[1];
        _mm_storeu_pd(t, accpIP); pIP = t[0] + t[1];
        _mm_storeu_pd(t, accpQP); pQP = t[0] + t[1];
        _mm_storeu_pd(t, accpIL); pIL = t[0] + t[1];
        _mm_storeu_pd(t, accpQL); pQL = t[0] + t[1];
    }

    /* Odd tail sample */
    if (i < blksize) {
        double tchip = remCodePhase + (double)i * codePhaseStep;
        mwIndex iE = clampIdx(tchip - elSpc, nCode);
        mwIndex iL = clampIdx(tchip + elSpc, nCode);
        mwIndex iP = clampIdx(tchip, nCode);
        unsigned li = (unsigned)(phaseNco >> PHASE_SHIFT) & LUT_MASK;
        float cs = g_cosLUT[li], sn = g_sinLUT[li];
        double xr = raw[i].real, xi = raw[i].imag;
        double qbb = xr * (double)cs - xi * (double)sn;
        double ibb = xr * (double)sn + xi * (double)cs;
        double cE = codeData[iE - 1], cL = codeData[iL - 1], cP = codeData[iP - 1];
        double qE = nh * codePilot[iE - 1], qL = nh * codePilot[iL - 1], qP = nh * codePilot[iP - 1];
        phaseNco += dphiNco;
        IE += cE * ibb; QE += cE * qbb;
        IP += cP * ibb; QP += cP * qbb;
        IL += cL * ibb; QL += cL * qbb;
        pIE += qE * ibb; pQE += qE * qbb;
        pIP += qP * ibb; pQP += qP * qbb;
        pIL += qL * ibb; pQL += qL * qbb;
    }

    remCodeOut = remCodePhase + (double)(blksize - 1) * codePhaseStep
                 + codePhaseStep - codeLength;
    remCarrOut = (double)phaseNco * (2.0 * M_PI / 4294967296.0);

    plhs[0] = mxCreateDoubleMatrix(1, 12, mxREAL);
    o = mxGetPr(plhs[0]);
    o[0]=IE; o[1]=QE; o[2]=IP; o[3]=QP; o[4]=IL; o[5]=QL;
    o[6]=pIE; o[7]=pQE; o[8]=pIP; o[9]=pQP; o[10]=pIL; o[11]=pQL;

    if (nlhs > 1) plhs[1] = mxCreateDoubleScalar(remCodeOut);
    if (nlhs > 2) plhs[2] = mxCreateDoubleScalar(remCarrOut);
}
