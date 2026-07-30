/*
 * correlateB2aMs_mex.c  — P2 hot-path correlator (B2a data+pilot E/P/L)
 *
 * [corr, remCodePhase, remCarrPhase] = correlateB2aMs_mex( ...
 *   rawSignal, codeData, codePilot, remCodePhase, remCarrPhase, ...
 *   codeFreq, carrFreq, fs, codeLength, elSpc, nh)
 *
 * corr is 1x12 double: [I_E Q_E I_P Q_P I_L Q_L pIE pQE pIP pQP pIL pQL]
 * Build:  mex -O mex/correlateB2aMs_mex.c -output mex/correlateB2aMs_mex
 */

#include "mex.h"
#include "matrix.h"
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double getScalar(const mxArray *a, const char *name)
{
    if (!mxIsDouble(a) || mxIsComplex(a) || mxGetNumberOfElements(a) != 1)
        mexErrMsgIdAndTxt("correlateB2aMs:arg", "%s must be real scalar double", name);
    return mxGetScalar(a);
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    if (nrhs != 11)
        mexErrMsgIdAndTxt("correlateB2aMs:nrhs", "Need 11 inputs");
    if (nlhs < 1)
        mexErrMsgIdAndTxt("correlateB2aMs:nlhs", "Need at least 1 output");

    /* rawSignal complex */
    if (!mxIsDouble(prhs[0]) || !mxIsComplex(prhs[0]))
        mexErrMsgIdAndTxt("correlateB2aMs:raw", "rawSignal must be complex double");
    mwSize nSig = mxGetNumberOfElements(prhs[0]);
    mxComplexDouble *raw = mxGetComplexDoubles(prhs[0]);

    if (!mxIsDouble(prhs[1]) || mxIsComplex(prhs[1]))
        mexErrMsgIdAndTxt("correlateB2aMs:code", "codeData must be real double");
    if (!mxIsDouble(prhs[2]) || mxIsComplex(prhs[2]))
        mexErrMsgIdAndTxt("correlateB2aMs:code", "codePilot must be real double");
    double *codeData  = mxGetPr(prhs[1]);
    double *codePilot = mxGetPr(prhs[2]);
    mwSize nCode = mxGetNumberOfElements(prhs[1]);
    if (mxGetNumberOfElements(prhs[2]) != nCode)
        mexErrMsgIdAndTxt("correlateB2aMs:code", "codeData/codePilot length mismatch");

    double remCodePhase = getScalar(prhs[3], "remCodePhase");
    double remCarrPhase = getScalar(prhs[4], "remCarrPhase");
    double codeFreq     = getScalar(prhs[5], "codeFreq");
    double carrFreq     = getScalar(prhs[6], "carrFreq");
    double fs           = getScalar(prhs[7], "fs");
    double codeLength   = getScalar(prhs[8], "codeLength");
    double elSpc        = getScalar(prhs[9], "elSpc");
    double nh           = getScalar(prhs[10], "nh");

    double codePhaseStep = codeFreq / fs;
    mwSize blksize = (mwSize)ceil((codeLength - remCodePhase) / codePhaseStep);
    if (blksize < 1) blksize = 1;
    if (blksize > nSig) blksize = nSig;

    double IE=0, QE=0, IP=0, QP=0, IL=0, QL=0;
    double pIE=0, pQE=0, pIP=0, pQP=0, pIL=0, pQL=0;

    double twoPiF = carrFreq * 2.0 * M_PI;
    double remCodeOut = remCodePhase;
    double remCarrOut = remCarrPhase;

    for (mwSize i = 0; i < blksize; ++i) {
        double tchip = remCodePhase + (double)i * codePhaseStep;
        double tE = tchip - elSpc;
        double tL = tchip + elSpc;
        double tP = tchip;

        /* ceil(t)+1 MATLAB 1-based into padded code vector */
        mwIndex iE = (mwIndex)ceil(tE) + 1; /* 1-based */
        mwIndex iL = (mwIndex)ceil(tL) + 1;
        mwIndex iP = (mwIndex)ceil(tP) + 1;
        if (iE < 1) iE = 1;
        if (iL < 1) iL = 1;
        if (iP < 1) iP = 1;
        if (iE > nCode) iE = nCode;
        if (iL > nCode) iL = nCode;
        if (iP > nCode) iP = nCode;

        double cE = codeData[iE - 1];
        double cL = codeData[iL - 1];
        double cP = codeData[iP - 1];
        double qE = nh * codePilot[iE - 1];
        double qL = nh * codePilot[iL - 1];
        double qP = nh * codePilot[iP - 1];

        double phase = twoPiF * ((double)i / fs) + remCarrPhase;
        double cs = cos(phase);
        double sn = sin(phase);
        /* carrsig = exp(1i*phase) = cs + 1i*sn
         * base = raw * carrsig
         * MATLAB: qbb = real(base), ibb = imag(base)
         * raw = xr + 1i*xi
         * base = (xr+1i*xi)*(cs+1i*sn) = (xr*cs - xi*sn) + 1i*(xr*sn + xi*cs)
         */
        double xr = raw[i].real;
        double xi = raw[i].imag;
        double qbb = xr * cs - xi * sn;
        double ibb = xr * sn + xi * cs;

        IE += cE * ibb; QE += cE * qbb;
        IP += cP * ibb; QP += cP * qbb;
        IL += cL * ibb; QL += cL * qbb;
        pIE += qE * ibb; pQE += qE * qbb;
        pIP += qP * ibb; pQP += qP * qbb;
        pIL += qL * ibb; pQL += qL * qbb;

        if (i + 1 == blksize) {
            remCodeOut = tP + codePhaseStep - codeLength;
            remCarrOut = fmod(twoPiF * ((double)blksize / fs) + remCarrPhase, 2.0 * M_PI);
            if (remCarrOut < 0) remCarrOut += 2.0 * M_PI;
        }
    }

    plhs[0] = mxCreateDoubleMatrix(1, 12, mxREAL);
    double *o = mxGetPr(plhs[0]);
    o[0]=IE; o[1]=QE; o[2]=IP; o[3]=QP; o[4]=IL; o[5]=QL;
    o[6]=pIE; o[7]=pQE; o[8]=pIP; o[9]=pQP; o[10]=pIL; o[11]=pQL;

    if (nlhs > 1) {
        plhs[1] = mxCreateDoubleScalar(remCodeOut);
    }
    if (nlhs > 2) {
        plhs[2] = mxCreateDoubleScalar(remCarrOut);
    }
}
